#!/bin/bash
# Tier 3: score a model on what Claude Code actually does to it.
#
# This replaces code-eval-opencode.sh as the client-shaped rung. That tier was
# built when opencode was the client here; opencode was uninstalled from the
# workstation on 2026-08-11 and Claude Code is the harness this box exists to
# serve. Scoring a model on a tool surface nobody drives is measuring the wrong
# thing, however good the harness is.
#
# **Scores here are NOT comparable to code-eval.sh or code-eval-hard.sh**, and
# not to the opencode tier either. Different tool surface, different transport,
# different failure modes. Read this tier against its own calibration only.
#
# Two differences from the opencode tier are load-bearing rather than cosmetic,
# and they are the reason this file exists instead of a rename:
#
#   TRANSPORT. Claude Code speaks the Anthropic API (/v1/messages), not
#   /v1/chat/completions. On this server that is a different path: the request
#   is translated Anthropic->OAI before the jinja template renders it (see the
#   request flow in fast-opt-plan.md). Tool calls come back as `tool_use`
#   content blocks and go back in as `tool_result` blocks, and cache_control
#   markers ride along on the system block. A model can parse tools correctly
#   through one path and badly through the other, and only this tier would see
#   it. Set TRANSPORT=oai to run the same tasks over /v1/chat/completions - the
#   pair isolates a transport bug from a model weakness.
#
#   LINE NUMBERS. Claude Code's Read returns `cat -n` format, and its Edit
#   requires old_string to match the file exactly WITHOUT that prefix. So the
#   model must strip what the harness just handed it. Every other tier on this
#   box hands back raw file bodies, so no tier has ever tested this, and it is
#   the single most common way a real session burns turns. `lineno` counts
#   edits rejected for carrying the prefix back, tracked separately from real
#   edit misses so it never contaminates that metric.
#
# Three more Claude Code behaviours the harness enforces because the real client
# enforces them:
#
#   - Read before Edit. Editing a file not read in this session fails. Counted
#     as `rbe`. A model trained against harnesses without the invariant will
#     edit blind, and the prompt for `blind-fix` is written to tempt exactly
#     that by quoting the buggy line in full.
#   - old_string must be unique, or the call needs replace_all. Same shape as
#     the opencode tier's dup-block, kept because it is also Claude Code's
#     behaviour and it is the one place the two clients agree.
#   - Conventions live in CLAUDE.md, and the client injects it. `claude-md`
#     is the injected (faithful) item and carries the score.
#
# The task set, and what each is for. Six items, each with one unambiguous
# test-verified answer:
#
#   blind-fix     - the prompt quotes the buggy line verbatim, so the fix looks
#                   actionable without opening the file. Editing without
#                   reading is the failure, and the file also differs from the
#                   prompt's quote in whitespace, so a blind edit cannot even
#                   match. Measures `rbe`.
#   numbered      - a fix in a file whose relevant line is deep enough that the
#                   model must Read it, then edit it. The whole item is the
#                   line-number-prefix trap. Measures `lineno`.
#   dup-line      - the target line appears three times verbatim; needs context
#                   qualification or replace_all.
#   claude-md     - the project forbids bare ValueError and mandates ConfigError
#                   from errors.py. Stated only in CLAUDE.md, which is injected
#                   into the system prompt the way the client does it. Scored on
#                   the convention, not just the fix.
#   stale-edit    - the file changes between the Read and the Edit, once,
#                   deterministically. The model must re-read rather than retry
#                   the stale old_string. Induced misses counted separately.
#   no-collateral - one function to fix among correct-but-ugly neighbours. The
#                   others must survive byte-identical. An unrequested rewrite
#                   fails even if the tests pass.
#
# Metrics, and how to read them. Score is authoritative (the tests run for
# real). After that, in order of what has actually mattered on this box:
# turns (session latency is turns x per-turn time), lineno and rbe (harness
# fluency, and pure waste when nonzero), edmiss, botch, read bytes, think chars.
#
# usage: ./code-eval-claude.sh <alias>
#   ./code-eval-claude.sh fast
#   TRANSPORT=oai ./code-eval-claude.sh fast
#   ONLY='numbered|dup-line' MAX_TURNS=48 ./code-eval-claude.sh nerkyor-eval
#
# ONLY filters by label regex; MAX_TURNS raises the per-task turn budget
# (default 40) and MAX_TOKENS the per-turn generation budget (default 2500).
# A filtered or re-budgeted run is not comparable to a full-tier score.
set -euo pipefail

ALIAS="${1:?model alias}"
HOST="${HOST:-http://127.0.0.1:8080}"
MAX_TURNS="${MAX_TURNS:-40}"
MAX_TOKENS="${MAX_TOKENS:-2500}"
ONLY="${ONLY:-}"
TRANSPORT="${TRANSPORT:-anthropic}"

ALIAS="$ALIAS" HOST="$HOST" MAX_TURNS="$MAX_TURNS" MAX_TOKENS="$MAX_TOKENS" \
ONLY="$ONLY" TRANSPORT="$TRANSPORT" python3 <<'PYEOF'
import fnmatch, json, os, re, shutil, subprocess, sys, tempfile, time
import urllib.error, urllib.request

alias, host = os.environ["ALIAS"], os.environ["HOST"]
max_turns = int(os.environ["MAX_TURNS"])
max_tokens = int(os.environ["MAX_TOKENS"])
only = os.environ.get("ONLY") or ""
transport = os.environ["TRANSPORT"]
if transport not in ("anthropic", "oai"):
    raise SystemExit("TRANSPORT must be 'anthropic' or 'oai'")

CLAUDE_MD = (
    "# Project conventions\n\n"
    "- Every validation failure MUST raise `ConfigError` from `errors.py`.\n"
    "  Never raise a bare `ValueError` or `Exception`.\n"
    "- Keep functions under 20 lines.\n"
)

# --- tasks ------------------------------------------------------------------
# Each task is a self-contained in-memory project. test_main.py is the
# authority: it is run for real in a temp dir at the end of the episode.

TASKS = [
    {
        "label": "blind-fix",
        # The prompt quotes the line with single-space indentation; the file
        # uses four. A model that edits from the prompt cannot match, and one
        # that reads first has the real text. This is the read-before-edit
        # probe, and the mismatch makes the failure loud rather than silent.
        "prompt": ("In calc.py the discount is wrong. The line reads:\n\n"
                   " return price * 0.9\n\n"
                   "It should apply a 20 percent discount, not 10. Fix it and "
                   "run the tests."),
        "files": {
            "calc.py": (
                '"""Pricing helpers."""\n\n\n'
                'def discounted(price):\n'
                '    """Apply the standard discount."""\n'
                '    return price * 0.9\n'
            ),
            "test_main.py": (
                'from calc import discounted\n\n'
                'assert discounted(100) == 80, "standard discount is 20 percent"\n'
                'print("OK")\n'
            ),
        },
    },
    {
        "label": "numbered",
        # The target sits at a line number wide enough that a pasted-back
        # prefix is unmistakable. Nothing else about this task is hard.
        "prompt": ("parser.py has a bug: parse_port returns a string where it "
                   "should return an int. Fix it and run the tests."),
        "files": {
            "parser.py": (
                '"""Configuration parsing."""\n\n'
                'import re\n\n\n'
                'def parse_host(raw):\n'
                '    """Pull the host out of a host:port pair."""\n'
                '    return raw.split(":")[0]\n\n\n'
                'def parse_scheme(raw):\n'
                '    """Return the scheme, defaulting to http."""\n'
                '    if "://" not in raw:\n'
                '        return "http"\n'
                '    return raw.split("://")[0]\n\n\n'
                'def normalise(raw):\n'
                '    """Strip whitespace and trailing slashes."""\n'
                '    return raw.strip().rstrip("/")\n\n\n'
                'def parse_port(raw):\n'
                '    """Pull the port out of a host:port pair."""\n'
                '    return raw.split(":")[1]\n'
            ),
            "test_main.py": (
                'from parser import parse_port\n\n'
                'assert parse_port("localhost:8080") == 8080, "port must be an int"\n'
                'print("OK")\n'
            ),
        },
    },
    {
        "label": "dup-line",
        "prompt": ("In retry.py the backoff in send_batch doubles too "
                   "aggressively. Change the multiplier in send_batch only, "
                   "from 3 to 2. Leave the other functions alone. Run the tests."),
        "files": {
            "retry.py": (
                '"""Retry helpers."""\n\n\n'
                'def send_one(delay):\n'
                '    delay = delay * 3\n'
                '    return delay\n\n\n'
                'def send_many(delay):\n'
                '    delay = delay * 3\n'
                '    return delay\n\n\n'
                'def send_batch(delay):\n'
                '    delay = delay * 3\n'
                '    return delay\n'
            ),
            "test_main.py": (
                'from retry import send_one, send_many, send_batch\n\n'
                'assert send_batch(10) == 20, "batch backoff must double"\n'
                'assert send_one(10) == 30, "send_one must be untouched"\n'
                'assert send_many(10) == 30, "send_many must be untouched"\n'
                'print("OK")\n'
            ),
        },
    },
    {
        "label": "claude-md",
        "inject": CLAUDE_MD,
        "prompt": ("validate.py accepts a negative timeout. It should reject "
                   "anything below zero. Fix it and run the tests."),
        "files": {
            "CLAUDE.md": CLAUDE_MD,
            "errors.py": (
                '"""Project error types."""\n\n\n'
                'class ConfigError(Exception):\n'
                '    """Raised when configuration is invalid."""\n'
            ),
            "validate.py": (
                '"""Configuration validation."""\n\n\n'
                'def check_timeout(value):\n'
                '    """Validate a timeout in seconds."""\n'
                '    return value\n'
            ),
            "test_main.py": (
                'from errors import ConfigError\n'
                'from validate import check_timeout\n\n'
                'assert check_timeout(30) == 30\n'
                'try:\n'
                '    check_timeout(-1)\n'
                'except ConfigError:\n'
                '    pass\n'
                'except Exception as e:\n'
                '    raise AssertionError(\n'
                '        "must raise ConfigError, got " + type(e).__name__)\n'
                'else:\n'
                '    raise AssertionError("negative timeout must be rejected")\n'
                'print("OK")\n'
            ),
        },
    },
    {
        "label": "stale-edit",
        # Fires once, on the first Edit to totals.py: upstream renames the loop
        # variable, so any old_string carrying real context from the earlier
        # Read stops matching and the model must re-read. It must land INSIDE
        # the text the model is going to target - an earlier version of this
        # item mutated the module docstring instead, which left every realistic
        # old_string still matching and made the whole item inert. A model that
        # edits on a minimal old_string ("qty" alone) survives the rename and
        # passes, which is correct: the staleness is only supposed to bite the
        # wide-context edit, and that is the behaviour worth measuring.
        "stale": {"path": "totals.py",
                  "find": '    return sum(r["qty"] for r in rows)\n',
                  "repl": '    return sum(row["qty"] for row in rows)\n'},
        "prompt": ("totals.py sums the wrong field: it should total `amount`, "
                   "not `qty`. Fix it and run the tests."),
        "files": {
            "totals.py": (
                '"""Aggregation helpers."""\n\n\n'
                'def total(rows):\n'
                '    """Sum the amount across rows."""\n'
                '    return sum(r["qty"] for r in rows)\n'
            ),
            "test_main.py": (
                'from totals import total\n\n'
                'rows = [{"qty": 1, "amount": 10}, {"qty": 2, "amount": 5}]\n'
                'assert total(rows) == 15, "must sum amount"\n'
                'print("OK")\n'
            ),
        },
    },
    {
        "label": "no-collateral",
        "prompt": ("In report.py, fix summarise so it returns the mean instead "
                   "of the sum. Do not change anything else in the file. Run "
                   "the tests."),
        "files": {
            "report.py": (
                '"""Reporting."""\n\n\n'
                'def tally(xs):\n'
                '    t = 0\n'
                '    for x in xs:\n'
                '        t = t + x\n'
                '    return t\n\n\n'
                'def summarise(xs):\n'
                '    return sum(xs)\n\n\n'
                'def spread(xs):\n'
                '    lo = xs[0]\n'
                '    hi = xs[0]\n'
                '    for x in xs:\n'
                '        if x < lo:\n'
                '            lo = x\n'
                '        if x > hi:\n'
                '            hi = x\n'
                '    return hi - lo\n'
            ),
            "test_main.py": (
                'from report import summarise\n\n'
                'assert summarise([2, 4, 6]) == 4, "must return the mean"\n'
                'print("OK")\n'
            ),
        },
        # Byte-identical survival is checked against these exact bodies.
        "keep": ["tally", "spread"],
    },
]

SYSTEM = ("You are Claude Code, an interactive CLI tool that helps users with "
          "software engineering tasks. Use the provided tools to inspect and "
          "modify files, and verify your work by running the tests.\n\n"
          "IMPORTANT: You must use Read on a file before you Edit or overwrite "
          "it. Edit performs exact string replacement: old_string must match the "
          "file exactly including indentation, and must be unique unless you "
          "pass replace_all. Read returns content in `cat -n` format - strip the "
          "line number and tab prefix before using text as old_string.\n\n"
          "Prefer Grep over reading every file: context is limited. Make the "
          "smallest change that does the job and do not rewrite code you were "
          "not asked to change. Call Submit when you are done.")

TOOL_DEFS = [
    ("Read", "Read a file from the filesystem. Returns content in cat -n format "
             "(line number, tab, then the line). Optionally pass offset and limit.",
     {"file_path": {"type": "string"},
      "offset": {"type": "integer"},
      "limit": {"type": "integer"}}, ["file_path"]),
    ("Edit", "Exact string replacement in a file. You must Read the file first. "
             "old_string must match exactly including indentation, and must be "
             "unique in the file unless replace_all is true.",
     {"file_path": {"type": "string"},
      "old_string": {"type": "string"},
      "new_string": {"type": "string"},
      "replace_all": {"type": "boolean"}}, ["file_path", "old_string", "new_string"]),
    ("Write", "Write a file, overwriting if it exists. Overwriting a file you "
              "have not Read will fail.",
     {"file_path": {"type": "string"}, "content": {"type": "string"}},
     ["file_path", "content"]),
    ("Glob", "Fast file pattern matching. Returns matching paths.",
     {"pattern": {"type": "string"}}, ["pattern"]),
    ("Grep", "Search file contents with a regular expression. Returns matching "
             "lines as path:line:text. Far cheaper than reading every file.",
     {"pattern": {"type": "string"}, "glob": {"type": "string"}}, ["pattern"]),
    ("Bash", "Run a shell command. Supports ls, cat, grep and running the tests "
             "with 'python test_main.py'.",
     {"command": {"type": "string"}}, ["command"]),
    ("TodoWrite", "Record a structured task list for the current session.",
     {"todos": {"type": "array", "items": {"type": "string"}}}, ["todos"]),
    ("Submit", "Call when the task is done. Ends the session.",
     {"summary": {"type": "string"}}, ["summary"]),
]


def tools_anthropic():
    return [{"name": n, "description": d,
             "input_schema": {"type": "object", "properties": p, "required": r}}
            for n, d, p, r in TOOL_DEFS]


def tools_oai():
    return [{"type": "function", "function": {
                "name": n, "description": d,
                "parameters": {"type": "object", "properties": p, "required": r}}}
            for n, d, p, r in TOOL_DEFS]


def run_tests(files):
    """Materialise the in-memory repo and run its tests. Authoritative."""
    d = tempfile.mkdtemp(prefix="code-eval-cc-")
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


def post(path, payload, timeout=1800):
    req = urllib.request.Request(host + path,
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


def numbered(body, start=1):
    """cat -n rendering, matching what Claude Code's Read returns."""
    return "".join(f"{i:6d}\t{line}"
                   for i, line in enumerate(body.splitlines(True), start))


LINENO_RX = re.compile(r"^\s*\d+\t")


class Episode:
    def __init__(self, task):
        self.task = task
        self.files = dict(task["files"])
        self.turns = self.edmiss = self.botch = self.think = self.mutations = 0
        self.rbytes = self.denied = self.induced = self.todos = 0
        self.rbe = self.lineno = 0
        self.read = set()
        self.stale_fired = False

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
            # cat is not Read: it does not satisfy the read-before-edit
            # invariant, exactly as in the real client.
            return body
        if c.startswith("grep"):
            m = re.fullmatch(r"grep\s+(?:-[a-zA-Z]+\s+)*['\"]?(.+?)['\"]?(?:\s+(\S+))?", c)
            if m:
                return self.grep(m.group(1), None)
        self.denied += 1
        return (f"ERROR: '{c.split()[0] if c else cmd}' is not available in this "
                "sandbox. Available: ls, cat, grep, python test_main.py. "
                "Use Edit and Write to change files.")

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
        if name == "Glob":
            pat = args.get("pattern") or "*"
            hit = [p for p in sorted(self.files) if fnmatch.fnmatch(p, pat)]
            return "\n".join(hit) or "(no matches)"

        if name == "Grep":
            pat = args.get("pattern")
            if not pat:
                self.botch += 1
                return "ERROR: missing required field 'pattern'"
            return self.grep(pat, args.get("glob"))

        if name == "Read":
            path = args.get("file_path")
            if not path:
                self.botch += 1
                return "ERROR: missing required field 'file_path'"
            if path not in self.files:
                return f"ERROR: no such file: {path}"
            body = self.files[path]
            off, lim = args.get("offset"), args.get("limit")
            start = 1
            if off is not None or lim is not None:
                lines = body.splitlines(True)
                s = max(0, int(off or 0))
                body = "".join(lines[s:s + int(lim)] if lim else lines[s:])
                start = s + 1
            self.read.add(path)
            self.rbytes += len(body)
            return numbered(body, start)

        if name == "Edit":
            path = args.get("file_path")
            old, new = args.get("old_string"), args.get("new_string")
            if path is None or old is None or new is None:
                self.botch += 1
                return "ERROR: Edit needs file_path, old_string and new_string"
            if path not in self.files:
                self.edmiss += 1
                return f"ERROR: no such file: {path}"
            if path not in self.read:
                self.rbe += 1
                return ("ERROR: you must Read " + path + " before editing it.")

            # The Claude Code specific failure: old_string carrying the cat -n
            # prefix straight back from Read. Counted on its own so it never
            # inflates edmiss.
            if any(LINENO_RX.match(ln) for ln in old.splitlines()):
                self.lineno += 1
                return ("ERROR: old_string contains a line-number prefix from "
                        "Read output. Strip the line number and tab before "
                        "matching.")

            st = self.task.get("stale")
            if st and not self.stale_fired and path == st["path"]:
                self.stale_fired = True
                if st["find"] in self.files[path]:
                    self.files[path] = self.files[path].replace(st["find"], st["repl"], 1)
                    if old not in self.files[path]:
                        self.induced += 1
                        return ("ERROR: old_string not found in " + path +
                                ". The file has changed on disk since you last "
                                "read it. Re-read it and try again.")

            n = self.files[path].count(old)
            if n == 0:
                self.edmiss += 1
                return ("ERROR: old_string not found in " + path +
                        ". It must match the file exactly, including indentation.")
            if n > 1 and not args.get("replace_all"):
                self.edmiss += 1
                return (f"ERROR: old_string matches {n} times in {path}; it must "
                        "be unique, or pass replace_all.")
            count = n if args.get("replace_all") else 1
            self.files[path] = self.files[path].replace(old, new, count)
            self.mutations += 1
            return f"OK: edited {path}"

        if name == "Write":
            path, content = args.get("file_path"), args.get("content")
            if path is None or content is None:
                self.botch += 1
                return "ERROR: Write needs file_path and content"
            if path in self.files and path not in self.read:
                self.rbe += 1
                return ("ERROR: you must Read " + path + " before overwriting it.")
            self.files[path] = content
            self.read.add(path)
            self.mutations += 1
            return f"OK: wrote {path}"

        if name == "Bash":
            return self.sh(args.get("command") or "")

        if name == "TodoWrite":
            self.todos += 1
            return "OK: todos recorded"

        self.botch += 1
        return f"ERROR: unknown tool {name!r}"


def play_anthropic(task, ep, sysmsg):
    """Drive one task over /v1/messages, the way Claude Code talks to this box."""
    msgs = [{"role": "user", "content": task["prompt"]}]
    system = [{"type": "text", "text": sysmsg,
               "cache_control": {"type": "ephemeral"}}]

    while ep.turns < max_turns:
        ep.turns += 1
        r = post("/v1/messages",
                 {"model": alias, "system": system, "messages": msgs,
                  "tools": tools_anthropic(), "temperature": 0,
                  "max_tokens": max_tokens})
        blocks = r.get("content") or []
        for b in blocks:
            if b.get("type") == "thinking":
                ep.think += len(b.get("thinking") or "")
        uses = [b for b in blocks if b.get("type") == "tool_use"]
        if not uses:
            return "no-tool-call"
        msgs.append({"role": "assistant", "content": blocks})
        results = []
        for u in uses:
            if u.get("name") == "Submit":
                return "submitted"
            out = ep.dispatch(u.get("name"), u.get("input") or {})
            results.append({"type": "tool_result", "tool_use_id": u.get("id"),
                            "content": out})
        msgs.append({"role": "user", "content": results})
    return "turn-limit"


def play_oai(task, ep, sysmsg):
    """Same tasks over /v1/chat/completions, as a transport control."""
    msgs = [{"role": "system", "content": sysmsg},
            {"role": "user", "content": task["prompt"]}]

    while ep.turns < max_turns:
        ep.turns += 1
        r = post("/v1/chat/completions",
                 {"model": alias, "messages": msgs, "tools": tools_oai(),
                  "temperature": 0, "max_tokens": max_tokens})
        msg = r["choices"][0]["message"]
        ep.think += len(msg.get("reasoning_content") or "")
        calls = msg.get("tool_calls") or []
        if not calls:
            return "no-tool-call"
        msgs.append({"role": "assistant",
                     "content": msg.get("content") or "",
                     "tool_calls": calls})
        for c in calls:
            fn = c.get("function") or {}
            if fn.get("name") == "Submit":
                return "submitted"
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                ep.botch += 1
                args, out = {}, "ERROR: arguments were not valid JSON"
            else:
                out = ep.dispatch(fn.get("name"), args)
            msgs.append({"role": "tool", "tool_call_id": c.get("id"),
                         "content": out})
    return "turn-limit"


def play(task):
    ep = Episode(task)
    sysmsg = SYSTEM
    # The real client injects CLAUDE.md into the system prompt every session.
    if task.get("inject"):
        sysmsg += "\n\nProject conventions, from CLAUDE.md:\n" + task["inject"]
    runner = play_anthropic if transport == "anthropic" else play_oai
    ep.stop = runner(task, ep, sysmsg)
    return ep


def collateral_ok(task, files):
    """Every named function must survive byte-identical."""
    orig = task["files"]["report.py"]
    cur = files.get("report.py", "")
    for fn in task.get("keep", []):
        m = re.search(rf"def {fn}\(.*?(?=\n\ndef |\Z)", orig, re.S)
        if not m or m.group(0) not in cur:
            return False
    return True


print(f"alias={alias}  transport={transport}  max_turns={max_turns}")
print(f"{'task':<15s} {'res':>5s} {'time':>7s} {'turns':>6s} {'rbe':>4s} "
      f"{'lnum':>5s} {'edms':>5s} {'botch':>6s} {'read':>8s} {'think':>8s}")

tot = dict(s=0.0, turns=0, rbe=0, lineno=0, edmiss=0, botch=0, think=0,
           rbytes=0, induced=0, todos=0, denied=0)
passed = ran = 0

for task in TASKS:
    if only and not re.search(only, task["label"]):
        continue
    ran += 1
    t0 = time.monotonic()
    try:
        ep = play(task)
    except RuntimeError as e:
        print(f"{task['label']:<15s} {'ERR':>5s}  {e}")
        continue
    dt = time.monotonic() - t0
    ok, out = run_tests(ep.files)
    if ok and task["label"] == "no-collateral" and not collateral_ok(task, ep.files):
        ok, out = False, "collateral damage: an untouched function was rewritten"
    if ok:
        passed += 1
    tot["s"] += dt
    for k in ("turns", "rbe", "lineno", "edmiss", "botch", "think", "rbytes",
              "induced", "todos", "denied"):
        tot[k] += getattr(ep, k)
    print(f"{task['label']:<15s} {'PASS' if ok else 'FAIL':>5s} {dt:6.1f}s "
          f"{ep.turns:6d} {ep.rbe:4d} {ep.lineno:5d} {ep.edmiss:5d} "
          f"{ep.botch:6d} {ep.rbytes/1024:7.1f}K {ep.think:7d}c")
    if not ok:
        print(f"                 {out.splitlines()[-1][:100] if out else '(no output)'}")
    if ep.stop != "submitted":
        print(f"                 stop: {ep.stop}")

print(f"\n{alias} [{transport}]: {passed}/{ran} in {tot['s']:.0f}s, "
      f"{tot['turns']} turns, {tot['rbe']} read-before-edit, "
      f"{tot['lineno']} line-number, {tot['edmiss']} edit misses, "
      f"{tot['botch']} botched, {tot['rbytes']/1024:.1f}K read, "
      f"{tot['think']}c think, {tot['induced']} induced, {tot['todos']} todos")
PYEOF
