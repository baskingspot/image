#!/usr/bin/env bash
# The ten alpha planes, one byte a pixel, named NAME-WxH.a8, from the
# corpus sources; and libwebp's ALPH sizes for them (cwebp -q 75 -m M,
# -alpha_filter fast, none, best), read by alph.py. Run from the repository
# root with ImageMagick and libwebp 1.6.0 on PATH.
set -euo pipefail
out=${1:-/tmp/a3}
mkdir -p "$out/planes" "$out/lw"
files="pngimg/Number_2_PNG_images_free_download_PNG14940.png pngimg/academy_awards_PNG9.png pngimg/air_pump_PNG5.png test/dice.png test/qoi_logo.png test/testcard_rgba.png textures_plants/plant_01.png textures_plants/plant_02.png icon_512/actions_address_book_new.png icon_64/actions_contact_new.png"
cd bench/corpus-gen/.src
for f in $files; do
  n=$(echo "${f%.png}" | tr / -)
  magick "$f" -alpha extract -depth 8 "gray:$out/planes/$n-$(magick identify -format %wx%h "$f").a8"
  for m in 0 2 4 6; do for af in fast none best; do
    cwebp -quiet -q 75 -m $m -alpha_filter $af "$f" -o "$out/lw/m$m-$af-$n.webp"
  done; done
done
