import sys
def bits_of(b):
    return [(byte >> i) & 1 for byte in b for i in range(8)]
def bytes_of(bits):
    while len(bits) % 8: bits.append(0)
    return bytes(sum(bits[i+j] << j for j in range(8)) for i in range(0, len(bits), 8))
def put(out, v, n):
    for i in range(n): out.append((v >> i) & 1)
def get(bits, pos, n):
    return sum(bits[pos+i] << i for i in range(n)), pos + n
def u32d(bits, pos):
    sel, pos = get(bits, pos, 2)
    n, off = [(10,0),(14,1024),(22,17408),(30,4211712)][sel]
    v, pos = get(bits, pos, n); return v + off, pos
def put_u32d(out, v):
    for sel,(n,off) in enumerate([(10,0),(14,1024),(22,17408),(30,4211712)]):
        if v - off < (1 << n): put(out, sel, 2); put(out, v - off, n); return
src = bits_of(open(sys.argv[1],'rb').read()); s0, s1 = int(sys.argv[2]), int(sys.argv[3])
spl = src[s0:s1]
tb = open(sys.argv[4],'rb').read(); t = bits_of(tb)
fh_start, fh_end, nsec = int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
flags_at = fh_start + 4
sel, p2 = get(t, flags_at, 2)
if sel == 0: old = 0
elif sel == 1: v, p2 = get(t, p2, 4); old = 1 + v
else: assert sel == 2; v, p2 = get(t, p2, 8); old = 17 + v
assert old & 16 == 0 and old & 8 == 0  # no splines yet, no patches before them
new = old | 16
out = t[:flags_at]
if new <= 16: put(out, 1, 2); put(out, new - 1, 4)
else: put(out, 2, 2); put(out, new - 17, 8)
out += t[p2:fh_end]
pos = fh_end
perm, pos = get(t, pos, 1); assert perm == 0
pos = (pos + 7) // 8 * 8
sizes = []
for _ in range(nsec):
    v, pos = u32d(t, pos); sizes.append(v)
pos = (pos + 7) // 8 * 8
data = tb[pos // 8:]
lfg = bits_of(data[:sizes[0]])
newlfg = bytes_of(spl + lfg)
put(out, 0, 1)
while len(out) % 8: out.append(0)
for i, sz in enumerate(sizes): put_u32d(out, len(newlfg) if i == 0 else sz)
while len(out) % 8: out.append(0)
res = bytes_of(out) + newlfg + data[sizes[0]:]
open(sys.argv[8], 'wb').write(res)
print(sizes[0], len(newlfg), len(res))
