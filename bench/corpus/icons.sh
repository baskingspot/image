# The rotating icon rows' inputs: 64 distinct icons from the suite's
# icon_64 category (every third by name), and each box-filtered to 16 and
# 32 pixels as the sources' small icons are, as PNG in icons/png/ (the
# suite's files at 64) and QOI in icons/qoi/ (qoi.h's encoder). A rotating
# row (bench/README.md) cycles through one size's icons, so no one file's
# branches are learned. Sourced by bench/corpus/generate.
mkdir -p "$dst"/{png,qoi} "$out/.tmp/icons"
tar tf "$out/.cache/qoi_benchmark_suite.tar" | grep '^images/icon_64/.*\.png$' | LC_ALL=C sort |
  awk 'NR % 3 == 1' | head -64 > "$out/.tmp/icons.list"
tar xf "$out/.cache/qoi_benchmark_suite.tar" -C "$out/.tmp/icons" -T "$out/.tmp/icons.list"
while read -r f; do
  name=$(clean "$f")
  cp "$out/.tmp/icons/$f" "$dst/png/icon-$name-$(size "$out/.tmp/icons/$f").png"
  for s in 16 32; do
    magick "$out/.tmp/icons/$f" -filter Box -resize "${s}x${s}!" "PNG32:$dst/png/icon-$name-${s}x$s.png"
  done
done < "$out/.tmp/icons.list"
rm -rf "$out/.tmp"
for f in "$dst"/png/*.png; do
  qoiconv "$f" "$dst/qoi/$(basename "$f" .png).qoi"
done
