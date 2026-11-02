# TIFF encode

Notes and decisions for `src/tiff/encode.zig`, `encode_lzw.zig`, and
`encode_packbits.zig`: what the encoder writes, why its layout differs from
libtiff's, and where it follows libtiff byte for byte. Sources: TIFF 6.0
(sections 2, 9 for PackBits, 13 for LZW, 14 for Predictor) and Adobe's
Technical Note 3 for Deflate. libtiff 4.7.2 is the oracle and the bar
(`docs/slop/results/tiff-encode-20261102.md`).

## Scope

- Classic TIFF, little endian, chunky strips, one IFD a page;
  `encode` writes one page and `encodePages` several, in order, with no
  delays (TIFF pages have none).
- Compression none, PackBits (32773), LZW (5), and Deflate (8, through
  `compress.zlib` at the PNG encoder's levels: `Effort.fast`, `.default`,
  `.best`; while `compress` has only levels 1 and 6, every effort is
  level 6, as in the PNG encoder). Predictor 2 before LZW and Deflate
  (`EncodeOptions.predictor`, on by default), never on a palette.
- The default compression is LZW with the predictor: every TIFF reader
  takes it, and on the bench corpus its files are 2% larger than Deflate's at twice the speed
  (results file). Owner may prefer `.none` (libtiff's own default) or
  `.deflate`.
- Stored samples keep the source's channels: gray (BlackIsZero), gray and
  alpha, RGB, RGBA, at 8 bits for 8-bit sources and 16 bits otherwise
  (float sources become 16-bit). Straight alpha is ExtraSamples 2,
  premultiplied alpha ExtraSamples 1. `cmyk8` and `cmyk16` are Separated
  (Photometric 5) with ink amounts, the maximum minus the inverted inks
  they hold (plan.md decision 15).
- An 8-bit RGB image of at most 256 colors becomes a palette of 1, 2, 4, or
  8 bits, colors in order of first appearance, when the indices and the
  color map (6 bytes a color, 16-bit samples) are smaller than the RGB
  pixels. `EncodeOptions.palette = false` turns it off.
- Resolution from `EncodeOptions.density`, an `image.Density` as
  `Config.metadata` reports it: per inch is ResolutionUnit 2 with X/1, per
  meter ResolutionUnit 3 (centimeter) with X/100, and a unitless density
  (an aspect ratio) ResolutionUnit 1 with X/1. Null writes no resolution
  tags.

## Layout: the IFD first

The encoder writes to an `Io.Writer`, which cannot go back. libtiff writes
the strips first and the IFD after them, then seeks back to patch the
header's offset (and tiffcp does the same). We write instead:

1. the header, its first-IFD offset 8;
2. each page's IFD at an even offset, then the values that do not fit in
   an entry, in tag order but with StripOffsets and then StripByteCounts
   last, then the strips; the next page's IFD follows the strips.

So the file reads forward: `image.tiff.Decoder` reads the IFD and its
values at `decodeConfig` and the strip arrays at `decodeFrame`, then the
strips, and needs no seeker. `harness.checkEncoder` decodes without a
seeker, so this is required, not only convenient.

The IFD needs every strip's byte count before the first strip is written.
An uncompressed page knows them. A compressed page is compressed once to
count, and each strip is copied as it is made into the writer's free buffer,
after the room the IFD needs; when every strip fits there (a fixed writer
for the output, as in memory), the IFD is filled in before them and the
writer takes both, so the page is compressed once. When the buffer runs
out (a file writer's few KiB), the rest are counted and the page is
compressed again to write. Caching the compressed strips in work memory
instead would cost work memory that grows with the file; the fallback costs time only. The results file measures all three:
one pass 1.9–2.0× the two, and ahead of libtiff on every row but Deflate.

## Strips

Rows per strip is `max(1, 8192 / stored_row_bytes)`, clamped to the height,
as libtiff's `TIFFDefaultStripSize` gives with no hint. That keeps the work
memory to a strip and its compressed form (about 24 KiB for LZW, plus a row
for palette scanning and 4 bytes a strip), and lets the oracle compare
libtiff's strips byte for byte. `EncodeOptions.rows_per_strip` overrides it;
larger strips make LZW and Deflate files smaller (LZW's table restarts each
strip) at a work memory of about three strips, measured in the results
file.

## Matching libtiff byte for byte

Whole files cannot match, because the layouts differ. The oracle
(`test/oracle/tiff_encode.zig`, `tiff_encode.c`) writes the same source
with libtiff at the same settings through `TIFFWriteEncodedStrip`, moves
libtiff's IFD, values, and strips into our layout, and compares every byte
(100,301 comparisons, 0 mismatches). Deflate is left out: libtiff's zlib
and `compress` make different valid streams, so Deflate is checked by
readback (libtiff decodes our files to our decoder's pixels) only. These
rules, found by experiment against libtiff, make the rest match:

- **StripByteCounts' type.** One strip: LONG. Several strips: SHORT when
  uncompressed with a nominal strip of at most 65535 bytes, or LZW or
  Deflate with a nominal strip under 6553 bytes (libtiff estimates a
  compressed strip at up to ten times its raw size); PackBits always LONG.
  Two SHORT counts fit in the entry.
- **ImageWidth, ImageLength, RowsPerStrip**: SHORT when they fit, else LONG.
- **PackBits** works a row at a time. A run of three or more bytes is a
  repeat packet; a run of two joins the current literal only when that
  literal holds 1 to 126 bytes and the next run is a single byte, and is a
  repeat otherwise. Worst case: n + min(n, (n + 2) / 3 + n / 128) bytes.
- **LZW**: MSB-first codes, 9 bits growing to 10, 11, and 12 once the next
  free entry is 512, 1024, and 2048 (one code early, as TIFF 6.0 has it),
  Clear at the start and when the next free entry would be 4094. At the end, the code counter steps
  past the last code; when that reaches 4094, a Clear comes before EOI,
  which is then 9 bits. The hash table is tagged by generation so a Clear
  costs nothing.

## Safety and memory

Nothing is allocated; `workLen(options, width, height)` is the most any
page no wider and no taller needs. Every page is checked (`PixelBuffer.check`,
non-empty, work large enough) before the first byte is written, offsets past
4 GiB are `error.ImageTooLarge`, and the fuzz target
(`test/fuzz/tiff_encode.zig`) encodes random sources with random options
and checks that our decoder reads back the source converted to the stored
format.

## Open

- LZW and PackBits are written here from the specification; the decoder's
  codecs are in the TIFF orb's files. Sharing a module (`src/tiff/lzw.zig`
  with both directions) is a request in the report, not done.
- `tiff_encode_readback` is an oracle format whose inputs are generated,
  not read from a corpus; a harness hook for "encode, then let the oracles
  decode" would let other encoders do the same.
