# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
rm -rf "${out:?}/netpbm" && mkdir -p "$out/netpbm"

# Netpbm: every magic number, plain and raw, 8 and 16 bits, PAM, PFM.
im "$src/basn0g08.png" -threshold 50% -compress none "$out/netpbm/gray-plain.pbm"
im "$src/basn0g08.png" -threshold 50% "$out/netpbm/gray-raw.pbm"
im "$src/basn0g08.png" -compress none "$out/netpbm/gray8-plain.pgm"
im "$src/basn0g08.png" "$out/netpbm/gray8-raw.pgm"
im "$src/basn0g16.png" "$out/netpbm/gray16-raw.pgm"
im "$src/basn2c08.png" -compress none "$out/netpbm/rgb8-plain.ppm"
im "$src/basn2c08.png" "$out/netpbm/rgb8-raw.ppm"
im "$src/basn2c16.png" "$out/netpbm/rgb16-raw.ppm"
im "$src/basn2c16.png" -compress none "$out/netpbm/rgb16-plain.ppm"
im "$src/basn6a08.png" "$out/netpbm/rgba8.pam"
im "$src/basn4a08.png" "$out/netpbm/gray-alpha8.pam"
im "$src/basn6a16.png" "$out/netpbm/rgba16.pam"
im "$src/basn2c08.png" -endian LSB "$out/netpbm/rgb-le.pfm"
im "$src/basn0g08.png" -endian MSB "$out/netpbm/gray-be.pfm"
