#!/usr/bin/env python3
# Header-only GGUF reader: parses KV block + tensor info table from a truncated file.
import sys, struct, re

GT = {0:'u8',1:'i8',2:'u16',3:'i16',4:'u32',5:'i32',6:'f32',7:'bool',8:'str',9:'arr',10:'u64',11:'i64',12:'f64'}
FMT = {0:('<B',1),1:('<b',1),2:('<H',2),3:('<h',2),4:('<I',4),5:('<i',4),6:('<f',4),7:('<?',1),10:('<Q',8),11:('<q',8),12:('<d',8)}
QT = {0:'F32',1:'F16',2:'Q4_0',3:'Q4_1',6:'Q5_0',7:'Q5_1',8:'Q8_0',9:'Q8_1',10:'Q2_K',11:'Q3_K',12:'Q4_K',13:'Q5_K',14:'Q6_K',15:'Q8_K',
      16:'IQ2_XXS',17:'IQ2_XS',18:'IQ3_XXS',19:'IQ1_S',20:'IQ4_NL',21:'IQ3_S',22:'IQ2_S',23:'IQ4_XS',24:'I8',25:'I16',26:'I32',27:'I64',
      28:'F64',29:'IQ1_M',30:'BF16',34:'TQ1_0',35:'TQ2_0',39:'MXFP4'}

class R:
    def __init__(s, b): s.b = b; s.o = 0
    def raw(s, n):
        if s.o + n > len(s.b): raise EOFError
        v = s.b[s.o:s.o+n]; s.o += n; return v
    def sc(s, t):
        f, n = FMT[t]; return struct.unpack(f, s.raw(n))[0]
    def st(s):
        n = s.sc(10); return s.raw(n).decode('utf-8', 'replace')
    def val(s, t):
        if t == 8: return s.st()
        if t == 9:
            et = s.sc(4); n = s.sc(10)
            if et == 8: return [s.st() for _ in range(n)]
            f, w = FMT[et]
            return list(struct.unpack('<%d%s' % (n, f[1]), s.raw(n*w)))
        return s.sc(t)

data = open(sys.argv[1], 'rb').read()
r = R(data)
assert r.raw(4) == b'GGUF', 'not a GGUF'
ver = r.sc(4); ntensor = r.sc(10); nkv = r.sc(10)
print('gguf v%d  tensors=%d  kv=%d' % (ver, ntensor, nkv))
kv = {}
for _ in range(nkv):
    k = r.st(); t = r.sc(4); v = r.val(t)
    kv[k] = (GT.get(t, t), v)

SKIP = ('tokenizer.ggml.tokens', 'tokenizer.ggml.scores', 'tokenizer.ggml.token_type', 'tokenizer.ggml.merges')
print('--- KV ---')
for k, (t, v) in kv.items():
    if k in SKIP:
        print('  %-52s %-5s [len %d]' % (k, t, len(v)))
    elif k == 'tokenizer.chat_template':
        print('  %-52s %-5s [len %d chars]' % (k, t, len(v)))
    else:
        sv = repr(v)
        if len(sv) > 160: sv = sv[:160] + '...'
        print('  %-52s %-5s %s' % (k, t, sv))

# tensor info table
names = []
try:
    for _ in range(ntensor):
        nm = r.st(); nd = r.sc(4)
        dims = [r.sc(10) for _ in range(nd)]
        qt = r.sc(4); off = r.sc(10)
        names.append((nm, dims, QT.get(qt, str(qt))))
except EOFError:
    print('!! tensor table truncated after %d of %d entries' % (len(names), ntensor))

print('--- tensor table: %d of %d read ---' % (len(names), ntensor))
blocks = sorted({int(m.group(1)) for nm, _, _ in names for m in [re.match(r'blk\.(\d+)\.', nm)] if m})
print('  blk indices present: %s' % (('%d..%d' % (blocks[0], blocks[-1])) if blocks else 'none'))
if blocks and blocks[-1] - blocks[0] + 1 != len(blocks):
    print('  NOTE non-contiguous: %s' % blocks)
pats = {}
for nm, dims, qt in names:
    p = re.sub(r'\.\d+\.', '.N.', nm)
    pats.setdefault(p, []).append((dims, qt))
print('--- unique tensor name patterns (%d) ---' % len(pats))
for p, v in pats.items():
    print('  %-46s x%-4d %s %s' % (p, len(v), v[0][0], v[0][1]))
