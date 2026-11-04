import statistics as st, math, collections, sys
def load(f):
    d=collections.defaultdict(list)
    for line in open(f):
        if not line.startswith('Benchmark'): continue
        p=line.split('\t')
        d[p[0]].append(float(p[2].split()[0]))
    return d
a=load(sys.argv[1]); b=load(sys.argv[2])
ops=collections.defaultdict(list)
for k in a:
    if k not in b: continue
    op=k[len('Benchmark'):].split('/')[0]
    ops[op].append(st.median(a[k])/st.median(b[k]))
for op,rs in ops.items():
    g=math.exp(sum(map(math.log,rs))/len(rs))
    print(f"{op:24s} n={len(rs):3d}  0.17/0.16 MP/s geomean {g:.3f}  (min {min(rs):.3f}, max {max(rs):.3f})")
allr=[r for rs in ops.values() for r in rs]
print(f"{'all':24s} n={len(allr):3d}  {math.exp(sum(map(math.log,allr))/len(allr)):.3f}")
