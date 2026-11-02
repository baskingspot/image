# The WebP lossless encode rows' inputs: a subset of the sources, as raw
# 8-bit pixels, RGBA when the source has alpha and RGB otherwise, as for
# QOI encode. A subset because cwebp's slowest levels take seconds a
# megapixel: icons, photos, screenshots, textures, and test images, but not
# the 50-megapixel mosaic or the long web pages but one. Sourced by
# bench/corpus/generate.
for f in "$src"/icon_16/actions_a*.png "$src"/icon_32/actions_a*.png "$src"/icon_64/actions_a*.png \
  "$src"/icon_512/actions_address_book_new.png "$src"/photo_kodak/kodim0[12].png \
  "$src"/photo_tecnick/RGB_OR_1200x1200_001.png "$src"/photo_wikipedia/001.png \
  "$src"/pngimg/Number_2_PNG_images_free_download_PNG14940.png "$src"/pngimg/academy_awards_PNG9.png \
  "$src"/screenshot_game/20XX_Menu_picture.png "$src"/screenshot_game/3dbrick2.png \
  "$src"/screenshot_web/apple_com.png "$src"/test/dice.png "$src"/test/qoi_logo.png \
  "$src"/test/testcard_rgba.png "$src"/textures_pk/_pkf_water1.png "$src"/textures_plants/plant_01.png; do
  cat=$(basename "$(dirname "$f")")
  read -r w h channels < <(magick identify -format '%w %h %[channels]\n' "$f[0]")
  case "$channels" in *a | *a[[:space:]]*) map=rgba ;; *) map=rgb ;; esac
  magick "$f[0]" -depth 8 "$map:$dst/$cat-$(basename "$f" .png)-${w}x${h}.raw"
done
