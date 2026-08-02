#!/bin/bash
# Hard tier: separate a `deep`-slot model from `fast`.
#
# `reason-eval.sh` saturates - both `fast` and `deep` score 8/8 - so it cannot
# justify keeping a 117B model that costs 60 GiB and a 31 s swap, and it cannot
# score a candidate that is genuinely smarter than the incumbent. These
# problems are chosen so a strong 35B is expected to miss several: each needs a
# multi-step derivation or a named subtlety that the common pattern gets wrong,
# and each still has one unambiguous checkable answer.
#
# The wrong answer is usually the confident one. Most items have an `anti`
# pattern naming the specific plausible-but-wrong response, so a reply that
# lands on it is scored FAIL even if the right token appears somewhere in the
# tail.
#
# Truncation is reported separately from a wrong answer. Both models rejected
# on this box failed by exhausting the token budget without concluding, which
# a plain FAIL hides - TRUNC is that failure, and it counts against the model
# harder than a miss.
#
# Small N, so this is a discriminator, not a benchmark. Report the score, the
# reasoning volume and the wall time together: on this slot a model that thinks
# in half the tokens is worth more than one that generates 20% faster.
#
# usage: ./reason-eval-hard.sh <alias> [effort]
#   ./reason-eval-hard.sh deep high
#   MAX_TOKENS=16000 ONLY='recursion-tree|reservoir' ./reason-eval-hard.sh fast
#
# ONLY filters by label regex and MAX_TOKENS raises the budget - together they
# re-test the items a model truncated, to separate "cannot answer" from "needs
# more room". A rerun under either is not comparable to a full-tier score.
set -euo pipefail

ALIAS="${1:?model alias}"
EFFORT="${2:-}"
HOST="${HOST:-http://127.0.0.1:8080}"
MAX_TOKENS="${MAX_TOKENS:-8000}"
ONLY="${ONLY:-}"

ALIAS="$ALIAS" EFFORT="$EFFORT" HOST="$HOST" MAX_TOKENS="$MAX_TOKENS" ONLY="$ONLY" python3 <<'PYEOF'
import json, os, re, time, urllib.request

alias, host, effort = os.environ["ALIAS"], os.environ["HOST"], os.environ["EFFORT"]
max_tokens = int(os.environ["MAX_TOKENS"])
only = os.environ.get("ONLY") or ""

# (prompt, must-match regex, must-NOT-match regex or None, label)
TESTS = [
    # 2^53 is representable; 2^53+1 is the first that is not. Answering with
    # 2^53 itself is the standard near-miss.
    ("What is the smallest positive integer that cannot be represented exactly as an "
     "IEEE-754 binary64 (double precision) value? Reply with just the number, in digits.",
     r"9007199254740993", r"9007199254740992\s*$", "float64-gap"),

    # Master theorem does not apply: the recursion tree sums n/(log n - i),
    # a harmonic series, giving n log log n. n log n is the pattern-match answer.
    ("Solve the recurrence T(n) = 2*T(n/2) + n/log(n) for its asymptotic growth. "
     "Reply with just the asymptotic form, e.g. Theta(n^2).",
     r"log\s*\(?\s*log|lg\s*lg", None, "recursion-tree"),

    # StoreLoad is the one reordering x86-TSO permits. "x86 is strongly
    # ordered, so no" is the confident wrong answer.
    ("On x86-TSO, x and y are both initially 0. CPU0 executes: store x=1; then load y into r1. "
     "CPU1 executes: store y=1; then load x into r2. All accesses are plain aligned loads and "
     "stores with no fences. Is the final outcome r1=0 and r2=0 permitted by the architecture? "
     "Reply with exactly one word: YES or NO.",
     r"\byes\b", r"\bno\b", "store-buffer"),

    # Lamport clocks are one-directional: a -> b implies L(a) < L(b), never the
    # converse. Vector clocks are what would license the inference.
    ("Events a and b occur on different processes in a system using Lamport logical clocks. "
     "You observe that L(a) < L(b). Can you conclude that a happened-before b? "
     "Reply with exactly one word: YES or NO.",
     r"\bno\b", r"\byes\b", "lamport-converse"),

    # The comprehension owns `i`, but the lambdas close over the cell, which
    # ends at 2. Answering 0 assumes capture by value.
    ("In Python 3: fs = [lambda: i for i in range(3)]. What does fs[0]() return? "
     "Reply with just the number.",
     r"\b2\b", r"\b0\b", "late-binding"),

    # The election restriction (leader completeness) forbids it. "Yes, a stale
    # replica can win an election" is the plausible miss.
    ("In Raft, can a server be elected leader for a new term while its log is missing an entry "
     "that a leader of an earlier term had already committed? "
     "Reply with exactly one word: YES or NO.",
     r"\bno\b", r"\byes\b", "raft-completeness"),

    # Multi-step deduction with one irrelevant constraint. blue=1 forces
    # yellow=2; red/green must be 4/5 or white ends up adjacent to green.
    ("Five houses stand in a row, numbered 1 to 5 from left to right, each a different color: "
     "blue, yellow, red, green, white. The blue house is at one end of the row. The yellow house "
     "is immediately to the right of the blue house. The red house is immediately to the left of "
     "the green house. The white house is not adjacent to the green house. The person in house 3 "
     "owns a cat. What color is house 5? Reply with just the color.",
     r"\bgreen\b", r"\bwhite\b", "house-order"),

    # Each transaction's snapshot satisfies the invariant; the pair violates it.
    # Not a phantom read, which is the usual mislabel.
    ("Under snapshot isolation, two concurrent transactions each read the same set of rows and "
     "each then updates a different row in that set, in a way that preserves a constraint over "
     "the set within its own snapshot. After both commit, the constraint is violated. "
     "Name this anomaly in one or two words.",
     r"write.?skew", None, "write-skew"),

    # Not lost wakeups: the POSIX/C++ contract permits a wait to return with
    # no signal at all, so the predicate must be rechecked in a loop.
    ("A condition variable is waited on with `if (!ready) cond.wait(lock);` rather than a while "
     "loop. Setting aside lost wakeups and multiple waiters, name the phenomenon permitted by the "
     "condition variable contract that makes the `if` form unsafe even with a single waiter. "
     "Name it in one or two words.",
     r"spurious", None, "spurious-wakeup"),

    # One pass, O(k) memory, uniform over an unknown-length stream.
    ("You must select k items uniformly at random from a stream of unknown length n, in a single "
     "pass, using O(k) memory. Name the standard algorithm in one or two words.",
     r"reservoir", None, "reservoir"),
]

def ask(prompt):
    payload = {
        "model": alias, "temperature": 0, "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }
    if effort:
        payload["chat_template_kwargs"] = {"reasoning_effort": effort}
    req = urllib.request.Request(host + "/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=1800))
    c = r["choices"][0]
    m = c["message"]
    return (m.get("content") or ""), len(m.get("reasoning_content") or ""), c.get("finish_reason")

tests = [t for t in TESTS if not only or re.search(only, t[3])]

label = f"{alias}" + (f" (effort={effort})" if effort else "")
suffix = f" [{len(tests)}/{len(TESTS)} items, max_tokens={max_tokens}]" if only or max_tokens != 8000 else ""
print(f"== {label} hard tier{suffix} ==")
score, trunc, total_s, total_think = 0, 0, 0.0, 0
for prompt, pattern, anti, name in tests:
    t0 = time.time()
    try:
        out, think, finish = ask(prompt)
    except Exception as e:
        print(f"  {name:18s} ERROR {e}")
        continue
    dt = time.time() - t0
    total_s += dt
    total_think += think
    # check the tail: thinking models restate the problem early on
    tail = out[-400:] or out
    ok = re.search(pattern, tail, re.I) is not None
    if ok and anti and re.search(anti, tail, re.I):
        ok = False
    score += ok
    if finish == "length":
        trunc += 1
        verdict = "TRUNC"
    else:
        verdict = "PASS" if ok else "FAIL"
    flat = " ".join(out.split())[-70:]
    print(f"  {name:18s} {verdict:5s} {dt:6.1f}s  think={think:6d}ch  ...{flat}")

print(f"\n{label}: {score}/{len(tests)} correct, {trunc} truncated, {total_s:.0f}s total, "
      f"{total_think} chars of reasoning")
if trunc:
    print("NOTE: truncated answers mean the budget ran out before a conclusion. "
          "That is the failure mode that rejected Ornith-3.6 and MiniMax-M2.1 - "
          "weigh it above a wrong answer, and do not tune a model that does it.")
PYEOF
