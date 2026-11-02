# The Netpbm rows' inputs, from every source by ImageMagick: raw PPM and
# PGM, 1-bit PBM (thresholded at 50%), and for the encode rows raw pixels
# with an 8-byte header (width and height, little-endian u32) in
# raw-<format>/. The 50-megapixel mosaic is left out of the 16-bit, PAM,
# plain, and PFM rows and their raw inputs, which would take gigabytes.
# Sourced by bench/corpus/generate.
mkdir -p "$dst"/{ppm,pgm,pbm,ppm16,pam,plain,pfm,raw-rgb8,raw-gray8,raw-rgba8,raw-rgb16}
# The 8-byte header of a W x H image.
dims() {
  local w=${1%x*} h=${1#*x}
  printf "$(printf '\\x%02x' $((w & 255)) $((w >> 8 & 255)) $((w >> 16 & 255)) $((w >> 24)) \
    $((h & 255)) $((h >> 8 & 255)) $((h >> 16 & 255)) $((h >> 24)))"
}
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  wh=$(size "$f")
  name="$cat-$(basename "$f" .png)-$wh"
  magick "$f" -alpha off -depth 8 "ppm:$dst/ppm/$name.ppm"
  magick "$f" -alpha off -colorspace Gray -depth 8 "pgm:$dst/pgm/$name.pgm"
  magick "$f" -alpha off -colorspace Gray -threshold 50% "pbm:$dst/pbm/$name.pbm"
  { dims "$wh" && magick "$f" -alpha off -depth 8 rgb:-; } > "$dst/raw-rgb8/$name.raw"
  { dims "$wh" && magick "$f" -alpha off -colorspace Gray -depth 8 gray:-; } > "$dst/raw-gray8/$name.raw"
  [ "$cat" = photo_mosaic ] && continue
  magick "$f" -alpha off -depth 16 "ppm:$dst/ppm16/$name.ppm"
  magick "$f" -alpha set -depth 8 "pam:$dst/pam/$name.pam"
  magick "$f" -alpha off -depth 8 -compress none "ppm:$dst/plain/$name.ppm"
  magick "$f" -alpha off -endian LSB "pfm:$dst/pfm/$name.pfm"
  { dims "$wh" && magick "$f" -alpha set -depth 8 rgba:-; } > "$dst/raw-rgba8/$name.raw"
  { dims "$wh" && magick "$f" -alpha off -depth 16 -endian LSB rgb:-; } > "$dst/raw-rgb16/$name.raw"
done
