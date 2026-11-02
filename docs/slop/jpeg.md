# JPEG decode: notes and decisions

`src/jpeg/` is a streaming JPEG decoder written from ITU T.81 (the JPEG
process), T.871 (JFIF), and Adobe's APP14 note (the color transform).
libjpeg-turbo is the oracle and the bar, and owner decision 2 is to match its
default output bit for bit; its source was read only to settle behavior the
specifications leave open, never translated. This file records what the
decoder does where the specifications leave room, and why. Results:
`results/jpeg-20261102.md`.

Stage 1 (this one): sequential and progressive Huffman-coded DCT images with
8-bit samples (SOF0, SOF1, SOF2), restart intervals, every sampling factor
libjpeg-turbo accepts, grayscale, YCbCr, RGB, CMYK, and YCCK, DCT-domain
scaling to 1/2, 1/4, and 1/8, and JFIF density, EXIF orientation, ICC, EXIF,
and XMP reported. Stage 2: 12-bit samples (SOF1 and SOF2 with precision 12),
arithmetic coding (SOF9 to SOF11, DAC), and lossless (SOF3 and SOF11); they
are `Unsupported` until then.

## Shape

- `Decoder.zig` reads marker segments from the caller's `std.Io.Reader`
  through the first scan's header in `decodeConfig`, and the rest, through
  EOI, in `decodeFrame`. A single-scan sequential image decodes straight
  through: each iMCU row is Huffman-decoded, transformed into a ring of
  component rows, then upsampled, converted, and written to the destination
  row by row. A progressive or multi-scan image decodes every scan into a
  coefficient buffer in work memory, then transforms and writes it the same
  way, one iMCU row at a time.
- Work memory (`Config.work_len`): the eight Huffman tables (3.4 KiB each),
  each component's ring of sample rows (one iMCU row, or three when fancy
  upsampling needs the rows above and below), one upsampled row per
  component, a native row when the destination format differs, and, for a
  multi-scan image, every block's coefficients (128 bytes a block). So 28
  KiB for a 16×16 icon, 85 KiB for a 768×512 baseline photo, 643 KiB for the
  8192×6144 baseline mosaic, and 145 MiB for the same mosaic progressive,
  where libjpeg-turbo needs the same coefficient buffer.
- `huffman.zig`: the bit reader refills up to eight bytes at a time when
  none is 0xFF (a SWAR test), inline in the decode loop, and byte by byte
  around stuffing and markers. Tables have a 9-bit lookahead; AC tables also
  have a combined entry that decodes a short code and its magnitude bits in
  one lookup, or gives the code's symbol when only the code fits. The block
  decoders copy the reader's state into a local that never has its address
  taken, so it lives in registers; the slow refill takes and returns it by
  value.
- `idct.zig`: the islow IDCT (Loeffler, Ligtenberg, and Moschytz, 13-bit
  constants) at 8×8, 4×4, 2×2, and 1×1. Full-size 8-bit blocks go through
  `Queue`: a block whose AC coefficients are all zero is filled from its DC;
  one whose dequantized coefficients' magnitudes sum to at most 5,900 waits
  for a partner, and the two run together in 16-bit lanes, one block in each
  128-bit half, with every product pair a pmaddwd and the constants regrouped
  so that each output is four pairs (exact in integers); a sum to 15,000 runs
  in 32-bit vectors; anything larger in 64 bits, as the reference computes.
  The bounds are derived in the code from the largest weight any input has on
  any intermediate.
- `sample.zig`: fancy upsampling (h2v1, h1v2, h2v2) in 16-lane vectors with
  the reference's alternating rounding, box replication for every other
  integral ratio, and YCbCr to RGB. The conversion runs in 16-bit lanes: R's
  and B's terms are each one pmulhrsw, with constants an exhaustive search
  over the 256 chroma values found to reproduce the 32-bit formula exactly
  (a unit test checks every chroma pair), and G's two products one pmaddwd.
- `simd.zig`: pmaddwd, packssdw, and pmulhrsw as inline assembly on x86-64
  with AVX2, each with a portable fallback. LLVM does not choose them from
  portable vector code: it splits the multiply-add's pairs back into their
  sources and multiplies each in 32 bits, which made the IDCT 1.5× slower.
  The dependency `compress` uses inline assembly the same way for pshufb.

## Decisions

- **Pixels: libjpeg-turbo's defaults, bit for bit (decision 2).** Its islow
  IDCT, fancy upsampling (with its exceptions: no fancy upsampling at 1/8
  scale, or for a component two samples wide or less), and YCbCr to RGB in
  16-bit fixed point. Where its C and SIMD paths differ, only on corrupt data
  (the SIMD IDCT dequantizes in 16 bits and saturates), this package follows
  the C path, which computes in 64 bits and wraps: 16-bit quantization
  values are signed multipliers, the column pass keeps 32 bits, and results
  wrap to 10 bits around the center before clamping. Matching cost nothing
  measurable against libjpeg-turbo itself (results file), so there was no
  trade to make.
- **No block smoothing.** For a progressive image whose scans leave any of
  the first nine AC coefficients unrefined, libjpeg-turbo by default
  estimates them from the neighbors' DC (T.81 K.8 suggests the idea; its 5×5
  filter is its own). Every complete progression an encoder writes refines
  them, so smoothing changes nothing there; it changes files cut short, such
  as Wuffs's `peacock.progressive.scan00N.jpeg`. Matching it means
  reproducing libjpeg-turbo's filter, which is not in any specification, so
  this package writes what the scans coded, and the oracle turns smoothing
  off. **Owner decision:** keep this, or reproduce the filter from its
  description.
- **Strict, as libjpeg-turbo is when every warning is an error.** A
  truncated file, a segment whose length does not match its contents (DHT,
  DQT, DRI, SOF, SOS), an undefined Huffman code, a scan or restart interval
  whose data ends early, the wrong restart marker, a refinement coefficient
  whose size is not 1, or an inconsistent progression is an error. What
  libjpeg-turbo skips silently, this package skips too: bytes that are not a
  marker between segments, APPn and COM segments shorter than their length
  field, and a JFIF version other than 1.x. A sequential scan's DC predictor
  wraps as the reference's `int` does; a progressive DC past 32 bits is
  `BadCoefficient`, where the reference fails too.
- **Frame and scan rules, where T.81 leaves room**, follow libjpeg-turbo:
  dimensions to 65,500, one, three, or four components, sampling factors 1
  to 4, at most 10 blocks per MCU, quantization tables latched at a
  component's first scan, the K.3 standard Huffman tables for a sequential
  scan that names slot 0 or 1 without a DHT (Motion JPEG), and its quirk of
  matching a scan's component IDs only at or after the scan position.
  DCT-domain scaling picks each component's block size as libjpeg-turbo's
  `jpeg_core_output_dimensions` does, so a sampling ratio that does not
  divide evenly at the chosen scale is `Unsupported`, as it is there.
- **Color space.** Guessed from the markers as libjpeg-turbo guesses it: one
  component is gray; three are YCbCr unless an Adobe marker says transform 0
  or the IDs spell R, G, B; four are CMYK, or YCCK for Adobe transform 2. An
  Adobe transform past 2 is `BadMarker`. `Options.color` overrides the guess
  for a caller that knows better (TIFF's photometric interpretation).
- **CMYK and YCCK.** `PixelFormat` has no CMYK, so by default they decode to
  RGB by libjpeg-turbo's naive conversion (each channel is the ink's
  inverted sample times black's, over the maximum, rounded), the same as its
  `JCS_EXT_RGB` output from a CMYK file, and native is `rgb8`. With
  `Options.cmyk = .raw` they decode to the stored inks, C, M, Y, K in the
  R, G, B, A channels of `rgba8` (inverted, as Adobe writes them), for a
  caller with a color-management system. **Request:** a shared `cmyk8`
  pixel format (and `cmyk16` for 12-bit and TIFF), so that raw inks have
  their own name and `convert` can do the naive conversion for every
  format; `.raw` would then report `cmyk8` as native.
- **Metadata** is reported, never applied. JFIF density (dots per inch or
  per centimeter, the latter as per meter). EXIF: the blob, and the
  orientation from its first 4 KiB, through `src/exif.zig`. ICC: the
  profile reassembled from its APP2 segments in sequence order; it is
  reported once every segment has arrived and the bytes add up to the size
  the profile's header gives, and dropped (no error) if the segments are out
  of order, their counts disagree, or one is missing. XMP: the first XMP
  APP1 segment. Each blob goes to the blob sink as it passes.
- **TIFF's JPEG (compression 7).** `Options.tables` takes the bytes of a
  TIFF's JPEGTables tag: a table-specification stream (SOI, DQT, DHT, DRI,
  then EOI), whose tables load before the image stream's own markers, as T.81
  B.5 describes for abbreviated streams. Each strip or tile is then its own
  abbreviated image stream. `Options.color` takes the photometric
  interpretation: `.ycc` for YCbCr, `.none` for RGB, CMYK, and gray, so the
  Adobe marker and component IDs are not consulted. The TIFF decoder can test
  for the interface with `@hasDecl(image.jpeg.Decoder.Options, "tables")`
  or `@hasField`. Old-style JPEG (compression 6) is not supported.

## Testing

- Unit tests beside the code: the 32-bit and 16-bit IDCTs against the
  64-bit arithmetic on random blocks on both sides of each bound, the queue
  on mixed blocks, the vector upsampling against a scalar definition, the
  color conversion over every chroma pair, Huffman table building and the
  bit reader's stuffing, fill bytes, and markers, and decoder cases.
- The oracle (`test/oracle/jpeg.zig`, `jpeg.c`): libjpeg-turbo with SIMD
  off and block smoothing off, strict, reading through a 256-byte source
  manager (its fast Huffman path decodes a bad code as symbol 0 when 512
  bytes per block are buffered, instead of warning), and Wuffs as a second
  oracle. Both corpus files and fuzzed inputs: 0 mismatches; the splits are
  all Wuffs (its own edge upsampling and damaged-file handling).
- `djpeg` at every scale against this package on the corpus (libjpeg-turbo's
  and Wuffs's test images and the benchmark corpus): identical but for the
  12-bit and arithmetic files (stage 2) and the truncated progressive files
  (block smoothing).
- The fuzz target generates files by walking the decoder's states: metadata
  segments, quantization and Huffman tables (flat or standard), restart
  intervals, sequential and progressive scripts with refinement, and
  restart markers, and checks a scaled decode alongside the full one.
