#!/usr/bin/env bash
# The rate-distortion runs for this pass, on each set of the first
# measurement (dev, hold, alpha): the cwebp rows from there
# (../webp-lossy-encode-20261102/, the same images and libwebp), our
# three efforts before this pass as main-* (MAIN_ENCDEV, encdev built
# against a checkout of the main it started from), and after it as ours-*;
# then the BD-rates (bd.txt). Run inside `nix develop` from the repository
# root, after ./encdev-build.sh (encdev.zig, which also times the best of
# $REPEAT encodes).
set -euo pipefail
here=$(dirname "$0")
old=$here/../webp-lossy-encode-20261102
S=bench/corpus-gen/.src
for SET in dev hold alpha; do
  case $SET in
    dev) IMAGES="$S/photo_kodak/kodim01.png $S/photo_kodak/kodim02.png $S/photo_kodak/kodim03.png $S/test/kodim23.png $S/photo_wikipedia/001.png $S/screenshot_web/apple_com.png $S/screenshot_game/20XX_Menu_picture.png $S/test/testcard.png $S/textures_pk/_pkf_water1.png" ;;
    hold) IMAGES="$S/test/kodim10.png $S/photo_wikipedia/002.png $S/photo_wikipedia/003.png $S/test/wikipedia_008.png $S/photo_tecnick/RGB_OR_1200x1200_001.png $S/photo_tecnick/RGB_OR_1200x1200_002.png $S/screenshot_game/3dbrick2.png $S/screenshot_game/3dcursedlabyrinth_mazegame.png $S/screenshot_web/cnn_com.png" ;;
    alpha) IMAGES="$S/pngimg/Number_2_PNG_images_free_download_PNG14940.png $S/pngimg/academy_awards_PNG9.png $S/pngimg/air_pump_PNG5.png $S/test/dice.png $S/test/qoi_logo.png $S/test/testcard_rgba.png $S/textures_plants/plant_01.png $S/textures_plants/plant_02.png $S/icon_512/actions_address_book_new.png $S/icon_64/actions_contact_new.png" ;;
  esac
  export IMAGES QS="10 20 30 40 50 60 70 75 80 85 90 95" OUT=/tmp/rd-$SET
  all=$here/rd-$SET.txt
  grep '^cwebp' "$old/rd-$SET.txt" > "$all"
  for e in fast default best; do
    ENCDEV=$MAIN_ENCDEV "$old/rd.sh" ours-$e-main | sed "s/^ours-$e-main /main-$e /" >> "$all"
  done
  for e in fast default best; do "$old/rd.sh" ours-$e >> "$all"; done
done
cat "$here/rd-dev.txt" "$here/rd-hold.txt" > /tmp/rd-both.txt
{
  for set in both dev hold; do
    f=/tmp/rd-both.txt
    [ $set = both ] || f=$here/rd-$set.txt
    echo "== $set"
    for r in cwebp0 cwebp2 cwebp4 cwebp6 main-fast main-default main-best; do
      for t in fast default best; do
        case $r in main-*) [ "$r" = "main-$t" ] || continue ;; esac
        echo "ours-$t vs $r: $(python3 "$old/bd.py" "$f" $r ours-$t | tail -1)"
      done
    done
  done
  echo "== alpha (psnr over pixels whose alpha is not 0)"
  for p in "cwebp2 fast" "cwebp4 default" "cwebp6 best" "main-fast fast" "main-default default" "main-best best"; do
    set -- $p
    echo "ours-$2 vs $1: $(python3 "$old/bd.py" "$here/rd-alpha.txt" $1 ours-$2 | tail -1)"
  done
} > "$here/bd.txt"
cat "$here/bd.txt"
