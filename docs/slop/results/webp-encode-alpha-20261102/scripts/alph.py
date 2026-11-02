import sys,struct
def alph(p):
    d=open(p,'rb').read(); i=12
    while i<len(d):
        t=d[i:i+4]; n=struct.unpack('<I',d[i+4:i+8])[0]
        if t==b'ALPH': return n, d[i+8]
        i+=8+n+(n&1)
    return 0,0
for p in sys.argv[1:]:
    n,h=alph(p); print(p.split('/')[-1], n, 'filter', (h>>2)&3, 'method', h&3)
