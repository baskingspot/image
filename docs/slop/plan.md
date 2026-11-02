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
  gamma and chromaticities, physical size and DPI, animation timing and loop
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
  chromaticities, and density.
- `PixelFormat` has 20 formats: 8- and 16-bit gray, gray-alpha, RGB, BGR,
  RGBA, and BGRA, straight and premultiplied, and RGBA f32. `PixelBuffer` is
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

- **JPEG XL decode** (branch `wave4-jxl`): `src/jxl/`, the files
  adding-a-format.md assigns to jxl, and `docs/slop/jxl.md`. It may propose
  splitting off a second orb once its entropy decoder lands.

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
  with `@hasField(image.jpeg.Decoder.Options, "tables")`.
- **WebP decode** (branch `wave3-webp`): `src/webp/`. Stage 1 landed at
  `446a5da` (webp.md, results/webp-20261102.md): lossless (VP8L) from RFC
  9649, simple and extended, with ICCP, EXIF, and XMP to the blob sink and
  `Config.metadata`. `decodeConfig` states the work memory from the
  dimensions alone, with prefix tables for at most `Options.max_prefix_groups`
  groups (default 2600, libwebp's encoder maximum) at 10,024 bytes each;
  only the used groups are touched. 1.03× libwebp overall, 1.46× on icons,
  at about half its peak RSS. Stages 2 (VP8 and ALPH) and 3 (ANIM/ANMF)
  follow on the same branch.
- **TIFF decode** (branch `wave3-tiff`): `src/tiff/`, with TIFF's own LZW.
  Stage 1 landed at `e96a20e` (tiff.md, results/tiff-20261102.md): classic
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
  or below libtiff's in every class. Stage 2 is JPEG compression through
  `image.jpeg`'s `Options.tables` and `.color`.
- **PNG and APNG encode** (branch `wave5-png-encode`): `src/png/encode.zig`
  and the png_encode harness files; `src/png/` otherwise stays with the PNG
  orb until `wave1-png-strict` lands.
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
  file. Rotating icons are 1.31–1.60× the qoi crate. Next: whatever the full
  bench-compare shows below 1.

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
   size bar. Whether to add trellis quantization is measured after the
   baseline encoder works.
4. **JPEG XL lossy encoding.** VarDCT encoding is as large as the decoder.
   Decide after lossless encode lands whether it stays in phase 1.
5. **JPEG XL's JPEG reconstruction** (`jbrd`, the original JPEG's exact
   bytes). In scope for decode; decide whether we also produce `jbrd` boxes
   from a JPEG (lossless JPEG recompression).
6. **GIF quantization.** Which quantizer (median cut, octree, k-means) and
   dither, measured on quality and speed against gifski and ImageMagick.
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

## Harness requests

Changes the format orbs asked for in files the orchestrating thread owns,
not yet made:

- compress exporting CRC-32, so `src/png/crc32.zig` can go (a
  baskingspot/compress change).
- `src/encode.zig`: take the source as a const pixel view.
- `test/oracle/compare.zig`'s `ours()` takes each input's work memory from
  the batch arena, whose pages pile up across batches; WebP's worst-case
  bound got the oracle OOM-killed, and `test/oracle/webp.zig` works around
  it with a threadlocal buffer. Allocate work per input outside the arena,
  or one buffer per worker.
- A per-size-class peak RSS column in `just bench-compare`.
- `PF_CMYK8` and `PF_CMYK16` in test/oracle/oracle.h and oracle.c, so
  tiff-raw and JPEG's oracle answer CMYK natively.
- `harness.checkDecoder` passing a `Seeker.fixed` itself (TIFF's fuzz
  target does it privately). Avoid `threadlocal` in fuzz targets: in Zig
  0.16 Debug it broke png's zig-fuzz test.
- A generic `decodeFrameConfig` fuzz property in `test/fuzz/harness.zig`,
  replacing ICO's, PNG's, and Netpbm's copies.
- `just ci`'s oracle pass is about 270 s of 419 s (wbmp 64 s, jpeg 60 s,
  qoi 59 s); profile wbmp and qoi.
- `cmyk8` and `cmyk16` pixel formats with their `image.convert` kernels
  (decision 15), once the performance pass lands.
