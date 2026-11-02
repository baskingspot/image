import sys, math, re, collections
lib = collections.defaultdict(dict)
for line in open('/home/user/workspace/repo/docs/slop/results/jxl-encode-20261102/check-libjxl.txt'):
    m = re.match(r'JxlEncodeE(\d)/(\S+)\.raw\s+len=(\d+)', line)
    if m: lib[int(m.group(1))][m.group(2)] = int(m.group(3))
ours = {}
for eff in ['fast','default','best']:
    ours[eff] = {l.split()[0]: int(l.split()[1]) for l in open(f'/tmp/bc/run-{eff}-{sys.argv[1]}.txt')}
def cls(n):
    w,h = map(int, n.rsplit('-',1)[1].split('x'))
    px = w*h
    return 'icons' if px <= 4096 else ('1mp' if px <= 1<<20 else 'large')
eff_of = {1:'fast',2:'fast',3:'fast',4:'default',5:'default',6:'default',7:'default',8:'best',9:'best'}
print('| libjxl effort | ours | icons total | icons geomean | ≤1 MP total | ≤1 MP geomean | >1 MP total | >1 MP geomean | all total | all geomean |')
print('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
for e in range(1,10):
    o = ours[eff_of[e]]; row = [f'e{e}', eff_of[e]]
    for c in ['icons','1mp','large','all']:
        names = [n for n in o if c == 'all' or cls(n) == c]
        tot = sum(o[n] for n in names) / sum(lib[e][n] for n in names)
        g = math.exp(sum(math.log(o[n]/lib[e][n]) for n in names)/len(names))
        row += [f'{tot:.3f}', f'{g:.3f}']
    print('| ' + ' | '.join(row) + ' |')
