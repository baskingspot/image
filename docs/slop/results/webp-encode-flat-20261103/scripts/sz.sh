#!/bin/bash
# sz.sh LEVEL BIN...: per-file bytes on the corpus and totals on the few-color set.
C=/home/user/workspace/repo/bench/corpus-gen/webp_encode
L=$1; shift
for b in "$@"; do
  mkdir -p o/sz_$b
  env -u Q R=1 nice -n 19 taskset -c 0 ./$b $L o/sz_$b $C/*.raw 2>&1 | grep -v TOTAL | awk '{print $1, $2}' > o/sz_$b/corpus$L.txt
  env -u Q R=1 nice -n 19 taskset -c 0 ./$b $L o/sz_$b few/*.raw 2>&1 | grep -v TOTAL | awk '{print $1, $2}' > o/sz_$b/few$L.txt
done
first=$1
for b in "$@"; do
  printf "z%s %-8s corpus %8d few %8d |" $L $b $(awk '{s+=$2} END {print s}' o/sz_$b/corpus$L.txt) $(awk '{s+=$2} END {print s}' o/sz_$b/few$L.txt)
  join o/sz_$first/corpus$L.txt o/sz_$b/corpus$L.txt | awk '$2 != $3 {split($1,a,"-"); if (($3/$2-1)^2 > 0.0001) printf " %s %+.1f%%", substr(a[2],1,8), ($3/$2-1)*100}'
  echo
done
