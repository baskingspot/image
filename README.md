<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="image" height="48">
  </picture>
</h1>

Image decoders and encoders in Zig with no C: PNG, JPEG, GIF, WebP, TIFF, JPEG XL, and more.

Wuffs showed that image decoders can read hostile files safely without giving up speed. This package reads Wuffs's image formats in Zig, adds three that Wuffs does not read (TIFF, JPEG XL, and ICO), and has an encoder for every one. Nothing allocates. A decoder reads the header, says how much work memory it needs in `Config.work_len`, and writes pixels into your buffer in any of 24 pixel formats.

Each decoder is tested against its reference library on the same files. Lossless formats give identical pixels. JPEG matches libjpeg-turbo and lossy WebP matches libwebp bit for bit. The JPEG and QOI encoders write the same bytes as libjpeg-turbo and qoi.h.

```zig
var decoder: image.Decoder = try .initDetect(&reader, .{});
const config = try decoder.decodeConfig();
const len = image.PixelBuffer.len(.rgba8, config.width, config.height).?;
const pixels = try gpa.alloc(u8, len);
const work = try gpa.alloc(u8, config.work_len);
const dst = try image.PixelBuffer.init(pixels, .rgba8, config.width, config.height);
_ = try decoder.decodeFrame(dst, work) orelse return error.NoFrames;
```

No release is tagged, so `zig fetch` pins a commit, and the API can change between commits. [`CHANGELOG.md`](CHANGELOG.md) says what changed.

## What is in it

| Namespace | Format                  | Decode                                                                                                                                  | Encode                                                                  |
| --------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `png`     | PNG and APNG            | every color type and bit depth, Adam7, APNG frames                                                                                      | smallest lossless color type and depth, filter choice, APNG             |
| `jpeg`    | JPEG                    | baseline, 12-bit, progressive, arithmetic, lossless; CMYK and YCCK; 1/2, 1/4, and 1/8 size                                              | baseline and progressive, 4:4:4, 4:2:2, 4:2:0, optimized Huffman tables |
| `gif`     | GIF87a and GIF89a       | stills and animations, interlacing, transparency                                                                                        | stills and animations, quantized and dithered past 256 colors           |
| `webp`    | WebP                    | lossless, lossy with alpha, animations                                                                                                  | lossless (`encode`) and lossy (`lossy.encode`)                          |
| `tiff`    | TIFF and BigTIFF        | every page; strips and tiles; none, PackBits, LZW, Deflate, CCITT G3 and G4, JPEG; 1- to 32-bit integer and 16- to 64-bit float samples | every page; none, PackBits, LZW, or Deflate, with Predictor 2           |
| `jxl`     | JPEG XL                 | VarDCT and Modular, animations, extra channels, the container; the original JPEG rebuilt from `jbrd` (`JpegReconstructor`)              | lossless (Modular)                                                      |
| `bmp`     | BMP                     | 1- to 32-bit, RLE4 and RLE8, bitfields, V4 and V5 headers                                                                               | 24-bit, 32-bit with alpha, 8-bit indexed                                |
| `ico`     | ICO and CUR             | every entry, BMP and PNG data, hotspots                                                                                                 | BMP and PNG entries                                                     |
| `tga`     | TGA                     | every image type, RLE, color maps, the 2.0 footer                                                                                       | uncompressed and RLE                                                    |
| `netpbm`  | PBM, PGM, PPM, PAM, PFM | plain and raw, several images as frames                                                                                                 | every kind                                                              |
| `wbmp`    | WBMP                    | type 0                                                                                                                                  | type 0                                                                  |
| `qoi`     | QOI                     | the specification                                                                                                                       | the specification, byte for byte as qoi.h                               |

`image.detect` names any of these formats from its first 18 bytes, `image.Decoder` decodes any of them behind one interface, and `image.convert` converts between every pair of pixel formats. Metadata is reported and never applied: ICC, EXIF, and XMP bytes go to your `BlobSink`, and `Config.metadata` has the orientation, transfer function, primaries, and density.

Not implemented:

- AVIF and HEIC: `image.Format` has no tag for them.
- Color management: `Metadata.icc` is the profile's bytes, and pixels are never converted with it.
- Resizing: only JPEG decodes smaller, through `jpeg.Decoder.Options.scale`.
- Lossy JPEG XL encoding: `jxl.encode` writes lossless Modular images only.
- Animated WebP and JPEG XL encoding: `webp.encode`, `webp.lossy.encode`, and `jxl.encode` write one image.
- Hierarchical JPEG and lossless arithmetic-coded JPEG: `error.Unsupported`, as in libjpeg-turbo.
- Threads: every call runs on the calling thread.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/image
```

Add the module to your build:

```zig
const image = b.dependency("image", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("image", image.module("image"));
```

image builds with Zig 0.16 only.

## Documentation

- The [guide](https://baskingspot.dev/image/) says which piece to use for a task, with examples that compile.
- The [API reference](https://baskingspot.dev/image/api/) documents every symbol.
- [`docs/examples/`](docs/examples/) is the code the guide shows, compiled and run by `just test`.
- [`CHANGELOG.md`](CHANGELOG.md) records every change.
- [`bench/README.md`](bench/README.md) describes the benchmark harness and its arms.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain, the reference libraries, the comparison
arms, and the site tools. `just ci` runs what CI runs: the tests and the
guide's examples in Debug and ReleaseSafe and on a big-endian target, each
fuzz target over its seeds, the linters, the differential comparison against
the reference decoders, and the site build. `just fuzz`, `just oracle`, and
`just bench-compare` run the longer versions. `just corpus` fetches the
conformance suites (see [`corpus/README.md`](corpus/README.md) and
[`THIRD_PARTY.md`](THIRD_PARTY.md)). `just guide` serves the guide with live
reload, and `just doc` builds the site into `zig-out/site/image/`.

## License

MIT. See [`LICENSE`](LICENSE). `src/` has no third-party code;
[`THIRD_PARTY.md`](THIRD_PARTY.md) lists the test images and libraries the
tests and benchmarks use. The logo files in `docs/static/` are baskingspot
marks and are not covered by it. See
[`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
