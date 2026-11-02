import os, re, subprocess, math
R='/home/user/workspace/repo/bench/corpus-gen/netpbm/raw-rgb8/'
pick=[f for f in sorted(os.listdir(R)) if f.startswith(('photo_kodak','photo_tecnick','photo_wikipedia','test-dice','textures_plants-plant_02'))]
def run(*a): return subprocess.run(a, capture_output=True, text=True).stdout + subprocess.run(a, capture_output=True, text=True).stderr if False else subprocess.run(a, capture_output=True, text=True)
def dssim(src,jpg):
    subprocess.run(['djpeg','-outfile','/tmp/d3/dec2.ppm',jpg],check=True)
    r=subprocess.run(['magick','compare','-metric','SSIM',src,'/tmp/d3/dec2.ppm','null:'],capture_output=True,text=True)
    return float(re.search(r'\(([0-9.e-]+)\)',r.stderr+r.stdout).group(1))
def ours(src,q,prog,opt):
    subprocess.run(['/tmp/je/enc',src,'/tmp/d3/o2.jpg',str(q),'420',str(prog),str(opt)],check=True); return os.path.getsize('/tmp/d3/o2.jpg'), dssim(src,'/tmp/d3/o2.jpg')
def moz(src,q,mode,prog,opt):
    subprocess.run(['/tmp/je/mozt',src,str(q),'420',str(prog),str(opt),'1',mode,'/tmp/d3/m2.jpg'],check=True,capture_output=True); return os.path.getsize('/tmp/d3/m2.jpg'), dssim(src,'/tmp/d3/m2.jpg')
def at(curve,d):
    c=sorted(curve,key=lambda x:-x[1])  # decreasing dssim = increasing quality
    for (s0,d0),(s1,d1) in zip(c,c[1:]):
        if d1<=d<=d0:
            t=(math.log(d0)-math.log(d))/(math.log(d0)-math.log(d1)) if d0>d1 else 0
            return math.exp(math.log(s0)+t*(math.log(s1)-math.log(s0)))
    return None
T=[];M=[]
for f in pick:
    w,h=map(int,re.search(r'-(\d+)x(\d+)\.raw$',f).groups())
    src='/tmp/d3/src2.ppm'
    with open(src,'wb') as o: o.write(b'P6 %d %d 255\n'%(w,h)); o.write(open(R+f,'rb').read())
    qs=list(range(60,100,3))
    copt=[ours(src,q,0,1) for q in qs]; cprog=[ours(src,q,1,0) for q in qs]
    st,dt=moz(src,85,'trellis',0,1); sm,dm=moz(src,85,'max',0,0)
    so,do=ours(src,85,0,1)
    et=at(copt,dt); em=at(cprog,dm)
    if et: T.append(st/et)
    if em: M.append(sm/em)
    print(f"{f[:38]:38} q85 ours {so} {do:.5f} | trellis {st} {dt:.5f} eq {et and round(et)} | max {sm} {dm:.5f} eq-prog {em and round(em)}",flush=True)
g=lambda xs: math.exp(sum(map(math.log,xs))/len(xs))
print(f"equal SSIM: trellis vs ours-opt {100*(g(T)-1):+.1f}% (n={len(T)}); max vs ours-prog {100*(g(M)-1):+.1f}% (n={len(M)})")
