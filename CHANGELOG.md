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
- The package depends on `compress` 0.2.0, which brings `fastmem`.
