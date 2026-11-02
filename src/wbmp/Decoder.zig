//! A streaming WBMP decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, needs no work memory, and allocates nothing.
//!
//! Format: the Wireless Bitmap of the WAP Wireless Application Environment
//! specification (WAP-237, section 6 and appendix A), type 0, the only type
//! it defines: a multi-byte integer type field (0), a fixed header octet
//! (0: no extension headers), the width and height as multi-byte integers,
//! then the rows, one bit per pixel, most significant bit first, each row
//! padded to an octet. A set bit is white, a clear one black. A multi-byte
//! integer is big-endian groups of 7 bits, each octet but the last with its
//! top bit set. The decoder reads nothing after the last row.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

const Decoder = @This();

pub const Options = decode.Options;

pub const Error = decode.Error;

reader: *Io.Reader,
options: Options,
state: State = .start,
width: u32 = 0,
height: u32 = 0,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,

const State = enum { start, config, done };

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the header. The native format is `gray8`, every pixel 0 or 255.
/// Calling it again returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHeader() catch |e| return d.fail(e);
        d.state = .config;
    }
    return .{
        .width = d.width,
        .height = d.height,
        .native = .gray8,
        .frame_count = 1,
        .is_opaque = true,
    };
}

/// Decodes the image into `dst`, which must be the image's size, in any
/// format. Returns null once the image is decoded. `work` is unused: WBMP
/// needs no work memory.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    _ = work;
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    try dst.check();
    if (dst.width != d.width or dst.height != d.height) return error.SizeMismatch;
    d.pixels(dst) catch |e| return d.fail(e);
    d.state = .done;
    return .{ .width = d.width, .height = d.height, .is_opaque = true };
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

fn readHeader(d: *Decoder) Error!void {
    // Type 0 in one octet, as Wuffs reads it (not an overlong 0x80 0x00),
    // and no extension headers: anything else is not type 0.
    const head = d.reader.takeArray(2) catch |e| return mapRead(e);
    if (head[0] != 0 or head[1] != 0) return error.BadHeader;
    d.width = try readInt(d.reader);
    d.height = try readInt(d.reader);
    try d.options.limits.checkSize(d.width, d.height);
}

/// A width or height, read as Wuffs reads it: any number of octets, so
/// leading zero groups (`0x80`) are only slower, but a value of 2^24 or
/// more is `Unsupported`. The check comes before each shift, so `v` stays
/// under 2^24.
fn readInt(r: *Io.Reader) Error!u32 {
    var v: u32 = 0;
    while (true) {
        const b = r.takeByte() catch |e| return mapRead(e);
        v |= b & 0x7f;
        if (b & 0x80 == 0) return v;
        if (v >= 1 << 17) return error.Unsupported;
        v <<= 7;
    }
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

/// Each octet's eight pixels, most significant bit first.
const expand: [256][8]u8 = blk: {
    @setEvalBranchQuota(4000);
    var t: [256][8]u8 = undefined;
    for (&t, 0..) |*px, b| {
        for (px, 0..) |*p, i| p.* = if (b >> (7 - i) & 1 != 0) 255 else 0;
    }
    break :blk t;
};

/// Pixels per span when converting: a multiple of 8, so only a row's last
/// span ends inside an octet.
const span_len = 256;

fn pixels(d: *Decoder, dst: PixelBuffer) Error!void {
    const w: usize = d.width;
    if (dst.format == .gray8) {
        for (0..d.height) |y| try d.row(dst.row(@intCast(y)));
        return;
    }
    const conv: Converter = .init(dst.format, .gray8);
    const bpp = dst.format.bytesPerPixel();
    var buf: [span_len]u8 = undefined;
    for (0..d.height) |y| {
        const out = dst.row(@intCast(y));
        var x: usize = 0;
        while (x < w) : (x += span_len) {
            const n = @min(span_len, w - x);
            try d.row(buf[0..n]);
            conv.run(out[x * bpp ..], &buf, n);
        }
    }
}

/// Reads the octets of `out.len` pixels and writes them to `out` as gray.
fn row(d: *Decoder, out: []u8) Error!void {
    const r = d.reader;
    const full = out.len / 8;
    var i: usize = 0;
    while (i < full) {
        const in = r.peekGreedy(1) catch |e| return mapRead(e);
        const n = @min(in.len, full - i);
        for (in[0..n], 0..) |b, k| out[(i + k) * 8 ..][0..8].* = expand[b];
        r.toss(n);
        i += n;
    }
    const rest = out.len % 8;
    if (rest != 0) {
        const b = r.takeByte() catch |e| return mapRead(e);
        @memcpy(out[full * 8 ..], expand[b][0..rest]);
    }
}

fn testDecode(file: []const u8, format: PixelFormat, out: []u8) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    const frame = (try d.decodeFrame(dst, &.{})).?;
    try testing.expectEqual(config.width, frame.width);
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
    try testing.expectEqual(0, r.bufferedLen());
    return config;
}

test "rows are padded to an octet, most significant bit first" {
    // 10 by 2: two octets a row, the second's low 6 bits padding.
    const file = "\x00\x00\x0a\x02" ++ "\xa5\xff" ++ "\x0f\x40";
    var out: [20]u8 = undefined;
    const config = try testDecode(file, .gray8, &out);
    try testing.expectEqual(PixelFormat.gray8, config.native);
    try testing.expect(config.is_opaque);
    try testing.expectEqualSlices(u8, &.{
        255, 0, 255, 0, 0,   255, 0,   255, 255, 255,
        0,   0, 0,   0, 255, 255, 255, 255, 0,   255,
    }, &out);
    var rgba: [80]u8 = undefined;
    _ = try testDecode(file, .bgra8, &rgba);
    for (0..20) |i| try testing.expectEqualSlices(u8, &.{ out[i], out[i], out[i], 255 }, rgba[i * 4 ..][0..4]);
}

test "multi-byte integers" {
    // A width of 300 (0x82 0x2c), a height of 1, and an overlong 1.
    var file: [5 + 38]u8 = undefined;
    @memcpy(file[0..5], "\x00\x00\x82\x2c\x01");
    for (file[5..], 0..) |*b, i| b.* = @truncate(i *% 37);
    var out: [300]u8 = undefined;
    const config = try testDecode(&file, .gray8, &out);
    try testing.expectEqual(300, config.width);
    try testing.expectEqual(1, config.height);
    for (0..300) |x| {
        const b = file[5 + x / 8];
        try testing.expectEqual(@as(u8, if (b >> @intCast(7 - x % 8) & 1 != 0) 255 else 0), out[x]);
    }
    _ = try testDecode("\x00\x00\x80\x80\x01\x01\x80", .gray8, out[0..1]);
    // Any number of leading zero groups: a height of 12 in nine octets, as
    // Wuffs and ImageMagick read it.
    const tall = "\x00\x00\x01" ++ "\x80" ** 8 ++ "\x0c";
    try testing.expectEqual(12, (try testDecode(tall ++ "\xff" ** 12, .gray8, out[0..12])).height);
    // 2^24 - 1 is a size; 2^24 is not, even after zero groups.
    var none: Io.Reader = .fixed("\x00\x00\x80\x87\xff\xff\x7f\x00");
    var d: Decoder = .init(&none, .{ .limits = .none });
    try testing.expectEqual((1 << 24) - 1, (try d.decodeConfig()).width);
    none = .fixed("\x00\x00\x80\x88\x80\x80\x00\x00");
    d = .init(&none, .{ .limits = .none });
    try testing.expectError(error.Unsupported, d.decodeConfig());
    none = .fixed("\x00\x00\x01\x8f\xff\xff\xff\x7f");
    d = .init(&none, .{ .limits = .none });
    try testing.expectError(error.Unsupported, d.decodeConfig());
}

test "malformed streams" {
    var out: [64]u8 = undefined;
    const good = "\x00\x00\x03\x02\xe0\x40";
    _ = try testDecode(good, .gray8, &out);
    for (0..good.len) |n| try testing.expectError(error.Truncated, testDecode(good[0..n], .gray8, &out));
    // Another type, or extension headers.
    try testing.expectError(error.BadHeader, testDecode("\x01" ++ good[1..], .gray8, &out));
    try testing.expectError(error.BadHeader, testDecode("\x00\x80" ++ good[2..], .gray8, &out));
    // Type 0 spelled with an overlong octet.
    try testing.expectError(error.BadHeader, testDecode("\x80" ++ good, .gray8, &out));
    // An empty image is only its header.
    _ = try testDecode("\x00\x00\x00\x05", .gray8, &out);
    _ = try testDecode("\x00\x00\x05\x00", .gray8, &out);
    // Limits apply before any pixel.
    var r: Io.Reader = .fixed(good);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_pixels = 5 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
    try testing.expectError(error.ImageTooLarge, d.decodeFrame(try PixelBuffer.init(&out, .gray8, 3, 2), &.{}));
    r = .fixed(good);
    d = .init(&r, .{});
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .gray8, 2, 3), &.{}));
    const short: PixelBuffer = .{ .pixels = out[0..5], .format = .gray8, .width = 3, .height = 2, .stride = 3 };
    try testing.expectError(error.BufferTooSmall, d.decodeFrame(short, &.{}));
    // Stream errors are sticky.
    r = .fixed(good[0..5]);
    d = .init(&r, .{});
    try testing.expectError(error.Truncated, d.decodeFrame(try PixelBuffer.init(&out, .gray8, 3, 2), &.{}));
    try testing.expectError(error.Truncated, d.decodeConfig());
}

test "a row longer than the reader's buffer" {
    // 1000 pixels a row is 125 octets, through a 64-byte buffer.
    var whole: [5 + 250]u8 = undefined;
    @memcpy(whole[0..5], "\x00\x00\x87\x68\x02"); // 1000 = 7 * 128 + 104
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    prng.random().bytes(whole[5..]);
    var want: [2000]u8 = undefined;
    _ = try testDecode(&whole, .gray8, &want);
    var buffer: [decode.min_buffer_len]u8 = undefined;
    var big: Io.Reader = .fixed(&whole);
    var limited = big.limited(.unlimited, &buffer);
    var d: Decoder = .init(&limited.interface, .{});
    var got: [2000]u8 = undefined;
    _ = try d.decodeFrame(try PixelBuffer.init(&got, .gray8, 1000, 2), &.{});
    try testing.expectEqualSlices(u8, &want, &got);
}
