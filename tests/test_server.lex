# lex-oms — server tests
#
# Pure suite   (run_all)        : parse_side, parse_order_kind, JSON helpers
# Integration  (integration_main): DB round-trips — run manually:
#   lex run --allow-effects sql,time,fs_write tests/test_server.lex integration_main

import "std.map" as map

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as trail_log

import "../src/server" as srv

import "../src/marks" as marks

# ---- helpers --------------------------------------------------------
fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, v :: Result[Unit, Str]) -> Int {
    match v {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn make_ctx(body :: Str) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.new() }
}

fn empty_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  make_ctx("")
}

fn order_body(cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int, kind :: Str) -> Str {
  "{\"cl_ord_id\":\"" + cl_ord_id + "\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"quantity\":" + int.to_str(qty) + ",\"order_type\":\"" + kind + "\",\"price\":\"\",\"stop_price\":\"\",\"time_in_force\":\"\",\"account\":\"\",\"trader_id\":\"\",\"timestamp\":\"\"}"
}

fn exec_body(exec_id :: Str, cl_ord_id :: Str, exec_type :: Str, ord_status :: Str, symbol :: Str, side :: Str, last_px :: Str, cum_qty :: Str, last_qty :: Str) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"ORD001\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"" + exec_type + "\",\"ord_status\":\"" + ord_status + "\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"100\",\"cum_qty\":\"" + cum_qty + "\",\"leaves_qty\":\"" + int.to_str(100 - 50) + "\",\"avg_px\":\"" + last_px + "\",\"last_px\":\"" + last_px + "\",\"last_qty\":\"" + last_qty + "\",\"text\":\"\"}"
}

# ---- Pure: parse_side -----------------------------------------------
fn test_parse_side_buy() -> Result[Unit, Str] {
  match srv.parse_side("buy") {
    Ok(_) => Ok(()),
    Err(_) => Err("parse_side 'buy' should be Ok"),
  }
}

fn test_parse_side_sell() -> Result[Unit, Str] {
  match srv.parse_side("sell") {
    Ok(_) => Ok(()),
    Err(_) => Err("parse_side 'sell' should be Ok"),
  }
}

fn test_parse_side_invalid() -> Result[Unit, Str] {
  match srv.parse_side("long") {
    Ok(_) => Err("parse_side 'long' should be Err"),
    Err(_) => Ok(()),
  }
}

fn test_parse_side_empty() -> Result[Unit, Str] {
  match srv.parse_side("") {
    Ok(_) => Err("parse_side '' should be Err"),
    Err(_) => Ok(()),
  }
}

# ---- Pure: parse_order_kind -----------------------------------------
fn test_parse_market() -> Result[Unit, Str] {
  match srv.parse_order_kind("market", "", "") {
    Ok(_) => Ok(()),
    Err(_) => Err("market should be Ok"),
  }
}

fn test_parse_limit_with_price() -> Result[Unit, Str] {
  match srv.parse_order_kind("limit", "174.50", "") {
    Ok(_) => Ok(()),
    Err(_) => Err("limit+price should be Ok"),
  }
}

fn test_parse_limit_no_price() -> Result[Unit, Str] {
  match srv.parse_order_kind("limit", "", "") {
    Ok(_) => Err("limit without price should be Err"),
    Err(_) => Ok(()),
  }
}

fn test_parse_stop_with_price() -> Result[Unit, Str] {
  match srv.parse_order_kind("stop", "", "170.00") {
    Ok(_) => Ok(()),
    Err(_) => Err("stop+stop_price should be Ok"),
  }
}

fn test_parse_stop_no_price() -> Result[Unit, Str] {
  match srv.parse_order_kind("stop", "", "") {
    Ok(_) => Err("stop without stop_price should be Err"),
    Err(_) => Ok(()),
  }
}

fn test_parse_stop_limit_both() -> Result[Unit, Str] {
  match srv.parse_order_kind("stop_limit", "174.50", "170.00") {
    Ok(_) => Ok(()),
    Err(_) => Err("stop_limit+both should be Ok"),
  }
}

fn test_parse_stop_limit_no_stop() -> Result[Unit, Str] {
  match srv.parse_order_kind("stop_limit", "174.50", "") {
    Ok(_) => Err("stop_limit without stop_price should be Err"),
    Err(_) => Ok(()),
  }
}

fn test_parse_stop_limit_no_price() -> Result[Unit, Str] {
  match srv.parse_order_kind("stop_limit", "", "170.00") {
    Ok(_) => Err("stop_limit without price should be Err"),
    Err(_) => Ok(()),
  }
}

fn test_parse_unknown_kind() -> Result[Unit, Str] {
  match srv.parse_order_kind("market_on_close", "", "") {
    Ok(_) => Err("unknown kind should be Err"),
    Err(_) => Ok(()),
  }
}

# ---- Pure: or_str / or_int ------------------------------------------
fn test_or_str_some() -> Result[Unit, Str] {
  check("or_str non-empty", srv.or_str("hello", "default") == "hello")
}

fn test_or_str_none() -> Result[Unit, Str] {
  check("or_str empty", srv.or_str("", "default") == "default")
}

fn test_or_int_some() -> Result[Unit, Str] {
  check("or_int non-zero", srv.or_int(42, 0) == 42)
}

fn test_or_int_none() -> Result[Unit, Str] {
  check("or_int zero", srv.or_int(0, 0) == 0)
}

# ---- Pure: JSON helpers ---------------------------------------------
fn test_q() -> Result[Unit, Str] {
  check("q", srv.q("hello") == "\"hello\"")
}

fn test_kv_s() -> Result[Unit, Str] {
  check("kv_s", srv.kv_s("k", "v") == "\"k\":\"v\"")
}

fn test_kv_i() -> Result[Unit, Str] {
  check("kv_i", srv.kv_i("n", 7) == "\"n\":7")
}

fn test_obj_empty() -> Result[Unit, Str] {
  check("obj empty", srv.obj([]) == "{}")
}

fn test_obj_single() -> Result[Unit, Str] {
  check("obj single", srv.obj(["\"a\":1"]) == "{\"a\":1}")
}

fn test_arr_empty() -> Result[Unit, Str] {
  check("arr empty", srv.arr([]) == "[]")
}

fn test_arr_two() -> Result[Unit, Str] {
  check("arr two", srv.arr(["1", "2"]) == "[1,2]")
}

# ---- Pure suite and run_all (called by lex test) --------------------
fn suite_pure() -> List[Result[Unit, Str]] {
  [test_parse_side_buy(), test_parse_side_sell(), test_parse_side_invalid(), test_parse_side_empty(), test_parse_market(), test_parse_limit_with_price(), test_parse_limit_no_price(), test_parse_stop_with_price(), test_parse_stop_no_price(), test_parse_stop_limit_both(), test_parse_stop_limit_no_stop(), test_parse_stop_limit_no_price(), test_parse_unknown_kind(), test_or_str_some(), test_or_str_none(), test_or_int_some(), test_or_int_none(), test_q(), test_kv_s(), test_kv_i(), test_obj_empty(), test_obj_single(), test_arr_empty(), test_arr_two()]
}

fn run_all() -> Int {
  count_failures(suite_pure())
}

# ---- Integration tests (sql, time, fs_write) ------------------------
# Run manually:
#   lex run --allow-effects sql,time,fs_write tests/test_server.lex integration_main
fn intg_init_db(db :: conn.ConnDb) -> [sql, fs_write] Result[Unit, Str] {
  match srv.init_db(db) {
    Err(msg) => Err("init_db: " + msg),
    Ok(_) => Ok(()),
  }
}

fn intg_post_orders_valid(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let c := make_ctx(order_body("T001", "AAPL", "buy", 100, "market"))
  let res := srv.post_orders(db, log, c)
  check("post_orders valid → 201", res.status == 201)
}

fn intg_post_orders_bad_side(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let c := make_ctx(order_body("T002", "AAPL", "short", 100, "market"))
  let res := srv.post_orders(db, log, c)
  check("post_orders bad side → 400", res.status == 400)
}

fn intg_post_orders_limit_no_price(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let c := make_ctx(order_body("T003", "AAPL", "buy", 100, "limit"))
  let res := srv.post_orders(db, log, c)
  check("post_orders limit no price → 400", res.status == 400)
}

fn intg_post_orders_bad_json(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let c := make_ctx("{bad}")
  let res := srv.post_orders(db, log, c)
  check("post_orders bad JSON → 400", res.status == 400)
}

fn intg_blotter_after_order(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __lex_discard_1 := srv.post_orders(db, log, make_ctx(order_body("T010", "MSFT", "sell", 50, "market")))
  let res := srv.get_blotter(db, empty_ctx())
  if res.status == 200 {
    check("blotter contains T010", str.contains(res.body, "T010"))
  } else {
    Err("blotter status " + int.to_str(res.status))
  }
}

fn intg_exec_report_partial_fill(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __lex_discard_2 := srv.post_orders(db, log, make_ctx(order_body("T020", "AAPL", "buy", 100, "market")))
  let __ack := srv.post_execution_reports(db, make_ctx(exec_body("E000", "T020", "0", "0", "AAPL", "buy", "174.91", "0", "0")))
  let er := make_ctx(exec_body("E001", "T020", "1", "1", "AAPL", "buy", "174.91", "50", "50"))
  let res := srv.post_execution_reports(db, er)
  if res.status == 200 {
    check("exec report body contains cl_ord_id", str.contains(res.body, "T020"))
  } else {
    Err("post_execution_reports status " + int.to_str(res.status))
  }
}

fn intg_positions_after_fill(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __lex_discard_3 := srv.post_orders(db, log, make_ctx(order_body("T030", "AAPL", "buy", 100, "market")))
  let __ack := srv.post_execution_reports(db, make_ctx(exec_body("E000", "T030", "0", "0", "AAPL", "buy", "174.91", "0", "0")))
  let er := make_ctx(exec_body("E002", "T030", "2", "2", "AAPL", "buy", "174.91", "100", "100"))
  let __lex_discard_4 := srv.post_execution_reports(db, er)
  let res := srv.get_positions(db, empty_ctx())
  if res.status == 200 {
    check("positions contains AAPL", str.contains(res.body, "AAPL"))
  } else {
    Err("get_positions status " + int.to_str(res.status))
  }
}

# A simulation request carries sim_ts_ms in state; the OMS resolves the
# mark from the seeded marks table at that timestamp.
fn sim_ctx(body :: Str, ts :: Int) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json"), ("sim_ts_ms", int.to_str(ts))]), state: map.from_list([("sim_ts_ms", int.to_str(ts))]) }
}

# With a real mark seeded, a position-notional breach (600k AAPL @ $100 =
# $60M > the $50M cap) is rejected — the gate is live, not inert.
fn intg_post_orders_notional_breach(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __m := marks.set(db, "AAPL", 5000, "100.00")
  let res := srv.post_orders(db, log, sim_ctx(order_body("TNB", "AAPL", "buy", 600000, "market"), 5000))
  check("notional breach with live mark → 422", res.status == 422)
}

# Same mark, modest size ($3M notional) is accepted — proves the breach
# above is the notional gate firing, not a blanket rejection.
fn intg_post_orders_within_notional(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __m := marks.set(db, "AAPL", 5000, "100.00")
  let res := srv.post_orders(db, log, sim_ctx(order_body("TWN", "AAPL", "buy", 30000, "market"), 5000))
  check("within notional with live mark → 201", res.status == 201)
}

# In simulation, an order whose symbol has no seeded mark is rejected
# rather than silently risk-checked against $0.
fn intg_post_orders_missing_mark(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let res := srv.post_orders(db, log, sim_ctx(order_body("TMM", "ZZZZ", "buy", 1, "market"), 7777))
  check("missing mark in sim → 422", res.status == 422)
}

fn intg_audit_returns_200(log :: trail_log.Log) -> [sql] Result[Unit, Str] {
  let res := srv.get_audit(log, empty_ctx())
  check("get_audit → 200", res.status == 200)
}

fn cancel_body(cl_ord_id :: Str, orig_cl_ord_id :: Str, symbol :: Str, side :: Str) -> Str {
  "{\"cl_ord_id\":\"" + cl_ord_id + "\",\"orig_cl_ord_id\":\"" + orig_cl_ord_id + "\",\"account\":\"\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"order_qty\":100,\"timestamp\":\"\"}"
}

fn replace_body(orig_cl_ord_id :: Str, new_cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int) -> Str {
  "{\"orig_cl_ord_id\":\"" + orig_cl_ord_id + "\",\"new_cl_ord_id\":\"" + new_cl_ord_id + "\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"quantity\":" + int.to_str(qty) + ",\"order_type\":\"market\",\"price\":\"\",\"stop_price\":\"\",\"time_in_force\":\"\",\"account\":\"\",\"trader_id\":\"\",\"timestamp\":\"\"}"
}

# Cancel: order must be in New state to be cancelable; first ack it via exec report.
fn intg_cancel_transitions_to_pending_cancel(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __o := srv.post_orders(db, log, make_ctx(order_body("C001", "AAPL", "buy", 10, "market")))
  let ack := make_ctx(exec_body("EA001", "C001", "0", "0", "AAPL", "buy", "174.91", "0", "0"))
  let __a := srv.post_execution_reports(db, ack)
  let c := make_ctx(cancel_body("CXL001", "C001", "AAPL", "buy"))
  let res := srv.post_cancel(db, log, c)
  if res.status == 200 {
    let blotter := srv.get_blotter(db, empty_ctx())
    check("cancel: C001 transitions to PendingCancel", str.contains(blotter.body, "PendingCancel"))
  } else {
    Err("post_cancel status " + int.to_str(res.status) + ": " + res.body)
  }
}

# Replace: orig transitions to PendingCancel, new order appears as PendingNew.
fn intg_replace_manages_both_states(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __o := srv.post_orders(db, log, make_ctx(order_body("R001", "MSFT", "buy", 10, "market")))
  let ack := make_ctx(exec_body("ER001", "R001", "0", "0", "MSFT", "buy", "420.00", "0", "0"))
  let __a := srv.post_execution_reports(db, ack)
  let c := make_ctx(replace_body("R001", "R002", "MSFT", "buy", 20))
  let res := srv.post_replace(db, log, c)
  if res.status == 200 {
    let blotter := srv.get_blotter(db, empty_ctx())
    if str.contains(blotter.body, "PendingCancel") {
      check("replace: R002 appears as PendingNew", str.contains(blotter.body, "PendingNew"))
    } else {
      Err("replace: R001 not transitioned to PendingCancel")
    }
  } else {
    Err("post_replace status " + int.to_str(res.status) + ": " + res.body)
  }
}

fn intg_queue_starts_empty(db :: conn.ConnDb) -> [sql] Result[Unit, Str] {
  let res := srv.get_queue(db, empty_ctx())
  check("get_queue → 200", res.status == 200)
}

fn intg_order_enqueues_job(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] Result[Unit, Str] {
  let __o := srv.post_orders(db, log, make_ctx(order_body("Q001", "AAPL", "buy", 5, "market")))
  let res := srv.get_queue(db, empty_ctx())
  check("accepted order enqueues a job", str.contains(res.body, "pending"))
}

fn suite_integration(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, fs_write] List[Result[Unit, Str]] {
  [intg_init_db(db), intg_post_orders_valid(db, log), intg_post_orders_bad_side(db, log), intg_post_orders_limit_no_price(db, log), intg_post_orders_bad_json(db, log), intg_blotter_after_order(db, log), intg_exec_report_partial_fill(db, log), intg_positions_after_fill(db, log), intg_post_orders_notional_breach(db, log), intg_post_orders_within_notional(db, log), intg_post_orders_missing_mark(db, log), intg_audit_returns_200(log), intg_cancel_transitions_to_pending_cancel(db, log), intg_replace_manages_both_states(db, log), intg_queue_starts_empty(db), intg_order_enqueues_job(db, log)]
}

fn integration_main() -> [sql, time, fs_write] Int {
  match conn.connect_sqlite(":memory:") {
    Err(_) => 1,
    Ok(db) => match trail_log.open_memory() {
      Err(_) => 1,
      Ok(log) => count_failures(suite_integration(db, log)),
    },
  }
}

