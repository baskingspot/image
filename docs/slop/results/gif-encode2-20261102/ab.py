#!/usr/bin/env python3
# Interleaved A/B of two arm binaries through `serve`: for each row, R rounds,
# order alternating; prints geomean of per-row median B/A throughput by class.
import subprocess, sys, os, math, statistics, glob
A = os.environ.get('A', '/tmp/gif/bench-A')
B = os.environ.get('B', '/home/user/workspace/repo/zig-out/bin/bench-image')
R = int(os.environ.get('R', '7'))
ops = sys.argv[1:] or ['gif-decode', 'gif-decode-anim']
os.chdir(os.environ.get('DIR', '/home/user/workspace/repo'))
dirs = {l.split('\t')[0]: l.split('\t')[2] for l in open('bench/ops.tsv') if not l.startswith('#') and l.strip()}
def start(b): return subprocess.Popen(['taskset', '-c', '3', b, 'serve'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=dict(os.environ))
sa, sb = start(A), start(B)
def ask(s, op, inp, n):
    s.stdin.write(f'{op} {inp} {n}\n'); s.stdin.flush()
    line = s.stdout.readline()
    return float(line.split('\t')[2].split()[0])  # ns/op
res = {}
for op in ops:
    for path in sorted(glob.glob(f'bench/corpus-gen/{dirs[op]}/*')):
        inp = os.path.basename(path)
        # size the loop to ~40 ms from one call of 1 iteration
        t = ask(sa, op, inp, 3)
        n = max(1, int(40e6 / max(t, 1)))
        rs = []
        for r in range(R):
            if r % 2: tb = ask(sb, op, inp, n); ta = ask(sa, op, inp, n)
            else: ta = ask(sa, op, inp, n); tb = ask(sb, op, inp, n)
            rs.append(ta / tb)
        w, h = inp.rsplit('-', 1)[1].split('.')[0].split('x')
        px = int(w) * int(h)
        cls = 'icon' if px <= 4096 else ('1mp' if px <= 1000000 else 'large')
        res.setdefault(op + '/' + cls, []).append(statistics.median(rs))
sa.stdin.close(); sb.stdin.close()
allr = []
for k in sorted(res):
    v = res[k]; allr += v
    print(f'{k:28s} {len(v):3d} {math.exp(sum(map(math.log, v))/len(v)):.3f}')
print(f'{"all":28s} {len(allr):3d} {math.exp(sum(map(math.log, allr))/len(allr)):.3f}')
