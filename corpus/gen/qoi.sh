# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
rm -rf "${out:?}/qoi" && mkdir -p "$out/qoi"

# QOI: the reference encoder on every 8-bit RGB and RGBA PngSuite basic
# image and a few filtered ones, three and four channels.
for f in "$src"/bas[in]2c08.png "$src"/bas[in]6a08.png "$src"/basn[26]?16.png "$src"/tbrn2c08.png "$src"/f0[0-4]n2c08.png; do
  qoiconv "$f" "$out/qoi/$(basename "${f%.png}").qoi"
done
