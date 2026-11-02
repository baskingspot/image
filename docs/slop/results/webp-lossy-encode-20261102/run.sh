#!/usr/bin/env bash
# The rate-distortion runs: every image of a set at qualities 10 to 95,
# through cwebp at methods 0, 2, 4, and 6 and our three efforts, measured
# by encdev (RGB PSNR and BT.601 luma SSIM against the source), then
# BD-rates against each cwebp method. Run inside `nix develop` from the
# repository root, after ./encdev-build.sh. SET is dev (the images the
# constants were tuned on) or hold (held out).
set -euo pipefail
here=$(dirname "$0")
S=bench/corpus-gen/.src
case ${SET:-dev} in
  dev) IMAGES="$S/photo_kodak/kodim01.png $S/photo_kodak/kodim02.png $S/photo_kodak/kodim03.png $S/test/kodim23.png $S/photo_wikipedia/001.png $S/screenshot_web/apple_com.png $S/screenshot_game/20XX_Menu_picture.png $S/test/testcard.png $S/textures_pk/_pkf_water1.png" ;;
  hold) IMAGES="$S/test/kodim10.png $S/photo_wikipedia/002.png $S/photo_wikipedia/003.png $S/test/wikipedia_008.png $S/photo_tecnick/RGB_OR_1200x1200_001.png $S/photo_tecnick/RGB_OR_1200x1200_002.png $S/screenshot_game/3dbrick2.png $S/screenshot_game/3dcursedlabyrinth_mazegame.png $S/screenshot_web/cnn_com.png" ;;
esac
export IMAGES QS="10 20 30 40 50 60 70 75 80 85 90 95"
export OUT=/tmp/rd-${SET:-dev}
all=$here/rd-${SET:-dev}.txt
: > "$all"
for l in cwebp0 cwebp2 cwebp4 cwebp6 ours-fast ours-default ours-best; do "$here/rd.sh" $l >> "$all"; done
for r in cwebp0 cwebp2 cwebp4 cwebp6; do
  for t in ours-fast ours-default ours-best; do
    echo "$t vs $r: $(python3 "$here/bd.py" "$all" $r $t | tail -1)"
  done
done
