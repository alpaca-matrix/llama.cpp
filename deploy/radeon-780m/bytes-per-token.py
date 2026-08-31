#!/usr/bin/env python3
# Per-token active bytes from a GGUF tensor table. Expert tensors are weighted by
# expert_used_count / expert_count; token_embd-style tables are gathers and count
# as zero; everything else counts in full. Works on a range-fetched prefix.
import sys, struct, re
FMT = {0:('<B',1),1:('<b',1),2:('<H',2),3:('<h',2),4:('<I',4),5:('<i',4),6:('<f',4),7:('<?',1),10:('<Q',8),11:('<q',8),12:('<d',8)}
QT = {0:'F32',1:'F16',2:'Q4_0',3:'Q4_1',6:'Q5_0',7:'Q5_1',8:'Q8_0',9:'Q8_1',10:'Q2_K',11:'Q3_K',12:'Q4_K',
      13:'Q5_K',14:'Q6_K',15:'Q8_K',16:'IQ2_XXS',17:'IQ2_XS',18:'IQ3_XXS',19:'IQ1_S',20:'IQ4_NL',
      21:'IQ3_S',22:'IQ2_S',23:'IQ4_XS',24:'I8',25:'I16',26:'I32',27:'I64',28:'F64',29:'IQ1_M',
      30:'BF16',34:'TQ1_0',35:'TQ2_0',39:'MXFP4'}
BPW = {'F32':32.0,'F16':16.0,'BF16':16.0,'F64':64.0,'I8':8.0,'I16':16.0,'I32':32.0,'I64':64.0,
       'Q8_1':9.0,'Q8_0':8.5,'Q8_K':9.125,'Q6_K':6.5625,'Q5_1':6.0,'Q5_K':5.5,'Q5_0':5.5,
       'Q4_1':5.0,'Q4_K':4.5,'Q4_0':4.5,'Q3_K':3.4375,'Q2_K':2.625,
       'IQ4_NL':4.5,'IQ4_XS':4.25,'IQ3_S':3.4375,'IQ3_XXS':3.0625,'IQ2_S':2.5625,
       'IQ2_XS':2.3125,'IQ2_XXS':2.0625,'IQ1_M':1.75,'IQ1_S':1.5625,
       'TQ1_0':1.6875,'TQ2_0':2.0625,'MXFP4':4.25}

class R:
    def __init__(s,b): s.b=b; s.o=0
    def raw(s,n):
        if s.o+n>len(s.b): raise EOFError
        v=s.b[s.o:s.o+n]; s.o+=n; return v
    def sc(s,t):
        f,n=FMT[t]; return struct.unpack(f,s.raw(n))[0]
    def st(s):
        return s.raw(s.sc(10)).decode('utf-8','replace')
    def val(s,t):
        if t==8: return s.st()
        if t==9:
            et=s.sc(4); n=s.sc(10)
            if et==8: return [s.st() for _ in range(n)]
            f,w=FMT[et]; return list(struct.unpack('<%d%s'%(n,f[1]),s.raw(n*w)))
        return s.sc(t)

path=sys.argv[1]
r=R(open(path,'rb').read())
assert r.raw(4)==b'GGUF'
r.sc(4); ntensor=r.sc(10); nkv=r.sc(10)
kv={}
for _ in range(nkv):
    k=r.st(); t=r.sc(4); kv[k]=r.val(t)
arch=kv['general.architecture']
ec=kv.get(arch+'.expert_count',0); eu=kv.get(arch+'.expert_used_count',0)
frac = (eu/ec) if ec else 0.0
rows=[]
for _ in range(ntensor):
    nm=r.st(); nd=r.sc(4); dims=[r.sc(10) for _ in range(nd)]; qt=QT.get(r.sc(4),'?'); r.sc(10)
    rows.append((nm,dims,qt))

groups={}
tot_bytes=0.0; act_bytes=0.0; unknown=set()
for nm,dims,qt in rows:
    n=1
    for d in dims: n*=d
    if qt not in BPW: unknown.add(qt)
    b = n*BPW.get(qt,16.0)/8.0
    tot_bytes += b
    is_exp = '_exps' in nm
    # Embedding tables are gathers, not matmuls: a token reads a handful of rows,
    # not the table. Counting them in full priced Qwen3.8-Flash-Next's 26.8 GiB
    # n-gram PLE table as per-token traffic and inflated its active bytes 7x.
    # The LM head (output.weight) IS read in full and stays counted.
    is_lut = 'token_embd' in nm
    a = 0.0 if is_lut else (b*frac if is_exp else b)
    act_bytes += a
    g = re.sub(r'^blk\.\d+\.','blk.N.',nm)
    g = 'EXPERTS' if is_exp else ('ATTN' if '.attn' in g else ('EMBD/LUT' if is_lut else ('HEAD' if g.startswith('output') else ('DENSE_FFN' if '.ffn' in g else 'NORMS/MISC'))))
    e=groups.setdefault(g,[0.0,0.0,0]); e[0]+=b; e[1]+=a; e[2]+=1

print('%s  arch=%s  experts=%s top%s (active frac %.4f)' % (path, arch, ec or '-', eu or '-', frac))
print('  file total weights: %.2f GiB' % (tot_bytes/2**30))
print('  %-12s %12s %12s' % ('group','total GiB','active GB'))
for g,(b,a,c) in sorted(groups.items(), key=lambda x:-x[1][1]):
    print('  %-12s %12.3f %12.4f   (%d tensors)' % (g, b/2**30, a/1e9, c))
if unknown:
    print('  WARNING: unknown quant type(s) %s priced at F16 - fix the BPW table' % sorted(unknown))
print('  ACTIVE BYTES/TOKEN: %.3f GB  (EMBD/LUT excluded as gathers)' % (act_bytes/1e9))
gdn = any(k.endswith('.ssm.state_size') or k.endswith('.ssm.conv_kernel') for k in kv)
iq = any(t.startswith('IQ') for _,_,t in rows)
for bw in ((60.5,) if gdn else (70.0,)):
    c = bw/(act_bytes/1e9)
    # Band recalibrated 2026-08-31 against three points on this box, UNSPECULATED
    # and K-quant: balanced 1.00, fast 1.03, QCN-Q6_K 0.90 (the last assumes
    # nothing - it has no MTP head). The old 0.45-0.75 band compensated for the
    # over-counting fixed above; with real active bytes the model is near-exact.
    print('  tg ceiling @ %.1f GB/s%s: %.1f t/s   realised 0.85-1.05 -> %.1f - %.1f t/s'
          % (bw, ' (GDN hybrid)' if gdn else '', c, c*0.85, c*1.05))
    print('  NB: unspeculated. An MTP head adds ~30% on top; IQ-family types on')
    print('      routed experts run ~20% UNDER this prediction (2026-08-17).')
    if iq: print('  This file uses IQ-family types - apply that discount.')
