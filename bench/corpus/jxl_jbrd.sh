# The JPEG reconstruction rows' inputs: cjxl's lossless JPEG transcodes
# (--lossless_jpeg=1, one thread) of the JPEG rows' baseline and
# progressive files, every source with its alpha dropped as cjpeg writes it
# at quality 85, into baseline/ and progressive/. Sourced by
# bench/corpus/generate.
mkdir -p "$dst/baseline" "$dst/progressive"
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  base=$cat-$(basename "$f" .png)-$(size "$f")
  magick "$f" -alpha off ppm:"$dst/.ppm"
  cjpeg -quality 85 -outfile "$dst/.jpg" "$dst/.ppm"
  cjxl --quiet --num_threads=0 --lossless_jpeg=1 "$dst/.jpg" "$dst/baseline/$base.jxl"
  cjpeg -quality 85 -progressive -outfile "$dst/.jpg" "$dst/.ppm"
  cjxl --quiet --num_threads=0 --lossless_jpeg=1 "$dst/.jpg" "$dst/progressive/$base.jxl"
done
rm "$dst/.ppm" "$dst/.jpg"
