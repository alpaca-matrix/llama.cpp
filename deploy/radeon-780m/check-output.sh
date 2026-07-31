#!/bin/bash
# Confirm a model produces coherent output before trusting any benchmark of it.
#
# A byte-damaged GGUF loads cleanly, reports correct metadata, and benchmarks at
# full speed while emitting gibberish. Run this on every new model.
set -euo pipefail

BIN="${BIN:-/root/llama.cpp/build-vk2/bin}"
MODEL="${1:?path to gguf}"
PORT="${PORT:-8099}"

"$BIN/llama-server" -m "$MODEL" -ngl 99 -fa on -c 8192 -ub 2048 \
  -ctk q8_0 -ctv q8_0 --jinja --host 127.0.0.1 --port "$PORT" >/tmp/chk.log 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

for _ in $(seq 1 300); do
  curl -s -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q ok && break
  kill -0 $pid 2>/dev/null || { echo "server died:"; tail -5 /tmp/chk.log; exit 1; }
  sleep 2
done

# Generous max_tokens: thinking models emit reasoning before content, so a small
# budget returns empty content and looks like a failure.
curl -s -m 600 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with exactly: The capital of France is Paris."}],"max_tokens":600,"temperature":0}' \
| python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'choices' not in d:
    print('FAIL:', str(d)[:200]); sys.exit(1)
m = d['choices'][0]['message']
c = (m.get('content') or '').strip()
r = m.get('reasoning_content') or ''
print('content  :', repr(c[:120]))
print('reasoning: %d chars' % len(r))
if 'Paris' in c:
    print('RESULT: OK')
else:
    print('RESULT: SUSPECT - model did not answer correctly; verify sha256')
    sys.exit(1)
"
