#!/bin/bash
# qrun.sh ROUNDS bin1 bin2 ... : interleaved serve timings of key QOI files, median ns per file per binary
cd /home/user/workspace/repo
R=$1; shift
files="screenshot_game-3dbrick2-320x240.qoi test-testcard-256x256.qoi screenshot_game-3dcursedlabyrinth_mazegame-343x480.qoi icon_64-actions_address_book_new-64x64.qoi textures_pk-_0mod_button1-64x64.qoi photo_kodak-kodim01-768x512.qoi photo_wikipedia-001-1276x850.qoi test-dice-800x600.qoi screenshot_web-apple_com-1313x4755.qoi icon_16-actions_address_book_new-16x16.qoi"
out=$(mktemp)
for r in $(seq $R); do for f in $files; do for b in "$@"; do
  echo "qoi-decode $f 0" | BENCHTIME_MS=${MS:-100} taskset -c ${CORE:-3} $b serve | awk -v b=$(basename $b) -v f=$f '{print b, f, $3}' >> $out
done; done; done
python3 - "$out" "$@" <<'PY'
import sys,statistics as st,collections
d=collections.defaultdict(list)
for l in open(sys.argv[1]):
    b,f,ns=l.split(); d[(b,f)].append(float(ns))
bins=[x.split('/')[-1] for x in sys.argv[2:]]
files=sorted({f for _,f in d}, key=lambda f: list(k[1] for k in d).index(f))
print(f"{'file':34}"+"".join(f"{b:>14}" for b in bins))
g=collections.defaultdict(float)
import math
for f in files:
    base=st.median(d[(bins[0],f)])
    row=f"{f[:34]:34}"
    for b in bins:
        m=st.median(d[(b,f)]); row+=f"{m/1000:9.1f}us {base/m:4.2f}"[-14:].rjust(14) if False else f"{m/1000:8.1f} {base/m:4.2f}".rjust(14)
        g[b]+=math.log(base/m)
    print(row)
print("geomean speedup vs first: "+" ".join(f"{b}={math.exp(g[b]/len(files)):.3f}" for b in bins))
PY
