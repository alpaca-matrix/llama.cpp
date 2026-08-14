#!/bin/bash
# Vision, at the depth an agent client actually needs it.
#
# check-vision-tools.sh asks a model to name the colours in a four-quadrant
# square. That proves the mmproj is wired and nothing else, and it is the whole
# vision evidence behind at least one slot recommendation in candidates.md.
# Hermes Agent's screenshot tooling does not send colour swatches - it sends UI
# screenshots and expects the model to read them, compare them, and act on what
# it read. Those are three separate capabilities and none of them is tested by
# naming a red square.
#
# What this adds, in the order the capabilities get harder:
#
#   read     - a synthetic settings dialog with real rendered text. The model
#              must report a field value it can only get by reading pixels.
#              This is OCR-in-practice, the core screenshot-tooling skill.
#   locate   - which of two buttons is the primary (highlighted) one. Reading
#              plus spatial reasoning, which is what "click the right button"
#              needs.
#   compare  - two images, one changed field. The model must say WHICH changed.
#              Multi-image in a single message is its own capability: a model
#              can pass single-image tests and still collapse when given two,
#              and agent clients send before/after pairs constantly.
#   act      - read a value from the image, then call a tool with it. Vision
#              and tool calling in one turn is the actual agentic pattern, and
#              a model can pass both separately and fail the combination.
#
# Runs over /v1/messages by default, because that is the path Claude Code and
# Hermes use, and image blocks are shaped differently there (base64 `source`
# blocks) than in the OpenAI `image_url` form check-vision-tools.sh uses. A
# model can decode one and not the other. TRANSPORT=oai runs the same four
# items the OpenAI way, so a failure can be attributed to the transport rather
# than the model.
#
# There is no PIL on this box, so the PNGs are built from raw zlib/struct and
# the text is drawn with a 5x7 bitmap font defined below. Glyph coverage is
# deliberately limited to the characters these fixtures use - extend FONT if a
# new fixture needs a letter that is not there, and the renderer will raise
# rather than silently drawing blanks.
#
# usage: ./check-vision-agentic.sh <alias>
#   ./check-vision-agentic.sh fast
#   TRANSPORT=oai ./check-vision-agentic.sh nerkyor-eval
#   KEEP=/tmp/shots ./check-vision-agentic.sh fast     # dump the PNGs to look at
set -euo pipefail

ALIAS="${1:?model alias}"
HOST="${HOST:-http://127.0.0.1:8080}"
TRANSPORT="${TRANSPORT:-anthropic}"
KEEP="${KEEP:-}"

ALIAS="$ALIAS" HOST="$HOST" TRANSPORT="$TRANSPORT" KEEP="$KEEP" python3 <<'PYEOF'
import base64, json, os, re, struct, sys, urllib.request, zlib

alias, host = os.environ["ALIAS"], os.environ["HOST"]
transport = os.environ["TRANSPORT"]
keep = os.environ.get("KEEP") or ""
MAX_TOK = 1200

# --- 5x7 bitmap font --------------------------------------------------------
FONT = {
    "A": ".###.|#...#|#...#|#####|#...#|#...#|#...#",
    "B": "####.|#...#|#...#|####.|#...#|#...#|####.",
    "C": ".####|#....|#....|#....|#....|#....|.####",
    "D": "####.|#...#|#...#|#...#|#...#|#...#|####.",
    "E": "#####|#....|#....|####.|#....|#....|#####",
    "F": "#####|#....|#....|####.|#....|#....|#....",
    "G": ".####|#....|#....|#..##|#...#|#...#|.####",
    "H": "#...#|#...#|#...#|#####|#...#|#...#|#...#",
    "I": "#####|..#..|..#..|..#..|..#..|..#..|#####",
    "L": "#....|#....|#....|#....|#....|#....|#####",
    "N": "#...#|##..#|##..#|#.#.#|#..##|#..##|#...#",
    "O": ".###.|#...#|#...#|#...#|#...#|#...#|.###.",
    "P": "####.|#...#|#...#|####.|#....|#....|#....",
    "R": "####.|#...#|#...#|####.|#.#..|#..#.|#...#",
    "S": ".####|#....|#....|.###.|....#|....#|####.",
    "T": "#####|..#..|..#..|..#..|..#..|..#..|..#..",
    "U": "#...#|#...#|#...#|#...#|#...#|#...#|.###.",
    "V": "#...#|#...#|#...#|#...#|#...#|.#.#.|..#..",
    "0": ".###.|#...#|#..##|#.#.#|##..#|#...#|.###.",
    "1": "..#..|.##..|..#..|..#..|..#..|..#..|.###.",
    "2": ".###.|#...#|....#|...#.|..#..|.#...|#####",
    "3": "####.|....#|....#|.###.|....#|....#|####.",
    "4": "#...#|#...#|#...#|#####|....#|....#|....#",
    "5": "#####|#....|#....|####.|....#|....#|####.",
    "7": "#####|....#|...#.|..#..|.#...|.#...|.#...",
    "8": ".###.|#...#|#...#|.###.|#...#|#...#|.###.",
    "9": ".###.|#...#|#...#|.####|....#|....#|.###.",
    " ": ".....|.....|.....|.....|.....|.....|.....",
}


class Canvas:
    def __init__(self, w, h, bg=(235, 235, 235)):
        self.w, self.h = w, h
        self.px = [[bg for _ in range(w)] for _ in range(h)]

    def rect(self, x, y, w, h, col, fill=True):
        for j in range(y, min(y + h, self.h)):
            for i in range(x, min(x + w, self.w)):
                if fill or j in (y, y + h - 1) or i in (x, x + w - 1):
                    if 0 <= i < self.w and 0 <= j < self.h:
                        self.px[j][i] = col

    def text(self, x, y, s, col=(20, 20, 20), scale=2):
        cx = x
        for ch in s.upper():
            if ch not in FONT:
                raise SystemExit(f"FONT has no glyph for {ch!r}; extend it")
            rows = FONT[ch].split("|")
            for j, row in enumerate(rows):
                for i, bit in enumerate(row):
                    if bit != "#":
                        continue
                    for dy in range(scale):
                        for dx in range(scale):
                            px, py = cx + i * scale + dx, y + j * scale + dy
                            if 0 <= px < self.w and 0 <= py < self.h:
                                self.px[py][px] = col
            cx += (5 + 1) * scale

    def png(self):
        raw = b"".join(b"\x00" + b"".join(bytes(p) for p in row) for row in self.px)
        def chunk(tag, data):
            c = struct.pack(">I", len(data)) + tag + data
            return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9))
                + chunk(b"IEND", b""))


BLUE = (40, 90, 200)
GREY = (170, 170, 170)
WHITE = (255, 255, 255)
DARK = (30, 30, 30)


def dialog(port="8080", debug="ON", primary="save"):
    """A settings dialog. `primary` decides which button is highlighted."""
    c = Canvas(420, 240)
    c.rect(0, 0, 420, 40, (70, 70, 90))
    c.text(14, 12, "SETTINGS", WHITE, 2)
    c.rect(20, 70, 380, 40, WHITE)
    c.rect(20, 70, 380, 40, GREY, fill=False)
    c.text(32, 82, "PORT", DARK, 2)
    c.text(150, 82, port, DARK, 2)
    c.rect(20, 125, 380, 40, WHITE)
    c.rect(20, 125, 380, 40, GREY, fill=False)
    c.text(32, 137, "DEBUG", DARK, 2)
    c.text(150, 137, debug, DARK, 2)
    save_col = BLUE if primary == "save" else GREY
    cancel_col = BLUE if primary == "cancel" else GREY
    c.rect(210, 185, 85, 36, save_col)
    c.text(224, 195, "SAVE", WHITE, 2)
    c.rect(305, 185, 95, 36, cancel_col)
    c.text(315, 195, "CANCEL", WHITE, 2)
    return c.png()


def b64(p):
    return base64.b64encode(p).decode()


def post(path, payload, timeout=600):
    req = urllib.request.Request(host + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def ask(images, prompt, tools=None):
    """Send N images plus a prompt. Returns (text, tool_name, tool_args)."""
    if transport == "anthropic":
        content = [{"type": "image",
                    "source": {"type": "base64", "media_type": "image/png",
                               "data": b64(p)}} for p in images]
        content.append({"type": "text", "text": prompt})
        body = {"model": alias, "max_tokens": MAX_TOK, "temperature": 0,
                "messages": [{"role": "user", "content": content}]}
        if tools:
            body["tools"] = tools
        r = post("/v1/messages", body)
        text, tname, targs = "", None, None
        for b in r.get("content") or []:
            if b.get("type") == "text":
                text += b.get("text") or ""
            elif b.get("type") == "tool_use":
                tname, targs = b.get("name"), b.get("input") or {}
        return text, tname, targs

    content = [{"type": "image_url",
                "image_url": {"url": "data:image/png;base64," + b64(p)}}
               for p in images]
    content.append({"type": "text", "text": prompt})
    body = {"model": alias, "max_tokens": MAX_TOK, "temperature": 0,
            "messages": [{"role": "user", "content": content}]}
    if tools:
        body["tools"] = [{"type": "function",
                          "function": {"name": t["name"],
                                       "description": t["description"],
                                       "parameters": t["input_schema"]}}
                         for t in tools]
    r = post("/v1/chat/completions", body)
    msg = r["choices"][0]["message"]
    text = msg.get("content") or ""
    tname, targs = None, None
    for c in msg.get("tool_calls") or []:
        fn = c.get("function") or {}
        tname = fn.get("name")
        try:
            targs = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            targs = {}
    return text, tname, targs


base = dialog()
changed = dialog(port="8080", debug="OFF")
cancel_primary = dialog(primary="cancel")

if keep:
    os.makedirs(keep, exist_ok=True)
    for name, blob in (("base", base), ("changed", changed),
                       ("cancel", cancel_primary)):
        with open(os.path.join(keep, name + ".png"), "wb") as fh:
            fh.write(blob)
    print(f"wrote fixtures to {keep}")

SET_TOOL = [{"name": "apply_port",
             "description": "Apply a port number to the running configuration",
             "input_schema": {"type": "object",
                              "properties": {"port": {"type": "integer"}},
                              "required": ["port"]}}]

print(f"alias={alias}  transport={transport}")
results = []

# 1. read
txt, _, _ = ask([base], "This is a screenshot of a settings dialog. What is the "
                        "PORT value shown? Reply with just the number.")
ok = bool(re.search(r"8080", txt))
results.append(("read", ok, txt.strip()[-90:]))

# 2. locate
txt, _, _ = ask([base], "In this settings dialog, two buttons are shown. One is "
                        "highlighted in blue and one is grey. Which button is the "
                        "blue one? Reply with just the button label.")
ok = bool(re.search(r"\bsave\b", txt, re.I)) and not re.search(r"\bcancel\b", txt, re.I)
results.append(("locate", ok, txt.strip()[-90:]))

# 3. compare
txt, _, _ = ask([base, changed],
                "These are two screenshots of the same dialog taken at different "
                "times. Exactly one field's value differs. Which field changed? "
                "Reply with just the field name.")
ok = bool(re.search(r"debug", txt, re.I)) and not re.search(r"\bport\b", txt, re.I)
results.append(("compare", ok, txt.strip()[-90:]))

# 4. act
txt, tname, targs = ask([base],
                        "Read the PORT value from this settings screenshot and "
                        "apply it using the apply_port tool.", tools=SET_TOOL)
ok = tname == "apply_port" and str((targs or {}).get("port")) == "8080"
results.append(("act", ok, f"tool={tname} args={targs}"))

print(f"{'item':<10s} {'result':>7s}  detail")
for name, ok, detail in results:
    print(f"{name:<10s} {'PASS' if ok else 'FAIL':>7s}  {detail}")
passed = sum(1 for _, ok, _ in results if ok)
print(f"\n{alias} [{transport}]: {passed}/{len(results)}")
PYEOF
