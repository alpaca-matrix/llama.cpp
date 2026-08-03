#!/bin/bash
# Agentic coding eval: score a model the way opencode actually uses it.
#
# Why this exists. Every model in `candidates.md` was ranked on published
# SWE-bench Verified figures, and that metric is a poor proxy for this slot:
#
#   - SWE-bench scores are scaffold-dependent (Agentless vs OpenHands vs
#     vendor-custom, usually unlabelled), so a model tuned for a pipelined
#     localize-then-patch harness scores well without being good in a
#     free-form tool loop, which is the only thing opencode does.
#   - It does not score latency or token economy at all. A model emitting 30k
#     reasoning chars before every tool call scores the same as one emitting
#     500. In an interactive client one of those is unusable, and "init takes
#     too long" was the complaint that started this whole search.
#   - It does not test edit-format compliance. opencode lives on well-formed
#     tool calls and exactly-matching search/replace edits; SWE-bench harnesses
#     retry or constrain the format, so malformed-call rates never surface.
#
# And this repo already has the counterexample: both models ever rejected on
# this box failed by not terminating, which no published benchmark predicted.
#
# So this measures the loop directly. Four small tasks, real multi-turn tool
# calling against an in-memory repo, scored on whether the tests actually pass
# at the end - verified by this script, never by asking the model.
#
# The four metrics that matter, none of which SWE-bench reports:
#   turns    - how many round trips to get there. Latency is turns x per-turn
#              time, so a model that takes 12 turns to do a 4-turn job is slow
#              even at high t/s.
#   edmiss   - edit_file calls whose old_str did not match, or matched more
#              than once. This is the opencode-critical failure: the model
#              believes it edited a file and it did not.
#   botch    - malformed tool calls: unknown tool, unparseable arguments,
#              missing required field.
#   think    - reasoning chars. Paid once per turn, so it compounds across a
#              session in a way a single-shot benchmark never shows.
#
# The `no-op` task is a trap and the most useful item here. The code is already
# correct; the only right move is to run the tests, see them pass, and stop.
# A model that "fixes" working code scores MEDDLE - it passes the tests but
# would be destructive in a real repo, and no benchmark scores this.
#
# Calibration, measured 2026-08-03:
#
#   fast   4/4  93s  19 turns  0 edmiss  0 botch  4342c think
#   coder  2/4 162s  36 turns  0 edmiss  0 botch     0c think
#          (STALL on add-feature at the 24-turn budget; no-op errored - the
#          alias failed to load, see below, so it was never scored)
#
# Read that as two findings. First, the tier already discriminates: `coder`
# took 1.9x the turns and 1.7x the wall time for half the score, and stalled
# outright on the one task requiring a new function - consistent with it being
# the alias opencode was slow on. Second, and more important, **it saturates
# on `fast` at 4/4**, exactly as `reason-eval.sh` saturates at 8/8. So it can
# justify the incumbent and catch a regression, but it cannot rank a candidate
# claiming to be better. A model scoring 4/4 here is not thereby better than
# `fast` - it has only failed to be worse. Ranking above the incumbent needs a
# harder tier, the way `reason-eval-hard.sh` was built for the deep slot.
#
# Also measured 2026-08-03: `coder` fails to load on this box - repeatable
# `radv/amdgpu: Not enough memory for command submission` into
# `vk::DeviceLostError` during load, with system RAM nearly free. That is an
# infrastructure fault, unrelated to this eval, and it is why one row errored.
#
# usage: ./code-eval.sh <alias>
#   ./code-eval.sh fast
#   ONLY='no-op|cross-file' MAX_TURNS=40 ./code-eval.sh coder
#
# ONLY filters by label regex; MAX_TURNS raises the per-task turn budget
# (default 24) and MAX_TOKENS the per-turn generation budget (default 2500 -
# thinking models return empty content on a small budget and look broken).
# A filtered or re-budgeted run is not comparable to a full-tier score.
set -euo pipefail

ALIAS="${1:?model alias}"
HOST="${HOST:-http://127.0.0.1:8080}"
MAX_TURNS="${MAX_TURNS:-24}"
MAX_TOKENS="${MAX_TOKENS:-2500}"
ONLY="${ONLY:-}"

ALIAS="$ALIAS" HOST="$HOST" MAX_TURNS="$MAX_TURNS" MAX_TOKENS="$MAX_TOKENS" \
ONLY="$ONLY" python3 <<'PYEOF'
import json, os, re, shutil, subprocess, sys, tempfile, time
import urllib.error, urllib.request

alias, host = os.environ["ALIAS"], os.environ["HOST"]
max_turns = int(os.environ["MAX_TURNS"])
max_tokens = int(os.environ["MAX_TOKENS"])
only = os.environ.get("ONLY") or ""

# --- tasks -----------------------------------------------------------------
# Each: label, prompt, files, trap. `trap` means the correct action is to
# change nothing. Every task's test_main.py exits non-zero on failure, and this
# script runs it itself at the end - the model's own claim is never trusted.

TASKS = [
    dict(
        label="off-by-one",
        trap=False,
        prompt="total_stock() in inventory.py is dropping items. The tests in "
               "test_main.py show the expected behaviour. Find the bug and fix it.",
        files={
            "inventory.py":
                'def total_stock(items):\n'
                '    """Return the total quantity across all items."""\n'
                '    total = 0\n'
                '    for i in range(len(items) - 1):\n'
                '        total += items[i]["qty"]\n'
                '    return total\n',
            "test_main.py":
                'from inventory import total_stock\n\n'
                'assert total_stock([{"qty": 2}, {"qty": 3}, {"qty": 5}]) == 10\n'
                'assert total_stock([]) == 0\n'
                'assert total_stock([{"qty": 7}]) == 7\n'
                'print("OK")\n',
        },
    ),
    dict(
        # Needs two files read before the fix is visible. A model that patches
        # client.py to `attempt < 5` passes the tests but hardcodes the value
        # again - the tests assert MAX_RETRIES separately to make that stick.
        label="cross-file",
        trap=False,
        prompt="should_retry() in client.py ignores the retry ceiling configured "
               "elsewhere in the project. Fix it so the ceiling is read from "
               "configuration rather than hardcoded. test_main.py has the expected "
               "behaviour.",
        files={
            "config.py":
                '# Tuning knobs for the retry layer.\n'
                'MAX_RETRIES = 5\n'
                'BACKOFF_BASE_MS = 250\n',
            "client.py":
                'from config import MAX_RETRIES\n\n\n'
                'def should_retry(attempt):\n'
                '    """Return True while attempt is below the configured retry ceiling."""\n'
                '    return attempt < 3\n',
            "test_main.py":
                'from client import should_retry\n'
                'from config import MAX_RETRIES\n\n'
                'assert MAX_RETRIES == 5\n'
                'assert should_retry(0) is True\n'
                'assert should_retry(4) is True\n'
                'assert should_retry(5) is False\n'
                'print("OK")\n',
        },
    ),
    dict(
        # Writing a new function rather than patching one - exercises write_file
        # and whether the model reads the tests to infer the contract.
        label="add-feature",
        trap=False,
        prompt="test_main.py imports a slugify() function from textutil.py that does "
               "not exist yet. Implement it so the tests pass. Do not change the tests.",
        files={
            "textutil.py":
                'def strip_accents(s):\n'
                '    """Not implemented yet - out of scope."""\n'
                '    raise NotImplementedError\n\n\n'
                'def collapse_spaces(s):\n'
                '    return " ".join(s.split())\n',
            "test_main.py":
                'from textutil import slugify\n\n'
                'assert slugify("Hello World") == "hello-world"\n'
                'assert slugify("  Multiple   Spaces  ") == "multiple-spaces"\n'
                'assert slugify("Punctuation! Here?") == "punctuation-here"\n'
                'assert slugify("already-slugged") == "already-slugged"\n'
                'print("OK")\n',
        },
    ),
    dict(
        # The trap. clamp() is correct. The bug report is wrong. Editing
        # anything here is the failure, even if the tests still pass after.
        label="no-op",
        trap=True,
        prompt="A user reports that clamp() in math_utils.py misbehaves at the "
               "boundaries. Investigate. If it is genuinely broken, fix it. If it is "
               "not broken, leave it alone and say so.",
        files={
            "math_utils.py":
                'def clamp(value, lo, hi):\n'
                '    """Constrain value to the inclusive range [lo, hi]."""\n'
                '    return max(lo, min(value, hi))\n',
            "test_main.py":
                'from math_utils import clamp\n\n'
                'assert clamp(5, 0, 10) == 5\n'
                'assert clamp(-1, 0, 10) == 0\n'
                'assert clamp(11, 0, 10) == 10\n'
                'assert clamp(0, 0, 10) == 0\n'
                'assert clamp(10, 0, 10) == 10\n'
                'print("OK")\n',
        },
    ),
]

TOOLS = [
    {"type": "function", "function": {
        "name": "list_files", "description": "List the files in the project.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "read_file", "description": "Read a file's full contents.",
        "parameters": {"type": "object",
                       "properties": {"path": {"type": "string"}},
                       "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "edit_file",
        "description": "Replace an exact substring in a file. old_str must appear "
                       "exactly once, matching whitespace and indentation exactly.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"},
            "old_str": {"type": "string"},
            "new_str": {"type": "string"}},
            "required": ["path", "old_str", "new_str"]}}},
    {"type": "function", "function": {
        "name": "write_file",
        "description": "Create a file or overwrite one entirely.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["path", "content"]}}},
    {"type": "function", "function": {
        "name": "run_tests", "description": "Run test_main.py and return its output.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "submit",
        "description": "Call when the task is done. Ends the session.",
        "parameters": {"type": "object",
                       "properties": {"summary": {"type": "string"}},
                       "required": ["summary"]}}},
]

SYSTEM = ("You are a coding agent working in a small Python project. Use the "
          "provided tools to inspect and modify files. Verify your work by "
          "running the tests. Call submit when you are done. Be efficient: do "
          "not re-read files you have already read.")


def run_tests(files):
    """Materialise the in-memory repo and run its tests. Authoritative."""
    d = tempfile.mkdtemp(prefix="code-eval-")
    try:
        for name, body in files.items():
            with open(os.path.join(d, name), "w") as fh:
                fh.write(body)
        p = subprocess.run([sys.executable, "test_main.py"], cwd=d,
                           capture_output=True, text=True, timeout=30)
        out = (p.stdout + p.stderr).strip()
        return p.returncode == 0, out[-600:]
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT after 30s"
    finally:
        shutil.rmtree(d, ignore_errors=True)


def post(payload, timeout=1800):
    req = urllib.request.Request(host + "/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        # A bare "HTTP Error 500" hides whether the model misbehaved or the
        # server simply failed to swap it in - which are opposite conclusions.
        # An alias that fails to load is an infrastructure fault, not evidence
        # about agentic ability, so surface the body and let the reader tell.
        try:
            body = json.loads(e.read().decode())
            detail = body.get("error", {}).get("message") or str(body)[:200]
        except Exception:
            detail = "(no readable body)"
        raise RuntimeError(f"HTTP {e.code}: {detail}") from None


class Episode:
    def __init__(self, task):
        self.files = dict(task["files"])
        self.turns = self.edmiss = self.botch = self.think = self.mutations = 0
        self.ran_tests = False

    def dispatch(self, name, args):
        """Execute one tool call. Returns the string handed back to the model."""
        if name == "list_files":
            return "\n".join(sorted(self.files))

        if name == "read_file":
            path = args.get("path")
            if not path:
                self.botch += 1
                return "ERROR: missing required field 'path'"
            if path not in self.files:
                return f"ERROR: no such file: {path}"
            return self.files[path]

        if name == "edit_file":
            path, old, new = args.get("path"), args.get("old_str"), args.get("new_str")
            if path is None or old is None or new is None:
                self.botch += 1
                return "ERROR: edit_file needs path, old_str and new_str"
            if path not in self.files:
                self.edmiss += 1
                return f"ERROR: no such file: {path}"
            n = self.files[path].count(old)
            if n == 0:
                self.edmiss += 1
                return ("ERROR: old_str not found in " + path +
                        ". It must match the file exactly, including indentation.")
            if n > 1:
                self.edmiss += 1
                return f"ERROR: old_str matches {n} times in {path}; it must be unique."
            self.files[path] = self.files[path].replace(old, new, 1)
            self.mutations += 1
            return f"OK: edited {path}"

        if name == "write_file":
            path, content = args.get("path"), args.get("content")
            if path is None or content is None:
                self.botch += 1
                return "ERROR: write_file needs path and content"
            self.files[path] = content
            self.mutations += 1
            return f"OK: wrote {path}"

        if name == "run_tests":
            self.ran_tests = True
            ok, out = run_tests(self.files)
            return ("PASS\n" if ok else "FAIL\n") + out

        self.botch += 1
        return f"ERROR: unknown tool {name!r}"


def play(task):
    """Drive one task to completion or exhaustion. Returns an Episode."""
    ep = Episode(task)
    msgs = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": task["prompt"]}]

    while ep.turns < max_turns:
        ep.turns += 1
        r = post({"model": alias, "messages": msgs, "tools": TOOLS,
                  "temperature": 0, "max_tokens": max_tokens})
        choice = r["choices"][0]
        msg = choice["message"]
        ep.think += len(msg.get("reasoning_content") or "")

        calls = msg.get("tool_calls") or []
        if not calls:
            break  # model answered in prose; episode is over either way

        msgs.append({"role": "assistant",
                     "content": msg.get("content") or "",
                     "tool_calls": calls})

        done = False
        for call in calls:
            fn = call["function"]
            raw = fn.get("arguments") or "{}"
            if isinstance(raw, dict):
                args = raw                      # some builds pre-parse
            else:
                try:
                    args = json.loads(raw)
                except json.JSONDecodeError:
                    ep.botch += 1
                    args, result = {}, "ERROR: arguments were not valid JSON"
                    msgs.append({"role": "tool", "tool_call_id": call.get("id", ""),
                                 "content": result})
                    continue
            if fn["name"] == "submit":
                done = True
                msgs.append({"role": "tool", "tool_call_id": call.get("id", ""),
                             "content": "OK"})
                continue
            msgs.append({"role": "tool", "tool_call_id": call.get("id", ""),
                         "content": ep.dispatch(fn["name"], args)})
        if done:
            break

    return ep


tasks = [t for t in TASKS if not only or re.search(only, t["label"])]
suffix = ""
if only or max_turns != 24 or max_tokens != 2500:
    suffix = f" [{len(tasks)}/{len(TASKS)} tasks, max_turns={max_turns}, max_tokens={max_tokens}]"
print(f"== {alias} agentic coding{suffix} ==")
print(f"  {'task':12s} {'verdict':7s} {'time':>7s} {'turns':>6s} {'edmiss':>7s} "
      f"{'botch':>6s} {'think':>8s}")

score = 0
tot = dict(s=0.0, turns=0, edmiss=0, botch=0, think=0)
stalls = meddles = errors = 0

for task in tasks:
    t0 = time.time()
    try:
        ep = play(task)
    except Exception as e:
        errors += 1
        print(f"  {task['label']:12s} ERROR   {e}")
        continue
    dt = time.time() - t0
    ok, out = run_tests(ep.files)          # authoritative, not the model's word

    if task["trap"]:
        if ok and ep.mutations == 0:
            verdict = "PASS"
        elif ok:
            verdict, meddles = "MEDDLE", meddles + 1
        else:
            verdict = "FAIL"
    else:
        verdict = "PASS" if ok else "FAIL"

    if ep.turns >= max_turns and verdict != "PASS":
        verdict, stalls = "STALL", stalls + 1

    score += verdict == "PASS"
    tot["s"] += dt
    for k in ("turns", "edmiss", "botch", "think"):
        tot[k] += getattr(ep, k)

    note = ""
    if verdict == "FAIL":
        note = "  " + " ".join(out.split())[-60:]
    elif verdict == "MEDDLE":
        note = f"  edited working code ({ep.mutations} change(s))"
    print(f"  {task['label']:12s} {verdict:7s} {dt:6.1f}s {ep.turns:6d} "
          f"{ep.edmiss:7d} {ep.botch:6d} {ep.think:7d}c{note}")

scored = len(tasks) - errors
print(f"\n{alias}: {score}/{scored} passed"
      + (f" ({errors} errored, not scored)" if errors else "")
      + f", {tot['s']:.0f}s total, {tot['turns']} turns, {tot['edmiss']} edit "
        f"misses, {tot['botch']} botched calls, {tot['think']} chars of reasoning")

if errors:
    print("NOTE: ERROR rows are transport or server faults, not model behaviour. "
          "'failed to load' means the alias never swapped in - re-run that task "
          "alone before reading anything into the score.")
if tot["edmiss"]:
    print("NOTE: edit misses are the opencode-critical failure - the model believes "
          "it changed a file and did not. A model with a high count here will feel "
          "broken in an agent client no matter how it benchmarks.")
if meddles:
    print("NOTE: MEDDLE means the model rewrote code that was already correct. The "
          "tests still pass, so a pass/fail benchmark scores this as a win; in a real "
          "repo it is an unrequested diff to review.")
if stalls:
    print("NOTE: STALL means the turn budget ran out. That is the same "
          "non-termination that rejected Ornith-3.6 and MiniMax-M2.1 - weigh it "
          "above a wrong answer, and do not tune a model that does it.")
print("NOTE: small N, so this is a discriminator, not a benchmark. Read turns and "
      "think alongside the score: session latency is turns x per-turn time, so a "
      "model that solves in 4 turns beats one that needs 12 at the same t/s.")
PYEOF
