import sys, collections
# perf script output: header line, then frames "addr sym+off (dso)", blank line between samples.
total=0; setup=0; ms=collections.Counter(); msn=0
stack=[]
def flush():
    global total, setup, msn
    if not stack: return
    syms=[f.split()[1].rsplit('+',1)[0] if len(f.split())>1 else '?' for f in stack]
    if any(s in ('map','unmap','load','list_inputs','main_load') for s in syms):
        setup+=1; return
    total+=1
    if syms[0] in ('memset','compiler_rt.memset'):
        msn+=1
        caller=next((s for s in syms[1:] if s not in ('memset','compiler_rt.memset')),'?')
        ms[caller]+=1
for line in sys.stdin:
    if line.startswith('bench-image') or (line and not line[0].isspace() and line.strip()):
        flush(); stack=[]; continue
    if not line.strip():
        flush(); stack=[]; continue
    stack.append(line.strip())
flush()
op=sys.argv[1]
pct=100*msn/total if total else 0
top='; '.join(f'{c} {100*n/total:.1f}%' for c,n in ms.most_common(4))
print(f'{op}\t{total}\t{pct:.2f}\t{top}')
