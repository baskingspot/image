#!/usr/bin/env bash
# Interleaved A/B: ab.sh A_BIN B_BIN OUTDIR ROUNDS OP DIR [GLOB]
# Each round times every input under A and B back to back, alternating
# which goes first, both pinned to the last core; benchstat compares them.
set -euo pipefail
a=$1 b=$2 out=$3 rounds=$4 op=$5 dir=$6 glob=${7:-*}
mkdir -p "$out"
: > "$out/a.txt"
: > "$out/b.txt"
core=$(( $(nproc) - 1 ))
export BENCHTIME_MS=${BENCHTIME_MS:-60}
mapfile -t inputs < <(cd "$dir" && ls $glob)
for ((r = 0; r < rounds; r++)); do
  i=0
  for f in "${inputs[@]}"; do
    if (( (r + i) % 2 == 0 )); then order="a b"; else order="b a"; fi
    for s in $order; do
      bin=$a; [ "$s" = b ] && bin=$b
      echo "$op $f 0" | taskset -c "$core" "$bin" serve >> "$out/$s.txt"
    done
    i=$((i + 1))
  done
done
{ echo "cpu: $(lscpu | sed -n 's/^Model name: *//p'), pinned to core $core"; benchstat "$out/a.txt" "$out/b.txt"; } > "$out/benchstat.txt"
cat "$out/benchstat.txt"
