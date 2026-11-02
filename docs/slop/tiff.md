# TIFF

Notes and decisions for `src/tiff/`: what the decoder reads, how it walks a
file whose offsets point anywhere, what it does with pixels the shared
formats cannot hold, and where it follows libtiff rather than the letter of
the specification. Sources: TIFF 6.0, the BigTIFF proposal, Adobe's
Technical Notes 1 and 3 (Deflate, floating point predictor), and ITU-T
T.4 and T.6 for CCITT. libtiff 4.7.2 is the oracle and the speed bar.

## Scope

Stages 1 and 2 (branch `wave3-tiff`) decode:

- classic and BigTIFF, either byte order; strips and tiles; chunky and
  planar;
- compression 1 (none), 32773 (PackBits), 5 (LZW, new style and the old
  LSB-first style), 8 and 32946 (Deflate, through `compress.zlib`), 2
  (modified Huffman), 3 (T.4 Group 3, 1D and 2D), 4 (T.6 Group 4), and 7
  (JPEG, through `image.jpeg`; below);
- predictors 2 (8, 16, 32, and 64-bit samples) and 3 (float);
- 1 to 32-bit unsigned and signed integer samples and 16, 24, 32, and 64-bit
  float samples, with FillOrder 2;
- MinIsWhite, MinIsBlack, palette, RGB, CMYK (InkSet 1, four inks), and
  YCbCr (8-bit, chunky, subsampling 1, 2, or 4 by 1, 2, or 4 with vertical
  not above horizontal); any model but palette and YCbCr may have extra
  samples, the first of which is alpha when ExtraSamples says 1 or 2;
- every IFD of the main chain as a frame.

Out of scope, `error.Unsupported`: old-style JPEG (6), LogLuv, CIE L*a*b*, JBIG, WebP,
ZSTD, LZMA, CCITT uncompressed mode, planar YCbCr, more than 32-bit
integers, and palettes over 8 bits. SubIFDs and EXIF IFDs are not pages.

## Seeking and the IFD walk (decision 8)

The decoder reads forward and goes back only through `Options.seeker`, the
shared `image.Seeker` (`DecodeOptions.seeker` through `image.Decoder`);
without one, data behind the reader is `error.DataBehind`. TIFF writers
usually put the IFD after the pixels, so most files need the seeker; a file
whose IFDs and values come before their data (`tiffcp` output, our
generated corpus with the IFD first) decodes from any stream.

- `decodeConfig` reads the header and the first IFD. With a seeker it then
  walks the chain to report `frame_count`, a canvas as large as the largest
  page, the largest page's `work_len`, and a native format that holds every
  page (`samples.join`). A chain that loops ends before the first repeated
  IFD (Brent's cycle finding, bounded by `max_frames`); an IFD that cannot
  be read ends the walk there, and that page fails when it is decoded. A
  chain of more than `max_frames` pages leaves `frame_count` null, as the
  shared contract says; the pages past the limit are not planned, and the
  first of them is `error.TooManyFrames` when it is reached.
- Without a seeker, the config is the first page's and `frame_count` is
  null when there is a second page. A later page that is larger than the
  canvas, needs more work memory, or has pixels the native format cannot
  hold is `error.PageMismatch`; the caller who wants every page of such a
  file passes a seeker.
- Each frame is one page in the top-left corner of the canvas, its size in
  `Frame.width` and `Frame.height`, which `decodeFrameConfig` reports from
  the page's IFD before its pixels are read; the rest of the canvas is black, or
  transparent when the native format has alpha.
- Values outside the IFD (BitsPerSample arrays, the color map, offsets and
  counts, metadata) are read in file order. A strip or tile is decoded and
  then the reader skips to its end, `offset + count`, which must be inside
  the input. That makes the result independent of how the reader's buffer
  chunks the input (the fuzz harness checks this): what a decompressor read
  ahead depends on the chunking, the chunk's end does not.
- Planar data is stored plane after plane but decoded one strip or tile of
  every plane at a time, so it seeks between planes unless each plane is a
  single chunk that comes in order.

## Work memory

`decodeConfig` states `work_len` before any pixel is read; every term is
bounded by the page's fields and checked against `Limits.max_work`:

- the strip or tile offsets and byte counts when they are stored outside
  the IFD (8 or 16 bytes per chunk, so it grows with the strip count, not
  the pixel count);
- a 4 KiB staging buffer for compressed data;
- the decompressor: LZW 52 KiB (its table holds each string's last 8
  bytes, so a string is written out 8 bytes a step), Deflate `zlib.Reader.Buffer` (32 KiB
  window), CCITT 8 bytes per pixel of chunk width plus 3, PackBits none;
- one line of a strip or tile for chunky data, so it does not grow with
  the height; for planar data one whole strip or tile of every plane,
  since rows interleave across planes;
- a line for the float predictor's byte shuffle;
- for JPEG, JPEGTables, `image.jpeg`'s work for the strip or tile's frame
  (`jpeg.Decoder.workLen`, single scan), and for the pages whose streams do
  not decode straight to the caller's rows a whole strip or tile of samples
  (below).

A planar page stored as one strip per plane needs the whole image in work
memory; past `max_work` that is `error.WorkTooLarge`. That is the one
layout this streaming decoder cannot read within bounded memory, and it is
documented on `Decoder`. A tiled image under the limits always fits, as
does any chunky strip layout.

## Pixels: native formats and what the shared formats lack

The native format is the cheapest of the shared `PixelFormat`s that holds
the page:

| Page                  | Native                                        |
| --------------------- | --------------------------------------------- |
| gray 1–8 bits         | `gray8` (`gray_alpha8`, `_premul` with alpha) |
| gray 9–32 bits        | `gray16` (and alpha variants)                 |
| palette               | `rgb8` if every entry is v·257, else `rgb16`  |
| RGB 1–8 bits          | `rgb8`, `rgba8`, `rgba8_premul`               |
| RGB 9–32 bits         | `rgb16`, `rgba16`, `rgba16_premul`            |
| CMYK 1–8 bits         | `cmyk8`                                       |
| CMYK 9–32 bits, float | `cmyk16`                                      |
| YCbCr                 | `rgb8` (`rgb16` for 12-bit JPEG)              |
| float, but CMYK       | `rgba_f32` (`rgba_f32_premul`)                |

Decisions for what the shared formats cannot hold (asking the owner whether
to add formats instead; see the report):

- **Scaling.** Integer samples scale exactly to 8 or 16 bits:
  round(v · 255 / max) or round(v · 65535 / max), max = 2^bits − 1. 8 and
  16 bits are kept as they are; 17 to 32 bits lose their low bits.
- **Signed samples** (SampleFormat 2) are offset by half their range, so
  the most negative value is 0 and zero is mid-gray. libtiff's RGBA
  interface refuses them; tiff-raw checks this rule.
- **CMYK** (decision 15) keeps its inks in the shared `cmyk8` and `cmyk16`,
  which store them inverted, as Adobe's JPEGs do: each is the maximum
  minus TIFF's ink amount, scaled as above. Float inks become `cmyk16` as
  1 − v, rounded and clamped, NaN as 0, which is how `image.convert`
  quantizes floats. Extra samples, alpha too, are dropped: the formats
  have none, and conversion drops alpha rather than compositing. Color
  comes from `image.convert`, libjpeg-turbo's naive ink × black / max,
  rounded, at the format's depth; libtiff's RGBA interface truncates the
  same product, so the RGBA oracle leaves CMYK out; tiff-raw checks the
  inks natively. Pages of `cmyk8` and `cmyk16`, or of inks and color, have
  no common native format (`samples.join`): converting `cmyk8` widened to
  `cmyk16` gives other colors than converting it directly.
- **Float** stays float, unscaled and unclamped, in `rgba_f32`; gray fills
  R, G, and B. 16 and 24-bit floats widen exactly; NaNs become the quiet NaN
  of their sign; 64-bit narrows. Float MinIsWhite is unsupported.
- **YCbCr** is converted by the specification's equations in floating
  point with YCbCrCoefficients and ReferenceBlackWhite, rounded and clamped;
  libtiff's fixed-point tables differ by 1 in a few percent of samples, so
  the RGBA oracle leaves YCbCr out and tiff-raw compares it, with the
  same equations, on files that keep the default coefficients and
  reference black and white.
- Alpha is the first extra sample when ExtraSamples is 1 (associated, so a
  premultiplied format) or 2; other extra samples are dropped. MinIsWhite
  gray with associated alpha becomes alpha − sample.

## Following libtiff

The specification leaves malformed files open; where libtiff accepts or
refuses, the decoder does the same, found by the oracle and pinned by it:

- IFD fields. A wrong type or count on Photometric, FillOrder,
  Orientation, T4/T6Options, ResolutionUnit, Predictor, InkSet, or
  YCbCrSubSampling ignores the field, as do unknown types, a count of 0, or
  a count whose size overflows 64 bits on any field the layout does not
  rest on. Those it does rest on (width, height, BitsPerSample,
  Compression, offsets, counts, SamplesPerPixel, RowsPerStrip,
  PlanarConfig, tile sizes, SampleFormat) are `error.BadHeader` instead;
  ExtraSamples with no values is ignored. Single values take the integer
  types libtiff reads a SHORT or LONG from (BYTE, SHORT, LONG, LONG8 and
  their signed kinds, not UNDEFINED), but not negative values; BitsPerSample
  and SampleFormat too, and Compression may have one value per sample,
  which must agree. Fields libtiff reads as LONGs (width, height,
  RowsPerStrip, tile sizes, T4/T6Options) take the IFD types as well.
  YCbCrSubSampling takes any integer type held in the entry. Orientation outside 1–8 and ResolutionUnit outside 1–3
  are BadHeader. Either tile tag makes the page tiled; a missing tile width
  or length is the image width or RowsPerStrip, when RowsPerStrip came
  before the tile tag (as libtiff sets them), and BadHeader otherwise.
  RowsPerStrip 0 is BadHeader. The first of a repeated tag wins, valid or
  not. The sizes of the out-of-IFD values of BitsPerSample, SampleFormat,
  the sample range fields, the offsets and counts, ColorMap, and
  TransferFunction must add up within 64 bits, read or not.
- Strip and tile offsets or byte counts with fewer values than chunks are
  padded with zeros, as libtiff pads them up to a million chunks.
- Optional values that lie past the input's end are ignored. A next-IFD
  offset cut off by the end of the input ends the chain.
- A palette page without a valid color map (or without BitsPerSample) is
  gray or RGB when its samples are 8 bits or wider, and BadHeader below.
  The map takes any integer type; a negative or out-of-range entry, or a
  count other than 3 × 2^bits, leaves it ignored.
  The map is read as 16-bit, as the specification has it; libtiff's guess
  that a map with every entry below 256 is 8-bit is not followed.
- Missing Photometric: MinIsWhite for CCITT, RGB for three or more samples,
  MinIsBlack otherwise.
- Byte counts over 1 MiB and over ten times the chunk's decoded size plus
  4096 are cut to that.
- Tiles decode whole, rows below the image included, so damage there fails
  as it does in libtiff.
- LZW data must start with Clear. Whether it is old-style is decided by the
  page's first chunk and holds for the rest, as libtiff decides it once. Only the codes the rows need are read:
  what follows them (EOI or not) is not checked.
- A Deflate stream that ends together with the rows has its Adler-32
  checked; one with data after the rows, or cut off after them, is not.
- Group 3: bits before each row's EOL are skipped, fill or damage. When the
  data ends before a row's EOL is found, that row and the rest of the page
  are read without EOLs, the row from its chunk's start again with the
  rows before it and the reference row kept, as libtiff 4.7 does; this
  goes back through the seeker. Two EOLs in a row end the data.
- CCITT codes cut off by the end of the data are read with zeros added,
  and a code that starts past the end is `error.NotEnoughData`, as libtiff
  pads its bit buffer.
- In Group 4 and 2D Group 3 rows, b1 after a pass mode, while the row has
  no change yet, is the change after b2 on the row above even when it is
  at a0 itself (after an empty run there), as libtiff takes it; past the
  row's first change, b1 is the first change after a0, as T.4 defines it.

## JPEG (compression 7)

TIFF Technical Note 2: each strip or tile is a JPEG stream, abbreviated
when JPEGTables (347) holds the tables it shares, itself a tables-only
stream. `image.jpeg` decodes each stream (`Options.tables` primes it with
JPEGTables, read into work memory in file order with the offsets and
counts), so its pixels are libjpeg-turbo's, which is what libtiff hands
out. The stream's bytes come through the same limited `Source` as the other
codecs, at the strip's offset and byte count, never bit-reversed: libtiff
reads JPEG data in stored order whatever FillOrder says.

- Work memory comes from the IFD alone: `jpeg.Decoder.workLen` for a frame
  of the strip or tile's size, one component per sample (one per plane for
  planar data), the samples' precision, and luma sampled as
  YCbCrSubSampling says, with `multi_scan = false`. libtiff writes
  single-scan streams; a progressive or non-interleaved one would keep
  every coefficient of the strip, and is `error.Unsupported` (libtiff reads
  it with a warning).
- Gray (MinIsBlack), RGB, and chunky YCbCr with unsigned samples decode
  straight into the caller's rows, `Options.crop` writing the visible part
  of an edge tile; YCbCr is converted by libjpeg-turbo's equations
  (`Options.color = .ycc`), as libtiff's JPEGCOLORMODE_RGB has libjpeg do,
  so YCbCrCoefficients and ReferenceBlackWhite do not apply. Everything
  else (planar data, MinIsWhite, CMYK, palette, signed samples, extra
  samples) decodes as stored (`Options.color = .none`, `.cmyk = .raw`) into
  a strip or tile of samples in work memory, which then become pixels as
  uncompressed samples do. 12-bit samples are read only straight to pixels
  (`gray16`, `rgb16`): libtiff hands out the others packed in 12 bits, which
  tiff-raw expands with this package's rules, and the samples path would
  need its own 12-bit layout.
- As libtiff checks: a stream's components must be the samples per pixel
  (1 per plane), 1 to 4; its precision must be
  BitsPerSample (8 or 12); its first component's sampling must be
  YCbCrSubSampling for chunky YCbCr and 1 by 1 otherwise, the others 1
  by 1. A stream wider or taller than its strip or tile is `error.BadJpeg`,
  but for the last strip, whose stream may have the other strips' height;
  a smaller one leaves the rest of the chunk zero, as libtiff's buffer is.
  `image.jpeg`'s own errors are `error.BadJpeg`, or the shared error they
  are.
- JPEGTables of a type other than BYTE, ASCII, or UNDEFINED is ignored:
  libtiff reads it as bytes from any integer type whose values fit, which
  a stream starting with 0xff never does.
- Chunky YCbCr JPEG data without a YCbCrSubSampling that libtiff reads
  (missing, or of the wrong count) takes its sampling from the first strip
  or tile's frame header when that is 1, 2, or 4 each way with the chroma
  1 by 1, and keeps the default 2 by 2 otherwise, as libtiff's
  JPEGFixupTags does; work memory then covers any of those samplings. Any
  YCbCrSubSampling is accepted for JPEG data, which libjpeg checks against
  the streams (1 to 4, at most 10 blocks a unit).
- The checks read the frame through `jpeg.Decoder.frameParams()` after
  `decodeConfig`.
- Tables carry from stream to stream within a page, as libjpeg under
  libtiff keeps them: JPEGTables primes the first stream
  (`Options.tables`), and each later stream starts from the DQT and DHT
  tables the one before it left (`keptTables()`, `Options.prior`). libjpeg
  resets DAC and DRI at every SOI, so those do not carry, not even from
  JPEGTables. The streams are read in libtiff's RGBA interface's order:
  row by row of strips or tiles, and for planar data every plane of one
  before the next. tiff-raw reads planar streams plane by plane, so the
  oracle skips planar pages whose streams define different tables. A new
  page starts from its own JPEGTables, as libtiff sets up a new codec per
  directory.
- JPEGTables is read as libjpeg reads a tables-only stream (SOFn checked
  loosely and dropped, DNL, RSTn, and TEM skipped); SOF5 to 7, SOF13 to
  15, and JPG are `error.Unsupported`, as libjpeg fails them.
- Chunky gray with an extra sample is a two-component stream, which
  `image.jpeg` hands out unconverted, as libjpeg's JCS_UNKNOWN does; more
  than 4 components are `error.Unsupported` (libjpeg reads up to 10).
- Not followed: a libtiff that cannot find the first frame header by its
  own marker scan (a DAC segment before it, say) keeps 2 by 2 where this
  decoder takes the frame's sampling.

## Testing

- Unit tests beside the code: a `testFile` TIFF writer covers strips and
  tiles, every compression, predictors, planar, both byte orders, BigTIFF,
  pages, PageMismatch, DataBehind, and a looping chain; lzw.zig and fax.zig
  test their codecs, packbits.zig its own.
- Fuzz (`test/fuzz/tiff.zig`): the harness's decoder properties on the
  corpus, mutated, and on generated files of every layout, compression,
  and sample format, JPEG among them (flat streams with the standard
  Huffman tables, their quantization table inline or in JPEGTables), read
  forward and through the harness's own seeker pass.
- Oracle (`test/oracle/tiff.{c,zig}`): libtiff's RGBA interface and a raw
  op (libtiff decompression with this package's sample rules) on the first
  page; `comparable` lists what each leaves out and why. JPEG data goes
  through libjpeg-turbo under libtiff, which conceals corrupt data, so
  tiff.c first decodes every strip or tile strictly (warnings are errors,
  256 bytes at a time, as test/oracle/jpeg.c does) and rejects a page that
  fails, and skips one with a multi-scan stream.
- Corpus: libtiff's test images and `corpus/gen/tiff.sh`, 205 files that
  ImageMagick makes from PngSuite, one per kind of pixel, and `tiffcp`
  rewrites with each compression, predictor, layout, byte order, and
  BigTIFF, and with JPEG: YCbCr 2×2 in strips and tiles at 32×32 and
  37×29, RGB, planar RGB, gray, MinIsWhite gray, CMYK, RGB with alpha, and
  12-bit gray and YCbCr.
