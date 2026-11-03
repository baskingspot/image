# Plan

image is Wuffs's image formats as a Zig package, plus encoders and the
formats Wuffs lacks: decode and encode the image formats people actually
meet, with no C, no allocation, streaming input, and the speed and memory of
each format's best library or better. This file is the scope, the API, the
order of work, the decisions to measure, and who owns what. Update it when a
decision lands.

## Scope: phase 1

Every format below is in phase 1, decode and encode, unless a cell says
otherwise.

| Format    | Decode                                                                                                                                                                                                                         | Encode                                                                                                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| PNG, APNG | every color type and bit depth, interlacing, tRNS, gAMA/cHRM/sRGB/iCCP/eXIf reported, APNG frames with dispose and blend                                                                                                       | filter selection, deflate levels through `compress`, palette and gray reduction, APNG                 |
| JPEG      | baseline, extended (12-bit), progressive, arithmetic coding, lossless (process 14), restart markers, every sampling factor, CMYK and YCCK, Adobe and JFIF markers, DCT-domain 1/2, 1/4, 1/8 scaling                            | baseline and progressive, 4:4:4/4:2:2/4:2:0, optimized Huffman tables, the standard quality tables    |
| GIF       | GIF87a and 89a, interlacing, animation with disposal, transparency, NETSCAPE loop count                                                                                                                                        | palette quantization and optional dithering for truecolor input, animation, frame-difference cropping |
| WebP      | lossless (VP8L), lossy (VP8) with alpha (ALPH), animation (ANIM/ANMF), ICCP/EXIF/XMP reported                                                                                                                                  | lossless first; lossy (VP8) last in phase 1                                                           |
| TIFF      | classic and BigTIFF; strips and tiles; none, PackBits, LZW, Deflate, JPEG (new style), CCITT G3/G4; predictors 2 and 3; 1–32-bit integer and float samples; planar and chunky; gray, palette, RGB, CMYK, YCbCr; multiple pages | none, PackBits, LZW, Deflate, with predictor 2; strips; multiple pages                                |
| JPEG XL   | the full codestream: VarDCT and Modular, every profile the conformance suite covers, animation, extra channels, progressive passes, the container's boxes (Exif, xml, jbrd, brob through `compress`'s Brotli)                  | lossless (Modular) in phase 1; lossy (VarDCT) is a decision below                                     |
| BMP       | 1/4/8/16/24/32-bit, RLE4/RLE8, bitfields, V4/V5 headers, top-down and bottom-up, embedded PNG/JPEG reported                                                                                                                    | 24/32-bit, 8-bit palette                                                                              |
| ICO, CUR  | every entry, BMP and PNG payloads, hotspots                                                                                                                                                                                    | BMP and PNG payloads                                                                                  |
| TGA       | every image type including RLE, color maps, origin                                                                                                                                                                             | uncompressed and RLE                                                                                  |
| Netpbm    | PBM, PGM, PPM (plain and raw), PAM, PFM                                                                                                                                                                                        | the same                                                                                              |
| WBMP      | type 0                                                                                                                                                                                                                         | type 0                                                                                                |
| QOI       | the spec                                                                                                                                                                                                                       | the spec                                                                                              |

Shared by every format:

- **Metadata** is reported, never applied: ICC profiles, EXIF (with the
  orientation parsed out, since callers need it to display a photo), XMP,
  gamma, transfer, primaries, intensity target, physical size and DPI, animation timing and loop
  counts, TIFF and ICO page lists.
- **Format detection** from the first bytes (`image.detect`).
- **Pixel formats.** A decoder writes the format the caller asks for:
  RGBA8, BGRA8, RGB8, BGR8, Gray8, GrayAlpha8, their 16-bit forms, RGBA
  f32 for float and HDR sources (TIFF float, PFM, JPEG XL), and premultiplied
  or straight alpha. It also reports the source's native format, so a caller
  can ask for that and skip conversion. Conversion and swizzle are SIMD.

## Not in phase 1

- AVIF and HEIC: an AV1 or HEVC decoder in a container, each a project of its
  own, and HEVC is patent-encumbered.
- Color management (applying ICC profiles), resizing beyond JPEG's and JPEG
  XL's own downscaled decode, and drawing: separate libraries.
- SVG, PSD, OpenEXR, Radiance HDR, DDS and other GPU textures (ETC2), and
  Wuffs's own NIE, Handsum, and Thumbhash.
- Wuffs's non-image packages. Compression belongs in `baskingspot/compress`,
  which already has DEFLATE, zlib, and Brotli; bzip2, xz, and lzma would go
  there too.

## API

Modeled on Wuffs's, in Zig's terms. Nothing allocates: callers own every
buffer. As built in wave 0 (src/; adding-a-format.md is the contract a new
format follows):

- One namespace per format (`image.qoi`, later `image.png`, ...), each with a
  `Decoder`, and a generic layer on top: `image.detect(prefix) ?Format`
  names any phase-1 format from its first `image.detect_prefix_len` (18)
  bytes, and `image.Decoder` (`init(format, reader, options)` or
  `initDetect(reader, options)`) decodes any format this build has, a tagged
  union over the format decoders with the same calls. `Decoder.supports`
  says which formats are in.
- Decoding is two calls on a decoder made by `init(reader, options)`, which
  reads nothing. `decodeConfig` reads the header and returns `Config`:
  canvas size, `native` pixel format (lossless and cheapest to write),
  `frame_count` and `loop_count` when known, `work_len`, `is_opaque`,
  `background`, and `Metadata`. Then `decodeFrame(dst: PixelBuffer, work)`
  writes the next frame into the caller's buffer, in any pixel format, and
  returns its `Frame` (region, duration in flicks, disposal, blend), or null
  when there are no more. Errors are sticky: after one, every call returns
  it.
- Input is pulled from a `std.Io.Reader` whose buffer holds at least
  `image.min_buffer_len` (64) bytes; decoders read forward and never seek
  on their own (decision 1); formats that store offsets (ICO, TIFF) go back
  only through a caller's `image.Seeker` (decision 8).
- `Limits` (width, height, pixels, frames, work memory) are options checked
  before any work; `Limits.none` lifts them. `DecodeOptions` also carries a
  `BlobSink` that receives ICC, EXIF, and XMP bytes as the decoder passes
  them; `Metadata` reports orientation (`image.exif` parses it), transfer,
  primaries, intensity target, density, and whether a JPEG XL file can
  rebuild its JPEG (`jpeg_reconstruction`).
- `PixelFormat` has 24 formats: 8- and 16-bit gray, gray-alpha, RGB, BGR,
  RGBA, and BGRA, straight and premultiplied; RGBA, RGB, and gray f32; and
  8- and 16-bit CMYK. `PixelBuffer` is
  pixels, format, size, and stride. `image.convert` (`Converter`, `convert`,
  `convertBuffer`) converts between any two, with SIMD kernels for the
  common pairs and a general path through 16-bit or f32 RGBA. Its integer
  rounding is Wuffs's (results/convert-rounding-20261101.md): 16 to 8 bits
  takes the high byte, and premultiplying (`c·a / 65535`) and
  unpremultiplying (`c·65535 / a`, clamped) truncate, keeping 8 bits from an
  8-bit source. Dropping alpha drops it (no compositing), the one place the
  results differ from Wuffs's, which composites onto black (decision 7).
  Gray is luma 19595/38470/7471.
- Encoding mirrors it (src/encode.zig): `encode(writer, src: PixelBuffer,
options, work)` in each format's namespace, with `workLen(options, width,
height)` saying how much work memory to pass, and `image.EncodeError` as
  the shared error set. QOI encode in wave 1 is the first.
- Errors are one set per format: `image.DecodeError` (truncated, bad
  signature or header, unsupported, over a limit, buffer or work memory too
  small, the reader's failure) plus the format's own causes.

## Dependencies

- `baskingspot/compress`: zlib and DEFLATE for PNG, TIFF, and the PNG inside
  ICO; Brotli for JPEG XL's `brob` boxes. Its decoders take caller-owned
  buffers, which fits. If inflate's speed is PNG's bottleneck, improve it in
  `compress`, not with a private copy here.
- `baskingspot/fastmem` as `compress` uses it, and `testingx` for tests.
- LZW lives here: GIF's and TIFF's variants differ and nothing else uses them.

## Testing

- **Oracles**, from nixpkgs in the dev shell: libpng and libspng, Wuffs (built
  from source if nixpkgs lacks it), libjpeg-turbo, giflib, libwebp, libtiff,
  libjxl, and stb_image. A differential harness decodes the same files with
  ours and the oracle and compares pixels, frames, and reported metadata.
  Encoders are checked by decoding their output with the oracle and with ours.
- **Corpora**: PngSuite; libjpeg-turbo's and Wuffs's JPEG test images, with
  generated files for the processes they miss (the ITU T.83 conformance files
  have no free download, and the owner has no copy); libwebp's test images; libtiff's test images; the JPEG XL
  conformance repository; plus a benchmark corpus of photographs,
  screenshots, icons, line art, and animations at many sizes. Vendor the
  small suites unmodified with checksums in `THIRD_PARTY.md`; fetch large
  ones by a pinned script, as utf's `bench/corpus` does.
- **Fuzzing** from each format's first commit: mutated corpus files and
  generated structures through every decoder, under the safety rules in
  AGENTS.md (no crash, hang, out-of-bounds access, or limit breach), plus
  allocation-limit sweeps and encoder round trips. `just fuzz` runs them; lua's
  `test/fuzz` harness is a model. Decided by the owner: fuzzing is not a push
  gate. `just ci` runs each target once over its seeds (in `just test`), an
  orb runs `just fuzz` before it pushes a format, and
  `.github/workflows/fuzz.yml` fuzzes daily and by hand (`just fuzz-scheduled`, 240 seconds per target; `just fuzz N/target` gives every target N seconds), failing with the inputs as an artifact.
- **Oracle pass**: the oracle answers with each image's length and XXH64,
  not its pixels, and compare.zig gives our decoder its work memory per
  input. Fuzzed inputs mutate corpus files of at most 2^18 pixels, and one
  time in 16 any corpus file; every corpus file is still compared whole, and
  corpus files are taken in path order, so a seed gives the same inputs, and
  a mismatch the same id, on every machine (results/oracle-pass-20261102.md:
  the pass fell from 299 s to 123 s, and size-gated mutants still fail it).
  CI runs oracle-ci as its own job and uploads a failing run's mismatch
  inputs. `harness.checkDecoder` checks `decodeFrameConfig` against every
  `decodeFrame` where a decoder has one, and checks a decoder that can move
  back with a seeker too. `just test` also runs the unit tests in
  ReleaseFast, where `undefined` memory is not filled with 0xaa. `just
bench-compare` reports peak RSS per operation and per size class.

## Benchmarks

Encode and conversion rows take raw pixels with no header; the harness sets
`bench_width`/`bench_height` from the input's `-WxH` (bench/c/arm.h;
`bench/zig/input.zig`, `input_size()` in Rust, `inWidth`/`inHeight` in Go).
A `rotate=<op>` row cycles through one size's distinct files so a tiny
input's branches cannot be learned; `png-decode-icons` and
`qoi-decode-icons` rotate 64 icons, and QOI icon numbers cite them
(results/icon-rotation-20261102.md). The oracle protocol has an encode op
(`.encode`; the request is u32 width, u32 height, pixels; the response is
the file), used by qoi_encode, and oracle modules must be thread-safe.
`harness.checkEncoderWith` takes an `expect` hook and sides past 64 for
quantizing and lossy encoders; `expect(want, trip)` sees the round trip
(`harness.RoundTrip`: source, decode, file). A decoder declaring
`float_direct = true` writes float formats from its own floats (decision
24), and `checkDecoder` skips comparing those with converted native pixels.
An oracle module may declare `toleranceFor(input) ?Oracle.Tolerance`
(`peak`, optional `rms`, in sample units, 16-bit steps for floats) instead
of a format-wide `tolerance` (decision 45). Gate recipes clear `.zig-cache`
at 20 GiB or 85% disk, except under CI.

Megapixels per second and peak RSS, decode and encode, per format, against
the bar library and the comparison arms in AGENTS.md, using utf's harness
design: each arm a pinned server, rows timed back to back in rotating order,
paired ratios with 95% intervals, identical buffer placement for every arm.

## Order of work

Each wave fans out to orbs with disjoint file ownership; this file records
the owner of each file while a wave runs. Files have one owner at a time.
Work that needs another owner's file asks for the change in its report
instead of editing the file; a private helper is fine until the merge. Each
orb pushes a signed branch rebased on the latest `origin/main`, and the
orchestrating thread fast-forwards `main` to it after rerunning the gates.

0. **Foundations.** Pixel formats and SIMD conversion, the shared config,
   frame, limit, and metadata types, `detect`, the oracle and fuzz harnesses,
   the benchmark harness, and the corpus scripts. One orb, before the rest.
1. **PNG and APNG decode**, and the simple formats both ways: BMP, ICO and
   CUR, TGA, Netpbm, WBMP, QOI.
2. **JPEG decode** and **GIF decode**, in parallel.
3. **WebP decode** (lossless, then lossy and animation) and **TIFF decode**,
   in parallel.
4. **JPEG XL decode.** The largest decoder; it may run alongside wave 3 once
   foundations land.
5. **Encoders**: PNG and APNG, JPEG, GIF, TIFF, WebP lossless, then JPEG XL
   lossless and WebP lossy.

### Owners

Wave 0 (landed at `ef9fb93`): the shared types, conversion, `detect`, the
generic `Decoder`, the fuzz, oracle, and bench harnesses, the corpus, and the
QOI decoder.

Running beside wave 1's tail, started early by the owner:

- **JPEG XL decode** (stages 1–3 landed at `7dc3b58`; jxl.md,
  results/jxl-20261102.md): `src/jxl/`, the files adding-a-format.md assigns
  to jxl, and `docs/slop/jxl.md`. The container (`jxlc`, `jxlp`, `brob`
  through compress's Brotli, Exif and xml to the blob sink, `jbrd` noted),
  the headers, ANS and prefix codes with clustering and LZ77, the ICC
  profile's encoding, Modular (every predictor, RCT, palette, squeeze), and
  VarDCT (every transform, custom dequantization, chroma from luma, LF
  frames, progressive passes); XYB and YCbCr, Gaborish, EPF, upsampling,
  patches, splines, noise, animation with blending and reference frames, and
  extra channels. All 40 conformance files decode; 38 are within their
  `test.json` bounds, and the lossless ones match libjxl's 16-bit output bit
  for bit. On one thread: 1.3–1.4× libjxl on icons, 0.48–0.77× past a
  megapixel, faster than jxl-oxide everywhere. Peak memory past a megapixel
  comes from whole-frame planes (about 12 bytes a pixel), where libjxl
  renders by group. Frames are coalesced as libjxl's default, held as f32,
  and written through a 16-bit pivot (native 8-bit for lossless images whose
  depths divide 255, 16-bit otherwise up to 16 bits, f32 above). A frame may
  have up to twice the canvas's pixels; each entropy code's tables get 1 MiB
  of work memory; patches and splines have work budgets past which a file is
  `TooComplex`. Work memory is a header-derived bound, exact when
  `decodeConfig` reads ahead a single last frame. There is no jxl
  `decodeFrameConfig` yet (it would need work memory). The oracle compares
  integer frames exactly and float frames within decision 45's bounds (an
  internal `Decoder.skim` reads the frame headers to pick one), asks libjxl
  for grey+alpha on grey images, and leaves out files with header-bundle
  extensions or libjxl's ftyp quirk (minor_version above 1, or no
  compatible brand). `metadata()` reports the colour
  encoding's transfer (or gamma), primaries, and intensity target, and
  linear sRGB for XYB images with an ICC (decision 46); the last frame comes
  back before the boxes after the codestream are read, as libjxl and
  jxl-oxide return it. A single-frame VarDCT image of five group rows or
  more streams a group row at a time into dst, alpha included, with whole
  planes when GlobalModular transforms the extra channels; the work arena
  aligns arrays of 4 KiB or more to cache lines (+1.6% lossy); 50 MP lossy
  peak RSS is 507 MiB against libjxl's 527 (results/jxl-mem-20261102.md).
  Images under a megapixel don't stream (to-1-MP class 28.0 MiB against
  libjxl's 23.1), nor do subsampled, noisy, or upsampled frames or Modular.
  `decodeJpeg` rebuilds DC from LF groups with extra precision as libjxl
  does and refuses raw tables whose denominator isn't 1/(8·255) or a
  chroma-from-luma factor other than 84; the Modular predictors, weighted
  predictor, and alias table are pub for the encoder. `rgba_f32` and
  `rgba_f32_premul` destinations come straight from the f32 planes
  (`float_direct`): all 40 conformance files are within their peak bounds
  against libjxl's floats. Open: 135 of bike's 21 M samples, blue below
  −0.13, are less negative than libjxl's unclamped output (outside the
  clamped reference's bounds). Decode speed (`wave4-jxl-speed`,
  results/jxl-speed-20261103.md): decodeJpeg's coefficients +48% (range
  checked once a block), VarDCT +21% (separable LLF DCT, coefficients kept
  zero, Gaborish vectorized in place, a cheaper cube root), Modular +16%
  (two-level tree walk, scalar weighted-predictor table reads, inlined
  symbol reads). Over ede392a: lossy +32%, lossless +16%, baseline rebuild
  +54%, peak RSS unchanged; about 0.76× libjxl lossy, 0.89× lossless, 0.59×
  rebuilding the mosaic. `jpegWorkLen` 9.2 MB at 16×16 (from 10.0), 25 MB
  at 768×512 (from 37). `modular.pixelProps` and `modular.walk` are pub for
  the encoder. Speed pass 2 (`wave4-jxl-speed2`,
  results/jxl-speed2-20261103.md): VarDCT's coefficient loop specialized on
  the code's kind (+1.3% lossy, +1.6% rebuilding), the default
  dequantization tables up to DCT32 computed at compile time (+8.8% lossy,
  icons +20–28%), and the planes left uncleared without chroma subsampling
  (+3.1%). Over pass 1: lossy +13.8%, rebuilding +2.4%, lossless unchanged,
  bit for bit, same memory; about 0.81× libjxl lossy on the 1200×1200
  photo. EPF's shared differences were measured and rejected (−0.9%,
  `cjxl -d 1` runs one iteration). Speed pass 3 (`wave4-jxl-speed3`,
  results/jxl-speed3-20261103.md): color transform and packing done per
  chunk as rows are written, straight into native-plus-alpha destinations
  (+1.5% lossy); EPF's output stored a vector at a time (+2.0%); large
  clears with the vector fill (+1.5% lossy, +2.8% rebuild, +2.2% lossless);
  output pixels interleaved eight at a time (+1.4%); Modular trees flattened
  two levels to an entry for channels of at least 4096 pixels and at most
  4096 splits (+6.5% lossless; work_len +393 KB). Over pass 2: lossy +6.2%,
  lossless +8.9%, rebuild +2.7%, bit for bit, same peak RSS; about 0.9×
  libjxl lossy on the 1200×1200 photo. Next: coefficient decoding (30% of
  lossy), the XYB transform (13%, op-bound), EPF (11%), the weighted
  predictor and symbol reads in lossless, then render by group row. Speed
  pass 4 (results/jxl-speed4-20261103.md): nothing kept; ANS,
  weighted-predictor, fused-filter, IDCT-copy and AVX-512 changes measured
  inside an A/A noise floor of about 1.5% or slower. What's left needs a
  different algorithm (a cheaper XYB power function, tables for
  single-property trees). Streaming Modular (`wave4-jxl-mstream`,
  results/jxl-mstream-20261103.md): integer Modular frames without global
  transforms stream a group row at a time, and streamed VarDCT alpha keeps
  two group rows: the 50 MP lossless arena peak falls 608 → 29 MB (peak RSS
  989 → 437 MiB with the 384 MiB output), same pixels and speed; work_len
  is unchanged. Global RCTs and palettes without deltas stream too
  (`wave4-jxl-mstream2`, results/jxl-mstream2-20261103.md): each band's
  rows have those transforms undone on their own (`modular.Image.band`).
  Only squeezes and delta palettes keep a frame whole. `work_len` still
  covers the whole frame.

Started at once by the owner ("anything we can do in parallel"), each
owning the files adding-a-format.md assigns to its format plus
`docs/slop/<fmt>.md`, with one line per registry:

- **JPEG decode** (landed; jpeg.md): `src/jpeg/`. Stage 1, baseline and
  progressive Huffman 8-bit, landed at `a12ff24`. Stage 2 landed at
  `a748af5`: arithmetic coding (SOF9, SOF10, DAC), 12-bit DCT (SOF1/2/9/10,
  native rgb16/gray16), and lossless process 14 (SOF3, P 2–16, all
  predictors, point transform, restarts). SOF11 and the hierarchical
  processes return Unsupported, as in libjpeg-turbo. Bit-exact with
  libjpeg-turbo, and at or above it by size-class geomean on every row
  (results/jpeg-stage2-20261102.md). TIFF detects its interface
  with `@hasField(image.jpeg.Decoder.Options, "tables")`. JPEG gives TIFF
  `Decoder.workLen` (work memory from IFD fields, exactly what
  `decodeConfig` states for that frame header; `multi_scan = false` bounds
  single-scan streams only) and `Options.crop` (edge tiles into a top-left
  page-buffer view), and builds the CMYK converter only for CMYK images
  (results/jpeg-tiff-20261102.md, icons +4.6%). JPEG's oracle compares `.raw` CMYK and
  YCCK decodes with libjpeg-turbo's JCS_CMYK output as cmyk8 and cmyk16, and
  corpus/gen/jpeg.sh adds ten CMYK and YCCK files from tjbench across every
  process.
- **WebP decode** (landed at `a7f586e`; webp.md, results/webp-20261102.md):
  lossless (VP8L) from RFC 9649, lossy (VP8) from RFC 6386 with ALPH (raw or
  lossless, every filter), and animation (ANIM/ANMF) under the Frame
  contract with `decodeFrameConfig`; ICCP, EXIF, and XMP go to the blob sink
  and `Config.metadata`, with late chunks through `applyTrailer`.
  `decodeConfig` states the work memory before any pixel data. VP8L:
  entropy-coded pixels, two transform rows, transform and entropy images,
  the color cache, and prefix tables for at most `Options.max_prefix_groups`
  groups (default 2600, libwebp's encoder maximum). VP8: 6W of output and
  chroma rows, about 680 bytes per macroblock column, and the kept
  partitions, bounded by the payload. ALPH: a W×H plane. Animation: two RGBA
  canvas rows plus a canvas-sized frame of either kind. Lossy pixels match
  libwebp's defaults bit for bit (fancy upsampling, 14-bit BT.601),
  including its x86 build's 16-bit wrapping in the full inverse DCT and
  32-bit AC3. A still image's partitions read past the VP8 chunk, as libwebp
  and Wuffs do. Animation composites as `WebPAnimDecoder` does (key-frame
  rule, integer blend, disposal to transparent black); the ANIM background
  is reported, never applied, and `frame_count` is null. Lossless 1.03×
  libwebp, lossy 1.02× (1.36× icons, 0.86× over 1 MP), animation 1.16×,
  peak RSS at or below libwebp in every class. Splits are in
  test/oracle/webp.zig.
- **TIFF decode** (branch `wave3-tiff`): `src/tiff/`, with TIFF's own LZW.
  Stage 1 landed at `e96a20e`, was reverted for IFD rules where it
  disagreed with libtiff on CI's corpus, and re-landed from `wave3-tiff-fix`
  at `0a17750`: it agrees with libtiff over seeds 1–200 × 20000 on CI's
  corpus and 100000 on the full corpus; the rules are in tiff.md
  "Following libtiff". Stage 1 (tiff.md, results/tiff-20261102.md): classic
  TIFF and BigTIFF; strips and tiles; chunky and planar; none, PackBits,
  LZW, Deflate, and CCITT MH/G3/G4; predictors 2 and 3; 1–32-bit integer
  and 16–64-bit float samples; gray, palette, RGB, CMYK, and subsampled
  YCbCr; every page a frame, with its size from `decodeFrameConfig`; IFDs
  and strips behind the reader through `DecodeOptions.seeker`. Integers
  wider than 16 bits scale to 16, signed samples are offset by half their
  range, and floats decode to `rgba_f32`. CMYK decodes to `cmyk8` or
  `cmyk16` holding max − ink (decision 15), float inks to `cmyk16`, with
  alpha dropped. A chain longer than `max_frames` gives a null
  `frame_count`. ×0.90 libtiff overall: faster on uncompressed data and
  icons, about ×0.5 on the compressed paths at 1 MP and above; peak RSS at
  or below libtiff's in every class. Stage 2 (results/tiff-stage2-20261102.md) adds JPEG compression (new
  style) through `image.jpeg`: JPEGTables through `Options.tables`, work
  memory from the IFD through `Decoder.workLen` for single-scan streams (a
  progressive or non-interleaved stream in TIFF is `error.Unsupported`), and
  `Options.crop` for edge tiles. Gray, RGB, and chunky YCbCr decode straight
  into the caller's rows with libjpeg-turbo's YCbCr equations, as libtiff's
  JPEGCOLORMODE_RGB has them; planar, white-is-zero, CMYK, palette, signed,
  and extra-sample pages go through a strip or tile of samples. 8- and
  12-bit, 12-bit for gray, RGB, and YCbCr only. Pixels equal libtiff's on
  every bench input; ×6.5 libtiff on icons and ×1.1–1.3 above, peak RSS
  below libtiff's in every class. The oracle decodes each JPEG strip strictly
  with libjpeg-turbo first, since libtiff conceals corrupt data. Decision
  23's follow-up landed (results/tiff-speed-20261102.md): past icons, TIFF
  LZW runs at 0.89–1.00 of libtiff, Deflate 0.93–0.95 (the rest is
  compress's per-stream Huffman setup on 8 KiB strips), PackBits 1.6–1.75×,
  and Group 4 1.2–1.5×; icons run 1.3–6× libtiff. An LZW page's work memory
  grows by 24 KiB. JPEG-in-TIFF carries DQT and DHT across strips
  (`keptTables` and `prior`), reads each frame through `frameParams`, and
  decodes gray-and-alpha as two components. The oracle skips only planar
  JPEG pages whose streams define different tables, and chunky pages of
  more than 4 samples. Group 4 and 2D Group 3 take b1 after a leading pass
  as libtiff does. compress 364ef40 (masked table build, buffered header bits,
  add-only Adler-32; results/tiff-deflate-20261102.md) brings TIFF Deflate
  to 2.16 / 1.12 / 1.02× libtiff (icons / to 1 MP / larger) and PNG decode
  to 1.30–1.58× Wuffs. compress e383aa8 (the fast loop reads through a
  cursor; results/tiff-inflate-loop-20261102.md) brings TIFF Deflate to
  2.15 / 1.16 / 1.06× libtiff, photos to 0.80–0.87×, and PNG decode to
  1.34–1.62× Wuffs; copying a match's first 32 bytes without a loop test
  was rejected (+6% inflate, but the test-card rows 3–4% slower in TIFF).
- **WebP decode performance pass** (landed; results/webp-perf-20261102.md):
  WebP decode beats libwebp in every size class. Lossless is 2.14×, 1.15×,
  1.11× (icons, ≤1 MP, >1 MP) and 1.10× on the 50 MP mosaic; lossy 1.77×,
  1.14×, 1.04×; animation 1.50× and 1.23×. Peak RSS and work memory are
  unchanged. A finding for every format: this Ice Lake server lowers the core
  clock after any zmm (512-bit) instruction, and with -Dcpu=native LLVM joins
  32-bit-lane `@Vector` math and some cross-lane shuffles into zmm. Keep hot
  kernels in 16-bit lanes or at most 256 bits, and check each with objdump
  for zmm. A large decode loop sits at the edge of the register file: when
  added code spills the bit buffer, specialize the loop at comptime.
- **PNG and APNG encode** (landed at `d50a0e8`; png.md,
  results/png-encode-20261102.md) with compress 6319823: default effort is
  level 7 filtered (1.3% smaller than libpng and libspng, 2.3–3.5× libpng's
  speed), fast is level 6 (10.6% smaller than their level 1, 1.6–2.1×).
  Palette only when it saves more than twice its cost; colors under
  transparent pixels kept; APNG frame 0 is the canvas; pHYs from
  `EncodeOptions.density`; no interlace, text, or bKGD. compress keeps a
  block's token list and output scratch in `Writer.Buffer` (426,636 bytes),
  not on the stack: in `Writer` itself, returned by value from `init`, it
  ran `zig build check -Dtarget=arm-linux` out of memory. Work memory is
  850,439 bytes plus 72 per pixel of width. Output never depends on prior
  work-memory contents (ICO measures an entry with a discarding pass).
- **GIF encode** (landed; gif.md "Encoder"; results/gif-encode-20261102.md):
  `gif.encode` and `gif.encodeAnimation` write GIF89a from any pixel format,
  allocation-free (`workLen`: 6 KiB up to 256 pixels, about 2.4 MiB above,
  plus a byte a pixel to interlace a dithered image). A frame with at most
  256 colors is stored exactly; one with more is quantized (`Quantizer.wu`,
  `.median_cut`, `.octree`, `refine` k-means passes) and dithered
  (`Dither.floyd_steinberg`, error bounded at 16 a channel, or `.none`).
  `AnimationFrame` is PNG's without `blend`; `crop` keeps only what changes.
  The oracle re-encodes every GIF input and holds the file against Wuffs and
  giflib. Bench rows `gif-encode`, `gif-encode-few`, and `gif-encode-anim`
  against giflib, gifski (a C arm through libgifski), ImageMagick, and Go:
  0.73× giflib over all rows (giflib takes our indices, so the quantized
  rows time our quantize-and-dither against its LZW writer alone), 0.73–0.81×
  on the exact path, which reads the pixels twice; 7–30× the other arms;
  peak RSS at or below giflib's past icons. Follow-ups landed
  (results/gif-encode2-20261102.md): exact frames read their pixels once
  (gif-encode-few 1.14–1.25×, giflib's speed up to 1 MP, same bytes and
  work memory); Floyd–Steinberg passes on no error from a pixel within 1 a
  channel of its entry (1.3% fewer bytes, PSNR +0.36 dB, blurred PSNR
  −0.09 dB); Wu's boxes shrink to their cells and its table is u32 up to
  16.8 MP (quantized icons 1.16×, same palettes). Not taken: an image-sized
  index buffer, and LZW loop restructures.
- **JPEG encode** (landed; results/jpeg-encode-20261102.md): baseline and
  progressive, 4:4:4/4:2:2/4:2:0, optimized tables, byte-identical to
  libjpeg-turbo; 1.87× its speed over all rows, 0.93× on baseline 4:2:0 over
  1 MP; peak RSS at or below it. The performance pass
  (results/jpeg-encode-perf-20261102.md) puts every class at or above
  libjpeg-turbo, with the same bytes: baseline over 1 MP 1.18× (4:2:0) and
  1.26× (4:4:4), 2.16× over all rows. No zmm in the encoder; the source is
  prefetched 4 rows ahead.
- **HDR metadata** (branch `wave6-hdr-meta`, a new orb, decision 51): the
  new `Metadata` fields in `src/decode.zig`, PNG cICP/mDCV/cLLi in
  `src/png/` (decoder and encode.zig), the gain-map flag in the JPEG
  decoder's APPn handling, and their fuzz and oracle files.
- **JPEG for TIFF stage 2** (landed): `Decoder.frameParams()`;
  `Options.tables` reads tables streams as libjpeg's header reader does
  (SOFn dropped, DNL skipped, RSTn and TEM ignored); `keptTables()` and
  `Options.prior` carry DQT and DHT across strips, as libjpeg does, with DAC
  and DRI reset at each SOI; 2-component streams decode as gray_alpha8 or
  gray_alpha16 (JCS_UNKNOWN in the oracle).
- **WebP lossless encode** (branch `wave5-webp-encode`, the performance
  orb): `src/webp/encode.zig` and any new `src/webp/encode_*.zig` files, the
  webp_encode fuzz and oracle files, and the webp-encode bench rows. It adds
  only its export lines to `src/webp/root.zig`; the rest of `src/webp/`
  stays with the WebP orb's performance pass. Stage 1 landed
  (results/webp-encode-20261102.md): `image.webp.encode`, `workLen`, and
  `EncodeOptions` (effort 0–9, cwebp's `-z` levels, default 5), plus
  `encodeAlpha` for the lossy encoder's ALPH chunks, written from RFC 9649.
  Smaller than libwebp in total bytes at every level and faster at every
  level on large images; behind on speed at efforts 1–2 (and 4–7, slightly)
  on flat few-color images, and 2–3% larger on icons from effort 3. Effort 5
  is 1.2% smaller than libwebp's default `-z 6` at 1.1–2.9× its speed. The
  oracle leaves out Wuffs for VP8X files: Wuffs 0.4 decodes no VP8L inside
  VP8X. Stage 2, on `wave5-webp-encode2`: low-effort speed on flat images, work
  memory's fixed part on icons, and no zmm in the code-length builder.
  Stage 2 landed (results/webp-encode-stage2-20261102.md): no zmm in the
  encoder (radix sort in buildLengths, u16 lanes in lengthCodeCost);
  output-identical changes 1.08× overall (icons up to 1.19×); workLen
  0.17–0.31 MB on a 16×16 icon, from 0.52–4.1 MB; efforts 1 and 2 stop the
  match search at 64 pixels (12% faster on the mid class for 0.1% more
  bytes, flat images up to 5% larger, still below libwebp's totals). Effort
  7 keeps nice 256. Open: flat, few-color images at efforts 1–7 run
  0.2–0.5× libwebp's speed and need a separate cheap path. Stage 3
  (results/webp-encode-alpha-20261102.md): `encodeAlpha` searches no hash
  chain. Far matches led the optimal parse into a local optimum on alpha
  planes, and libwebp's ALPH uses no transforms, so the gap was in backward
  references. Alpha streams are 5–9% smaller and 1.16–1.60× faster from
  effort 1, and effort 9 is the smallest. Effort 1 beats libwebp -m 2 by
  4.2% in less time; effort 8 is 1.7% above -m 6 at 1/25 of its time. The
  fuzz target and the oracle cover `encodeAlpha` through a VP8L header.
  Stage 4 (`wave5-webp-encode4`, results/webp-encode-flat-20261103.md): the
  same bytes, 1.28× main over the 210 encode rows (1.17–2.66× on 16 KP–1 MP
  at efforts 1–9, 1.96× libwebp), and `encodeAlpha` 1.28/1.79/2.71× at
  efforts 1/5/8. Clustering caches pair costs, match lengths carry along a
  match, the chain skips a run's own pixels, the parse skips dominated near
  codes, and the color cache is chosen in one pass. Left: qoi_logo
  0.39–0.66× libwebp at efforts 1–6 (its bytes need no chain; decision 66),
  water1 0.71–0.77× at 1, 2, and 7, and memset (the harness's shared fill:
  21% of a 16×16 encode).
- **TIFF encode** (branch `wave5-tiff-encode`, the BMP/ICO orb):
  `src/tiff/encode.zig` and any new `src/tiff/encode_*.zig` files, the
  tiff_encode fuzz and oracle files, and the tiff-encode bench rows. It adds
  only its export lines to `src/tiff/root.zig`; the rest of `src/tiff/`
  stays with the TIFF orb (the compressed-path speedup). Landed
  (results/tiff-encode-20261102.md): classic little-endian TIFF,
  `tiff.encode` and `encodePages`; none, PackBits, LZW, and Deflate with
  Predictor 2; libtiff's 8 KiB strips; gray, gray and alpha, RGB, RGBA,
  palette when smaller, and CMYK at 8 or 16 bits; density tags. IFD-first
  layout that reads forward. A page is compressed once when the writer's
  buffer holds it and twice otherwise (1.92–2.01× two passes). Uncompressed,
  PackBits, and LZW strips are byte-identical to libtiff's. Against libtiff:
  PackBits 1.5–2.8×, LZW 1.25–1.70×, Deflate 0.60–0.73× (compress against
  zlib), uncompressed 0.95–13.8×; peak RSS about 3 MiB under libtiff.
- **Vector fill** (`wave2-memset`, the harness orb; results/memset-20261103.md):
  `@memset` of a runtime length, and LLVM's zeroing of large aggregates,
  call compiler_rt's byte-wise memset even with libc. Large or per-call
  clears use `src/fill.zig`'s 256-bit `fill` (volatile vector stores, or
  LLVM turns the loop back into memset), and short fills keep `@memset`.
  bmp-decode-rle 1.57×, ico-decode 1.48× (its PNG decoder left the
  `picked` union), progressive JPEG 1.26×, tiff-decode-jpeg 1.21×,
  tiff-encode-lzw 1.11×, GIF and WebP lossless encode 1.05–1.15×. TIFF
  PackBits keeps `@memset` (runs of at most 128 bytes). Left: WebP lossy
  decode and animation clears (WebP lossy orb), compress's
  `flate.Writer.initInPlace` (done in compress 61998af with its own
  `fastmem.set`, also for `bitCounts`' leaf counts; image pins it:
  tiff-encode-deflate 1.04–1.05×, PNG encode icons 1.03–1.04×, the same
  bytes; results/deflate-clears-20261103.md).
- **Harness pass 4** (landed; results/oracle-memory-20261102.md): the oracle
  streams each batch behind its length, sends a decoder's requests op by op
  (adapting each input once per op), and reads corpus files from disk as
  batches need them. With the full corpus on an 8 GB orb (6 GiB cgroup),
  `just oracle 100000` peaks at 1.9 GiB (was OOM-killed at 5.6) and `just
ci` at 4.65 GiB, the test compiles; the oracle pass is 16% faster. Pass 6
  (results/test-memory-20261102.md) builds `just test`'s ReleaseFast unit
  tests after ReleaseSafe instead of beside it: `just test` peaks at 3.3 GiB
  (was 4.9) and takes 203 s (was 113).
- **WebP lossy encode** (branch `wave5-webp-lossy`, a new orb):
  `src/webp/vp8_encode.zig` and any new `src/webp/vp8_encode_*.zig` files,
  the webp_lossy_encode fuzz and oracle files, and the webp-encode-lossy
  bench rows; only its export lines in `src/webp/root.zig`. Landed
  (webp-lossy-encode.md, results/webp-lossy-encode-20261102.md):
  `image.webp.lossy`, one VP8 key frame from RFC 6386, simple format or VP8X
  with alpha or ICCP/EXIF/XMP. Quality 0–100 maps to cwebp's base
  quantizer; four segments by luma activity, each with its own quantizer and
  filter level; rate-distortion mode choice for 16×16, 4×4, and chroma;
  token probabilities and the skip flag chosen by cost. Efforts `fast`,
  `default`, `best`. Alpha goes in ALPH through `encodeAlpha` at lossless
  effort 0/1/5, unfiltered, raw when smaller; colors under alpha 0 cost
  nothing. At quality 75 against libwebp 1.6.0 (BD-rate PSNR/SSIM, 18 opaque
  images): `fast` vs -m 2 −4.5%/−1.2% at 1.10–1.22× its speed; `default` vs
  -m 4 −1.1%/−4.6% at 1.15–1.46×; `best` vs -m 6 +0.8%/−4.3% at 1.00–1.08×.
  RGBA, visible PSNR: −3.6% vs -m 4. Peak RSS below libwebp's except RGBA
  ≤1 MP (31.0 vs 30.1 MiB). Pass 2 (`wave5-webp-lossy3`,
  results/webp-lossy-trellis-20261102.md): trellis quantization
  (`vp8_encode_trellis.zig`) on the chosen modes at `default` and in every
  choice at `best`, at 10/16 of the mode-decision lambda for luma and 5/16
  for chroma. Below `best`, 4×4 is skipped when the 16×16 choice costs under
  64 bits' worth. Tokens are counted by class, the token partition is coded
  once into the level store's spare room, and modes are ranked by strip
  SATD. Alpha uses efforts 1/1/8 (decision 65). SNS-like tuning found
  nothing that gained on both PSNR and SSIM. `default` is 2.7%/4.4% smaller
  than -m 4 at equal PSNR/SSIM, at 1.28–1.38× its speed (0.96× on icons);
  `fast` is 0.92× -m 0's speed over 1 MP with 17.5% smaller files; `best` is
  0.6× -m 6. Pass 3 (`wave5-webp-lossy4`, results/webp-lossy-speed-20261103.md): token costs from each class's tree path plus a constant table, both partitions coded once into the level store's spare room (`Counter` removed), and the token histograms zeroed with vector stores (compiler_rt's memset is byte-wise without libc), for the same files; `best`'s first pass searches as `default` does, while its coding pass keeps trellis in every choice (decision 73), for the same size. `default` runs at 1.30–1.44× libwebp -m 4 in every class (icons from 0.95×), `fast` at 2.74× -m 2 on icons, and `best` at 0.83–0.97× -m 6, 1.7%/4.8% smaller at equal PSNR/SSIM. Next: trellis is half of `best`'s time; `fast` is 0.93× -m 0 over 1 MP. The vector fill (`wave5-webp-fill`, results/webp-fill-20261103.md) clears `vp8.decodeFrame`'s coefficients and the encoder's histograms: webp-decode-lossy 1.056×, webp-decode-anim 1.037× (the rest of anim's memset is the bench's own disposal).
- **Shared types for JPEG XL** (landed; results/convert-f32-20261102.md):
  decision 29's metadata fields (`Transfer` bt709, dci, pq, and hlg;
  `Metadata.primaries` replacing `chromaticities`; `intensity_target`;
  `jpeg_reconstruction`), `rgb_f32` and `gray_f32`, and SIMD between float
  and 8- or 16-bit samples in the same layout (5–16× the general path).
  PNG encode takes `primaries`. The JPEG XL orb still maps its colour
  encoding into the new fields.
- **JPEG reconstruction** (branch `wave4-jxl-jbrd`, the Netpbm orb):
  `src/jxl/jbrd.zig`, `src/jxl/JpegReconstructor.zig`, and their fuzz and
  oracle files, on `Decoder.decodeJpeg` and `Decoder.Jpeg`, the coefficient
  pass the JPEG XL orb added (`wave4-jxl-coeffs`, landed: coefficients and
  quant tables equal libjpeg's `jpeg_read_coefficients` of djxl's
  reconstruction on 353,186 blocks; chroma from luma undone in integers).
  The rest of `src/jxl/` stays with the JPEG XL orb (render by group row,
  then speed). The jbrd box and the JPEG writer landed (byte-identical on 67
  cjxl transcodes given libjpeg-turbo's coefficients); `JpegReconstructor`
  needs a seeker. Stage 2 landed (results/jxl-jbrd-20261102.md):
  `JpegReconstructor` rebuilds the transcoded JPEG byte for byte from
  `jbrd` and `Decoder.decodeJpeg`; it matches libjxl on 67 committed
  transcodes and on every oracle input (no exclusions; seeds 1–10 at 20000
  and 100000 at seed 1, 0 mismatches). 0.63× libjxl overall, faster on icons
  (1.48–1.67×), 0.31× baseline and 0.56× progressive past icons, peak RSS
  lower in every class; decodeJpeg is 63–87% of the time. The Brotli state
  (compress's `brotli.decode.Buffer`, 6953f33) lives in the work memory.
  Open: libjxl also refuses a colour factor other than 84, which decodeJpeg
  doesn't check yet.
- **JPEG XL lossless encode** (branch `wave5-jxl-encode`, the TGA orb):
  `src/jxl/encode.zig` and new `src/jxl/encode_*.zig` files, the jxl_encode
  fuzz and oracle files, and the jxl-encode bench rows; only its export
  lines in `src/jxl/root.zig`. Stage 1 landed (jxl-encode.md,
  results/jxl-encode-20261102.md): one lossless Modular frame in a bare
  codestream. 8-bit sources are stored at 8 bits and others at 16, CMYK as
  RGB, alpha as an extra channel (associated when premultiplied). A global
  palette, or the cheapest of the 42 RCTs; 256×256 groups; one MA tree
  learned from sampled rows of every group; ANS with up to 256 clustered
  histograms. Efforts `fast`, `default`, and `best` sit at about cjxl e3,
  between e6 and e7, and e8 in size; `default` runs at e7's speed above
  icons and 0.43× on icons. Files decode bit for bit in libjxl (oracle),
  jxl-oxide (117 files), and ours. LZ77 was measured with no gain and is not
  kept. Stage 2 (`wave5-jxl-encode2`, results/jxl-encode2-20261102.md): the
  jxl_encode oracle runs under a minute at 20000 inputs. Tree learning
  stores u8 property buckets (default peak 158→124 MiB, best 255→144 MiB;
  libjxl e8 267). Icons encode 1.2–1.7× faster. The fast and default trees
  grow to 256 and 2048 leaves: default matches e7's size (1.003× total) at
  0.82× of e7's speed up to 1 MP and 1.01× above; decision 71 then set
  default to 1024 leaves. The encoder uses the
  decoder's predictors, weighted predictor, and alias table; the per-pixel
  properties stay private until the decoder shares them. Stage 3
  (`wave5-jxl-encode3`, results/jxl-encode3-20261102.md): groups take
  palettes and RCTs of their own (cjxl's local transforms), chosen by
  estimate with a 3% RCT margin, few-color and majority rules for palettes.
  The corpus is 0.8/1.4/1.5% smaller at fast/default/best (0.969 of e3,
  0.990 of e7, 0.983 of e8) at the same speed; amazon.com is 0.983 of e7,
  apple.com 1.043. Next: icon speed (0.58× e7 at default), prefix codes for
  small images, the apple.com gap, count subtraction in split scoring, and
  work tables sized from the image. Stage 4 (`wave5-jxl-encode4`,
  results/jxl-encode4-20261103.md): tree-learning counting is faster, with
  the same files: icons 1.3–1.5×, ≤1 MP 1.06/1.22/1.39× at
  fast/default/best; default is now 0.84/1.08/1.27× e7's speed (icons / to
  1 MP / above). Prefix codes for small images were measured and not kept
  (two icons gained, 6–10% of icon time). The apple.com gap is sample
  coverage; scaling default's samples with image size is with the owner.
  Stage 5 (`wave5-jxl-encode5`, results/jxl-encode5-20261103.md): the
  encoder uses the decoder's `pixelProps`, with the same files and speed.
  The decoder's `walk` was measured slower for the encoder (fast 0.91 above
  a megapixel) and isn't used; `Flat` stays. Stage 6
  (results/jxl-encode6-20261103.md): `workLen` sizes leaves, histograms,
  samples, and learning counts by the image. At 16×16 that is 0.5 / 0.8 /
  3.8 MiB at fast / default / best, down from 3.8 / 5.6 / 8.1. The files
  and the speed are the same. Best keeps 3.1 MiB of counts at any size,
  because it judges each split with all 14 predictors. Stage 7
  (results/jxl-encode7-20261103.md): decision 75 as decided. Images above a
  megapixel come out 1.0% smaller at default (apple.com 1.019 of e7), at
  0.91× their speed (1.23× e7). Peak RSS rises from 126 to 142 MiB (libjxl
  261), because 2^20 samples add 25 MB of work memory at 32 bytes each.
  Stage 8 (results/jxl-encode8-20261103.md): learning samples are kept as
  rows, packed to 21 bytes at default and 36 at best wherever they would
  outgrow the token store, and partitioned in place, so the files are the
  same. `workLen` counts learning's memory and the parts after it once.
  Peak RSS falls from 142.5 to 131.3 MiB at default and from 143.1 to 131.2
  at best, so decision 75 now costs 5.5 MiB. Default runs at 1.02× and best
  at 1.06–1.10×.
- **Harness pass** (landed at `28b6e10`): bench arms skip inputs they fail,
  one shared `loadCorpus` with a 64 MiB limit, `Result.eql` compares error
  codes (a Zig 0.16 x86_64-backend miscompile of `?anyerror` `==`), seeds
  encoded as Smith reads them, `N/target` fuzz budgets, the shared
  `magick_decode`, fuzz modules import compress, and a parallel, cached
  oracle that cut warm `just ci` from 241 s to 59 s.
- **TGA fuzz cleanup** (landed at `f4513e3`): TGA's fuzz targets run in
  Debug with raw seeds; `bench/corpus-gen/tga` stays out of the corpus, since
  it cut the fuzz rate 14× and found nothing.
- **Netpbm corpus** (landed at `20a1f64`): the CNN screenshot is back in the
  bench corpus; zune's failure on it is a skipped row.
- **bmp-stb determinism** (landed at `56024dd`): stb_image reads its
  uninitialized on-stack palette for some BMPs; bmp-stb now skips those, and
  BMP split counts are stable between runs.
- **Performance pass 1** (landed at `0469a46`, with compress at `1cdd3d8`):
  conversion row tails go through the SIMD kernels, and RGB↔BGR stores whole
  cache lines. PNG unfilters rows from the inflate window, pairs Average and
  Paeth rows, folds the CRC with PCLMULQDQ, and expands 8-bit palettes with
  one loop per layout: 1.19× Wuffs with compress's faster inflate (0.82× on
  fd03d72), at 239.5 MiB peak RSS against Wuffs's 384.2. Netpbm scans plain
  samples with 64-byte digit and whitespace masks and reads headers from the
  buffer. QOI takes INDEX without the index store and fills runs 8 pixels a
  store: 0.99–1.18× the `qoi` crate and 1.64–1.83× Wuffs. Results:
  convert-tails, png-perf, netpbm-perf, and qoi-perf (20261102). A
  `@Vector(N, bool)` bit cast puts lane 0 in the top bit on big-endian; use
  a helper that reverses it there.
- **Performance pass 2** (branch `wave2-perf`): `src/convert.zig` and
  `src/qoi/`. Landed so far: the `cmyk8` and `cmyk16` kernels (decision 15),
  and QOI decode in one loop at every size (results/qoi-icons-20261102.md):
  INDEX, runs, and RGBA take their own branches, and DIFF, LUMA, and RGB go
  through the 256-entry table. The 64×64 branch-per-kind loop is gone: it
  won only on single-file icon rows, where the predictor has learned the
  file. Rotating icons are 1.31–1.60× the qoi crate. QOI encode treats
  packed `rgba8` and `rgb8` sources as one span, and its chunk loop checks
  only a pixel count, computed from the output room left
  (results/qoi-encode-20261102.md): 1.02–1.17× the `qoi` crate by size
  class. The full bench-compare on eabc1ac found no convert row below 1
  outside noise. The decoder's chunk loop checks one count, the smaller of
  buffered bytes / 5 and pixels left, cut after each run
  (results/qoi-decode-bound-20261102.md): 1.03×. Screenshots stay at
  0.87–0.88× the crate. Local copies of the index and run carry do not pay
  (results/qoi-decode-locals-20261102.md: 0.99× overall, icons down to
  0.86×), so the QOI decoder work stops here.

Wave 1, five orbs in parallel. Each owns the files adding-a-format.md assigns
to its formats, plus `docs/slop/<fmt>.md` for its notes and decisions, and
adds one line per format to each shared registry and a CHANGELOG bullet;
registry lines conflict trivially on rebase, and both sides stay. The
orchestrating thread owns everything else: the shared `src/` files
(`root.zig` beyond the registry lines, `pixel.zig`, `convert.zig`,
`decode.zig`, `encode.zig`, `detect.zig`, `Decoder.zig`, `exif.zig`), the
harness cores, `build.zig`, the justfile, the flake, CI, and this file. An
orb asks for a change to them, or for text in this file, in its report.

- **PNG and APNG decode** (landed; png.md has the design). Work memory is
  the 64 KiB inflate window, an 8 KiB chunk stage, and two rows, so nothing
  scales with height. Checksums are strict, as in Wuffs: CRC-32 of critical
  chunks (`BadCrc`) and the zlib Adler-32 (`BadChecksum`); ancillary CRCs are
  not checked, as Wuffs, libpng, and libspng do not. Image data must
  decompress to exactly the frame. An APNG's default image outside the
  animation is skipped, as Wuffs and the APNG spec do, and `frame_count` is
  acTL's, with no option to decode the default image until a caller needs
  one (owner); an APNG's native format always has alpha (owner: keep, as
  Wuffs does), and frame 0 clears
  outside its region to transparent black. Palette indices past the palette
  decode as opaque black. Metadata is reported, never applied; iCCP and eXIf
  go to the blob sink. Inflate is compress's, pinned to commit 1cdd3d8
  (0.38× Wuffs on compress 0.2.0, 0.79× on fd03d72's fast path, 1.19× on
  1cdd3d8 with the performance pass); the owner chose a pinned commit over a
  compress release.
- **BMP, ICO and CUR, decode and encode** (landed; bmp.md and ico.md).
  `src/bmp/dib.zig` is shared by both. ICO reads entries forward in directory
  order; an entry behind the reader needs an `image.Seeker` (`DecodeOptions.seeker`; `fixed` over a
  `Reader.fixed`, at no copy, or `file`) and is `error.EntryBehind` without
  one, and `Options.entry` decodes one entry without seeking (a PNG entry
  through `image.png`, read through IEND; an APNG entry stops after its first
  frame). PNG entries
  decode only through `Options.entry` until png has a `workLen` bound, and
  PNG-entry encoding waits for wave 5.
- **GIF decode** (landed; gif.md). GIF87a and GIF89a from the specifications,
  with the NETSCAPE2.0 (and ANIMEXTS1.0) loop count. Work memory is about 68
  KiB for any image: the LZW table, whose entries hold 8 bytes of their
  string's tail, an 8 KiB index buffer, 4 KiB of sub-blocks, and the palette
  in the destination's format. Frames follow APNG's model. Frame 0 clears
  outside its region and writes transparent pixels as transparent black
  (`src`); later frames with a transparent index are `src_over`. Disposal 2 is
  background (transparent black; the background color is reported, not
  applied), 3 and 4 are previous (4 as Wuffs and Chromium read it), and frame
  0's previous is reported as background. `gif.Decoder.decodeFrameConfig`
  returns the next frame before it is drawn. Native format is RGBA8 and
  `is_opaque` is false. `frame_count` is null, and `loop_count` is 1
  without a loop extension before the first frame. Where Wuffs and giflib
  disagree it follows Wuffs: the canvas grows to hold the first frame and
  later frames are clipped; LZW data must hold exactly the frame
  (`NotEnoughData`, `TooMuchData`), and data after the end code is skipped; a
  byte that starts no block ends the image; the last of several graphic
  control extensions wins; an index past the color table is opaque black. A
  minimum code size of 0 decodes, since both references read it. A missing
  trailer is `Truncated` after the last frame. XMP and ICC are skipped until a
  blob can stream without a length. 1.12× Wuffs over 52 rows, with the lowest
  peak RSS of every arm (results/gif-20261101.md).
- **TGA, decode and encode** (landed; tga.md). Every image type in the 2.0
  spec. The color map is the only work memory. The footer and extension area
  follow the pixels, so the `decodeFrame` call that returns null reads them,
  and `Decoder.trailer()` reports gamma (as PNG's gAMA, 100000 / gamma),
  aspect ratio, key color, and attributes type. A 16-bit attribute bit is
  alpha only when the descriptor names attribute bits; an index outside the
  map is opaque black, as in Wuffs. The encoder writes top-left 8-bit gray,
  24-bit BGR, or 32-bit BGRA, uncompressed or RLE, with a 2.0 footer.
- **Netpbm, decode and encode** (landed; netpbm.md). Native format is 8-bit
  for maxval ≤255 and 16-bit above, PBM is gray8, PFM is rgba_f32; any other
  maxval scales exactly, round(v·255/m) or round(v·65535/m). Raw files are
  frame sequences whose images must match the first (`FrameMismatch`;
  Netpbm's tools allow mixed sizes), with `frame_count` null; plain and PFM
  files hold one image. PFM's scale sign is the byte order and its magnitude
  is not applied. The encoder defaults to PGM, PPM, or PAM (for alpha) at
  maxval 255 or 65535, and float sources to a 16-bit RGB_ALPHA PAM, since
  `checkEncoder` uses default options.
- **WBMP decode and encode, QOI encode, and the QOI decoder follow-ups**
  (landed at `d61c1c7`; wbmp.md, qoi.md, results/wbmp-qoi-20261101.md): QOI
  decode 1.47–1.54× Wuffs and 0.79–1.03× the `qoi` crate; QOI encode
  byte-identical to qoi.h at 1.5× its speed; WBMP 48–114× Wuffs. WBMP is
  strict: type is the single octet 0, the fixed header 0, dimensions at most
  5 octets in u32, zero width or height allowed (as Wuffs); native gray8.
  The encoder thresholds image.convert's gray at 128. QOI decode keeps a
  branchy loop below 64×64 and a 256-entry table loop above. An encoder that
  needs no work memory returns 0 from `workLen`; both wave 1 encoders do.
- **PNG LaxDiffers fix** (landed at `33cca5f`): the fuzz check compared
  `?anyerror` values, the Zig 0.16 Debug miscompile again; it compares error
  codes now. Compare optional errors only through `errorCode`.
- **Harness pass 2** (landed at `f86574e`): `harness.checkEncoderWith` with
  an `expect` hook and sides past 64; an encode op in the oracle protocol;
  `just oracle N SEED FORMAT...`; raw encode inputs sized from their names;
  oracle-build renaming into place; rotating icon rows
  (results/icon-rotation-20261102.md).
- **Harness pass 3** (landed at `346a22a`; results/oracle-pass-20261102.md):
  hashed oracle answers, per-input work memory (the WebP OOM), small
  mutation bases, the sorted corpus walk, `PF_CMYK8`/`PF_CMYK16` in the
  oracle protocol, `checkDecoder`'s `decodeFrameConfig` and seeker passes,
  per-class peak RSS, ReleaseFast unit tests, and oracle-ci as its own job
  uploading mismatches. Agree counts moved once with the sort.
- **Harness pass 5** (landed at `ab2e128`): a format's oracle module may
  declare `pub const tolerance: u16 = N`, and compare.zig then compares its
  pixels within N (u8 or u16 units; N/65535 for floats) instead of hashes; no
  format declares one yet (jxl's lossy frames, tried at 1, show 162
  mismatches with differences up to 52, for the JPEG XL orb). The Go bench
  arm unmaps each row's buffers when the next loads (a full serve run went
  from OOM at 6.2 GiB to 1.5 GiB). `harness.Trickle` is public.
- **Decoder contract** (landed at `5b7b9f4`): `image.Decoder.finalConfig`
  with an optional `applyTrailer` (decision 10); `decodeFrameConfig`
  (decision 11), forwarded when a format has one, synthesized for formats of
  at most one frame, and `Unsupported` otherwise; `Blob.len` as `?u64` with
  `Blob.endsAt` (decision 13).
- **Contract wiring** (landed at `a7976c3`): decisions 10 and 11 are wired
  for TGA (`applyTrailer`: gamma, density, key color), PNG (`applyTrailer`:
  late eXIf; other late Config chunks are ignored as the spec requires;
  `decodeFrameConfig` for APNG) and Netpbm (`decodeFrameConfig`; raw P5 and
  P6 no longer Unsupported). PNG's `max_frames` applies when a frame past
  the limit is reached; an acTL count over the limit leaves `frame_count`
  null. The BMP/ICO orb keeps `src/tga/`, `src/png/` (decoder) and
  `src/netpbm/`.
- **GIF follow-ups** (landed at `e6e0414`; results/gif-options-20261102.md):
  decision 12. `loop_count` is 1 without a loop extension, and
  `gif.Decoder.Options.ignore_too_much_data` matches Wuffs's quirk, including
  when a zero-area or interlaced frame counts as whole.
- **GIF metadata** (landed at `5c3839d`; results/gif-meta-20261102.md): GIF
  reports ICC (ICCRGBG1012) and XMP (XMP DataXMP) through the blob sink and
  Metadata under decision 13. The first of each kind wins, and ones after the
  first frame go through `applyTrailer` and `finalConfig`. The oracle hands
  Wuffs empty NETSCAPE2.0 extensions renamed, because Wuffs reads their
  terminator as a sub-block size (gif.md).
- **Netpbm oracle determinism** (landed at `c94a296`): a data race, not an
  oracle library. `comparable()` cached our decode in globals shared by the
  oracle's worker threads; they are `threadlocal` now. Wrappers that keep
  state must keep it per thread (GIF's saved canvas is the other one).
- **Seeker** (landed at `6ee1d9f`): `image.Seeker` in `src/decode.zig`,
  `DecodeOptions.seeker`, passed through by `image.Decoder` to formats whose
  `Options` have the field.
- **PNG strictness** (landed at `f521a91`): `png.Decoder.Options` has
  `ignore_checksums`, which skips the critical-chunk CRCs (about 4.5% of
  decode time, results/png-ignore-checksums-20261101.md) and accepts a wrong
  Adler-32; compress's `zlib.Reader` cannot skip computing it yet.
- **Conversion rounding** (landed at `938b0c4`): `src/convert.zig` matches
  Wuffs's rounding (decided by the owner: match the references unless there
  is a strong reason not to). `src/convert.zig` is the orchestrating
  thread's again.

## Decisions to measure

1. **Streaming model. Decided: pull from `std.Io.Reader`.** Measured in
   wave 0 against a Wuffs-style resumable push decoder on the QOI decoder
   (results/streaming-20261101.md): within ±1.3% per call on 16×16 to 64×64
   icons, 3–4% slower than pull over a megapixel, a 4 KiB-chunked reader
   costs pull 1.5%, and push needs resumption state at every level of a
   format. Decoders need a reader buffer of at least `min_buffer_len` (64)
   bytes.
2. **JPEG IDCT and upsampling.** libjpeg-turbo's integer IDCT and fancy
   upsampling decide whether our pixels can match it exactly. Default: match
   libjpeg-turbo's output bit for bit, so it is a strict oracle. Landed with
   JPEG stage 1 (results/jpeg-20261102.md): libjpeg-turbo's islow IDCT,
   fancy upsampling, and YCbCr to RGB, bit for bit, at 1.03–1.35× its
   throughput on photos over 1 MP and 3–5× on icons, with peak RSS at or
   below it. No trade was needed.
3. **JPEG encoder quality.** libjpeg-turbo is the speed bar and mozjpeg the
   size bar. Measured (results/jpeg-encode-20261102.md): at equal PSNR,
   mozjpeg's trellis is no smaller than our optimized baseline (+0.6% to
   +1.9%); at equal SSIM it is 6.6% smaller, and mozjpeg's full profile 12.2%
   smaller than our progressive, at 8–14× less speed. Decided by the owner
   (decision 30): no trellis by default; an opt-in size mode measured by
   SSIM or butteraugli may come after phase 1.
4. **JPEG XL lossy encoding. Decided by the owner (decision 57): phase 2.**
   VarDCT encoding is as large as the decoder.
5. **JPEG XL's JPEG reconstruction** (`jbrd`, the original JPEG's exact
   bytes). In scope for decode. Producing `jbrd` files from JPEGs (lossless
   JPEG recompression) is phase 2, alongside VarDCT encoding (decision 58).
6. **GIF quantization.** Which quantizer (median cut, octree, k-means) and
   dither, measured on quality and speed against gifski and ImageMagick.
   Measured (results/gif-encode-20261102.md, 16 images): Wu beats median
   cut by 0.6 dB and octree by 3.3 dB at the same speed; `refine` adds at
   most 0.17 dB; bounded Floyd–Steinberg has the best blurred PSNR of every
   encoder measured (51.17 dB; ImageMagick's Floyd–Steinberg 50.93, gifski
   q100 46.92) at 2.1 dB less PSNR than no dither and 20% more bytes.
   Decided by the owner (decision 43).
7. **Dropping alpha. Decided by the owner: drop it, never composite.**
   Converting to a format without alpha keeps the stored colors, as qoi.h,
   stb_image, ImageMagick's RGB export, libpng's `strip_alpha`, Pillow, and
   Rust's `image` do; Wuffs and Go composite onto black, a consequence of
   converting through premultiplied color. A conversion has no background to
   composite onto, and dropping loses nothing a caller could not composite
   from; a premultiplied source dropped is already composited onto black.
   Compositing was briefly on main (8d974d2, reverted): it cost RGBA8 to RGB8
   a premultiply, 0.17–0.52× the drop (results/convert-rounding-20261101.md).
   Oracles that composite (Wuffs) are left out of answers without alpha for
   sources with alpha. An explicit background option in `convert` can come
   later if callers need one.
8. **Offsets that do not ascend (ICO, TIFF). Decided by the owner: forward,
   with a caller's seeker.** Data behind the reader needs an `image.Seeker`
   (`fixed` over a `Reader.fixed`, at no copy, or `file`) passed in
   `DecodeOptions.seeker`, and is an error without one. Sorting offsets
   cannot serve TIFF's IFD chain, and buffering the whole file breaks
   caller-owned memory (ico.md).
9. **PNG strictness. Decided by the owner:** an `ignore_checksums` option,
   off by default, as Wuffs's IGNORE_CHECKSUM quirk; and one-row interlaced
   images with extra data are accepted, as Wuffs does.
10. **Metadata after the frames. Decided by the owner:**
    `image.Decoder.finalConfig() ?Config`, the `Config` from `decodeConfig`
    updated with what followed the frames, available once `decodeFrame` has
    returned null. A format opts in with an optional `applyTrailer(d, config)`
    that overwrites only the fields it found late. `frame_count` is not
    filled from the frames decoded.
11. **The next frame before it is drawn. Decided by the owner:**
    `decodeFrameConfig() !?Frame` joins the generic decoder contract, as
    Wuffs's `decode_frame_config`; GIF and APNG need it to save the region a
    restore-to-previous frame brings back.
12. **GIF. Decided by the owner:** without a loop extension, `loop_count`
    is 1, as browsers play the file once; too much LZW data is
    `TooMuchData` unless an off-by-default option (as Wuffs's
    IGNORE_TOO_MUCH_PIXEL_DATA quirk) accepts it; disposal 4 is previous,
    as Wuffs and Chromium read it.
13. **Blobs whose length is known only at their end. Decided by the owner:**
    `Blob.len` is `?u64`. Pieces before the end carry null, and the last
    call carries the final length, its bytes possibly empty; formats that
    know the length up front pass it on every piece as before. For GIF's ICC
    and XMP the blob is the payload, not the stored bytes.
14. **JPEG block smoothing. Decided by the owner: no.** libjpeg-turbo's
    estimate of low AC coefficients in truncated progressive files follows
    no specification, and matching it would mean translating its source.
    The oracle turns it off.
15. **CMYK. Decided by the owner:** CMYK and YCCK decode to RGB by the
    naive conversion by default, and the raw inks are available. Shared
    `cmyk8` and `cmyk16` pixel formats make the inks native for JPEG and
    TIFF, with the naive RGB in `image.convert`. Landed
    (results/convert-cmyk-20261102.md): `cmyk8` and `cmyk16` hold inks
    stored inverted, as Adobe's JPEGs and libjpeg-turbo's output have them,
    so all-zero bytes are black as in every format. `image.convert` gives
    libjpeg-turbo's naive RGB bit for bit (SIMD from `cmyk8`, 1.3–1.8 GP/s)
    and a naive inverse. JPEG's `.raw` can report `cmyk8` with its samples
    unchanged (wider samples scaled to `cmyk16`); TIFF writes `max - ink`.
    JPEG's `.raw` reports `cmyk8`/`cmyk16` as native, and its default 8-bit
    path converts through `image.convert` (results/jpeg-cmyk-20261102.md,
    +45%).
    Adding `PixelFormat` values reseeds TGA's oracle inputs (its generator
    draws the encoder's source format from every format), so TGA's counts
    move once without a decoder change.
16. **PNG encode. Decided by the owner:** the default effort is compress
    level 7 with filtering (1.3% smaller than libpng and libspng at 2.2–3.5×
    libpng's speed). A palette is used only when it saves more than twice its
    own bytes. Colors under fully transparent pixels are kept. APNG frame 0
    covers the canvas, with no hidden default image. pHYs is written; interlace,
    text, and bKGD are not. compress's writer takes its per-block scratch
    (about 320 KiB) from the writer's memory, not the stack.
17. **ICO encode. Decided by the owner:** the default payload is `.auto`: PNG
    for 256×256 entries, BMP otherwise. Landed (wave1-ico-png): `ico.Payload` per
    image, `.auto` the default; PNG entries measured with
    `Io.Writer.Discarding`, then written; `encodeAll` takes `work`; a
    one-entry PNG ICO decodes without `Options.entry`.
18. **CMYK storage. Decided by the owner:** inverted, as decision 15 landed
    it (the maximum is no ink).
19. **JPEG. Decided by the owner:** lossless JPEG marked YCbCr or YCCK is
    `Unsupported`, as libjpeg-turbo does not convert it.
20. **GIF. Decided by the owner:** an XMP extension shorter than its 258-byte
    end marker gives no blob.
21. **WebP. Decided by the owner:** at most 2600 prefix-code groups
    (libwebp's encoder maximum); the lossless work memory is stated as a worst
    case for now; lossless data past its chunk is `Truncated`, as in Wuffs;
    of several ALPH chunks the last wins; an animation's `frame_count` is
    null; a frame whose alpha size differs from its image matches libwebp
    given `Options.seeker` (`AlphaBehind` without one); the ANIM background
    is reported, never applied; a lossy partition before the last that runs
    past the container is `Truncated`, and the last reads to the input's
    end, as in libwebp.
22. **QOI. Decided by the owner:** keep the one-loop decoder; rotating icons
    are the honest icon numbers, and a repeated 16–32 px file at 0.66–0.97×
    is accepted.
23. **TIFF. Decided by the owner:** integers wider than 16 bits scale to 16,
    signed samples are offset by half their range, floats decode to
    `rgba_f32`, float CMYK to `cmyk16`, and CMYK alpha is dropped. The
    compressed paths (about 0.5× libtiff at 1 MP and up) speed up in a
    follow-up after stage 2.

24. **JPEG XL lossy precision. Decided by the owner:** native stays 16-bit,
    but an `rgba_f32` destination is written straight from the decoder's f32
    planes, with no 16-bit step, which meets the conformance bounds.
    Landed (`wave4-jxl-f32`).
25. **JPEG XL `decodeFrameConfig`. Decided by the owner:** the gap is
    accepted: `Unsupported` for JPEG XL animations, stills answered from
    `Config`, until a caller needs more.
26. **JPEG XL oracle exclusions. Decided by the owner:** lossy frames are
    left out until the oracle takes a per-format tolerance (the harness orb's
    next item), and files with header-bundle extensions (a libjxl quirk).
27. **JPEG XL `TooComplex` bounds. Decided by the owner:** frames up to twice
    the canvas, 1 MiB of tables per entropy code, patch and spline budgets,
    and a header-derived work bound, as jxl.md documents.
28. **JPEG reconstruction. Decided by the owner:** a separate
    `image.jxl.JpegReconstructor` (`init(reader, options)`, `workLen()`,
    `run(writer, work)`) streams the original JPEG from the `jbrd` box and
    the quantized coefficients, with no pixels; `Config.metadata` flags a
    `jbrd` box.
29. **Shared types for JPEG XL. Decided by the owner:** add HDR metadata
    (`Metadata.transfer` gains PQ, HLG, BT.709, DCI, and gamma;
    `Metadata.primaries`; `Metadata.intensity_target`) and the `rgb_f32` and
    `gray_f32` pixel formats now. The extra-channel output API, f16, and
    non-coalesced blend modes wait for a caller.

30. **JPEG trellis. Decided by the owner:** none by default (see decision 3's
    measurement); an opt-in size mode may follow phase 1.
31. **JPEG optimized tables. Decided by the owner:** `EncodeOptions.optimize`
    defaults to false, as cjpeg and TurboJPEG do, so default output matches
    libjpeg-turbo byte for byte.
32. **compress's block scratch. Decided by the owner:** it lives in
    `Writer.Buffer`, not `Writer`, which `init` returns by value (in `Writer`
    it ran the arm-linux build out of memory).
33. **Plain gamma. Decided by the owner:** it stays in `Metadata.gamma`;
    `transfer` null with `gamma` set means that power law, so a PNG with
    sRGB and gAMA keeps both.

34. **jbrd syntax. Decided by the owner:** the jbrd box's field order and U32
    distributions come from libjxl 0.12's `JPEGData::VisitFields`, read as a
    table with no code copied, because 18181-2's jbrd clause is not public;
    jxl-jbrd.md states the provenance.
35. **JpegReconstructor seeking. Decided by the owner:** it needs
    `Options.seeker` (`error.NeedsSeeker` without one) and reads the box
    twice, since a valid box can declare far more payload than its length.
36. **jbrd corpus. Decided by the owner:** lossless JPEG XL transcodes of the
    fetched suites' JPEGs (860 KB) are committed under their suites'
    licenses, so CI exercises reconstruction.
37. **ICO entries in order. Decided by the owner:** a multi-size icon with a
    PNG entry must decode straight through without `Options.entry`: the
    BMP/ICO orb bounds PNG work memory by the canvas size and counts bytes
    through the PNG decoder, after the TIFF encoder. Landed
    (wave1-ico-png2): PNG entries among several decode in order on the
    bgra8 canvas through a reader limited to the entry's length, which
    counts the bytes; `Config.work_len` is `png.Decoder.maxWorkLen(canvas
width)` for every file with several entries.
38. **ICO 16-bit sources. Decided by the owner:** convert to 8 bits per
    channel before encoding a PNG entry (256 KiB more work memory, only for
    16-bit sources).
39. **ICO double encode. Decided by the owner:** keep measuring each PNG
    entry with a discarding writer before writing it.
40. **TIFF progressive JPEG. Decided by the owner:** progressive or
    non-interleaved JPEG-in-TIFF stays `error.Unsupported`.
41. **TIFF 12-bit JPEG. Decided by the owner:** 12-bit stays limited to gray,
    RGB, and YCbCr pages; the samples path stays `Unsupported`.
42. **WebP lossless effort. Decided by the owner:** `image.webp.encode`
    defaults to effort 5: 1.2% smaller than cwebp's lossless default
    (`-z 6`) at 1.1–2.9× libwebp's speed.
43. **GIF quantization. Decided by the owner:** defaults `.wu`, `refine = 0`,
    `.floyd_steinberg` with its error bounded at 16 a channel; `.none` is
    documented for smaller files and screen content.
44. **GIF animation frames. Decided by the owner:** `AnimationFrame` has no
    `blend`; a frame composites over the previous one, as PNG's `.over`, and
    a caller whose frame clears pixels disposes the previous frame to
    background. Documented, not detected.
45. **JPEG XL lossy comparison. Decided by the owner:** the harness gets a
    per-input tolerance hook (`toleranceFor(input) ?Oracle.Tolerance`); lossless answers
    stay exact, lossy frames get 3 (float evaluation in the sRGB curve's
    linear segment), and frames that draw splines get the conformance bound
    (peak 262, RMS ≤ 1e-4). No coarse erf to sit nearer libjxl. Done:
    `test/oracle/jxl.zig`'s `toleranceFor`; 433 of 19,974 inputs agree only
    within a tolerance at 20000, 1,585 of 99,050 at 100000.
46. **JPEG XL XYB with ICC. Decided by the owner:** the pixels are reported
    as they are (`transfer = .linear`, sRGB `primaries`); the ICC is still
    delivered and documented as the original's space (libjxl's original
    profile), not the pixels'.
47. **TIFF compression. Decided by the owner:** `tiff.encode` defaults to
    LZW with Predictor 2 (libtiff's own default is none).
48. **TIFF strips. Decided by the owner:** libtiff's 8 KiB, which keeps the
    byte match; larger strips may come later as an option.
49. **TIFF Deflate effort. Decided by the owner:** `.default` (compress level
    7, filtered), as PNG's decision 16.
50. **ICO 16-bit sources. Decided by the owner:** `png.EncodeOptions` gains an
    8-bit cap, converted row by row with no extra work memory, and ICO sets
    it for PNG entries (decision 38). The BMP/ICO orb makes the PNG encode
    change in `wave1-ico-png2`. Landed: `png.EncodeOptions.max_depth =
.@"8"` narrows the base format row by row with no extra work memory; ICO
    sets it for PNG entries.
51. **HDR metadata and color. Decided by the owner:** image reads and writes
    PNG's cICP, mDCV, and cLLi (PNG third edition) and flags a JPEG HDR gain
    map (Ultra HDR, ISO 21496-1) without decoding it, on `wave6-hdr-meta`.
    Color management (applying ICC, gamut and tone mapping) stays out of
    image, for a separate baskingspot/color library started after phase 1. Landed
    (`wave6-hdr-meta`): `Metadata.cicp` (H.273 code points as stored),
    `Metadata.mastering_display` (xy as `primaries`, luminances in nits),
    `Metadata.content_light_level` (MaxCLL and MaxFALL in nits), and
    `Metadata.gain_map`. PNG reads cICP, mDCV, and cLLI up to IDAT and
    writes them from `png.EncodeOptions`. cICP alone sets `transfer`,
    `gamma`, and `primaries` over iCCP, sRGB, gAMA, and cHRM, leaving them
    null for codes they cannot name; one with a nonzero matrix or a range
    flag past 1 is ignored; narrow range is reported, not rescaled; the ICC
    profile is still reported. The `png_hdr` oracle compares with libpng
    1.6.59. JPEG flags a gain map from MPF plus the hdrgm XMP namespace or
    ISO 21496-1's APP2, checked against libultrahdr by hand.
    png-decode-icons is unchanged (results/png-hdr-chunks-20261102.md).
52. **GIF dead zone. Decided by the owner:** Floyd–Steinberg passes on no
    error from a pixel within 1 a channel of its palette entry (1.3% fewer
    bytes, PSNR +0.36 dB, blurred PSNR −0.09 dB), refining decision 43.
53. **GIF index buffer. Decided by the owner:** not taken; exact frames over
    2.4 MP map their pixels again rather than spend a byte a pixel.
54. **WebP lossy defaults. Decided by the owner:** quality 75, effort
    `default`, `alpha_compression` on, as cwebp's defaults.
55. **WebP lossy alpha memory. Decided by the owner:** with
    `alpha_compression` on, `workLen` includes the lossless encoder's work
    memory whatever the source; a caller encoding opaque images sets it off
    to ask for 3.2 B/px. Documented.
56. **JPEG XL lossless effort. Decided by the owner:** `default` (between
    cjxl e6 and e7 in size, e7's speed above icons).
57. **JPEG XL lossy encoding. Decided by the owner:** phase 2 (decision 4).
58. **JPEG recompression into JPEG XL. Decided by the owner:** phase 2, with
    VarDCT encoding (decision 5).
59. **APNG default-image fcTL. Decided by the owner:** an fcTL smaller than
    the canvas is accepted and decoded as Wuffs, libpng, and libspng decode
    it. Landed (`wave6-hdr-meta2`): the references split; all
    three read the IDAT at the canvas size. libpng and libspng show the
    whole image, and so do we (frame 0 at the canvas's size with the fcTL's
    duration, disposal, and blend); Wuffs draws only the fcTL's region, an
    expected split. A region outside the canvas stays BadChunk.
60. **cICP and ICC. Decided by the owner:** the ICC profile is still
    reported beside cICP; cICP's precedence is documented.
61. **HDR chunks after PLTE. Decided by the owner:** read, as gAMA, cHRM,
    sRGB, and iCCP are.
62. **Draft HDR chunk names. Decided by the owner:** mDCv and cLLi are not
    read.
63. **Duplicate HDR chunks. Decided by the owner:** the first chunk decides,
    valid or not, as libpng. Landed: one of the
    wrong length doesn't count; png_hdr leaves out files whose first cICP
    has a range flag past 1, which libpng keeps and we drop.
64. **Gain-map oracle. Decided by the owner:** libultrahdr joins the flake
    and the jpeg oracle checks `Metadata.gain_map`. Landed: libultrahdr 1.4
    ignores the base image's MPF and XMP and parses the second image, so on
    mutations the two split as often as not; `jpeg_gain_map` compares whole
    files only (`mutates = false` in compare.zig): the corpus, and generated
    files whose base image declares a gain map exactly when the second image
    carries one.
65. **WebP lossy alpha effort. Decided by the owner:** the lossy encoder's
    alpha plane uses lossless effort 1 for `fast` and `default` and 8 for
    `best` (was 0, 1, 5).
66. **WebP lossless effort 1 on RGB. Decided by the owner:** keeps its hash
    chain; the cheap path for flat, few-color images is the fix for their
    speed.
67. **APNG undersized default image. Decided by the owner:** the whole image
    is frame 0, as libpng and libspng show it; Wuffs, which draws only the
    fcTL's region, is a documented split (decision 59).
68. **Gain-map oracle scope. Decided by the owner:** `jpeg_gain_map`
    compares whole files only, the corpus and generated declare/carry
    combinations, since libultrahdr can't check the base image's
    declaration on damaged files.
69. **Oracle `mutates` opt-in. Decided by the owner:** an oracle module may
    declare `mutates = false` in test/oracle/compare.zig when its reference
    can't judge mutated inputs.
70. **JPEG XL learning samples. Decided by the owner:** `default` keeps its
    sample count; 2^19 samples (−1.16% size for +28% time) is not taken.
71. **JPEG XL default leaves. Decided by the owner:** `default` grows its
    tree to 1024 leaves, not 2048 (−0.78% against stage 1 for +13% time,
    instead of −0.93% for +20%). Landed (`wave5-jxl-encode3`,
    results/jxl-encode3-20261102.md): corpus +0.15% bytes against 2048
    leaves (1.005× e7 in total), 1.09×/1.11× faster up to and above a
    megapixel (0.60/0.89/1.15× e7), peak RSS 130.2 → 126.7 MiB.
72. **WebP lossy trellis at `default`. Decided by the owner:** kept; icons
    run at 0.96× libwebp -m 4 for about 2% at equal PSNR on every size.
    Icon speed is the orb's next item.
73. **WebP lossy trellis at `best`. Decided by the owner:** kept in every
    mode choice, at 0.6× libwebp -m 6; trellis speed is the orb's next
    item.
74. **JPEG XL reconstruction budgets. Decided by the owner:** `jpegWorkLen`
    keeps its fixed budgets (4 MiB of tables, LF group, and pass scratch;
    1 MiB per entropy code), about 9 MB at 16×16; scaling them would make a
    small file with a large code `TooComplex` where libjxl decodes it.
75. **JPEG XL learning samples by size. Decided by the owner:** `default`
    learns from `clamp(pixels × 4 / 16, 2^18, 2^20)` samples, so only large
    images change (corpus −0.58% for +7.5% time; apple.com 1.043 → 1.019 of
    e7). This refines decision 70. Landed (stage 7): default peak RSS 126 →
    142 MiB, the trade the decision didn't state.
76. **`fill` stays private. Decided by the owner:** `src/fill.zig` is not
    exported; callers' own `@memset` is compiler_rt's problem. The drafted
    Zig issue (results/memset-20261103.md) is not filed for now.
77. **JPEG XL lossy tolerance. Decided by the owner:** decision 45's
    tolerance for frames drawn in floats rises from 3 to 4: a fuzzed
    out-of-gamut XYB animation put one sample 4 steps from libjxl (5.1e-5 in
    the sRGB curve's linear segment, the same float-evaluation class).
    Lossless frames stay exact; splines keep the conformance bound.

## Harness requests

Changes the format orbs asked for in files the orchestrating thread owns,
not yet made:

- compress exporting CRC-32, so `src/png/crc32.zig` can go (a
  baskingspot/compress change).
- `src/encode.zig`: take the source as a const pixel view.
- An `artifacts` key per job in baskingspot/gh-actions' ci.yml (a
  gh-actions change, release, and pin bump), so oracle-ci can move back into
  `.github/ci.yaml` from its own job in `.github/workflows/ci.yml`.
