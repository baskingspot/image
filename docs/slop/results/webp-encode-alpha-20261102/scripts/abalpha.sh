#!/bin/bash
# abalpha.sh OUT ROUNDS "EFFORTS" name=bin...: encodeAlpha on the ten planes, the arms
# interleaved within each round, pinned to core 3, as Go benchmark lines for benchstat.
out=$1 rounds=$2 efforts=$3; shift 3
mkdir -p $out
for a in "$@"; do : > $out/${a%%=*}.txt; done
for r in $(seq 1 $rounds); do
  for k in $efforts; do
    for a in "$@"; do
      n=${a%%=*} b=${a#*=}
      taskset -c 3 $b $k 5 ${PLANES:-/tmp/a3/planes}/*.a8 2>&1 | awk -v k=$k '!/^TOTAL/ {
        split($1, p, "-"); dims=p[length(p)]; split(dims, d, "x"); px=d[1]*d[2]
        ms=$3; sub("ms","",ms); ns=ms*1e6
        printf "BenchmarkAlphaZ%d/%s 1 %.0f ns/op %.3f MP/s %d B\n", k, $1, ns, px/ns*1e3, $2 }' >> $out/$n.txt
    done
  done
done
