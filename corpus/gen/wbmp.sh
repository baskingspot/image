# Sourced by corpus/generate, with $src (PngSuite) and $out
# (corpus/vendor/generated) set and `im` running ImageMagick.
rm -rf "${out:?}/wbmp" && mkdir -p "$out/wbmp"

# WBMP: type 0, from gray, at two widths (one not a multiple of 8).
im "$src/basn0g08.png" -threshold 50% "$out/wbmp/32x32.wbmp"
im "$src/basn0g08.png" -crop 29x17+0+0 -threshold 50% "$out/wbmp/29x17.wbmp"
