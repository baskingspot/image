import sys,struct,glob,os,subprocess
# splice.py EFFORT: our ALPH streams into cwebp's -m 4 files, decoded by dwebp, alpha compared with the plane.
k=sys.argv[1]; bad=0; n=0
for vp in sorted(glob.glob(f'vp8l/{k}/*.vp8l')):
    stem=os.path.basename(vp)[:-5]
    name=stem.rsplit('-',1)[0]
    lw=f'lw/m4-fast-{name}.webp'
    d=open(lw,'rb').read(); out=b''; i=12
    body=b'\x01'+open(vp,'rb').read()
    while i<len(d):
        t=d[i:i+4]; ln=struct.unpack('<I',d[i+4:i+8])[0]; pay=d[i+8:i+8+ln]
        if t==b'ALPH': pay=body
        out+=t+struct.pack('<I',len(pay))+pay+(b'\0' if len(pay)&1 else b'')
        i+=8+ln+(ln&1)
    out=b'RIFF'+struct.pack('<I',len(out)+4)+b'WEBP'+out
    f=f'sp/{stem}.webp'; open(f,'wb').write(out)
    subprocess.run(['dwebp','-quiet','-pam',f,'-o','sp/x.pam'],check=True)
    pam=open('sp/x.pam','rb').read(); hdr=pam.index(b'ENDHDR\n')+7; rgba=pam[hdr:]
    plane=open(f'planes/{stem}.a8','rb').read()
    n+=1
    if rgba[3::4]!=plane: bad+=1; print('MISMATCH',stem)
print(f'effort {k}: {n} planes, {bad} mismatches')
