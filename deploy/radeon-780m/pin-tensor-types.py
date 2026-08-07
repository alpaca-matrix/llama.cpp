#!/usr/bin/env python3
"""Emit a llama-quantize --tensor-type-file that pins every tensor to the type it
already has, except the ones you retarget.

llama-quantize has no "change these tensors and copy the rest" mode: picking any
ftype re-derives a type for every tensor, and round-tripping an imatrix-built
IQ2_S expert through f32 and back loses the quality the imatrix bought. But
llama-quant.cpp skips a tensor entirely when its target type equals its current
type, so pinning the whole file and overriding a few names gets a byte-exact
copy everywhere else.

Why bother: on this box token generation is bandwidth-bound, so t/s is set by
the bytes read per token, and published mixes do not optimise for that. Laguna-S
2.1 UD-IQ3_S spends 41.6% of its per-token traffic on attn_q + attn_output at
Q6_K while the experts sit at IQ2_S - those two tensors are read in full every
token, the experts only 10/256 of the time.

    ./pin-tensor-types.py model.gguf attn_q=q5_K attn_output=q5_K > types.txt
    llama-quantize --allow-requantize --tensor-type-file types.txt \
        model.gguf out.gguf Q5_K_M

The ftype argument still matters: it must be a quantized type or llama-quantize
ignores --tensor-type overrides entirely. Every tensor is pinned, so which one
you pick has no other effect.

Retarget patterns are matched with re.search against the full tensor name, the
same way llama-quantize matches them, so "attn_q" hits every layer.
"""

import re
import sys
from pathlib import Path

# normally this file sits in the checkout, but it also gets copied around; look for
# gguf-py above it and then in the usual checkout path before giving up
for _root in list(Path(__file__).resolve().parents) + [Path("/root/llama.cpp")]:
    if (_root / "gguf-py" / "gguf").is_dir():
        sys.path.insert(0, str(_root / "gguf-py"))
        break

from gguf import GGUFReader  # noqa: E402


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)

    src = argv[1]
    retargets = []
    for arg in argv[2:]:
        if "=" not in arg:
            sys.exit("malformed retarget %r, expected <regex>=<ggml_type>" % arg)
        pattern, qtype = arg.rsplit("=", 1)
        retargets.append((re.compile(pattern), qtype))

    reader = GGUFReader(src)

    n_pinned = 0
    n_retargeted = 0
    for tensor in reader.tensors:
        cur = tensor.tensor_type.name
        # F32/F16/BF16 tensors are norms, biases and the expert router, none of which
        # llama-quantize touches. Pinning them would only add noise to the file.
        if not (cur.startswith("Q") or cur.startswith("IQ")):
            continue

        new = cur
        for pattern, qtype in retargets:
            if pattern.search(tensor.name):
                new = qtype
        if new != cur:
            n_retargeted += 1
        n_pinned += 1

        print("^%s$=%s" % (re.escape(tensor.name), new))

    print("pinned %d tensors, %d retargeted" % (n_pinned, n_retargeted), file=sys.stderr)
    if n_retargeted == 0:
        print("warning: nothing retargeted, the output would be a plain copy", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
