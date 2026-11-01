#!/usr/bin/env bash
# Decision 1's measurement (../streaming-20261101.md): builds ab.zig in
# ReleaseFast for this machine, checks every arm decodes the same pixels,
# then times them on one core and compares them with benchstat. Run from
# the repository root in the dev shell, after `just bench-corpus`.
set -euo pipefail
here=docs/slop/results/streaming-20261101
rounds=${ROUNDS:-10}
ms=${MS:-20}
zig build-exe -OReleaseFast -femit-bin=zig-out/bin/streaming-ab --dep image -Mroot="$here/ab.zig" -Mimage=src/root.zig
mapfile -t files < <(ls -v bench/corpus-gen/qoi/*.qoi)
zig-out/bin/streaming-ab verify "${files[@]}"
core=$(($(nproc) - 1))
(cd "$here" && taskset -c "$core" ../../../../zig-out/bin/streaming-ab bench "$rounds" "$ms" "${files[@]/#/../../../../}")
lscpu | grep -E 'Model name|^CPU\(s\)|MHz' > "$here/cpu.txt"
(cd "$here" && benchstat pull_fixed=ab-pull_fixed.txt pull_4k=ab-pull_4k.txt push_whole=ab-push_whole.txt push_4k=ab-push_4k.txt > benchstat.txt)
echo "$here/benchstat.txt"
