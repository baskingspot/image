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
  `image.min_buffer_len` (64) bytes; decoders never seek (decision 1).
- `Limits` (width, height, pixels, frames, work memory) are options checked
  before any work; `Limits.none` lifts them. `DecodeOptions` also carries a
  `BlobSink` that receives ICC, EXIF, and XMP bytes as the decoder passes
  them; `Metadata` reports orientation (`image.exif` parses it), transfer,
  chromaticities, and density.
- `PixelFormat` has 20 formats: 8- and 16-bit gray, gray-alpha, RGB, BGR,
  RGBA, and BGRA, straight and premultiplied, and RGBA f32. `PixelBuffer` is
  pixels, format, size, and stride. `image.convert` (`Converter`, `convert`,
  `convertBuffer`) converts between any two, with SIMD kernels for the
  common pairs and a general path through 16-bit or f32 RGBA; dropping alpha
  drops it (no compositing), gray is luma 19595/38470/7471, 16 to 8 bits
  rounds c / 257, and 8-bit premultiplication rounds exactly.
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
  `test/fuzz` harness is a model.

## Benchmarks

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

Wave 1, five orbs in parallel. Each owns the files adding-a-format.md assigns
to its formats, plus `docs/slop/<fmt>.md` for its notes and decisions, and
adds one line per format to each shared registry and a CHANGELOG bullet;
registry lines conflict trivially on rebase, and both sides stay. The
orchestrating thread owns everything else: the shared `src/` files
(`root.zig` beyond the registry lines, `pixel.zig`, `convert.zig`,
`decode.zig`, `encode.zig`, `detect.zig`, `Decoder.zig`, `exif.zig`), the
harness cores, `build.zig`, the justfile, the flake, CI, and this file. An
orb asks for a change to them, or for text in this file, in its report.

- **PNG and APNG decode** (branch `wave1-png`): `src/png/` and its harness
  files. Inflate improvements go to `baskingspot/compress`, on a branch there.
- **BMP, ICO and CUR, decode and encode** (branch `wave1-bmp`): `src/bmp/`,
  `src/ico/`, and their harness files. One owner, so ICO's BMP payloads share
  BMP's DIB reader. Also decides how ICO reads directory offsets that do not
  ascend, which TIFF will face in wave 3.
- **TGA, decode and encode** (branch `wave1-tga`): `src/tga/` and its harness
  files.
- **Netpbm, decode and encode** (branch `wave1-netpbm`): `src/netpbm/` and
  its harness files.
- **WBMP, decode and encode, and QOI encode** (branch `wave1-wbmp-qoi`):
  `src/wbmp/`, the QOI encoder, and their harness files; it also owns
  `src/qoi/` for the decoder follow-ups wave 0 measured.
- **Conversion rounding** (branch `wave1-convert`): `src/convert.zig` and the
  `convert` bench files, to match Wuffs's rounding (decided by the owner:
  match the references unless there is a strong reason not to).

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
   libjpeg-turbo's output bit for bit, so it is a strict oracle.
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
