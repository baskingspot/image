# Changelog

All notable changes to image are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `image.PixelFormat`, twenty interleaved formats from `gray8` to `rgba_f32_premul`, and `image.PixelBuffer`, the caller's pixel memory with a stride.
- `image.convert`: conversion and swizzle between any two pixel formats, with SIMD for the common pairs; `convert.Converter` picks the kernel once for many rows.
- `image.Config`, `image.Frame`, `image.Limits`, `image.DecodeOptions`, `image.Metadata`, and `image.DecodeError`, shared by every decoder; `image.exif.orientation` reads EXIF orientation.
- `image.detect` names a file's `image.Format` from its first `image.detect_prefix_len` bytes, for every phase-1 format.
- `image.Decoder` decodes any supported format behind one interface; `Decoder.initDetect` picks the format from the input.
- `image.qoi.Decoder`, a streaming QOI decoder that writes any pixel format and needs no work memory.
- `image.bmp` and `image.ico`: BMP decode (every header, 1- to 32-bit, RLE, bitfields; embedded JPEG and PNG reported as `error.EmbeddedJpeg` and `error.EmbeddedPng`) and encode (24-bit, 32-bit with alpha, 8-bit indexed); ICO and CUR decode of every entry with hotspots, out-of-order entries through `DecodeOptions.seeker`, and encode of BMP entries.
- `image.tga`: `Decoder` reads every TGA image type (color-mapped, true-color, and gray, run-length encoded or not, any origin) and reports the TGA 2.0 footer and extension area through `Decoder.trailer`; `encode`, `workLen`, and `EncodeOptions` write uncompressed or run-length encoded files.
- `image.netpbm`: PBM, PGM, and PPM (plain and raw), PAM, and PFM; `netpbm.Decoder` streams any pixel format with no work memory and reads a raw file's concatenated images as frames, and `netpbm.encode` writes every kind (`netpbm.Kind`, with `EncodeOptions.maxval` and the PFM byte order).
- `image.ico.Decoder` decodes PNG entries picked with `Options.entry` through `image.png`.
- `image.png.Decoder`, a streaming PNG and APNG decoder: every color type and bit depth, Adam7, tRNS, APNG frames with their region, disposal, and blend, and gAMA, cHRM, sRGB, pHYs, bKGD, iCCP, and eXIf reported; CRCs of critical chunks and the Adler-32 are checked, image data must fill exactly the frame (except after the last row of an interlaced image one row tall, which is skipped, as in Wuffs), and it needs about 72 KiB plus two rows of work memory.
- `image.png.Decoder.Options.ignore_checksums` skips the critical chunks' CRCs and the Adler-32, as Wuffs's `IGNORE_CHECKSUM` quirk does; off by default.
- `image.jpeg.Decoder`, a streaming JPEG decoder whose pixels match libjpeg-turbo's defaults bit for bit: baseline, extended, and progressive Huffman-coded 8-bit images, restart intervals, every sampling factor, grayscale, YCbCr, RGB, CMYK, and YCCK (`Options.cmyk`), decoding at 1/2, 1/4, or 1/8 size (`Options.scale`), TIFF's JPEGTables (`Options.tables`, `Options.color`), and JFIF density, EXIF orientation, and ICC (reassembled from its APP2 segments), EXIF, and XMP reported; arithmetic coding, lossless, and 12-bit images return `error.Unsupported` for now.
- Decoders pull from a `std.Io.Reader` whose buffer holds at least `image.min_buffer_len` (64) bytes, and read it forward; a format whose offsets can point backward (ICO) moves back only through the `image.Seeker` the caller passes in `DecodeOptions.seeker`, which `image.Decoder` passes through, and fails without one.
- `image.gif.Decoder`, a streaming GIF87a and GIF89a decoder: interlacing, transparency, local and global color tables, animation frames with their region, disposal (restore to previous included), and blend, delays in flicks, and the NETSCAPE2.0 loop count; `Decoder.decodeFrameConfig` reports the next frame before it is drawn, and it needs about 68 KiB of work memory.
- `image.gif.Decoder` reports `Config.loop_count` as 1, not null, for a file without a loop extension, as browsers play it once.
- `image.EncodeError`, the errors every encoder shares; each format's encoder will be `encode(writer, pixels, options, work)` with `workLen` for its work memory.
- The package depends on `compress` at commit fd03d72 (after 0.2.0, for its faster inflate), which brings `fastmem`.
- `image.wbmp`: WBMP type 0, a streaming `wbmp.Decoder` that writes any pixel format, and `wbmp.encode`, which stores gray of at least 128 as white.
- `image.qoi.encode`, `qoi.workLen`, and `qoi.EncodeOptions`: a QOI encoder that writes the same bytes as the reference encoder (qoi.h) and needs no work memory.
