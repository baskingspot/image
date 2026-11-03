#!/bin/bash
# tm.sh "LEVELS" BIN...: best-of times on the flat files, interleaved 3 times.
C=/home/user/workspace/repo/bench/corpus-gen/webp_encode
F="${F:-$C/test-qoi_logo-448x220.raw $C/pngimg-Number_2_PNG_images_free_download_PNG14940-600x600.raw $C/textures_pk-_pkf_water1-128x128.raw $C/screenshot_game-3dbrick2-320x240.raw $C/photo_kodak-kodim01-768x512.raw}"
L=$1; shift
for l in $L; do
  for r in 1 2 3; do for b in "$@"; do R=${RR:-15} taskset -c ${TC:-2} ./$b $l /tmp/a3/o/fz1 $F 2>&1 | awk -v b=$b -v l=$l '!/TOTAL/ {print l, b, NR, $3+0}'; done; done
done | awk '{k=$1" "$2" "$3; if (!(k in m) || $4 < m[k]) m[k]=$4} END {for (k in m) print k, m[k]}' | sort -k1,1n -k2,2 -k3,3n | awk '{if ($1" "$2 != p) {if (p) print ""; printf "z%s %-8s", $1, $2; p=$1" "$2} printf " %7.2f", $4} END {print ""}'
