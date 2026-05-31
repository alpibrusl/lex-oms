# lex-oms

Agent-native HTTP order management system built on the Lex ecosystem.

## Live demo — end-to-end order lifecycle

Three orders submitted, filled by the exchange, positions calculated with exact WAAC arithmetic, risk report generated. All in a single `lex run`.

[![lex-oms demo](https://asciinema.org/a/qPEizlsZRlLNsFkp.svg)](https://asciinema.org/a/qPEizlsZRlLNsFkp)

```sh
bash examples/demo.sh
```

## What it shows

```
ORD-001  AAPL buy 100  market  → ACK → partial fill 50@174.91 → full fill 50@175.00
ORD-002  MSFT sell 50  market  → ACK → full fill 50@418.51
ORD-003  TSLA buy 200  market  → ACK (left open)

GET /blotter   → all orders, newest first
GET /positions → AAPL +100, MSFT -50, WAAC arithmetic
GET /risk      → delta, notional, margin per position
```

## Stack

| Library | Role |
|---|---|
| [lex-trade](https://github.com/alpibrusl/lex-trade) | Pre-trade validation pipeline — risk limits → FIX conformance → accept/reject |
| [lex-positions](https://github.com/alpibrusl/lex-positions) | WAAC position tracking + realized PnL |
| [lex-risk](https://github.com/alpibrusl/lex-risk) | Portfolio Greeks, notional, margin aggregation |
| [lex-trail](https://github.com/alpibrusl/lex-trail) | Content-addressed attestation log — every execution report is attested |
| [lex-money](https://github.com/alpibrusl/lex-money) | Exact decimal arithmetic — no floating-point money |

## Run

```sh
# HTTP server (port 8080)
lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time src/server.lex main

# Standalone lifecycle demo (no server)
lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time src/demo.lex main
```

## HTTP API

| Method | Path | Description |
|---|---|---|
| `POST` | `/orders` | Submit a new order |
| `POST` | `/execution-reports` | Apply an exchange execution report |
| `GET` | `/blotter` | All orders, newest first |
| `GET` | `/positions` | Current positions with WAAC and realized PnL |
| `GET` | `/risk` | Portfolio risk report |

## Install

```toml
# lex.toml
[dependencies]
"lex-oms" = { git = "https://github.com/alpibrusl/lex-oms" }
```
