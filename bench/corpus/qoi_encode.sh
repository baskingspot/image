# The QOI encode rows' inputs: every source as raw 8-bit pixels, RGBA when
# it has alpha and RGB otherwise, after a 12-byte header of little-endian
# u32s: width, height, and channels (bench/zig/qoi.zig reads it). Sourced
# by bench/corpus/generate.
le32() { printf "\\x$(printf %02x $(($1 & 255)))\\x$(printf %02x $(($1 >> 8 & 255)))\\x$(printf %02x $(($1 >> 16 & 255)))\\x$(printf %02x $(($1 >> 24 & 255)))"; }
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  read -r w h channels < <(magick identify -format '%w %h %[channels]\n' "$f[0]")
  case "$channels" in *a | *a[[:space:]]*) n=4 map=rgba ;; *) n=3 map=rgb ;; esac
  file="$dst/$cat-$(basename "$f" .png)-${w}x${h}.raw"
  { le32 "$w"; le32 "$h"; le32 "$n"; magick "$f[0]" -depth 8 "$map:-"; } > "$file"
done
