#!/usr/bin/env bash
# The A/B of the decoder's header and raster changes: two builds of
# zig-out/bin/bench-image, before (A) and after (B), timed on one core in
# alternating rounds, compared with benchstat.
# Usage: ab.sh A-BINARY B-BINARY OUT-DIR ROUNDS OP...
set -euo pipefail
a=$1 b=$2 out=$3 rounds=$4
shift 4
mkdir -p "$out"
rm -f "$out/A.txt" "$out/B.txt"
for round in $(seq "$rounds"); do
  for op in "$@"; do
    # Alternate which build goes first.
    if [ $((round % 2)) = 0 ]; then order="A B"; else order="B A"; fi
    for arm in $order; do
      bin=$a
      [ "$arm" = B ] && bin=$b
      BENCHTIME_MS=${BENCHTIME_MS:-50} taskset -c 3 "$bin" bench "$op" >> "$out/$arm.txt"
    done
  done
done
benchstat A="$out/A.txt" B="$out/B.txt"
