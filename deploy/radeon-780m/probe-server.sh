#!/bin/bash
# Measure real serving throughput through llama-server.
#
# bench.sh uses llama-bench, which cannot exercise speculative decoding. MTP and
# DFlash gains only appear through the server, so this is the tool that answers
# "how fast is an actual request". Reports a median because single runs on this
# box vary by a few percent.
#
# usage: ./probe-server.sh <alias> [n_samples] [n_predict]
#   ./probe-server.sh coder 6
set -euo pipefail

ALIAS="${1:?model alias, e.g. fast|coder|deep}"
SAMPLES="${2:-3}"
NPREDICT="${3:-256}"
HOST="${HOST:-http://127.0.0.1:8080}"
# a real source file, so prompt processing sees representative tokens
PROMPT_FILE="${PROMPT_FILE:-/root/llama.cpp/src/llama-context.cpp}"

if [ "$(curl -s "$HOST/slots" | grep -c '"is_processing":true' || true)" != "0" ]; then
  echo "WARNING: server is busy, results will be wrong" >&2
fi

ALIAS="$ALIAS" SAMPLES="$SAMPLES" NPREDICT="$NPREDICT" HOST="$HOST" \
PROMPT_FILE="$PROMPT_FILE" python3 <<'PYEOF'
import json, os, statistics, urllib.request

alias, host = os.environ["ALIAS"], os.environ["HOST"]
samples, npredict = int(os.environ["SAMPLES"]), int(os.environ["NPREDICT"])
prompt = open(os.environ["PROMPT_FILE"]).read()[:9000]

pp, tg = [], []
for i in range(samples):
    body = json.dumps({
        "model": alias, "prompt": prompt, "n_predict": npredict,
        # cache_prompt off so every sample measures a cold prefill;
        # ignore_eos so tg is measured over the full n_predict
        "cache_prompt": False, "ignore_eos": True, "temperature": 0,
    }).encode()
    req = urllib.request.Request(f"{host}/completion", data=body,
                                 headers={"Content-Type": "application/json"})
    t = json.load(urllib.request.urlopen(req, timeout=600))["timings"]
    pp.append(t["prompt_per_second"])
    tg.append(t["predicted_per_second"])
    print(f"  sample {i+1}: pp {pp[-1]:6.1f} t/s ({t['prompt_n']} tok)  "
          f"tg {tg[-1]:5.2f} t/s ({t['predicted_n']} tok)")

print(f"\n{alias}: pp median {statistics.median(pp):.1f} t/s "
      f"(range {min(pp):.1f}-{max(pp):.1f})")
print(f"{alias}: tg median {statistics.median(tg):.2f} t/s "
      f"(range {min(tg):.2f}-{max(tg):.2f})")
PYEOF

cat <<'EOF'

If tg is several times lower than expected, check for silent CPU fallback before
anything else - see "Watch for silent CPU fallback" in README.md.
EOF
