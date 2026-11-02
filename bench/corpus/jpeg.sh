# The JPEG rows' inputs: every source with its alpha dropped, as
# libjpeg-turbo's cjpeg writes it at quality 85. jpeg/baseline is cjpeg's
# default layout, sequential Huffman with 4:2:0 chroma; jpeg/progressive is
# the same with cjpeg's progressive script; jpeg/444 is sequential at full
# chroma resolution, quality 90, as screenshots and high-quality photos are
# often saved. jpeg/arith is the baseline layout arithmetic-coded,
# jpeg/12bit the same at 12-bit precision (the 8-bit samples scaled up by
# cjpeg), and jpeg/lossless cjpeg's lossless mode with the first predictor.
# jpeg/cmyk is the baseline layout as YCCK, Adobe's CMYK with a color
# transform (Photoshop's usual CMYK JPEG): tjbench converts the RGB to
# inverted inks naively and compresses them at quality 85, black and luma
# at full resolution and chroma at half. Sourced by bench/corpus/generate.
mkdir -p "$dst/baseline" "$dst/progressive" "$dst/444" "$dst/arith" "$dst/12bit" "$dst/lossless" "$dst/cmyk"
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  name=$cat-$(basename "$f" .png)-$(size "$f").jpg
  magick "$f" -alpha off ppm:"$dst/.ppm"
  cjpeg -quality 85 -outfile "$dst/baseline/$name" "$dst/.ppm"
  cjpeg -quality 85 -progressive -outfile "$dst/progressive/$name" "$dst/.ppm"
  cjpeg -quality 90 -sample 1x1 -outfile "$dst/444/$name" "$dst/.ppm"
  cjpeg -quality 85 -arithmetic -outfile "$dst/arith/$name" "$dst/.ppm"
  cjpeg -quality 85 -precision 12 -outfile "$dst/12bit/$name" "$dst/.ppm"
  cjpeg -lossless 1 -outfile "$dst/lossless/$name" "$dst/.ppm"
  # tjbench writes its reference file next to its input, named after it.
  ln -f "$dst/.ppm" "$dst/.cmyk.ppm"
  tjbench "$dst/.cmyk.ppm" 85 -pixelformat cmyk -subsamp 420 -benchtime 0.01 -warmup 0 > /dev/null
  mv "$dst/.cmyk_420_Q85.jpg" "$dst/cmyk/$name"
  rm "$dst/.cmyk_420_Q85_full.ppm"
done
rm "$dst/.ppm" "$dst/.cmyk.ppm"
