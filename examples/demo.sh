#!/usr/bin/env bash
# Theatrical demo — lex-oms: agent-native OMS, end-to-end order lifecycle
# Usage:   bash examples/demo.sh
#          asciinema rec examples/demo.cast -c "bash examples/demo.sh" --overwrite
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
LEX="${LEX:-lex}"

BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'
GREEN=$'\033[32m'; BLUE=$'\033[34m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

slow() { echo "$@" | pv -qL 55; }
pause() { sleep "${1:-1.2}"; }
hr()  { printf '%s' "$DIM"; printf '─%.0s' {1..72}; printf '%s\n' "$RESET"; }
hdr() { echo; hr; echo "  ${BOLD}${CYAN}$*${RESET}"; hr; echo; }
cmd() { echo "${BOLD}${BLUE}\$${RESET}  $*"; pause 0.6; }

# Post-process lex-oms demo output: io.print in lex 0.9.7 omits newlines.
# Split section-by-section so ORD- inside JSON is not split as an order line.
fmt() {
  python3 -c "
import sys, re, json
raw = sys.stdin.read().replace('null', '').strip()
parts = re.split(r'(=== [^=]+ ===)', raw)
section = ''
for part in parts:
    part = part.strip()
    if not part:
        continue
    if re.match(r'^=== ', part):
        print()
        print('  ' + part)
        print()
        section = part
    elif any(k in section for k in ('blotter', 'positions', 'risk')):
        try:
            obj = json.loads(part)
            print(json.dumps(obj, indent=2))
        except Exception:
            print('  ' + part)
    elif 'orders' in section and 'execution' not in section:
        for line in re.split(r'(?=ORD-)', part):
            if line.strip():
                print('  ' + line.strip())
    elif 'execution' in section:
        for line in re.split(r'(?=E-\d{3})', part):
            if line.strip():
                print('  ' + line.strip())
    else:
        print('  ' + part)
"
}

clear
echo
echo "  ${BOLD}lex-oms${RESET}  ·  Agent-native order management, end to end"
echo "  ${DIM}lex-trade · lex-positions · lex-risk · lex-trail · lex-money${RESET}"
echo
sleep 2

# ── Stack ────────────────────────────────────────────────────────────────
hdr "Stack — five libraries, one effect graph"
slow "  Orders are typed records. Risk limits are checked before serialization."
slow "  Every execution report is an attestation in the tamper-evident trail."
slow "  Positions use exact decimal arithmetic — no floating-point money."
echo
pause 1.2

# ── Type check ───────────────────────────────────────────────────────────
hdr "Type check — all effects declared before a byte runs"
cmd "lex check src/demo.lex"
pause 0.4
"$LEX" check src/demo.lex
echo "${GREEN}${BOLD}✓  ok${RESET}"
echo
pause 1.2

# ── Run the demo ─────────────────────────────────────────────────────────
hdr "End to end — submit orders, apply fills, query blotter / positions / risk"
slow "  Three orders submitted: AAPL buy 100, MSFT sell 50, TSLA buy 200."
slow "  Exchange sends back ACKs and fills. Positions and risk update atomically."
echo
pause 0.8

cmd "lex run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time \\"
echo "        src/demo.lex main"
pause 0.5
"$LEX" run --allow-effects concurrent,crypto,fs_read,fs_write,io,net,random,sql,time \
  src/demo.lex main 2>&1 | fmt
echo
pause 1.5

# ── Summary ─────────────────────────────────────────────────────────────
hr
echo
echo "  ${BOLD}${GREEN}DONE${RESET}"
echo
echo "  Three orders submitted and filled."
echo "  Positions calculated with exact WAAC arithmetic."
echo "  Risk report: delta, notional, margin — all typed, all checked."
echo "  Every step attested in the append-only trail log."
echo
hr
echo
