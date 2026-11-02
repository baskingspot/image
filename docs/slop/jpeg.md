# JPEG: notes and decisions

`src/jpeg/` is a streaming JPEG decoder written from ITU T.81 (the JPEG
process), T.871 (JFIF), and Adobe's APP14 note (the color transform), and
an encoder ("Encoding" below).
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
- **HDR gain maps** (plan.md decision 51) are flagged, never decoded or
  applied: `Metadata.gain_map` is set when the base image's APPn segments
  hold an MPF APP2 segment (`MPF\0`, CIPA DC-007, which locates the gain
  map image after EOI) and either the gain map XMP namespace
  (`http://ns.adobe.com/hdr-gain-map/1.0/`, Ultra HDR 1.0 and Adobe's gain
  map) in the first XMP packet or ISO 21496-1's APP2 segment
  (`urn:iso:std:iso:ts:21496:-1\0`). Both are required: a camera's MPF
  preview has no namespace, and the gain map cannot be found without MPF.
  The namespace is searched in the XMP bytes as they pass to the sink,
  each piece joined to the end of the one before (`Find`); nothing past
  EOI is read, so the gain map image's own metadata is not checked.
  libjpeg-turbo has no notion of gain maps, so no oracle compares the flag;
  it was checked by hand against libultrahdr 1.4's `is_uhdr_image` on two
  Pixel Ultra HDR 1.0 photographs (XMP), four libultrahdr files (ISO
  21496-1 only, which libultrahdr writes by default), and a plain JPEG,
  agreeing on all seven. `corpus/gen/jpeg.sh` adds one libultrahdr file
  (`ultrahdr-iso.jpg`), so the oracle compares a gain-map file's base
  image with libjpeg-turbo's.
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
  TIFF's JPEGTables tag: a table-specification stream (SOI, DQT and DHT,
  then EOI), whose tables load before the image stream's own markers, as T.81
  B.5 describes for abbreviated streams. Each strip or tile is then its own
  abbreviated image stream. `Options.color` takes the photometric
  interpretation: `.ycc` for YCbCr, `.none` for RGB, CMYK, and gray, so the
  Adobe marker and component IDs are not consulted. The TIFF decoder can test
  for the interface with `@hasDecl(image.jpeg.Decoder.Options, "tables")`
  or `@hasField`. Old-style JPEG (compression 6) is not supported.
- **Tables streams as libjpeg reads them** (TIFF stage 2's requests).
  `Options.tables` is read as libjpeg's `jpeg_read_header` reads a
  tables-only stream: SOFn is checked (nonzero size and component count,
  and the length they need) and dropped, DNL skipped, RSTn and TEM ignored,
  APPn and COM skipped, SOS refused. libjpeg's `get_soi` resets the restart
  interval and the DAC conditioning at every SOI, so a DRI or DAC in the
  tables stream does not reach the image; only DQT and DHT carry over.
  The same holds across streams: libtiff decodes every strip with one
  decompressor, so a strip's tables persist into the next, and
  `Decoder.keptTables()` with `Options.prior` carries them the same way.
- **The frame for a container.** `Decoder.frameParams()`, after
  `decodeConfig`, returns the frame header as `FrameParams` (components,
  each one's sampling, precision, lossless, and `multi_scan`), so TIFF
  checks a stream against its IFD without reaching into the decoder.
- **Two components.** libjpeg reads a two-component frame as JCS_UNKNOWN
  and returns its samples unconverted; TIFF writes gray with alpha so. They
  decode to native `gray_alpha8` (`gray_alpha16` past 8 bits), the first
  component gray and the second alpha. The oracle compares them as gray
  with alpha, gray, and RGB against libjpeg-turbo's JCS_UNKNOWN output.
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
  colors). CMYK and YCCK images also as `cmyk8` and `cmyk16`: this package
  with `cmyk = .raw` (the oracle's `Decoder` sets it for those formats
  only) against libjpeg-turbo's JCS_CMYK output, scaled the same way, so
  the inks, YCCK's color conversion, and the 12-bit and lossless
  precisions are held directly, not through the naive RGB; other color
  spaces skip them, and lossless YCCK both reject. Both corpus files and
  fuzzed inputs: 0 mismatches; the splits are all Wuffs (its own edge
  upsampling and damaged-file handling).
- `djpeg` at every scale against this package on the corpus (libjpeg-turbo's
  and Wuffs's test images, the benchmark corpus, and the generated files):
  identical but for the truncated progressive files (block smoothing).
- `corpus/gen/jpeg.sh` writes what the public test images lack with cjpeg:
  arithmetic coding at each sampling, with restarts, progressive, and one
  scan per component; 12-bit Huffman and arithmetic, sequential and
  progressive; and lossless with every predictor, point transforms,
  precisions 2 to 16, subsampling, restarts, and one scan per component.
  tjbench adds CMYK: YCCK baseline, with restarts, progressive,
  arithmetic, 12-bit, and 12-bit arithmetic progressive, and lossless CMYK
  at precisions 6, 8, 12, and 16.
- The fuzz target generates files by walking the decoder's states: metadata
  segments (MPF, gain map XMP, and ISO 21496-1 among them), quantization and Huffman tables (flat or standard), restart
  intervals, sequential and progressive scripts with refinement, and
  restart markers, and checks a scaled decode alongside the full one.
  Stage 2 adds 12-bit frames, arithmetic-coded frames with DAC segments and
  random bytes for their data, and lossless frames of every precision and
  predictor with Huffman-coded differences.

## Encoding

`encode.zig`, `fdct.zig`, and `huffman_encode.zig` write baseline or
progressive DCT files with Huffman coding and 8-bit samples: YCbCr at 4:4:4,
4:2:2, or 4:2:0 for a color source, one component for a gray one, in JFIF,
with EXIF (APP1) and an ICC profile (APP2, split into 65,519-byte chunks)
written when given. `encode(w, src, options, work)` follows src/encode.zig's
contract: any source format, converted a row at a time to `rgb8` or `gray8`
by `image.convert` (alpha dropped, decision 7), no allocation, and `work`
of at least `workLen(options, width, height)` bytes, which the caller can
compute before it has pixels. Results: `results/jpeg-encode-20261102.md`.

### Matching libjpeg-turbo

For the same settings the file is libjpeg-turbo's byte for byte, so the
oracle compares bytes (`jpeg-turbo-encode`), not pixels. That fixes every
choice T.81 leaves open:

- Quantization tables: K.1 and K.2 scaled by libjpeg's quality rule (5000/q
  below 50, 200 - 2q from 50, rounded, clamped to 1-255; quality 0 counts
  as 1, above 100 as 100), written as one DQT segment per table.
- Color: T.871's equations in libjpeg-turbo's 16-bit fixed point, Cb and Cr
  rounded with half less one. Downsampling averages each pair (4:2:2) or
  2×2 square (4:2:0) with the bias alternating 0, 1 or 1, 2 across the row.
- Edges: a row past the bottom repeats the last; a column past the right
  edge repeats before downsampling; a chroma row past the last made from
  image rows repeats that one. A dummy block that completes an MCU has no
  AC coefficients and the DC of the block to its left, or, below the image,
  of its MCU's last block in the row above.
- Forward DCT: the islow LLM DCT, with its 13-bit constants and its two
  rounding points, then division by 8q rounding half away from zero.
  `fdct.zig` computes it with 16-bit multiply-adds on two blocks at once
  and divides with two high multiplies (a reciprocal and a power-of-two
  correction), exact for every input the DCT can produce; its tests check
  the regrouped butterflies against the plain 32-bit ones and the division
  exhaustively.
- Optimized tables: K.2's procedure with a reserved symbol of count 1, ties
  merged larger symbol first, and K.3's length adjustment; symbols listed
  by their length before adjustment, then value.
- Progressive: libjpeg's default script (`jpeg_simple_progression`: ten
  scans for color with Cr's before Cb's, six for gray), optimized tables
  for every scan (libjpeg-turbo forces them), an EOB run ended at 0x7fff or
  before its held correction bits could pass 937 (its 1,000-bit buffer less
  a block's 63), and 0 for the table selector a scan does not use.
- Markers: SOI, JFIF 1.01 (aspect 1:1, no thumbnail), APP1 Exif, APP2
  ICC_PROFILE, DQT, SOF0 or SOF2, DHT and SOS per scan, EOI.

`EncodeOptions` defaults to quality 75, 4:2:0, standard tables, and
baseline, as `cjpeg` and TurboJPEG do.

### Memory

A baseline file with the standard tables streams: the work memory holds
one converted source row, each component's samples for one MCU row (at
full resolution, and downsampled), and the quantized blocks of that MCU
row, 128 bytes a block: tens of kilobytes for a megapixel image. Optimized tables and progressive
scans read every coefficient at least twice (count, then write), so they
keep the whole image's quantized blocks, two bytes a sample of each
component padded to whole MCUs, as libjpeg-turbo's full-image coefficient
buffer does: 3 bytes a pixel at 4:2:0 and 6 at 4:4:4. `workLen` assumes a
color source, the larger case.

### Speed

Measured against libjpeg-turbo with its SIMD on, on one core
(`results/jpeg-encode-20261102.md`):

- Color conversion: eight pixels a step, loaded as 32 bytes and permuted so
  each 128-bit half holds four pixels (`vpermd`), two in-half byte
  shuffles to (R,G) and (B,G) pairs, and `pmaddwd` with the weights over
  2^15 split in two or applied by a shift. The permute is inline assembly
  on x86: as a portable shuffle LLVM merged it with the byte shuffles into
  four `vpermt2b`, three µops each, and a 48-byte shuffle was built a byte
  at a time with `vpinsrb`. This took the sample stage from 2.0 to 1.0
  cycles a pixel.
- Downsampling: each pair of samples is one u16 lane, and its two bytes'
  sum is the pair's sum whatever the byte order.
- Entropy coding: a 64-bit bit accumulator in registers for a whole block,
  stored eight bytes at a time when no byte is 0xff; the nonzero
  coefficients come from a vector compare, its mask moved to zigzag order
  by eight byte tables, and the loop visits only set bits, clearing the
  lowest each time (`mask & (mask - 1)`: the loop's dependency through
  the mask is one instruction instead of three, 11% less Huffman time). The
  progressive AC first and refinement scans use the same mask loop over
  the magnitudes after the point transform, which made progressive files
  1.9× faster.
- Optimal tables are built only for the tables a scan uses, searching
  only the symbols seen and listing them by counting sort: per-call cost
  that dominated small images (a 16×16 progressive file went from 0.07× to
  1.7× libjpeg-turbo).

The performance pass (`results/jpeg-encode-perf-20261102.md`) took
baseline color over 1 MP from 0.93× to 1.18× libjpeg-turbo (4:2:0) and from
0.98× to 1.26× (4:4:4), every class at or above it:

- No 512-bit instructions: the benchmark's Ice Lake host lowers its clock
  after any (plan.md). LLVM made them from 16-lane u16 high multiplies
  (widened to 32-bit lanes; now `simd.mulhu`, `vpmulhuw ymm` in assembly),
  64-lane compares (now four of 16 lanes), and 32-bit counts narrowed to
  bytes. Check `objdump` for zmm in `jpeg.*` after changing a kernel.
- The coder's table pointers are hoisted out of the block loop, and the
  0xff test of a full word is a vector compare, so the loop's state stays
  in registers.
- `fill` prefetches the source row 4 rows ahead: a source larger than the
  caches came in at 3.4 GB/s, where one core streams 12, and a 16 MP photo
  encodes a third faster.

Tried and dropped: splitting a block's coding into a pass that makes
(code, length) words and a pass that writes them, to free registers (the
same speed); 32-bit DCT lanes with array transposes (slower than the
16-bit pair DCT); each coefficient's category and value bits computed in
vectors for the whole block before the loop (within 2%).

### Testing the encoder

- Unit tests: the vector color conversion against T.871's equations and
  the scalar fixed point, downsampling's alternating bias in both vector
  widths, the pair DCT against the 32-bit butterflies and the float DCT,
  the division exhaustively, the standard tables' codes, optimal tables
  (prefix-free, at most 16 bits, never all ones, Kraft), and the bit
  writer's stuffing and padding across its staging buffer.
- The oracle (`test/oracle/jpeg_encode.zig`, `jpeg_turbo_encode` in
  `jpeg.c`): the JPEG corpus and fuzzed JPEG streams decoded by our decoder
  into `rgb8`, `rgba8`, and `gray8` sources, each encoded by both with the
  settings its size picks (quality 1 to 100, every subsampling, baseline,
  optimized, progressive, EXIF and a two-segment ICC profile sometimes),
  compared byte for byte: 0 mismatches on 100,409 comparisons.
- The benchmark's checksums: libjpeg-turbo with its SIMD on writes the same
  bytes as this package on all 220 rows of the five encode operations.
- The fuzz target (`test/fuzz/jpeg_encode.zig`): every source format and
  setting, the exact `workLen` (one byte fewer fails), a writer that drains
  a few bytes at a time, our decoder reading the file back, and at quality
  100 with 4:4:4 a bound on each sample's error and the mean's.

### Decision 3: trellis quantization

Not built; the measurement for the owner is in the results file. On 15
photographs, screenshots, and textures from the benchmark corpus at
quality 75, 85, and 95, 4:2:0, with mozjpeg 4.1.5 built out of tree:
mozjpeg's trellis on the standard tables makes files 7.5-11.6% smaller
than our optimized baseline at the same quality setting, but they lose
0.4-1.0 dB of PSNR; at equal RGB PSNR they are no smaller (+0.6 to +1.9%),
and at equal SSIM 6.6% smaller (10 images, q85). mozjpeg's full default
(progressive with scan optimization, trellis, and its own tables) is
2.2-6.1% smaller than our progressive at equal PSNR and 12.2% at equal
SSIM. Trellis runs at 1/14 of our optimized baseline's speed, and the full
profile at 1/8 of our progressive's.
