# lex-oms — HTTP Order Management System
#
# Endpoints:
#   POST /orders              validate + position check + enqueue to exchange
#   POST /execution-reports   apply lifecycle event + update positions
#   POST /cancel              validate cancel + transition to PendingCancel + trail
#   POST /replace             validate cancel/replace + state transitions + trail
#   GET  /blotter             list all order states
#   GET  /positions           current positions by account/symbol
#   GET  /audit               trail events (all, newest-first)
#   GET  /risk                portfolio risk snapshot
#   GET  /queue               pending job count
#   POST /queue/tick          process one queued order job
#
# Run:
#   lex run --allow-effects io,net,time,sql,concurrent \
#           src/server.lex main
#
# Effects: net, io, time, random, sql, fs_read, fs_write, concurrent

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.sql" as sql

import "std.map" as map

import "std.time" as time

import "std.json" as json

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as q

import "lex-orm/src/error" as dbe

import "lex-trail/src/log" as trail_log

import "lex-jobs/src/jobs" as jobs

import "lex-positions/src/position_store" as pstore

import "lex-positions/src/position" as pos

import "lex-trade/src/order" as order

import "lex-trade/src/limit" as limit

import "lex-trade/src/lifecycle" as lc

import "lex-trade/src/rejection" as rejection

import "lex-trade/src/validation_io" as vio

import "lex-trade/src/order_store" as ostore

import "lex-trade/src/cancel" as cancel

import "lex-trade/src/replace" as replace

import "lex-trade/src/price_check" as pc

import "lex-trade/src/exec_report_from_str" as efrs

import "lex-trade/src/trail_kinds" as kinds

import "lex-trade/src/position_check" as position_check

import "lex-money/src/decimal" as d

import "lex-marketdata/src/mock" as mock

import "./marks" as marks

import "lex-risk/src/margin" as risk_margin

import "lex-risk/src/portfolio" as risk_portfolio

import "lex-web/src/ctx" as ctx

import "lex-web/src/response" as resp

import "lex-web/src/router" as router

import "lex-web/src/middleware" as mw

# ---- Request body types ---------------------------------------------
type NewOrderBody = { cl_ord_id :: Str, symbol :: Str, side :: Str, quantity :: Int, order_type :: Str, price :: Str, stop_price :: Str, time_in_force :: Str, account :: Str, trader_id :: Str, timestamp :: Str }

type ExecReportBody = { exec_id :: Str, order_id :: Str, cl_ord_id :: Str, exec_type :: Str, ord_status :: Str, symbol :: Str, side :: Str, account :: Str, order_qty :: Str, cum_qty :: Str, leaves_qty :: Str, avg_px :: Str, last_px :: Str, last_qty :: Str, text :: Str }

type CancelBody = { cl_ord_id :: Str, orig_cl_ord_id :: Str, account :: Str, symbol :: Str, side :: Str, order_qty :: Int, timestamp :: Str }

type ReplaceBody = { orig_cl_ord_id :: Str, new_cl_ord_id :: Str, symbol :: Str, side :: Str, quantity :: Int, order_type :: Str, price :: Str, stop_price :: Str, time_in_force :: Str, account :: Str, trader_id :: Str, timestamp :: Str }

# ---- JSON response helpers ------------------------------------------
fn q(s :: Str) -> Str {
  "\"" + s + "\""
}

fn kv_s(k :: Str, v :: Str) -> Str {
  q(k) + ":" + q(v)
}

fn kv_i(k :: Str, v :: Int) -> Str {
  q(k) + ":" + int.to_str(v)
}

fn obj(fields :: List[Str]) -> Str {
  "{" + str.join(fields, ",") + "}"
}

fn arr(items :: List[Str]) -> Str {
  "[" + str.join(items, ",") + "]"
}

fn or_str(s :: Str, def :: Str) -> Str {
  if str.is_empty(s) {
    def
  } else {
    s
  }
}

fn or_int(n :: Int, def :: Int) -> Int {
  if n == 0 {
    def
  } else {
    n
  }
}

# Trail timestamp for a request. When the caller provides a sim_ts_ms
# state entry (in-process simulation dispatch — see lex-oms-agent), all
# trail events for the request use that sim-time, making them content-
# addressed reproducibly (replay verification). The HTTP path has no
# such entry and falls back to the wall clock — unchanged behavior.
fn req_ts(c :: ctx.Ctx) -> [time] Int {
  match map.get(c.state, "sim_ts_ms") {
    None => time.now_ms(),
    Some(s) => match str.to_int(s) {
      None => time.now_ms(),
      Some(n) => n,
    },
  }
}

# Reference mark for pre-trade risk checks. In simulation (sim_ts_ms in
# state) the mark is drawn from the seeded marks table and a miss is a hard
# reject — the sim must never risk-check against a phantom $0 price. The
# HTTP path has no sim_ts_ms and keeps the existing static-mock behavior
# (absent symbol => no mark, lenient pass), so live OMS semantics are
# unchanged by this code.
type MarkResult = MarkOk(Option[d.Decimal]) | MarkMissing(Str)

fn resolve_mark(db :: conn.ConnDb, c :: ctx.Ctx, symbol :: Str) -> [sql] MarkResult {
  match map.get(c.state, "sim_ts_ms") {
    None => match mock.get_reference_price(symbol) {
      Err(_) => MarkOk(None),
      Ok(p) => MarkOk(Some(p)),
    },
    Some(ts_s) => match str.to_int(ts_s) {
      None => MarkOk(None),
      Some(ts) => match marks.get(db, symbol, ts) {
        None => MarkMissing(symbol + "@" + ts_s),
        Some(p) => MarkOk(Some(p)),
      },
    },
  }
}

fn rejection_json(vs :: List[rejection.RejectionReason]) -> Str {
  let descs := list.map(vs, rejection.describe)
  obj([kv_s("status", "rejected"), q("violations") + ":" + arr(list.map(descs, q))])
}

fn err_422(vs :: List[rejection.RejectionReason]) -> resp.Response {
  { body: rejection_json(vs), status: 422, headers: map.from_list([("content-type", "application/json")]) }
}

# Reject an order AND record it on the trail. The pre-trade margin and
# position-notional gates previously returned a 422 without logging, so
# downstream consumers that scan the trail for `trade.order.rejected`
# (e.g. Lex Arena's disqualification check) never saw the breach. Logging
# here makes every rejection — quantity, margin, or notional — a first-
# class, replayable trail event.
fn reject_logged(log :: trail_log.Log, c :: ctx.Ctx, cl_ord_id :: Str, symbol :: Str, vs :: List[rejection.RejectionReason]) -> [sql, time] resp.Response {
  let rej_payload := obj([kv_s("cl_ord_id", cl_ord_id), kv_s("symbol", symbol), kv_s("status", "rejected"), kv_s("reason", str.join(list.map(vs, rejection.describe), "; "))])
  let __tr := trail_log.append_at(log, kinds.order_rejected(), None, rej_payload, req_ts(c))
  err_422(vs)
}

# ---- Side / kind parsing --------------------------------------------
fn parse_side(s :: Str) -> Result[order.OrderSide, resp.Response] {
  if s == "buy" {
    Ok(OrderBuy(()))
  } else {
    if s == "sell" {
      Ok(OrderSell(()))
    } else {
      Err(resp.bad_request("invalid side: " + s))
    }
  }
}

fn parse_order_kind(ot :: Str, price :: Str, stop :: Str) -> Result[order.OrderKind, resp.Response] {
  if ot == "market" {
    Ok(MarketOrder(()))
  } else {
    if ot == "limit" {
      if str.is_empty(price) {
        Err(resp.bad_request("limit orders require price"))
      } else {
        Ok(LimitOrder(price))
      }
    } else {
      if ot == "stop" {
        if str.is_empty(stop) {
          Err(resp.bad_request("stop orders require stop_price"))
        } else {
          Ok(StopOrder(stop))
        }
      } else {
        if ot == "stop_limit" {
          if str.is_empty(stop) {
            Err(resp.bad_request("stop_limit requires stop_price"))
          } else {
            if str.is_empty(price) {
              Err(resp.bad_request("stop_limit requires price"))
            } else {
              Ok(StopLimitOrder(stop, price))
            }
          }
        } else {
          Err(resp.bad_request("unknown order_type: " + ot))
        }
      }
    }
  }
}

# ---- DB init --------------------------------------------------------
fn init_db(db :: conn.ConnDb) -> [sql] Result[Unit, Str] {
  match ostore.init(db) {
    Err(e) => Err(dbe.message(e)),
    Ok(_) => match pstore.init(db) {
      Err(e) => Err(dbe.message(e)),
      Ok(_) => match jobs.init_schema(db.handle) {
        Err(e) => Err(e),
        Ok(_) => match marks.init(db) {
          Err(e) => Err(dbe.message(e)),
          Ok(_) => Ok(()),
        },
      },
    },
  }
}

# ---- POST /orders ---------------------------------------------------
fn post_orders(db :: conn.ConnDb, log :: trail_log.Log, c :: ctx.Ctx) -> [sql, time] resp.Response {
  let parsed :: Result[NewOrderBody, Str] := json.parse(c.body)
  match parsed {
    Err(msg) => resp.bad_request("invalid JSON: " + msg),
    Ok(b) => match parse_side(b.side) {
      Err(r) => r,
      Ok(side) => match parse_order_kind(b.order_type, b.price, b.stop_price) {
        Err(r) => r,
        Ok(kind) => {
          let tif := or_str(b.time_in_force, "0")
          let account := or_str(b.account, "DEFAULT")
          let trader_id := or_str(b.trader_id, "OMS")
          let timestamp := or_str(b.timestamp, "20260101-00:00:00.000")
          let o := order.order(b.cl_ord_id, b.symbol, side, b.quantity, kind, tif, account, trader_id, timestamp)
          let lim := limit.default_limits()
          match resolve_mark(db, c, b.symbol) {
            MarkMissing(what) => reject_logged(log, c, b.cl_ord_id, b.symbol, [PositionViolation("no reference mark for " + what)]),
            MarkOk(ref_opt) => {
              let mark_for_margin := match ref_opt {
                None => d.zero(),
                Some(p) => p,
              }
              let mc := risk_margin.default_margin_config()
              match risk_margin.pre_trade_check(b.quantity, mark_for_margin, mc) {
                Err(msg) => reject_logged(log, c, b.cl_ord_id, b.symbol, [PositionViolation("margin: " + msg)]),
                Ok(_) => {
                  let pos_cfg := { max_notional: d.from_int(50000000), allow_flip: false }
                  let mark_str := match ref_opt {
                    None => "0",
                    Some(p) => pos.decimal_to_str(p),
                  }
                  match position_check.check_position(db, pos_cfg, o, mark_str) {
                    FailedPositionCheck(reason) => reject_logged(log, c, b.cl_ord_id, b.symbol, [reason]),
                    PassedPositionCheck(_) => {
                      let lar := vio.validate_log_and_record_at(o, lim, ref_opt, pc.default_tolerance(), "OMS", "EXCH01", log, "", req_ts(c))
                      match lar.result {
                        Rejected(vs) => err_422(vs),
                        Accepted(_) => {
                          let __st := ostore.upsert(db, b.cl_ord_id, account, b.symbol, PendingNew(()))
                          let job_id := match jobs.enqueue(db.handle, "orders", "order.submit", b.cl_ord_id) {
                            Err(_) => 0,
                            Ok(id) => id,
                          }
                          resp.created_json(obj([kv_s("cl_ord_id", b.cl_ord_id), kv_s("status", "PendingNew"), kv_s("symbol", b.symbol), kv_s("account", account), kv_s("entry_id", lar.entry_id), kv_i("job_id", job_id)]), "/blotter/" + b.cl_ord_id)
                        },
                      }
                    },
                  }
                },
              }
            },
          }
        },
      },
    },
  }
}

# ---- POST /execution-reports ----------------------------------------
fn apply_fill_if_any(db :: conn.ConnDb, account :: Str, symbol :: Str, fills :: List[pos.Fill]) -> [sql] Unit {
  match list.head(fills) {
    None => (),
    Some(f) => {
      let key := { account: account, symbol: symbol }
      let __lex_discard_2 := pstore.apply_and_store(db, key, f)
      ()
    },
  }
}

fn post_execution_reports(db :: conn.ConnDb, c :: ctx.Ctx) -> [sql] resp.Response {
  let parsed :: Result[ExecReportBody, Str] := json.parse(c.body)
  match parsed {
    Err(msg) => resp.bad_request("invalid JSON: " + msg),
    Ok(b) => {
      let account := or_str(b.account, "DEFAULT")
      match efrs.from_strings(b.exec_id, b.order_id, b.cl_ord_id, b.exec_type, b.ord_status, b.symbol, b.side, b.order_qty, b.cum_qty, b.leaves_qty, b.avg_px, b.last_px, b.last_qty, b.text) {
        Err(msg) => resp.bad_request("cannot map report: " + msg),
        Ok(res) => match ostore.apply_event(db, b.cl_ord_id, account, b.symbol, res.event) {
          Err(_) => resp.internal_error(),
          Ok(new_state) => {
            let __lex_discard_3 := apply_fill_if_any(db, account, b.symbol, res.fill)
            resp.json(obj([kv_s("cl_ord_id", b.cl_ord_id), kv_s("new_state", lc.state_name(new_state))]))
          },
        },
      }
    },
  }
}

# ---- POST /cancel ---------------------------------------------------
fn post_cancel(db :: conn.ConnDb, log :: trail_log.Log, c :: ctx.Ctx) -> [sql, time] resp.Response {
  let parsed :: Result[CancelBody, Str] := json.parse(c.body)
  match parsed {
    Err(msg) => resp.bad_request("invalid JSON: " + msg),
    Ok(b) => match parse_side(b.side) {
      Err(r) => r,
      Ok(side) => {
        let qty := or_int(b.order_qty, 0)
        let timestamp := or_str(b.timestamp, "20260101-00:00:00.000")
        match cancel.validate_cancel(db, b.cl_ord_id, b.orig_cl_ord_id, b.account, b.symbol, side, qty, timestamp, "OMS", "EXCH01") {
          Err(reason) => err_422([reason]),
          Ok(req) => {
            let __st := ostore.upsert(db, b.orig_cl_ord_id, b.account, b.symbol, PendingCancel(()))
            let cancel_payload := obj([kv_s("orig_cl_ord_id", b.orig_cl_ord_id), kv_s("cl_ord_id", b.cl_ord_id), kv_s("symbol", b.symbol), kv_s("account", b.account)])
            let __tr := trail_log.append_at(log, kinds.cancel_requested(), None, cancel_payload, req_ts(c))
            resp.json(obj([kv_s("cl_ord_id", req.cl_ord_id), kv_s("orig_cl_ord_id", req.orig_cl_ord_id), kv_s("symbol", req.symbol), kv_s("status", "CancelRequested")]))
          },
        }
      },
    },
  }
}

# ---- POST /replace --------------------------------------------------
fn post_replace(db :: conn.ConnDb, log :: trail_log.Log, c :: ctx.Ctx) -> [sql, time] resp.Response {
  let parsed :: Result[ReplaceBody, Str] := json.parse(c.body)
  match parsed {
    Err(msg) => resp.bad_request("invalid JSON: " + msg),
    Ok(b) => match parse_side(b.side) {
      Err(r) => r,
      Ok(side) => match parse_order_kind(b.order_type, b.price, b.stop_price) {
        Err(r) => r,
        Ok(kind) => {
          let tif := or_str(b.time_in_force, "0")
          let account := or_str(b.account, "DEFAULT")
          let trader_id := or_str(b.trader_id, "OMS")
          let timestamp := or_str(b.timestamp, "20260101-00:00:00.000")
          let lim := limit.default_limits()
          let orig := order.order(b.orig_cl_ord_id, b.symbol, side, b.quantity, kind, tif, account, trader_id, timestamp)
          let amnd := order.order(b.new_cl_ord_id, b.symbol, side, b.quantity, kind, tif, account, trader_id, timestamp)
          match replace.validate_replace(orig, amnd, lim, "OMS", "EXCH01") {
            Rejected(vs) => {
              let rej_payload := obj([kv_s("orig_cl_ord_id", b.orig_cl_ord_id), kv_s("new_cl_ord_id", b.new_cl_ord_id), kv_s("symbol", b.symbol)])
              let __tr := trail_log.append_at(log, kinds.replace_rejected(), None, rej_payload, req_ts(c))
              err_422(vs)
            },
            Accepted(_) => {
              let __pc := ostore.upsert(db, b.orig_cl_ord_id, b.account, b.symbol, PendingCancel(()))
              let __pn := ostore.upsert(db, b.new_cl_ord_id, b.account, b.symbol, PendingNew(()))
              let replace_payload := obj([kv_s("orig_cl_ord_id", b.orig_cl_ord_id), kv_s("new_cl_ord_id", b.new_cl_ord_id), kv_s("symbol", b.symbol), kv_s("account", b.account)])
              let __tr := trail_log.append_at(log, kinds.replace_accepted(), None, replace_payload, req_ts(c))
              resp.json(obj([kv_s("orig_cl_ord_id", b.orig_cl_ord_id), kv_s("new_cl_ord_id", b.new_cl_ord_id), kv_s("status", "ReplaceAccepted")]))
            },
          }
        },
      },
    },
  }
}

# ---- GET /blotter ---------------------------------------------------
fn get_blotter(db :: conn.ConnDb, _c :: ctx.Ctx) -> [sql] resp.Response {
  let sq := q.for_dialect({ sql: "SELECT cl_ord_id, account, symbol, state_kind, filled_qty, avg_price_str FROM order_states ORDER BY rowid DESC LIMIT 200", params: [] }, db.dialect)
  let raw :: Result[List[{ cl_ord_id :: Str, account :: Str, symbol :: Str, state_kind :: Str, filled_qty :: Int, avg_price_str :: Str }], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match raw {
    Err(_) => resp.internal_error(),
    Ok(rows) => resp.json(arr(list.map(rows, fn (row :: { cl_ord_id :: Str, account :: Str, symbol :: Str, state_kind :: Str, filled_qty :: Int, avg_price_str :: Str }) -> Str {
      obj([kv_s("cl_ord_id", row.cl_ord_id), kv_s("account", row.account), kv_s("symbol", row.symbol), kv_s("state", row.state_kind), kv_i("filled_qty", row.filled_qty), kv_s("avg_price", row.avg_price_str)])
    }))),
  }
}

# ---- GET /positions -------------------------------------------------
fn get_positions(db :: conn.ConnDb, _c :: ctx.Ctx) -> [sql] resp.Response {
  let sq := q.for_dialect({ sql: "SELECT account, symbol, qty, avg_cost_str, realized_pnl_str FROM positions ORDER BY account, symbol", params: [] }, db.dialect)
  let raw :: Result[List[{ account :: Str, symbol :: Str, qty :: Int, avg_cost_str :: Str, realized_pnl_str :: Str }], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match raw {
    Err(_) => resp.internal_error(),
    Ok(rows) => resp.json(arr(list.map(rows, fn (row :: { account :: Str, symbol :: Str, qty :: Int, avg_cost_str :: Str, realized_pnl_str :: Str }) -> Str {
      obj([kv_s("account", row.account), kv_s("symbol", row.symbol), kv_i("qty", row.qty), kv_s("avg_cost", row.avg_cost_str), kv_s("realized_pnl", row.realized_pnl_str)])
    }))),
  }
}

# ---- GET /audit -----------------------------------------------------
fn get_audit(log :: trail_log.Log, _c :: ctx.Ctx) -> [sql] resp.Response {
  match trail_log.range(log, 0, 9999999999999) {
    Err(_) => resp.internal_error(),
    Ok(events) => {
      let items := list.map(list.reverse(events), fn (evt :: { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }) -> Str {
        let parent_s := match evt.parent {
          None => "null",
          Some(p) => q(p),
        }
        "{" + q("id") + ":" + q(evt.id) + "," + q("kind") + ":" + q(evt.kind) + "," + q("parent") + ":" + parent_s + "," + q("ts_ms") + ":" + int.to_str(evt.ts_ms) + "," + q("payload") + ":" + evt.payload_json + "}"
      })
      resp.json(arr(items))
    },
  }
}

# ---- GET /risk ------------------------------------------------------
fn get_risk(db :: conn.ConnDb, _c :: ctx.Ctx) -> [sql] resp.Response {
  let sq := q.for_dialect({ sql: "SELECT account, symbol, qty, avg_cost_str, realized_pnl_str FROM positions ORDER BY account, symbol", params: [] }, db.dialect)
  let raw :: Result[List[{ account :: Str, symbol :: Str, qty :: Int, avg_cost_str :: Str, realized_pnl_str :: Str }], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match raw {
    Err(_) => resp.internal_error(),
    Ok(rows) => {
      let entries := list.map(rows, fn (row :: { account :: Str, symbol :: Str, qty :: Int, avg_cost_str :: Str, realized_pnl_str :: Str }) -> risk_portfolio.MarkedPosition {
        let avg_cost := match pos.parse_price(row.avg_cost_str) {
          None => d.zero(),
          Some(p) => p,
        }
        let realized := match pos.parse_price(row.realized_pnl_str) {
          None => d.zero(),
          Some(p) => p,
        }
        let mark := match mock.get_reference_price(row.symbol) {
          Err(_) => avg_cost,
          Ok(p) => p,
        }
        { position: { key: { account: row.account, symbol: row.symbol }, qty: row.qty, avg_cost: avg_cost, realized_pnl: realized }, mark_price: mark }
      })
      let cfg := risk_margin.default_margin_config()
      let risk := risk_portfolio.portfolio_risk(entries, cfg)
      let pos_items := list.map(risk.positions, fn (pr :: risk_portfolio.PositionRisk) -> Str {
        obj([kv_s("account", pr.account), kv_s("symbol", pr.symbol), kv_i("qty", pr.qty), kv_i("delta", pr.delta), kv_s("dollar_delta", pos.decimal_to_str(pr.dollar_delta)), kv_s("gross_notional", pos.decimal_to_str(pr.gross_notional)), kv_s("unrealized_pnl", pos.decimal_to_str(pr.unrealized_pnl)), kv_s("initial_margin", pos.decimal_to_str(pr.initial_margin))])
      })
      resp.json(obj([q("positions") + ":" + arr(pos_items), kv_s("net_dollar_delta", pos.decimal_to_str(risk.net_dollar_delta)), kv_s("total_notional", pos.decimal_to_str(risk.total_notional)), kv_s("total_unreal_pnl", pos.decimal_to_str(risk.total_unreal_pnl)), kv_s("total_margin", pos.decimal_to_str(risk.total_margin))]))
    },
  }
}

# ---- GET /queue -----------------------------------------------------
fn get_queue(db :: conn.ConnDb, _c :: ctx.Ctx) -> [sql] resp.Response {
  match jobs.count_pending(db.handle, "orders") {
    Err(_) => resp.internal_error(),
    Ok(n) => resp.json(obj([kv_s("queue", "orders"), kv_i("pending", n)])),
  }
}

# ---- POST /queue/tick -----------------------------------------------
fn post_queue_tick(db :: conn.ConnDb, _c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  let dispatch := fn (_handler :: Str, _payload :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
    Done
  }
  match jobs.work_one(db.handle, "orders", dispatch) {
    Err(_) => resp.internal_error(),
    Ok(None) => resp.json(obj([kv_i("processed", 0)])),
    Ok(Some(job)) => resp.json(obj([kv_i("processed", 1), kv_s("handler", job.handler), kv_s("payload", job.payload)])),
  }
}

# ---- Router ---------------------------------------------------------
fn app(db :: conn.ConnDb, log :: trail_log.Log) -> router.Router {
  ((((((((((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "POST", "/orders", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      post_orders(db, log, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "POST", "/execution-reports", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      post_execution_reports(db, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "POST", "/cancel", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      post_cancel(db, log, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "POST", "/replace", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      post_replace(db, log, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/blotter", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      get_blotter(db, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/positions", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      get_positions(db, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/audit", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      get_audit(log, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/risk", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      get_risk(db, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/queue", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      get_queue(db, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.cors(["*"]))
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.logger())
  }
}

# ---- HTTP handler factory -------------------------------------------
#
# make_handler captures db and log and returns a (Request) -> Response
# closure typed against the stdlib Request/Response — the same shape
# router.dispatch emits and net.serve_fn consumes.  Structural
# equivalence bridges Request ↔ ctx.RawRequest and
# resp.Response ↔ Response at the call sites.
fn make_handler(db :: conn.ConnDb, log :: trail_log.Log) -> (Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Response {
  fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let res := router.dispatch(app(db, log), raw)
    { status: res.status, body: BodyStr(res.body), headers: res.headers }
  }
}

# ---- Entry point ----------------------------------------------------
fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc] Nil {
  match conn.connect_sqlite(":memory:") {
    Err(err) => io.print("DB open failed: " + dbe.message(err)),
    Ok(db) => match trail_log.open_memory() {
      Err(msg) => io.print("Trail open failed: " + msg),
      Ok(log) => match init_db(db) {
        Err(msg) => io.print("DB init failed: " + msg),
        Ok(_) => {
          let __lex_discard_4 := io.print("lex-oms :8080")
          net.serve_fn(8080, make_handler(db, log))
        },
      },
    },
  }
}

