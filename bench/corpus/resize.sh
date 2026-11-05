# The resize rows' inputs, raw pixels in resize/<kind>/: glyph-sized
# coverage and color bitmaps at 16 to 256 pixels square (the suite's three
# 512-pixel icons and the one 64-pixel icon it has no larger copy of: their
# alpha as gray8, and the icons as premultiplied BGRA), photos at
# 4000x3000 for thumbnails (the 50-megapixel mosaic and a Wikipedia photo),
# and Kodak photos at 512x384 and 1000x750 for doubling, as RGB. Sourced by
# bench/corpus/generate.
icons=("$src"/icon_512/*.png "$src"/icon_64/actions_contact_new.png)
mkdir -p "$dst"/{gray8,bgra8p,photo,photo-small}
for f in "${icons[@]}"; do
  n=$(clean "$f")
  for s in 16 32 64 128 256; do
    magick "$f" -resize "${s}x${s}!" -alpha extract -depth 8 "gray:$dst/gray8/$n-${s}x${s}.raw"
    # Premultiplied: the colors associated with alpha, alpha put back.
    magick "$f" -resize "${s}x${s}!" -write mpr:a +delete \( mpr:a -alpha associate -alpha off \) \
      \( mpr:a -alpha extract \) -compose CopyOpacity -composite -depth 8 "bgra:$dst/bgra8p/$n-${s}x${s}.raw"
  done
done
wiki=("$src"/photo_wikipedia/*.png)
magick "$src/photo_mosaic/50mp.png" -resize '4000x3000!' -depth 8 "rgb:$dst/photo/mosaic-4000x3000.raw"
magick "${wiki[0]}" -resize '4000x3000!' -depth 8 "rgb:$dst/photo/wikipedia-4000x3000.raw"
kodak=("$src"/photo_kodak/*.png)
for k in "${kodak[@]:0:2}"; do
  for s in 512x384 1000x750; do
    magick "$k" -resize "$s!" -depth 8 "rgb:$dst/photo-small/$(clean "$k")-$s.raw"
  done
done
