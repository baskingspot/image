#!/usr/bin/env python3
# Paired ratios of an ab.sh run: each round's A and B samples of a row ran
# back to back, so B's time over A's in the same round cancels the machine's
# drift. Prints each row's median ratio (B/A time: below 1, B is faster), and
# the geomean of those per size class (icons <= 64x64, to 1 MP, over).
import re, statistics, sys, math
from collections import defaultdict

def load(p):
    rows = []
    for l in open(p):
        m = re.match(r'Benchmark\S+/(\S+)\t\d+\t([0-9.]+) ns/op', l)
        if m: rows.append((m.group(1), float(m.group(2))))
    return rows

a, b = load(sys.argv[1] + '/a.txt'), load(sys.argv[1] + '/b.txt')
assert [x[0] for x in a] == [x[0] for x in b]
r = defaultdict(list)
for (f, ta), (_, tb) in zip(a, b): r[f].append(tb / ta)
cls = defaultdict(list)
for f, v in r.items():
    m = re.search(r'-(\d+)x(\d+)\.', f)
    w, h = int(m.group(1)), int(m.group(2))
    c = 'icon' if w <= 64 and h <= 64 else ('1mp' if w * h <= 1 << 20 else 'large')
    med = statistics.median(v)
    cls[c].append(med); cls['all'].append(med)
    print(f'{med:7.3f}  {f}')
for c in ['icon', '1mp', 'large', 'all']:
    if cls[c]:
        g = math.exp(sum(map(math.log, cls[c])) / len(cls[c]))
        print(f'{c:6} rows={len(cls[c]):3}  B/A time geomean {g:.3f}  (B speedup {1/g:.3f}x)')
