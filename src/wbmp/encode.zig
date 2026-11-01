//! The WBMP encoder: type 0, one bit per pixel. A pixel is white when its
//! gray value, from `image.convert`, is at least 128, and black otherwise;
//! alpha is dropped, as conversion drops it. Black and white sources (gray
//! 0 and 255) round-trip exactly.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const native_endian = @import("builtin").cpu.arch.endian();

const encoding = @import("../encode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const Decoder = @import("Decoder.zig");

pub const EncodeOptions = struct {};

pub const EncodeError = encoding.Error;

/// WBMP needs no work memory.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    _ = .{ options, width, height };
    return 0;
}

/// Pixels per span: a multiple of 64, so only a row's last span ends
/// inside a 64-pixel block.
const span_len = 512;

/// Writes `src` as a WBMP file to `w`.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    _ = .{ options, work };
    try src.check();
    var header: [2 + 2 * 5]u8 = @splat(0);
    var len: usize = 2;
    len += putInt(header[len..], src.width);
    len += putInt(header[len..], src.height);
    try w.writeAll(header[0..len]);
    const conv: Converter = .init(.gray8, src.format);
    const bpp = src.format.bytesPerPixel();
    var gray: [span_len]u8 = undefined;
    var bits: [span_len / 8]u8 = undefined;
    for (0..src.height) |y| {
        const row = src.row(@intCast(y));
        var x: usize = 0;
        while (x < src.width) : (x += span_len) {
            const n = @min(span_len, src.width - x);
            const g = if (src.format == .gray8) row[x..][0..n] else blk: {
                conv.run(&gray, row[x * bpp ..], n);
                break :blk gray[0..n];
            };
            const out = bits[0 .. (n + 7) / 8];
            pack(out, g);
            try w.writeAll(out);
        }
    }
}

/// A multi-byte integer: big-endian groups of 7 bits, the top bit set on
/// every octet but the last. Returns the octets written.
fn putInt(out: []u8, v: u32) usize {
    var n: usize = 1;
    while (n < 5 and v >> @intCast(7 * n) != 0) n += 1;
    for (0..n) |i| {
        const shift: u5 = @intCast(7 * (n - 1 - i));
        out[i] = @as(u8, @truncate(v >> shift)) & 0x7f | if (i + 1 < n) @as(u8, 0x80) else 0;
    }
    return n;
}

/// Packs gray pixels into bits, most significant first: 1 for at least
/// 128. The last octet's unused low bits are 0.
fn pack(out: []u8, gray: []const u8) void {
    const V = @Vector(64, u8);
    var i: usize = 0;
    while (gray.len - i >= 64) : (i += 64) {
        const v: V = gray[i..][0..64].*;
        const bits: u64 = @bitCast(v >= @as(V, @splat(128)));
        // Bit k of the mask is pixel k (a bool vector's lanes are in memory
        // order, so big-endian targets hold them reversed); pixel 8j belongs
        // in the top bit of octet j.
        const mask = if (native_endian == .little) bits else @bitReverse(bits);
        std.mem.writeInt(u64, out[i / 8 ..][0..8], @bitReverse(mask), .big);
    }
    while (i < gray.len) : (i += 8) {
        var b: u8 = 0;
        for (gray[i..@min(i + 8, gray.len)], 0..) |g, k| {
            if (g >= 128) b |= @as(u8, 0x80) >> @intCast(k);
        }
        out[i / 8] = b;
    }
}

test putInt {
    var out: [5]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{0}, out[0..putInt(&out, 0)]);
    try testing.expectEqualSlices(u8, &.{0x7f}, out[0..putInt(&out, 127)]);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, out[0..putInt(&out, 128)]);
    try testing.expectEqualSlices(u8, &.{ 0x82, 0x2c }, out[0..putInt(&out, 300)]);
    try testing.expectEqualSlices(u8, &.{ 0x8f, 0xff, 0xff, 0xff, 0x7f }, out[0..putInt(&out, std.math.maxInt(u32))]);
}

test "encode" {
    // 70 by 2 gray: a 64-pixel block and a tail each row, thresholds at
    // 127 and 128.
    var px: [140]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = if (i % 3 == 0) 128 else if (i % 3 == 1) 127 else @truncate(i * 7);
    var file: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&file);
    try encode(&w, try PixelBuffer.init(&px, .gray8, 70, 2), .{}, &.{});
    const out = w.buffered();
    try testing.expectEqualSlices(u8, "\x00\x00\x46\x02", out[0..4]);
    try testing.expectEqual(4 + 2 * 9, out.len);
    for (0..2) |y| {
        for (0..70) |x| {
            const bit = out[4 + y * 9 + x / 8] >> @intCast(7 - x % 8) & 1;
            try testing.expectEqual(@intFromBool(px[y * 70 + x] >= 128), bit);
        }
        // Padding bits are zero.
        try testing.expectEqual(0, out[4 + y * 9 + 8] & 0x03);
    }
    // The same through a color format, whose gray is the same value.
    var rgba: [140 * 4]u8 = undefined;
    for (px, 0..) |p, i| rgba[i * 4 ..][0..4].* = .{ p, p, p, @truncate(i) };
    var again: [64]u8 = undefined;
    var w2: Io.Writer = .fixed(&again);
    try encode(&w2, try PixelBuffer.init(&rgba, .rgba8, 70, 2), .{}, &.{});
    try testing.expectEqualSlices(u8, out, w2.buffered());
    // And back through the decoder.
    var r: Io.Reader = .fixed(out);
    var d: Decoder = .init(&r, .{});
    var back: [140]u8 = undefined;
    _ = try d.decodeFrame(try PixelBuffer.init(&back, .gray8, 70, 2), &.{});
    for (px, back) |p, b| try testing.expectEqual(@as(u8, if (p >= 128) 255 else 0), b);
}
