# The QOI encode rows' inputs: every source as raw 8-bit pixels, RGBA when
# it has alpha and RGB otherwise. Sourced by bench/corpus/generate.
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  read -r w h channels < <(magick identify -format '%w %h %[channels]\n' "$f[0]")
  case "$channels" in *a | *a[[:space:]]*) map=rgba ;; *) map=rgb ;; esac
  magick "$f[0]" -depth 8 "$map:$dst/$cat-$(basename "$f" .png)-${w}x${h}.raw"
done
