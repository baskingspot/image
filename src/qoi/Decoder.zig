//! A streaming QOI decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, needs no work memory, and allocates nothing.
//!
//! Format: the QOI specification, version 1.0 (qoiformat.org). Every
//! decoded pixel goes into the index, runs and index chunks included, as
//! the specification says. The decoder is strict where the specification
//! is silent: the stream must end with its 8-byte end marker, and a run may
//! not go past the last pixel.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

const Decoder = @This();

pub const Options = decode.Options;

pub const Error = decode.Error || error{
    /// The stream does not end with the end marker, seven zeros and a one.
    BadFooter,
    /// A run goes past the last pixel.
    RunPastEnd,
};

reader: *Io.Reader,
options: Options,
state: State = .start,
header: Header = undefined,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,

const State = enum { start, config, done };

const Header = struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,
};

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops after the end marker.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the 14-byte header. The native format is `rgb8` for a
/// three-channel file and `rgba8` for a four-channel one. Calling it again
/// returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.header = readHeader(d.reader, d.options.limits) catch |e| return d.fail(e);
        d.state = .config;
    }
    const h = d.header;
    return .{
        .width = h.width,
        .height = h.height,
        .native = if (h.channels == 4) .rgba8 else .rgb8,
        .frame_count = 1,
        .is_opaque = h.channels == 3,
        .metadata = .{ .transfer = switch (h.colorspace) {
            0 => .srgb,
            1 => .linear,
            else => null,
        } },
    };
}

/// Decodes the image into `dst`, which must be the image's size, in any
/// format. Returns null once the image is decoded. `work` is unused: QOI
/// needs no work memory.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    _ = work;
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    const h = d.header;
    try dst.check();
    if (dst.width != h.width or dst.height != h.height) return error.SizeMismatch;
    d.pixels(dst) catch |e| return d.fail(e);
    d.state = .done;
    return .{ .width = h.width, .height = h.height, .is_opaque = h.channels == 3 };
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

fn readHeader(r: *Io.Reader, limits: decode.Limits) Error!Header {
    const b = r.takeArray(14) catch |e| return mapRead(e);
    if (!std.mem.eql(u8, b[0..4], "qoif")) return error.BadSignature;
    const h: Header = .{
        .width = std.mem.readInt(u32, b[4..8], .big),
        .height = std.mem.readInt(u32, b[8..12], .big),
        .channels = b[12],
        .colorspace = b[13],
    };
    if (h.channels != 3 and h.channels != 4) return error.BadHeader;
    try limits.checkSize(h.width, h.height);
    return h;
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

/// The decoding state that carries from one span of pixels to the next.
const Stream = struct {
    px: [4]u8 = .{ 0, 0, 0, 255 },
    index: [64][4]u8 = @splat(.{ 0, 0, 0, 0 }),
    /// Pixels of the current run not yet written.
    run: u32 = 0,
};

/// How a span's pixels are stored: four bytes as decoded, four with alpha
/// forced opaque (a three-channel file), or three.
const Out = enum { rgba, rgbx, rgb };

fn pixels(d: *Decoder, dst: PixelBuffer) Error!void {
    const h = d.header;
    var s: Stream = .{};
    // Write rows straight into the buffer when it holds RGBA or RGB, and
    // through a converter from a span of RGBA otherwise.
    const direct: ?Out = switch (dst.format) {
        .rgba8 => if (h.channels == 4) .rgba else .rgbx,
        .rgb8 => .rgb,
        else => null,
    };
    if (direct) |out| switch (out) {
        inline else => |o| for (0..h.height) |y| try span(d.reader, &s, dst.row(@intCast(y)), o),
    } else {
        const native: PixelFormat = if (h.channels == 4) .rgba8 else .rgb8;
        const conv: Converter = .init(dst.format, native);
        var buf: [256 * 4]u8 = undefined;
        for (0..h.height) |y| {
            const row = dst.row(@intCast(y));
            var x: usize = 0;
            while (x < h.width) {
                const n: usize = @min(256, h.width - x);
                if (h.channels == 4) {
                    try span(d.reader, &s, buf[0 .. n * 4], .rgba);
                } else {
                    try span(d.reader, &s, buf[0 .. n * 3], .rgb);
                }
                conv.run(row[x * dst.format.bytesPerPixel() ..], &buf, n);
                x += n;
            }
        }
    }
    if (s.run != 0) return error.RunPastEnd;
    const footer = d.reader.takeArray(8) catch |e| return mapRead(e);
    if (!std.mem.eql(u8, footer, "\x00\x00\x00\x00\x00\x00\x00\x01")) return error.BadFooter;
}

inline fn hash(px: [4]u8) u6 {
    return @truncate(@as(u32, px[0]) * 3 + @as(u32, px[1]) * 5 + @as(u32, px[2]) * 7 + @as(u32, px[3]) * 11);
}

inline fn put(out: []u8, i: usize, px: [4]u8, comptime o: Out) void {
    switch (o) {
        .rgba => out[i * 4 ..][0..4].* = px,
        .rgbx => out[i * 4 ..][0..4].* = .{ px[0], px[1], px[2], 255 },
        .rgb => out[i * 3 ..][0..3].* = px[0..3].*,
    }
}

/// Decodes `out.len / bytes-per-pixel` pixels into `out`.
fn span(r: *Io.Reader, s: *Stream, out: []u8, comptime o: Out) Error!void {
    const bpp = if (o == .rgb) 3 else 4;
    const n = out.len / bpp;
    var i: usize = 0;
    var px = s.px;
    const index = &s.index;
    // The rest of a run from the last span.
    const carried = @min(s.run, n);
    while (i < carried) : (i += 1) put(out, i, px, o);
    s.run -= @intCast(carried);
    while (i < n) {
        // Every chunk is at most 5 bytes, so with 5 buffered the inner loop
        // reads without checking for more. The end marker follows the last
        // chunk, so a valid stream always has 5 bytes here.
        r.fill(5) catch |e| return mapRead(e);
        const buf = r.buffered();
        var p: usize = 0;
        while (i < n and buf.len - p >= 5) {
            const b = buf[p];
            if (b == 0xfe) {
                px[0..3].* = buf[p + 1 ..][0..3].*;
                p += 4;
            } else if (b == 0xff) {
                px = buf[p + 1 ..][0..4].*;
                p += 5;
            } else switch (@as(u2, @intCast(b >> 6))) {
                0 => {
                    px = index[b];
                    p += 1;
                },
                1 => {
                    px[0] +%= (b >> 4 & 3) -% 2;
                    px[1] +%= (b >> 2 & 3) -% 2;
                    px[2] +%= (b & 3) -% 2;
                    p += 1;
                },
                2 => {
                    const dg = (b & 0x3f) -% 32;
                    const c = buf[p + 1];
                    px[0] +%= dg +% (c >> 4) -% 8;
                    px[1] +%= dg;
                    px[2] +%= dg +% (c & 0xf) -% 8;
                    p += 2;
                },
                3 => {
                    // 1 to 62 pixels; 63 and 64 would be 0xfe and 0xff.
                    const count: usize = (b & 0x3f) + 1;
                    const m = @min(count, n - i);
                    index[hash(px)] = px;
                    for (i..i + m) |j| put(out, j, px, o);
                    i += m;
                    s.run = @intCast(count - m);
                    p += 1;
                    continue;
                },
            }
            index[hash(px)] = px;
            put(out, i, px, o);
            i += 1;
        }
        r.toss(p);
    }
    s.px = px;
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

const end = "\x00\x00\x00\x00\x00\x00\x00\x01";

inline fn testHeader(comptime w: u8, comptime h: u8, comptime channels: u8) []const u8 {
    return "qoif\x00\x00\x00" ++ [_]u8{w} ++ "\x00\x00\x00" ++ [_]u8{h} ++ [_]u8{ channels, 0 };
}

test "every chunk kind" {
    // RGB, DIFF, LUMA, RGBA, INDEX back to the first pixel, and a run.
    const file = testHeader(7, 1, 4) ++
        "\xfe\x10\x20\x30" ++ // (16, 32, 48, 255)
        "\x7b" ++ // diff +1, +0, +1: (17, 32, 49)
        "\xa8\x9a" ++ // luma dg +8, dr-dg +1, db-dg +2: (26, 40, 59)
        "\xff\x01\x02\x03\x80" ++ // (1, 2, 3, 128)
        [_]u8{hash(.{ 16, 32, 48, 255 })} ++
        "\xc1" ++ // run of 2
        end;
    var out: [7 * 4]u8 = undefined;
    const config = try testDecode(file, .rgba8, &out);
    try testing.expectEqual(PixelFormat.rgba8, config.native);
    try testing.expectEqualSlices(u8, &.{
        16, 32, 48, 255, 17, 32, 49, 255, 26, 40, 59, 255, 1, 2, 3, 128,
        16, 32, 48, 255, 16, 32, 48, 255, 16, 32, 48, 255,
    }, &out);
}

test "runs cross rows and conversion spans" {
    // 300 by 2 needs two spans per row through the converter.
    const runs = "\xfd" ** 9 ++ "\xd5"; // 9 * 62 + 22 = 580
    const head = "qoif\x00\x00\x01\x2c\x00\x00\x00\x02\x03\x00";
    const file = head ++ "\xfe\x05\x06\x07" ++ "\xc0" ++ runs ++ "\xc1" ++ end;
    // 1 + 1 + 580 + 2 = 584 is short of 600: a truncated stream.
    var out: [300 * 2 * 4]u8 = undefined;
    try testing.expectError(error.Truncated, testDecode(file, .bgra8, &out));
    const full = file[0 .. file.len - end.len - 1] ++ "\xd1" ++ end; // run of 18 instead of 2
    const config = try testDecode(full, .bgra8, &out);
    try testing.expectEqual(PixelFormat.rgb8, config.native);
    try testing.expect(config.is_opaque);
    for (0..600) |i| try testing.expectEqualSlices(u8, &.{ 7, 6, 5, 255 }, out[i * 4 ..][0..4]);
}

test "the index holds every decoded pixel" {
    // A first run puts the starting pixel (0, 0, 0, 255) in the index, so
    // index 53 then reads it back.
    const file = testHeader(2, 1, 4) ++ "\xc0" ++ [_]u8{hash(.{ 0, 0, 0, 255 })} ++ end;
    var out: [8]u8 = undefined;
    _ = try testDecode(file, .rgba8, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 0, 0, 0, 255 }, &out);
}

test "three channels: alpha is opaque whatever the chunks say" {
    const file = testHeader(1, 1, 3) ++ "\xff\x01\x02\x03\x04" ++ end;
    var out: [4]u8 = undefined;
    _ = try testDecode(file, .rgba8, &out);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &out);
    _ = try testDecode(file, .rgb8, out[0..3]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, out[0..3]);
}

test "malformed streams" {
    var out: [64]u8 = undefined;
    const good = testHeader(2, 1, 4) ++ "\xc1" ++ end;
    _ = try testDecode(good, .rgba8, &out);
    // Every truncation.
    for (0..good.len) |n| try testing.expectError(error.Truncated, testDecode(good[0..n], .rgba8, &out));
    try testing.expectError(error.BadSignature, testDecode("qoiF" ++ good[4..], .rgba8, &out));
    try testing.expectError(error.BadHeader, testDecode(testHeader(2, 1, 5) ++ good[14..], .rgba8, &out));
    try testing.expectError(error.BadFooter, testDecode(testHeader(2, 1, 4) ++ "\xc1" ++ "\x00" ** 8, .rgba8, &out));
    try testing.expectError(error.RunPastEnd, testDecode(testHeader(2, 1, 4) ++ "\xc2" ++ end, .rgba8, &out));
    // An empty image is only its header and end marker.
    _ = try testDecode(testHeader(0, 0, 4) ++ end, .rgba8, &out);
    // Limits apply before any pixel.
    var r: Io.Reader = .fixed(good);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_width = 1 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
    try testing.expectError(error.ImageTooLarge, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 1), &.{}));
    // The pixel buffer must be the image's size.
    r = .fixed(good);
    d = .init(&r, .{});
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 1, 1), &.{}));
    const short: PixelBuffer = .{ .pixels = out[0..7], .format = .rgba8, .width = 2, .height = 1, .stride = 8 };
    try testing.expectError(error.BufferTooSmall, d.decodeFrame(short, &.{}));
}

test "a reader with a small buffer" {
    // Pixels from every chunk kind, through a reader that serves a few
    // bytes at a time from a 64-byte buffer.
    var file: [14 + 5 * 40 + 8]u8 = undefined;
    @memcpy(file[0..14], testHeader(40, 1, 4));
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for (0..40) |i| {
        file[14 + 5 * i ..][0..5].* = .{ 0xff, random.int(u8), random.int(u8), random.int(u8), random.int(u8) };
    }
    @memcpy(file[file.len - 8 ..], end);
    var want: [160]u8 = undefined;
    _ = try testDecode(&file, .rgba8, &want);
    var buffer: [decode.min_buffer_len]u8 = undefined;
    var trickle: Trickle = .{
        .data = &file,
        .reader = .{ .vtable = &.{ .stream = Trickle.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
    };
    var d: Decoder = .init(&trickle.reader, .{});
    var got: [160]u8 = undefined;
    _ = try d.decodeFrame(try PixelBuffer.init(&got, .rgba8, 40, 1), &.{});
    try testing.expectEqualSlices(u8, &want, &got);
}

/// A reader that hands over at most 3 bytes per read.
const Trickle = struct {
    data: []const u8,
    reader: Io.Reader,
    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("reader", r);
        if (t.data.len == 0) return error.EndOfStream;
        const n = try w.write(t.data[0..limit.minInt(@min(3, t.data.len))]);
        t.data = t.data[n..];
        return n;
    }
};
