#!/bin/bash
# fewcmp.sh BIN LEVELS...: per level, totals of ours (BIN) and cwebp on the few-color set.
export PATH=/nix/store/48jp3zrc8rsgn441kfrk0dfx3n11ph26-libwebp-1.6.0/bin:$PATH
B=$1; shift
cd /tmp/a3
for L in "$@"; do
  mkdir -p o/few_$L
  R=3 taskset -c 2 $B $L o/few_$L few/*.raw 2>&1 | grep -v TOTAL | sed 's/ms$//' > o/few_$L/ours.txt
  : > o/few_$L/lw.txt
  for f in fewpng/*.png; do
    b=$(basename $f .png); best=9
    for r in 1 2 3; do
      t=$(taskset -c 2 cwebp -z $L -v $f -o o/few_$L/$b.lw.webp 2>&1 | awk '/Time to encode/ {sub("s","",$5); print $5}')
      best=$(echo "$t $best" | awk '{print ($1<$2)?$1:$2}')
    done
    echo -e "$b\t$(stat -c %s o/few_$L/$b.lw.webp)\t$(echo $best | awk '{print $1*1000}')" >> o/few_$L/lw.txt
  done
  paste o/few_$L/ours.txt o/few_$L/lw.txt | awk -v L=$L '{ob+=$2; ot+=$3; lb+=$5; lt+=$6} END {printf "z%s ours %d B %.1f ms | libwebp %d B %.1f ms | size %.3f speed %.2fx\n", L, ob, ot, lb, lt, ob/lb, lt/ot}'
done
