# lex-oms — reference marks store
#
# Pre-trade risk checks (margin, position-notional) need a mark price per
# symbol. In live operation that comes from a market-data feed; in the
# in-process simulation (lex-oms-agent / Lex Arena) the driver seeds the
# scripted price for each (symbol, step) here, keyed by the same sim
# timestamp the OMS already threads through ctx.state as `sim_ts_ms`.
#
# Keeping marks in a table (rather than reaching into a static mock) lets
# the gates evaluate against the actual price the order fills at, so a
# $50M position-notional or margin breach is rejected for real.

import "std.sql" as sql
import "std.list" as list

import "lex-orm/src/connection" as conn
import "lex-orm/src/query" as q
import "lex-orm/src/error" as dbe

import "lex-money/src/decimal" as d
import "lex-positions/src/position" as pos

fn init(db :: conn.ConnDb) -> [sql] Result[Unit, dbe.DbErr] {
  let ddl := "CREATE TABLE IF NOT EXISTS oms_marks (symbol TEXT NOT NULL, ts_ms INTEGER NOT NULL, price TEXT NOT NULL, PRIMARY KEY (symbol, ts_ms))"
  match sql.exec(db.handle, ddl, []) {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(_) => Ok(()),
  }
}

# Seed/replace the mark for a symbol at a sim timestamp.
fn set(db :: conn.ConnDb, symbol :: Str, ts_ms :: Int, price_str :: Str) -> [sql] Result[Unit, dbe.DbErr] {
  let sq := q.for_dialect({ sql: "INSERT INTO oms_marks (symbol, ts_ms, price) VALUES (?, ?, ?) ON CONFLICT (symbol, ts_ms) DO UPDATE SET price = EXCLUDED.price", params: [PStr(symbol), PInt(ts_ms), PStr(price_str)] }, db.dialect)
  match sql.exec(db.handle, sq.sql, sq.params) {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(_) => Ok(()),
  }
}

# The mark for a symbol at a sim timestamp, if one was seeded. None means
# "no mark on record" — the caller decides whether that's a hard reject
# (simulation) or a fall-through to another source (HTTP).
fn get(db :: conn.ConnDb, symbol :: Str, ts_ms :: Int) -> [sql] Option[d.Decimal] {
  let sq := q.for_dialect({ sql: "SELECT price FROM oms_marks WHERE symbol = ? AND ts_ms = ?", params: [PStr(symbol), PInt(ts_ms)] }, db.dialect)
  let raw :: Result[List[{ price :: Str }], SqlError] := sql.query(db.handle, sq.sql, sq.params)
  match raw {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => pos.parse_price(row.price),
    },
  }
}
