# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick. Small JPEG XL
# files from libjxl's cjxl, each exercising a VarDCT or Modular path
# the conformance suite reaches only in large files: seeds the fuzzer and
# the oracle can run quickly. One thread, so the output does not depend on
# the machine.
rm -rf "${out:?}/jxl" && mkdir -p "$out/jxl"
tmp=$(mktemp -d)
cj() { cjxl --quiet --num_threads=0 "$@"; }
rgba="$src/basn6a08.png"
rgb="$src/basn2c08.png"
grey="$src/basn0g08.png"
cj -d 1 "$rgba" "$out/jxl/vardct-alpha.jxl"
cj -d 1 "$grey" "$out/jxl/vardct-grey.jxl"
# Grey with alpha and patches of a glyph repeated on a flat background:
# its dictionary frame keeps X, Y, and B for the patches.
im "$grey" -resize '12x16!' -threshold 50% -background white -gravity northwest -extent 14x20 "$tmp/grey-glyph.png"
im -size 14x20 xc:white "$tmp/grey-blank.png"
im "$tmp/grey-glyph.png" "$tmp/grey-glyph.png" "$tmp/grey-blank.png" +append "$tmp/grey-glyphs.png"
im -size 61x41 "tile:$tmp/grey-glyphs.png" -alpha set -channel A -fx 'j<20?1:0.5' +channel \
  -type GrayscaleAlpha "$tmp/grey-text.png"
cj -d 1 --patches=1 "$tmp/grey-text.png" "$out/jxl/vardct-grey-patches.jxl"
# The same in colour: the patches blend into the alpha, whose rows (61) are
# narrower than the colour planes' (64).
im "$tmp/grey-text.png" -colorspace sRGB -type TrueColorAlpha -fill '#204080' -opaque black \
  "$tmp/colour-text.png"
cj -d 1 --patches=1 "$tmp/colour-text.png" "$out/jxl/vardct-patches-alpha.jxl"
cj -d 4 -p "$rgb" "$out/jxl/vardct-progressive.jxl"
cj -d 2 --progressive_dc=1 "$rgb" "$out/jxl/vardct-lf-frame.jxl"
cj -d 2 --resampling=2 "$rgb" "$out/jxl/vardct-upsampling.jxl"
# Alpha stored at a quarter of the size and upsampled on its own.
cj -d 1 --ec_resampling=4 "$rgba" "$out/jxl/vardct-ec-upsampling.jxl"
cj -d 1 --photon_noise_iso=6400 "$rgb" "$out/jxl/vardct-noise.jxl"
cj -d 1 --epf=3 --gaborish=1 "$rgb" "$out/jxl/vardct-filters.jxl"
cj -d 2 -m 1 "$rgba" "$out/jxl/modular-lossy.jxl"
# JPEG recompression: YCbCr with 4:2:0 and 4:4:4 chroma, and a jbrd box.
im "$rgb" -quality 85 -sampling-factor 4:2:0 "$tmp/420.jpg"
im "$rgb" -quality 85 -sampling-factor 4:4:4 "$tmp/444.jpg"
cj --lossless_jpeg=1 "$tmp/420.jpg" "$out/jxl/jpeg-420.jxl"
cj --lossless_jpeg=1 "$tmp/444.jpg" "$out/jxl/jpeg-444.jxl"
# Five group rows (over 1024 tall), every EPF pass: streamed a group row at
# a time, and with its groups stored centre first (a permuted TOC), whole.
im "$rgb" -resize '8x1100!' "$tmp/tall.png"
cj -d 2 --epf=3 --gaborish=1 "$tmp/tall.png" "$out/jxl/vardct-tall.jxl"
cj -d 2 --epf=3 --gaborish=1 --group_order=1 "$tmp/tall.png" "$out/jxl/vardct-tall-centre.jxl"
# A 4:2:0 JPEG, recompressed, of five group rows and an odd width:
# streamed, its chroma upsampled a band at a time.
im "$rgb" -resize '17x1100!' -quality 85 -sampling-factor 4:2:0 "$tmp/tall-420.jpg"
cj --lossless_jpeg=1 "$tmp/tall-420.jpg" "$out/jxl/jpeg-tall-420.jxl"
# The same, streamed with its alpha.
im "$rgba" -resize '8x1100!' "$tmp/tall-alpha.png"
cj -d 2 --epf=3 --gaborish=1 "$tmp/tall-alpha.png" "$out/jxl/vardct-tall-alpha.jxl"
# Streamed with noise; upsampled twice with alpha (upsampled with the
# colors), an odd width; and with patches of a glyph repeated on a flat
# background, which cjxl takes into a dictionary frame, and alpha.
cj -d 2 --photon_noise_iso=6400 "$tmp/tall.png" "$out/jxl/vardct-tall-noise.jxl"
im "$rgba" -resize '17x2100!' "$tmp/tall-alpha-2x.png"
cj -d 2 --resampling=2 "$tmp/tall-alpha-2x.png" "$out/jxl/vardct-tall-upsampling.jxl"
im "$grey" -resize '12x16!' -threshold 50% -background white -gravity northwest -extent 14x20 \
  -colorspace sRGB -type TrueColor -fill '#204080' -opaque black "$tmp/glyph.png"
im -size 14x20 xc:white "$tmp/blank.png"
im "$tmp/glyph.png" "$tmp/glyph.png" "$tmp/blank.png" +append "$tmp/glyphs.png"
im -size 41x1100 "tile:$tmp/glyphs.png" -alpha set -channel A -fx 'j<550?1:0.5' +channel \
  -type TrueColorAlpha "$tmp/text.png"
cj -d 1 --patches=1 "$tmp/text.png" "$out/jxl/vardct-tall-patches.jxl"
# Two-level alpha, which cjxl palettes over the whole frame: the palette
# is undone on each band.
im "$tmp/tall-alpha.png" -channel A -threshold 50% +channel "$tmp/tall-alpha2.png"
cj -d 2 "$tmp/tall-alpha2.png" "$out/jxl/vardct-tall-alpha-palette.jxl"
# Lossless Modular, five group rows: streamed a group row at a time; with
# alpha, which cjxl palettes over the whole frame, streamed with the
# palette undone on each band; with alpha in 128-pixel groups (nine group
# rows), streamed; and squeezed (`-R 1`), which needs the whole frame.
cj -d 0 "$tmp/tall.png" "$out/jxl/modular-tall.jxl"
cj -d 0 "$tmp/tall-alpha.png" "$out/jxl/modular-tall-alpha.jxl"
cj -d 0 -g 0 "$tmp/tall-alpha.png" "$out/jxl/modular-tall-alpha-g128.jxl"
cj -d 0 -R 1 "$tmp/tall-alpha.png" "$out/jxl/modular-tall-squeeze.jxl"
# Three frames of animation.
im -delay 10 "$rgb" "$src/basn2c16.png" "$src/basn3p08.png" "$tmp/anim.gif"
cj -d 1 "$tmp/anim.gif" "$out/jxl/vardct-animation.jxl"
rm -rf "$tmp"
