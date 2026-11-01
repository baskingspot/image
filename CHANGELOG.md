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
- `image.bmp` and `image.ico`: BMP decode (every header, 1- to 32-bit, RLE, bitfields; embedded JPEG and PNG reported as `error.EmbeddedJpeg` and `error.EmbeddedPng`) and encode (24-bit, 32-bit with alpha, 8-bit indexed); ICO and CUR decode of every entry with hotspots, out-of-order entries through `ico.Seeker`, and encode of BMP entries.
- `image.tga`: `Decoder` reads every TGA image type (color-mapped, true-color, and gray, run-length encoded or not, any origin) and reports the TGA 2.0 footer and extension area through `Decoder.trailer`; `encode`, `workLen`, and `EncodeOptions` write uncompressed or run-length encoded files.
- `image.netpbm`: PBM, PGM, and PPM (plain and raw), PAM, and PFM; `netpbm.Decoder` streams any pixel format with no work memory and reads a raw file's concatenated images as frames, and `netpbm.encode` writes every kind (`netpbm.Kind`, with `EncodeOptions.maxval` and the PFM byte order).
- Decoders pull from a `std.Io.Reader` whose buffer holds at least `image.min_buffer_len` (64) bytes, and never seek.
- `image.EncodeError`, the errors every encoder shares; each format's encoder will be `encode(writer, pixels, options, work)` with `workLen` for its work memory.
- The package depends on `compress` 0.2.0, which brings `fastmem`.
