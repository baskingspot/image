# paired.py DIR A B: each row's median over rounds of B's time over A's in
# the same round, with its range, and geometric means by size class.
import sys, re, math, statistics as st
d, a, b = sys.argv[1:4]
def load(arm):
    rows = {}
    for line in open(f"{d}/{arm}.txt"):
        f = line.split("\t")
        if len(f) < 3 or not f[0].startswith("Benchmark"): continue
        rows.setdefault(f[0], []).append(float(f[2].split()[0]))
    return rows
ra, rb = load(a), load(b)
out = []
classes = {"rotating icons (3)": [], "icons <= 64x64": [], "to 1 MP": [], "over 1 MP": []}
for name in ra:
    ta, tb = ra[name], rb[name]
    n = min(len(ta), len(tb))
    rs = [tb[i] / ta[i] for i in range(n)]
    med = st.median(rs)
    w, h = map(int, re.search(r"-(\d+)x(\d+)", name).groups())
    px = w * h
    if "Icons" in name: c = "rotating icons (3)"
    elif px <= 64 * 64: c = "icons <= 64x64"
    elif px <= 1 << 20: c = "to 1 MP"
    else: c = "over 1 MP"
    classes[c].append(med)
    out.append(f"{name}\t{med:.4f}\t[{min(rs):.4f}, {max(rs):.4f}]\tn={n}")
print("\n".join(out))
print()
allr = []
for c, v in classes.items():
    if v:
        g = math.exp(sum(map(math.log, v)) / len(v))
        print(f"{c}: {len(v)} rows, geomean {b}/{a} time {g:.4f}")
        allr += v
print(f"all: {len(allr)} rows, geomean {math.exp(sum(map(math.log, allr)) / len(allr)):.4f}")
