#!/bin/bash
# Download a GGUF from Hugging Face and verify its SHA256 against the API.
#
# Why this exists: parallel downloaders against HF's Xet CDN can return a file
# of the correct length with damaged bytes. A damaged GGUF still loads, still
# reports the right tensor shapes, and still benchmarks at full speed - it just
# emits gibberish. Always verify.
#
# usage: ./fetch-model.sh <repo> <remote-file> [out-file] [dest-dir]
#   ./fetch-model.sh ggml-org/gpt-oss-120b-GGUF gpt-oss-120b-MXFP4.gguf
set -euo pipefail

REPO="${1:?repo, e.g. ggml-org/gpt-oss-120b-GGUF}"
REMOTE="${2:?remote filename}"
OUT="${3:-$REMOTE}"
DEST="${4:-/root/models}"
VENV="${VENV:-/root/hfenv}"

mkdir -p "$DEST"
cd "$DEST"

expected=$(curl -s "https://huggingface.co/api/models/$REPO/tree/main?recursive=true" \
  | python3 -c "
import sys, json
for f in json.load(sys.stdin):
    if f.get('path') == '$REMOTE':
        print((f.get('lfs') or {}).get('oid', ''))
        break
")
if [ -z "$expected" ]; then
  echo "could not resolve sha256 for $REPO/$REMOTE" >&2
  exit 1
fi
echo "expected sha256: $expected"

verify() {
  [ -f "$OUT" ] || return 1
  local actual
  actual=$(sha256sum "$OUT" | awk '{print $1}')
  [ "$actual" = "$expected" ]
}

if verify; then
  echo "already present and verified: $OUT"
  exit 0
fi

# Attempt 1-2: aria2 with few connections (fast). Many connections against the
# Xet CDN triggers signed-URL expiry storms and corrupts the result.
for attempt in 1 2; do
  echo "== aria2 attempt $attempt =="
  rm -f "$OUT" "$OUT.aria2"
  aria2c -x4 -s4 -k 32M -c --console-log-level=error --summary-interval=0 \
         --auto-file-renaming=false --allow-overwrite=true \
         --max-tries=5 --retry-wait=10 \
         -o "$OUT" "https://huggingface.co/$REPO/resolve/main/$REMOTE" || true
  # aria2 can stall a few MiB short holding an expired URL; top off with curl
  curl -sL -C - -o "$OUT" "https://huggingface.co/$REPO/resolve/main/$REMOTE" || true
  if verify; then echo "VERIFIED $OUT"; exit 0; fi
  echo "checksum mismatch"
done

# Fallback: HF client does chunk-level integrity checking. Slower but reliable.
echo "== falling back to hf client =="
if [ ! -x "$VENV/bin/hf" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -U huggingface_hub hf_xet
fi
rm -f "$OUT"
"$VENV/bin/hf" download "$REPO" "$REMOTE" --local-dir "$DEST/_dl"
mv -f "$DEST/_dl/$REMOTE" "$DEST/$OUT"
rmdir "$DEST/_dl" 2>/dev/null || true

if verify; then
  echo "VERIFIED $OUT"
else
  echo "STILL CORRUPT after all methods: $OUT" >&2
  exit 1
fi
