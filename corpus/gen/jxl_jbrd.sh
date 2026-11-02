# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
#
# JPEG XL files that hold a JPEG to reconstruct: cjxl's lossless JPEG
# transcodes (--lossless_jpeg=1) of every JPEG in the fetched suites up to
# 128 KiB that cjxl takes (it refuses arithmetic coding, 12-bit samples,
# lossless, and CMYK), and of JPEGs from the dev shell's cjpeg for the
# layouts those leave out: every sampling, restarts in rows and MCUs,
# progressive scan scripts, 16-bit quantization tables, comments, APP
# markers of no known type, ICC profiles, Exif and XMP, fill bytes between
# markers, and bytes after EOI. Needs `just corpus` first. One thread, so
# the output does not depend on the machine.
rm -rf "${out:?}/jxl_jbrd" && mkdir -p "$out/jxl_jbrd"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' RETURN
[ -d fetched/wuffs ] || {
  echo "jxl_jbrd: run 'just corpus' first" >&2
  return 1
}

# transcode IN NAME: the transcode, when cjxl takes the JPEG.
transcode() {
  cjxl --quiet --num_threads=0 --lossless_jpeg=1 "$1" "$out/jxl_jbrd/$2.jxl" 2>/dev/null ||
    rm -f "$out/jxl_jbrd/$2.jxl"
}

while IFS= read -r f; do
  [ "$(stat -c %s "$f")" -le 131072 ] || continue
  name=$(basename "${f%.*}")
  [ -e "$out/jxl_jbrd/$name.jxl" ] && name="$(basename "$(dirname "$f")")-$name"
  transcode "$f" "$name"
done < <(find fetched -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) | LC_ALL=C sort)

# Sources: PngSuite's 32×32 color and gray images, and an odd size (39×39)
# so that MCUs are partial.
im "$src/basn2c08.png" "$tmp/rgb.ppm"
im "$src/basn0g08.png" "$tmp/gray.pgm"
im "$src/s39n3p04.png" -type TrueColor "$tmp/odd.ppm"

# cj NAME OPTION... INPUT: a cjpeg JPEG, transcoded.
cj() {
  local name=$1
  shift
  cjpeg "${@:1:$#-1}" -outfile "$tmp/$name.jpg" "${@: -1}"
  transcode "$tmp/$name.jpg" "gen-$name"
}

for s in 1x1 2x1 1x2 2x2; do
  cj "baseline-$s" -sample "$s" "$tmp/odd.ppm"
  cj "progressive-$s" -progressive -sample "$s" "$tmp/odd.ppm"
done
cj gray "$tmp/gray.pgm"
cj gray-progressive -progressive "$tmp/gray.pgm"
cj optimize -optimize "$tmp/odd.ppm"
cj restart-rows -restart 1 "$tmp/odd.ppm"
cj restart-mcus -restart 3B "$tmp/odd.ppm"
cj progressive-restart -progressive -restart 2B -sample 2x2 "$tmp/odd.ppm"
cj gray-progressive-restart -progressive -restart 1B "$tmp/gray.pgm"
cj q100 -quality 100 "$tmp/rgb.ppm"
cj q5 -quality 5 "$tmp/odd.ppm"
# One scan per component, interleaved and not.
printf '0: 0 63 0 0;\n1: 0 63 0 0;\n2: 0 63 0 0;\n' >"$tmp/separate.scan"
cj separate -scans "$tmp/separate.scan" "$tmp/odd.ppm"
printf '0: 0 63 0 0;\n1 2: 0 63 0 0;\n' >"$tmp/pair.scan"
cj pair -scans "$tmp/pair.scan" -sample 2x1 "$tmp/odd.ppm"
# Progressive: spectral selection alone, and successive approximation down
# to the last bit, with DC refinement in separate scans.
printf '0 1 2: 0 0 0 0;\n0: 1 9 0 0;\n0: 10 63 0 0;\n1: 1 63 0 0;\n2: 1 63 0 0;\n' >"$tmp/spectral.scan"
cj spectral -scans "$tmp/spectral.scan" "$tmp/odd.ppm"
printf '0 1 2: 0 0 0 2;\n0: 1 63 0 3;\n1: 1 63 0 2;\n2: 1 63 0 2;\n0 1 2: 0 0 2 1;\n0: 1 63 3 2;\n0: 1 63 2 1;\n1: 1 63 2 1;\n2: 1 63 2 1;\n0 1 2: 0 0 1 0;\n0: 1 5 1 0;\n0: 6 63 1 0;\n1: 1 63 1 0;\n2: 1 63 1 0;\n' >"$tmp/approx.scan"
cj approximation -scans "$tmp/approx.scan" -sample 2x2 "$tmp/odd.ppm"
# Quantization tables past 255, which take 16-bit entries.
{
  for _ in 1 2 3 4 5 6 7 8; do echo "300 300 300 300 300 300 300 300"; done
  for _ in 1 2 3 4 5 6 7 8; do echo "2 3 4 5 6 7 8 9"; done
} >"$tmp/q16.txt"
cj q16 -qtables "$tmp/q16.txt" -qslots 0,1,1 "$tmp/odd.ppm"
# Metadata: an ICC profile, one of more than 64 KiB split over several
# markers, a comment, and APP markers of no known type.
cj icc -icc fetched/wuffs/DCI-P3-D65.icc "$tmp/rgb.ppm"
cj icc-large -icc fetched/jpeg/libjpeg-turbo/test1.icc "$tmp/rgb.ppm"
cjpeg -outfile "$tmp/plain.jpg" "$tmp/odd.ppm"
wrjpgcom -comment "a comment for the transcode" "$tmp/plain.jpg" >"$tmp/comment.jpg"
transcode "$tmp/comment.jpg" gen-comment
# SOI, then the rest of plain.jpg with markers spliced in: APP3 and APP15
# of no known type, Exif, and XMP before it, fill bytes before its first
# marker, and bytes after EOI.
rest() { tail -c +3 "$tmp/plain.jpg"; }
seg() { printf "\\xff\\x$1\\x00\\x$(printf %02x $((${#2} + 2)))%s" "$2"; }
{
  printf '\xff\xd8'
  seg e3 "not a known type"
  seg ef "Ducky......"
  rest
} >"$tmp/apps.jpg"
transcode "$tmp/apps.jpg" gen-apps
{
  printf '\xff\xd8'
  printf '\xff\xe1\x00\x16Exif\x00\x00II*\x00\x08\x00\x00\x00\x00\x00'
  printf '\xff\xe1\x00\x44http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta xmlns:x="adobe:ns:meta/"/>'
  rest
} >"$tmp/exif-xmp.jpg"
transcode "$tmp/exif-xmp.jpg" gen-exif-xmp
{
  printf '\xff\xd8\xff\xff\xff'
  rest
} >"$tmp/fill.jpg"
transcode "$tmp/fill.jpg" gen-fill
{
  cat "$tmp/plain.jpg"
  printf 'trailing bytes'
} >"$tmp/tail.jpg"
transcode "$tmp/tail.jpg" gen-tail
