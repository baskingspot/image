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

# Maxvals other than 255 and 65535, raw (ImageMagick writes plain files with
# maxval 65535 whatever the depth), two images in one file, PAM's tuple
# types, and big-endian color PFM; then small hand-written files for
# comments, plain files with other maxvals, and PAM's BLACKANDWHITE.
im "$src/basn0g08.png" -depth 4 "$out/netpbm/gray4-raw.pgm"
im "$src/basn0g16.png" -depth 10 "$out/netpbm/gray10-raw.pgm"
im "$src/basn2c08.png" -depth 5 "$out/netpbm/rgb5-raw.ppm"
im "$src/basn0g08.png" \( "$src/basn0g08.png" -negate \) "$out/netpbm/frames.pgm"
im "$src/basn2c08.png" \( "$src/basn2c08.png" -negate \) "$out/netpbm/frames.ppm"
im "$src/basn0g08.png" -colorspace Gray "$out/netpbm/gray8.pam"
im "$src/basn2c08.png" "$out/netpbm/rgb8.pam"
im "$src/basn2c08.png" -endian MSB "$out/netpbm/rgb-be.pfm"
printf 'P5\n# a comment\n4 2 # another\r255#\n\0\100\200\377\377\200\100\0' > "$out/netpbm/comment.pgm"
printf 'P2\n# feep\n4 2\n7\n0 1 2 3\n4 5 6 7\n' > "$out/netpbm/plain7.pgm"
printf 'P3 2 2 1000\n0 0 0 1000 1000 1000\n500 1 999 250 750 3\n' > "$out/netpbm/plain1000.ppm"
printf 'P7\nWIDTH 4\nHEIGHT 1\nDEPTH 1\nMAXVAL 1\nTUPLTYPE BLACKANDWHITE\nENDHDR\n\0\1\1\0' > "$out/netpbm/bw.pam"
# Header ends the specifications allow and MagickWand reads otherwise: a CR
# before ENDHDR's newline, and two whitespace characters after a PFM scale
# (the raster starts at the second), with tab and CR between the numbers.
printf 'P7\nWIDTH 4\nHEIGHT 1\nDEPTH 1\nMAXVAL 1\nTUPLTYPE BLACKANDWHITE\nENDHDR\r\n\0\1\1\0' > "$out/netpbm/crlf.pam"
printf 'Pf 1 2 1. \n\236\266\151\077\310\247\036\076' > "$out/netpbm/scale-spaces.pfm"
printf 'Pf 2\t\t\r1 -1. \n\0\0\200\077\0\0\0\077' > "$out/netpbm/separators.pfm"
