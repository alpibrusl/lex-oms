# lex-oms — end-to-end demo
#
# Runs the full order lifecycle in memory:
#   ORD-001  AAPL buy 100  market → ACK → partial fill 50@174.91 → full fill 50@175.00
#   ORD-002  MSFT sell 50  market → ACK → full fill 50@418.51
#   ORD-003  TSLA buy 200  market → left as New (no fill)
#
# Then prints blotter, positions, and risk report.
#
# Run:
#   lex run --allow-effects concurrent,fs_read,fs_write,io,net,random,sql,time src/demo.lex main

import "std.io" as io

import "std.map" as map

import "std.int" as int

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as trail_log

import "./server" as srv

# ---- Context builders -----------------------------------------------
fn post_ctx(body :: Str) -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  { method: "POST", path: "/", query: "", body: body, path_params: map.new(), headers: map.from_list([("content-type", "application/json")]), state: map.new() }
}

fn get_ctx() -> { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] } {
  post_ctx("")
}

# ---- JSON builders --------------------------------------------------
fn order_json(cl_ord_id :: Str, symbol :: Str, side :: Str, qty :: Int, order_type :: Str) -> Str {
  "{\"cl_ord_id\":\"" + cl_ord_id + "\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"quantity\":" + int.to_str(qty) + ",\"order_type\":\"" + order_type + "\",\"price\":\"\",\"stop_price\":\"\",\"time_in_force\":\"\",\"account\":\"\",\"trader_id\":\"\",\"timestamp\":\"\"}"
}

# exec_type "0" = New (ExchangeAck)
fn ack_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, order_qty :: Int) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"0\",\"ord_status\":\"0\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(order_qty) + "\",\"cum_qty\":\"0\",\"leaves_qty\":\"" + int.to_str(order_qty) + "\",\"avg_px\":\"0\",\"last_px\":\"\",\"last_qty\":\"\",\"text\":\"\"}"
}

# exec_type "1" = Partial fill
fn partial_fill_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, order_qty :: Int, cum_qty :: Int, last_qty :: Int, last_px :: Str, avg_px :: Str) -> Str {
  let leaves := order_qty - cum_qty
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"1\",\"ord_status\":\"1\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(order_qty) + "\",\"cum_qty\":\"" + int.to_str(cum_qty) + "\",\"leaves_qty\":\"" + int.to_str(leaves) + "\",\"avg_px\":\"" + avg_px + "\",\"last_px\":\"" + last_px + "\",\"last_qty\":\"" + int.to_str(last_qty) + "\",\"text\":\"\"}"
}

# exec_type "2" = Fill (full)
fn fill_json(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, symbol :: Str, side :: Str, order_qty :: Int, last_qty :: Int, last_px :: Str, avg_px :: Str) -> Str {
  "{\"exec_id\":\"" + exec_id + "\",\"order_id\":\"" + order_id + "\",\"cl_ord_id\":\"" + cl_ord_id + "\",\"exec_type\":\"2\",\"ord_status\":\"2\",\"symbol\":\"" + symbol + "\",\"side\":\"" + side + "\",\"account\":\"\",\"order_qty\":\"" + int.to_str(order_qty) + "\",\"cum_qty\":\"" + int.to_str(order_qty) + "\",\"leaves_qty\":\"0\",\"avg_px\":\"" + avg_px + "\",\"last_px\":\"" + last_px + "\",\"last_qty\":\"" + int.to_str(last_qty) + "\",\"text\":\"\"}"
}

# ---- Demo sequence --------------------------------------------------
fn run_demo(db :: conn.ConnDb, log :: trail_log.Log) -> [sql, time, io, fs_write] Unit {
  let __d01 := srv.init_db(db)
  let __d02 := io.print("=== POST /orders ===")
  let r1 := srv.post_orders(db, log, post_ctx(order_json("ORD-001", "AAPL", "buy", 100, "market")))
  let __d03 := io.print("ORD-001  AAPL  buy  100  market  → " + int.to_str(r1.status))
  let r2 := srv.post_orders(db, log, post_ctx(order_json("ORD-002", "MSFT", "sell", 50, "market")))
  let __d04 := io.print("ORD-002  MSFT  sell  50  market  → " + int.to_str(r2.status))
  let r3 := srv.post_orders(db, log, post_ctx(order_json("ORD-003", "TSLA", "buy", 200, "market")))
  let __d05 := io.print("ORD-003  TSLA  buy  200  market  → " + int.to_str(r3.status))
  let __d06 := io.print("")
  let __d07 := io.print("=== POST /execution-reports ===")
  let e01 := srv.post_execution_reports(db, post_ctx(ack_json("E-001", "EXCH-001", "ORD-001", "AAPL", "buy", 100)))
  let __d08 := io.print("E-001  ACK  ORD-001           → " + int.to_str(e01.status) + "  " + e01.body)
  let e02 := srv.post_execution_reports(db, post_ctx(partial_fill_json("E-002", "EXCH-001", "ORD-001", "AAPL", "buy", 100, 50, 50, "174.91", "174.91")))
  let __d09 := io.print("E-002  partial  50@174.91     → " + int.to_str(e02.status) + "  " + e02.body)
  let e03 := srv.post_execution_reports(db, post_ctx(fill_json("E-003", "EXCH-001", "ORD-001", "AAPL", "buy", 100, 50, "175.00", "174.955")))
  let __d10 := io.print("E-003  fill     50@175.00     → " + int.to_str(e03.status) + "  " + e03.body)
  let e04 := srv.post_execution_reports(db, post_ctx(ack_json("E-004", "EXCH-002", "ORD-002", "MSFT", "sell", 50)))
  let __d11 := io.print("E-004  ACK  ORD-002           → " + int.to_str(e04.status) + "  " + e04.body)
  let e05 := srv.post_execution_reports(db, post_ctx(fill_json("E-005", "EXCH-002", "ORD-002", "MSFT", "sell", 50, 50, "418.51", "418.51")))
  let __d12 := io.print("E-005  fill    50@418.51      → " + int.to_str(e05.status) + "  " + e05.body)
  let e06 := srv.post_execution_reports(db, post_ctx(ack_json("E-006", "EXCH-003", "ORD-003", "TSLA", "buy", 200)))
  let __d13 := io.print("E-006  ACK  ORD-003           → " + int.to_str(e06.status) + "  " + e06.body)
  let __d14 := io.print("")
  let __d15 := io.print("=== GET /blotter ===")
  let blotter := srv.get_blotter(db, get_ctx())
  let __d16 := io.print(blotter.body)
  let __d17 := io.print("")
  let __d18 := io.print("=== GET /positions ===")
  let pos := srv.get_positions(db, get_ctx())
  let __d19 := io.print(pos.body)
  let __d20 := io.print("")
  let __d21 := io.print("=== GET /risk ===")
  let risk := srv.get_risk(db, get_ctx())
  io.print(risk.body)
}

# ---- Entry point ----------------------------------------------------
fn main() -> [sql, time, io, fs_write] Unit {
  match conn.connect_sqlite(":memory:") {
    Err(_) => io.print("error: could not open SQLite"),
    Ok(db) => match trail_log.open_memory() {
      Err(msg) => io.print("error: trail log: " + msg),
      Ok(log) => run_demo(db, log),
    },
  }
}

