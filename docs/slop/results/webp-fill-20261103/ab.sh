#!/usr/bin/env bash
# ab.sh OUTDIR ROUNDS OPS...: alternate /tmp/bench-A and /tmp/bench-B per op, pinned to core 3
out=$1; rounds=$2; shift 2
mkdir -p $out; : > $out/ab-A.txt; : > $out/ab-B.txt
for r in $(seq $rounds); do
  for op in "$@"; do
    for arm in A B; do
      BENCHTIME_MS=50 taskset -c 3 /tmp/bench-$arm bench $op | grep '^Benchmark' >> $out/ab-$arm.txt
    done
  done
  echo "round $r done $(date +%T)"
done
