# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick. ImageMagick
# makes one TIFF per kind of pixel; libtiff's tiffcp rewrites each with every
# compression, predictor, layout, byte order, and BigTIFF.
rm -rf "${out:?}/tiff" && mkdir -p "$out/tiff"
t=$out/tiff
base=$(mktemp -d)

# The kinds of pixel, uncompressed.
im "$src/basn0g01.png" -compress none "$base/gray1.tif"
im "$src/basn0g02.png" -compress none "$base/gray2.tif"
im "$src/basn0g04.png" -compress none "$base/gray4.tif"
im "$src/basn0g08.png" -compress none "$base/gray8.tif"
im "$src/basn0g16.png" -compress none "$base/gray16.tif"
im "$src/basn4a08.png" -compress none "$base/grayalpha8.tif"
im "$src/basn3p04.png" -compress none "$base/palette4.tif"
im "$src/basn3p08.png" -compress none "$base/palette8.tif"
im "$src/basn2c08.png" -compress none "$base/rgb8.tif"
im "$src/basn2c16.png" -compress none "$base/rgb16.tif"
im "$src/basn6a08.png" -compress none "$base/rgba8.tif"
im "$src/basn6a16.png" -compress none "$base/rgba16.tif"
im "$src/basn2c08.png" -colorspace CMYK -compress none "$base/cmyk8.tif"
im "$src/basn2c08.png" -depth 32 -define quantum:format=floating-point -compress none "$base/float32.tif"
im "$src/basn2c08.png" -depth 16 -define quantum:format=floating-point -compress none "$base/float16.tif"
im "$src/basn2c08.png" -depth 32 -define quantum:format=signed -compress none "$base/rgb32.tif"
# Planar (tiffcp separates only 8-bit samples).
im "$src/basn2c08.png" -interlace plane -compress none "$base/rgb8-planar.tif"
im "$src/basn2c16.png" -interlace plane -compress none "$base/rgb16-planar.tif"
im "$src/basn6a16.png" -interlace plane -compress none "$base/rgba16-planar.tif"
im "$src/basn2c08.png" -depth 32 -define quantum:format=floating-point -interlace plane -compress none "$base/float32-planar.tif"

for f in "$base"/*.tif; do
  n=$(basename "$f" .tif)
  cp "$f" "$t/$n-none.tif"
  tiffcp -c packbits "$f" "$t/$n-packbits.tif"
  tiffcp -c lzw "$f" "$t/$n-lzw.tif"
  tiffcp -c zip "$f" "$t/$n-zip.tif"
  case $n in
    float*)
      tiffcp -c lzw:3 "$f" "$t/$n-lzw-pred3.tif"
      tiffcp -c zip:3 -t -w 16 -l 16 "$f" "$t/$n-zip-pred3-tiles.tif"
      ;;
    gray1 | gray2 | gray4 | palette4) ;;
    *)
      tiffcp -c lzw:2 "$f" "$t/$n-lzw-pred2.tif"
      tiffcp -c zip:2 -r 7 -B "$f" "$t/$n-zip-pred2-be.tif"
      ;;
  esac
  tiffcp -c lzw -t -w 16 -l 32 "$f" "$t/$n-lzw-tiles.tif"
  tiffcp -c zip -8 -r 5 "$f" "$t/$n-zip-bigtiff.tif"
  tiffcp -c packbits -B -8 -t -w 32 -l 16 "$f" "$t/$n-packbits-be-bigtiff-tiles.tif"
  case $n in
    rgb8 | rgba8 | cmyk8 | grayalpha8)
      tiffcp -p separate -r 9 "$f" "$t/$n-separate.tif"
      tiffcp -p separate -c lzw:2 -t -w 16 -l 16 "$f" "$t/$n-separate-lzw-tiles.tif"
      ;;
  esac
done

# Bilevel: CCITT modified Huffman (tiffcp has no MH encoder, so Group 3 and
# 4 only), Group 3 1D and 2D, Group 4, and FillOrder 2.
f=$base/gray1.tif
tiffcp -c g3 "$f" "$t/gray1-g3.tif"
tiffcp -c g3:2d "$f" "$t/gray1-g3-2d.tif"
tiffcp -c g3:2d:fill "$f" "$t/gray1-g3-2d-fill.tif"
tiffcp -c g4 "$f" "$t/gray1-g4.tif"
tiffcp -c g4 -f lsb2msb "$f" "$t/gray1-g4-lsb.tif"
tiffcp -c g4 -t -w 16 -l 16 "$f" "$t/gray1-g4-tiles.tif"

# JPEG (new style), libjpeg-turbo's under tiffcp: YCbCr 2×2 (tiffcp's
# default for RGB) in strips and tiles, at an odd size too; RGB; planar RGB;
# gray; white-is-zero gray; CMYK; RGB with alpha; and 12-bit gray and YCbCr.
im "$src/basn2c08.png" -resize '37x29!' -compress none "$base/odd.tif"
im "$src/basn0g08.png" -define quantum:polarity=min-is-white -compress none "$base/miw.tif"
im "$src/basn0g16.png" -depth 12 -compress none "$base/gray12.tif"
im "$src/basn2c16.png" -depth 12 -compress none "$base/rgb12.tif"
for n in rgb8 odd; do
  tiffcp -c jpeg "$base/$n.tif" "$t/$n-jpeg.tif"
  tiffcp -c jpeg:r "$base/$n.tif" "$t/$n-jpeg-rgb.tif"
  tiffcp -c jpeg:50 -r 16 "$base/$n.tif" "$t/$n-jpeg-strips.tif"
  tiffcp -c jpeg -t -w 16 -l 16 "$base/$n.tif" "$t/$n-jpeg-tiles.tif"
  tiffcp -c jpeg:r -p separate "$base/$n.tif" "$t/$n-jpeg-separate.tif"
done
tiffcp -c jpeg "$base/gray8.tif" "$t/gray8-jpeg.tif"
tiffcp -c jpeg -t -w 16 -l 16 "$base/gray8.tif" "$t/gray8-jpeg-tiles.tif"
tiffcp -c jpeg "$base/miw.tif" "$t/gray8-miniswhite-jpeg.tif"
tiffcp -c jpeg "$base/cmyk8.tif" "$t/cmyk8-jpeg.tif"
tiffcp -c jpeg:r "$base/rgba8.tif" "$t/rgba8-jpeg-rgb.tif"
tiffcp -c jpeg "$base/gray12.tif" "$t/gray12-jpeg.tif"
tiffcp -c jpeg -t -w 16 -l 16 "$base/rgb12.tif" "$t/rgb12-jpeg-tiles.tif"

# Pages of different sizes and kinds.
tiffcp "$base/rgb8.tif" "$base/gray4.tif" "$base/rgba16.tif" "$t/pages.tif"
im "$src/s01n3p01.png" "$src/s09n3p02.png" "$src/s32n3p04.png" -compress lzw "$t/pages-sizes.tif"
rm -rf "$base"
