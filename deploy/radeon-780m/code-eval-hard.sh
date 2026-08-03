#!/bin/bash
# Hard tier: rank an agentic-coding candidate above `fast`, not just against it.
#
# `code-eval.sh` saturates - `fast` scores 4/4 - so it can justify the incumbent
# and catch a regression, but a candidate scoring 4/4 there has only failed to
# be worse. This tier exists for the same reason `reason-eval-hard.sh` exists
# for the deep slot: to produce a number that can separate two models that both
# already pass the easy tier.
#
# The harness is `code-eval.sh`'s, unchanged - same tools, same system prompt,
# same metrics, same authoritative test run. Only the tasks are harder, so a
# score here is read the same way and the two tiers stay comparable.
#
# What makes these harder, item by item. Each targets a failure the easy tier
# cannot produce, and each still has one unambiguous test-verified answer:
#
#   dup-block    - the buggy line appears three times verbatim, so `old_str`
#                  must be qualified with surrounding context to be unique.
#                  Every model measured on the easy tier scored 0 edit misses;
#                  that metric has never actually been under load. This puts it
#                  there, and it is the opencode-critical one.
#   two-bugs     - one function, two independent defects, only one of which is
#                  obvious. Models characteristically stop at the first fix and
#                  declare victory; the tests assert both.
#   hidden-call  - the constant is duplicated across three files and the two
#                  copies disagree with each other. Requires listing the project
#                  rather than patching the file named in the prompt.
#   parse-range  - the naive fix and the obvious second fix both pass three of
#                  four assertions. Only a regex handles the fourth.
#   shared-state - a class attribute where an instance attribute belongs. The
#                  code reads as correct; the bug is only visible across two
#                  objects, so it cannot be found without running the tests.
#   trap-idiom   - the trap. `n & (n - 1)` is correct and looks wrong, and the
#                  bug report is confidently specific about a case that already
#                  works. Editing anything here is the failure.
#
# Two traps would be one too many, so this tier keeps a single one - but it is a
# harder trap than the easy tier's, because the idiom itself invites a rewrite.
#
# Calibration, measured 2026-08-03:
#
#   fast     6/6  163s  27 turns  0 edmiss  0 botch  6601c think
#   nerkyor  6/6  244s  31 turns  0 edmiss  0 botch  8991c think
#           (nerkyor/Qwen3.6-35B-A3B-DSV4Pro RL-Agent Q4, standalone, c=32768)
#
# **This tier is saturated and does not do the job it was built for.** It was
# written to rank a candidate above `fast`; two models scored 6/6 on the first
# attempt, so it cannot. Read it as a regression check only - it is a harder
# workload than `code-eval.sh` (27 turns and 163s against 19 and 93s) without
# being a harder discriminator, which is the only thing that mattered.
#
# The one separation it does produce is effort: `fast` finished 33% faster in 4
# fewer turns. Usable as a tiebreak between models that both pass, not as a
# ranking.
#
# dup-block, the item written specifically to force edit misses, produced 0 for
# both models - each qualified its `old_str` with surrounding context on the
# first try. Good model behaviour, and it leaves the opencode-critical metric
# still untested on this box. Provoking it needs a harder construction than
# three identical lines in one file.
#
# If this tier is revised rather than retired, the items to harden first are the
# ones both models solved in the fewest turns. See `code-eval-opencode.sh`,
# which does discriminate, and consider whether this rung is still worth having.
#
# usage: ./code-eval-hard.sh <alias>
#   ./code-eval-hard.sh fast
#   ONLY='two-bugs|parse-range' MAX_TURNS=48 ./code-eval-hard.sh nerkyor
#
# ONLY filters by label regex; MAX_TURNS raises the per-task turn budget
# (default 32, higher than the easy tier because these need more tool calls
# legitimately) and MAX_TOKENS the per-turn generation budget (default 2500).
# A filtered or re-budgeted run is not comparable to a full-tier score.
set -euo pipefail

ALIAS="${1:?model alias}"
HOST="${HOST:-http://127.0.0.1:8080}"
MAX_TURNS="${MAX_TURNS:-32}"
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
# Same shape as `code-eval.sh`: label, prompt, files, trap. Every test_main.py
# exits non-zero on failure and this script runs it itself at the end - the
# model's own claim is never trusted.

TASKS = [
    dict(
        # The line `    if len(s) < 3:` appears verbatim three times. An
        # unqualified old_str matches 3 times and is rejected, so the model has
        # to include the def line or the body to disambiguate. This is the
        # edit-format pressure the easy tier never applies.
        label="dup-block",
        trap=False,
        prompt="Passwords are being accepted that are far too short. validators.py "
               "has the rule wrong. test_main.py shows the expected minimum lengths "
               "for each kind of value. Fix only what is wrong.",
        files={
            "validators.py":
                'def validate_username(s):\n'
                '    if len(s) < 3:\n'
                '        return False\n'
                '    return s.isalnum()\n\n\n'
                'def validate_password(s):\n'
                '    if len(s) < 3:\n'
                '        return False\n'
                '    return s.isalnum()\n\n\n'
                'def validate_token(s):\n'
                '    if len(s) < 3:\n'
                '        return False\n'
                '    return s.isalnum()\n',
            "test_main.py":
                'from validators import validate_username, validate_password, validate_token\n\n'
                'assert validate_username("abc") is True\n'
                'assert validate_username("ab") is False\n'
                'assert validate_password("abcdefgh") is True\n'
                'assert validate_password("abcdefg") is False\n'
                'assert validate_token("abc") is True\n'
                'assert validate_token("ab") is False\n'
                'print("OK")\n',
        },
    ),
    dict(
        # Two defects: the even-length case, and the in-place sort that mutates
        # the caller's list. Fixing the first is the obvious move and leaves the
        # second; the tests assert both independently.
        label="two-bugs",
        trap=False,
        prompt="median() in stats.py is misbehaving. test_main.py has the expected "
               "behaviour. Fix it so every assertion passes.",
        files={
            "stats.py":
                'def median(xs):\n'
                '    """Return the median of xs. Must not modify the caller\'s list."""\n'
                '    xs.sort()\n'
                '    n = len(xs)\n'
                '    return xs[n // 2]\n',
            "test_main.py":
                'from stats import median\n\n'
                'assert median([3, 1, 2]) == 2\n'
                'assert median([4, 1, 3, 2]) == 2.5\n'
                'original = [5, 2, 9, 1]\n'
                'median(original)\n'
                'assert original == [5, 2, 9, 1], "median() mutated its argument"\n'
                'print("OK")\n',
        },
    ),
    dict(
        # The limit is hardcoded in two other files and the two copies already
        # disagree (<= vs <). Patching only the file named in the prompt fails.
        label="hidden-call",
        trap=False,
        prompt="The upload size limit needs to go from 10 MB to 25 MB. Update the "
               "project so the new limit is enforced consistently everywhere and is "
               "read from configuration rather than hardcoded. test_main.py has the "
               "expected behaviour.",
        files={
            "limits.py":
                '# Central tuning knobs.\n'
                'MAX_UPLOAD_MB = 10\n',
            "api.py":
                'def check_upload(mb):\n'
                '    """Reject uploads over the limit."""\n'
                '    return mb <= 10\n',
            "worker.py":
                'def will_accept(mb):\n'
                '    """Reject uploads over the limit."""\n'
                '    return mb < 10\n',
            "test_main.py":
                'from limits import MAX_UPLOAD_MB\n'
                'from api import check_upload\n'
                'from worker import will_accept\n\n'
                'assert MAX_UPLOAD_MB == 25\n'
                'assert check_upload(25) is True\n'
                'assert check_upload(26) is False\n'
                'assert will_accept(25) is True\n'
                'assert will_accept(26) is False\n'
                'print("OK")\n',
        },
    ),
    dict(
        # split("-") fails on a negative low bound; rsplit("-", 1) fixes three
        # of the four assertions and still fails "-3--1". Only a regex (or an
        # equivalent scan) handles a negative bound on both sides.
        label="parse-range",
        trap=False,
        prompt="parse_range() in ranges.py crashes on ranges whose bounds are "
               "negative. test_main.py has the full expected behaviour. Fix it.",
        files={
            "ranges.py":
                'def parse_range(s):\n'
                '    """Parse "lo-hi" into the tuple (lo, hi). Bounds may be negative."""\n'
                '    lo, hi = s.split("-")\n'
                '    return int(lo), int(hi)\n',
            "test_main.py":
                'from ranges import parse_range\n\n'
                'assert parse_range("1-5") == (1, 5)\n'
                'assert parse_range("0-0") == (0, 0)\n'
                'assert parse_range("-3-5") == (-3, 5)\n'
                'assert parse_range("-3--1") == (-3, -1)\n'
                'print("OK")\n',
        },
    ),
    dict(
        # A class attribute where an instance attribute belongs. Reading the
        # file suggests nothing wrong; the defect only appears across two
        # instances, so it cannot be found without running the tests.
        label="shared-state",
        trap=False,
        prompt="Carts are showing items that were added to a different cart. "
               "cart.py is the culprit. test_main.py has the expected behaviour.",
        files={
            "cart.py":
                'class Cart:\n'
                '    """A shopping cart. Each cart holds its own items."""\n\n'
                '    items = []\n\n'
                '    def add(self, name):\n'
                '        self.items.append(name)\n\n'
                '    def count(self):\n'
                '        return len(self.items)\n',
            "test_main.py":
                'from cart import Cart\n\n'
                'a = Cart()\n'
                'b = Cart()\n'
                'a.add("apple")\n'
                'a.add("pear")\n'
                'b.add("plum")\n'
                'assert a.count() == 2, a.items\n'
                'assert b.count() == 1, b.items\n'
                'assert "apple" not in b.items\n'
                'print("OK")\n',
        },
    ),
    dict(
        # The trap, and a harder one than the easy tier's clamp(): the bit trick
        # looks wrong to anyone reading quickly, and the bug report names two
        # specific cases that both already work. The only right move is to run
        # the tests, see them pass, and say so.
        label="trap-idiom",
        trap=True,
        prompt="A user reports that is_power_of_two() in bits.py returns True for 0 "
               "and for negative numbers, which is wrong. The bit trick it uses looks "
               "suspicious. Investigate. If it is genuinely broken, fix it. If it is "
               "not broken, leave it alone and say so.",
        files={
            "bits.py":
                'def is_power_of_two(n):\n'
                '    """True if n is a positive power of two."""\n'
                '    return n > 0 and (n & (n - 1)) == 0\n',
            "test_main.py":
                'from bits import is_power_of_two\n\n'
                'assert is_power_of_two(1) is True\n'
                'assert is_power_of_two(2) is True\n'
                'assert is_power_of_two(1024) is True\n'
                'assert is_power_of_two(3) is False\n'
                'assert is_power_of_two(0) is False\n'
                'assert is_power_of_two(-4) is False\n'
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
    d = tempfile.mkdtemp(prefix="code-eval-hard-")
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
if only or max_turns != 32 or max_tokens != 2500:
    suffix = f" [{len(tasks)}/{len(TASKS)} tasks, max_turns={max_turns}, max_tokens={max_tokens}]"
print(f"== {alias} agentic coding, hard tier{suffix} ==")
print(f"  {'task':13s} {'verdict':7s} {'time':>7s} {'turns':>6s} {'edmiss':>7s} "
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
        print(f"  {task['label']:13s} ERROR   {e}")
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
    print(f"  {task['label']:13s} {verdict:7s} {dt:6.1f}s {ep.turns:6d} "
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
          "it changed a file and did not. dup-block is built to provoke them, so a "
          "count of 1-2 recovered from is normal here; a model that never recovers "
          "will feel broken in an agent client no matter how it benchmarks.")
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
