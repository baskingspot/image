#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ops="png-decode jpeg-decode jpeg-decode-progressive webp-decode-lossy webp-decode-lossless gif-decode jxl-decode qoi-decode"
export BENCHTIME_MS=${BENCHTIME_MS:-30}
out=${OUT:-.}
rm -f $out/016.txt $out/017.txt
for r in 1 2 3 4 5 6; do
  if [ $((r % 2)) = 1 ]; then order="016 017"; else order="017 016"; fi
  for v in $order; do
    taskset -c 3 ~/scratch/bench-image-$v bench $ops >> $out/$v.txt
  done
  echo "round $r $(date +%T)"
done
