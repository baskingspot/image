# The QOI rows' inputs: every source, encoded by qoi.h's reference
# encoder. Sourced by bench/corpus/generate.
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  qoiconv "$f" "$dst/$cat-$(basename "$f" .png)-$(size "$f").qoi"
done
