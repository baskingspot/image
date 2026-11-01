//! The BMP encoder: 24-bit BGR, 32-bit BGRA, or 8-bit with a color table,
//! rows bottom first as every reader expects. src/encode.zig has the
//! contract.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const EncodeError = @import("../encode.zig").Error;

pub const Options = struct {
    /// What the file stores.
    format: Format = .auto,

    pub const Format = enum {
        /// `indexed8` for gray pixels without alpha, `bgra32` for pixels
        /// with alpha, and `bgr24` for the rest.
        auto,
        /// 24-bit pixels in a BITMAPINFOHEADER file; alpha is dropped.
        bgr24,
        /// 32-bit pixels with straight alpha: `BI_BITFIELDS` in a
        /// BITMAPV4HEADER, which is how readers learn there is alpha.
        bgra32,
        /// 8-bit indices into a color table of the image's colors, alpha
        /// dropped: a gray ramp for gray pixels, and otherwise every
        /// distinct color, at most 256 (`error.TooManyColors`).
        indexed8,
    };
};

pub const Error = EncodeError || error{
    /// `indexed8` was asked for and the image has more than 256 colors.
    TooManyColors,
};

/// BMP needs no work memory: 0, or null when the image is too large for
/// the format (a side over 2^31 - 1 pixels, or a file of 4 GiB or more).
pub fn workLen(options: Options, width: u32, height: u32) ?usize {
    _ = layout(options.format, .rgba8, width, height) orelse return null;
    return 0;
}

const Layout = struct {
    format: Options.Format,
    header_len: u32,
    table_len: u32,
    row_len: u32,
    file_len: u32,
};

fn layout(asked: Options.Format, src: PixelFormat, width: u32, height: u32) ?Layout {
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return null;
    const format: Options.Format = switch (asked) {
        .auto => if (src.hasAlpha()) .bgra32 else if (src.isGray()) .indexed8 else .bgr24,
        else => asked,
    };
    const bytes: u64 = switch (format) {
        .bgr24 => 3,
        .bgra32 => 4,
        .indexed8, .auto => 1,
    };
    const row = (bytes * width + 3) / 4 * 4;
    const header_len: u32 = if (format == .bgra32) 108 else 40;
    const table_len: u32 = if (format == .indexed8) 256 * 4 else 0;
    const total = 14 + header_len + table_len + row * height;
    if (total > std.math.maxInt(u32)) return null;
    return .{
        .format = format,
        .header_len = header_len,
        .table_len = table_len,
        .row_len = @intCast(row),
        .file_len = @intCast(total),
    };
}

/// Writes `src` as a BMP file.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: Options, work: []u8) Error!void {
    _ = work;
    try src.check();
    const l = layout(options.format, src.format, src.width, src.height) orelse return error.ImageTooLarge;
    var table: Table = .{};
    const gray = src.format.isGray();
    if (l.format == .indexed8 and !gray) try table.collect(src);
    const colors: u32 = if (l.format != .indexed8) 0 else if (gray) 256 else table.count;
    // A table of fewer than 256 colors is written short.
    const table_len = colors * 4;
    const file_len = l.file_len - l.table_len + table_len;

    var head: [14 + 108]u8 = @splat(0);
    head[0..2].* = "BM".*;
    std.mem.writeInt(u32, head[2..6], file_len, .little);
    std.mem.writeInt(u32, head[10..14], 14 + l.header_len + table_len, .little);
    writeInfo(head[14..], l.header_len, src.width, src.height, l.format, colors, l.row_len * src.height);
    try w.writeAll(head[0 .. 14 + l.header_len]);
    if (l.format == .indexed8) {
        for (0..colors) |i| {
            const c: [4]u8 = if (gray) .{ @intCast(i), @intCast(i), @intCast(i), 0 } else table.colors[i];
            try w.writeAll(&c);
        }
    }
    try writeRows(w, src, l.format, if (l.format == .indexed8 and !gray) &table else null, l.row_len);
}

/// An info header for 32-bit pixels with an alpha mask (`header_len`
/// 108), or a BITMAPINFOHEADER (40). The height is doubled for an ICO
/// entry, whose AND mask follows the pixels.
pub fn writeInfo(
    out: []u8,
    header_len: u32,
    width: u32,
    height: u32,
    format: Options.Format,
    colors: u32,
    image_len: u32,
) void {
    @memset(out[0..header_len], 0);
    std.mem.writeInt(u32, out[0..4], header_len, .little);
    std.mem.writeInt(u32, out[4..8], width, .little);
    std.mem.writeInt(u32, out[8..12], height, .little);
    std.mem.writeInt(u16, out[12..14], 1, .little);
    std.mem.writeInt(u16, out[14..16], switch (format) {
        .bgr24 => 24,
        .bgra32 => 32,
        .indexed8, .auto => 8,
    }, .little);
    std.mem.writeInt(u32, out[20..24], image_len, .little);
    std.mem.writeInt(u32, out[32..36], colors, .little);
    if (header_len >= 108) {
        std.mem.writeInt(u32, out[16..20], 3, .little);
        for ([_]u32{ 0xff0000, 0xff00, 0xff, 0xff000000 }, 0..) |m, i| {
            std.mem.writeInt(u32, out[40 + 4 * i ..][0..4], m, .little);
        }
        std.mem.writeInt(u32, out[56..60], 0x73524742, .little);
    }
}

/// The pixel rows, bottom first, each padded to four bytes.
fn writeRows(w: *Io.Writer, src: PixelBuffer, format: Options.Format, table: ?*const Table, row_len: u32) Error!void {
    const span = 1024;
    var buf: [span * 4]u8 = undefined;
    var index: [span]u8 = undefined;
    const out: PixelFormat = switch (format) {
        .bgr24 => .bgr8,
        .bgra32 => .bgra8,
        .indexed8, .auto => if (table == null) .gray8 else .bgr8,
    };
    const conv: Converter = .init(out, src.format);
    const in_bpp = src.format.bytesPerPixel();
    const out_bpp = out.bytesPerPixel();
    const pad = row_len - src.width * @as(u64, if (format == .indexed8) 1 else out_bpp);
    var y = src.height;
    while (y > 0) {
        y -= 1;
        const row = src.row(y);
        var x: usize = 0;
        while (x < src.width) {
            const n = @min(src.width - x, span);
            const piece = buf[0 .. n * out_bpp];
            conv.run(piece, row[x * in_bpp ..], n);
            if (table) |t| {
                for (index[0..n], 0..) |*i, k| i.* = t.find(piece[k * 3 ..][0..3].*);
                try w.writeAll(index[0..n]);
            } else {
                try w.writeAll(piece);
            }
            x += n;
        }
        try w.splatByteAll(0, pad);
    }
}

/// An image's distinct colors, in the order they first appear, found
/// through an open-addressed hash table.
const Table = struct {
    colors: [256][4]u8 = undefined,
    count: u32 = 0,
    /// Color + 1 << 24 (0 for empty), and its index.
    keys: [512]u32 = @splat(0),
    slots: [512]u8 = undefined,

    fn slot(key: u32) u9 {
        return @truncate((key *% 0x9e3779b1) >> 23);
    }

    fn collect(t: *Table, src: PixelBuffer) Error!void {
        const span = 1024;
        var buf: [span * 3]u8 = undefined;
        const conv: Converter = .init(.bgr8, src.format);
        const in_bpp = src.format.bytesPerPixel();
        var last: ?u32 = null;
        for (0..src.height) |y| {
            const row = src.row(@intCast(y));
            var x: usize = 0;
            while (x < src.width) {
                const n = @min(src.width - x, span);
                conv.run(&buf, row[x * in_bpp ..], n);
                for (0..n) |k| {
                    const key = pack(buf[k * 3 ..][0..3].*);
                    if (last == key) continue;
                    last = key;
                    try t.add(key);
                }
                x += n;
            }
        }
    }

    fn pack(c: [3]u8) u32 {
        return @as(u32, c[0]) | @as(u32, c[1]) << 8 | @as(u32, c[2]) << 16 | 1 << 24;
    }

    fn add(t: *Table, key: u32) Error!void {
        var s = slot(key);
        while (t.keys[s] != 0) : (s +%= 1) if (t.keys[s] == key) return;
        if (t.count == 256) return error.TooManyColors;
        t.keys[s] = key;
        t.slots[s] = @intCast(t.count);
        t.colors[t.count] = .{ @truncate(key), @truncate(key >> 8), @truncate(key >> 16), 0 };
        t.count += 1;
    }

    fn find(t: *const Table, c: [3]u8) u8 {
        const key = pack(c);
        var s = slot(key);
        while (t.keys[s] != key) s +%= 1;
        return t.slots[s];
    }
};

const Decoder = @import("Decoder.zig");

fn testRoundTrip(src: PixelBuffer, options: Options, file: []u8, out: []u8) !usize {
    var w: Io.Writer = .fixed(file);
    try encode(&w, src, options, &.{});
    var r: Io.Reader = .fixed(w.buffered());
    var d: Decoder = .init(&r, .{});
    _ = (try d.decodeFrame(try PixelBuffer.init(out, src.format, src.width, src.height), &.{})).?;
    return w.end;
}

test "auto picks the smallest file that holds the pixels" {
    var file: [2048]u8 = undefined;
    var out: [16]u8 = undefined;
    // Gray: 8-bit with a gray ramp, rows padded to four.
    var gray = [_]u8{ 0, 77, 200, 255 };
    var len = try testRoundTrip(try PixelBuffer.init(&gray, .gray8, 2, 2), .{}, &file, &out);
    try testing.expectEqual(14 + 40 + 1024 + 2 * 4, len);
    try testing.expectEqualSlices(u8, &gray, out[0..4]);
    // Alpha: 32-bit BGRA in a BITMAPV4HEADER.
    var rgba = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 0 };
    len = try testRoundTrip(try PixelBuffer.init(&rgba, .rgba8, 2, 1), .{}, &file, &out);
    try testing.expectEqual(14 + 108 + 8, len);
    try testing.expectEqualSlices(u8, &rgba, out[0..8]);
    // Color: an exact table of the image's colors when asked, written short.
    var rgb = [_]u8{ 9, 8, 7, 1, 2, 3, 9, 8, 7 };
    len = try testRoundTrip(try PixelBuffer.init(&rgb, .rgb8, 3, 1), .{ .format = .indexed8 }, &file, &out);
    try testing.expectEqual(14 + 40 + 2 * 4 + 4, len);
    try testing.expectEqualSlices(u8, &rgb, out[0..9]);
}

test "an indexed file holds at most 256 colors" {
    var px: [257 * 3]u8 = undefined;
    for (0..257) |i| px[i * 3 ..][0..3].* = .{ @truncate(i), @intCast(i >> 8), 0 };
    var file: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&file);
    const src = try PixelBuffer.init(&px, .rgb8, 257, 1);
    try testing.expectError(error.TooManyColors, encode(&w, src, .{ .format = .indexed8 }, &.{}));
    px[256 * 3 ..][0..3].* = .{ 0, 0, 0 };
    w = .fixed(&file);
    try encode(&w, src, .{ .format = .indexed8 }, &.{});
}
