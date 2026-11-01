# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
rm -rf "${out:?}/ico" "$out/cur" && mkdir -p "$out/ico" "$out/cur"

# ICO: one 32-bit BMP entry, five BMP sizes up to 256 (stored as 0), a
# palette image's sizes, and one PNG entry: a PngSuite file as it is.
im "$src/basn6a08.png" "$out/ico/rgba32-one.ico"
im "$src/basn6a08.png" -define icon:auto-resize=256,64,48,32,16 "$out/ico/sizes.ico"
im "$src/basn3p08.png" -define icon:auto-resize=32,16 "$out/ico/palette-sizes.ico"
le32() { printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)); }
png="$src/basn6a08.png"
{
  printf '\x00\x00\x01\x00\x01\x00'
  printf '\x20\x20\x00\x00\x01\x00\x20\x00'"$(le32 "$(stat -c %s "$png")")$(le32 22)"
  cat "$png"
} > "$out/ico/png-one.ico"

# CUR: the ICO files with the type set to 2 and hotspots (3, 5) in place of
# planes and bit count, which is all that distinguishes the formats.
for f in rgba32-one sizes png-one; do
  cp "$out/ico/$f.ico" "$out/cur/$f.cur"
  printf '\x02' | dd of="$out/cur/$f.cur" bs=1 seek=2 conv=notrunc status=none
  count=$(od -An -tu2 -j4 -N2 --endian=little "$out/cur/$f.cur" | tr -d ' ')
  for ((i = 0; i < count; i++)); do
    printf '\x03\x00\x05\x00' | dd of="$out/cur/$f.cur" bs=1 seek=$((6 + 16 * i + 4)) conv=notrunc status=none
  done
done
