//! A streaming BMP decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, needs no work memory, and allocates nothing.
//!
//! Every header version (OS/2 1.x and 2.x, and Windows 3 through 5), 1-,
//! 2-, 4-, 8-, 16-, 24-, and 32-bit pixels, RLE4 and RLE8, bitfields with
//! or without alpha, and top-down and bottom-up rows. A JPEG or PNG stream
//! in place of the pixels is reported (`error.EmbeddedJpeg`,
//! `error.EmbeddedPng`) with the reader at its first byte, for the caller to
//! hand to a JPEG or PNG decoder. dib.zig decides the cases the format
//! leaves open. The color table is the bytes between the info header and
//! the pixels, as the pixel offset says, up to 256 entries.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const dib = @import("dib.zig");

const Decoder = @This();

pub const Options = decode.Options;

pub const Error = dib.Error || error{
    /// The pixels are a JPEG stream (`BI_JPEG`). `decodeConfig` leaves the
    /// reader at its first byte, and `embeddedLen` says how long it is.
    EmbeddedJpeg,
    /// The pixels are a PNG stream (`BI_PNG`). `decodeConfig` leaves the
    /// reader at its first byte, and `embeddedLen` says how long it is.
    EmbeddedPng,
};

in: dib.Input,
options: Options,
state: State = .start,
header: dib.Header = undefined,
/// Where the pixels start: the file header's `bfOffBits`.
offset: u32 = 0,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,

const State = enum { start, config, done };

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops after the last row.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .in = .{ .r = reader }, .options = options };
}

/// Reads the file and info headers. The native format is `bgr8`, or `bgra8`
/// when the pixels have an alpha mask or are RLE (whose skipped pixels are
/// transparent). Calling it again returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHeaders() catch |e| return d.fail(e);
        d.state = .config;
    }
    const h = d.header;
    return .{
        .width = h.width,
        .height = h.height,
        .native = h.native(),
        .frame_count = 1,
        .is_opaque = !h.hasAlpha(),
        .metadata = .{
            .density = h.density,
            .transfer = if (h.color_space == dib.Header.srgb or h.color_space == dib.Header.windows) .srgb else null,
            .icc = d.icc(),
        },
    };
}

/// Decodes the image into `dst`, which must be the image's size, in any
/// format. Returns null once the image is decoded. `work` is unused: BMP
/// needs no work memory. With a `blob_sink`, an ICC profile stored after
/// the pixels is read and passed on too.
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
    return .{ .width = h.width, .height = h.height, .is_opaque = !h.hasAlpha() };
}

/// The length of the JPEG or PNG stream after `error.EmbeddedJpeg` or
/// `error.EmbeddedPng`: the header's image size, which may be 0.
pub fn embeddedLen(d: *const Decoder) u32 {
    return d.header.image_size;
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

fn readHeaders(d: *Decoder) Error!void {
    const f = try d.in.takeArray(14);
    if (!std.mem.eql(u8, f[0..2], "BM")) return error.BadSignature;
    d.offset = std.mem.readInt(u32, f[10..14], .little);
    d.header = try dib.readHeader(&d.in, .bmp, d.offset -| (14 + 40));
    const h = d.header;
    try d.options.limits.checkSize(h.width, h.height);
    if (d.offset < d.in.pos) return error.BadHeader;
    switch (h.compression) {
        .jpeg, .png => |c| {
            try d.in.skipTo(d.offset);
            return if (c == .jpeg) error.EmbeddedJpeg else error.EmbeddedPng;
        },
        else => {},
    }
}

/// The embedded ICC profile, if the header names one.
fn icc(d: *const Decoder) ?decode.Blob {
    const p = d.header.profile;
    if (p[1] == 0) return null;
    return .{ .kind = .icc, .offset = 14 + @as(u64, p[0]), .len = p[1] };
}

fn pixels(d: *Decoder, dst: PixelBuffer) Error!void {
    const h = d.header;
    var palette: dib.Palette = undefined;
    if (h.bits <= 8) {
        const room = d.offset - d.in.pos;
        try dib.readPalette(&d.in, h, @intCast(@min(room / h.entry_len, 256)), &palette);
    }
    try d.skipTo(d.offset);
    try dib.decodePixels(&d.in, h, &palette, dst);
    if (d.options.blob_sink != null) {
        if (d.icc()) |b| if (b.offset >= d.in.pos) try d.skipTo(b.offset + b.len);
    }
}

/// Skips to offset `to`, passing an ICC profile that lies wholly in the
/// skipped bytes to the blob sink.
fn skipTo(d: *Decoder, to: u64) Error!void {
    const sink = d.options.blob_sink orelse return d.in.skipTo(to);
    const blob = d.icc() orelse return d.in.skipTo(to);
    if (blob.offset < d.in.pos or blob.offset + blob.len > to) return d.in.skipTo(to);
    try d.in.skipTo(blob.offset);
    var at: u64 = 0;
    while (at < blob.len) {
        const piece = try d.in.take(@intCast(@min(blob.len - at, d.in.maxTake(1))));
        sink.put(blob, at, piece);
        at += piece.len;
    }
    try d.in.skipTo(to);
}

fn testDecode(file: []const u8, format: PixelFormat, out: []u8) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    _ = (try d.decodeFrame(dst, &.{})).?;
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
    return config;
}

inline fn le(comptime T: type, comptime v: T) [@sizeOf(T)]u8 {
    return @bitCast(std.mem.nativeToLittle(T, v));
}

/// A BITMAPINFOHEADER.
inline fn testInfo(comptime w: i32, comptime h: i32, comptime bits: u16, comptime compression: u32) []const u8 {
    return &(le(u32, 40) ++ le(i32, w) ++ le(i32, h) ++ le(u16, 1) ++ le(u16, bits) ++
        le(u32, compression) ++ [_]u8{0} ** 20);
}

/// A file whose pixels follow the info header and color table.
inline fn testFile(comptime info: []const u8, comptime table: []const u8, comptime data: []const u8) []const u8 {
    const offset = 14 + info.len + table.len;
    return "BM" ++ le(u32, offset + data.len) ++ [_]u8{0} ** 4 ++ le(u32, offset) ++ info ++ table ++ data;
}

test "24-bit rows, bottom-up and top-down, padded to four" {
    const top = "\x03\x02\x01\x06\x05\x04\x09\x08\x07\x00\x00\x00";
    const bottom = "\x0c\x0b\x0a\x0f\x0e\x0d\x12\x11\x10\x00\x00\x00";
    const want = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255, 13, 14, 15, 255, 16, 17, 18, 255 };
    var out: [24]u8 = undefined;
    const up = testFile(testInfo(3, 2, 24, 0), "", bottom ++ top);
    const config = try testDecode(up, .rgba8, &out);
    try testing.expectEqual(PixelFormat.bgr8, config.native);
    try testing.expect(config.is_opaque);
    try testing.expectEqualSlices(u8, &want, &out);
    _ = try testDecode(testFile(testInfo(3, -2, 24, 0), "", top ++ bottom), .rgba8, &out);
    try testing.expectEqualSlices(u8, &want, &out);
    // The native format is a straight copy of each row.
    _ = try testDecode(up, .bgr8, out[0..18]);
    try testing.expectEqualSlices(u8, top[0..9] ++ bottom[0..9], out[0..18]);
    // Every truncation, the last row's padding included.
    for (0..up.len) |n| try testing.expectError(error.Truncated, testDecode(up[0..n], .rgba8, &out));
}

test "indexed pixels, and indices past the color table" {
    // Two entries: (10, 20, 30) and (40, 50, 60).
    const table = "\x1e\x14\x0a\x00\x3c\x32\x28\x00";
    const c0 = [_]u8{ 10, 20, 30, 255 };
    const c1 = [_]u8{ 40, 50, 60, 255 };
    const black = [_]u8{ 0, 0, 0, 255 };
    var out: [9 * 4]u8 = undefined;
    _ = try testDecode(testFile(testInfo(4, 1, 8, 0), table, "\x00\x01\x02\xff"), .rgba8, out[0..16]);
    try testing.expectEqualSlices(u8, &(c0 ++ c1 ++ black ++ black), out[0..16]);
    // High nibble first.
    _ = try testDecode(testFile(testInfo(3, 1, 4, 0), table, "\x10\x20\x00\x00"), .rgba8, out[0..12]);
    try testing.expectEqualSlices(u8, &(c1 ++ c0 ++ black), out[0..12]);
    // High bit first.
    _ = try testDecode(testFile(testInfo(9, 1, 1, 0), table, "\xa0\x80\x00\x00"), .rgba8, &out);
    try testing.expectEqualSlices(u8, &(c1 ++ c0 ++ c1 ++ c0 ** 5 ++ c1), &out);
}

test "RLE8 and RLE4: runs, literals, deltas, and skipped pixels" {
    // Entries 1, 2, and 3: (10, 20, 30), (40, 50, 60), (70, 80, 90).
    const table = "\x00\x00\x00\x00\x1e\x14\x0a\x00\x3c\x32\x28\x00\x5a\x50\x46\x00";
    const t = [_]u8{ 0, 0, 0, 0 };
    const c1 = [_]u8{ 10, 20, 30, 255 };
    const c2 = [_]u8{ 40, 50, 60, 255 };
    const c3 = [_]u8{ 70, 80, 90, 255 };
    // Bottom row: a run of two 1s, a literal 2 3 1 padded to a word, end of
    // line. Middle row: a delta of (2, 1), which skips it. Top row from
    // x = 2: a run of two 3s, end of bitmap.
    const rle8 = "\x02\x01\x00\x03\x02\x03\x01\x00\x00\x00" ++ "\x00\x02\x02\x01" ++ "\x02\x03\x00\x01";
    var out: [15 * 4]u8 = undefined;
    const config = try testDecode(testFile(testInfo(5, 3, 8, 1), table, rle8), .rgba8, &out);
    try testing.expectEqual(PixelFormat.bgra8, config.native);
    try testing.expect(!config.is_opaque);
    try testing.expectEqualSlices(u8, &(t ++ t ++ c3 ++ c3 ++ t ++ t ** 5 ++ c1 ++ c1 ++ c2 ++ c3 ++ c1), &out);
    // A run of three alternating 1 2, and a literal 3 0 1 cut off at the
    // row's end.
    const rle4 = "\x03\x12\x00\x03\x30\x10\x00\x01";
    _ = try testDecode(testFile(testInfo(5, 1, 4, 2), table, rle4), .rgba8, out[0..20]);
    try testing.expectEqualSlices(u8, &(c1 ++ c2 ++ c1 ++ c3 ++ t[0..3].* ++ [_]u8{255}), out[0..20]);
    // The stream must end with an end-of-bitmap code, and no end of line
    // may follow the last row.
    const no_end = testFile(testInfo(5, 3, 8, 1), table, rle8[0 .. rle8.len - 2]);
    try testing.expectError(error.Truncated, testDecode(no_end, .rgba8, &out));
    const eol_after = testFile(testInfo(1, 1, 8, 1), table, "\x01\x01\x00\x00\x00\x00\x00\x01");
    try testing.expectError(error.BadRle, testDecode(eol_after, .rgba8, out[0..4]));
    // An RLE8 literal past the end of the row.
    const long = testFile(testInfo(2, 1, 8, 1), table, "\x00\x03\x01\x01\x01\x00\x00\x01");
    try testing.expectError(error.BadRle, testDecode(long, .rgba8, out[0..8]));
}

test "bitfields: narrow masks widen, and alpha needs a mask" {
    // 5-6-5: white, and (16, 32, 16), which widen to (132, 130, 132).
    const masks = comptime le(u32, 0xf800) ++ le(u32, 0x07e0) ++ le(u32, 0x001f);
    var out: [8]u8 = undefined;
    _ = try testDecode(testFile(testInfo(2, 1, 16, 3), &masks, "\xff\xff\x10\x84"), .rgba8, &out);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 132, 130, 132, 255 }, &out);
    // 32-bit BI_RGB: the high byte is unused.
    _ = try testDecode(testFile(testInfo(1, 1, 32, 0), "", "\x01\x02\x03\x80"), .rgba8, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255 }, out[0..4]);
    // A 56-byte header's alpha mask.
    const v3 = comptime testInfo(1, 1, 32, 3) ++
        le(u32, 0xff0000) ++ le(u32, 0xff00) ++ le(u32, 0xff) ++ le(u32, 0xff000000);
    const v3_file = comptime "BM" ++ le(u32, 14 + 56 + 4) ++ [_]u8{0} ** 4 ++ le(u32, 14 + 56) ++
        le(u32, 56) ++ v3[4..] ++ "\x01\x02\x03\x80";
    const config = try testDecode(v3_file, .rgba8, out[0..4]);
    try testing.expectEqual(PixelFormat.bgra8, config.native);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 128 }, out[0..4]);
    // A mask with a gap.
    const gap = comptime le(u32, 0xf00f) ++ le(u32, 0x07e0) ++ le(u32, 0x001f);
    const gap_file = testFile(testInfo(2, 1, 16, 3), &gap, "\x00" ** 4);
    try testing.expectError(error.BadHeader, testDecode(gap_file, .rgba8, &out));
}

test "an embedded PNG is left for the caller" {
    const stream = "\x89PNG\r\n\x1a\n";
    const info = comptime blk: {
        var b = testInfo(1, 1, 0, 5)[0..40].*;
        b[20..24].* = le(u32, stream.len);
        break :blk b;
    };
    var r: Io.Reader = .fixed(testFile(&info, "", stream));
    var d: Decoder = .init(&r, .{});
    try testing.expectError(error.EmbeddedPng, d.decodeConfig());
    try testing.expectEqual(stream.len, d.embeddedLen());
    try testing.expectEqualSlices(u8, stream, try r.peek(stream.len));
}

test "limits apply before the pixels, and errors stick" {
    const file = comptime testFile(testInfo(2, 2, 24, 0), "", "\x00" ** 16);
    var out: [16]u8 = undefined;
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_height = 1 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
    try testing.expectError(error.ImageTooLarge, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 2), &.{}));
    try testing.expectError(error.BadSignature, testDecode("MB" ++ file[2..], .rgba8, &out));
    r = .fixed(file);
    d = .init(&r, .{});
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 1, 2), &.{}));
}
