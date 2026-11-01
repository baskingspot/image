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
  `.github/workflows/fuzz.yml` fuzzes daily and by hand (`just
fuzz-scheduled`), failing with the inputs as an artifact.

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

Running beside wave 1's tail, started early by the owner:

- **JPEG XL decode** (branch `wave4-jxl`): `src/jxl/`, the files
  adding-a-format.md assigns to jxl, and `docs/slop/jxl.md`. It may propose
  splitting off a second orb once its entropy decoder lands.

Wave 2, after wave 1's last branches land: JPEG decode, GIF decode, the
harness pass (the requests below, in the harness cores), and a performance
orb on the measured gaps: PNG decode against Wuffs first, then
`image.convert`'s per-call cost, TGA's 50 MP mosaic, Netpbm's small images,
and QOI against Rust's qoi crate.

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
  go to the blob sink. Inflate is compress's, pinned to commit fd03d72 for
  its fast path (0.38× Wuffs on compress 0.2.0, 0.79× with it); the owner
  chose a pinned commit over a compress release.
- **BMP, ICO and CUR, decode and encode** (landed; bmp.md and ico.md).
  `src/bmp/dib.zig` is shared by both. ICO reads entries forward in directory
  order; an entry behind the reader needs an `ico.Seeker` (`fixed` over a
  `Reader.fixed`, at no copy, or `file`) and is `error.EntryBehind` without
  one, and `Options.entry` decodes one entry without seeking (a PNG entry
  through `image.png`, read through IEND; an APNG entry stops after its first
  frame). It becomes the
  shared `image.Seeker` (decision 8). PNG entries
  decode only through `Options.entry` until png has a `workLen` bound, and
  PNG-entry encoding waits for wave 5.
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
- **WBMP, decode and encode, and QOI encode** (branch `wave1-wbmp-qoi`):
  `src/wbmp/`, the QOI encoder, and their harness files; it also owns
  `src/qoi/` for the decoder follow-ups wave 0 measured.
- **Seeker** (branch `wave1-seeker`, the BMP/ICO orb): moves `ico.Seeker`
  to `image.Seeker` in `src/decode.zig`, adds `DecodeOptions.seeker`, and
  passes it through `image.Decoder`; it owns `src/decode.zig`,
  `src/Decoder.zig`, and `src/ico/` for this.
- **PNG strictness** (branch `wave1-png-strict`, the PNG orb): decision 9 in
  `src/png/` and its harness files.
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

## Harness requests

Changes the format orbs asked for in files the orchestrating thread owns,
not yet made:

- `bench-compare` and `bench/c/arm.c`: let an arm skip a row it fails.
- `test/oracle/compare.zig`'s `loadCorpus` fails on files over 64 MiB; skip
  them, so the fuzz and oracle corpora can include `bench/corpus-gen`.
- `test/fuzz/harness.zig` `Result.eql`: in Zig 0.16 Debug, comparing
  `?anyerror` fields through pointers returns false for equal values (TGA
  skips its `zigFuzz` test in Debug until it is fixed).
- `test/fuzz/main.zig`: `zigFuzz` seeds are used raw, but Smith reads a
  length-prefixed input and a choice, so QOI's seeds are mangled.
- `just fuzz` splits its time across every target, so each gets less as
  formats land; the scheduled run may want a per-target budget instead.
- `image.convert`'s kernels cost about 25 ns per call in their tails, half a
  166-pixel row; narrow 24- and 32-bit BMPs run 0.69× Wuffs from it.
- A shared MagickWand helper in the oracle core (ico.c borrows bmp.c's).
- Let fuzz modules import compress (test/fuzz/png.zig has its own zlib
  writer), and have compress export CRC-32 so `src/png/crc32.zig` can go.
- A generic hook on `image.Decoder` for metadata that follows the frames
  (TGA's footer, PNG's chunks after IDAT).
