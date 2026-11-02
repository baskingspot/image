#!/bin/bash
# run.sh ROUNDS: kernel and general builds in turn, pinned to core 3.
for r in $(seq $1); do
  if [ $((r % 2)) = 0 ]; then order="kernel general"; else order="general kernel"; fi
  for b in $order; do taskset -c 3 ./$b.bin >> raw-$b.txt 2>&1; done
done
