#!/usr/bin/env bash
# run.sh DIR A B ROUNDS: ROUNDS interleaved rounds of png-decode-icons and
# png-decode, pinned to core 3, the order alternating each round.
set -euo pipefail
dir=$1 a=$2 b=$3 rounds=$4
cd /home/user/workspace/repo
export BENCHTIME_MS=40
: > "$dir/$a.txt"; : > "$dir/$b.txt"
for r in $(seq 1 "$rounds"); do
  if [ $((r % 2)) -eq 1 ]; then order="$a $b"; else order="$b $a"; fi
  for arm in $order; do
    bin=/tmp/ab/$arm
    taskset -c 3 "$bin" bench png-decode-icons png-decode >> "$dir/$arm.txt"
  done
done
