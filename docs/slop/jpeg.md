# JPEG decode: notes and decisions

`src/jpeg/` is a streaming JPEG decoder written from ITU T.81 (the JPEG
process), T.871 (JFIF), and Adobe's APP14 note (the color transform).
libjpeg-turbo is the oracle and the bar, and owner decision 2 is to match its
default output bit for bit; its source was read only to settle behavior the
specifications leave open, never translated. This file records what the
decoder does where the specifications leave room, and why. Results:
`results/jpeg-20261102.md`.

Stage 1: sequential and progressive Huffman-coded DCT images with 8-bit
samples (SOF0, SOF1, SOF2), restart intervals, every sampling factor
libjpeg-turbo accepts, grayscale, YCbCr, RGB, CMYK, and YCCK, DCT-domain
scaling to 1/2, 1/4, and 1/8, and JFIF density, EXIF orientation, ICC, EXIF,
and XMP reported. Stage 2: 12-bit samples (SOF1, SOF2, SOF9, SOF10 with
precision 12), arithmetic coding (SOF9, SOF10, DAC), and lossless (SOF3,
process 14, precisions 2 to 16). What libjpeg-turbo does not decode is
`Unsupported`: lossless arithmetic coding (SOF11) and the hierarchical
processes.

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
- `arith.zig`: T.81 Annex D's decoder (Initdec, Decode, Renorm_d,
  Byte_in) with Table D.3 as data plus one state that never moves for the
  fixed one-half estimate, and the block decoders for sequential (F.2.4)
  and progressive (G.1.3) scans. Statistics live in work memory where the
  Huffman tables would, one area per table destination (16 of each, as DAC
  allows), reset at each scan and restart. K.4.1's test sequence is a unit
  test. Data that ends at a marker feeds zero bytes, as D.2.6 says, and that
  is not an error; data that ends at the end of the input is.
- Lossless (`losslessScan`): each iMCU row's differences into a row buffer,
  then each component's rows reconstructed (H.1.2.1's predictors, modulo
  2^16) into a second buffer, which keeps the row above, and scaled by the
  point transform into the sample rows. A single-scan image streams; one of
  several scans keeps every component's samples (2 bytes each past 8 bits).
  Each row decodes through a register copy of the bit reader, checked for
  overrun once a row (zeros past the end, at most 32 bits a value), with a
  path for scans whose components are all 1×1.
- 12-bit samples run the same pipeline on `u16` sample rows: the IDCT in 64
  bits, upsampling generic over the sample type. The output stage is
  specialized by color space and by the 12- and 16-bit precisions so its
  divisions are by constants, and 12-bit YCbCr converts and scales 16
  pixels at a time (`sample.yccToRgb16`): together 2.4× on 12-bit and 1.7×
  on lossless (results/jpeg-stage2-20261102.md).
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
- **CMYK and YCCK** (plan.md decision 15). By default they decode to RGB
  by libjpeg-turbo's naive conversion (each channel is the ink's inverted
  sample times black's, over the maximum, rounded), as djpeg converts its
  CMYK output, and native is `rgb8`. With `Options.cmyk = .raw` they decode
  to the inks, native `cmyk8` (`cmyk16` past 8 bits, scaled like every
  wide sample): the stored samples for CMYK, inverted as Adobe writes them,
  and for YCCK the YCbCr converted to RGB and inverted, as libjpeg-turbo
  returns them; another destination format converts from `cmyk8` through
  `image.convert`. At 8 bits both go through a `cmyk8` row
  (`sample.inks`, 16 pixels at a time) and the default converts it with
  `image.convert`'s SIMD kernel: 1.6× the per-pixel loop it replaced
  above icon sizes, 1.1× on icons (results/jpeg-cmyk-20261102.md). Past 8 bits the conversion stays at the
  image's precision, which libjpeg-turbo rounds at, not at 16 bits.
- **Metadata** is reported, never applied. JFIF density (dots per inch or
  per centimeter, the latter as per meter). EXIF: the blob, and the
  orientation from its first 4 KiB, through `src/exif.zig`. ICC: the
  profile reassembled from its APP2 segments in sequence order; it is
  reported once every segment has arrived and the bytes add up to the size
  the profile's header gives, and dropped (no error) if the segments are out
  of order, their counts disagree, or one is missing. XMP: the first XMP
  APP1 segment. Each blob goes to the blob sink as it passes.
- **Samples past 8 bits, and lossless ones below.** Native is 16-bit
  (`gray16`, `rgb16`, `cmyk16`) past 8 bits and 8-bit otherwise. Color
  conversion runs at the image's precision, as libjpeg-turbo's does, then
  each sample is scaled to the native format, rounded:
  `(v · 65535 + m/2) / m` for maximum `m`, and `(v · 255 + m/2) / m` below 8
  bits. libjpeg-turbo returns 12-bit samples for a 12-bit image and P-bit
  ones for a lossless one, so the oracle scales them the same way. A
  lossless sample that corrupt data reconstructs past the maximum (the
  reference keeps the low bits in its sample type, unsigned 16-bit past 8
  bits, 8-bit below) is clamped to it.
- **12-bit quantization values are unsigned.** libjpeg-turbo builds its
  12-bit code without SIMD, where the IDCT's multiplier type is `int`, not
  the 8-bit SIMD build's `short`, so a 16-bit quantization value past 32767
  multiplies as positive at 12 bits and negative at 8. Only corrupt files
  have such values.
- **A component two sequential scans name** gets the second scan's DC and
  nonzero AC coefficients over the first's, as libjpeg-turbo writes only
  nonzero coefficients into its coefficient buffer. (Its scan-position quirk
  for component IDs makes such files out of renumbered ones.)
- **Arithmetic coding** follows T.81, and where it leaves room
  libjpeg-turbo: DAC may set any Kx (T.81 allows 1 to 63; every value
  decodes), table destinations go to 15, a zero run past the band's end or a
  magnitude past 15 bits is `BadArithmeticCode` (the reference warns and
  stops decoding the scan), and the DC predictor of a progressive first
  scan fails past 32 bits as the Huffman one does.
- **Lossless**, where T.81 leaves room, follows libjpeg-turbo: a restart
  interval must be whole MCU rows (`BadRestart` otherwise), there are no
  standard Huffman tables, a three-component image without markers is RGB,
  a scan restarts its prediction at the first row of the iMCU row where a
  restart falls (in a single-component scan of a component sampled more
  than once vertically, that can be a row before the RSTn marker), and an
  image of several scans where some component has none is `BadScan` (the
  reference reads that component's samples uninitialized and fails). It
  does not convert colors in lossless mode, so a YCbCr or YCCK lossless
  image is `Unsupported` here: the conversion would undo the losslessness,
  and there would be nothing to match. **Owner decision:** convert them
  anyway, with the 8- or 12-bit formula, unchecked.
- **TIFF's JPEG (compression 7).** `Options.tables` takes the bytes of a
  TIFF's JPEGTables tag: a table-specification stream (SOI, DQT, DHT, DRI,
  then EOI), whose tables load before the image stream's own markers, as T.81
  B.5 describes for abbreviated streams. Each strip or tile is then its own
  abbreviated image stream. `Options.color` takes the photometric
  interpretation: `.ycc` for YCbCr, `.none` for RGB, CMYK, and gray, so the
  Adobe marker and component IDs are not consulted. The TIFF decoder can test
  for the interface with `@hasDecl(image.jpeg.Decoder.Options, "tables")`
  or `@hasField`. Old-style JPEG (compression 6) is not supported.
- **Work memory from the IFD.** `Decoder.workLen(params, options)` gives,
  from a `FrameParams` (width, height, component count, each component's
  sampling factors, precision, lossless, and `multi_scan`), the `work_len`
  that `decodeConfig` states for a stream with that frame header: it runs
  the same geometry (`setup`) on those fields, so the two agree exactly
  (the fuzz target checks it on every input). `multi_scan` (default true)
  provides for a progressive stream or one that codes its components in
  separate scans, which keeps every coefficient: for a tile that is two
  bytes per sample, for a whole-image strip as much as the image; false
  bounds single-scan streams, as libtiff writes, and `decodeFrame` then
  returns `error.WorkTooSmall` for a multi-scan one. A stream whose frame
  differs from the IFD gets the same check.
- **Edge tiles.** With `Options.crop`, `decodeFrame` takes a destination
  no larger than the frame and writes the frame's top-left `dst.width` ×
  `dst.height` pixels; the rest is decoded (so damage there still fails)
  but not written. An edge tile's part inside the image is its top-left, so
  TIFF passes a view of its page buffer (offset pointer, the page's stride,
  the clipped size) and needs no tile-sized scratch. A crop or a row
  callback for an arbitrary rectangle was the alternative; nothing needs it
  yet. The fuzz target checks a random crop against the full decode.

## Testing

- Unit tests beside the code: the 32-bit and 16-bit IDCTs against the
  64-bit arithmetic on random blocks on both sides of each bound, the queue
  on mixed blocks, the vector upsampling against a scalar definition, the
  color conversion over every chroma pair, Huffman table building and the
  bit reader's stuffing, fill bytes, and markers, the arithmetic decoder on
  K.4.1's test sequence, and decoder cases.
- The oracle (`test/oracle/jpeg.zig`, `jpeg.c`): libjpeg-turbo with SIMD
  off and block smoothing off, strict, reading through a 256-byte source
  manager (its fast Huffman path decodes a bad code as symbol 0 when 512
  bytes per block are buffered, instead of warning), and Wuffs as a second
  oracle for 8-bit Huffman-coded DCT images. RGB and gray, 8- and 16-bit:
  libjpeg-turbo's samples are read at their own precision (its 12- and
  16-bit entry points), scaled as this package scales them, and a gray
  image is decoded as gray and copied to RGB (lossless mode converts no
  colors). Both corpus files and fuzzed inputs: 0 mismatches; the splits
  are all Wuffs (its own edge upsampling and damaged-file handling).
- `djpeg` at every scale against this package on the corpus (libjpeg-turbo's
  and Wuffs's test images, the benchmark corpus, and the generated files):
  identical but for the truncated progressive files (block smoothing).
- `corpus/gen/jpeg.sh` writes what the public test images lack with cjpeg:
  arithmetic coding at each sampling, with restarts, progressive, and one
  scan per component; 12-bit Huffman and arithmetic, sequential and
  progressive; and lossless with every predictor, point transforms,
  precisions 2 to 16, subsampling, restarts, and one scan per component.
- The fuzz target generates files by walking the decoder's states: metadata
  segments, quantization and Huffman tables (flat or standard), restart
  intervals, sequential and progressive scripts with refinement, and
  restart markers, and checks a scaled decode alongside the full one.
  Stage 2 adds 12-bit frames, arithmetic-coded frames with DAC segments and
  random bytes for their data, and lossless frames of every precision and
  predictor with Huffman-coded differences.
