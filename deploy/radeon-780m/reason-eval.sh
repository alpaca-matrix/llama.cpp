#!/bin/bash
# Compare reasoning models on problems with checkable answers.
#
# Throughput tells you nothing about whether a model in the `deep` slot is
# actually better at the analysis you keep it around for. These are short
# problems with one unambiguous answer each, weighted toward traps that a model
# gets wrong by answering from the first plausible pattern rather than working
# it through - which is exactly what a thinking budget is supposed to buy.
#
# Small N, so treat the score as a smoke test, not a benchmark. Reports wall
# time too: a model that is right but three times slower is a real trade.
#
# usage: ./reason-eval.sh <alias> [effort]
#   ./reason-eval.sh deep high
set -euo pipefail

ALIAS="${1:?model alias}"
EFFORT="${2:-}"
HOST="${HOST:-http://127.0.0.1:8080}"

ALIAS="$ALIAS" EFFORT="$EFFORT" HOST="$HOST" python3 <<'PYEOF'
import json, os, re, time, urllib.request

alias, host, effort = os.environ["ALIAS"], os.environ["HOST"], os.environ["EFFORT"]

# (prompt, regex the final answer must match, label)
TESTS = [
    ("A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. "
     "How much does the ball cost? Reply with just the amount.",
     r"0?\.05|5\s*cents?", "bat-and-ball"),

    ("If it takes 5 machines 5 minutes to make 5 widgets, how long would 100 machines "
     "take to make 100 widgets? Reply with just the number of minutes.",
     r"\b5\b", "widgets"),

    ("A lily pad patch doubles in size every day and covers the whole lake on day 48. "
     "On which day does it cover half the lake? Reply with just the day number.",
     r"\b47\b", "lily-pads"),

    ("I have 3 boxes. Box A holds twice what Box B holds. Box C holds 4 fewer than Box A. "
     "Together they hold 31 items. How many items are in Box B? Reply with just the number.",
     r"\b7\b", "boxes"),

    ("A race car driver overtakes the car in second place near the finish. "
     "What position is the driver in now? Reply with just the position.",
     r"\bsecond\b|\b2nd\b", "overtake"),

    ("Sally has 3 brothers. Each brother has 2 sisters. How many sisters does Sally have? "
     "Reply with just the number.",
     r"\b1\b|\bone\b", "sallys-sisters"),

    ("A mutex is locked by thread A, which then blocks waiting on a condition variable "
     "that only thread B signals. Thread B must acquire that same mutex before signalling. "
     "Name this failure in one or two words.",
     r"deadlock", "deadlock"),

    ("You append to a Python list while iterating over it with a for loop. "
     "Does the loop terminate? Answer yes or no, then one short clause why.",
     r"\bno\b", "list-mutation"),
]

def ask(prompt):
    payload = {
        "model": alias, "temperature": 0, "max_tokens": 8000,
        "messages": [{"role": "user", "content": prompt}],
    }
    if effort:
        payload["chat_template_kwargs"] = {"reasoning_effort": effort}
    req = urllib.request.Request(host + "/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=1200))
    m = r["choices"][0]["message"]
    return (m.get("content") or ""), len(m.get("reasoning_content") or "")

label = f"{alias}" + (f" (effort={effort})" if effort else "")
print(f"== {label} ==")
score, total_s, total_think = 0, 0.0, 0
for prompt, pattern, name in TESTS:
    t0 = time.time()
    try:
        out, think = ask(prompt)
    except Exception as e:
        print(f"  {name:16s} ERROR {e}")
        continue
    dt = time.time() - t0
    total_s += dt
    total_think += think
    # check the tail: thinking models restate the problem early on
    ok = re.search(pattern, out[-400:] or out, re.I) is not None
    score += ok
    flat = " ".join(out.split())[-70:]
    print(f"  {name:16s} {'PASS' if ok else 'FAIL'}  {dt:5.1f}s  think={think:5d}ch  ...{flat}")

print(f"\n{label}: {score}/{len(TESTS)} correct, {total_s:.0f}s total, "
      f"{total_think} chars of reasoning")
PYEOF
