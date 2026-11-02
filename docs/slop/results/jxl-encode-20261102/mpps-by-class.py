#!/usr/bin/env python3
# Megapixels per second by size class from bench-compare's raw-<arm>.txt:
# each row's median over the rounds, then the geometric mean over the
# class's rows, for this package and libjxl, and their ratio (above 1,
# ours is faster). Classes as bench-compare's: icons (at most 4096
# pixels), up to 1 MP, larger.
# Usage: mpps-by-class.py DIR
import collections, math, re, statistics, sys

def load(path):
    d = collections.defaultdict(list)
    for line in open(path):
        m = re.match(r'Benchmark(\S+)\s+(\d+)\s+([\d.]+) ns/op', line)
        if m:
            d[m.group(1)].append(float(m.group(3)))
    return d

ours = load(f'{sys.argv[1]}/raw-image.txt')
theirs = load(f'{sys.argv[1]}/raw-libjxl.txt')
out = collections.defaultdict(lambda: collections.defaultdict(list))
for row in ours:
    if row not in theirs:
        continue
    w, h = map(int, re.search(r'-(\d+)x(\d+)\.raw$', row).groups())
    px = w * h
    c = 'icon' if px <= 4096 else '1mp' if px <= 1048576 else 'large'
    pair = (px / statistics.median(ours[row]) * 1e3, px / statistics.median(theirs[row]) * 1e3)
    op = row.split('/')[0]
    out[op][c].append(pair)
    out[op]['all'].append(pair)
print('row class image_MPs libjxl_MPs ratio')
for op in sorted(out):
    for c in ['icon', '1mp', 'large', 'all']:
        v = out[op][c]
        gi = math.exp(sum(math.log(x) for x, _ in v) / len(v))
        gl = math.exp(sum(math.log(y) for _, y in v) / len(v))
        print(f'{op} {c} {gi:.3f} {gl:.3f} {gi / gl:.2f}')
