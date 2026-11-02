# WBMP

Notes and decisions for `image.wbmp` (src/wbmp/). Measurements are in
results/wbmp-qoi-20261101.md.

## Format

WAP-237 (Wireless Application Environment), section 6 and appendix A: a
multi-byte integer type field, a fixed header octet, optional extension
headers, the width and height as multi-byte integers, then the rows, one bit
per pixel, most significant bit first, padded to an octet. 1 is white, 0
black. Type 0 is the only type the specification defines, and it has no
extension headers.

## Decoder decisions

- **Strict header.** The type must be the single octet 0 and the fixed
  header octet 0; anything else is `BadHeader`. Wuffs and ImageMagick both
  read these as two zero octets, so an overlong type (`0x80 0x00`) is
  rejected too.
- **Widths and heights as Wuffs reads them.** A multi-byte integer may
  take any number of octets, so leading zero groups (`0x80`) are accepted
  however many there are, as both Wuffs and ImageMagick accept them (an
  earlier five-octet cap left this package alone against both oracles on a
  height of 12 in nine octets). A value of 2^24 or more is `Unsupported`,
  as Wuffs calls it an unsupported dimension. ImageMagick has no cap of its
  own (its `size_t` shifts out high bits) but rejects a size larger than
  the file. Below 2^24, size is left to `Limits`.
- **Zero width or height** decodes to an empty image, as Wuffs does.
  ImageMagick rejects it. `image.detect` does not name such a file WBMP
  (detect.zig wants both dimensions nonzero), so only `Decoder.init(.wbmp)`
  or `image.wbmp.Decoder` reads one.
- **Nothing after the last row is read**, so trailing bytes are ignored and
  a reader shared with what follows is left just past the image.
- **Native format `gray8`**, 0 and 255. Other formats go through a 256-pixel
  gray span and `image.convert`.
- **Expansion** is a 256-entry table of eight output bytes per input octet:
  one load and one 8-byte store per octet. It is 48–114 times Wuffs to gray
  and 11–26 times to RGBA, and memory bound at large sizes, so SIMD was not
  tried.

## Encoder decisions

- A pixel is white when its gray value from `image.convert` (Rec. 601
  luma, alpha dropped, narrowed to 8 bits by the high byte since
  `convert` matched Wuffs) is at least 128. Black and white sources round-trip
  exactly; anything else is thresholded, so `harness.checkEncoder`'s exact
  round trip does not hold. test/fuzz/wbmp_encode.zig checks the same
  properties with the threshold applied (a private copy until the harness
  takes a hook; see the report).
- The padding bits at the end of a row are 0.
- No work memory: a 512-pixel gray span on the stack, packed 64 pixels at a
  time with one vector compare.
- ImageMagick's writer thresholds differently: on the same gray input it
  writes white for some values from 124 to 127. `wbmp-encode` is an `own`
  operation in bench/ops.tsv for that reason.

## Oracles

Wuffs and ImageMagick (test/oracle/wbmp.c). The expected split, ours and
Wuffs against ImageMagick, is ImageMagick rejecting zero-sized images and
reporting "insufficient image data" for some complete small files (its size
check is not the row arithmetic; adding a few trailing bytes makes it
accept them).
