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
# Animations, eight frames each, as img2webp writes them lossy (quality 75)
# and lossless: a 64-pixel icon moving across a Kodak photo, which its
# encoder keeps as small frames that blend; a pngimg cutout moving on a
# transparent canvas, which blends and disposes; and a 64-pixel icon
# turning, for small images.
mkdir -p "$dst/anim" "$dst/.anim"
icon="$src/icon_64/actions_address_book_new.png"
cut="$src/pngimg/air_pump_PNG5.png"
for k in 0 1 2 3 4 5 6 7; do
  magick "$src/photo_kodak/kodim01.png" "$icon" -geometry "+$((k * 80))+$((k * 40))" -composite \
    "PNG24:$dst/.anim/sprite$k.png"
  magick "$cut" -resize 50% -background none -gravity northwest -extent 640x480 -roll "+$((k * 20))+$((k * 10))" \
    "PNG32:$dst/.anim/cutout$k.png"
  magick "$icon" -background none -rotate $((k * 45)) -gravity center -extent 64x64 "PNG32:$dst/.anim/turn$k.png"
done
for kind in sprite cutout turn; do
  name=$kind-$(size "$dst/.anim/${kind}0.png")
  img2webp -lossy -d 100 "$dst/.anim/$kind"[0-7].png -o "$dst/anim/lossy_$name.webp" > /dev/null 2>&1
  img2webp -lossless -d 100 "$dst/.anim/$kind"[0-7].png -o "$dst/anim/lossless_$name.webp" > /dev/null 2>&1
done
rm -r "$dst/.anim"
