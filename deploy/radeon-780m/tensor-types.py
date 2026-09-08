#!/usr/bin/env python3
# Per-tensor quant-type breakdown for a GGUF, from the tensor-info table alone.
#
# gguf-header.py collapses tensors to unique name patterns and prints the type
# of the FIRST match, so a mixed-precision mix is invisible in its output: an
# APEX file whose routed experts run Q6_K / Q5_K / IQ4_XS across the block
# range prints as "all Q6_K". That reads as a uniform Q6_K file and is wrong by
# 5 GiB. This prints the type histogram and the per-block layout instead.
#
# Works on a range-fetched prefix, like the other two header tools.
#
#   curl -sL -r 0-52428800 -o /tmp/head.gguf "https://huggingface.co/<repo>/resolve/main/<f>.gguf"
#   ./tensor-types.py /tmp/head.gguf
#
# Compare "weights" against the real file size from the HF API before believing
# anything: a mismatch means an unknown quant type is being priced at F16.
import sys, struct, re, collections

FMT = {0:('<B',1),1:('<b',1),2:('<H',2),3:('<h',2),4:('<I',4),5:('<i',4),6:('<f',4),7:('<?',1),10:('<Q',8),11:('<q',8),12:('<d',8)}
QT = {0:'F32',1:'F16',2:'Q4_0',3:'Q4_1',6:'Q5_0',7:'Q5_1',8:'Q8_0',9:'Q8_1',10:'Q2_K',11:'Q3_K',12:'Q4_K',
      13:'Q5_K',14:'Q6_K',15:'Q8_K',16:'IQ2_XXS',17:'IQ2_XS',18:'IQ3_XXS',19:'IQ1_S',20:'IQ4_NL',
      21:'IQ3_S',22:'IQ2_S',23:'IQ4_XS',24:'I8',25:'I16',26:'I32',27:'I64',28:'F64',29:'IQ1_M',
      30:'BF16',34:'TQ1_0',35:'TQ2_0',39:'MXFP4'}
# same table as bytes-per-token.py - keep the two in step
BPW = {'F32':32.0,'F16':16.0,'BF16':16.0,'F64':64.0,'I8':8.0,'I16':16.0,'I32':32.0,'I64':64.0,
       'Q8_1':9.0,'Q8_0':8.5,'Q8_K':9.125,'Q6_K':6.5625,'Q5_1':6.0,'Q5_K':5.5,'Q5_0':5.5,
       'Q4_1':5.0,'Q4_K':4.5,'Q4_0':4.5,'Q3_K':3.4375,'Q2_K':2.625,
       'IQ4_NL':4.5,'IQ4_XS':4.25,'IQ3_S':3.4375,'IQ3_XXS':3.0625,'IQ2_S':2.5625,
       'IQ2_XS':2.3125,'IQ2_XXS':2.0625,'IQ1_M':1.75,'IQ1_S':1.5625,
       'TQ1_0':1.6875,'TQ2_0':2.0625,'MXFP4':4.25}

class R:
    def __init__(s, b): s.b = b; s.o = 0
    def raw(s, n):
        if s.o + n > len(s.b): raise EOFError
        v = s.b[s.o:s.o+n]; s.o += n; return v
    def sc(s, t):
        f, n = FMT[t]; return struct.unpack(f, s.raw(n))[0]
    def st(s):
        return s.raw(s.sc(10)).decode('utf-8', 'replace')
    def val(s, t):
        if t == 8: return s.st()
        if t == 9:
            et = s.sc(4); n = s.sc(10)
            if et == 8: return [s.st() for _ in range(n)]
            f, w = FMT[et]
            return list(struct.unpack('<%d%s' % (n, f[1]), s.raw(n*w)))
        return s.sc(t)

path = sys.argv[1]
r = R(open(path, 'rb').read())
assert r.raw(4) == b'GGUF', 'not a GGUF'
r.sc(4); ntensor = r.sc(10); nkv = r.sc(10)
for _ in range(nkv):
    r.st(); r.val(r.sc(4))

rows = []
try:
    for _ in range(ntensor):
        nm = r.st(); nd = r.sc(4); dims = [r.sc(10) for _ in range(nd)]
        qt = QT.get(r.sc(4), '?'); r.sc(10)
        rows.append((nm, dims, qt))
except EOFError:
    print('!! tensor table truncated after %d of %d entries' % (len(rows), ntensor))

tot = 0.0
byt = collections.Counter(); cnt = collections.Counter(); unknown = set()
for nm, dims, qt in rows:
    n = 1
    for d in dims: n *= d
    if qt not in BPW: unknown.add(qt)
    b = n * BPW.get(qt, 16.0) / 8.0
    tot += b; byt[qt] += b; cnt[qt] += 1

print('%s  tensors=%d of %d' % (path, len(rows), ntensor))
print('  file total weights: %.2f GiB' % (tot / 2**30))
print('--- type histogram ---')
for qt, b in byt.most_common():
    print('  %-8s %4d tensors  %8.2f GiB  %5.1f%%' % (qt, cnt[qt], b/2**30, 100*b/tot))
if unknown:
    print('  WARNING: unknown quant type(s) %s priced at F16 - fix the BPW table' % sorted(unknown))

print('--- per-block layout (contiguous runs) ---')
roles = collections.defaultdict(dict)
for nm, dims, qt in rows:
    m = re.match(r'blk\.(\d+)\.(.+)', nm)
    if m: roles[m.group(2)][int(m.group(1))] = qt
for role in sorted(roles):
    d = roles[role]; runs = []
    for k in sorted(d):
        if runs and runs[-1][2] == d[k] and runs[-1][1] == k - 1: runs[-1][1] = k
        else: runs.append([k, k, d[k]])
    if len(runs) == 1 and runs[0][0] == 0:
        s = 'all=%s' % runs[0][2]
    else:
        s = ' '.join(('%d-%d:%s' % (a, b, t)) if a != b else ('%d:%s' % (a, t)) for a, b, t in runs)
    print('  %-32s %s' % (role, s))

print('--- non-blk ---')
for nm, dims, qt in rows:
    if not nm.startswith('blk.'):
        print('  %-32s %-24s %s' % (nm, dims, qt))
