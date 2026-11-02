# The TGA rows' inputs: every source as ImageMagick writes it in true color
# (24-bit, or 32-bit when the source has alpha), uncompressed in tga/none/
# and run-length encoded in tga/rle/; and the encoder rows' inputs in
# tga/rgba/: the source's raw RGB or RGBA pixels. Sourced by
# bench/corpus/generate.
mkdir -p "$dst"/{none,rle,rgba}
for f in "$src"/*/*.png; do
  wh=$(size "$f")
  name="$(basename "$(dirname "$f")")-$(basename "$f" .png)-$wh"
  case "$(magick identify -format '%A' "$f[0]")" in
    Undefined | False) type=(-alpha off -type TrueColor) map=rgb ;;
    *) type=(-type TrueColorAlpha) map=rgba ;;
  esac
  magick "$f" "${type[@]}" -compress None "$dst/none/$name.tga"
  magick "$f" "${type[@]}" -compress RLE "$dst/rle/$name.tga"
  magick "$f" -depth 8 "$map:$dst/rgba/$name.$map"
done
