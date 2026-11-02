# The TIFF rows' inputs: every source as 8-bit RGB, written by ImageMagick
# and rewritten by libtiff's tiffcp, in strips of libtiff's default size:
# uncompressed in none/, LZW with the horizontal predictor in lzw/, Deflate
# with the predictor in deflate/, PackBits in packbits/, and JPEG (YCbCr 2×2,
# quality 75, in strips of a multiple of 16 rows) in jpeg/; and the sources
# that are not photos thresholded to bilevel as CCITT Group 4 in g4/. No
# alpha, so every arm's RGBA8 is the same bytes. Sourced by
# bench/corpus/generate.
mkdir -p "$dst/none" "$dst/lzw" "$dst/deflate" "$dst/packbits" "$dst/jpeg" "$dst/g4"
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  wh=$(size "$f")
  name="$cat-$(basename "$f" .png)-$wh.tif"
  # libtiff's default strip: 8 KiB, at least one row.
  rows=$((8192 / (${wh%x*} * 3)))
  rows=$((rows > 0 ? rows : 1))
  magick "$f" -alpha off -type TrueColor -depth 8 -compress None \
    -define tiff:rows-per-strip=$rows TIFF:"$dst/.rgb.tif"
  tiffcp "$dst/.rgb.tif" "$dst/none/$name"
  tiffcp -c lzw:2 "$dst/.rgb.tif" "$dst/lzw/$name"
  tiffcp -c zip:2 "$dst/.rgb.tif" "$dst/deflate/$name"
  tiffcp -c packbits "$dst/.rgb.tif" "$dst/packbits/$name"
  tiffcp -c jpeg -r $(((rows + 15) / 16 * 16)) "$dst/.rgb.tif" "$dst/jpeg/$name"
  case "$cat" in
    photo_*) ;;
    *)
      magick "$f" -alpha off -colorspace Gray -threshold 50% -type Bilevel -depth 1 -compress None TIFF:"$dst/.rgb.tif"
      tiffcp -c g4 "$dst/.rgb.tif" "$dst/g4/$name"
      ;;
  esac
done
rm -f "$dst/.rgb.tif"
