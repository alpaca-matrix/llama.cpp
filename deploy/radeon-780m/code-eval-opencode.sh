#!/bin/bash
# Tier 3: score a model on what opencode actually does to it.
#
# The ladder, and what each rung is for:
#
#   code-eval.sh        4 toy tasks. Saturates on `fast` at 4/4. Catches a
#                       regression, cannot rank a candidate.
#   code-eval-hard.sh   6 harder tasks, same harness and tools, so scores stay
#                       comparable to the easy tier. Separates two models that
#                       both pass tier 1.
#   this file           8 tasks built around opencode's real failure modes,
#                       using opencode's real tool surface.
#
# **Scores here are NOT comparable to tiers 1 and 2.** The tool set is
# different on purpose - `list`/`read`/`grep`/`glob`/`edit`/`write`/`bash`/
# `todowrite` rather than the toy six - because half of what breaks a model in
# opencode is the tool surface itself, and a harness that hides that cannot
# measure it. Read this tier's score against this tier's own calibration only.
#
# What tiers 1 and 2 structurally cannot see, and this one is built to catch:
#
#   agents-md    - project conventions live in AGENTS.md and are stated nowhere
#                  in the prompt. opencode injects that file on every session;
#                  a model that never reads it writes code that violates house
#                  rules while passing every test. Scored on the convention,
#                  not just the fix.
#   needle       - 30 files, 2 of which matter, 3 of them decoys mentioning the
#                  same term. A model that reads the whole project to answer one
#                  question works fine here and is unusable in a real repo,
#                  because context is the budget opencode actually runs out of.
#                  This is the tier's one genuinely new metric: `read` bytes.
#   stale-edit   - the file changes between the read and the edit. This is THE
#                  opencode failure: the model believes it edited a file and it
#                  did not. Injected deterministically, once, on the first edit.
#                  The induced miss is counted separately from real edit misses
#                  so it never contaminates that metric.
#   three-asks   - three independent requirements in one prompt. Models do two
#                  and submit. opencode sessions are full of compound asks.
#   no-collateral- one function to fix in a file of correct-but-ugly ones. The
#                  others must survive byte-identical. An unrequested rewrite is
#                  a diff the user has to review and the single most common
#                  complaint about coding agents.
#   py38         - a constraint stated in AGENTS.md that the tests cannot catch,
#                  because the box runs a newer Python than the target. Only the
#                  source check catches it. Tests retention of a rule over the
#                  whole episode, not compliance at the moment it is read.
#   steer        - the user changes their mind mid-task, after work has already
#                  landed. Deterministic: fires on the first mutation. A model
#                  that plows on with the original plan fails, and this is the
#                  single most opencode-shaped item here.
#
# `bash` is SIMULATED, and deliberately. opencode gives the model a real shell;
# this harness runs on the box as root, so executing model-generated shell to
# measure a model is not a trade worth making. A small whitelist (ls, cat, grep,
# python test_main.py, pytest) is interpreted in Python against the in-memory
# repo. Anything else returns a refusal and increments `denied`, which is
# reported but never scored - a model reaching for `sed -i` is behaving
# reasonably for opencode and only looks wrong against this sandbox.
#
# Verdicts beyond PASS/FAIL/STALL:
#   MEDDLE  - tests pass but a frozen region was rewritten (no-collateral).
#   VIOLATE - tests pass but a stated constraint was broken (agents-md, py38,
#             steer). This is the tier's most important verdict: it is exactly
#             the case a pass/fail benchmark scores as a win and a user
#             experiences as the model ignoring them.
#
# Calibration, measured 2026-08-03:
#
#   fast     6/7  200s  43 turns  0 edmiss  0 botch  3.7K read  7901c think
#   nerkyor  6/7  275s  42 turns  0 edmiss  0 botch  3.8K read  8003c think
#           (7-task run, before agents-inject was added. nerkyor is
#            nerkyor/Qwen3.6-35B-A3B-DSV4Pro-SFT-GPT56Sol-RL-Agent-GGUF Q4,
#            served standalone at c=32768.) Both would score 7/8 on the current
#            task set: the added item passes for both, see the A/B below.
#
# Both models failed the same single item, agents-md, with the same VIOLATE and
# the same cause: correct fix, every assertion passing, bare exception instead
# of the ConfigError that AGENTS.md mandates. Both spent ~0.5K of reads and 5-6
# turns getting there, which is not enough to have opened AGENTS.md at all.
#
# This is the only tier of the three that produced a failure, so it is the only
# one worth running against a candidate - but it did NOT separate the two
# models, and one shared failure is thin evidence. Treat 6/7 as the current bar
# and read the per-item rows, not the total.
#
# **The agents-md / agents-inject A/B, measured 2026-08-03.** The pair was built
# because opencode injects AGENTS.md *contents* into the system prompt, while the
# original item only told the model the file existed. Byte-identical repo,
# prompt and rules; the only difference is `inject`. Result:
#
#   fast     agents-md VIOLATE (6 turns, 0.6K)  agents-inject PASS (5 turns, 0.5K)
#   nerkyor  agents-md VIOLATE (5 turns, 0.4K)  agents-inject PASS (4 turns, 0.5K)
#
# Unambiguous, and the same for both models: **neither model goes looking for
# conventions, and both follow them once handed over.** The failure is discovery,
# not compliance. Since opencode does the handing over, the practical exposure in
# the real client is low - which is exactly why the un-injected item alone would
# have been read as a worse finding than it is.
#
# Keep both. agents-inject is the opencode-faithful measurement and belongs in
# the score; agents-md is the control that makes it interpretable, and it stays
# relevant for any client that does not inject (or when AGENTS.md is large enough
# that a client truncates it). Do not collapse them into one item.
#
# What the passing items did establish, and tiers 1-2 could not:
#   - stale-edit passed for both, 1 harness-induced miss and 0 real misses each:
#     both models re-read the changed file and adapted rather than blindly
#     retrying the stale old_str. That is the opencode-critical behaviour, now
#     measured rather than assumed.
#   - needle passed on ~0.4K of reads for both, against ~5.3K to brute-read the
#     32-file project. Both grep rather than reading everything.
#   - py38 passed for both, so a stated constraint IS honoured when the model has
#     it in hand - which is what makes the agents-md caveat above the more
#     likely reading of that failure.
#
# usage: ./code-eval-opencode.sh <alias>
#   ./code-eval-opencode.sh fast
#   ONLY='steer|needle' MAX_TURNS=60 ./code-eval-opencode.sh nerkyor
#
# ONLY filters by label regex; MAX_TURNS raises the per-task turn budget
# (default 40 - these tasks need more tool calls legitimately) and MAX_TOKENS
# the per-turn generation budget (default 2500). A filtered or re-budgeted run
# is not comparable to a full-tier score.
set -euo pipefail

ALIAS="${1:?model alias}"
HOST="${HOST:-http://127.0.0.1:8080}"
MAX_TURNS="${MAX_TURNS:-40}"
MAX_TOKENS="${MAX_TOKENS:-2500}"
ONLY="${ONLY:-}"

ALIAS="$ALIAS" HOST="$HOST" MAX_TURNS="$MAX_TURNS" MAX_TOKENS="$MAX_TOKENS" \
ONLY="$ONLY" python3 <<'PYEOF'
import fnmatch, json, os, re, shutil, subprocess, sys, tempfile, time
import urllib.error, urllib.request

alias, host = os.environ["ALIAS"], os.environ["HOST"]
max_turns = int(os.environ["MAX_TURNS"])
max_tokens = int(os.environ["MAX_TOKENS"])
only = os.environ.get("ONLY") or ""

# --- filler for the needle task ---------------------------------------------
# 26 innocuous modules plus 3 decoys that mention retries without owning the
# ceiling. The point is that reading all of them is the wrong move.

def _filler():
    out = {}
    for i in range(26):
        out[f"mod_{i:02d}.py"] = (
            f'"""Support module {i}."""\n\n\n'
            f'def helper_{i:02d}(value):\n'
            f'    """Return value scaled by {i + 1}."""\n'
            f'    return value * {i + 1}\n\n\n'
            f'def describe_{i:02d}():\n'
            f'    return "module {i} of the support layer"\n'
        )
    out["svc_mailer.py"] = (
        '"""Mail delivery. Retries are handled by the transport, not here."""\n\n\n'
        'def send(msg):\n'
        '    # NOTE: the transport already retries; do not add a retry loop here.\n'
        '    return {"sent": True, "body": msg}\n'
    )
    out["docs_retry.py"] = (
        '"""Historical notes about the retry design. Not executed anywhere."""\n\n'
        'NOTES = """\n'
        'The retry ceiling used to be hardcoded in every service. It was\n'
        'centralised into settings.py. Some services were missed.\n'
        '"""\n'
    )
    out["test_helpers.py"] = (
        '"""Shared assertions. The retry tests live in test_main.py."""\n\n\n'
        'def approx(a, b, tol=1e-9):\n'
        '    return abs(a - b) <= tol\n'
    )
    return out


NEEDLE_FILES = dict(_filler())
NEEDLE_FILES.update({
    "settings.py":
        '"""Central configuration. Services must read their limits from here."""\n\n'
        'RETRY_LIMIT = 4\n'
        'TIMEOUT_S = 30\n',
    "svc_payments.py":
        '"""Payments transport."""\n\n\n'
        'def attempts():\n'
        '    """How many times a payment call may be attempted."""\n'
        '    return 2\n',
    "test_main.py":
        'from settings import RETRY_LIMIT\n'
        'from svc_payments import attempts\n\n'
        'assert RETRY_LIMIT == 4\n'
        'assert attempts() == 4, "payments must honour the configured ceiling"\n'
        'print("OK")\n',
})

AGENTS = (
    '# Project conventions\n\n'
    '- Every validation failure MUST raise `ConfigError` from `errors.py`.\n'
    '  Never raise a bare `ValueError` or `Exception`.\n'
    '- Never modify anything under `vendor/`. It is third-party code and is\n'
    '  overwritten on every dependency refresh.\n'
    '- Never modify tests.\n'
)

PY38_AGENTS = (
    '# Project conventions\n\n'
    '- The target runtime is **Python 3.8**. CI runs 3.8 and nothing newer.\n'
    '  Do NOT use syntax added after 3.8: no dict union (`|`), no walrus\n'
    '  (`:=`), no `match` statements, no builtin generics in annotations\n'
    '  (`list[int]`, `dict[str, int]` - use `typing.List` etc. if needed).\n'
    '- Never modify tests.\n'
)

# --- tasks -----------------------------------------------------------------
# label, prompt, files, and any of: trap, frozen, forbidden, stale, steer.
#   frozen    - [(path, substring)] that must still be present at scoring time
#   forbidden - [(path, regex, why)] that must NOT match at scoring time
#   stale     - dict(path, find, repl): applied once, on the first edit to path
#   steer     - dict(after, message): injected once, after `after` mutations

TASKS = [
    dict(
        # AGENTS.md is never mentioned in the prompt. The system prompt says
        # conventions live there, exactly as opencode injects it - the model
        # has to go and read it. Tests pass either way; only the convention
        # check separates a compliant model from a merely correct one.
        label="agents-md",
        prompt="settings.py accepts any port number, including nonsense like 0 or "
               "70000. Add validation to load_port() so out-of-range ports are "
               "rejected. test_main.py shows the expected behaviour.",
        files={
            "AGENTS.md": AGENTS,
            "errors.py":
                'class ConfigError(Exception):\n'
                '    """Raised when configuration is invalid."""\n',
            "settings.py":
                'def load_port(raw):\n'
                '    """Parse a port number from a string."""\n'
                '    return int(raw)\n',
            "vendor/legacy.py":
                '# Third-party. Do not edit.\n'
                'def old_parse(raw):\n'
                '    return int(raw)\n',
            # Deliberately does NOT import ConfigError and accepts any
            # exception. If the tests enforced the convention, a model that
            # never opened AGENTS.md would comply by reading the tests, and the
            # item would measure nothing. Only the forbidden check catches it.
            "test_main.py":
                'from settings import load_port\n\n'
                'assert load_port("8080") == 8080\n'
                'assert load_port("1") == 1\n'
                'assert load_port("65535") == 65535\n'
                'for bad in ("0", "70000", "-1"):\n'
                '    try:\n'
                '        load_port(bad)\n'
                '    except Exception:\n'
                '        pass\n'
                '    else:\n'
                '        raise AssertionError("expected a rejection for " + bad)\n'
                'print("OK")\n',
        },
        forbidden=[
            ("settings.py", r"raise\s+(ValueError|Exception|RuntimeError)",
             "raised a bare exception instead of ConfigError"),
        ],
        frozen=[("vendor/legacy.py", "def old_parse(raw):\n    return int(raw)\n")],
    ),
    dict(
        # The A/B twin of agents-md: byte-identical repo, prompt and rules, with
        # the AGENTS.md contents injected into the system prompt the way opencode
        # actually does it. The pair is the measurement - agents-md asks whether
        # the model goes and finds the conventions, this one asks whether it
        # follows them once handed over. Fail both: it ignores conventions. Pass
        # this and fail that: it never looked, which is what opencode's injection
        # papers over. Keep the two definitions identical apart from `inject`.
        label="agents-inject",
        prompt="settings.py accepts any port number, including nonsense like 0 or "
               "70000. Add validation to load_port() so out-of-range ports are "
               "rejected. test_main.py shows the expected behaviour.",
        inject=AGENTS,
        files={
            "AGENTS.md": AGENTS,
            "errors.py":
                'class ConfigError(Exception):\n'
                '    """Raised when configuration is invalid."""\n',
            "settings.py":
                'def load_port(raw):\n'
                '    """Parse a port number from a string."""\n'
                '    return int(raw)\n',
            "vendor/legacy.py":
                '# Third-party. Do not edit.\n'
                'def old_parse(raw):\n'
                '    return int(raw)\n',
            "test_main.py":
                'from settings import load_port\n\n'
                'assert load_port("8080") == 8080\n'
                'assert load_port("1") == 1\n'
                'assert load_port("65535") == 65535\n'
                'for bad in ("0", "70000", "-1"):\n'
                '    try:\n'
                '        load_port(bad)\n'
                '    except Exception:\n'
                '        pass\n'
                '    else:\n'
                '        raise AssertionError("expected a rejection for " + bad)\n'
                'print("OK")\n',
        },
        forbidden=[
            ("settings.py", r"raise\s+(ValueError|Exception|RuntimeError)",
             "raised a bare exception instead of ConfigError"),
        ],
        frozen=[("vendor/legacy.py", "def old_parse(raw):\n    return int(raw)\n")],
    ),
    dict(
        # 30 files, 2 that matter, 3 decoys. Reading everything passes and is
        # the wrong behaviour - watch the read column, not just the verdict.
        label="needle",
        prompt="Payment calls are giving up too early. Somewhere in this project a "
               "service applies the retry ceiling inconsistently with the central "
               "configuration. Find it and fix it so it reads from configuration. "
               "test_main.py has the expected behaviour.",
        files=NEEDLE_FILES,
    ),
    dict(
        # The file changes between read and edit, once, deterministically. A
        # model that retries the same old_str twice has the opencode failure.
        label="stale-edit",
        prompt="The request timeout needs to go from 30 to 60 seconds, and client.py "
               "should read it from configuration instead of hardcoding it. "
               "test_main.py has the expected behaviour.",
        files={
            "config.py":
                '"""Central configuration."""\n\n'
                'TIMEOUT_S = 30\n'
                'RETRIES = 3\n',
            "client.py":
                'def request_timeout():\n'
                '    """Seconds to wait before giving up."""\n'
                '    return 30\n',
            "test_main.py":
                'from config import TIMEOUT_S\n'
                'from client import request_timeout\n\n'
                'assert TIMEOUT_S == 60\n'
                'assert request_timeout() == 60\n'
                'print("OK")\n',
        },
        # The injected change must alter the matched text itself, not append to
        # it: a trailing comment would leave "TIMEOUT_S = 30" as a prefix and
        # the edit would still land, firing nothing. A concurrent tuning bump
        # to 45 is realistic and genuinely invalidates the model's old_str.
        stale=dict(path="config.py", find="TIMEOUT_S = 30",
                   repl="TIMEOUT_S = 45"),
    ),
    dict(
        # Three requirements, one prompt. Models do two and submit.
        label="three-asks",
        prompt="Three things in pager.py, please. First, page_count() is off by one "
               "for exact multiples of the page size. Second, add a "
               "last_page_size(total, per_page) helper returning how many items are "
               "on the final page. Third, the error message prefix should be "
               "'[pager]' rather than '[PAGER]'. test_main.py has the expected "
               "behaviour for all three.",
        files={
            "pager.py":
                'def page_count(total, per_page):\n'
                '    """Number of pages needed to show `total` items."""\n'
                '    return total // per_page + 1\n\n\n'
                'def guard(total):\n'
                '    if total < 0:\n'
                '        raise ValueError("[PAGER] total must not be negative")\n'
                '    return total\n',
            "test_main.py":
                'from pager import page_count, last_page_size, guard\n\n'
                'assert page_count(10, 5) == 2\n'
                'assert page_count(11, 5) == 3\n'
                'assert page_count(0, 5) == 0\n'
                'assert last_page_size(10, 5) == 5\n'
                'assert last_page_size(11, 5) == 1\n'
                'try:\n'
                '    guard(-1)\n'
                'except ValueError as e:\n'
                '    assert str(e).startswith("[pager]"), str(e)\n'
                'else:\n'
                '    raise AssertionError("guard did not raise")\n'
                'print("OK")\n',
        },
    ),
    dict(
        # One bug in a file of correct-but-ugly functions. The others must
        # survive byte-identical. Tests pass either way; frozen catches it.
        label="no-collateral",
        prompt="normalize_email() in accounts.py does not lowercase the domain, so "
               "the same address compares unequal depending on how it was typed. "
               "Fix that one function. test_main.py has the expected behaviour.",
        files={
            "accounts.py":
                'def normalize_email(addr):\n'
                '    local, _, domain = addr.partition("@")\n'
                '    return local.lower() + "@" + domain\n\n\n'
                'def display_name(first, last):\n'
                '    n = ""\n'
                '    n = n + first\n'
                '    n = n + " "\n'
                '    n = n + last\n'
                '    return n\n\n\n'
                'def initials(first, last):\n'
                '    x = first[0:1]\n'
                '    y = last[0:1]\n'
                '    return (x + y).upper()\n\n\n'
                'def is_adult(age):\n'
                '    if age >= 18:\n'
                '        return True\n'
                '    else:\n'
                '        return False\n',
            "test_main.py":
                'from accounts import normalize_email, display_name, initials, is_adult\n\n'
                'assert normalize_email("A.User@Example.COM") == "a.user@example.com"\n'
                'assert normalize_email("x@y.z") == "x@y.z"\n'
                'assert display_name("Ada", "Lovelace") == "Ada Lovelace"\n'
                'assert initials("ada", "lovelace") == "AL"\n'
                'assert is_adult(18) is True\n'
                'assert is_adult(17) is False\n'
                'print("OK")\n',
        },
        frozen=[
            ("accounts.py", 'def display_name(first, last):\n    n = ""\n    n = n + first\n'
                            '    n = n + " "\n    n = n + last\n    return n\n'),
            ("accounts.py", 'def initials(first, last):\n    x = first[0:1]\n'
                            '    y = last[0:1]\n    return (x + y).upper()\n'),
            ("accounts.py", 'def is_adult(age):\n    if age >= 18:\n        return True\n'
                            '    else:\n        return False\n'),
        ],
    ),
    dict(
        # The box runs a newer Python than the stated target, so the tests
        # cannot catch a 3.9+ construct. Only the source check can.
        label="py38",
        prompt="Add a merge() to merge.py that combines a base settings dict with an "
               "overrides dict, where overrides win, without modifying either input. "
               "test_main.py has the expected behaviour.",
        files={
            "AGENTS.md": PY38_AGENTS,
            "merge.py":
                '"""Settings composition."""\n\n\n'
                'def defaults():\n'
                '    return {"host": "localhost", "port": 8080}\n',
            "test_main.py":
                'from merge import merge, defaults\n\n'
                'base = defaults()\n'
                'over = {"port": 9090, "debug": True}\n'
                'got = merge(base, over)\n'
                'assert got == {"host": "localhost", "port": 9090, "debug": True}, got\n'
                'assert base == {"host": "localhost", "port": 8080}, "merge mutated base"\n'
                'assert over == {"port": 9090, "debug": True}, "merge mutated overrides"\n'
                'print("OK")\n',
        },
        forbidden=[
            ("merge.py", r"\|", "used dict union `|`, which needs Python 3.9"),
            ("merge.py", r":=", "used the walrus operator, which needs Python 3.8+ only in expressions but is banned by AGENTS.md"),
            ("merge.py", r"\bmatch\b\s+\w+\s*:", "used a match statement, which needs Python 3.10"),
            ("merge.py", r"\b(?:list|dict|tuple|set)\[", "used builtin generics, which need Python 3.9"),
        ],
    ),
    dict(
        # The user changes their mind after work has landed. Fires once, on the
        # first mutation. Plowing on with the original plan is the failure.
        label="steer",
        prompt="Add a to_csv(rows) function to report.py. rows is a list of dicts "
               "with keys 'name' and 'qty'. Return a CSV string with a header line, "
               "comma-separated, newline-terminated rows.",
        files={
            "report.py":
                '"""Reporting helpers."""\n\n\n'
                'def row_count(rows):\n'
                '    return len(rows)\n',
            "test_main.py":
                'from report import to_tsv\n\n'
                'rows = [{"name": "apple", "qty": 3}, {"name": "pear", "qty": 5}]\n'
                'out = to_tsv(rows)\n'
                'lines = out.strip().split("\\n")\n'
                'assert lines[0] == "name\\tqty", lines[0]\n'
                'assert lines[1] == "apple\\t3", lines[1]\n'
                'assert lines[2] == "pear\\t5", lines[2]\n'
                'assert "," not in out, "output must be tab-separated, not comma"\n'
                'print("OK")\n',
        },
        steer=dict(after=1, message=(
            "Hold on - change of plan. We do not want CSV after all, the downstream "
            "tool needs tab-separated. Make it to_tsv(rows) instead, tab-separated, "
            "same header-plus-rows shape. Nothing in the final code should mention "
            "CSV - no to_csv function, no csv module, no leftover commas.")),
        forbidden=[
            ("report.py", r"(?i)csv", "left CSV behind after being asked to drop it"),
        ],
    ),
]

# opencode's actual tool surface, near enough that a model trained on it
# behaves the way it will in the client.
TOOLS = [
    {"type": "function", "function": {
        "name": "list", "description": "List all files in the project.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "read",
        "description": "Read a file. Optionally pass offset and limit (line numbers) "
                       "to read only part of a large file.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"},
            "offset": {"type": "integer"},
            "limit": {"type": "integer"}},
            "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "grep",
        "description": "Search file contents with a regular expression. Returns "
                       "matching lines as path:line:text. Far cheaper than reading "
                       "every file.",
        "parameters": {"type": "object", "properties": {
            "pattern": {"type": "string"},
            "glob": {"type": "string", "description": "optional filename filter, e.g. *.py"}},
            "required": ["pattern"]}}},
    {"type": "function", "function": {
        "name": "glob", "description": "List files matching a glob pattern.",
        "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}},
                       "required": ["pattern"]}}},
    {"type": "function", "function": {
        "name": "edit",
        "description": "Replace an exact substring in a file. old_str must appear "
                       "exactly once, matching whitespace and indentation exactly.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"},
            "old_str": {"type": "string"},
            "new_str": {"type": "string"}},
            "required": ["path", "old_str", "new_str"]}}},
    {"type": "function", "function": {
        "name": "write", "description": "Create a file or overwrite one entirely.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["path", "content"]}}},
    {"type": "function", "function": {
        "name": "bash",
        "description": "Run a shell command in the project directory. Supports ls, "
                       "cat, grep and running the tests with 'python test_main.py'.",
        "parameters": {"type": "object", "properties": {"command": {"type": "string"}},
                       "required": ["command"]}}},
    {"type": "function", "function": {
        "name": "todowrite",
        "description": "Record a plan as a list of steps. Use for multi-step work.",
        "parameters": {"type": "object", "properties": {
            "todos": {"type": "array", "items": {"type": "string"}}},
            "required": ["todos"]}}},
    {"type": "function", "function": {
        "name": "submit", "description": "Call when the task is done. Ends the session.",
        "parameters": {"type": "object",
                       "properties": {"summary": {"type": "string"}},
                       "required": ["summary"]}}},
]

SYSTEM = ("You are a coding agent working in a software project. Use the provided "
          "tools to inspect and modify files, and verify your work by running the "
          "tests. Project conventions, when the project has any, are in AGENTS.md "
          "at the project root and must be followed. Prefer grep over reading every "
          "file: context is limited. Make the smallest change that does the job and "
          "do not rewrite code you were not asked to change. Call submit when you "
          "are done.")


def run_tests(files):
    """Materialise the in-memory repo and run its tests. Authoritative."""
    d = tempfile.mkdtemp(prefix="code-eval-oc-")
    try:
        for name, body in files.items():
            p = os.path.join(d, name)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as fh:
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
        try:
            body = json.loads(e.read().decode())
            detail = body.get("error", {}).get("message") or str(body)[:200]
        except Exception:
            detail = "(no readable body)"
        raise RuntimeError(f"HTTP {e.code}: {detail}") from None


class Episode:
    def __init__(self, task):
        self.task = task
        self.files = dict(task["files"])
        self.turns = self.edmiss = self.botch = self.think = self.mutations = 0
        self.rbytes = self.denied = self.induced = self.todos = 0
        self.stale_fired = False
        self.steered = False

    # -- simulated shell -----------------------------------------------------
    # Interpreted, never executed. See the header for why.
    def sh(self, cmd):
        c = " ".join((cmd or "").split())
        if re.fullmatch(r"(python3?|py)\s+test_main\.py", c) or c in ("pytest", "python -m pytest"):
            ok, out = run_tests(self.files)
            return ("PASS\n" if ok else "FAIL\n") + out
        if c in ("ls", "ls -a", "ls -l", "ls ."):
            return "\n".join(sorted(self.files))
        m = re.fullmatch(r"cat\s+(\S+)", c)
        if m:
            path = m.group(1)
            if path not in self.files:
                return f"cat: {path}: No such file or directory"
            body = self.files[path]
            self.rbytes += len(body)
            return body
        m = re.fullmatch(r"grep\s+(?:-[a-zA-Z]+\s+)*['\"]?(.+?)['\"]?(?:\s+(\S+))?", c)
        if m and c.startswith("grep"):
            return self.grep(m.group(1), None)
        self.denied += 1
        return (f"ERROR: '{c.split()[0] if c else cmd}' is not available in this "
                "sandbox. Available: ls, cat, grep, python test_main.py. "
                "Use the edit and write tools to change files.")

    def grep(self, pattern, globpat):
        try:
            rx = re.compile(pattern)
        except re.error as e:
            self.botch += 1
            return f"ERROR: bad regex: {e}"
        hits = []
        for path in sorted(self.files):
            if globpat and not fnmatch.fnmatch(path, globpat):
                continue
            for i, line in enumerate(self.files[path].splitlines(), 1):
                if rx.search(line):
                    hits.append(f"{path}:{i}:{line.strip()[:160]}")
        if not hits:
            return "(no matches)"
        out = "\n".join(hits[:100])
        if len(hits) > 100:
            out += f"\n... {len(hits) - 100} more matches"
        self.rbytes += len(out)
        return out

    def dispatch(self, name, args):
        """Execute one tool call. Returns the string handed back to the model."""
        if name == "list":
            return "\n".join(sorted(self.files))

        if name == "glob":
            pat = args.get("pattern") or "*"
            hit = [p for p in sorted(self.files) if fnmatch.fnmatch(p, pat)]
            return "\n".join(hit) or "(no matches)"

        if name == "grep":
            pat = args.get("pattern")
            if not pat:
                self.botch += 1
                return "ERROR: missing required field 'pattern'"
            return self.grep(pat, args.get("glob"))

        if name == "read":
            path = args.get("path")
            if not path:
                self.botch += 1
                return "ERROR: missing required field 'path'"
            if path not in self.files:
                return f"ERROR: no such file: {path}"
            body = self.files[path]
            off, lim = args.get("offset"), args.get("limit")
            if off is not None or lim is not None:
                lines = body.splitlines(True)
                start = max(0, int(off or 0))
                body = "".join(lines[start:start + int(lim)] if lim else lines[start:])
            self.rbytes += len(body)
            return body

        if name == "edit":
            path, old, new = args.get("path"), args.get("old_str"), args.get("new_str")
            if path is None or old is None or new is None:
                self.botch += 1
                return "ERROR: edit needs path, old_str and new_str"
            if path not in self.files:
                self.edmiss += 1
                return f"ERROR: no such file: {path}"

            # Deterministic staleness: the file changed under the model, once.
            st = self.task.get("stale")
            if st and not self.stale_fired and path == st["path"]:
                self.stale_fired = True
                if st["find"] in self.files[path]:
                    self.files[path] = self.files[path].replace(st["find"], st["repl"], 1)
                    if old not in self.files[path]:
                        self.induced += 1
                        return ("ERROR: old_str not found in " + path +
                                ". The file has changed on disk since you last read "
                                "it. Re-read it and try again.")

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

        if name == "write":
            path, content = args.get("path"), args.get("content")
            if path is None or content is None:
                self.botch += 1
                return "ERROR: write needs path and content"
            self.files[path] = content
            self.mutations += 1
            return f"OK: wrote {path}"

        if name == "bash":
            return self.sh(args.get("command") or "")

        if name == "todowrite":
            self.todos += 1
            return "OK: plan recorded"

        self.botch += 1
        return f"ERROR: unknown tool {name!r}"


def play(task):
    """Drive one task to completion or exhaustion. Returns an Episode."""
    ep = Episode(task)
    # `inject` puts the AGENTS.md contents straight into the system prompt, the
    # way opencode does. Paired with an identical non-injected task it isolates
    # discovery from compliance - see the agents-md / agents-inject pair.
    sysmsg = SYSTEM
    if task.get("inject"):
        sysmsg += "\n\nProject conventions, from AGENTS.md:\n" + task["inject"]
    msgs = [{"role": "system", "content": sysmsg},
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
                    msgs.append({"role": "tool", "tool_call_id": call.get("id", ""),
                                 "content": "ERROR: arguments were not valid JSON"})
                    continue
            if fn["name"] == "submit":
                done = True
                msgs.append({"role": "tool", "tool_call_id": call.get("id", ""),
                             "content": "OK"})
                continue
            msgs.append({"role": "tool", "tool_call_id": call.get("id", ""),
                         "content": ep.dispatch(fn["name"], args)})

        # The user changes their mind, once, after work has landed. If the model
        # tried to submit on the same turn, the steer still lands and the
        # episode continues - that is what happens in the client.
        st = task.get("steer")
        if st and not ep.steered and ep.mutations >= st["after"]:
            ep.steered = True
            msgs.append({"role": "user", "content": st["message"]})
            done = False
            continue

        if done:
            break

    return ep


def score_episode(task, ep):
    """Verdict for one finished episode. Tests are authoritative, then rules."""
    ok, out = run_tests(ep.files)
    if not ok:
        if ep.turns >= max_turns:
            return "STALL", " ".join(out.split())[-60:]
        return "FAIL", " ".join(out.split())[-60:]

    for path, sub in task.get("frozen", []):
        if sub not in ep.files.get(path, ""):
            return "MEDDLE", f"rewrote untouched code in {path}"

    for path, rx, why in task.get("forbidden", []):
        if re.search(rx, ep.files.get(path, "")):
            return "VIOLATE", why

    if task.get("steer") and not ep.steered:
        return "FAIL", "never reached the steering point"

    return "PASS", ""


tasks = [t for t in TASKS if not only or re.search(only, t["label"])]
suffix = ""
if only or max_turns != 40 or max_tokens != 2500:
    suffix = f" [{len(tasks)}/{len(TASKS)} tasks, max_turns={max_turns}, max_tokens={max_tokens}]"
print(f"== {alias} agentic coding, opencode tier{suffix} ==")
print(f"  {'task':14s} {'verdict':7s} {'time':>7s} {'turns':>6s} {'edmiss':>7s} "
      f"{'botch':>6s} {'read':>8s} {'think':>8s}")

score = 0
tot = dict(s=0.0, turns=0, edmiss=0, botch=0, think=0, rbytes=0,
           denied=0, induced=0, todos=0)
stalls = meddles = violates = errors = 0

for task in tasks:
    t0 = time.time()
    try:
        ep = play(task)
    except Exception as e:
        errors += 1
        print(f"  {task['label']:14s} ERROR   {e}")
        continue
    dt = time.time() - t0
    verdict, note = score_episode(task, ep)

    score += verdict == "PASS"
    stalls += verdict == "STALL"
    meddles += verdict == "MEDDLE"
    violates += verdict == "VIOLATE"
    tot["s"] += dt
    for k in ("turns", "edmiss", "botch", "think", "rbytes", "denied", "induced", "todos"):
        tot[k] += getattr(ep, k)

    print(f"  {task['label']:14s} {verdict:7s} {dt:6.1f}s {ep.turns:6d} "
          f"{ep.edmiss:7d} {ep.botch:6d} {ep.rbytes/1024:7.1f}K {ep.think:7d}c"
          + (f"  {note}" if note else ""))

scored = len(tasks) - errors
print(f"\n{alias}: {score}/{scored} passed"
      + (f" ({errors} errored, not scored)" if errors else "")
      + f", {tot['s']:.0f}s total, {tot['turns']} turns, {tot['edmiss']} edit misses, "
        f"{tot['botch']} botched calls, {tot['rbytes']/1024:.1f}K read, "
        f"{tot['think']} chars of reasoning")
print(f"  todowrite used {tot['todos']}x, {tot['denied']} unsupported shell command(s), "
      f"{tot['induced']} harness-induced stale-edit miss(es)")

if errors:
    print("NOTE: ERROR rows are transport or server faults, not model behaviour. "
          "'failed to load' means the alias never swapped in - re-run that task "
          "alone before reading anything into the score.")
if violates:
    print("NOTE: VIOLATE is the verdict that matters most here. The tests passed and "
          "the model broke a rule it was given - an AGENTS.md convention, or an "
          "instruction the user gave mid-session. Every pass/fail benchmark scores "
          "this as a win; a user experiences it as being ignored.")
if meddles:
    print("NOTE: MEDDLE means the model rewrote code it was not asked to touch. In a "
          "real repo that is an unrequested diff someone has to review.")
if stalls:
    print("NOTE: STALL means the turn budget ran out. That is the same "
          "non-termination that rejected Ornith-3.6 and MiniMax-M2.1 - weigh it "
          "above a wrong answer, and do not tune a model that does it.")
print("NOTE: read the 'read' column against the needle task specifically. The whole "
      "project is ~30 files and only 2 matter; a model that reads 40K to answer it "
      "passes here and exhausts context in a real session.")
print("NOTE: small N, so this is a discriminator, not a benchmark. Scores are NOT "
      "comparable to code-eval.sh or code-eval-hard.sh - different tool surface.")
PYEOF
