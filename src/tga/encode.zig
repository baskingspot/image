//! TGA encoding: true-color or gray images, uncompressed (image types 2
//! and 3) or run-length encoded (10 and 11), top-left origin, ending with
//! the TGA 2.0 footer and no extension area.
//!
//! The file stores 8-bit samples: gray sources as 8-bit gray, color as
//! 24-bit BGR, and anything with alpha (gray included) as 32-bit BGRA with
//! straight alpha and eight attribute bits, so `image.tga.Decoder` reads
//! back the source converted by `image.convert` to `gray8`, `bgr8`, or
//! `bgra8`. Run-length packets stay within a scan line, as the
//! specification asks.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const shared = @import("../encode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

pub const EncodeOptions = struct {
    /// Run-length encode the pixels; otherwise store them as they are.
    rle: bool = true,
};

pub const EncodeError = shared.Error;

/// The largest width or height a TGA header holds.
const max_side = 0xffff;

/// The work memory `encode` needs for a `width` by `height` image: a row of
/// pixels as the file stores them, and for run-length encoding, the row's
/// packets. Null if the image is too large for TGA.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    if (width > max_side or height > max_side) return null;
    const row = @as(usize, width) * 4;
    return if (options.rle) row + packedLen(width, 4) else row;
}

/// The most bytes a row of `width` pixels of `bpp` bytes takes in packets:
/// every pixel raw, a count byte for every 128.
fn packedLen(width: usize, bpp: usize) usize {
    return width * bpp + (width + 127) / 128;
}

/// What the file stores for pixels of `format`.
fn fileFormat(format: PixelFormat) PixelFormat {
    if (format.hasAlpha()) return .bgra8;
    return if (format.isGray()) .gray8 else .bgr8;
}

const footer = "\x00" ** 8 ++ "TRUEVISION-XFILE.\x00";

/// Writes `src` as a TGA file to `w`, converting its pixels to what the
/// file stores. `work` holds at least `workLen(options, src.width,
/// src.height)` bytes.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    try src.check();
    const need = workLen(options, src.width, src.height) orelse return error.ImageTooLarge;
    if (work.len < need) return error.WorkTooSmall;
    const format = fileFormat(src.format);
    const bpp = format.bytesPerPixel();
    const gray = format == .gray8;
    const image_type: u8 = @as(u8, if (gray) 3 else 2) | @as(u8, if (options.rle) 8 else 0);
    var header: [18]u8 = @splat(0);
    header[2] = image_type;
    std.mem.writeInt(u16, header[12..14], @intCast(src.width), .little);
    std.mem.writeInt(u16, header[14..16], @intCast(src.height), .little);
    header[16] = @intCast(bpp * 8);
    // Top-left origin, and eight attribute bits for alpha.
    header[17] = 0x20 | @as(u8, if (bpp == 4) 8 else 0);
    try w.writeAll(&header);
    const width: usize = src.width;
    const row_len = width * bpp;
    const conv: Converter = .init(format, src.format);
    for (0..src.height) |y| {
        var row = src.row(@intCast(y));
        if (src.format != format) {
            conv.run(work[0..row_len], row, width);
            row = work[0..row_len];
        }
        if (!options.rle) {
            try w.writeAll(row);
            continue;
        }
        const out = work[width * 4 ..][0..packedLen(width, bpp)];
        const len = switch (bpp) {
            inline 1, 3, 4 => |b| packRow(out, row, b),
            else => unreachable,
        };
        try w.writeAll(out[0..len]);
    }
    try w.writeAll(footer);
}

/// Whether pixels `i` and `j` of `row` are the same, compared as one
/// integer: `std.mem.eql` on 3 bytes compares them one at a time
/// (results/tga-20261101.md, RLE encode of the 50 MP photo 168 to
/// 292 MP/s).
inline fn same(row: []const u8, i: usize, j: usize, comptime bpp: usize) bool {
    const T = @Int(.unsigned, bpp * 8);
    return @as(T, @bitCast(row[i * bpp ..][0..bpp].*)) == @as(T, @bitCast(row[j * bpp ..][0..bpp].*));
}

/// Encodes one row of pixels as packets into `out`, returning the bytes
/// written. A run packet takes a run of two or more pixels (three for gray,
/// where a run of two costs a raw packet as much), and a raw packet takes
/// everything up to the next such run.
fn packRow(out: []u8, row: []const u8, comptime bpp: usize) usize {
    const min_run = if (bpp == 1) 3 else 2;
    const n = row.len / bpp;
    var o: usize = 0;
    var i: usize = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n and j - i < 128 and same(row, i, j, bpp)) j += 1;
        if (j - i >= min_run) {
            out[o] = @intCast(0x80 | (j - i - 1));
            out[o + 1 ..][0..bpp].* = row[i * bpp ..][0..bpp].*;
            o += 1 + bpp;
            i = j;
            continue;
        }
        // A raw packet, up to the start of the next run.
        var k = i + 1;
        while (k < n and k - i < 128) : (k += 1) {
            if (k + min_run <= n and same(row, k, k + 1, bpp) and (min_run == 2 or same(row, k, k + 2, bpp))) break;
        }
        out[o] = @intCast(k - i - 1);
        @memcpy(out[o + 1 ..][0 .. (k - i) * bpp], row[i * bpp .. k * bpp]);
        o += 1 + (k - i) * bpp;
        i = k;
    }
    return o;
}

test packRow {
    var out: [64]u8 = undefined;
    // A run of three, two raw pixels, and a run of two.
    const rgb = [_]u8{ 1, 2, 3, 1, 2, 3, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0, 0, 0, 0 };
    const len = packRow(&out, &rgb, 3);
    try testing.expectEqualSlices(u8, &.{ 0x82, 1, 2, 3, 0x01, 4, 5, 6, 7, 8, 9, 0x81, 0, 0, 0 }, out[0..len]);
    // Gray: a run of two stays in the raw packet.
    const gray = [_]u8{ 5, 5, 6, 7, 7, 7 };
    const glen = packRow(&out, &gray, 1);
    try testing.expectEqualSlices(u8, &.{ 0x02, 5, 5, 6, 0x82, 7 }, out[0..glen]);
    // Long rows split at 128 pixels.
    const flat: [300]u8 = @splat(9);
    const flen = packRow(&out, &flat, 1);
    try testing.expectEqualSlices(u8, &.{ 0xff, 9, 0xff, 9, 0xab, 9 }, out[0..flen]);
}

test encode {
    const Decoder = @import("Decoder.zig");
    var file: [128]u8 = undefined;
    var work: [64]u8 = undefined;
    // Two equal RGB pixels: one run packet, stored blue first.
    const rgb = [_]u8{ 1, 2, 3, 1, 2, 3 };
    var w: Io.Writer = .fixed(&file);
    try encode(&w, try PixelBuffer.init(@constCast(&rgb), .rgb8, 2, 1), .{}, &work);
    const header = "\x00\x00\x0a" ++ "\x00" ** 9 ++ "\x02\x00\x01\x00\x18\x20";
    try testing.expectEqualSlices(u8, header ++ "\x81\x03\x02\x01" ++ footer, w.buffered());
    // Gray with alpha becomes 32-bit, uncompressed, and reads back.
    const ga = [_]u8{ 10, 200, 20, 0, 30, 255 };
    w = .fixed(&file);
    try encode(&w, try PixelBuffer.init(@constCast(&ga), .gray_alpha8, 1, 3), .{ .rle = false }, &work);
    var r: Io.Reader = .fixed(w.buffered());
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(PixelFormat.bgra8, config.native);
    var out: [6]u8 = undefined;
    _ = try d.decodeFrame(try PixelBuffer.init(&out, .gray_alpha8, 1, 3), &.{});
    try testing.expectEqualSlices(u8, &ga, &out);
    try testing.expectEqual(null, try d.decodeFrame(try PixelBuffer.init(&out, .gray_alpha8, 1, 3), &.{}));
    try testing.expect(d.trailer().?.footer);
    // Sizes past the header's 16 bits, and too little work memory.
    try testing.expectEqual(null, workLen(.{}, 0x10000, 1));
    const src = try PixelBuffer.init(@constCast(&rgb), .rgb8, 2, 1);
    try testing.expectError(error.WorkTooSmall, encode(&w, src, .{}, work[0..8]));
}
