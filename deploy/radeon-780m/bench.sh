#!/bin/bash
# Reproducible benchmark for this hardware.
#
# Two rules learned the hard way:
#  1. Run nothing else. A second llama-bench, a compile, or a heavy download
#     skews results by 10x and the numbers look plausible.
#  2. llama-bench does not validate output. It happily measures the throughput
#     of a corrupted model. Run check-output first.
set -euo pipefail

BIN="${BIN:-/root/llama.cpp/build-vk2/bin}"
MODEL="${1:?path to gguf}"
UB="${UB:-2048}"
KV="${KV:-q8_0}"

echo "== environment =="
# both pipelines are informational, and both can fail the script under pipefail:
# grep -m1 closes the pipe and SIGPIPEs vulkaninfo (exit 141), and a grep that
# matches nothing exits 1. Neither is a reason to abandon the benchmark.
vulkaninfo 2>/dev/null | grep -m1 driverInfo | sed 's/^\s*//' || true
"$BIN/llama-bench" --list-devices 2>&1 | grep -E 'ggml_vulkan: 0|Vulkan0' || true
echo

if pgrep -x llama-bench >/dev/null || pgrep -x aria2c >/dev/null; then
  echo "WARNING: other load detected, results will be wrong" >&2
fi

echo "== prompt processing =="
"$BIN/llama-bench" -m "$MODEL" -ngl 99 -t 8 -fa 1 -ub "$UB" \
  -ctk "$KV" -ctv "$KV" -p 512,4096,16384 -n 0 -r 3

echo "== generation at depth =="
"$BIN/llama-bench" -m "$MODEL" -ngl 99 -t 8 -fa 1 -ub "$UB" \
  -ctk "$KV" -ctv "$KV" -n 128 -p 0 -d 0,16384,32768 -r 3

cat <<'EOF'

Note: llama-bench does not exercise speculative decoding. MTP gains only appear
through llama-server with `spec-type = draft-mtp`. Measure real generation with:

  curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"fast","messages":[{"role":"user","content":"..."}],
         "max_tokens":400,"temperature":0}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['timings'])"
EOF
