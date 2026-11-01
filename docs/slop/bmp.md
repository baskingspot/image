# BMP

Notes and decisions for `src/bmp/`. `dib.zig` is the device-independent
bitmap reader that BMP files and ICO and CUR entries share; `Decoder.zig` is
the BMP file around it; `encode.zig` the encoder.

## Decode

- Every header size Wuffs reads (12, 16, 40, 52, 56, 64, 108, 124), 1, 2,
  4, 8, 16, 24, and 32 bits, RLE4 and RLE8, `BI_BITFIELDS` and
  `BI_ALPHABITFIELDS`, top-down and bottom-up. 64-bit pixels, OS/2 Huffman
  and RLE24 are `error.Unsupported`, as in Wuffs.
- Where the documents leave a case open, `dib.zig` decides it as Wuffs
  does, so the bar library is also a strict oracle: the oracle agrees with
  Wuffs on all 155 bmpsuite files and every fuzzed input. The rules are in
  `dib.zig`'s file comment; the ones that are easy to get wrong:
  - The color table is the bytes between the info header (and any masks
    after it) and `bfOffBits`, up to 256 entries; an index past it is
    opaque black.
  - 32-bit `BI_RGB` is opaque. Alpha comes from an alpha mask with
    `BI_BITFIELDS` in a header of 56 bytes or more, from
    `BI_ALPHABITFIELDS`, or from a fourth mask after a 40-byte header when
    `bfOffBits` leaves room for it.
  - Masks narrower than 8 bits widen by repeating their bits; wider ones
    keep their top 8 (native output is 8-bit only). 24-bit bitfields must
    be the standard masks.
  - RLE: skipped pixels are transparent black, so RLE images are BGRA. Runs
    and RLE4 literals are cut off at the row's end and dropped past the
    last row; an RLE8 literal past the row or after the last row, a delta
    past the right or top edge, and an end of line after the last row are
    errors. The stream must end with end-of-bitmap.
  - OS/2 2.x: the 16-byte header's height is unsigned, the 64-byte
    header's signed (negative is top-down).
  - A row missing its padding at the end of the file is `Truncated`.
- Native format: `bgr8`, or `bgra8` with an alpha mask or RLE. Indexed and
  RLE pixels go through a 256-entry lookup table already converted to the
  destination format; 24-bit and standard 32-bit rows go through
  `image.convert`'s kernels; other bitfields through per-channel tables.
- An embedded JPEG or PNG (`BI_JPEG`, `BI_PNG`) is `error.EmbeddedJpeg` or
  `error.EmbeddedPng` from `decodeConfig`, with the reader at the stream's
  first byte and `embeddedLen()` its length (the header's image size, which
  may be 0). Handing the stream to `image.png` or the JPEG decoder is the
  caller's step; the generic `image.Decoder` could do it once both land.
- Metadata: density, sRGB transfer for `LCS_sRGB` and `LCS_WINDOWS_COLOR_SPACE`,
  and an embedded ICC profile as a `Blob`; with a `blob_sink`, the profile's
  bytes are passed while skipping to the pixels, or read after them.
- No work memory.

## Encode

`EncodeOptions.format`:

- `auto` (default): 8-bit with a gray ramp for gray pixels without alpha,
  32-bit for pixels with alpha, 24-bit for the rest.
- `bgr24`: BITMAPINFOHEADER, alpha dropped.
- `bgra32`: straight alpha, `BI_BITFIELDS` in a BITMAPV4HEADER marked sRGB,
  which is how readers (Windows, Wuffs, stb_image, Magick) learn there is
  alpha.
- `indexed8`: a gray ramp for gray sources; otherwise an exact table of the
  image's colors in first-seen order, written short, through a 512-slot
  hash table on the stack, and `error.TooManyColors` past 256. No
  quantization: that is GIF's decision (plan.md decision 6) and can be
  shared later.

Rows are written bottom first, as every reader expects. No work memory.

## Measurements

docs/slop/results/bmp-20261101.md: decode 1.30× Wuffs on icons (1.45× to
BGRA), at parity from a megapixel up (0.97 to 1.02), and RLE 1.3 to 2.6×;
peak RSS is the caller's buffers. The rows that lose to Wuffs (down to 0.69)
are narrow 24-bit and 32-bit images, where `image.convert`'s per-call tail
cost is half of a short row; the fix belongs in src/convert.zig.
