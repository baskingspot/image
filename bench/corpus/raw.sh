# The conversion rows' inputs, raw pixels in raw/<format>/ at 16x16 to
# 4096x4096: a photo with alpha (the first pngimg source) as RGBA, 8 and
# 16 bits (little endian), and a Kodak photo as RGB and gray. Sourced by
# bench/corpus/generate.
pngimg=("$src"/pngimg/*.png)
kodak=("$src"/photo_kodak/*.png)
alpha=${pngimg[0]}
photo=${kodak[0]}
mkdir -p "$dst"/{rgba8,rgb8,gray8,rgba16}
for s in 16 64 256 1024 4096; do
  magick "$alpha" -resize "${s}x${s}!" -depth 8 "rgba:$dst/rgba8/alpha-${s}x${s}.raw"
  magick "$alpha" -resize "${s}x${s}!" -depth 16 -endian LSB "rgba:$dst/rgba16/alpha-${s}x${s}.raw"
  magick "$photo" -resize "${s}x${s}!" -depth 8 "rgb:$dst/rgb8/photo-${s}x${s}.raw"
  magick "$photo" -resize "${s}x${s}!" -colorspace Gray -depth 8 "gray:$dst/gray8/photo-${s}x${s}.raw"
done
