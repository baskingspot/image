#!/usr/bin/env python3
"""bd.py results.txt REF TEST: Bjontegaard-delta rate of TEST against REF
per image, on PSNR and on SSIM (as -10 log10(1 - SSIM) dB), by piecewise
linear interpolation of log(bytes) over the overlapping quality range; and
the mean. Negative means TEST is smaller at equal quality."""
import sys, math, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) < 6: continue
    label, img, q, size, psnr, ssim = p[:6]
    rows[(label, img)].append((int(size), float(psnr), float(ssim)))
ref, test = sys.argv[2], sys.argv[3]

def curve(pts, metric):
    c = sorted((m, math.log(s)) for s, *ms in pts for m in [metric(ms)])
    return c

def interp(c, x):
    for (x0, y0), (x1, y1) in zip(c, c[1:]):
        if x0 <= x <= x1:
            return y0 if x1 == x0 else y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return None

def bd(a, b):
    lo = max(a[0][0], b[0][0]); hi = min(a[-1][0], b[-1][0])
    if hi <= lo: return None
    n = 200; s = 0
    for i in range(n + 1):
        x = lo + (hi - lo) * i / n
        ya, yb = interp(a, x), interp(b, x)
        if ya is None or yb is None: return None
        s += (yb - ya) * (0.5 if i in (0, n) else 1)
    return math.exp(s / n) - 1

metrics = {"psnr": lambda m: m[0], "ssim": lambda m: -10 * math.log10(max(1e-9, 1 - m[1]))}
imgs = sorted({img for (l, img) in rows if l == ref} & {img for (l, img) in rows if l == test})
tot = collections.defaultdict(list)
for img in imgs:
    out = [img]
    for name, f in metrics.items():
        r = bd(curve(rows[(ref, img)], f), curve(rows[(test, img)], f))
        out.append(f"{name} {'n/a' if r is None else f'{100*r:+.1f}%'}")
        if r is not None: tot[name].append(r)
    print("  ".join(out))
print("mean", "  ".join(f"{k} {100*sum(v)/len(v):+.1f}%" for k, v in tot.items()))
