# lex-oms

[![CI](https://github.com/alpibrusl/lex-oms/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/lex-oms/actions/workflows/ci.yml)

**Part of the [Lex](https://lexlang.org) project** — Finance · [Manifesto](https://lexlang.org/manifesto) · [All packages](https://lexlang.org)

HTTP order management system for Lex. The wiring layer that connects every piece of the stack.

An order enters via `POST /orders`, passes through the full pre-trade gate (margin → position check → FIX conformance), is enqueued for dispatch, and updates positions on fill. Every decision is logged to a hash-chained audit trail. The position book, risk snapshot, and audit trail are readable via HTTP at any time.

---

## Live demo

```sh
# Standalone lifecycle demo (no server needed)
lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time \
        src/demo.lex main
```

Three orders submitted, filled by the exchange, positions calculated with exact WAAC arithmetic, risk snapshot generated.

---

## HTTP API

| Method | Path | Description |
|---|---|---|
| `POST` | `/orders` | Pre-trade gate → enqueue → `201 Accepted` or `422` with rejection reasons |
| `POST` | `/execution-reports` | Apply exchange fill; update order state + position book |
| `POST` | `/cancel` | Validate cancel request; transition order to `PendingCancel` |
| `POST` | `/replace` | Cancel/replace; enforces FIX immutability (Side, Symbol immutable) |
| `GET` | `/blotter` | All orders, newest first |
| `GET` | `/positions` | Current positions with WAAC cost and realized PnL |
| `GET` | `/risk` | Portfolio Greeks, notional, and margin per position |
| `GET` | `/audit` | lex-trail events, newest first |
| `GET` | `/queue` | Pending dispatch count |
| `POST` | `/queue/tick` | Process one queued order — dispatches to exchange gateway |

**Note:** `/queue/tick` currently has no exchange gateway implementation. Orders are enqueued but the dispatch leg sends nothing. A FIX 4.4 gateway is tracked in [issue #2](https://github.com/alpibrusl/lex-oms/issues/2).

---

## Run as HTTP server

```sh
lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,llm,net,proc,random,sql,time \
        src/server.lex main
# Listening on :8080
```

---

## In the stack

```
lex-money · lex-fix · lex-positions · lex-risk · lex-trade · lex-marketdata
    ↓
lex-oms  ←  HTTP order management system
    ↓
lex-oms-agent
```

---

## Stack

| Package | Role |
|---|---|
| [lex-trade](https://github.com/alpibrusl/lex-trade) | Pre-trade validation: risk limits → FIX conformance → accept/reject |
| [lex-positions](https://github.com/alpibrusl/lex-positions) | WAAC position tracking + realized PnL |
| [lex-risk](https://github.com/alpibrusl/lex-risk) | Portfolio Greeks, notional, margin |
| [lex-trail](https://github.com/alpibrusl/lex-trail) | Content-addressed audit log — every execution attested |
| [lex-money](https://github.com/alpibrusl/lex-money) | Exact decimal arithmetic |

---

## Install

```toml
[dependencies]
"lex-oms" = { git = "https://github.com/alpibrusl/lex-oms" }
```
