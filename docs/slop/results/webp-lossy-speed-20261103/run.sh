#!/usr/bin/env bash
# The rate-distortion runs for this pass. Only `best` changes its output
# (`fast` and `default` write the same bytes as before), so only it is
# run, on each set of the first measurement (dev, hold, alpha), against
# the cwebp -m 6 rows and our `best` before this pass (main-best) from
# ../webp-lossy-trellis-20261102/; then the BD-rates (bd.txt). Run inside
# `nix develop` from the repository root, after ./encdev-build.sh.
set -euo pipefail
here=$(dirname "$0")
old=$here/../webp-lossy-encode-20261102
prev=$here/../webp-lossy-trellis-20261102
S=bench/corpus-gen/.src
for SET in dev hold alpha; do
  case $SET in
    dev) IMAGES="$S/photo_kodak/kodim01.png $S/photo_kodak/kodim02.png $S/photo_kodak/kodim03.png $S/test/kodim23.png $S/photo_wikipedia/001.png $S/screenshot_web/apple_com.png $S/screenshot_game/20XX_Menu_picture.png $S/test/testcard.png $S/textures_pk/_pkf_water1.png" ;;
    hold) IMAGES="$S/test/kodim10.png $S/photo_wikipedia/002.png $S/photo_wikipedia/003.png $S/test/wikipedia_008.png $S/photo_tecnick/RGB_OR_1200x1200_001.png $S/photo_tecnick/RGB_OR_1200x1200_002.png $S/screenshot_game/3dbrick2.png $S/screenshot_game/3dcursedlabyrinth_mazegame.png $S/screenshot_web/cnn_com.png" ;;
    alpha) IMAGES="$S/pngimg/Number_2_PNG_images_free_download_PNG14940.png $S/pngimg/academy_awards_PNG9.png $S/pngimg/air_pump_PNG5.png $S/test/dice.png $S/test/qoi_logo.png $S/test/testcard_rgba.png $S/textures_plants/plant_01.png $S/textures_plants/plant_02.png $S/icon_512/actions_address_book_new.png $S/icon_64/actions_contact_new.png" ;;
  esac
  export IMAGES QS="10 20 30 40 50 60 70 75 80 85 90 95" OUT=/tmp/rd-$SET
  {
    grep -E '^(cwebp6|ours-best) ' "$prev/rd-$SET.txt" | sed 's/^ours-best /main-best /'
    "$old/rd.sh" ours-best
  } > "$here/rd-$SET.txt"
done
cat "$here/rd-dev.txt" "$here/rd-hold.txt" > /tmp/rd-both.txt
{
  for set in both dev hold; do
    f=/tmp/rd-both.txt
    [ $set = both ] || f=$here/rd-$set.txt
    echo "== $set"
    for r in cwebp6 main-best; do echo "ours-best vs $r: $(python3 "$old/bd.py" "$f" $r ours-best | tail -1)"; done
  done
  echo "== alpha (psnr over pixels whose alpha is not 0)"
  for r in cwebp6 main-best; do echo "ours-best vs $r: $(python3 "$old/bd.py" "$here/rd-alpha.txt" $r ours-best | tail -1)"; done
} > "$here/bd.txt"
cat "$here/bd.txt"
