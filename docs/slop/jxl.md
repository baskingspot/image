# JPEG XL decode: notes and decisions

`src/jxl/` is a streaming JPEG XL decoder written from ISO/IEC 18181-1 (the
codestream) and 18181-2 (the container). libjxl 0.12.0 is the oracle
(`test/oracle/jxl.c`); jxl-oxide and libjxl are the speed and memory bars.
This file records the stages, the work-memory bound, and what the decoder
does where the specification leaves room.

## Stages

1. **Container, headers, entropy decoding** (landed with stage 2). Boxes,
   the image and frame headers, the TOC with its permutation, ANS and prefix
   codes with context clustering, LZ77, hybrid integers, and the ICC
   profile's encoding.
2. **Modular** (landed). Lossless and lossy Modular frames end to end:
   meta-adaptive trees, every predictor including the weighted one, RCT,
   palette (delta palettes, implicit cubes), squeeze, the global and group
   streams, LF and pass groups, extra channels, animation, blending,
   reference frames, and cropped layers larger than the canvas.
3. **VarDCT and the restoration filters** (this branch). XYB and YCbCr
   with chroma subsampling, LF frames, every transform, dequantization with
   custom tables, chroma from luma, adaptive LF smoothing, Gaborish, EPF,
   upsampling (2×, 4×, 8×, custom weights), patches, splines, noise, and
   progressive passes.
4. **JPEG reconstruction** from `jbrd` (plan.md decision 5).

Until a stage lands, files that need it fail with `error.Unsupported`, and
the oracle leaves them out (`test/oracle/jxl.zig`).

## Shape

- `container.zig`: `Source` hands the codestream to the bit reader, bare or
  in `jxlc` or `jxlp` boxes, and sends `Exif` and `xml ` boxes (raw, or
  Brotli in `brob` with `Blob.encoding = .brotli`) to the blob sink as it
  passes them. `jbrd` is noted and skipped.
- `BitReader.zig`: a 64-bit LSB-first bit buffer over `Source`, with the
  specification's U32, U64, F16, and enum field codings.
- `headers.zig`: SizeHeader, ImageMetadata (bit depth, extra channels,
  color encoding, tone mapping, animation, preview), the custom upsampling
  weights (`upsample_weights.zig`), and FrameHeader with its passes, crop,
  blending, and restoration filter fields.
- `entropy.zig`: `Code.read` reads the clustered distributions, either
  prefix codes (lookup tables with a second level) or ANS (alias tables),
  and the LZ77 parameters; `Reader` keeps the ANS state and the LZ77 window.
  A code whose cluster has one symbol is read without touching the stream
  (`Reader.singleValue`).
- `modular.zig`: channels and transforms, the tree (16-byte nodes, the
  right child beside the left), and the channel decoder. Each channel picks
  a path: a single leaf with a fixed predictor, or the general loop that
  evaluates the tree with the properties the tree reads. `plan()` resolves
  each channel's static properties (channel and stream index) once instead
  of per pixel. The weighted predictor runs in wrapping 64-bit arithmetic,
  so hostile residuals cannot trap.
- `frame.zig`: the TOC, then each section in file order: LfGlobal (the
  global tree and the GlobalModular channels), LF groups, and pass groups,
  each group copied into the frame's channels. A frame that `streams`
  (below) is filtered and handed to the Decoder a group row at a time.
- `icc.zig`: the encoded ICC profile's prediction, written straight into
  work memory and sent to the blob sink as kind `.icc`.
- `vardct.zig`: the HF global and LF group sections (quantized LF,
  adaptive smoothing, the AC strategy, quant field, and chroma-from-luma
  maps), and the pass groups: coefficient orders, non-zero contexts, and
  the coefficients, kept across passes in i32 and dequantized when the last
  pass of a group arrives. `dct.zig` has the inverse transforms (8-lane
  columns over `@Vector`), `quant.zig` the dequantization tables.
  `Decoder.coeff_sink` (a `vardct.CoeffSink`) hands each LF group's
  quantized LF as it is read and each varblock's quantized coefficients
  after its last pass, before dequantization, with the block's
  quantization field and chroma-from-luma factors, in stored layout (a
  DCT8's is transposed from JPEG's natural order). The fuzz target checks
  that a sink changes no frame, pixel, or error and sees only in-frame
  rectangles.
- `Decoder.decodeJpeg` is the coefficient pass JPEG reconstruction builds
  on (below): a sink (`vardct.Jpeg`) that turns those into the JPEG's
  components, with no pixels made.
- `color.zig`: XYB to linear sRGB, YCbCr, and the sRGB transfer function,
  eight pixels at a time. `filters.zig` has Gaborish and EPF, `upsample.zig`
  the upsampling kernels, and `patches.zig`, `splines.zig`, and `noise.zig`
  the features they name.
- `Decoder.zig`: frames converted to floats at their bit depth, composited
  onto the canvas with the frame's blend mode, saved to reference slots, and
  written to the caller's buffer through `image.convert`.
- `Arena.zig`: a bump allocator over the caller's work memory that aligns
  by address and tracks its peak, for the measurements below.

## Work memory

`Config.work_len` is a bound computed from the headers before any pixel is
read; a file that would need more fails with `TooComplex` rather than
writing past it. Its terms, in `Decoder.workBound`:

- The canvas and four reference slots, as float planes, when frames may
  need them: three colour planes for an XYB image, grey too, since a slot
  saved before the colour transform holds X, Y, and B for patches; the grey
  comes from the first as it is written. A single last frame without a crop in a still image needs
  neither, which `decodeConfig` learns by reading the first frame header
  when there is no ICC profile or preview before it.
- One Modular frame of up to twice the canvas's pixels, three times over
  for undoing squeezes, plus a delta palette's indices and the largest
  palette.
- A group's channels with their transforms, at the first frame's group
  size when it is known.
- Two trees and three live entropy codes, each code's tables within a 1 MiB
  budget plus its LZ77 window, and a channel's tree flattened for the walk
  (393 KB, `modular.flat_bytes`; larger trees walk the nodes).
- Reference-property rows and the weighted predictor's rows.

- With VarDCT: three padded planes, the coefficients kept between passes
  when there is more than one, the block fields, each pass's orders (for
  the order classes of strategies that fit the frame and a group, when
  the frame header is known) and code, and the LF frames' planes at each
  level when frames may use them.
- Upsampled planes, noise's planes, and the patch and spline budgets, for
  the features the frame header turns on.
- A 64th of all that: the arena starts each array of 4096 bytes or more on
  a cache line (64 bytes), wasting under a 64th of it. Planes that started
  wherever the allocations before them ended cost 2–4% of VarDCT decoding
  when they landed off a line.

**Streaming.** A shown VarDCT frame that replaces the canvas and is never
referenced, in one pass with its groups in order (the TOC not permuted),
without upsampling, patches, splines, or noise, and at least five group
rows tall, keeps a ring of three group rows of pixels
instead of whole planes (`vardct.Shared.ring_rows`). Once a
group row is in, the one before it is copied with eight rows of each
neighbor into a window, filtered there (Gaborish reads one row each side,
EPF's passes three, two, and one; a window starting on a block row keeps
EPF's sigmas and border rows aligned, and its edges are the frame's only
at the frame's edges, where mirroring is right), color-transformed, and
written to the caller's rows. Subsampled chroma (a recompressed JPEG's) is
upsampled into the window: each ring row of a subsampled channel is
upsampled across in place once, when the first window needs it, and the
window's rows are blended down from those, as `vardct.upsampleChroma` does
on whole planes, before Gaborish, which then filters the window in place. Extra channels (alpha) are Modular channels
read as each band is written: groups decode in order, so a group row's
extra channels are final once its groups are in, and they keep two group
rows (`Channel.ring`), the band being written and the row after it. A
Modular frame under the same conditions, drawn in integers (no XYB,
filters, or YCbCr: `frame.needsFloat` false) and at least two group rows
tall, keeps one group row of each channel and writes each group row as
soon as its groups are in, since no filter reads past it.

Global Modular transforms that take each pixel on its own
(`Transform.pointwise`: RCTs, and palettes without deltas or a predictor,
which is what cjxl writes for a two-level alpha and for channels with few
distinct values) are undone on each band as it is written:
`Image.band` takes the band's rows from the rings as channels of their
own, shares the meta channels (the palettes), undoes the transforms on
them, and the result must have the frame's channels at its width. Squeezes
and delta palettes read across bands, so a frame with one is decoded
whole; its memory is taken at the end of `lfGlobal`, once its transforms
are known: rings, or whole planes and channels. Pixels are the whole
frame's bit for bit (the unit tests and the fuzz target's `checkStream`
compare them, and `vardct-tall*.jxl`, `jpeg-tall-420.jxl`, and
`modular-tall*.jxl` in the generated corpus cover the plain, permuted,
alpha, palette, 4:2:0, and squeezed cases). `decodeConfig` peeks the TOC's permutation bit
after the frame header, so the bound shrinks only when the frame will
stream; for VarDCT with extra channels it keeps the larger of the ring and
whole planes, since the transforms are not known until the frame is read,
and for Modular it keeps the whole frame for the same reason: the
transforms follow the tree in LfGlobal, which `decodeConfig` cannot read
without work memory. A streamed Modular frame therefore touches far less
of `work_len` than it asks for. A frame without extra channels has no
Modular channels of frame size, so the bound leaves out a delta palette's
indices too.

When `decodeConfig` has peeked a single last frame, the frame term is that
frame's exactly (`frameBound`); otherwise it covers any frame of up to twice
the canvas with every feature. On a 50-megapixel photograph the arena's peak
is 127 MB of a 243 MB bound for `cjxl -d 1`, streamed (627 MB of 948 MB
whole), and 608 MB for `-d 0`; recompressed from a 4:2:0 JPEG, 120 MB
of a 244 MB bound, streamed (686 MB of 744 MB whole). Memory the decoder never touches costs a
caller nothing when it comes from `mmap`, but a caller that fills it, as
Zig's safe allocators do, pays for all of it. Further cuts: undoing
squeezes row by row (one extra channel instead of three).

## Decisions

- **Coalesced frames.** `decodeFrame` returns displayed frames as libjxl
  does by default: zero-duration frames are blended into the canvas and the
  next displayed frame is returned composited. `Frame.blend` is `src_over`
  when the frame went through the canvas and `src` when it replaced it.
- **Blending in floats.** Frames are held as f32 at the image's bit depth,
  as the specification blends, and written out through a 16-bit or f32
  pivot that rounds as libjxl does: `f32(v) * f32(1 / max)`, then ×65535
  rounded to nearest even. Native formats: f32 for float samples or more
  than 16 bits, 8-bit when every channel's maximum divides 255 (1, 2, 4,
  or 8 bits), otherwise 16-bit.
- **Float destinations** (plan.md decision 24) are written from the f32
  planes, not through the native format, so a lossy frame keeps its
  precision: every conformance file is within its `test.json` peak bound
  in `rgba_f32` (alpha_premultiplied 3.0e-6 against 3.8e-6, spot exact;
  through 16 bits they were 9.5e-6 and 7.6e-6). Integer images are clamped
  to [0, 1] there, as the 16-bit step clamps; float images are not. Out of
  gamut the floats can differ from libjxl's unclamped output: on bike, 135
  of 21 million samples, all blue below -0.13, are less negative than
  libjxl's (-0.34 against -0.59 at worst), while everything in [0, 1] and
  above 1 agrees to 7e-6. The conformance reference there is a clamped PNG,
  so the bounds do not reach it; the cause is not yet found. The fuzz target
  checks a float destination against the 16-bit one, within half a native
  step, since `harness.checkDecoder`'s exact format check skips decoders
  with `float_direct`.
- **Frame size.** A frame (a cropped layer) may have up to twice the
  canvas's pixels; more is `TooComplex`. The specification allows any size;
  the cap keeps the bound finite, and the conformance files stay within it
  (sunset_logo's layers are the largest).
- **Boxes after the codestream** are read by the `decodeFrame` call after
  the last frame, the one that returns null, so metadata found there
  reaches `finalConfig` and a broken or cut-off box there fails that call
  without losing the image. libjxl reads nothing after a complete
  codestream and jxl-oxide tolerates cut-off boxes; both return the image
  whatever follows, which the oracle found on fuzzed transcodes.
- **The ICC profile** is decoded in the first `decodeFrame`, since
  `decodeConfig` has no work memory, and reported to the blob sink at
  offset 0 with its decoded length. `Config.metadata.icc` names it only
  after that call. Profiles are not applied: pixels stay in the encoded
  color space, as libjxl returns them without a CMS.
- **Colour metadata** (plan.md decision 29). Without an ICC profile the
  colour encoding fills `Metadata.transfer` (sRGB, linear, BT.709, DCI,
  PQ, HLG) or `gamma`, and for RGB `primaries`: the named primaries and
  white points as the specification gives their xy (sRGB, BT.2100 =
  BT.2020, P3; D65, E, DCI) or the stored custom xy. Grey has no
  primaries. `intensity_target` is the tone mapping header's, 255 by
  default. An XYB image's pixels are in that encoding, which `color.zig`
  converts to (it supports sRGB primaries and D65). An XYB image with an
  ICC profile is written in linear sRGB, as libjxl writes it without a
  CMS, so `transfer` is linear and `primaries` sRGB's; the profile is
  still delivered and describes the original image's space, not the
  pixels' (decision 46). Other images with a profile are in its space and
  these fields are null.
- **Spot colors** are extra channels and are not rendered into the color
  channels, as libjxl does with `JxlDecoderSetRenderSpotcolors(false)`; the
  shared pixel formats have nowhere to put extra channels yet.
- **No `decodeFrameConfig` yet** (plan.md decision 11), so
  `image.Decoder.decodeFrameConfig` is `Unsupported` for animations and
  answers from `Config` for one frame. Reaching the next displayed frame's
  header can mean decoding an ICC profile, a preview, or frames blended in
  without being shown, and all of those need work memory, which the call
  does not take. An earlier version answered only when the header was next
  and was `Unsupported` otherwise; `harness.announced` rightly counts that
  as announcing an error `decodeFrame` does not return. Coalesced frames
  always cover the canvas with `disposal = .none`, so no caller needs it to
  save a region.
- **Frame limit.** `Config.frame_count` is null for animations, and
  `decodeFrame` fails with `TooManyFrames` before drawing a displayed
  frame past `Limits.max_frames`.
- **Orientation** is reported, not applied, as for every other format.
- **Preview frames** are skipped, but count as non-visible frames for
  noise's seed, as the specification says.
- **Lossy output precision.** A lossy (drawn) frame's native format is
  16-bit, as for integer images of up to 16 bits, and `rgba_f32` output
  goes through that 16-bit pivot. Two conformance bounds (alpha_premultiplied
  and spot, 3.8e-6) are a quarter of a 16-bit step, so they would need f32
  native for drawn or blended frames, which doubles the caller's buffer;
  the owner decides.
- **Chroma upsampling before Gaborish** (results/jxl-chroma-20261103.md).
  A subsampled frame's chroma is upsampled before the restoration filters,
  the order libjxl's pipeline also uses. With Gaborish on (which cjxl never
  writes for a JPEG, but a frame may), libjxl's even rows differ from ours
  by up to 1,134 16-bit steps and its odd rows agree, while ours match
  Gaborish applied to the unfiltered output (which is linear, as are the
  upsampling and YCbCr), so ours are kept.
- **Splines** are drawn with an exact erf and cosine; animation_spline
  differs from libjxl by up to 1.1e-3, within its 4e-3 bound.
- **Feature budgets.** Patches are held to 65536 plus one per 16 padded
  pixels, and splines to 1 MiB plus 4 bytes a pixel of work memory; past
  them is `TooComplex`, where the specification's own limits (references,
  control points) are `BadImage`.
- **Errors.** `BadBox`, `BadEntropy`, `BadImage`, `BadIcc`, `NotJpeg`, and
  `TooComplex` beside the shared ones.
- **JPEG reconstruction** (decision 28) is `image.jxl.JpegReconstructor`,
  the Netpbm orb's (`jbrd.zig`, `JpegReconstructor.zig`). It takes the
  coefficients from `Decoder.decodeJpeg(coefs, work)`, called after
  `decodeConfig` in place of `decodeFrame`, with `work[0..jpegWorkLen()]`
  and `coefs` of at least `Jpeg.maxCoefs(width, height)` (12 blocks a
  16-pixel square). It returns a `vardct.Jpeg`: per JPEG component (Y, Cb,
  Cr, channels Y, X, B; a grey JPEG is component 0) the sampling factors as
  JPEG's h and v (`(1 << max shift) >> shift`), blocks across and down
  (the frame's blocks are whole MCUs already), the quantization table in
  natural order from the raw DCT8 table, and the coefficients as i16 in
  natural order with chroma from luma undone. The ICC profile goes to the
  blob sink as for `decodeFrame`. A frame that cannot be a JPEG's is
  `NotJpeg`: anything but one regular VarDCT YCbCr frame of the image's
  size with DCT8 blocks, raw tables, LF without extra precision or
  chroma-from-luma factors, and no extra channels, animation, upsampling,
  patches, splines, noise, or LF frame. A JPEG stored as RGB rather than
  YCbCr is `NotJpeg` until a file shows its channel order.
- **Chroma from luma in integers.** A chroma coefficient is the stored one
  plus `(s * y + 1024) >> 11`, where `y` is the luma coefficient,
  `s = (m * r + 1024) >> 11`, `m = trunc(f * 2048 / color_factor)` for the
  tile's factor `f`, and `r = floor(Qy[k] * 2048 / Qc[k])` for the luma and
  chroma tables' entries. This was fitted against djxl's reconstructions:
  exact on 152,530 nonzero terms in the 67 transcodes the Netpbm orb
  generated, where no other fixed-point precision or rounding fits; twelve
  photograph transcodes with random tables (factors up to 51) then ruled
  out rounding `r` (23 misses) and leave truncation exact. The unit test's
  16 by 8 fixture has coefficients that rounding the exact quotient, or
  `r`, gets wrong.
- **Verified:** on those 79 files and the three conformance JPEGs
  (`bench_oriented_brg`, `cafe`, `grayscale_jpeg`), every quantization
  table and every coded block's coefficients equal libjpeg's
  `jpeg_read_coefficients` of djxl's reconstruction (353,186 blocks); no
  other corpus file passes as a JPEG. The pass peaks at 0.9 to 6.8 MB of
  work memory. `jpegWorkLen` is the frame bound without planes: block
  fields, a pass group, the codes, and with several passes (or an ICC
  profile hiding the frame header) the kept coefficients. It leaves out a
  group's Modular channels (a JPEG's frame has none) and counts one LZ77
  window rather than three (one stream decodes at a time); each pass's
  orders count only the classes of strategies that fit the frame. That
  makes it 9.2 MB on a 16×16 file (from 10.0), 25 MB on a 768×512 photo
  (from 37), 118 MB on the 50-megapixel mosaic (from 130), and 136 MB on
  cafe (from 193). What is left on small files is budgets that do not
  shrink with the frame: 4 MiB for the LF group's channels and every
  dequantization table (any of which may be stored raw, at its full size,
  in any frame), and 1 MiB for each live entropy code's tables.

## Testing

- Oracle: libjxl decodes the first displayed frame in RGBA16 (straight or
  premultiplied as the image stores alpha) and float RGBA. Ours must match
  bit for bit when every frame is drawn in integers (lossless Modular);
  with a frame drawn in floats, within 4 16-bit steps a sample, and with
  splines within the conformance bound (peak 262 steps, RMS 6.55), which
  `toleranceFor` picks from the frame headers (`Decoder.skim`) before the
  decode (plan.md decisions 45 and 77; `test/oracle/jxl.zig` has the
  reasoning).
  16-bit answers count for integer images and float answers for float
  ones. A grey image is compared with libjxl's grey output, widened
  (test/oracle/jxl.c): like ours it is the first color channel, where its
  RGBA output keeps the chroma a fuzzed YCbCr frame in a grey image may
  carry. libjxl's 8-bit output is dithered, so it is not compared.
- Fuzz: `test/fuzz/jxl.zig` writes valid one-group Modular files (gray or
  RGB, optional alpha, 8 to 12 bits, a random predictor, an optional RCT)
  with a small bit writer, and random bodies an eighth of the time.
- Conformance: the `jxl-conformance` suite's 40 files, every frame
  compared in floats with libjxl's float output against each file's
  `test.json` peak bound (a scratch program; the harness compares bytes
  only). All 40 decode, and 38 are within their bounds; the worst lossy
  error is 4.3e-5 (upsampling), and animation_spline's 1.1e-3 is the
  largest, from the splines' exact erf. The lossless files match libjxl's
  16-bit output bit for bit. alpha_premultiplied (9.5e-6 against 3.8e-6)
  and spot (7.6e-6 against 3.8e-6, its blended layers falling between
  16-bit steps) have bounds a quarter of a 16-bit step, which our float
  output cannot meet through the 16-bit native pivot (Decisions, lossy
  output precision).
- `corpus/gen/jxl.sh` writes sixteen small cjxl
  files covering VarDCT, the filters, LF frames, progressive passes,
  upsampling (of the colors, and of alpha alone), noise, animation, lossy
  Modular, JPEG recompression, and streaming (`vardct-tall*`), which seed
  the fuzzer and the oracle; the first twelve match libjxl in floats, and
  the tall ones are within 3 in 16 bits, alpha exact.

## Measurements

`results/jxl-20261102.md`, one thread, RGBA16 out, against libjxl 0.12.0
and jxl-oxide 0.12.6. Lossy (VarDCT): 1.39× libjxl on icons, 0.57× to a
megapixel, 0.48× above; 1.4–1.8× jxl-oxide past icons. Lossless (Modular):
1.31×, 0.77×, and 0.75× libjxl; 1.1–1.2× jxl-oxide. Peak RSS on the
50-megapixel mosaic is about 590 MiB beyond the output for us, 130 MiB
(lossy) and 25 MiB (lossless) for libjxl, and more for jxl-oxide; below a
megapixel we are within 20% of libjxl.

`results/jxl-mem-20261102.md`: arrays on cache lines (+1.57% lossy, +8.4%
on the mosaic) and streaming bring the mosaic's lossy peak RSS to 507.4
MiB, about 120 MiB beyond the output, below libjxl's 527.0 in the run
above; lossless and images under five group rows are unchanged.

`results/jxl-speed-20261103.md`: `decodeJpeg`'s coefficients +48%
(baseline rebuild) and +35% (progressive); VarDCT reconstruction +21%
(the LF-to-LLF DCT made separable, coefficients kept zero, Gaborish
vectorized and reading the rows in place, a cheaper sRGB cube root); and
Modular +16% lossless, +9% lossy, from a two-level tree walk, the weighted
predictor's table reads kept scalar, and inlined symbol reads. Over
ede392a: lossy +32%, lossless +16%, baseline rebuild +54%, with peak RSS
unchanged. On the 1200×1200 photo that is about 0.76× libjxl lossy and
0.89× lossless, and 0.59× rebuilding the mosaic's JPEG.

`results/jxl-speed2-20261103.md`: VarDCT's coefficient loop specialized on
the code's kind (+1.3% lossy, +1.6% rebuilding JPEGs), the default
dequantization tables up to DCT32 computed at compile time (+8.8% lossy,
16×16 icons +20–28%), and the planes left uncleared without chroma
subsampling (+3.1%). Over the first pass: lossy +13.8% (16×16 icons +23–31%,
the 1200×1200 photo +6%, about 0.81× libjxl), rebuilding +2.4%, lossless
unchanged, bit for bit, peak RSS unchanged. EPF's differences shared
between offset pairs measured −0.9% on `cjxl -d 1` files (one iteration)
and were not kept.

`results/jxl-speed3-20261103.md`: a frame's color transform and packing
done as its rows are written, into the destination when it is the native
format with at most an opaque alpha added (+1.5% lossy); EPF's output
stored a vector at a time (+2.0%); large clears with the shared vector
fill (+1.5% lossy, +2.8% rebuilding, +2.2% lossless); output pixels
interleaved eight at a time (+1.4%); and each channel's Modular tree
flattened two levels to an entry, one load a step (+6.5% lossless, the
photos +7–14%). Over pass 2: lossy +6.2%, lossless +8.9%, rebuilding +2.7%,
bit for bit, peak RSS unchanged, `work_len` 393 KB larger. A cheaper sRGB
power (two square roots, no division) measured +0.5% and moved 0.1% of
16-bit samples, so it was not kept: the transform is bound by its
operation count, not the divider.

`results/jxl-speed4-20261103.md`: nothing kept. Branch-free ANS with
eight-byte alias entries (lossy −1.2%), the weighted predictor's errors
interleaved (lossless −0.5%), Gaborish and EPF's passes a row apart
(+1.0%, needing 11 more ring rows), the IDCT without its copies (−0.5%),
and AVX-512's sixteen lanes for the transform and filters (−1.0%) were
all bit for bit and inside the noise or slower; an A/A run puts the
noise at about ±1.5%.

## Next

1. **Memory, further**: stream more frames (noise and upsampling, which
   need a few more rows each); keep two
   group rows plus the margin instead of three. `work_len` for Modular
   stays the whole frame's until `decodeConfig` can learn the transforms,
   which come after the tree (`results/jxl-mstream2-20261103.md`).
2. **Speed**, after `results/jxl-speed4-20261103.md`, which found no
   tuning left that measures: what remains needs another algorithm. The
   XYB to sRGB transform (13% of lossy) with a power function of fewer
   operations, which moves some 16-bit samples a step, so the oracle's
   lossy tolerance must be rechecked; trees on one property as tables,
   for `cjxl -e 2` and `-e 3` files; and an 8-bit destination, which
   still converts from the 16-bit native format.
3. **JPEG reconstruction** (stage 4), by the Netpbm orb in `jbrd.zig` and
   `JpegReconstructor.zig`, on `Decoder.decodeJpeg`. Its writer is now 29%
   of a baseline rebuild. Shrinking `jpegWorkLen` on small files further
   needs smaller budgets (Work memory above), an owner decision.
