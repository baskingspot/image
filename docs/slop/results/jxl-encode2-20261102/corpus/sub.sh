#!/bin/bash
# sub.sh enc effort: bytes for a photo/screenshot subset
C=/home/user/workspace/repo/bench/corpus-gen/jxl_encode
tot=0; ms=0
for n in photo_kodak-kodim01-768x512 photo_kodak-kodim02-768x512 photo_kodak-kodim03-768x512 test-kodim10-512x768 test-dice-800x600 test-wikipedia_008-1152x858 textures_plants-plant_02-1024x1316; do
  f=$C/$n.raw; wh=${n##*-}; w=${wh%x*}; h=${wh#*x}; sz=$(stat -c %s $f); fmt=rgb8; [ $((sz/(w*h))) = 4 ] && fmt=rgba8
  out=$(taskset -c ${CORE:-0} $1 $f $w $h $fmt $2 /tmp/bc/sub-$$.jxl 2>&1 | grep "bytes,")
  b=$(echo "$out" | sed 's/.*: \([0-9]*\) bytes.*/\1/'); t=$(echo "$out" | sed 's/.*bpp, \([0-9.]*\) ms.*/\1/')
  printf "%s %s %s\n" $n $b $t
  tot=$((tot+b)); ms=$(echo "$ms + $t" | bc)
done
echo "TOTAL $tot $ms"
