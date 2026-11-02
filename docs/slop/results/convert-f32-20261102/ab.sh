#!/usr/bin/env bash
# The A/B of docs/slop/results/convert-f32-20261102.md. BEFORE and AFTER
# are directories holding a `convert.zig` and `pixel.zig` each; main.zig
# (here) is built against both, then the two run in ROUNDS interleaved
# rounds pinned to CORE, and benchstat compares them. Run in the dev shell:
#
#   CORE=3 ab.sh OUT ROUNDS BEFORE AFTER
set -euo pipefail
out=$1 rounds=$2 before=$3 after=$4
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
for arm in before after; do
  dir=${!arm}
  zig build-exe -OReleaseFast -mcpu=native --dep conv -Mroot="$here/main.zig" -Mconv="$dir/convert.zig" \
    -femit-bin="$out/$arm" --cache-dir "$out/.zig-cache"
done
lscpu | sed -n 's/^Model name: *//p' > "$out/cpu.txt"
: > "$out/before.txt"
: > "$out/after.txt"
for _ in $(seq "$rounds"); do
  for arm in before after; do
    taskset -c "${CORE:-3}" "$out/$arm" 2>> "$out/$arm.txt"
  done
done
benchstat "$out/before.txt" "$out/after.txt" > "$out/benchstat.txt"
rm -rf "$out/before" "$out/after" "$out/.zig-cache"
