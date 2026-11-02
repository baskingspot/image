import os, re, subprocess, sys, glob
R='/home/user/workspace/repo/bench/corpus-gen/netpbm/raw-rgb8/'
pick=[f for f in sorted(os.listdir(R)) if f.startswith(('photo_','screenshot_web','textures_plants-plant_02','test-dice','test-wikipedia'))]
def run(*a): return subprocess.run(a, capture_output=True, text=True, check=True).stdout
def psnr(src, jpg):
    run('djpeg','-outfile','/tmp/d3/dec.ppm',jpg); return float(run('/tmp/d3/psnr',src,'/tmp/d3/dec.ppm'))
def ours(src,q,prog,opt):
    run('/tmp/je/enc',src,'/tmp/d3/o.jpg',str(q),'420',str(prog),str(opt)); return os.path.getsize('/tmp/d3/o.jpg'), psnr(src,'/tmp/d3/o.jpg')
def moz(src,q,mode,prog,opt):
    run('/tmp/je/mozt',src,str(q),'420',str(prog),str(opt),'1',mode,'/tmp/d3/m.jpg'); return os.path.getsize('/tmp/d3/m.jpg'), psnr(src,'/tmp/d3/m.jpg')
def at(curve, p):
    # our size at PSNR p, linear in log size between neighbours
    import math
    c=sorted(curve,key=lambda x:x[1])
    for (s0,p0),(s1,p1) in zip(c,c[1:]):
        if p0<=p<=p1:
            t=(p-p0)/(p1-p0) if p1>p0 else 0
            return math.exp(math.log(s0)+t*(math.log(s1)-math.log(s0)))
    return None
rows=[]
for f in pick:
    w,h=map(int,re.search(r'-(\d+)x(\d+)\.raw$',f).groups())
    src='/tmp/d3/src.ppm'
    with open(src,'wb') as o: o.write(b'P6 %d %d 255\n'%(w,h)); o.write(open(R+f,'rb').read())
    qs=list(range(30,100,3))+[100]
    copt=[ours(src,q,0,1) for q in qs]; cprog=[ours(src,q,1,0) for q in qs]
    for q in (75,85,95):
        so,po=ours(src,q,0,1)
        st,pt=moz(src,q,'trellis',0,1)
        sm,pm=moz(src,q,'max',0,0)
        eqt=at(copt,pt); eqm=at(cprog,pm)
        rows.append((f,q,so,po,st,pt,eqt,sm,pm,eqm))
        print(f"{f[:40]:40} q{q} ours {so} {po:.2f} | trellis {st} {pt:.2f} eq-ours {eqt and round(eqt)} | max {sm} {pm:.2f} eq-ours-prog {eqm and round(eqm)}", flush=True)
import json; json.dump(rows, open('/tmp/d3/rows.json','w'))
