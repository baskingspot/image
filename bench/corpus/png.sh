# The PNG rows' inputs: every source as its encoder wrote it (the suite's
# files, and ImageMagick's for the scaled icons and the mosaic), plus one
# Kodak photo and one icon as ImageMagick writes the color types and the
# interlacing the sources lack: gray, palette, gray with alpha, and Adam7.
# 8-bit samples only, so every arm's RGBA8 is the same bytes. Sourced by
# bench/corpus/generate.
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  cp "$f" "$dst/$cat-$(basename "$f" .png)-$(size "$f").png"
done
kodak=("$src"/photo_kodak/*.png)
icons=("$src"/icon_64/*.png)
for f in "${kodak[0]}" "${icons[0]}"; do
  base=$(basename "$f" .png)-$(size "$f")
  set -- -depth 8 -define png:bit-depth=8
  magick "$f" -alpha off -colorspace Gray "$@" -define png:color-type=0 "PNG:$dst/variant_gray-$base.png"
  magick "$f" -alpha off -colors 256 "PNG8:$dst/variant_palette-$base.png"
  magick "$f" -colorspace Gray "$@" -define png:color-type=4 "PNG:$dst/variant_gray_alpha-$base.png"
  magick "$f" -interlace PNG "$@" -define png:color-type=6 "PNG:$dst/variant_interlaced-$base.png"
done
