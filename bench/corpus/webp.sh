# The WebP rows' inputs: every source as cwebp writes it with its default
# settings, lossless (`-lossless`: quality 75, method 4) and lossy (quality
# 75), so the lossy rows of sources with alpha carry an ALPH chunk. The
# 50-megapixel mosaic's lossless file names 278 prefix code groups, more
# than the 256 Wuffs reads, so it has a row of its own, which Wuffs's arm
# leaves out. Sourced by bench/corpus/generate.
mkdir -p "$dst/lossless" "$dst/lossless-large" "$dst/lossy"
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  name=$cat-$(basename "$f" .png)-$(size "$f")
  if [ "$cat" = photo_mosaic ]; then
    cwebp -quiet -lossless "$f" -o "$dst/lossless-large/$name.webp"
  else
    cwebp -quiet -lossless "$f" -o "$dst/lossless/$name.webp"
  fi
  cwebp -quiet "$f" -o "$dst/lossy/$name.webp"
done
