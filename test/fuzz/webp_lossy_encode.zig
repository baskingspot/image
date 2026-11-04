//! The lossy WebP encoder's fuzz target (`image.webp.lossy`).
//!
//! `harness.checkEncoderWith` checks the encoder contract at the default
//! options on images up to 112 by 96 made from the input's bytes (sizes
//! that cross macroblocks and leave partial ones), with an `expect` hook
//! that bounds the loss: our decoder must read back the source with its
//! alpha exact and its color within `bound` of it. Then the input, read by
//! `source` (an image file our decoders read, or a size and pixel bytes),
//! is encoded at a quality, effort, and metadata the choice picks, and
//! must decode within the bound for that quality, with the metadata in its
//! chunks. The oracle (test/oracle/webp_lossy_encode.zig) checks that
//! libwebp decodes the same files to the same pixels.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const PixelBuffer = image.PixelBuffer;
const PixelFormat = image.PixelFormat;
const lossy = image.webp.lossy;

pub const name = "webp_lossy_encode";

pub const corpus = [_][]const u8{"corpus/vendor/pngsuite"};
pub const extensions = [_][]const u8{".png"};

/// The namespace `harness.checkEncoderWith` takes.
const F = struct {
    pub const EncodeOptions = lossy.EncodeOptions;
    pub const workLen = lossy.workLen;
    pub const encode = lossy.encode;
    pub const Decoder = image.webp.Decoder;
};

const max_width = 112;
const max_height = 96;
/// The largest source `source` makes, in pixels.
pub const max_source_pixels = 1 << 16;

var file_buf: [4 << 20]u8 = undefined;
var work_buf: [32 << 20]u8 = undefined;
var got_buf: [max_source_pixels * 4]u8 = undefined;
var src_buf: [max_source_pixels * 16]u8 = undefined;
var decode_work: [harness.limits.max_work]u8 = undefined;
var row_buf: [16384 * 4]u8 = undefined;
/// U and V averaged over 2x2 pixels, for `withinBound`.
var chroma_buf: [2][max_source_pixels]f64 = undefined;

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkEncoderWith(F, .{
        .max_width = max_width,
        .max_height = max_height,
        .expect = expectBound,
    }, input, choice);

    const src = source(input, &src_buf, &decode_work, choice) orelse return;
    const options = optionsFor(input, choice);
    const file = encodeTo(src, options, &file_buf) catch return error.EncodeFailed;
    var r: Io.Reader = .fixed(file);
    var sink: Blobs = .{};
    var d = image.webp.Decoder.init(&r, .{ .limits = harness.limits, .blob_sink = sink.sink() });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.width != src.width or config.height != src.height) return error.RoundTripDiffers;
    const want_format: PixelFormat = if (hasAlpha(src)) .rgba8 else .rgb8;
    if (config.native != want_format) return error.RoundTripDiffers;
    const got_len = src.width * src.height * want_format.bytesPerPixel();
    const got = PixelBuffer.init(got_buf[0..got_len], want_format, src.width, src.height) catch unreachable;
    _ = d.decodeFrame(got, decode_work[0..config.work_len]) catch return error.RoundTripDiffers;
    if (!withinBound(got, src, options.quality)) return error.RoundTripDiffers;
    // Each metadata blob in its chunk, once.
    for ([_]?[]const u8{ options.icc, options.exif, options.xmp }, 0..) |m, i| {
        const want = m orelse continue;
        if (want.len == 0) continue;
        const hash = std.hash.Wyhash.hash(0, want);
        if (sink.seen[i] != 1 or sink.len[i] != want.len or sink.hash[i] != hash) return error.RoundTripDiffers;
    }
}

/// The options the choice picks for `source`'s image: any quality and
/// effort, raw alpha one time in four, and metadata from the input's bytes
/// one time in four.
pub fn optionsFor(input: []const u8, choice: u64) lossy.EncodeOptions {
    var o: lossy.EncodeOptions = .{
        .quality = @intCast((choice >> 8) % 101),
        .effort = @fromBackingInt(@intCast((choice >> 16) % 3)),
        .alpha_compression = (choice >> 24) % 4 != 0,
    };
    if ((choice >> 20) % 4 == 0) {
        const n = input.len;
        o.icc = input[0 .. n / 3];
        if (n % 2 == 0) o.exif = input[n / 3 .. n / 2];
        if (n % 3 == 0) o.xmp = input[n / 2 ..];
    }
    return o;
}

fn encodeTo(src: PixelBuffer, options: lossy.EncodeOptions, out: []u8) ![]const u8 {
    const work_len = lossy.workLen(options, src.width, src.height) orelse return error.EncodeFailed;
    var w: Io.Writer = .fixed(out);
    try lossy.encode(&w, src, options, work_buf[0..work_len]);
    return w.buffered();
}

fn hasAlpha(src: PixelBuffer) bool {
    if (!src.format.hasAlpha()) return false;
    var px: [4]u8 = undefined;
    const conv: image.convert.Converter = .init(.rgba8, src.format);
    for (0..src.height) |y| {
        const row = src.row(@intCast(y));
        const bpp = src.format.bytesPerPixel();
        for (0..src.width) |x| {
            conv.run(&px, row[x * bpp ..], 1);
            if (px[3] != 255) return true;
        }
    }
    return false;
}

/// Whether `got`, decoded from the encoding of `src` at `quality`, is
/// within the loss lossy coding may cause: alpha exact, and the mean
/// squared error over R, G, and B of the pixels whose alpha is not 0 at most
/// 1.5 times that of a 4:2:0 reference (the source's chroma averaged over
/// 2x2 pixels, then upsampled as the decoder does, 9:3:3:1 from the four
/// nearest samples) plus the error quantization may add: a quarter of the
/// AC step squared in luma, scaled to RGB, and as much again in chroma. The
/// step is bounded from the base quantizer index (RFC 6386 section 14.1's
/// AC table rises by at most 2.25 per index from 4); segments move it by at
/// most 15.
pub fn withinBound(got: PixelBuffer, src: PixelBuffer, quality: u8) bool {
    const w: usize = src.width;
    const h: usize = src.height;
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    const bpp = got.format.bytesPerPixel();
    const conv: image.convert.Converter = .init(got.format, src.format);
    const px = row_buf[0 .. w * bpp];
    // The chroma averaged over 2x2 pixels.
    for (0..ch) |cy| {
        @memset(chroma_buf[0][cy * cw ..][0..cw], 0);
        @memset(chroma_buf[1][cy * cw ..][0..cw], 0);
        for ([_]usize{ 2 * cy, @min(2 * cy + 1, h - 1) }) |y| {
            conv.run(px, src.row(@intCast(y)), w);
            for (0..cw) |cx| for ([_]usize{ 2 * cx, @min(2 * cx + 1, w - 1) }) |x| {
                const c = yuv(px[x * bpp ..][0..3]);
                chroma_buf[0][cy * cw + cx] += c[1] / 4;
                chroma_buf[1][cy * cw + cx] += c[2] / 4;
            };
        }
    }
    var err: f64 = 0;
    var sub: f64 = 0;
    var counted: usize = 0;
    for (0..h) |y| {
        conv.run(px, src.row(@intCast(y)), w);
        const g_row = got.row(@intCast(y));
        // The nearest chroma row and the one beside it, toward this row.
        const cy = y / 2;
        const ny = if (y % 2 == 0) cy -| 1 else @min(cy + 1, ch - 1);
        for (0..w) |x| {
            const s = px[x * bpp ..][0..bpp];
            const g = g_row[x * bpp ..][0..bpp];
            if (bpp == 4 and s[3] != g[3]) return false;
            // Colors that show nothing may change.
            if (bpp == 4 and s[3] == 0) continue;
            counted += 3;
            const cx = x / 2;
            const nx = if (x % 2 == 0) cx -| 1 else @min(cx + 1, cw - 1);
            var uv: [2]f64 = undefined;
            for (&uv, &chroma_buf) |*c, *plane| {
                const near = 9 * plane[cy * cw + cx] + 3 * plane[cy * cw + nx];
                c.* = (near + 3 * plane[ny * cw + cx] + plane[ny * cw + nx]) / 16;
            }
            const ref = rgb(.{ yuv(s[0..3])[0], uv[0], uv[1] });
            for (0..3) |c| {
                const d = @as(f64, @floatFromInt(g[c])) - @as(f64, @floatFromInt(s[c]));
                const e = ref[c] - @as(f64, @floatFromInt(s[c]));
                err += d * d;
                sub += e * e;
            }
        }
    }
    if (counted == 0) return true;
    const n: f64 = @floatFromInt(counted);
    const qi: f64 = @floatFromInt(@min(127, @as(u32, lossy.quantizerIndex(quality)) + 15));
    const step = 4 + 2.25 * qi;
    const quant = step * step / 4 * (1.36 + 2.0);
    return err / n <= 1.5 * sub / n + quant + 4;
}

/// BT.601 limited-range YUV, unrounded.
fn yuv(p: *const [3]u8) [3]f64 {
    const r: f64 = @floatFromInt(p[0]);
    const g: f64 = @floatFromInt(p[1]);
    const b: f64 = @floatFromInt(p[2]);
    return .{
        16 + 0.256788 * r + 0.504129 * g + 0.097906 * b,
        128 - 0.148223 * r - 0.290993 * g + 0.439216 * b,
        128 + 0.439216 * r - 0.367788 * g - 0.071427 * b,
    };
}

fn rgb(c: [3]f64) [3]f64 {
    const y = 1.164384 * (c[0] - 16);
    const u = c[1] - 128;
    const v = c[2] - 128;
    return .{
        std.math.clamp(y + 1.596027 * v, 0, 255),
        std.math.clamp(y - 0.391762 * u - 0.812968 * v, 0, 255),
        std.math.clamp(y + 2.017232 * u, 0, 255),
    };
}

/// The harness's `expect`: the file decodes to the source within the
/// bound at the default quality, so `want` becomes what our decoder reads
/// from our encoding, which the harness's own encoding must match; outside
/// the bound, `want` stays the source, which the decoded file then differs
/// from.
fn expectBound(want: PixelBuffer, trip: harness.RoundTrip) void {
    if (trip.got.format != want.format) return;
    if (!withinBound(trip.got, trip.src, (lossy.EncodeOptions{}).quality)) return;
    @memcpy(want.pixels, trip.got.pixels);
}

/// The image `input` holds, in `buf`: an image file our decoders read, of
/// at most `max_source_pixels`, as RGBA8 when it has alpha and RGB8
/// otherwise; or else a size from the first two bytes (up to 256 by 256
/// within `max_source_pixels`), a pixel format from the choice, and the
/// rest of the bytes, repeated, as pixels. Null when there is none.
/// `work` is the decoders' work memory.
pub fn source(input: []const u8, buf: []u8, work: []u8, choice: u64) ?PixelBuffer {
    if (image.detect(input[0..@min(input.len, image.detect_prefix_len)])) |_| {
        var r: Io.Reader = .fixed(input);
        var d = image.Decoder.initDetect(&r, .{ .limits = .{ .max_pixels = max_source_pixels } }) catch return null;
        const config = d.decodeConfig() catch return null;
        if (config.width == 0 or config.height == 0) return null;
        const format: PixelFormat = if (config.native.hasAlpha()) .rgba8 else .rgb8;
        const len = PixelBuffer.len(format, config.width, config.height).?;
        if (len > buf.len or config.work_len > work.len) return null;
        const dst = PixelBuffer.init(buf[0..len], format, config.width, config.height) catch return null;
        _ = (d.decodeFrame(dst, work[0..config.work_len]) catch return null) orelse return null;
        return dst;
    }
    if (input.len < 4) return null;
    const width: u32 = 1 + @as(u32, input[0]);
    var height: u32 = 1 + @as(u32, input[1]);
    height = @min(height, max_source_pixels / width);
    const formats = std.enums.values(PixelFormat);
    const format = formats[choice % formats.len];
    const len = PixelBuffer.len(format, width, height).?;
    const body = input[2..];
    for (buf[0..len], 0..) |*b, i| b.* = body[i % body.len];
    if (format.sample() == .f32) {
        const floats: []align(1) f32 = @ptrCast(buf[0..len]);
        for (floats, 0..) |*f, i| f.* = @as(f32, @floatFromInt(body[i % body.len])) / 255;
    }
    return PixelBuffer.init(buf[0..len], format, width, height) catch null;
}

/// Records the blobs the decoder passes on: how many of each kind start,
/// and the length and hash of the last.
const Blobs = struct {
    seen: [3]u32 = @splat(0),
    len: [3]u64 = @splat(0),
    hash: [3]u64 = @splat(0),
    hasher: [3]std.hash.Wyhash = @splat(.init(0)),

    fn sink(b: *Blobs) image.BlobSink {
        return .{ .context = b, .write = write };
    }

    fn write(context: *anyopaque, blob: image.Blob, at: u64, bytes: []const u8) void {
        const b: *Blobs = @ptrCast(@alignCast(context));
        const i = @backingInt(blob.kind);
        if (at == 0) {
            b.seen[i] += 1;
            b.hasher[i] = .init(0);
        }
        b.hasher[i].update(bytes);
        if (blob.endsAt(at, bytes.len)) {
            b.len[i] = blob.len.?;
            b.hash[i] = b.hasher[i].final();
        }
    }
};

/// Smooth fields, edges, noise, and flat runs, with a size and a stretch of
/// alpha that is sometimes all opaque, sometimes not.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 4 + random.uintLessThan(usize, @min(buf.len - 4, 8192));
    random.bytes(buf[0..2]);
    var i: usize = 2;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 64));
        switch (random.uintLessThan(u8, 5)) {
            0 => @memset(buf[i..][0..n], random.int(u8)),
            1 => {
                const step = random.intRangeAtMost(i8, -4, 4);
                for (buf[i..][0..n], 0..) |*b, k| b.* = buf[i - 1] +% @as(u8, @bitCast(step)) *% @as(u8, @truncate(k));
            },
            2 => @memset(buf[i..][0..n], 255),
            3 => if (i >= 2 + n) @memcpy(buf[i..][0..n], buf[i - n ..][0..n]) else random.bytes(buf[i..][0..n]),
            else => random.bytes(buf[i..][0..n]),
        }
        i += n;
    }
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    "\x0f\x0f\x80\x80\x80\xff",
    "\x40\x21\x00\xff\x10\x20\x30\x40\x50\x60\x70",
    "\x11\x05\x01\x02\x03\x04\xfe\xfd\xfc\x00\x80",
    // Two-pixel stripes of saturated colors, at quality 98: the decoder's
    // chroma upsampling, not the encoder, loses most of them.
    "\x86\x00\x00\x00\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x20" ++
        "\x00\x00\x00\x20\x02\x03\x00\x00\x00\x0e\x14\x92\x67\x00\x00\x00\x04\x67\x41\x4d\x41\xff\x01\x86" ++
        "\xa0\x31\xe8\x96\x5f\x00\x00\x00\x03\x73\x42\x49\x54\x01\x01\x01\x7c\x2e\x77\x82\x00\x00\x00\x0c" ++
        "\x50\x4c\x54\x45\x00\xff\x00\xff\x00\x00\xff\xff\x00\x00\x00\xff\x65\x3f\x2b\xba\x00\x00\x00\x22" ++
        "\x49\x44\x41\x54\x78\x9c\x63\xf8\x1f\xba\x8a\x01\x84\x19\xf0\x30\xf0\xc9\xc1\x18\xab\xa0\x2c\x7c" ++
        "\x0c\xa8\xd2\xff\xf8\x18\x83\xcc\x3d\x00\xbd\x49\x7f\x81\xea\x89\x8e\x1b\xca\x88\x46\xfb\x32\xcf" ++
        "\x7a\x1d",
};

test "webp_lossy_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
