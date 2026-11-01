# The ICO rows' inputs, written by ImageMagick: each 16, 32, and 64 pixel
# icon, and each 512 pixel one scaled to 256, as a one-entry icon of
# 32-bit BMP data. Sourced by bench/corpus/generate.
for f in "$src"/icon_16/*.png "$src"/icon_32/*.png "$src"/icon_64/*.png; do
  cat=$(basename "$(dirname "$f")")
  magick "$f" "$dst/$cat-$(basename "$f" .png)-$(size "$f").ico"
done
for f in "$src"/icon_512/*.png; do
  magick "$f" -resize 256x256 "$dst/icon_256-$(basename "$f" .png)-256x256.ico"
done
