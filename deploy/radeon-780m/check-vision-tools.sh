#!/bin/bash
# Smoke-test the two capabilities an agent client actually needs from a model:
# tool calling and image input. Throughput says nothing about either, and a
# model that benchmarks well but cannot emit a tool call is useless to Hermes
# Agent or Claude Code. Run this whenever a model alias changes.
#
# usage: ./check-vision-tools.sh <alias>
set -euo pipefail

ALIAS="${1:?model alias}"
HOST="${HOST:-http://127.0.0.1:8080}"

ALIAS="$ALIAS" HOST="$HOST" python3 <<'PYEOF'
import base64, json, os, struct, urllib.request, zlib

alias, host = os.environ["ALIAS"], os.environ["HOST"]

# Thinking models emit reasoning before the answer, so a small budget returns
# empty content and looks exactly like a capability failure. 200 tokens was
# enough to make `fast` appear to have no tool support at all.
MAX_TOK = 1200

def post(path, payload, timeout=600):
    req = urllib.request.Request(host + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))

# --- 1. tool calling -------------------------------------------------------
tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
}]
r = post("/v1/chat/completions", {
    "model": alias, "max_tokens": MAX_TOK, "tools": tools, "temperature": 0,
    "messages": [{"role": "user", "content": "What is the weather in Manila right now?"}],
})
msg = r["choices"][0]["message"]
calls = msg.get("tool_calls") or []
if calls:
    fn = calls[0]["function"]
    print(f"tool calling : PASS  -> {fn['name']}({fn.get('arguments','')[:60]})")
else:
    print(f"tool calling : FAIL  -> no tool_calls; content={(msg.get('content') or '')[:80]!r}")

# --- 2. vision -------------------------------------------------------------
# 64x64 PNG, four quadrants: red, green / blue, white. Built with zlib only so
# the check has no dependency on PIL, which is not installed on the LXC.
W = H = 64
quad = [((255, 0, 0), (0, 255, 0)), ((0, 0, 255), (255, 255, 255))]
raw = b"".join(
    b"\x00" + b"".join(bytes(quad[y // 32][x // 32]) for x in range(W))
    for y in range(H)
)
def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw))
       + chunk(b"IEND", b""))
b64 = base64.b64encode(png).decode()

try:
    r = post("/v1/chat/completions", {
        "model": alias, "max_tokens": MAX_TOK, "temperature": 0,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": "This image has four quadrants. Name the colour of each, top-left first."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
        ]}],
    })
    out = (r["choices"][0]["message"].get("content") or "").strip().replace("\n", " ")
    seen = [c for c in ("red", "green", "blue", "white") if c in out.lower()]
    verdict = "PASS" if len(seen) >= 3 else "WEAK"
    print(f"vision       : {verdict}  -> saw {seen}; {out[:100]!r}")
except urllib.error.HTTPError as e:
    print(f"vision       : FAIL  -> HTTP {e.code} (no mmproj loaded?)")
PYEOF
