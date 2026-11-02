# The WBMP encode rows' inputs: every source as raw 8-bit gray, which the
# encoders threshold. Sourced by bench/corpus/generate.
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  wh=$(size "$f")
  magick "$f[0]" -colorspace Gray -depth 8 "gray:$dst/$cat-$(basename "$f" .png)-$wh.raw"
done
