#!/bin/bash
# Run the EVAL-PLAYBOOK step-5 battery over several aliases in ONE session.
#
# Step 5's governing rule is that a candidate and its incumbent must be measured
# in the same session, under the same parallel/ctx/build - historical numbers do
# not transfer, and `fast`'s code-eval-hard moved 163 s -> 255 s across a
# parallel change with no model change at all. That means the control has to be
# re-run every time, which is exactly the step that gets skipped when the
# battery is driven by hand.
#
# Aliases are swept in the OUTER loop and tiers in the inner one, so each alias
# is loaded once per tier rather than once per alias-tier pair. With
# models-max 1 a swap costs a full reload, and interleaving tiers across aliases
# would pay it dozens of times.
#
# usage: ./head-to-head.sh <outdir> <alias>...
#   ./head-to-head.sh /root/models/h2h-ornith15 fast balanced ornith15-eval
#   TIERS='probe reason' ./head-to-head.sh /root/h2h fast balanced
set -euo pipefail

OUT="${1:?output directory}"; shift
[ $# -gt 0 ] || { echo "usage: $0 <outdir> <alias>..." >&2; exit 2; }
ALIASES=("$@")

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${HOST:-http://127.0.0.1:8080}"
# probe and conc are cheap and gate the reading of everything else, so they run
# first; perplexity is last because it is a tie-breaker and never promotes.
TIERS="${TIERS:-probe conc reason codeclaude vision codehard}"

mkdir -p "$OUT"
LEDGER="$OUT/ledger.txt"

note() { echo "$*" | tee -a "$LEDGER"; }

note "=== head-to-head $(date -Is) ==="
note "aliases: ${ALIASES[*]}"
note "tiers:   $TIERS"
note ""

# One warm request per alias before it is measured. The first request after a
# load costs ~9 GiB of lazily-allocated buffers and is not representative;
# measuring it as if it were is how a swap gets misread as a leak.
warm() {
  curl -s -m 300 "$HOST/completion" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"prompt\":\"hello\",\"n_predict\":8,\"temperature\":0}" \
    >/dev/null 2>&1 || true
}

for alias in "${ALIASES[@]}"; do
  note "########## $alias ##########"
  warm "$alias"
  for tier in $TIERS; do
    log="$OUT/$alias.$tier.log"
    start=$(date +%s)
    note "--- $tier ---"
    case "$tier" in
      probe)      timeout 1800 "$HERE/probe-server.sh" "$alias" 3      > "$log" 2>&1 || true ;;
      conc)       timeout 1800 python3 "$HERE/conc-probe.py" "$alias" 2 > "$log" 2>&1 || true ;;
      reason)     timeout 5400 "$HERE/reason-eval-hard.sh"  "$alias"   > "$log" 2>&1 || true ;;
      codeclaude) timeout 5400 "$HERE/code-eval-claude.sh"  "$alias"   > "$log" 2>&1 || true ;;
      codehard)   timeout 5400 "$HERE/code-eval-hard.sh"    "$alias"   > "$log" 2>&1 || true ;;
      vision)     timeout 3600 "$HERE/check-vision-agentic.sh" "$alias" > "$log" 2>&1 || true ;;
      *) note "  unknown tier $tier"; continue ;;
    esac
    el=$(( $(date +%s) - start ))
    # Keep the last few lines of every tier in one place. The per-tier logs hold
    # the detail; the ledger is what gets read at 3am.
    tail -6 "$log" | sed 's/^/  /' | tee -a "$LEDGER"
    note "  [${el}s]"
    note ""
  done
done

note "=== done $(date -Is) ==="
echo "ledger: $LEDGER"
