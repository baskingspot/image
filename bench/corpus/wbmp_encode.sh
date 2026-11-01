# The WBMP encode rows' inputs: every source as raw 8-bit gray, which the
# encoders threshold, after a 12-byte header of little-endian u32s: width,
# height, and channels (1). Sourced by bench/corpus/generate.
le32() { printf "\\x$(printf %02x $(($1 & 255)))\\x$(printf %02x $(($1 >> 8 & 255)))\\x$(printf %02x $(($1 >> 16 & 255)))\\x$(printf %02x $(($1 >> 24 & 255)))"; }
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  read -r w h < <(magick identify -format '%w %h\n' "$f[0]")
  file="$dst/$cat-$(basename "$f" .png)-${w}x${h}.raw"
  { le32 "$w"; le32 "$h"; le32 1; magick "$f[0]" -colorspace Gray -depth 8 "gray:-"; } > "$file"
done
