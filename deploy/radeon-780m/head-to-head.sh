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
# probe and conc are cheap and gate the reading of every tier after them - wall
# time and turns are read against throughput - so they run first. reason follows
# because it is the tier that actually discriminates. Perplexity is not here: it
# runs against files rather than aliases, and step 7 is a tie-breaker that never
# promotes anything.
TIERS="${TIERS:-probe conc reason codeclaude vision codehard}"

mkdir -p "$OUT"
LEDGER="$OUT/ledger.txt"

note() { echo "$*" | tee -a "$LEDGER"; }

note "=== head-to-head $(date -Is) ==="
note "aliases: ${ALIASES[*]}"
note "tiers:   $TIERS"
note ""

# Swap models by RESTARTING THE UNIT, not by requesting the next alias.
#
# This wedged the GPU on 2026-09-08 and cost a host power cycle. Under
# models-max 1 a request for alias B while alias A is resident asks the router
# to load B before A's pool is released; two 27 GiB models plus first-request
# buffers do not fit in 76 GiB, so the load dies with
# "radv/amdgpu: Not enough memory for command submission" -> ErrorDeviceLost,
# the router retries, and the retry sticks in uninterruptible D state at
# drm_suballoc_new holding ~38 GB. SIGKILL does nothing to a D-state task and
# systemctl stop then hangs on it too.
#
# Restarting the unit tears the whole process tree down first, so the pool is
# provably empty before the next model is asked for. It costs one reload per
# alias, which is the price of not doing that again.
swap_to() {
  local alias="$1"
  systemctl restart llama-server
  # Wait for the router itself, then for the alias to answer. A request during
  # the load window is the thing that started all this, so ask once and be
  # patient rather than polling hard.
  sleep 10
  local deadline=$(( $(date +%s) + 900 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -s -m 600 "$HOST/completion" -H 'Content-Type: application/json' \
         -d "{\"model\":\"$alias\",\"prompt\":\"hello\",\"n_predict\":8,\"temperature\":0}" \
         2>/dev/null | grep -q '"content"'; then
      return 0
    fi
    sleep 20
  done
  echo "  FAILED to bring up $alias within 900 s" | tee -a "$LEDGER"
  return 1
}

for alias in "${ALIASES[@]}"; do
  note "########## $alias ##########"
  swap_to "$alias" || { note "  SKIPPED - would not load"; continue; }
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
