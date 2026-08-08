#!/bin/bash
# Measure one speculative-decoding configuration on a standalone llama-server.
#
# probe-server.sh measures whatever the production router is already serving.
# This launches its own server on a spare port instead, so a drafter file or a
# draft length can be swapped without editing router.ini - nothing here touches
# /etc/llama or production. The server's per-request speculative overrides are
# still #if 0'd upstream, so every configuration needs its own load.
#
# usage: ./spec-sweep.sh <model.gguf> <n_max> [drafter.gguf] [p_min]
#   ./spec-sweep.sh /root/models/EVAL-Laguna-S-2.1-UD-IQ3_S.gguf 0
#   ./spec-sweep.sh /root/models/EVAL-Laguna-S-2.1-UD-IQ3_S.gguf 2 \
#       /root/models/EVAL-Laguna-S-2.1-DFlash-Q8_0.gguf 0
#
# SPEC_TYPE selects the implementation (default draft-dflash, which needs a
# drafter file). Types that live inside the target file take no drafter:
#   SPEC_TYPE=draft-mtp ./spec-sweep.sh /root/models/EVAL-KAT-...-MTP.gguf 2 "" 0.3
# It is a comma-separated list, chained in order, so an n-gram pass can back a
# model-based one: SPEC_TYPE=draft-mtp,ngram-mod. NGRAM_ARGS passes the
# --spec-ngram-mod-* knobs through unsplit.
#
# Reports served tg, prompt processing, and draft acceptance. Stop the
# production unit first - a 45 GiB model plus whatever the router holds will
# not both fit in the pool.
set -euo pipefail

BIN="${BIN:-/root/llama.cpp/build-vk2/bin}"
MODEL="${1:?path to target gguf}"
NMAX="${2:?draft length, 0 for no speculation}"
DRAFTER="${3:-}"
PMIN="${4:-0}"
SPEC_TYPE="${SPEC_TYPE:-draft-dflash}"
NGRAM_ARGS="${NGRAM_ARGS:-}"

PORT="${PORT:-8081}"
CTX="${CTX:-32768}"
NPREDICT="${NPREDICT:-300}"
LOG="${LOG:-/tmp/spec-sweep-$PORT.log}"

if curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "ERROR: something is already serving on port $PORT" >&2
  exit 1
fi

args=(
  --model "$MODEL" --alias sweep --port "$PORT" --host 127.0.0.1
  --n-gpu-layers 99 --flash-attn on --ubatch-size 2048 --batch-size 2048
  --threads 8 --cache-type-k q8_0 --cache-type-v q8_0
  --ctx-size "$CTX" --parallel 1 --jinja --reasoning-format deepseek
)
if [ "$NMAX" != "0" ]; then
  args+=(
    --spec-type "$SPEC_TYPE"
    --spec-draft-n-max "$NMAX" --spec-draft-p-min "$PMIN"
    --cache-type-k-draft q8_0 --cache-type-v-draft q8_0
  )
  if [ -n "$DRAFTER" ]; then
    args+=(--model-draft "$DRAFTER")
  fi
  if [ -n "$NGRAM_ARGS" ]; then
    # shellcheck disable=SC2206
    args+=($NGRAM_ARGS)
  fi
fi

echo "== config: type=$SPEC_TYPE n_max=$NMAX p_min=$PMIN drafter=${DRAFTER:-none}"
: > "$LOG"
"$BIN/llama-server" "${args[@]}" >>"$LOG" 2>&1 &
SERVER_PID=$!
# Always reap the child. A server left holding the pool is how this box gets
# wedged, and an un-reaped one silently poisons the next configuration.
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true' EXIT

# NEVER send a request before the load finishes. Doing so is what forced a hard
# power cycle on 2026-08-07: a request during load made the router kill a child
# mid-GPU-allocation, and the teardown deadlocked in uninterruptible D state.
echo -n "   loading"
for _ in $(seq 1 240); do
  if grep -q 'llama_server: listening' "$LOG" 2>/dev/null; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo; echo "ERROR: server died during load, tail of $LOG:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  echo -n "."
  sleep 2
done
if ! grep -q 'llama_server: listening' "$LOG"; then
  echo; echo "ERROR: server did not come up within 480s" >&2
  exit 1
fi
echo " up"

PORT="$PORT" NPREDICT="$NPREDICT" python3 <<'PYEOF'
import json, os, statistics, urllib.request

port, npredict = os.environ["PORT"], int(os.environ["NPREDICT"])
host = f"http://127.0.0.1:{port}"

# realistic agentic-coding shapes: the drafter's win depends on how predictable
# the continuation is, and prose-only prompts flatter it
prompts = [
    "Write a Python function that parses a unified diff and returns, for each file, the list of changed line ranges. Handle renames and binary files.",
    "Here is a bug report: a Rust program using tokio::select! occasionally drops a message. Explain the likely cause and show a corrected version.",
    "Implement a thread-safe LRU cache in C++17 with a fixed capacity. Provide the header and a short usage example.",
    "Refactor this shell script to be POSIX-compliant and add error handling:\n\nfor f in *.txt; do\n  cat $f | grep foo >> out\ndone",
]

tg, pp, dn, da = [], [], 0, 0
for i, prompt in enumerate(prompts):
    body = json.dumps({
        "prompt": prompt, "n_predict": npredict,
        "cache_prompt": False, "ignore_eos": True, "temperature": 0,
    }).encode()
    req = urllib.request.Request(f"{host}/completion", data=body,
                                 headers={"Content-Type": "application/json"})
    t = json.load(urllib.request.urlopen(req, timeout=900))["timings"]
    tg.append(t["predicted_per_second"])
    pp.append(t["prompt_per_second"])
    dn += t.get("draft_n", 0)
    da += t.get("draft_n_accepted", 0)
    print(f"   prompt {i+1}: tg {tg[-1]:5.2f} t/s  pp {pp[-1]:6.1f} t/s")

acc = f"{da/dn:.3f} ({da}/{dn})" if dn else "n/a"
print(f"   RESULT tg median {statistics.median(tg):5.2f} t/s  "
      f"pp median {statistics.median(pp):6.1f} t/s  acceptance {acc}")
PYEOF
