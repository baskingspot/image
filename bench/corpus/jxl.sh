# The JPEG XL rows' inputs: every source encoded by libjxl's cjxl at its
# defaults (effort 7), lossy at distance 1 into lossy/ and lossless into
# lossless/, on one thread. Sourced by bench/corpus/generate.
mkdir -p "$dst/lossy" "$dst/lossless"
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  name=$cat-$(basename "$f" .png)-$(size "$f").jxl
  cjxl --quiet --num_threads=0 -d 1 "$f" "$dst/lossy/$name"
  cjxl --quiet --num_threads=0 -d 0 "$f" "$dst/lossless/$name"
done
