# The JPEG XL encode rows' inputs: every source but the 50-megapixel mosaic
# (which libjxl's slowest efforts take minutes over) as raw 8-bit pixels,
# RGBA when it has alpha and RGB otherwise. Sourced by bench/corpus/generate.
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  [ "$cat" = photo_mosaic ] && continue
  read -r w h channels < <(magick identify -format '%w %h %[channels]\n' "$f[0]")
  case "$channels" in *a | *a[[:space:]]*) map=rgba ;; *) map=rgb ;; esac
  magick "$f[0]" -depth 8 "$map:$dst/$cat-$(basename "$f" .png)-${w}x${h}.raw"
done
