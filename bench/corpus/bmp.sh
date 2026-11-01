# The BMP rows' inputs, written by ImageMagick: every source as 24-bit
# (BMP3), 32-bit with alpha (a BITMAPV5HEADER with bitfields), and 8-bit
# with a 256-color table, in uncompressed/; and the sources that are not
# photos as RLE8, in rle8/. Sourced by bench/corpus/generate.
mkdir -p "$dst/uncompressed" "$dst/rle8"
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  name="$cat-$(basename "$f" .png)-$(size "$f").bmp"
  magick "$f" -alpha off -type TrueColor BMP3:"$dst/uncompressed/24-$name"
  magick "$f" -type TrueColorAlpha BMP:"$dst/uncompressed/32-$name"
  magick "$f" -alpha off -colors 256 -type Palette -compress None BMP3:"$dst/uncompressed/8-$name"
  case "$cat" in
    photo_*) ;;
    *) magick "$f" -alpha off -colors 256 -type Palette -compress RLE BMP3:"$dst/rle8/$name" ;;
  esac
done
