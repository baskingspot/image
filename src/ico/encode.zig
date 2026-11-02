//! The ICO and CUR encoder: each image a 32-bit BMP entry with straight
//! alpha and an AND mask set where alpha is 0, for readers that ignore
//! alpha, or a PNG entry, which is what 256 by 256 icons hold (`Payload`,
//! plan.md decision 17). src/encode.zig has the contract; `encodeAll`
//! writes several images, as an icon's sizes.
//!
//! The directory gives every entry's length before the first entry, and a
//! writer cannot go back, so each PNG entry is encoded twice: once into a
//! discarding writer to measure it, and once to write it. `png.encode`'s
//! bytes depend only on the pixels, the options, and the work memory's
//! length, so the two agree.

const std = @import("std");
const Io = std.Io;

const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const EncodeError = @import("../encode.zig").Error;
const bmp = @import("../bmp/encode.zig");
const png = @import("../png/encode.zig");

/// How an entry stores its pixels.
pub const Payload = enum {
    /// PNG for a 256 by 256 image, BMP otherwise, as Windows' own icons
    /// are made.
    auto,
    /// A 32-bit BMP and its mask, which every reader takes.
    bmp,
    /// A PNG of the image's own channels at 8 bits, reduced to the
    /// smallest color type that holds them, which Windows Vista and later
    /// read.
    png,

    fn of(p: Payload, width: u32, height: u32) Payload {
        if (p != .auto) return p;
        return if (width == max_side and height == max_side) .png else .bmp;
    }
};

pub const Options = struct {
    /// Write a CUR, whose entries have hotspots, rather than an ICO.
    cursor: bool = false,
    /// `encode`'s image's hotspot, for a cursor.
    hotspot: [2]u16 = .{ 0, 0 },
    /// `encode`'s image's payload; `encodeAll` takes each image's.
    payload: Payload = .auto,
};

/// One image for `encodeAll`.
pub const Image = struct {
    pixels: PixelBuffer,
    /// The hotspot, for a cursor.
    hotspot: [2]u16 = .{ 0, 0 },
    payload: Payload = .auto,
};

pub const Error = EncodeError || error{
    /// `encodeAll` was given no images, or more than 256.
    ImageCount,
};

/// The largest side an entry can have.
pub const max_side = 256;

/// The work memory for an image with `options.payload`: none for a BMP
/// entry, and `png.workLen` with the default options for a PNG entry (about
/// 850 KiB at 256 by 256). Null when a side is 0 or over 256.
pub fn workLen(options: Options, width: u32, height: u32) ?usize {
    if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
    return switch (options.payload.of(width, height)) {
        .auto => unreachable,
        .bmp => 0,
        .png => png.workLen(png_options, width, height),
    };
}

/// PNG entries are written with the PNG encoder's defaults, but at most 8
/// bits a sample, as icons are and as every icon reader takes them
/// (plan.md decision 38).
const png_options: png.EncodeOptions = .{ .max_depth = .@"8" };

/// Writes `src` as a one-entry ICO or CUR file.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: Options, work: []u8) Error!void {
    return encodeAll(w, &.{.{ .pixels = src, .hotspot = options.hotspot, .payload = options.payload }}, options, work);
}

fn bmpLen(src: PixelBuffer) u32 {
    return 40 + (4 * src.width + maskRow(src.width)) * src.height;
}

/// An entry's length in the file: a PNG entry encoded to measure it.
fn entryLen(img: Image, work: []u8) Error!u32 {
    const p = img.pixels;
    if (img.payload.of(p.width, p.height) == .bmp) return bmpLen(p);
    var counter: Io.Writer.Discarding = .init(&.{});
    try writePng(&counter.writer, p, work);
    return std.math.cast(u32, counter.fullCount()) orelse error.ImageTooLarge;
}

fn writePng(w: *Io.Writer, src: PixelBuffer, work: []u8) Error!void {
    png.encode(w, src, png_options, work) catch |e| return switch (e) {
        // A side of 1 to 256 and no metadata: PNG takes every image.
        error.EmptyImage, error.BadFrame, error.BadMetadata => unreachable,
        else => |shared| shared,
    };
}

fn maskRow(width: u32) u32 {
    return (width + 31) / 32 * 4;
}

/// Writes `images` as the entries of one ICO or CUR file, in order. `work`
/// holds at least `workLen` for each image with its payload: the largest
/// PNG entry's.
pub fn encodeAll(w: *Io.Writer, images: []const Image, options: Options, work: []u8) Error!void {
    if (images.len == 0 or images.len > 256) return error.ImageCount;
    for (images) |img| {
        try img.pixels.check();
        var o = options;
        o.payload = img.payload;
        const need = workLen(o, img.pixels.width, img.pixels.height) orelse return error.ImageTooLarge;
        if (work.len < need) return error.WorkTooSmall;
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
        const len = try entryLen(img, work);
        std.mem.writeInt(u32, e[8..12], len, .little);
        std.mem.writeInt(u32, e[12..16], offset, .little);
        try w.writeAll(&e);
        offset = std.math.add(u32, offset, len) catch return error.ImageTooLarge;
    }
    for (images) |img| {
        const p = img.pixels;
        if (img.payload.of(p.width, p.height) == .png) try writePng(w, p, work) else try writeEntry(w, p);
    }
}

/// A BITMAPINFOHEADER entry: BGRA rows, then the mask's, bottom first.
fn writeEntry(w: *Io.Writer, src: PixelBuffer) Error!void {
    var info: [40]u8 = undefined;
    bmp.writeInfo(&info, 40, src.width, src.height * 2, .bgra32, 0, bmpLen(src) - 40);
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

const testing = std.testing;
const PngDecoder = @import("../png/Decoder.zig");
const Decoder = @import("Decoder.zig").Generic(PngDecoder);
const convertBuffer = @import("../convert.zig").convertBuffer;

test "256 by 256 entries are PNG by default, smaller ones BMP, and each reads back, picked or in order" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // An icon of four colors in a 16-bit format, whose low bytes only 16
    // bits hold, so only the 8-bit cap makes it the palette PNG it reduces
    // to (alpha 0xff37 narrows to opaque); and a smaller one.
    const big_px = try gpa.alloc(u8, 256 * 256 * 8);
    defer gpa.free(big_px);
    for (0..256 * 256) |i| {
        const c: u16 = random.uintLessThan(u8, 4);
        const rgba = [4]u16{ c * 80, 255 - c * 60, c * 7, 255 };
        for (rgba, 0..) |v, k| std.mem.writeInt(u16, big_px[i * 8 + k * 2 ..][0..2], v * 0x100 + 0x37, .little);
    }
    const big: PixelBuffer = try .init(big_px, .rgba16, 256, 256);
    var small_px: [32 * 16 * 4]u8 = undefined;
    random.bytes(&small_px);
    const small: PixelBuffer = try .init(&small_px, .rgba8, 32, 16);

    for ([_]Payload{ .auto, .bmp, .png }) |payload| {
        const images = [_]Image{
            .{ .pixels = big, .hotspot = .{ 3, 4 }, .payload = payload },
            .{ .pixels = small, .hotspot = .{ 5, 6 }, .payload = payload },
        };
        var need: usize = 0;
        for (images) |img| {
            const p = img.pixels;
            need = @max(need, workLen(.{ .payload = img.payload }, p.width, p.height).?);
        }
        try testing.expectEqual(payload != .bmp, need > 0);
        const work = try gpa.alloc(u8, need);
        defer gpa.free(work);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        if (need > 0) {
            const short = encodeAll(&out.writer, &images, .{ .cursor = true }, work[1..]);
            try testing.expectError(error.WorkTooSmall, short);
        }
        out.clearRetainingCapacity();
        try encodeAll(&out.writer, &images, .{ .cursor = true }, work);
        const file = out.written();

        for (images, 0..) |img, i| {
            var r: Io.Reader = .fixed(file);
            var d: Decoder = .init(&r, .{ .entry = @intCast(i) });
            const config = try d.decodeConfig();
            const e = d.entry(@intCast(i));
            try testing.expect(d.isCursor());
            try testing.expectEqual(img.hotspot, [2]u16{ e.planes, e.bits });
            try testing.expectEqual(e.offset + e.size, if (i == 0) d.entry(1).offset else file.len);
            const is_png = std.mem.startsWith(u8, file[e.offset..], "\x89PNG");
            try testing.expectEqual(img.payload.of(img.pixels.width, img.pixels.height) == .png, is_png);
            // PNG entries are at most 8 bits a sample, from 16-bit sources
            // too: IHDR's depth.
            if (is_png) try testing.expect(file[e.offset + 24] <= 8);
            // A BMP is 8-bit BGRA; a PNG is what it reduced to.
            try testing.expectEqual(!is_png, config.native == .bgra8);
            const len = PixelBuffer.len(config.native, config.width, config.height).?;
            const got_px = try gpa.alloc(u8, len);
            defer gpa.free(got_px);
            const want_px = try gpa.alloc(u8, len);
            defer gpa.free(want_px);
            const got: PixelBuffer = try .init(got_px, config.native, config.width, config.height);
            const want: PixelBuffer = try .init(want_px, config.native, config.width, config.height);
            const dwork = try gpa.alloc(u8, config.work_len);
            defer gpa.free(dwork);
            _ = (try d.decodeFrame(got, dwork)).?;
            try convertBuffer(want, img.pixels);
            try testing.expectEqualSlices(u8, want_px, got_px);
        }
        if (payload == .auto) {
            // The palette PNG is far smaller than the BMP would be.
            try testing.expect(file.len < bmpLen(big) / 8);
        }

        // Every entry, PNG and BMP, straight through without a seeker.
        var r: Io.Reader = .fixed(file);
        var d: Decoder = .init(&r, .{});
        const config = try d.decodeConfig();
        try testing.expectEqual(.{ 256, 256, 2 }, .{ config.width, config.height, config.frame_count.? });
        const canvas_px = try gpa.alloc(u8, 256 * 256 * 4);
        defer gpa.free(canvas_px);
        const want_px = try gpa.alloc(u8, 256 * 256 * 4);
        defer gpa.free(want_px);
        const canvas: PixelBuffer = try .init(canvas_px, .bgra8, 256, 256);
        const dwork = try gpa.alloc(u8, config.work_len);
        defer gpa.free(dwork);
        for (images) |img| {
            const p = img.pixels;
            const f = (try d.decodeFrame(canvas, dwork)).?;
            try testing.expectEqual(.{ p.width, p.height }, .{ f.width, f.height });
            const want: PixelBuffer = try .init(want_px[0 .. p.width * p.height * 4], .bgra8, p.width, p.height);
            try convertBuffer(want, p);
            for (0..p.height) |y| {
                try testing.expectEqualSlices(u8, want.row(@intCast(y)), canvas.row(@intCast(y))[0 .. p.width * 4]);
            }
        }
        try testing.expectEqual(null, try d.decodeFrame(canvas, dwork));
    }
}
