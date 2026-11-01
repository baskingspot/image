//! The QOI encoder. It writes the bytes the reference encoder (qoi.h) writes
//! for the same pixels: a run while pixels repeat (at most 62), else an
//! index chunk when the pixel's index entry holds it, else DIFF, LUMA, or
//! RGB when alpha is unchanged and RGBA when it is not. Like qoi.h, it puts
//! a pixel in the index only when it writes it with DIFF, LUMA, RGB, or
//! RGBA; a decoder that puts every pixel in the index (as the
//! specification says) reads the same image.
//!
//! A source with alpha is stored as four channels and one without as three,
//! after `image.convert` to straight RGBA or RGB.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const encoding = @import("../encode.zig");
const Transfer = @import("../decode.zig").Transfer;
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const Decoder = @import("Decoder.zig");

pub const EncodeOptions = struct {
    /// The header's colorspace byte: 0 for sRGB with linear alpha, 1 for
    /// all channels linear. It changes nothing in the pixels.
    transfer: Transfer = .srgb,
};

pub const EncodeError = encoding.Error;

/// QOI needs no work memory.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    _ = .{ options, width, height };
    return 0;
}

/// Pixels per span when converting.
const span_len = 256;
/// The most bytes one pixel can add: a run's end and an RGBA chunk.
const max_pixel_bytes = 6;

/// Writes `src` as a QOI file to `w`.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    _ = work;
    try src.check();
    const native: PixelFormat = if (src.format.hasAlpha()) .rgba8 else .rgb8;
    var header: [14]u8 = undefined;
    header[0..4].* = "qoif".*;
    std.mem.writeInt(u32, header[4..8], src.width, .big);
    std.mem.writeInt(u32, header[8..12], src.height, .big);
    header[12] = if (native == .rgba8) 4 else 3;
    header[13] = switch (options.transfer) {
        .srgb => 0,
        .linear => 1,
    };
    try w.writeAll(&header);
    var s: State = .{};
    switch (native) {
        inline .rgba8, .rgb8 => |n| {
            const ch = comptime n.bytesPerPixel();
            if (src.format == n) {
                for (0..src.height) |y| try s.pixels(w, src.row(@intCast(y)), ch);
            } else {
                const conv: Converter = .init(n, src.format);
                const bpp = src.format.bytesPerPixel();
                var buf: [span_len * ch]u8 = undefined;
                for (0..src.height) |y| {
                    const row = src.row(@intCast(y));
                    var x: usize = 0;
                    while (x < src.width) : (x += span_len) {
                        const count = @min(span_len, src.width - x);
                        conv.run(&buf, row[x * bpp ..], count);
                        try s.pixels(w, buf[0 .. count * ch], ch);
                    }
                }
            }
        },
        else => unreachable,
    }
    if (s.run != 0) try w.writeByte(0xc0 | (s.run - 1));
    try w.writeAll("\x00\x00\x00\x00\x00\x00\x00\x01");
}

/// What carries from one span to the next. Pixels are `u32`s holding R, G,
/// B, and A from the low byte up.
const State = struct {
    prev: u32 = 0xff00_0000,
    index: [64]u32 = @splat(0),
    /// Repeats of `prev` not yet written.
    run: u8 = 0,

    /// Encodes the pixels in `bytes`, `ch` bytes each, into `w`.
    fn pixels(s: *State, w: *Io.Writer, bytes: []const u8, comptime ch: comptime_int) EncodeError!void {
        const n = bytes.len / ch;
        var i: usize = 0;
        while (i < n) {
            var out = w.unusedCapacitySlice();
            if (out.len < max_pixel_bytes) {
                out = w.writableSliceGreedy(max_pixel_bytes) catch {
                    // A full fixed writer may still hold the few bytes left:
                    // one pixel at a time through writeAll.
                    var tiny: [max_pixel_bytes]u8 = undefined;
                    const done = s.chunks(&tiny, bytes[i * ch ..][0..ch], ch);
                    try w.writeAll(tiny[0..done.written]);
                    i += 1;
                    continue;
                };
            }
            const done = s.chunks(out, bytes[i * ch ..], ch);
            w.advance(done.written);
            i += done.read;
        }
    }

    /// Encodes pixels from `in` into `out` while `out` has room for the
    /// largest a pixel can need, which it has at the start.
    fn chunks(s: *State, out: []u8, in: []const u8, comptime ch: comptime_int) struct { read: usize, written: usize } {
        const n = in.len / ch;
        var prev = s.prev;
        var run = s.run;
        var o: usize = 0;
        var i: usize = 0;
        while (i < n and out.len - o >= max_pixel_bytes) : (i += 1) {
            const px: u32 = if (ch == 4)
                std.mem.readInt(u32, in[i * 4 ..][0..4], .little)
            else
                @as(u32, std.mem.readInt(u24, in[i * 3 ..][0..3], .little)) | 0xff00_0000;
            if (px == prev) {
                run += 1;
                if (run == 62) {
                    out[o] = 0xc0 | 61;
                    o += 1;
                    run = 0;
                }
                continue;
            }
            if (run != 0) {
                out[o] = 0xc0 | (run - 1);
                o += 1;
                run = 0;
            }
            const h = hash(px);
            if (s.index[h] == px) {
                out[o] = h;
                o += 1;
            } else {
                s.index[h] = px;
                var b: [4]u8 = undefined;
                var p: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, px, .little);
                std.mem.writeInt(u32, &p, prev, .little);
                if (b[3] == p[3]) {
                    const vr = b[0] -% p[0];
                    const vg = b[1] -% p[1];
                    const vb = b[2] -% p[2];
                    const vg_r = vr -% vg;
                    const vg_b = vb -% vg;
                    if (vr +% 2 < 4 and vg +% 2 < 4 and vb +% 2 < 4) {
                        out[o] = 0x40 | (vr +% 2) << 4 | (vg +% 2) << 2 | (vb +% 2);
                        o += 1;
                    } else if (vg +% 32 < 64 and vg_r +% 8 < 16 and vg_b +% 8 < 16) {
                        out[o..][0..2].* = .{ 0x80 | (vg +% 32), (vg_r +% 8) << 4 | (vg_b +% 8) };
                        o += 2;
                    } else {
                        out[o..][0..4].* = .{ 0xfe, b[0], b[1], b[2] };
                        o += 4;
                    }
                } else {
                    out[o..][0..5].* = .{ 0xff, b[0], b[1], b[2], b[3] };
                    o += 5;
                }
            }
            prev = px;
        }
        s.prev = prev;
        s.run = run;
        return .{ .read = i, .written = o };
    }
};

/// The specification's index position, (3r + 5g + 7b + 11a) mod 64: the
/// four bytes spread 16 bits apart, and one multiply sums their weighted
/// values into bits 48 to 63.
inline fn hash(px: u32) u6 {
    const x: u64 = px;
    const spread = (x & 0x00ff_00ff) | (x & 0xff00_ff00) << 24;
    return @truncate((spread *% (3 << 48 | 7 << 32 | 5 << 16 | 11)) >> 48);
}

fn testEncode(src: PixelBuffer, out: []u8) ![]u8 {
    var w: Io.Writer = .fixed(out);
    try encode(&w, src, .{}, &.{});
    return w.buffered();
}

test "every chunk kind, as qoi.h writes them" {
    // The pixels of the decoder's "every chunk kind" test, plus a first
    // pixel equal to the starting one (a run that does not enter the
    // index) and a later one that must not be an index chunk.
    var px = [_][4]u8{
        .{ 0, 0, 0, 255 }, // run 1 of the starting pixel
        .{ 16, 32, 48, 255 }, // RGB
        .{ 17, 32, 49, 255 }, // DIFF +1 +0 +1
        .{ 26, 40, 59, 255 }, // LUMA dg +8, dr-dg +1, db-dg +2
        .{ 1, 2, 3, 128 }, // RGBA
        .{ 16, 32, 48, 255 }, // INDEX
        .{ 16, 32, 48, 255 }, // run 2
        .{ 16, 32, 48, 255 },
        .{ 0, 0, 0, 255 }, // RGB: the run never put it in the index
    };
    var buf: [128]u8 = undefined;
    const file = try testEncode(try PixelBuffer.init(std.mem.asBytes(&px), .rgba8, px.len, 1), &buf);
    const want = "qoif\x00\x00\x00\x09\x00\x00\x00\x01\x04\x00" ++
        "\xc0" ++
        "\xfe\x10\x20\x30" ++
        "\x7b" ++
        "\xa8\x9a" ++
        "\xff\x01\x02\x03\x80" ++
        [_]u8{hash(0xff30_2010)} ++
        "\xc1" ++
        "\xfe\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x01";
    try testing.expectEqualSlices(u8, want, file);
}

test "runs of 62, and alpha dropped or kept by the source format" {
    // 130 equal pixels: runs of 62, 62, and 5 after the first RGB chunk.
    var px: [130 * 3]u8 = undefined;
    for (0..130) |i| px[i * 3 ..][0..3].* = .{ 90, 8, 7 };
    var buf: [64]u8 = undefined;
    const file = try testEncode(try PixelBuffer.init(&px, .rgb8, 130, 1), &buf);
    try testing.expectEqual(3, file[12]);
    try testing.expectEqualSlices(u8, "\xfe\x5a\x08\x07\xfd\xfd\xc4", file[14 .. file.len - 8]);
    // The same as BGRA: four channels, the same chunks.
    var bgra: [130 * 4]u8 = undefined;
    for (0..130) |i| bgra[i * 4 ..][0..4].* = .{ 7, 8, 90, 255 };
    var buf2: [64]u8 = undefined;
    const file2 = try testEncode(try PixelBuffer.init(&bgra, .bgra8, 130, 1), &buf2);
    try testing.expectEqual(4, file2[12]);
    try testing.expectEqualSlices(u8, file[14..], file2[14..]);
}

test "a fixed writer of exactly the file's size" {
    var px: [40 * 4]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    prng.random().bytes(&px);
    const src = try PixelBuffer.init(&px, .rgba8, 40, 1);
    var big: [512]u8 = undefined;
    const file = try testEncode(src, &big);
    var exact: [512]u8 = undefined;
    try testing.expectEqualSlices(u8, file, try testEncode(src, exact[0..file.len]));
    try testing.expectError(error.WriteFailed, testEncode(src, exact[0 .. file.len - 1]));
    // And it decodes to the pixels.
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    var back: [40 * 4]u8 = undefined;
    _ = try d.decodeFrame(try PixelBuffer.init(&back, .rgba8, 40, 1), &.{});
    try testing.expectEqualSlices(u8, &px, &back);
}

test hash {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    for (0..10000) |_| {
        const px = prng.random().int(u32);
        const b: [4]u8 = .{ @truncate(px), @truncate(px >> 8), @truncate(px >> 16), @truncate(px >> 24) };
        const want: u6 = @truncate(@as(u32, b[0]) * 3 + @as(u32, b[1]) * 5 + @as(u32, b[2]) * 7 + @as(u32, b[3]) * 11);
        try testing.expectEqual(want, hash(px));
    }
    try testing.expectEqual(53, hash(0xff00_0000));
    try testing.expectEqual(@as(u6, @truncate(255 * 26)), hash(0xffff_ffff));
}
