import sys, statistics as st, math, collections
def load(p):
    d=collections.defaultdict(list)
    for l in open(p):
        f=l.split('\t'); d[f[0]].append(float(f[-1].split()[0]))
    return d
A=load(sys.argv[1]+'/ab-A.txt'); B=load(sys.argv[1]+'/ab-B.txt')
ops=collections.defaultdict(list)
for k in A:
    op=k.split('/')[0].replace('Benchmark','')
    name=k.split('/',1)[1]
    try: dims=name.rsplit('-',1)[1].split('.')[0]; w,h=map(int,dims.split('x')); px=w*h
    except: px=0
    cls='icon' if px<=4096 else '1mp' if px<=1<<20 else 'large'
    r=st.median(B[k])/st.median(A[k])
    ops[op].append((r,cls,name)); ops[op+'/'+cls].append((r,cls,name))
for op in sorted(ops):
    rs=ops[op]; g=math.exp(sum(math.log(r) for r,_,_ in rs)/len(rs))
    lo=min(rs); hi=max(rs)
    print(f"{op:32s} rows {len(rs):3d}  B/A {g:.3f}  min {lo[0]:.3f} ({lo[2][:30]})  max {hi[0]:.3f} ({hi[2][:30]})")
