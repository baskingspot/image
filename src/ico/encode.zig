//! The ICO and CUR encoder: each image a 32-bit BMP entry with straight
//! alpha and an AND mask set where alpha is 0, for readers that ignore
//! alpha. PNG entries wait for the PNG encoder. src/encode.zig has the
//! contract; `encodeAll` writes several images, as an icon's sizes.

const std = @import("std");
const Io = std.Io;

const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const EncodeError = @import("../encode.zig").Error;
const bmp = @import("../bmp/encode.zig");

pub const Options = struct {
    /// Write a CUR, whose entries have hotspots, rather than an ICO.
    cursor: bool = false,
    /// `encode`'s image's hotspot, for a cursor.
    hotspot: [2]u16 = .{ 0, 0 },
};

/// One image for `encodeAll`.
pub const Image = struct {
    pixels: PixelBuffer,
    /// The hotspot, for a cursor.
    hotspot: [2]u16 = .{ 0, 0 },
};

pub const Error = EncodeError || error{
    /// `encodeAll` was given no images, or more than 256.
    ImageCount,
};

/// The largest side an entry can have.
pub const max_side = 256;

/// ICO needs no work memory: 0, or null when a side is 0 or over 256.
pub fn workLen(options: Options, width: u32, height: u32) ?usize {
    _ = options;
    if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
    return 0;
}

/// Writes `src` as a one-entry ICO or CUR file.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: Options, work: []u8) Error!void {
    _ = work;
    return encodeAll(w, &.{.{ .pixels = src, .hotspot = options.hotspot }}, options);
}

fn entryLen(src: PixelBuffer) u32 {
    return 40 + (4 * src.width + maskRow(src.width)) * src.height;
}

fn maskRow(width: u32) u32 {
    return (width + 31) / 32 * 4;
}

/// Writes `images` as the entries of one ICO or CUR file, in order.
pub fn encodeAll(w: *Io.Writer, images: []const Image, options: Options) Error!void {
    if (images.len == 0 or images.len > 256) return error.ImageCount;
    for (images) |img| {
        try img.pixels.check();
        _ = workLen(options, img.pixels.width, img.pixels.height) orelse return error.ImageTooLarge;
    }
    var head: [6]u8 = undefined;
    std.mem.writeInt(u16, head[0..2], 0, .little);
    std.mem.writeInt(u16, head[2..4], if (options.cursor) 2 else 1, .little);
    std.mem.writeInt(u16, head[4..6], @intCast(images.len), .little);
    try w.writeAll(&head);
    var offset: u32 = 6 + 16 * @as(u32, @intCast(images.len));
    for (images) |img| {
        const p = img.pixels;
        var e: [16]u8 = @splat(0);
        e[0] = @truncate(p.width);
        e[1] = @truncate(p.height);
        const planes: u16, const bits: u16 = if (options.cursor) img.hotspot else .{ 1, 32 };
        std.mem.writeInt(u16, e[4..6], planes, .little);
        std.mem.writeInt(u16, e[6..8], bits, .little);
        std.mem.writeInt(u32, e[8..12], entryLen(p), .little);
        std.mem.writeInt(u32, e[12..16], offset, .little);
        try w.writeAll(&e);
        offset += entryLen(p);
    }
    for (images) |img| try writeEntry(w, img.pixels);
}

/// A BITMAPINFOHEADER entry: BGRA rows, then the mask's, bottom first.
fn writeEntry(w: *Io.Writer, src: PixelBuffer) Error!void {
    var info: [40]u8 = undefined;
    bmp.writeInfo(&info, 40, src.width, src.height * 2, .bgra32, 0, entryLen(src) - 40);
    try w.writeAll(&info);
    const row_len = maskRow(src.width);
    var mask: [max_side * max_side / 8]u8 = undefined;
    @memset(mask[0 .. row_len * src.height], 0);
    var buf: [max_side * 4]u8 = undefined;
    const conv: Converter = .init(.bgra8, src.format);
    var y = src.height;
    var k: usize = 0;
    while (y > 0) : (k += 1) {
        y -= 1;
        const row = buf[0 .. src.width * 4];
        conv.run(row, src.row(y), src.width);
        for (0..src.width) |x| {
            if (row[x * 4 + 3] == 0) mask[k * row_len + x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
        }
        try w.writeAll(row);
    }
    try w.writeAll(mask[0 .. row_len * src.height]);
}
