#!/bin/bash
# usage: corpus.sh effort [tag] -> total bytes and ms; per-file lines in /tmp/bc/run-<effort>-<tag>.txt
C=/home/user/workspace/repo/bench/corpus-gen/jxl_encode
tag=${2:-x}; log=/tmp/bc/run-$1-$tag.txt; : > $log
tot=0; ms=0; small_ms=0; small_b=0
for f in $C/${FILTER:-}*.raw; do
  n=$(basename $f .raw); wh=${n##*-}; w=${wh%x*}; h=${wh#*x}
  sz=$(stat -c %s $f); bpp=$((sz / (w*h)))
  fmt=rgb8; [ $bpp = 4 ] && fmt=rgba8
  reps=1; [ $((w*h)) -le 4096 ] && reps=20
  out=$(${ENC:-/home/user/workspace/scratch-enc/zig-out/bin/enc} $f $w $h $fmt $1 /tmp/bc/x-$tag.jxl $reps 2>&1 | grep "bytes,")
  b=$(echo "$out" | sed 's/.*: \([0-9]*\) bytes.*/\1/'); t=$(echo "$out" | sed 's/.*bpp, \([0-9.]*\) ms.*/\1/')
  tot=$((tot + b)); ms=$(echo "$ms + $t" | bc)
  if [ $((w*h)) -le 4096 ]; then small_ms=$(echo "$small_ms + $t" | bc); small_b=$((small_b + b)); fi
  echo "$n $b $t $(md5sum < /tmp/bc/x-$tag.jxl | cut -c1-12)" >> $log
done
echo "effort $1 [$tag]: $tot bytes, $ms ms; icons<=64x64: $small_b bytes, $small_ms ms"
