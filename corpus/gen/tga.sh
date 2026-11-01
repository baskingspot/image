# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
rm -rf "${out:?}/tga" && mkdir -p "$out/tga"

# TGA: color-mapped, truecolor, and gray, each uncompressed and RLE.
for c in none RLE; do
  im "$src/basn3p08.png" -type Palette -compress "$c" "$out/tga/cmap8-$c.tga"
  im "$src/basn2c08.png" -type TrueColor -compress "$c" "$out/tga/rgb24-$c.tga"
  im "$src/basn6a08.png" -type TrueColorAlpha -compress "$c" "$out/tga/rgba32-$c.tga"
  im "$src/basn0g08.png" -type Grayscale -compress "$c" "$out/tga/gray8-$c.tga"
done
