+++
title = "image"
+++

Image decoders and encoders in Zig with no C: PNG, JPEG, GIF, WebP, TIFF, JPEG XL, and more.

Wuffs showed that image decoders can read hostile files safely without giving up speed. This package reads Wuffs's image formats in Zig, adds three that Wuffs does not read (TIFF, JPEG XL, and ICO), and has an encoder for every one. Nothing allocates. A decoder reads the header, says how much work memory it needs in `Config.work_len`, and writes pixels into your buffer in any of 24 pixel formats.

Each decoder is tested against its reference library on the same files, and fuzzed under one rule: a hostile file gets an error, never a crash, a hang, an out-of-bounds access, or unbounded memory. Each format is a namespace (`image.png`, `image.jpeg`, ...) with a `Decoder`, an `encode`, and a `workLen`, and the calls have the same shape in every one.

- [Decoding](#decoding): `decodeConfig` reads the header into a `Config`, and `decodeFrame` writes each frame into a `PixelBuffer` you own, with `Config.work_len` bytes of work memory and `Limits` checked first.
- [Detection](#detection): `image.detect` names a file's `Format` from its first 18 bytes, and `image.Decoder` decodes any format behind one interface.
- [Pixel formats](#pixel-formats): 24 `PixelFormat`s from `gray8` to `rgba_f32_premul`, buffers with a stride, and `image.convert` between every pair.
- [Encoding](#encoding): `encode(writer, pixels, options, work)` in every namespace, with `workLen` for the work memory, plus animations and multi-page files.
- [Metadata](#metadata): `Config.metadata` reports orientation, color, and density, and a `BlobSink` receives ICC, EXIF, and XMP bytes; nothing is applied to the pixels.
- [Format notes](#format-notes): what each format's decoder and encoder do where the specification leaves room, and the options that change it.
- [Performance](#performance): throughput and memory against Wuffs, libjpeg-turbo, libwebp, libtiff, libjxl, and the other reference libraries.
- [Limits](#limits): the formats, features, and conversions this package does not have.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/image/v0.1.0.tar.gz
```

Add the module in `build.zig`:

```zig
const image = b.dependency("image", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("image", image.module("image"));
```

image builds with Zig 0.17 only, 0.17.1 or later. It depends on [compress](https://baskingspot.dev/compress/) for zlib, DEFLATE, and Brotli, which brings fastmem, and on nothing else.

## Import it

```zig
const image = @import("image");
```

`image` does not collide with a std namespace. It does collide with the obvious local name: Zig rejects a local `image` that shadows the import, so name values after their role, such as `photo` or `icon`.

## Read the examples

[`docs/examples/`](https://github.com/baskingspot/image/tree/main/docs/examples) is the code this guide shows, compiled against the public module and run by `just test`.

## Decode a file

This decodes the first frame of any supported file to RGBA8:

```zig
pub fn decodeFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Rgba {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);

    // The seeker lets ICO and TIFF reach data behind the reader.
    var decoder: image.Decoder = try .initDetect(&reader.interface, .{ .seeker = .file(&reader) });
    const config = try decoder.decodeConfig();

    const len = image.PixelBuffer.len(.rgba8, config.width, config.height) orelse
        return error.ImageTooLarge;
    const pixels = try gpa.alloc(u8, len);
    errdefer gpa.free(pixels);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);

    const dst = try image.PixelBuffer.init(pixels, .rgba8, config.width, config.height);
    _ = try decoder.decodeFrame(dst, work) orelse return error.NoFrames;
    return .{ .pixels = pixels, .width = config.width, .height = config.height };
}
```

The allocator is yours. The decoder never sees it: it asks for sizes, and you hand it slices.

# Decoding

Every format's `Decoder` has the same calls, and `image.Decoder` has them too:

1. `init(reader, options)` makes a decoder and reads nothing.
2. `decodeConfig()` reads the header and returns a `Config`. Later calls return the same `Config`.
3. `decodeFrame(dst, work)` writes the next frame into `dst` and returns its `Frame`, or null when there are no more frames.

## Read the header

`Config` describes the image before any pixel is decoded:

| Field         | What it says                                                                  |
| ------------- | ----------------------------------------------------------------------------- |
| `width`       | the canvas width, which every `dst` must have                                 |
| `height`      | the canvas height                                                             |
| `native`      | the `PixelFormat` that holds the source without loss and is cheapest to write |
| `frame_count` | the number of frames, or null when the header does not say                    |
| `loop_count`  | how many times an animation plays (0 is forever), or null for a still image   |
| `work_len`    | the bytes of work memory `decodeFrame` needs                                  |
| `is_opaque`   | whether the header promises that every pixel is opaque                        |
| `background`  | the background color the file names, straight RGBA, or null                   |
| `metadata`    | what the decoder found before the first frame (see [Metadata](#metadata))     |

Ask for `config.native` when you want the source's samples unchanged, such as 16-bit PNG or float TIFF.

## Size the buffers

`decodeFrame` takes two buffers, and both are yours:

- `dst`, a `PixelBuffer` of the canvas size in any pixel format. `PixelBuffer.len(format, width, height)` gives the bytes for packed rows, or null if they overflow `usize`. A buffer of another size is `error.SizeMismatch` (JPEG's `Options.crop` is the exception), and one too short is `error.BufferTooSmall`.
- `work`, at least `config.work_len` bytes, kept for every frame of the image. A shorter one is `error.WorkTooSmall`.

Input streams through the decoder, so work memory holds what the format must keep, not the image. QOI, Netpbm, and WBMP need none. GIF needs about 68 KiB for any image. PNG needs the 64 KiB inflate window, 8 KiB of staging, and two rows. TIFF needs the page's strip or tile offsets and one row of a strip or tile for chunky data. JPEG XL needs the most: its `work_len` covers whole-frame planes, though large lossy and lossless frames decode a group row at a time and touch far less of it.

## Decode the frames

A still image has one frame. An animation or a multi-page file has one per call, written into its region of the canvas:

```zig
while (try decoder.decodeFrameConfig()) |next| {
    // Restoring to the previous canvas needs a copy made before the
    // frame is drawn.
    if (next.disposal == .previous) @memcpy(saved, canvas);
    const frame = (try decoder.decodeFrame(dst, work)).?;
    shown += 1; // Show `canvas` for `frame.duration` flicks here.
    switch (frame.disposal) {
        .none => {},
        .background => {
            const region = dst.sub(frame.x, frame.y, frame.width, frame.height);
            for (0..region.height) |y| @memset(region.row(@intCast(y)), 0);
        },
        .previous => @memcpy(canvas, saved),
    }
}
```

The canvas must hold the previous frame between calls. The decoder blends: a `Frame.blend` of `src_over` means the frame was composited onto what the canvas held. Disposal is yours: `Frame.disposal` says what to do with the region before the next call, and `decodeFrameConfig` returns the next frame's region and disposal before anything is drawn, so you can save what `previous` restores. The first frame of a GIF, APNG, or WebP animation clears the canvas outside its region to transparent black.

`Frame.duration` counts flicks, `image.flicks_per_second` (705,600,000) to the second, which divides every common frame rate exactly. JPEG XL coalesces its frames, as libjxl does by default: each frame comes back whole, with no disposal for you to apply.

## Set limits

`DecodeOptions.limits` caps the image before any work. A file over a limit fails in `decodeConfig`, before the decoder writes a pixel or asks for memory, so buffers sized from `Config` stay within what you allowed:

```zig
var reader: std.Io.Reader = .fixed(file);
var decoder: image.png.Decoder = .init(&reader, .{ .limits = .{ .max_pixels = 100 } });
try testing.expectError(error.ImageTooLarge, decoder.decodeConfig());
// Errors are sticky: every later call returns the same one.
try testing.expectError(error.ImageTooLarge, decoder.decodeConfig());
```

| Field        | Default                    | Error           |
| ------------ | -------------------------- | --------------- |
| `max_width`  | 16,777,215                 | `ImageTooLarge` |
| `max_height` | 16,777,215                 | `ImageTooLarge` |
| `max_pixels` | 2^28, per frame and canvas | `ImageTooLarge` |
| `max_frames` | 65,536                     | `TooManyFrames` |
| `max_work`   | 1 GiB                      | `WorkTooLarge`  |

`Limits.none` lifts them all. A format whose header does not count its frames checks `max_frames` as frames arrive.

## Stream the input

A decoder pulls from a `std.Io.Reader` whose buffer holds at least `image.min_buffer_len` (64) bytes, and reads it forward. It never seeks on its own. A file read through a 4 KiB buffer decodes the same as one held in memory with `std.Io.Reader.fixed`.

Some formats store offsets that can point behind the reader. Those decoders take an `image.Seeker` in `DecodeOptions.seeker` and use it only for data behind their position:

| Format                  | Without a seeker                                                                               |
| ----------------------- | ---------------------------------------------------------------------------------------------- |
| TIFF                    | data behind the reader is `error.DataBehind`, and most writers put the IFD after the pixels    |
| ICO and CUR             | an entry behind the reader is `error.EntryBehind`                                              |
| WebP                    | an animation frame whose alpha is another size than its ANMF chunk says is `error.AlphaBehind` |
| `jxl.JpegReconstructor` | `error.NeedsSeeker`                                                                            |

`Seeker.fixed(&reader)` serves a reader made by `std.Io.Reader.fixed` over the whole file, with no copy. `Seeker.file(&file_reader)` serves a `std.Io.File.Reader` whose byte 0 is the file's first byte. For any other source, fill in `context` and `seek` yourself.

## Handle errors

Every decoder returns `image.DecodeError` plus its format's own causes:

| Error            | Cause                                                       |
| ---------------- | ----------------------------------------------------------- |
| `ReadFailed`     | the reader failed; its own error is in the reader           |
| `Truncated`      | the input ended before the image did                        |
| `BadSignature`   | the input does not start with this format's signature       |
| `BadHeader`      | a header field has a value the format does not allow        |
| `Unsupported`    | a feature the format allows that this decoder does not read |
| `ImageTooLarge`  | over `max_width`, `max_height`, or `max_pixels`             |
| `TooManyFrames`  | over `max_frames`                                           |
| `WorkTooLarge`   | `work_len` would be over `max_work`                         |
| `WorkTooSmall`   | `work` is shorter than `work_len`                           |
| `BufferTooSmall` | `dst` is smaller than its dimensions and stride need        |
| `SizeMismatch`   | `dst` is not the canvas size                                |

Errors are sticky. After one, every call on that decoder returns it, so a loop that stops on the first error cannot read a half-parsed stream by mistake. A frame that failed partway may have written some of its pixels into `dst`.

# Detection

## Name a file's format

`image.detect(prefix)` returns the `image.Format` of a file from its first `image.detect_prefix_len` (18) bytes, or null. A shorter prefix is fine for a short file.

```zig
const prefix = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
try testing.expectEqual(image.Format.png, image.detect(prefix).?);
try testing.expectEqual(null, image.detect("plain text, not an image"));

// CUR files decode through the ICO namespace.
try testing.expectEqualStrings("ico", image.Format.cur.namespace());
try testing.expect(image.Decoder.supports(.jxl));
```

PNG, JPEG, GIF, WebP, TIFF, JPEG XL, and QOI match their signatures exactly. BMP, ICO, CUR, and Netpbm also need plausible header fields. TGA has no signature and WBMP a weak one, so they are tried last, on header fields alone, and can match a file that is neither. The decoder still rejects what it cannot parse.

## Decode any format

`image.Decoder` is a tagged union over the format decoders with the same calls. `initDetect(reader, options)` peeks at the first bytes, leaves them in the reader, and picks the format; `init(format, reader, options)` takes one you already know.

```zig
var reader: std.Io.Reader = .fixed(file);
var decoder: image.Decoder = try .initDetect(&reader, .{});
try testing.expectEqual(image.Format.qoi, decoder.format());

const config = try decoder.decodeConfig();
var pixel: [4]u8 = undefined;
const dst = try image.PixelBuffer.init(&pixel, .rgba8, config.width, config.height);
_ = (try decoder.decodeFrame(dst, &.{})).?;
```

Input that matches no format is `error.UnknownFormat`. `DecodeOptions` reaches the format's decoder field by field; options only one format has, such as `png.Decoder.Options.ignore_checksums`, need that format's `Decoder`. `Decoder.decodeFrameConfig` forwards to the format's own where it has one (GIF, ICO, Netpbm, PNG, TIFF, WebP) and answers for a format whose header says it has one frame; otherwise, as for a JPEG XL animation, it is `error.Unsupported`.

# Pixel formats

## Pick a pixel format

Every `PixelFormat` is interleaved. Samples wider than a byte are in the machine's byte order, so an aligned 16-bit buffer can be viewed as `[]u16` and a float one as `[]f32`.

| Family               | Formats                                                                |
| -------------------- | ---------------------------------------------------------------------- |
| 8-bit                | `gray8`, `gray_alpha8`, `rgb8`, `bgr8`, `rgba8`, `bgra8`               |
| 8-bit premultiplied  | `gray_alpha8_premul`, `rgba8_premul`, `bgra8_premul`                   |
| 16-bit               | `gray16`, `gray_alpha16`, `rgb16`, `bgr16`, `rgba16`, `bgra16`         |
| 16-bit premultiplied | `gray_alpha16_premul`, `rgba16_premul`, `bgra16_premul`                |
| 32-bit float         | `gray_f32`, `rgb_f32`, `rgba_f32`, `rgba_f32_premul`, nominally 0 to 1 |
| CMYK                 | `cmyk8`, `cmyk16`                                                      |

CMYK samples are inverted inks, as Adobe's JPEGs store them and libjpeg-turbo returns them: the maximum is no ink, so all-zero bytes are black here as in every other format. TIFF's and PDF's ink amounts are the maximum minus these. `PixelFormat` has `bytesPerPixel`, `channelCount`, `hasAlpha`, `isPremultiplied`, and `channels`, which says where each channel sits.

A decoder writes whatever format you ask for. Asking for `config.native` skips conversion. PFM and float TIFF are native `rgba_f32`, as is JPEG XL past 16 bits a sample, and JPEG XL writes float destinations from its own floats, without an integer step.

## Lay out a buffer

`PixelBuffer` is pixels, format, width, height, and `stride`, the bytes from one row's start to the next. `init` packs rows; `initStride` takes a wider stride, and `sub` is a region that shares the memory:

```zig
// A 4 by 2 RGBA8 canvas with 32 bytes between rows: room for 8 pixels,
// of which 4 are the image.
var memory: [64]u8 = @splat(0);
const canvas = try image.PixelBuffer.initStride(&memory, .rgba8, 4, 2, 32);
const right = canvas.sub(2, 0, 2, 2);

var red: [2 * 2 * 3]u8 = undefined;
for (0..4) |i| red[i * 3 ..][0..3].* = .{ 255, 0, 0 };
try image.convert.convertBuffer(right, try .init(&red, .rgb8, 2, 2));
```

Decoders write into a buffer and never keep it, and they check its fields before writing, since the fields are public.

## Convert pixels

`image.convert` converts between every pair of formats. `convert` does one run of pixels, `Converter` picks the kernel once for many rows, and `convertBuffer` converts a whole `PixelBuffer` into another of the same size:

```zig
// Two straight-alpha pixels: half-transparent red, opaque green.
const src = [_]u8{ 255, 0, 0, 128, 0, 255, 0, 255 };
var dst: [8]u8 = undefined;
image.convert.convert(&dst, .bgra8_premul, &src, .rgba8, 2);
try testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128, 0, 255, 0, 255 }, &dst);
```

```zig
// Pick the kernel once, then run it on each row.
const converter: image.convert.Converter = .init(.gray8, .rgb8);
const rows = [_][6]u8{ .{ 255, 255, 255, 0, 0, 0 }, .{ 255, 0, 0, 0, 0, 255 } };
var gray: [2][2]u8 = undefined;
for (rows, &gray) |row, *out| converter.run(out, &row, 2);
```

Swizzles, adding and dropping alpha, premultiplying, gray to color, and 8-bit, 16-bit, and float samples in the same layout have SIMD kernels; `Converter.isFast` says whether a pair has one. Every other pair goes through 16-bit RGBA, or float RGBA when a side is float, with the same results the kernels give. The integer rounding is Wuffs's pixel swizzler's:

- Widening 8 bits to 16 multiplies by 257. Narrowing takes the high byte.
- Premultiplying is `c·a / 65535` and unpremultiplying `c·65535 / a` on 16-bit samples, both truncated. An 8-bit source keeps 8 bits.
- Gray from color is Rec. 601 luma, `(19595 R + 38470 G + 7471 B + 32768) >> 16`.
- Dropping alpha drops it. Wuffs composites onto black there instead, the one place the results differ.
- Color from CMYK is libjpeg-turbo's naive conversion, `ink · black / max`, rounded.

`Converter.run` may convert in place when both formats have the same pixel size.

# Encoding

## Encode an image

Every namespace has the same three declarations: `EncodeOptions`, with every field defaulted; `workLen(options, width, height)`, the work memory, or null when the image is too large for the format; and `encode(writer, src, options, work)`, which writes the whole file:

```zig
const options: image.png.EncodeOptions = .{ .effort = .best };
const work = try gpa.alloc(u8, image.png.workLen(options, 64, 32) orelse return error.ImageTooLarge);
defer gpa.free(work);
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try image.png.encode(&out.writer, src, options, work);
```

`src` is a `PixelBuffer` in any format, converted with `image.convert` to what the file stores. The shape holds across all twelve namespaces:

```zig
inline for (formats) |format| {
    const work = try gpa.alloc(u8, format.workLen(.{}, 32, 16).?);
    defer gpa.free(work);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try format.encode(&out.writer, src, .{}, work);
}
```

Every encoder returns `image.EncodeError` plus its own causes: `WriteFailed`, `WorkTooSmall`, `ImageTooLarge` (past what the format can store), and `BufferTooSmall`.

## Pick the options

| Namespace     | Options and their defaults                                                                                                                                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `png`         | `effort` (`.default`); `filter` (chosen per row); `reduce` to the smallest color type and depth (on); `max_depth`; `gamma`, `primaries`, `srgb`, `icc`, `cicp`, `mastering_display`, `content_light_level`, `exif`, `density` |
| `jpeg`        | `quality` (75); `subsampling` (`.@"4:2:0"`); `progressive` (off); `optimize` Huffman tables (off); `exif`, `icc`                                                                                                              |
| `gif`         | `quantizer` (`.wu`), `refine` k-means passes (0), `dither` (`.floyd_steinberg`), `interlace` (off), `loop_count` (0, forever), `crop` frames to what changes (on)                                                             |
| `webp`        | lossless: `effort` 0 to 9 (5), as cwebp's `-z`; `icc`, `exif`, `xmp`                                                                                                                                                          |
| `webp.lossy`  | `quality` 0 to 100 (75), on cwebp's scale; `effort` (`.default`); `alpha_compression` (on); `icc`, `exif`, `xmp`                                                                                                              |
| `tiff`        | `compression` (`.lzw`); `predictor` (on); `effort` for Deflate; `palette` when smaller (on); `density`; `rows_per_strip` (about 8 KiB strips)                                                                                 |
| `jxl`         | `effort` (`.default`)                                                                                                                                                                                                         |
| `bmp`         | `format`: `.auto`, `.bgr24`, `.bgra32`, or `.indexed8`                                                                                                                                                                        |
| `ico`         | `cursor` (off), `hotspot`, `payload` (`.auto`: PNG at 256×256, BMP below)                                                                                                                                                     |
| `tga`         | `rle` (on)                                                                                                                                                                                                                    |
| `netpbm`      | `kind` (PGM, PPM, or PAM from the source), `maxval`, `pfm_endian`                                                                                                                                                             |
| `wbmp`, `qoi` | none, except QOI's `transfer` (`.srgb`)                                                                                                                                                                                       |

Three efforts (`.fast`, `.default`, `.best`) trade speed for size in PNG, TIFF's Deflate, lossy WebP, and JPEG XL.

## Encode animations and pages

| Call                                                           | Writes                                                                                                     |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `png.encodeAnimation(w, width, height, frames, options, work)` | an APNG from `png.AnimationFrame`s with region, duration, disposal, and blend; frame 0 is the whole canvas |
| `gif.encodeAnimation(...)`                                     | a GIF animation from `gif.AnimationFrame`s, with the NETSCAPE2.0 loop count                                |
| `tiff.encodePages(w, pages, options, work)`                    | one TIFF page per `PixelBuffer`                                                                            |
| `ico.encodeAll(w, images, options, work)`                      | an icon with one entry per `ico.Image`, such as its 16, 32, 48, and 256 pixel sizes                        |

Durations are flicks, as in `Frame`, and PNG stores the nearest fraction APNG can hold.

# Metadata

## Read color and orientation

Decoders report metadata in `Config.metadata` and never apply it. The pixels are the file's pixels.

| Field                                                          | From                                                                                                     |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `orientation`                                                  | EXIF or the format's own field, as an `image.Orientation` named by where the first row and column belong |
| `transfer`                                                     | a named curve: `.srgb`, `.linear`, `.bt709`, `.dci`, `.pq`, `.hlg`                                       |
| `gamma`                                                        | a plain power law, times 100,000 (45455 is 1/2.2)                                                        |
| `primaries`                                                    | CIE xy of red, green, blue, and white                                                                    |
| `cicp`                                                         | PNG's cICP code points, which take precedence over the ICC profile and the other color chunks            |
| `intensity_target`, `mastering_display`, `content_light_level` | HDR luminance, in nits                                                                                   |
| `density`                                                      | pixels per inch or per meter, or only the aspect ratio                                                   |
| `icc`, `exif`, `xmp`                                           | a `Blob`: where the bytes are in the input, their length, and `encoding` (`.raw`, `.zlib`, or `.brotli`) |
| `jpeg_reconstruction`                                          | the JPEG XL file can rebuild its original JPEG                                                           |
| `gain_map`                                                     | the JPEG carries an HDR gain map, which is not decoded                                                   |

To show a photo upright, rotate or flip by `orientation` yourself. `image.exif.orientation(bytes)` reads the tag from EXIF data you hold, and `Orientation.toExif` gives the 1 to 8 value.

## Collect ICC, EXIF, and XMP

The decoder does not buffer metadata. It passes each blob's bytes to `DecodeOptions.blob_sink` as it reads past them, in pieces, and the sink copies what it wants:

```zig
fn write(context: *anyopaque, blob: image.Blob, at: u64, bytes: []const u8) void {
    const c: *ExifCollector = @ptrCast(@alignCast(context));
    if (blob.kind != .exif or blob.encoding != .raw) return;
    if (at + bytes.len > c.bytes.len) return;
    @memcpy(c.bytes[@intCast(at)..][0..bytes.len], bytes);
    c.len = @max(c.len, @as(usize, @intCast(at)) + bytes.len);
}
```

`at` is the piece's offset in the blob, so `at == 0` starts a blob and `blob.endsAt(at, bytes.len)` is true on its last piece. A format that learns a blob's length only at its end, such as GIF, passes `blob.len` as null until then. A `Blob` in `Config.metadata` always has its length. `encoding` says when the bytes are compressed (PNG's iCCP is zlib, JPEG XL's `brob` boxes Brotli); [compress](https://baskingspot.dev/compress/) decodes both.

## Read what follows the frames

Some files put metadata after the pixels: a TGA's footer, a PNG eXIf after the image data, GIF and WebP chunks after the first frame, the boxes after a JPEG XL codestream. `image.Decoder.finalConfig()` returns the `Config` updated with them once `decodeFrame` has returned null, and null before that or after an error:

```zig
while (try decoder.decodeFrame(dst, work)) |_| {}
try testing.expectEqual(image.Orientation.right_top, decoder.finalConfig().?.metadata.orientation);
```

# Format notes

## PNG and APNG

- `png.Decoder` checks the CRC-32 of every critical chunk (`error.BadCrc`) and the image data's Adler-32 (`error.BadChecksum`), as Wuffs does. `Options.ignore_checksums` skips both, as Wuffs's IGNORE_CHECKSUM quirk does.
- The image data must decompress to exactly the rows the image needs. An unknown critical chunk is `error.Unsupported`. A palette index past the palette is opaque black.
- An APNG's frames are the animation's: a default image outside the animation is skipped, and the native format always has alpha.
- `png.encode` writes the smallest lossless color type and bit depth (palette, gray, 1 to 16 bits, tRNS) and picks each row's filter. `max_depth = .@"8"` stores 16-bit and float sources at 8 bits. It writes no interlacing, text chunks, or bKGD.

## JPEG

- `jpeg.Decoder` matches libjpeg-turbo's default output bit for bit: its islow IDCT, fancy upsampling, and YCbCr conversion.
- `Options.scale` (`.half`, `.quarter`, `.eighth`) decodes smaller in the DCT domain, as libjpeg-turbo's `scale_num / scale_denom` does. Lossless images ignore it.
- CMYK and YCCK images decode to RGB by default. `Options.cmyk = .raw` gives the inks as native `cmyk8` or `cmyk16`.
- Lossless images past 8 bits are native `gray16`, `rgb16`, or `cmyk16`; 12-bit DCT images are native 16-bit too.
- `Options.tables`, `Options.prior`, `Options.color`, `Options.crop`, and `Decoder.workLen` exist for JPEG inside TIFF, where tables and color come from the container.
- `jpeg.encode` writes the same bytes as libjpeg-turbo for the same settings, with libjpeg's quality scaling, JFIF, and EXIF and ICC when given (`error.MetadataTooLarge` past what the segments hold). Alpha is dropped. A baseline file with standard tables streams an MCU row at a time.

## GIF

- `gif.Decoder` follows Wuffs where Wuffs and giflib disagree: the canvas grows to hold the first frame, later frames are clipped to it, and a frame's LZW data must hold exactly its pixels (`error.NotEnoughData`, `error.TooMuchData`). `Options.ignore_too_much_data` drops the extra pixels instead, as Wuffs's quirk does.
- `frame_count` is null, since GIF does not count its frames. `loop_count` is 1 for a file without a loop extension, as browsers play it once.
- A frame's `.background` disposal means clearing its region to transparent black. The file's background color is in `Config.background` and is never applied.
- `gif.encode` stores an image of at most 256 colors exactly, with alpha below 128 counting as one transparent color. Past 256 colors it quantizes (`Quantizer.wu`, `.median_cut`, or `.octree`) and dithers (`Dither.floyd_steinberg` or `.none`). Work memory is about 2.4 MiB past 256 pixels.

## WebP

- `webp.Decoder` reads lossless and lossy images, alpha, and animations. Lossy pixels match libwebp's default output bit for bit, and animations composite as libwebp's animation decoder does, given a caller that disposes of each region to transparent black.
- `Options.max_prefix_groups` bounds a lossless image's work memory, about 10 KiB a group. The default, 2600, is the most libwebp's encoder writes; past it is `error.Unsupported`.
- `webp.encode` writes lossless images, with `effort` 0 to 9 as cwebp's `-z`. `webp.lossy.encode` writes lossy ones, with alpha in an ALPH chunk compressed by the lossless encoder, and spends no bits on colors under fully transparent pixels. `webp.encodeAlpha` writes an alpha plane alone.

## TIFF

- Most TIFF writers put the IFD after the pixels, so pass a seeker. With one, `decodeConfig` walks every IFD and reports the page count, a canvas as large as the largest page, and a native format that holds every page. Without one, the config is the first page's, and a later page that does not fit it is `error.PageMismatch`.
- Each page is a frame written to the canvas's top-left corner; the rest of the canvas is black, or transparent when the native format has alpha.
- Integers wider than 16 bits scale to 16, floats decode to `rgba_f32`, and CMYK pages decode to `cmyk8` or `cmyk16`.
- JPEG data decodes through `image.jpeg`. A progressive or non-interleaved JPEG stream inside TIFF is `error.Unsupported`.
- `tiff.encode` writes classic little-endian TIFF with the IFD first, so the file reads forward without a seeker. Uncompressed, PackBits, and LZW strips are byte for byte what libtiff writes.

## JPEG XL

- `jxl.Decoder` reads bare codestreams and containers: VarDCT and Modular, the restoration filters, patches, splines, noise, animation, and extra channels.
- Lossless images match libjxl's 16-bit output bit for bit. All 40 files of the JPEG XL conformance suite decode within their peak error bounds against libjxl's floats.
- A large lossy or lossless frame decodes a group row at a time straight into `dst`. A 50-megapixel lossy photo peaks at about 484 MiB of RSS against libjxl's 527.
- `Decoder.decodeJpeg` reads a recompressed JPEG's coefficients without decoding pixels, and `jxl.JpegReconstructor` rebuilds the original JPEG byte for byte from the `jbrd` box (`error.NoJbrd` without one). It needs a seeker.
- `jxl.encode` writes one lossless Modular frame in a bare codestream, at 8 bits for 8-bit sources and 16 otherwise. CMYK is stored as RGB. The files decode bit for bit in libjxl and jxl-oxide.

## BMP, ICO, and CUR

- A BMP that holds a JPEG or PNG in place of pixels is `error.EmbeddedJpeg` or `error.EmbeddedPng`, with the reader at the embedded file's first byte, so you can hand it to `image.jpeg` or `image.png`.
- `ico.Decoder` decodes every entry as a frame, BMP or PNG, in directory order. `Options.entry` decodes one entry alone, without seeking. A file with several entries needs about 76 KiB of work memory at 256 pixels wide, since any entry might be a PNG.
- `ico.encode` writes a 256×256 image as a PNG entry and smaller ones as BMP; `payload` picks one. `cursor` and `hotspot` make a CUR.

## TGA, Netpbm, WBMP, and QOI

- `tga.Decoder` reads every image type. The 2.0 footer follows the pixels, so `Decoder.trailer` and `image.Decoder.finalConfig` report its gamma, aspect ratio, and key color after the last frame. `tga.encode` writes top-left 8-bit gray, 24-bit, or 32-bit images, run-length encoded by default.
- `netpbm.Decoder` reads a raw file's concatenated images as frames, each the first one's size (`error.FrameMismatch` otherwise). Any other maxval scales to 8 or 16 bits, rounded to nearest. PFM is native `rgba_f32`, and its scale's magnitude is not applied. `netpbm.encode` writes every kind, plain or raw (`netpbm.Kind`).
- `wbmp.encode` stores gray of at least 128 as white.
- `qoi.encode` writes the same bytes as the reference encoder, qoi.h. Neither QOI, Netpbm, nor WBMP needs work memory either way.

# Performance

Each format's best library is the bar, on throughput and on peak memory. These numbers come from `just bench-compare` on one core of a 2.6 GHz Intel Xeon (Ice Lake) cloud host in November 2026: image in ReleaseFast for the native CPU, the C libraries at `-O3 -march=native`. A ratio is image's throughput over the reference's, so above 1 is faster. Ranges are the geometric means of three size classes: icons up to 64×64, images up to a megapixel, and larger ones up to a 50-megapixel mosaic.

| Format and operation | Against       | Result                                                                                                                           |
| -------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| PNG decode           | Wuffs         | 1.34–1.62×, at 240 MiB peak RSS over the rows against Wuffs's 384                                                                |
| PNG encode           | libpng        | 2.3–3.5× libpng's speed at `.default`, with files 1.3% smaller than libpng's and libspng's                                       |
| JPEG decode          | libjpeg-turbo | 3–5× on icons and 1.03–1.35× on photos past a megapixel, with the same pixels                                                    |
| JPEG encode          | libjpeg-turbo | 2.16× over every row, 1.18× on baseline 4:2:0 past a megapixel, with the same bytes                                              |
| GIF decode           | Wuffs         | 1.12× over 52 rows, with the lowest peak RSS of every library measured                                                           |
| WebP decode          | libwebp       | lossless 2.14×, 1.15×, 1.11×; lossy 1.77×, 1.14×, 1.04×; animation 1.50× and 1.23×                                               |
| WebP lossless encode | libwebp       | 1.96× over every row, and smaller in total at every effort                                                                       |
| WebP lossy encode    | libwebp       | `.default` 1.30–1.44× `cwebp -m 4`, 2.7% smaller at equal PSNR and 4.4% at equal SSIM                                            |
| TIFF decode          | libtiff       | icons 1.3–6.5×; past icons PackBits 1.6–1.75×, Group 4 1.2–1.5×, JPEG 1.1–1.3×, Deflate 1.06–1.16×, LZW 0.89–1.00×               |
| TIFF encode          | libtiff       | PackBits 1.5–2.8×, LZW 1.25–1.70×, Deflate below 0.8×, compress's DEFLATE against zlib                                           |
| JPEG XL decode       | libjxl        | lossy about 0.9× on a 1200×1200 photo, both on one thread; 1.3–1.4× on icons                                                     |
| JPEG XL rebuild      | libjxl        | `JpegReconstructor` 1.55× over every row                                                                                         |
| JPEG XL encode       | libjxl        | `.default` writes about `cjxl -e 7`'s sizes, 0.84× its speed on icons and faster above, at 131 MiB peak RSS against libjxl's 261 |
| BMP decode           | Wuffs         | 1.30× on icons, 0.97–0.99× above                                                                                                 |
| TGA decode           | Wuffs         | 1.68×, 1.14×, 1.00×; RLE 2.57× and 4.45×                                                                                         |
| QOI decode           | Wuffs         | 1.64–1.83×                                                                                                                       |
| QOI encode           | qoi.h         | 1.5×, with the same bytes                                                                                                        |
| Netpbm decode        | Wuffs         | no row slower                                                                                                                    |

The measured losses: JPEG XL decode trails libjxl past icons, TIFF's LZW decode and Deflate encode trail libtiff, BMP decode sits at Wuffs's speed past icons, and GIF encode ran at 0.73× giflib's speed over all rows when first measured, where on the truecolor rows giflib times only its LZW writer against image's quantizer and ditherer. WebP lossless encode of flat, few-color images at efforts 1 to 6 runs at 0.39–0.66× libwebp. Every library here runs on one thread; libjxl can use more, and this package cannot.

[`bench/README.md`](https://github.com/baskingspot/image/blob/main/bench/README.md) describes the harness, the arms, and the method. `just bench-compare` reruns it on your machine; its numbers describe that machine on that day.

# Limits

- Formats: no AVIF or HEIC, which are an AV1 or HEVC decoder in a container. No SVG, PSD, OpenEXR, Radiance HDR, or GPU texture formats. `image.Format` has no tag for any of them.
- Color management: ICC profiles, primaries, and transfer functions are reported, and pixels are never converted with them. Orientation is reported and never applied.
- Resizing: only `jpeg.Decoder.Options.scale` decodes smaller. There is no general resampler.
- JPEG: hierarchical files and lossless arithmetic-coded files are `error.Unsupported`, as in libjpeg-turbo. The encoder writes no arithmetic coding, no 12-bit samples, and no CMYK. An HDR gain map is flagged in `Metadata.gain_map` and not decoded.
- JPEG XL: `jxl.encode` is lossless only, writes one frame, and writes a bare codestream with no container. There is no `jxl.Decoder.decodeFrameConfig`. Producing a `jbrd` box from a JPEG is not implemented.
- WebP: `webp.encode` and `webp.lossy.encode` write one image, not an animation.
- TIFF: `tiff.encode` writes classic little-endian strips, without BigTIFF, tiles, or JPEG compression. Progressive and non-interleaved JPEG streams inside TIFF are `error.Unsupported`.
- PNG: `png.encode` writes no interlacing, text chunks, or bKGD.
- Threads: every call runs on the calling thread.
