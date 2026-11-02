# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
#
# JPEG: the processes libjpeg-turbo's and Wuffs's test images leave out,
# written by the dev shell's cjpeg (libjpeg-turbo): arithmetic coding,
# 12-bit samples, and lossless, at several sampling factors, with restart
# intervals, and progressive.
rm -rf "${out:?}/jpeg" && mkdir -p "$out/jpeg"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' RETURN

# Sources: PngSuite's 32×32 color and gray images, 8- and 16-bit, and an
# odd size (39×39) so that MCUs are partial.
im "$src/basn2c08.png" "$tmp/rgb8.ppm"
im "$src/basn2c16.png" -depth 16 "$tmp/rgb16.ppm"
im "$src/basn0g08.png" "$tmp/gray8.pgm"
im "$src/basn0g16.png" -depth 16 "$tmp/gray16.pgm"
im "$src/s39n3p04.png" -type TrueColor "$tmp/odd8.ppm"
im "$src/s39n3p04.png" -type TrueColor -depth 16 "$tmp/odd16.ppm"

# cj NAME OPTION... INPUT
cj() {
  local name=$1
  shift
  cjpeg "${@:1:$#-1}" -outfile "$out/jpeg/$name.jpg" "${@: -1}"
}

# Arithmetic coding: sequential at each common sampling, gray, restarts in
# rows and in MCUs, progressive, and a scan script of separate components.
for s in 1x1 2x1 1x2 2x2 4x1; do
  cj "arith-$s" -arithmetic -sample "$s" "$tmp/odd8.ppm"
done
cj arith-gray -arithmetic "$tmp/gray8.pgm"
cj arith-restart-rows -arithmetic -restart 1 "$tmp/odd8.ppm"
cj arith-restart-mcus -arithmetic -restart 3B "$tmp/odd8.ppm"
cj arith-progressive -arithmetic -progressive "$tmp/odd8.ppm"
cj arith-progressive-gray -arithmetic -progressive "$tmp/gray8.pgm"
cj arith-progressive-restart -arithmetic -progressive -restart 2B "$tmp/rgb8.ppm"
cj arith-q100 -arithmetic -quality 100 "$tmp/rgb8.ppm"
printf '0: 0 63 0 0;\n1: 0 63 0 0;\n2: 0 63 0 0;\n' >"$tmp/separate.scan"
cj arith-separate -arithmetic -scans "$tmp/separate.scan" "$tmp/odd8.ppm"

# 12-bit samples: Huffman and arithmetic, sequential and progressive.
for s in 1x1 2x2 2x1; do
  cj "p12-$s" -precision 12 -sample "$s" "$tmp/odd16.ppm"
done
cj p12-gray -precision 12 "$tmp/gray16.pgm"
cj p12-optimize -precision 12 -optimize "$tmp/rgb16.ppm"
cj p12-restart -precision 12 -restart 1 "$tmp/rgb16.ppm"
cj p12-progressive -precision 12 -progressive "$tmp/odd16.ppm"
cj p12-arith -precision 12 -arithmetic "$tmp/rgb16.ppm"
cj p12-arith-progressive -precision 12 -arithmetic -progressive "$tmp/odd16.ppm"
cj p12-q100 -precision 12 -quality 100 "$tmp/rgb16.ppm"

# Lossless (process 14): every predictor; point transforms; precisions
# from 2 to 16, gray and RGB; subsampling; restarts; and one scan per
# component.
for psv in 1 2 3 4 5 6 7; do
  cj "lossless-psv$psv" -lossless "$psv" "$tmp/odd8.ppm"
done
cj lossless-pt3 -lossless 1,3 "$tmp/rgb8.ppm"
for p in 2 4 6; do
  cj "lossless-p$p-gray" -precision "$p" -lossless 4 "$tmp/gray8.pgm"
done
for p in 10 12 13 16; do
  cj "lossless-p$p" -precision "$p" -lossless 6 "$tmp/odd16.ppm"
  cj "lossless-p$p-gray" -precision "$p" -lossless 7,1 "$tmp/gray16.pgm"
done
cj lossless-2x2 -lossless 1 -sample 2x2,1x1,1x1 "$tmp/odd8.ppm"
cj lossless-2x1-p12 -precision 12 -lossless 5 -sample 2x1,1x1,1x1 "$tmp/odd16.ppm"
cj lossless-restart -lossless 2 -restart 2 "$tmp/odd8.ppm"
printf '0: 1 0 0 0;\n1: 1 0 0 0;\n2: 1 0 0 0;\n' >"$tmp/lossless.scan"
cj lossless-separate -lossless 1 -scans "$tmp/lossless.scan" -restart 1 "$tmp/odd8.ppm"
