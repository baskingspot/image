# The GIF rows' inputs, written by ImageMagick. still/: every source as a
# 256-color GIF (ImageMagick's dithering, and a transparent index for
# sources with alpha), plus one photo and one icon interlaced. anim/:
# animations made from the sources, the kinds people meet:
#
# - icons-WxH: the 32- and 64-pixel icons in turn, optimized by ImageMagick
#   into frames that hold only what changed, with transparency.
# - pan-480x320: a Kodak photo panned, every pixel changing each frame.
# - screen-1280x720: a web screenshot with a highlight that moves, as a
#   screen recording is, optimized into small frames.
# - sprite-1600x900: an icon moving over a photo, each frame disposed to
#   previous (restore what was under it).
# - bounce-320x240: an icon moving over a transparent canvas, each frame
#   disposed to background.
#
# Sourced by bench/corpus/generate.
mkdir -p "$dst/still" "$dst/anim" "$dst/.tmp"
tmp=$dst/.tmp
for f in "$src"/*/*.png; do
  cat=$(basename "$(dirname "$f")")
  magick "$f" +repage "GIF:$dst/still/$cat-$(basename "$f" .png)-$(size "$f").gif"
done
kodak=("$src"/photo_kodak/*.png)
icons=("$src"/icon_64/*.png)
for f in "${kodak[0]}" "${icons[0]}"; do
  magick "$f" +repage -interlace GIF "GIF:$dst/still/variant_interlaced-$(basename "$f" .png)-$(size "$f").gif"
done

for s in 32 64; do
  magick -delay 20 -loop 0 "$src/icon_$s"/*.png -layers Optimize "GIF:$dst/anim/icons-${s}x$s.gif"
done

frames=()
for i in $(seq 0 11); do
  magick "${kodak[1]}" -resize 640x -crop "480x320+$((i * 12))+$((i * 8))" +repage "$tmp/pan$i.png"
  frames+=("$tmp/pan$i.png")
done
magick -delay 4 -loop 0 "${frames[@]}" "GIF:$dst/anim/pan-480x320.gif"

web=("$src"/screenshot_web/*.png)
magick "${web[0]}" -crop 1280x720+0+0 +repage "$tmp/screen.png"
frames=()
for i in $(seq 0 9); do
  x=$((100 + i * 90))
  magick "$tmp/screen.png" -fill '#3080ff' -draw "rectangle $x,300 $((x + 160)),340" "$tmp/screen$i.png"
  frames+=("$tmp/screen$i.png")
done
magick -delay 10 -loop 0 "${frames[@]}" -layers Optimize "GIF:$dst/anim/screen-1280x720.gif"

magick "${kodak[2]}" -resize '1600x900!' "$tmp/bg.png"
pages=()
for i in $(seq 0 7); do pages+=('(' "${icons[1]}" -set page "+$((100 + i * 170))+$((200 + i * 60))" ')'); done
magick -delay 8 -loop 0 -dispose none "$tmp/bg.png" -dispose previous "${pages[@]}" "GIF:$dst/anim/sprite-1600x900.gif"

pages=()
for i in $(seq 0 7); do pages+=('(' "${icons[2]}" -set page "+$((i * 32))+$(((i % 4) * 50))" ')'); done
magick -delay 8 -loop 0 -size 320x240 xc:none -dispose background "${pages[@]}" "GIF:$dst/anim/bounce-320x240.gif"
rm -rf "$tmp"
