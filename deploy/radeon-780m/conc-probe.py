#!/usr/bin/env python3
"""Measure concurrent serving throughput through the production router.

probe-server.sh answers "how fast is one request". This answers "how fast is
this box when two clients are talking to it", which is the number that decides
draft length here - per-stream tg and aggregate tg move in opposite directions
as slots are added, and only aggregate is honest.

EVAL-PLAYBOOK.md step 5 has cited this tool since it was written; it existed
only as an inline script and was lost. Recreated 2026-08-15.

usage: python3 conc-probe.py <alias> [conc] [rounds] [n_predict]
  python3 conc-probe.py fast 2
  python3 conc-probe.py balanced 2 3 256

Each stream gets its OWN window of a real source file, and the windows move
every round. That is deliberate: the probe-server stall on `coder` (README,
2026-08-01) was triggered by the same prompt repeated with cache_prompt off and
ignore_eos on against more than one slot, and distinct windows avoid that shape
while keeping prompt processing representative.
"""

import json
import os
import statistics
import sys
import threading
import time
import urllib.request

alias = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
conc = int(sys.argv[2]) if len(sys.argv) > 2 else 2
rounds = int(sys.argv[3]) if len(sys.argv) > 3 else 3
npredict = int(sys.argv[4]) if len(sys.argv) > 4 else 256

host = os.environ.get("HOST", "http://127.0.0.1:8080")
prompt_file = os.environ.get("PROMPT_FILE", "/root/llama.cpp/src/llama-context.cpp")
window = int(os.environ.get("WINDOW", 9000))

src = open(prompt_file).read()
if len(src) < window * (conc + rounds):
    src = src * (1 + (window * (conc + rounds)) // max(len(src), 1))

try:
    busy = json.load(urllib.request.urlopen(f"{host}/slots", timeout=10))
    if any(s.get("is_processing") for s in busy):
        print("WARNING: server is busy, results will be wrong", file=sys.stderr)
except Exception as exc:
    # In router mode /slots answers 400, so this check cannot run. It is
    # advisory - never let it take the measurement down. probe-server.sh has
    # the same check and pipes it through `grep -c`, which turns the 400 into a
    # 0 and silently reports "not busy"; that guard has been inoperative here
    # for as long as the box has run in router mode.
    print(f"note: busy check unavailable ({exc}) - verify idleness yourself",
          file=sys.stderr)


def one(stream, rnd, out):
    # a distinct window per (stream, round) - see the module docstring
    start = (rnd * conc + stream) * window
    body = json.dumps({
        "model": alias, "prompt": src[start:start + window], "n_predict": npredict,
        "cache_prompt": False, "ignore_eos": True, "temperature": 0,
    }).encode()
    req = urllib.request.Request(f"{host}/completion", data=body,
                                 headers={"Content-Type": "application/json"})
    out[stream] = json.load(urllib.request.urlopen(req, timeout=900))["timings"]


per_stream, aggregate, prompt_ps, accept = [], [], [], []
for rnd in range(rounds):
    out = [None] * conc
    threads = [threading.Thread(target=one, args=(i, rnd, out)) for i in range(conc)]
    t0 = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.time() - t0

    tgs = [t["predicted_per_second"] for t in out]
    pps = [t["prompt_per_second"] for t in out]
    total_predicted = sum(t["predicted_n"] for t in out)
    agg = total_predicted / wall

    per_stream += tgs
    prompt_ps += pps
    aggregate.append(agg)
    for t in out:
        if t.get("draft_n"):
            accept.append(t["draft_n_accepted"] / t["draft_n"])

    print(f"  round {rnd + 1}: per-stream tg {' '.join(f'{v:5.2f}' for v in tgs)}"
          f"  aggregate {agg:6.2f} t/s  pp {statistics.median(pps):6.1f}"
          f"  wall {wall:5.1f}s")

print(f"\n{alias} at conc={conc}:")
print(f"  per-stream tg median {statistics.median(per_stream):.2f} t/s "
      f"(range {min(per_stream):.2f}-{max(per_stream):.2f})")
print(f"  aggregate tg  median {statistics.median(aggregate):.2f} t/s "
      f"(range {min(aggregate):.2f}-{max(aggregate):.2f})")
print(f"  pp            median {statistics.median(prompt_ps):.1f} t/s")
if accept:
    print(f"  draft acceptance median {statistics.median(accept):.3f} "
          f"(range {min(accept):.3f}-{max(accept):.3f})")
else:
    print("  draft acceptance: none reported (no speculation)")
