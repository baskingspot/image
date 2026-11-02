#!/usr/bin/env bash
# The A/B of docs/slop/results/tiff-encode-20261102.md (copied from
# qoi-icons-20261102/ab.sh): `just bench-compare`'s checksums, peak RSS,
# and rounds (the justfile has the method), with arms given as
# name=binary rather than built, so the encoder's variants run as arms
# beside libtiff, image-rs, and Go. Run from the repository root in the
# dev shell after `just bench-build`:
#
#   OPS="tiff-encode-none ..." ab.sh OUT ROUNDS image=zig-out/bin/bench-image \
#     twopass=/path/bench-image streamed=/path/bench-image \
#     libtiff=zig-out/bin/bench-libtiff image-rs=zig-out/bin/bench-image-rs go=zig-out/bin/bench-go
#
# Checksums are listed, not enforced: the arms other than ours write their
# own layouts.
set -euo pipefail
out=$1 rounds=$2
shift 2
declare -A bin
arms=()
for a in "$@"; do
  arms+=("${a%%=*}")
  bin[${a%%=*}]=${a#*=}
done
read -ra ops <<< "$OPS"
rm -rf "$out" && mkdir -p "$out"
export BENCHTIME_MS="${BENCHTIME_MS:-50}"
for arm in "${arms[@]}"; do
  "${bin[$arm]}" check "${ops[@]}" > "$out/check-$arm.txt"
done
{
  echo "cpu: $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) threads"
  echo "image: ReleaseFast, native; C arms: cc -O3 -march=native; go: GOAMD64=v3"
  echo "buffers: input ${BENCH_IN_OFFSET:-0} bytes past a page, output ${BENCH_OUT_OFFSET:-2048}; ${BENCHTIME_MS} ms a sample, $rounds rounds"
} | tee "$out/config.txt"
for arm in "${arms[@]:1}"; do
  join -t $'\t' <(grep -v '^#' "$out/check-${arms[0]}.txt" | sort) <(grep -v '^#' "$out/check-$arm.txt" | sort) |
    awk -F'\t' '$2 != $3' > "$out/check-diff-$arm.txt"
  printf '%-9s %4d rows, %d differ from %s\n' "$arm" "$(grep -vc '^#' "$out/check-$arm.txt" || true)" \
    "$(wc -l < "$out/check-diff-$arm.txt")" "${arms[0]}"
done | tee "$out/checksums.txt"
{
  printf '%-22s' "peak RSS (MiB)"; printf '%9s' "${arms[@]}"; echo
  for op in "${ops[@]}"; do
    printf '%-22s' "$op"
    for arm in "${arms[@]}"; do
      command time -f %M -o "$out/rss-run.txt" "${bin[$arm]}" check "$op" > "$out/rss-check.txt" 2> /dev/null
      if grep -q '^# SKIP' "$out/rss-check.txt"; then printf '%9s' -; continue; fi
      awk '{ printf "%9.1f", $1 / 1024 }' "$out/rss-run.txt"
    done
    echo
  done
} | tee "$out/rss.txt"
core=${CORE:-$(( $(nproc) - 1 ))}
taskset -cp 0 $$ > /dev/null
declare -A arg_of has iters to from
while IFS=$'\t' read -r arg row _; do arg_of[$row]=$arg; done < <(grep -v '^#' bench/ops.tsv)
mapfile -t rows < <(grep -v "^#" "$out/check-${arms[0]}.txt" | cut -f1 | grep -E "${ROWS:-.}")
for arm in "${arms[@]}"; do
  while IFS=$'\t' read -r row _; do has[$arm/$row]=1; done < <(grep -v '^#' "$out/check-$arm.txt")
done
fifos=$(mktemp -d)
trap 'rm -rf "$fifos"' EXIT
start() {
  for arm in "${arms[@]}"; do
    mkfifo "$fifos/$arm.in" "$fifos/$arm.out"
    taskset -c "$core" "${bin[$arm]}" serve < "$fifos/$arm.in" > "$fifos/$arm.out" 2>> "$out/stderr-$arm.txt" &
    exec {fd}> "$fifos/$arm.in"
    to[$arm]=$fd
    exec {fd}< "$fifos/$arm.out"
    from[$arm]=$fd
  done
}
stop() {
  for arm in "${arms[@]}"; do eval "exec ${to[$arm]}>&-"; done
  wait
  for arm in "${arms[@]}"; do eval "exec ${from[$arm]}<&-"; done
  rm -f "$fifos"/*
}
sample() {
  printf '%s %s %s\n' "$2" "$3" "$4" >&"${to[$1]}"
  if ! IFS= read -r line <&"${from[$1]}" || [[ $line != Benchmark* ]]; then
    echo "$1 failed on $2 $3: $line"
    exit 1
  fi
}
for round in $(seq 0 "$rounds"); do
  start
  j=0
  for row in "${rows[@]}"; do
    arg=${arg_of[${row%%/*}]}
    input=${row#*/}
    present=()
    for arm in "${arms[@]}"; do [ -n "${has[$arm/$row]:-}" ] && present+=("$arm"); done
    for i in "${!present[@]}"; do
      arm=${present[$(( (round + j + i) % ${#present[@]} ))]}
      if [ "$round" = 0 ]; then
        sample "$arm" "$arg" "$input" 0
        IFS=$'\t' read -r _ n _ <<< "$line"
        iters[$arm/$row]=$n
      else
        sample "$arm" "$arg" "$input" "${iters[$arm/$row]}"
        echo "$line" >> "$out/raw-$arm.txt"
      fi
    done
    j=$(( j + 1 ))
  done
  stop
  echo "round $round of $rounds done at $(date +%T)"
done
files=()
for arm in "${arms[@]}"; do
  awk -F'\t' '/^Benchmark/ { print $1 "\t" $2 "\t" $4 }' "$out/raw-$arm.txt" > "$out/$arm.txt"
  files+=("$arm=$out/$arm.txt")
done
benchstat "${files[@]}" > "$out/benchstat.txt"
# After against before, Wuffs, and Go; then before against Wuffs.
: > "$out/rows.txt"
args=()
for arm in "${arms[@]}"; do args+=("$out/$arm.txt"); done
awk -v rows="$out/rows.txt" -f bench/summary.awk "${args[@]}" | tee "$out/summary.txt"
echo
awk -f bench/summary.awk "$out/${arms[1]}.txt" "${args[@]:2}" | tee "$out/summary-${arms[1]}.txt"
