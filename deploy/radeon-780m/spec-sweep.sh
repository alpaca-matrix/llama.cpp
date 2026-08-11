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
# CONC sets how many requests are in flight at once (default 1), and PARALLEL
# sets the server's slot count (default: same as CONC). Both are needed to
# measure anything about concurrency, because the quantity that decides the
# Vulkan MUL_MAT_ID path is the WHOLE batch - every generating slot's sampled
# token plus its draft - not one slot's draft length:
#
#   CONC=3 SPEC_TYPE=draft-mtp ./spec-sweep.sh /root/models/...MTP.gguf 3 "" 0.3
#   GGML_VK_MUL_MAT_VEC_ID_MAX_COLS=16 CONC=3 ... (env passes to the child)
#
# Reports per-stream tg, aggregate tg, prompt processing, and draft acceptance.
# Aggregate is the number that matters at CONC > 1: per-stream tg falls as slots
# are added even when total throughput rises. Stop the production unit first - a
# 45 GiB model plus whatever the router holds will not both fit in the pool.
#
# CAUTION at CONC > 1: `cache_prompt: false` + `ignore_eos: true` against
# multiple slots with speculation is close to the request shape that made
# probe-server.sh stall for minutes at a time (see README). The per-request
# timeout below is the backstop; if a sweep hangs, that is the suspect.
set -euo pipefail

BIN="${BIN:-/root/llama.cpp/build-vk2/bin}"
MODEL="${1:?path to target gguf}"
NMAX="${2:?draft length, 0 for no speculation}"
DRAFTER="${3:-}"
PMIN="${4:-0}"
SPEC_TYPE="${SPEC_TYPE:-draft-dflash}"
NGRAM_ARGS="${NGRAM_ARGS:-}"
CONC="${CONC:-1}"
PARALLEL="${PARALLEL:-$CONC}"

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
  --ctx-size "$CTX" --parallel "$PARALLEL" --jinja --reasoning-format deepseek
)
if [ "$PARALLEL" != "1" ]; then
  # match production: slots share the ctx pool instead of dividing it
  args+=(--kv-unified)
fi
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
echo "==         conc=$CONC parallel=$PARALLEL max_cols=${GGML_VK_MUL_MAT_VEC_ID_MAX_COLS:-8 (default)}"
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

PORT="$PORT" NPREDICT="$NPREDICT" CONC="$CONC" python3 <<'PYEOF'
import json, os, statistics, threading, time, urllib.request

port, npredict = os.environ["PORT"], int(os.environ["NPREDICT"])
conc = int(os.environ["CONC"])
host = f"http://127.0.0.1:{port}"

# realistic agentic-coding shapes: the drafter's win depends on how predictable
# the continuation is, and prose-only prompts flatter it
prompts = [
    "Write a Python function that parses a unified diff and returns, for each file, the list of changed line ranges. Handle renames and binary files.",
    "Here is a bug report: a Rust program using tokio::select! occasionally drops a message. Explain the likely cause and show a corrected version.",
    "Implement a thread-safe LRU cache in C++17 with a fixed capacity. Provide the header and a short usage example.",
    "Refactor this shell script to be POSIX-compliant and add error handling:\n\nfor f in *.txt; do\n  cat $f | grep foo >> out\ndone",
]

def run(prompt):
    body = json.dumps({
        "prompt": prompt, "n_predict": npredict,
        "cache_prompt": False, "ignore_eos": True, "temperature": 0,
    }).encode()
    req = urllib.request.Request(f"{host}/completion", data=body,
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=900))["timings"]

# At conc == 1 this is the original serial pass, one prompt after another. Above
# that the prompts are issued in overlapping waves of `conc`, each stream on its
# own prompt, so the server sees the batch shape production would see. Prompts
# are drawn cyclically so EVERY wave is full width - a short final wave would
# quietly measure less concurrency than it claims to.
tg, pp, dn, da, predicted, wall = [], [], 0, 0, 0, 0.0
n_waves = -(-len(prompts) // conc)
for w in range(n_waves):
    wave = [prompts[(w * conc + i) % len(prompts)] for i in range(conc)]
    results = [None] * len(wave)

    def worker(idx, prompt):
        results[idx] = run(prompt)

    threads = [threading.Thread(target=worker, args=(i, p)) for i, p in enumerate(wave)]
    started = time.monotonic()
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    wall += time.monotonic() - started

    for i, t in enumerate(results):
        tg.append(t["predicted_per_second"])
        pp.append(t["prompt_per_second"])
        dn += t.get("draft_n", 0)
        da += t.get("draft_n_accepted", 0)
        predicted += t["predicted_n"]
        print(f"   wave {w+1} stream {i+1}: tg {tg[-1]:5.2f} t/s  pp {pp[-1]:6.1f} t/s")

acc = f"{da/dn:.3f} ({da}/{dn})" if dn else "n/a"
print(f"   RESULT tg median {statistics.median(tg):5.2f} t/s  "
      f"pp median {statistics.median(pp):6.1f} t/s  acceptance {acc}")
# Aggregate counts every stream's tokens against the wall clock they shared, so
# it is the only figure comparable across conc values. Per-stream tg is expected
# to FALL as slots are added; aggregate rising is what makes that a good trade.
print(f"   AGGREGATE {predicted/wall:6.2f} t/s over {wall:.1f}s "
      f"({predicted} tokens, conc {conc})")
PYEOF
