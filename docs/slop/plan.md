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
quantizing and lossy encoders.

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
  `decodeFrameConfig` yet (it would need work memory). The oracle leaves out
  lossy frames until the comparison takes a tolerance, and files with
  header-bundle extensions (a libjxl quirk). Next: render by group row, then
  speed, then JPEG reconstruction (stage 4).

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
  with libjpeg-turbo first, since libtiff conceals corrupt data. Next
  (decision 23): the compressed-path speedup.
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
  peak RSS at or below giflib's past icons. Follow-ups: one pass on the
  exact path, selective dithering, quantizer setup on icons.
- **JPEG encode** (landed; results/jpeg-encode-20261102.md): baseline and
  progressive, 4:4:4/4:2:2/4:2:0, optimized tables, byte-identical to
  libjpeg-turbo; 1.87× its speed over all rows, 0.93× on baseline 4:2:0 over
  1 MP; peak RSS at or below it. The performance pass
  (results/jpeg-encode-perf-20261102.md) puts every class at or above
  libjpeg-turbo, with the same bytes: baseline over 1 MP 1.18× (4:2:0) and
  1.26× (4:4:4), 2.16× over all rows. No zmm in the encoder; the source is
  prefetched 4 rows ahead.
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
- **TIFF encode** (branch `wave5-tiff-encode`, the BMP/ICO orb):
  `src/tiff/encode.zig` and any new `src/tiff/encode_*.zig` files, the
  tiff_encode fuzz and oracle files, and the tiff-encode bench rows. It adds
  only its export lines to `src/tiff/root.zig`; the rest of `src/tiff/`
  stays with the TIFF orb (the compressed-path speedup).
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
  bench rows; only its export lines in `src/webp/root.zig`. It writes ALPH
  raw until the lossless encoder (`wave5-webp-encode`) lands, then
  compresses it with that encoder.
- **Shared types for JPEG XL** (landed; results/convert-f32-20261102.md):
  decision 29's metadata fields (`Transfer` bt709, dci, pq, and hlg;
  `Metadata.primaries` replacing `chromaticities`; `intensity_target`;
  `jpeg_reconstruction`), `rgb_f32` and `gray_f32`, and SIMD between float
  and 8- or 16-bit samples in the same layout (5–16× the general path).
  PNG encode takes `primaries`. The JPEG XL orb still maps its colour
  encoding into the new fields.
- **JPEG reconstruction** (branch `wave4-jxl-jbrd`, the Netpbm orb):
  `src/jxl/jbrd.zig`, `src/jxl/JpegReconstructor.zig`, and their fuzz and
  oracle files, on the coefficient callback the JPEG XL orb adds to
  vardct.zig (`wave4-jxl-coeffs`). The rest of `src/jxl/` stays with the
  JPEG XL orb (render by group row, then speed).
  The jbrd box and the JPEG writer landed (byte-identical on 67 cjxl
  transcodes given libjpeg-turbo's coefficients); `JpegReconstructor` needs
  a seeker; the coefficients, oracle, and bench wait on the vardct
  coefficient pass.
- **JPEG XL lossless encode** (branch `wave5-jxl-encode`, the TGA orb):
  `src/jxl/encode.zig` and new `src/jxl/encode_*.zig` files, the jxl_encode
  fuzz and oracle files, and the jxl-encode bench rows; only its export
  lines in `src/jxl/root.zig`.
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
4. **JPEG XL lossy encoding.** VarDCT encoding is as large as the decoder.
   Decide after lossless encode lands whether it stays in phase 1.
5. **JPEG XL's JPEG reconstruction** (`jbrd`, the original JPEG's exact
   bytes). In scope for decode; decide whether we also produce `jbrd` boxes
   from a JPEG (lossless JPEG recompression).
6. **GIF quantization.** Which quantizer (median cut, octree, k-means) and
   dither, measured on quality and speed against gifski and ImageMagick.
   Measured (results/gif-encode-20261102.md, 16 images): Wu beats median
   cut by 0.6 dB and octree by 3.3 dB at the same speed; `refine` adds at
   most 0.17 dB; bounded Floyd–Steinberg has the best blurred PSNR of every
   encoder measured (51.17 dB; ImageMagick's Floyd–Steinberg 50.93, gifski
   q100 46.92) at 2.1 dB less PSNR than no dither and 20% more bytes.
   Recommended defaults `.wu`, `refine = 0`, `.floyd_steinberg`; the owner
   decides.
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
    through the PNG decoder, after the TIFF encoder.
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

## Harness requests

Changes the format orbs asked for in files the orchestrating thread owns,
not yet made:

- compress exporting CRC-32, so `src/png/crc32.zig` can go (a
  baskingspot/compress change).
- `src/encode.zig`: take the source as a const pixel view.
- An `artifacts` key per job in baskingspot/gh-actions' ci.yml (a
  gh-actions change, release, and pin bump), so oracle-ci can move back into
  `.github/ci.yaml` from its own job in `.github/workflows/ci.yml`.
