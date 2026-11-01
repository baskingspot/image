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
buffer.

- One namespace per format (`image.png`, `image.jpeg`, ...) and a generic
  layer (`image.detect`, `image.Decoder` over any format) on top.
- Decoding is two calls. `decodeConfig` reads the header: dimensions, native
  pixel format, frame count when known, metadata locations, and the work
  memory the decode needs (`work_len`). Then `decodeFrame(dst, work)` writes
  one frame into the caller's pixel buffer, using the caller's work buffer.
  Animated and multi-page formats call `decodeFrame` again for each frame.
- Limits are options the caller sets before any work: maximum width, height,
  pixel count, frame count, and work memory. A file over a limit is an error,
  not an allocation.
- Input streams through `std.Io.Reader` and encoder output through
  `std.Io.Writer`, as `compress` does. A decoder never needs the whole file
  in memory, and never seeks unless the format requires it (TIFF and ICO do;
  they take a seekable source).
- Encoding mirrors it: `encode(writer, pixels, options, work)`, with
  `workLen(options)` saying how much work memory to pass.
- Errors are one error set per format with specific causes (bad checksum,
  truncated, unsupported feature, over a limit), plus the reader's and
  writer's errors.

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
- **Corpora**: PngSuite; the JPEG conformance files and libjpeg-turbo's test
  images; libwebp's test images; libtiff's test images; the JPEG XL
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
the owner of each file while a wave runs.

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

## Decisions to measure

1. **Streaming model.** `std.Io.Reader` pulls are the default, for
   consistency with `compress`. Measure their per-call cost on small images
   against a Wuffs-style resumable push decoder before the API settles in
   wave 0.
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
