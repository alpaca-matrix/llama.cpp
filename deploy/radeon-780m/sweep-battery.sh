#!/bin/bash
# Drive spec-sweep.sh across a grid of draft lengths and concurrencies.
#
# EVAL-PLAYBOOK step 3 asks for n_max 0..4 at both CONC=1 and CONC=2, per model,
# with PROMPT_FILE set. That is 10 loads per model and it has been retyped by
# hand every time, which is how one session ended up with cells taken at
# different p_min values and no way to tell afterwards.
#
# Each cell gets its OWN log path, because a cell that hangs is a result and the
# post-mortem is worthless once the next cell overwrites it (Qwen3-Coder-Next,
# 7 of 21 cells, 2026-08-17).
#
# Stop the production unit first: a candidate plus whatever the router holds
# will not both fit in the pool.
#
# usage: ./sweep-battery.sh <model.gguf> <tag> [n_max_list] [conc_list]
#   ./sweep-battery.sh /root/models/CAND.gguf cand15 "0 1 2 3 4" "1 2"
set -euo pipefail

MODEL="${1:?path to target gguf}"
TAG="${2:?short tag for log paths}"
NMAX_LIST="${3:-0 1 2 3 4}"
CONC_LIST="${4:-1 2}"

PMIN="${PMIN:-0.3}"
OUTDIR="${OUTDIR:-/root/models/sweep-$TAG}"
HERE="$(cd "$(dirname "$0")" && pwd)"

export SPEC_TYPE="${SPEC_TYPE:-draft-mtp}"
export PROMPT_FILE="${PROMPT_FILE:-/root/llama.cpp/src/llama-context.cpp}"
export GGML_VK_MUL_MAT_VEC_ID_MAX_COLS="${GGML_VK_MUL_MAT_VEC_ID_MAX_COLS:-12}"
export PARALLEL="${PARALLEL:-3}"

mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"
: > "$SUMMARY"

echo "model    $MODEL"        | tee -a "$SUMMARY"
echo "spec     $SPEC_TYPE p_min=$PMIN parallel=$PARALLEL cols=$GGML_VK_MUL_MAT_VEC_ID_MAX_COLS" | tee -a "$SUMMARY"
echo "prompts  $PROMPT_FILE"  | tee -a "$SUMMARY"
echo                          | tee -a "$SUMMARY"

for conc in $CONC_LIST; do
  for nmax in $NMAX_LIST; do
    cell="$OUTDIR/c${conc}-n${nmax}"
    echo "=== CONC=$conc n_max=$nmax ===" | tee -a "$SUMMARY"
    # p_min is meaningless at n_max 0 and the sweep prints it either way; pass 0
    # there so the log cannot be misread as a speculated cell later.
    p="$PMIN"; [ "$nmax" = "0" ] && p=0
    if CONC="$conc" LOG="$cell.server.log" \
       timeout 1200 "$HERE/spec-sweep.sh" "$MODEL" "$nmax" '' "$p" \
       > "$cell.out" 2>&1; then
      grep -E "tg |aggregate|prompt|acceptance|per-stream" "$cell.out" | tee -a "$SUMMARY" || true
    else
      rc=$?
      # 124 is timeout(1). A cell that never returns is a result: a config that
      # wedges is disqualified whatever else it measures.
      if [ "$rc" = "124" ]; then
        echo "  HUNG - no result in 1200 s (DISQUALIFYING)" | tee -a "$SUMMARY"
      else
        echo "  FAILED rc=$rc - see $cell.out" | tee -a "$SUMMARY"
        tail -5 "$cell.out" | sed 's/^/  /' | tee -a "$SUMMARY"
      fi
    fi
    echo | tee -a "$SUMMARY"
    # let the pool drain fully between loads
    sleep 5
  done
done

echo "summary: $SUMMARY"
