import re, statistics, math, collections
import sys
d = sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bench-compare'
def load(arm):
    r=collections.defaultdict(list)
    for ln in open(f"{d}/raw-{arm}.txt"):
        f=ln.split('\t'); r[f[0][9:]].append(float(f[2].split()[0]))
    return {k: statistics.median(v) for k,v in r.items()}
def lens(arm):
    r={}
    for ln in open(f"{d}/check-{arm}.txt"):
        if ln.startswith('#'): continue
        f=ln.split('\t'); r[f[0]]=int(f[1][4:].split()[0])
    return r
im,lw=load('image'),load('libwebp'); li,ll=lens('image'),lens('libwebp')
def cls(n):
    w,h=map(int,re.search(r'-(\d+)x(\d+)\.raw$',n).groups()); px=w*h
    return 'icon' if px<=4096 else '1mp' if px<=1<<20 else 'large'
for ours,theirs in ((5,6),(5,5),(6,6),(5,7),(4,6),(3,6)):
    files=[r.split('/',1)[1] for r in im if r.startswith(f"WebpEncodeZ{ours}/")]
    out=[]
    for c in ('icon','1mp','large','all'):
        sel=[f for f in files if c=='all' or cls(f)==c]
        sp=math.exp(sum(math.log(lw[f"WebpEncodeZ{theirs}/{f}"]/im[f"WebpEncodeZ{ours}/{f}"]) for f in sel)/len(sel))
        sz=sum(li[f"WebpEncodeZ{ours}/{f}"] for f in sel)/sum(ll[f"WebpEncodeZ{theirs}/{f}"] for f in sel)
        out.append(f"{c} speed {sp:.2f} size {sz:.3f}")
    print(f"ours z{ours} vs libwebp z{theirs}: "+"; ".join(out))
