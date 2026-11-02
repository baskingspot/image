# The GIF encode rows' inputs, raw RGBA8, ImageMagick's export:
#
# - true/: the first source of each category with more than 256 colors,
#   which the encoders quantize: icons, photos, screenshots, a texture with
#   alpha, and the 50-megapixel mosaic's top left 4096x4096 (the whole
#   mosaic takes gifski and ImageMagick 2.5 GB each, and with every arm's
#   server holding its peak, more than an 8 GB machine has).
# - few/: sources after ImageMagick's 256-color GIF writer (its dithering,
#   transparency as one color), which an encoder can store exactly.
# - anim/: an animation's frames one after another in a file, each the
#   whole canvas, its frame count the file's length over the canvas's:
#   icons-64x64, the 64-pixel icons in turn, with alpha; pan-480x320, a
#   Kodak photo panned, every pixel changing; screen-1280x720, a web
#   screenshot with a highlight that moves, as a screen recording is;
#   sprite-1600x900, an icon moving over a photo.
#
# Sourced by bench/corpus/generate.
mkdir -p "$dst/true" "$dst/few" "$dst/anim" "$dst/.tmp"
tmp=$dst/.tmp
first() { find "$src/$1" -name '*.png' | LC_ALL=C sort | head -1; }
raw() { magick "$1" -depth 8 "rgba:$2"; }

magick "$src/photo_mosaic/50mp.png" -crop 4096x4096+0+0 +repage "$tmp/mosaic16mp.png"
for f in $(first icon_32) $(first icon_64) $(first icon_512) $(first photo_kodak) \
  $(first photo_tecnick) $(first photo_wikipedia) $(first pngimg) $(first screenshot_game) \
  $(first screenshot_web) $(first textures_plants) "$tmp/mosaic16mp.png"; do
  cat=$(basename "$(dirname "$f")")
  [ "$cat" = .tmp ] && cat=photo_mosaic
  raw "$f" "$dst/true/$cat-$(basename "$f" .png)-$(size "$f").raw"
done
for f in $(first icon_16) $(first icon_32) $(first icon_64) $(first icon_512) $(first photo_kodak) \
  $(first photo_wikipedia) $(first pngimg) $(first screenshot_game) $(first screenshot_web) \
  $(first textures_pk) "$tmp/mosaic16mp.png"; do
  cat=$(basename "$(dirname "$f")")
  [ "$cat" = .tmp ] && cat=photo_mosaic
  magick "$f" +repage "GIF:$tmp/few.gif"
  raw "$tmp/few.gif" "$dst/few/$cat-$(basename "$f" .png)-$(size "$f").raw"
done

raw "$src/icon_64/*.png" "$dst/anim/icons-64x64.raw"

kodak=("$src"/photo_kodak/*.png)
frames=()
for i in $(seq 0 11); do
  magick "${kodak[1]}" -resize 640x -crop "480x320+$((i * 12))+$((i * 8))" +repage "$tmp/pan$i.png"
  frames+=("$tmp/pan$i.png")
done
magick "${frames[@]}" -depth 8 "rgba:$dst/anim/pan-480x320.raw"

web=("$src"/screenshot_web/*.png)
magick "${web[0]}" -crop 1280x720+0+0 +repage "$tmp/screen.png"
frames=()
for i in $(seq 0 9); do
  x=$((100 + i * 90))
  magick "$tmp/screen.png" -fill '#3080ff' -draw "rectangle $x,300 $((x + 160)),340" "$tmp/screen$i.png"
  frames+=("$tmp/screen$i.png")
done
magick "${frames[@]}" -depth 8 "rgba:$dst/anim/screen-1280x720.raw"

icons=("$src"/icon_64/*.png)
magick "${kodak[2]}" -resize '1600x900!' "$tmp/bg.png"
frames=()
for i in $(seq 0 7); do
  magick "$tmp/bg.png" "${icons[1]}" -geometry "+$((100 + i * 170))+$((200 + i * 60))" -composite "$tmp/sprite$i.png"
  frames+=("$tmp/sprite$i.png")
done
magick "${frames[@]}" -depth 8 "rgba:$dst/anim/sprite-1600x900.raw"
rm -rf "$tmp"
