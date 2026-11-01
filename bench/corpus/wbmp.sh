# The WBMP decode rows' inputs: every source made 1-bit by ImageMagick,
# dithered as a photo turned black and white is. Sourced by
# bench/corpus/generate.
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  magick "$f[0]" -monochrome "wbmp:$dst/$cat-$(basename "$f" .png)-$(size "$f").wbmp"
done
