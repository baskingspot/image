# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
rm -rf "${out:?}/tga" && mkdir -p "$out/tga"

# TGA: color-mapped, truecolor, and gray, each uncompressed and RLE.
for c in none RLE; do
  im "$src/basn3p08.png" -type Palette -compress "$c" "$out/tga/cmap8-$c.tga"
  im "$src/basn2c08.png" -type TrueColor -compress "$c" "$out/tga/rgb24-$c.tga"
  im "$src/basn6a08.png" -type TrueColorAlpha -compress "$c" "$out/tga/rgba32-$c.tga"
  im "$src/basn0g08.png" -type Grayscale -compress "$c" "$out/tga/gray8-$c.tga"
  # 16-bit color, opaque and with an alpha bit; color maps of 16- and
  # 32-bit entries.
  im "$src/basn2c08.png" -depth 5 -compress "$c" "$out/tga/rgb16-$c.tga"
  im "$src/basn6a08.png" -depth 5 -compress "$c" "$out/tga/rgba16-$c.tga"
  im "$src/basn3p08.png" -depth 5 -type Palette -compress "$c" "$out/tga/cmap16-$c.tga"
  im "$src/basn6a08.png" -colors 64 -type PaletteAlpha -compress "$c" "$out/tga/cmap32-$c.tga"
done
# The three other origins.
for o in bottom-left top-right bottom-right; do
  im "$src/basn2c08.png" -orient "$o" "$out/tga/rgb24-$o.tga"
  im "$src/basn6a08.png" -orient "$o" -compress RLE "$out/tga/rgba32-RLE-$o.tga"
done

# What ImageMagick does not write, as bytes: numbers on stdin, written as
# 8-bit, 16-bit (w), or 32-bit (l) little-endian values.
bytes() {
  LC_ALL=C gawk -b '{
    for (i = 1; i <= NF; i++) {
      v = $i; n = 1
      if (v ~ /w$/) { n = 2; sub(/w$/, "", v) } else if (v ~ /l$/) { n = 4; sub(/l$/, "", v) }
      for (k = 0; k < n; k++) { printf "%c", v % 256; v = int(v / 256) }
    }
  }'
}
# header ID-LENGTH MAP-TYPE IMAGE-TYPE FIRST LENGTH ENTRY-BITS WIDTH HEIGHT DEPTH DESCRIPTOR
header() { echo "$1 $2 $3 ${4}w ${5}w $6 0w 0w ${7}w ${8}w $9 ${10}" | bytes; }

# 15-bit color: the 16-bit file's pixels, whose top bits are clear.
for c in none RLE; do
  { header 0 0 "$([ $c = none ] && echo 2 || echo 10)" 0 0 0 32 32 15 32
    tail -c +19 "$out/tga/rgb16-$c.tga"; } > "$out/tga/rgb15-$c.tga"
done

# 16-bit gray and alpha, bottom-left, from PngSuite's gray-and-alpha image.
{ header 0 0 3 0 0 0 32 32 16 8
  im "$src/basn4a08.png" -flip -depth 8 rgba:- | od -An -v -tu1 | gawk '{ for (i = 1; i <= NF; i += 4) print $i, $(i + 3) }' | bytes; } \
  > "$out/tga/gray16-none.tga"

# A 300-entry color map of 24-bit entries starting at entry 100, read
# through 16-bit indices, with an image ID; and the same run-length encoded,
# with runs that cross scan lines, and a top-right origin.
map() { seq 0 299 | gawk '{ print $1 % 256, (255 - $1) % 256, ($1 * 7) % 256 }' | bytes; }
{ header 5 1 1 100 300 24 16 16 16 0
  printf 'tga16'
  map
  seq 0 255 | gawk '{ print (100 + ($1 * 37) % 300) "w" }' | bytes; } > "$out/tga/cmap24-index16-first100.tga"
{ header 0 1 9 100 300 24 16 16 16 48
  map
  # Eight runs of 24 pixels, then 64 raw pixels in packets of 32.
  seq 0 7 | gawk '{ print 128 + 23, (100 + $1 * 41) "w" }' | bytes
  for p in 0 1; do
    { echo 31; seq 0 31 | gawk -v p=$p '{ print (100 + (p * 32 + $1) * 3) "w" }'; } | bytes
  done; } > "$out/tga/cmap24-index16-RLE-crossing.tga"

# TGA 2.0 footers: an extension area right after the image (key color,
# aspect ratio 2:1, gamma 2.2, premultiplied alpha), and one after a
# postage stamp, right before the footer.
extension() {
  { echo 495w; seq 1 468 | gawk '{ printf "0 " }'; echo; echo "$1 2w 1w 22w 10w 0l 0l 0l $2"; } | bytes
}
footer() { { echo "${1}l 0l"; } | bytes; printf 'TRUEVISION-XFILE.\0'; }
f="$out/tga/rgba32-none.tga"
n=$(stat -c %s "$f")
{ cat "$f"; extension "1 2 3 128" 4; footer "$n"; } > "$out/tga/rgba32-extension.tga"
{ cat "$f"; echo "2 2 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16" | bytes; extension "0 0 0 0" 3; footer $((n + 18)); } \
  > "$out/tga/rgba32-stamp-extension.tga"
f="$out/tga/gray8-RLE.tga"
{ cat "$f"; footer 0; } > "$out/tga/gray8-RLE-footer.tga"
