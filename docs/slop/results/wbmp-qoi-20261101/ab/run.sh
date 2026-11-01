#!/usr/bin/env bash
# run.sh OUT ROUNDS OP A B...: interleaved rounds of `bench-image bench OP`
# for each variant, pinned to the last core, the order rotating per round.
set -euo pipefail
cd /home/user/workspace/repo
out=$1 rounds=$2 op=$3; shift 3
vars=("$@")
mkdir -p "$out"
core=$(( $(nproc) - 1 ))
for r in $(seq 1 "$rounds"); do
  for i in "${!vars[@]}"; do
    v=${vars[$(( (r + i) % ${#vars[@]} ))]}
    BENCHTIME_MS=${BENCHTIME_MS:-50} taskset -c "$core" /tmp/ab/$v/bin/bench-image bench "$op" >> "$out/$v.txt"
  done
done
args=()
for v in "${vars[@]}"; do args+=("$v=$out/$v.txt"); done
benchstat "${args[@]}" > "$out/benchstat.txt"
