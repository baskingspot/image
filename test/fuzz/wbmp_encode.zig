//! The WBMP encoder's fuzz target. WBMP stores one bit per pixel, so the
//! encoder thresholds gray at 128 and `harness.checkEncoder`'s exact
//! round trip does not hold; `check` here keeps checkEncoder's properties
//! with that rule in place of exact equality: every pixel format encodes,
//! a writer that drains a few bytes at a time sees the same bytes, and our
//! decoder reads back the source converted to gray, thresholded to 0 or
//! 255.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const PixelFormat = image.PixelFormat;
const PixelBuffer = image.PixelBuffer;

pub const name = "wbmp_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

const max_side = 300;
var source: [max_side * 48 * 16]u8 = undefined;
var encoded: [2][max_side * 48]u8 = undefined;
var pixels: [2][max_side * 48]u8 = undefined;

/// The first two bytes of `input` pick the size, `choice` the source pixel
/// format, and the rest, repeated, is the pixels. Up to 300 pixels wide,
/// so rows cross the encoder's 64-pixel blocks and its spans.
pub fn check(input: []const u8, choice: u64) !void {
    if (input.len < 3) return;
    const width: u32 = 1 + @as(u32, input[0]) * max_side / 256;
    const height: u32 = 1 + input[1] % 48;
    const formats = std.enums.values(PixelFormat);
    const format = formats[choice % formats.len];
    const len = PixelBuffer.len(format, width, height).?;
    const body = input[2..];
    for (source[0..len], 0..) |*b, i| b.* = body[i % body.len];
    if (format.sample() == .f32) {
        const floats: []align(1) f32 = @ptrCast(source[0..len]);
        for (floats, 0..) |*f, i| f.* = @as(f32, @floatFromInt(body[i % body.len])) / 255;
    }
    const src = PixelBuffer.init(source[0..len], format, width, height) catch unreachable;

    const options: image.wbmp.EncodeOptions = .{};
    const work_len = image.wbmp.workLen(options, width, height) orelse return error.EncodeFailed;
    if (work_len != 0) return error.EncodeFailed;
    var w: Io.Writer = .fixed(&encoded[0]);
    image.wbmp.encode(&w, src, options, &.{}) catch return error.EncodeFailed;
    const file = w.buffered();

    var drip: Drip = undefined;
    drip.init(&encoded[1], 1 + choice / formats.len % 7);
    image.wbmp.encode(&drip.writer, src, options, &.{}) catch return error.EncodeFailed;
    drip.writer.flush() catch return error.EncodeFailed;
    if (!std.mem.eql(u8, file, encoded[1][0..drip.len])) return error.ChunkedWriterDiffers;

    var r: Io.Reader = .fixed(file);
    var d = image.wbmp.Decoder.init(&r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.width != width or config.height != height or config.native != .gray8) return error.RoundTripDiffers;
    const n = @as(usize, width) * height;
    const got = PixelBuffer.init(pixels[0][0..n], .gray8, width, height) catch unreachable;
    _ = d.decodeFrame(got, &.{}) catch return error.RoundTripDiffers;
    if (r.bufferedLen() != 0) return error.RoundTripDiffers;
    const want = PixelBuffer.init(pixels[1][0..n], .gray8, width, height) catch unreachable;
    image.convert.convertBuffer(want, src) catch unreachable;
    for (got.pixels, want.pixels) |g, v| {
        if (g != @as(u8, if (v >= 128) 255 else 0)) return error.RoundTripDiffers;
    }
}

/// harness.zig's Drip: a writer with a buffer of `image.min_buffer_len`
/// bytes that drains at most `step` bytes per call into `out`.
const Drip = struct {
    out: []u8,
    len: usize,
    step: usize,
    buffer: [image.min_buffer_len]u8,
    writer: Io.Writer,

    fn init(d: *Drip, out: []u8, step: usize) void {
        d.* = .{
            .out = out,
            .len = 0,
            .step = step,
            .buffer = undefined,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &d.buffer },
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const d: *Drip = @fieldParentPtr("writer", w);
        if (w.end > 0) {
            const n = @min(d.step, w.end);
            if (d.len + n > d.out.len) return error.WriteFailed;
            @memcpy(d.out[d.len..][0..n], w.buffer[0..n]);
            d.len += n;
            @memmove(w.buffer[0 .. w.end - n], w.buffer[n..w.end]);
            w.end -= n;
            return 0;
        }
        for (data, 0..) |bytes, i| {
            if (bytes.len == 0 or (i == data.len - 1 and splat == 0)) continue;
            const n = @min(d.step, bytes.len);
            if (d.len + n > d.out.len) return error.WriteFailed;
            @memcpy(d.out[d.len..][0..n], bytes[0..n]);
            d.len += n;
            return n;
        }
        return 0;
    }
};

/// Random sizes and pixels, mostly black and white with some gray.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 3 + random.uintLessThan(usize, @min(buf.len - 3, 4096));
    random.bytes(buf[0..2]);
    for (buf[2..len]) |*b| b.* = switch (random.uintLessThan(u8, 4)) {
        0 => 0,
        1 => 255,
        else => random.int(u8),
    };
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    "\x10\x02\x00\xff\x80\x7f",
    "\xff\x2f\x00\x00\x00\xff\xff\xff\x01\x02",
};

test "wbmp_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
