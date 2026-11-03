#!/bin/bash
# same.sh A B LEVELS: A's and B's outputs on the corpus and the few-color set are identical.
A=$1 B=$2; shift 2
C=/home/user/workspace/repo/bench/corpus-gen/webp_encode
for L in "$@"; do for set in corpus few; do
  if [ $set = corpus ]; then files="$C/*.raw"; else files="few/*.raw"; fi
  rm -rf o/sA o/sB; mkdir -p o/sA o/sB
  Q=1 taskset -c ${TA:-2} $A $L o/sA $files 2>&1 | tail -1 >/dev/null; Q=1 taskset -c 1 $B $L o/sB $files 2>&1 | tail -1 > /dev/null
  n=0; d=0; for f in o/sA/*.webp; do n=$((n+1)); cmp -s $f o/sB/$(basename $f) || { d=$((d+1)); echo DIFF $L $f; }; done
  echo "z$L $set: $n files, $d differ"
done; done
