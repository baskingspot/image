# The TGA rows' inputs: every source as ImageMagick writes it in true color
# (24-bit, or 32-bit when the source has alpha), uncompressed in tga/none/
# and run-length encoded in tga/rle/; and the encoder rows' inputs in
# tga/rgba/: the source's RGB or RGBA pixels after an 8-byte header, the
# width and height as little-endian 32-bit integers. Sourced by
# bench/corpus/generate.
mkdir -p "$dst"/{none,rle,rgba}
le32() {
  # shellcheck disable=SC2059
  printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"
}
for f in "$src"/*/*.png; do
  wh=$(size "$f")
  name="$(basename "$(dirname "$f")")-$(basename "$f" .png)-$wh"
  case "$(magick identify -format '%A' "$f[0]")" in
    Undefined | False) type=(-alpha off -type TrueColor) map=rgb ;;
    *) type=(-type TrueColorAlpha) map=rgba ;;
  esac
  magick "$f" "${type[@]}" -compress None "$dst/none/$name.tga"
  magick "$f" "${type[@]}" -compress RLE "$dst/rle/$name.tga"
  {
    le32 "${wh%x*}"
    le32 "${wh#*x}"
    magick "$f" -depth 8 "$map:-"
  } > "$dst/rgba/$name.$map"
done
