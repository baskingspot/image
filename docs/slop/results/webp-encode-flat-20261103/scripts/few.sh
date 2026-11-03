#!/bin/bash
# few.sh OUT: the few-color set, the GIF bench stills up to 5 MP (42 files) as raw RGBA.
out=$1; mkdir -p "$out"
for g in bench/corpus-gen/gif/still/*.gif; do
  b=$(basename "$g" .gif); wh=${b##*-}
  (( ${wh%x*} * ${wh#*x} <= 5000000 )) || continue
  magick "$g" -depth 8 "rgba:$out/$b.raw"
done
