//! GIF encoding (GIF89a): stills with `encode`, animations with
//! `encodeAnimation`, from pixels in any `PixelFormat`.
//!
//! Each frame's pixels are converted to RGBA8 by `image.convert`; alpha
//! below 128 is transparent, and the rest opaque, its color kept. A frame
//! with at most 256 colors, counting transparency as one, is stored exactly,
//! with those colors in the order they first appear. A frame with more is
//! quantized (quantize.zig): `EncodeOptions.quantizer` picks at most 256
//! colors (255 when the frame has transparency), `refine` improves them
//! with k-means passes, and pixels map to the nearest, with `dither`'s
//! error diffusion or without.
//!
//! The first frame's palette is the global color table; a later frame
//! with another palette carries a local one. A transparent frame, and
//! every frame of an animation, has a graphic control extension with its
//! delay (in hundredths of a second, rounded), its disposal, and the
//! transparent index, the palette's last entry. An animation that plays
//! other than once has a NETSCAPE2.0 extension. Frames are interlaced when
//! `interlace` asks.
//!
//! GIF has one way to put a frame on the canvas: its transparent pixels
//! show what is beneath. With `crop`, `encodeAnimation` stores each frame
//! as only what it changes: it trims rows and columns that are transparent
//! or equal to the previous frame (when that frame covers the same region,
//! is left in place, and was stored exactly), and makes such pixels inside
//! the trimmed region transparent, which compresses better. A frame whose
//! disposal clears its region to the background is not trimmed, since
//! that would clear less.
//!
//! The work memory is a few rows, the LZW table, and, for an image of more
//! than 256 pixels, the quantizer's tables (about 2.6 MiB); with both
//! `interlace` and dithering, an image's worth of palette indices too, so
//! error diffusion can run top to bottom.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const shared = @import("../encode.zig");
const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const lzw = @import("lzw_encode.zig");
const quantize = @import("quantize.zig");

pub const Quantizer = quantize.Method;

pub const Dither = enum {
    none,
    /// Floyd-Steinberg error diffusion, serpentine.
    floyd_steinberg,
};

pub const EncodeOptions = struct {
    /// How a frame with more than 256 colors gets its palette.
    quantizer: Quantizer = .wu,
    /// k-means passes over the quantizer's palette.
    refine: u8 = 0,
    /// How a quantized frame's pixels map to its palette.
    dither: Dither = .floyd_steinberg,
    interlace: bool = false,
    /// An animation's play count: 0 plays forever.
    loop_count: u32 = 0,
    /// Store each frame of an animation as only what it changes.
    crop: bool = true,
};

pub const EncodeError = shared.Error || error{
    /// GIF cannot store an image without rows or columns.
    EmptyImage,
    /// An animation with no frames, or a frame that is empty or outside
    /// the canvas.
    BadFrame,
};

/// One frame of an animation.
pub const AnimationFrame = struct {
    /// The frame's pixels, in any format, the size of its region.
    pixels: PixelBuffer,
    /// The region's top left corner on the canvas.
    x: u32 = 0,
    y: u32 = 0,
    /// How long to show the frame, in flicks (`image.flicks_per_second`);
    /// stored in hundredths of a second, rounded, at most 65535.
    duration: u64 = 0,
    disposal: decode.Frame.Disposal = .none,
};

/// GIF's largest width or height.
const max_side = 0xffff;
/// Alpha below this is transparent.
const alpha_opaque = 128;
/// A color set key for transparency, apart from every RGB value.
const transparent_key: u32 = 1 << 24;
/// An image of at most this many pixels has at most 256 colors, so it is
/// never quantized.
const exact_pixels = 256;

/// The colors of a frame stored exactly, in the order they first appear,
/// with a hash from color to index.
const ColorSet = struct {
    keys: [512]u32,
    index: [512]u8,
    colors: [256]u32,
    len: u16,
    /// The last color added or found, for runs.
    last_key: u32,
    last_index: u8,

    fn reset(s: *ColorSet) void {
        @memset(&s.keys, std.math.maxInt(u32));
        s.len = 0;
        s.last_key = std.math.maxInt(u32);
    }

    /// The index of `key`, added if new; null when there would be more
    /// than 256.
    inline fn insert(s: *ColorSet, key: u32) ?u8 {
        if (key == s.last_key) return s.last_index;
        var slot = (key *% 0x9E3779B1) >> 23;
        while (true) : (slot = (slot + 1) & 511) {
            const k = s.keys[slot];
            if (k == key) break;
            if (k == std.math.maxInt(u32)) {
                if (s.len == 256) return null;
                s.keys[slot] = key;
                s.index[slot] = @intCast(s.len);
                s.colors[s.len] = key;
                s.len += 1;
                break;
            }
        }
        s.last_key = key;
        s.last_index = s.index[slot];
        return s.last_index;
    }
};

/// Where each part of the work memory is.
const Layout = struct {
    /// Two RGBA8 rows: the frame's, and the previous frame's.
    rows: usize,
    /// A row of indices, and whether each pixel is transparent.
    indices: usize,
    clear: usize,
    /// Two rows of dithering errors.
    errors: usize,
    table: usize,
    table_len: usize,
    set: usize,
    /// The quantizer, for images that may need it.
    quant: ?usize,
    lookup: usize,
    /// An image of indices, for interlaced dithering.
    image: ?usize,
    total: usize,

    fn of(options: EncodeOptions, width: u32, height: u32) ?Layout {
        if (width > max_side or height > max_side) return null;
        const w: usize = @max(width, 1);
        const pixels = @as(u64, width) * height;
        var l: Layout = undefined;
        var at: usize = 0;
        const Place = struct {
            fn place(cursor: *usize, size: usize, alignment: usize) usize {
                const start = std.mem.alignForward(usize, cursor.*, alignment);
                cursor.* = start + size;
                return start;
            }
        };
        l.rows = Place.place(&at, w * 8, 8);
        l.indices = Place.place(&at, w, 1);
        l.clear = Place.place(&at, w, 1);
        l.errors = Place.place(&at, (w + 2) * 3 * 2 * 2, 2);
        l.table_len = lzw.tableLen(pixels);
        l.table = Place.place(&at, l.table_len * 4, 4);
        l.set = Place.place(&at, @sizeOf(ColorSet), @alignOf(ColorSet));
        l.quant = null;
        l.lookup = 0;
        l.image = null;
        if (pixels > exact_pixels) {
            l.quant = Place.place(&at, @sizeOf(quantize.Work), @alignOf(quantize.Work));
            l.lookup = Place.place(&at, @sizeOf(quantize.Lookup), @alignOf(quantize.Lookup));
            if (options.interlace and options.dither != .none) l.image = Place.place(&at, @intCast(pixels), 1);
        }
        // Alignment the caller's slice may lack.
        l.total = at + 7;
        return l;
    }
};

/// The work memory `encode` and `encodeAnimation` need for a `width` by
/// `height` canvas, or null when GIF cannot store it.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    const l = Layout.of(options, width, height) orelse return null;
    return l.total;
}

/// Writes `src` as a GIF file.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    const frame: AnimationFrame = .{ .pixels = src };
    return write(w, src.width, src.height, (&frame)[0..1], false, options, work);
}

/// Writes `frames` as an animation on a `width` by `height` canvas.
pub fn encodeAnimation(
    w: *Io.Writer,
    width: u32,
    height: u32,
    frames: []const AnimationFrame,
    options: EncodeOptions,
    work: []u8,
) EncodeError!void {
    return write(w, width, height, frames, true, options, work);
}

/// The encoder's state across frames.
const State = struct {
    out: *Io.Writer,
    options: EncodeOptions,
    animated: bool,
    width: u32,
    height: u32,
    rows: []u8,
    indices: []u8,
    clear: []bool,
    errors: []i16,
    table: []u32,
    set: *ColorSet,
    quant: ?*quantize.Work,
    lookup: ?*quantize.Lookup,
    image: ?[]u8,
    global: quantize.Palette = .{},
    /// Whether the previous frame was stored exactly.
    prev_exact: bool = false,
};

fn write(
    w: *Io.Writer,
    width: u32,
    height: u32,
    frames: []const AnimationFrame,
    animated: bool,
    options: EncodeOptions,
    work: []u8,
) EncodeError!void {
    for (frames) |f| try f.pixels.check();
    if (width == 0 or height == 0) return error.EmptyImage;
    const l = Layout.of(options, width, height) orelse return error.ImageTooLarge;
    if (work.len < l.total) return error.WorkTooSmall;
    if (frames.len == 0) return error.BadFrame;
    for (frames) |f| {
        const p = f.pixels;
        if (p.width == 0 or p.height == 0) return error.BadFrame;
        if (@as(u64, f.x) + p.width > width or @as(u64, f.y) + p.height > height) return error.BadFrame;
    }
    const base = std.mem.alignForward(usize, @intFromPtr(work.ptr), 8) - @intFromPtr(work.ptr);
    const mem = work[base..];
    const wide: usize = width;
    var s: State = .{
        .out = w,
        .options = options,
        .animated = animated,
        .width = width,
        .height = height,
        .rows = mem[l.rows..][0 .. wide * 8],
        .indices = mem[l.indices..][0..wide],
        .clear = @ptrCast(mem[l.clear..][0..wide]),
        .errors = @alignCast(std.mem.bytesAsSlice(i16, mem[l.errors..][0 .. (wide + 2) * 12])),
        .table = @alignCast(std.mem.bytesAsSlice(u32, mem[l.table..][0 .. l.table_len * 4])),
        .set = @ptrCast(@alignCast(mem[l.set..][0..@sizeOf(ColorSet)])),
        .quant = if (l.quant) |q| @ptrCast(@alignCast(mem[q..][0..@sizeOf(quantize.Work)])) else null,
        .lookup = if (l.quant != null) @ptrCast(@alignCast(mem[l.lookup..][0..@sizeOf(quantize.Lookup)])) else null,
        .image = if (l.image) |i| mem[i..][0 .. wide * height] else null,
    };
    for (frames, 0..) |f, i| {
        const prev: ?AnimationFrame = if (i > 0) frames[i - 1] else null;
        try writeFrame(&s, f, prev, i == 0);
    }
    try w.writeByte(0x3b);
}

/// A frame's plan: the region stored, how its pixels become indices, and
/// its palette.
const Plan = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    /// Pixels equal to the previous frame's become transparent.
    skip: bool,
    /// Stored exactly, with the color set's indices.
    exact: bool,
    transparent: ?u8,
    palette: quantize.Palette,
};

/// What each pixel of a row is: transparent, or a color.
fn classify(rgba: []const u8, prev: ?[]const u8, clear: []bool) void {
    for (clear, 0..) |*c, x| {
        const p = rgba[x * 4 ..][0..4];
        c.* = p[3] < alpha_opaque;
        if (prev) |q| {
            const o = q[x * 4 ..][0..4];
            if (!c.* and o[3] >= alpha_opaque and std.mem.eql(u8, p[0..3], o[0..3])) c.* = true;
        }
    }
}

fn keyOf(p: *const [4]u8) u32 {
    return @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16;
}

/// GIF's color table size field: the table holds 2^(field + 1) entries.
fn sizeField(len: u16) u3 {
    var f: u3 = 0;
    while ((@as(u16, 2) << f) < len) f += 1;
    return f;
}

fn samePalette(a: *const quantize.Palette, b: *const quantize.Palette) bool {
    if (a.len != b.len) return false;
    for (a.colors[0..a.len], b.colors[0..b.len]) |x, y| {
        if (!std.mem.eql(u8, &x, &y)) return false;
    }
    return true;
}

const Rows = struct {
    src: PixelBuffer,
    prev: ?PixelBuffer,
    cur_conv: Converter,
    prev_conv: Converter,
    cur: []u8,
    old: []u8,

    /// Row `y` of the frame, and of the previous frame when skipping, as
    /// RGBA8.
    fn get(r: *const Rows, y: u32) struct { []const u8, ?[]const u8 } {
        const n = r.src.width;
        const cur: []const u8 = if (r.src.format == .rgba8) r.src.row(y) else blk: {
            r.cur_conv.run(r.cur[0 .. n * 4], r.src.row(y), n);
            break :blk r.cur[0 .. n * 4];
        };
        const p = r.prev orelse return .{ cur, null };
        const old: []const u8 = if (p.format == .rgba8) p.row(y) else blk: {
            r.prev_conv.run(r.old[0 .. n * 4], p.row(y), n);
            break :blk r.old[0 .. n * 4];
        };
        return .{ cur, old };
    }
};

fn rowsOf(s: *State, src: PixelBuffer, prev: ?PixelBuffer) Rows {
    const wide: usize = s.width;
    return .{
        .src = src,
        .prev = prev,
        .cur_conv = .init(.rgba8, src.format),
        .prev_conv = .init(.rgba8, if (prev) |p| p.format else .rgba8),
        .cur = s.rows[0 .. wide * 4],
        .old = s.rows[wide * 4 .. wide * 8],
    };
}

/// The interlaced row order's passes: first row and step.
const passes = [4][2]u32{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };

fn delayOf(duration: u64) u16 {
    const cs = (duration + 3_528_000) / 7_056_000;
    return @intCast(@min(cs, 0xffff));
}

fn writeFrame(s: *State, f: AnimationFrame, prev_frame: ?AnimationFrame, first: bool) EncodeError!void {
    const o = s.options;
    // What the frame may leave out.
    const may_skip = s.animated and o.crop and s.prev_exact and if (prev_frame) |p|
        p.disposal == .none and p.x == f.x and p.y == f.y and
            p.pixels.width == f.pixels.width and p.pixels.height == f.pixels.height
    else
        false;
    const may_trim = s.animated and o.crop and f.disposal != .background;
    const full = f.pixels;
    const prev_pixels: ?PixelBuffer = if (may_skip) prev_frame.?.pixels else null;

    // The region: everything not left out, or the whole frame.
    var x0: u32 = 0;
    var y0: u32 = 0;
    var x1: u32 = full.width;
    var y1: u32 = full.height;
    if (may_trim) {
        const rows = rowsOf(s, full, prev_pixels);
        x0 = full.width;
        y0 = full.height;
        x1 = 0;
        y1 = 0;
        for (0..full.height) |yy| {
            const y: u32 = @intCast(yy);
            const cur, const old = rows.get(y);
            const clear = s.clear[0..full.width];
            classify(cur, old, clear);
            const first_kept = std.mem.findScalar(bool, clear, false) orelse continue;
            const last_kept = std.mem.findScalarLast(bool, clear, false).?;
            x0 = @min(x0, @as(u32, @intCast(first_kept)));
            x1 = @max(x1, @as(u32, @intCast(last_kept + 1)));
            if (y0 > y) y0 = y;
            y1 = y + 1;
        }
        if (x1 == 0) {
            // Nothing changes: one transparent pixel.
            x0 = 0;
            y0 = 0;
            x1 = 1;
            y1 = 1;
        }
    }
    const region = full.sub(x0, y0, x1 - x0, y1 - y0);
    const prev_region: ?PixelBuffer = if (prev_pixels) |p| p.sub(x0, y0, x1 - x0, y1 - y0) else null;

    var plan: Plan = .{
        .x = f.x + x0,
        .y = f.y + y0,
        .width = region.width,
        .height = region.height,
        .skip = may_skip,
        .exact = true,
        .transparent = null,
        .palette = .{},
    };
    // Stored exactly if the colors fit, skipping if that fits, otherwise
    // without; quantized, skipping, if neither fits.
    if (!countColors(s, region, if (may_skip) prev_region else null)) {
        if (may_skip and countColors(s, region, null)) {
            plan.skip = false;
        } else {
            plan.exact = false;
        }
    }
    const old_region = if (plan.skip) prev_region else null;
    if (plan.exact) {
        const set = s.set;
        plan.palette.len = 0;
        for (set.colors[0..set.len]) |k| {
            if (k == transparent_key) plan.transparent = @intCast(plan.palette.len);
            plan.palette.colors[plan.palette.len] = .{ @truncate(k), @truncate(k >> 8), @truncate(k >> 16) };
            plan.palette.len += 1;
        }
    } else {
        quantizeFrame(s, region, old_region, &plan);
    }
    // The transparent entry, never shown, repeats a color, so every entry
    // of the table is one of the frame's colors.
    if (plan.transparent) |t| plan.palette.colors[t] = fillColor(&plan);

    if (first) try header(s, &plan);
    try control(s, f, plan.transparent);
    try descriptor(s, &plan, first);
    try writePixels(s, region, old_region, &plan);
    s.prev_exact = plan.exact;
}

/// Counts the colors of `region`, pixels equal to `prev`'s counting as
/// transparent, into the color set; false when there are more than 256.
fn countColors(s: *State, region: PixelBuffer, prev: ?PixelBuffer) bool {
    const set = s.set;
    set.reset();
    const rows = rowsOf(s, region, prev);
    const clear = s.clear[0..region.width];
    for (0..region.height) |yy| {
        const cur, const old = rows.get(@intCast(yy));
        classify(cur, old, clear);
        for (clear, 0..) |c, x| {
            const key = if (c) transparent_key else keyOf(cur[x * 4 ..][0..4]);
            _ = set.insert(key) orelse return false;
        }
    }
    return true;
}

fn quantizeFrame(s: *State, region: PixelBuffer, prev: ?PixelBuffer, plan: *Plan) void {
    const h: quantize.Histogram = .{ .work = s.quant.? };
    h.clear();
    const rows = rowsOf(s, region, prev);
    const clear = s.clear[0..region.width];
    var any_clear = false;
    for (0..region.height) |yy| {
        const cur, const old = rows.get(@intCast(yy));
        classify(cur, old, clear);
        for (clear, 0..) |c, x| {
            if (c) {
                any_clear = true;
                continue;
            }
            h.add(cur[x * 4], cur[x * 4 + 1], cur[x * 4 + 2]);
        }
    }
    // More than 256 colors, so at least 256 opaque pixels.
    const max: u16 = if (any_clear) 255 else 256;
    h.palette(s.options.quantizer, max, s.options.refine, &plan.palette);
    s.lookup.?.init(&plan.palette);
    if (any_clear) {
        plan.transparent = @intCast(plan.palette.len);
        plan.palette.len += 1;
    }
}

/// A color of the frame's for entries that show none: the first that is
/// not the transparent entry, or black when there is none.
fn fillColor(plan: *const Plan) [3]u8 {
    for (plan.palette.colors[0..plan.palette.len], 0..) |c, i| {
        if (plan.transparent == null or plan.transparent.? != i) return c;
    }
    return .{ 0, 0, 0 };
}

/// Writes the plan's palette as a color table, padded to a power of two
/// with a color of its own.
fn writeTable(s: *State, plan: *const Plan) Io.Writer.Error!void {
    const palette = &plan.palette;
    const entries = @as(usize, 2) << sizeField(palette.len);
    var buf: [768]u8 = undefined;
    const fill = fillColor(plan);
    for (0..entries) |i| buf[i * 3 ..][0..3].* = if (i < palette.len) palette.colors[i] else fill;
    try s.out.writeAll(buf[0 .. entries * 3]);
}

fn header(s: *State, plan: *const Plan) EncodeError!void {
    var h: [13]u8 = undefined;
    h[0..6].* = "GIF89a".*;
    std.mem.writeInt(u16, h[6..8], @intCast(s.width), .little);
    std.mem.writeInt(u16, h[8..10], @intCast(s.height), .little);
    // A global color table, 8 bits of color resolution.
    h[10] = 0x80 | 0x70 | @as(u8, sizeField(plan.palette.len));
    h[11] = 0;
    h[12] = 0;
    try s.out.writeAll(&h);
    s.global = plan.palette;
    try writeTable(s, plan);
    if (s.animated and s.options.loop_count != 1) {
        const repeats: u16 = if (s.options.loop_count == 0) 0 else @intCast(@min(s.options.loop_count - 1, 0xffff));
        var ext = "\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00".*;
        std.mem.writeInt(u16, ext[16..18], repeats, .little);
        try s.out.writeAll(&ext);
    }
}

fn control(s: *State, f: AnimationFrame, transparent: ?u8) EncodeError!void {
    if (!s.animated and transparent == null) return;
    const disposal: u8 = if (!s.animated) 0 else switch (f.disposal) {
        .none => 1,
        .background => 2,
        .previous => 3,
    };
    const flags = disposal << 2 | @intFromBool(transparent != null);
    var ext: [8]u8 = .{ 0x21, 0xf9, 4, flags, 0, 0, transparent orelse 0, 0 };
    std.mem.writeInt(u16, ext[4..6], if (s.animated) delayOf(f.duration) else 0, .little);
    try s.out.writeAll(&ext);
}

fn descriptor(s: *State, plan: *const Plan, first: bool) EncodeError!void {
    var d: [10]u8 = undefined;
    d[0] = 0x2c;
    std.mem.writeInt(u16, d[1..3], @intCast(plan.x), .little);
    std.mem.writeInt(u16, d[3..5], @intCast(plan.y), .little);
    std.mem.writeInt(u16, d[5..7], @intCast(plan.width), .little);
    std.mem.writeInt(u16, d[7..9], @intCast(plan.height), .little);
    const local = !first and !samePalette(&plan.palette, &s.global);
    const table: u8 = if (local) 0x80 | @as(u8, sizeField(plan.palette.len)) else 0;
    d[9] = @as(u8, if (s.options.interlace) 0x40 else 0) | table;
    try s.out.writeAll(&d);
    if (local) try writeTable(s, plan);
}

/// Maps the region's pixels to indices and compresses them, in the file's
/// row order.
fn writePixels(s: *State, region: PixelBuffer, prev: ?PixelBuffer, plan: *const Plan) EncodeError!void {
    const min_bits: u4 = @max(2, @as(u4, sizeField(plan.palette.len)) + 1);
    var z: lzw.Encoder = try .init(s.out, s.table[0..lzw.tableLen(@as(u64, plan.width) * plan.height)], min_bits);
    const rows = rowsOf(s, region, prev);
    const n = region.width;
    const indices = s.indices[0..n];
    const clear = s.clear[0..n];
    const dither = !plan.exact and s.options.dither != .none;
    if (dither) {
        var d: quantize.Ditherer = .init(s.errors, n);
        if (s.image) |img| if (s.options.interlace) {
            for (0..region.height) |yy| {
                const cur, const old = rows.get(@intCast(yy));
                classify(cur, old, clear);
                d.row(s.lookup.?, &plan.palette, cur, clear, plan.transparent orelse 0, img[yy * n ..][0..n]);
            }
            var it = order(region.height, true);
            while (it.next()) |y| try z.write(img[@as(usize, y) * n ..][0..n]);
            return z.finish();
        };
        for (0..region.height) |yy| {
            const cur, const old = rows.get(@intCast(yy));
            classify(cur, old, clear);
            d.row(s.lookup.?, &plan.palette, cur, clear, plan.transparent orelse 0, indices);
            try z.write(indices);
        }
        return z.finish();
    }
    var it = order(region.height, s.options.interlace);
    while (it.next()) |y| {
        const cur, const old = rows.get(y);
        classify(cur, old, clear);
        if (plan.exact) {
            const set = s.set;
            for (indices, clear, 0..) |*i, c, x| {
                i.* = set.insert(if (c) transparent_key else keyOf(cur[x * 4 ..][0..4])).?;
            }
        } else {
            const l = s.lookup.?;
            const t = plan.transparent orelse 0;
            for (indices, clear, 0..) |*i, c, x| {
                const p = cur[x * 4 ..][0..4];
                i.* = if (c) t else l.find(p[0], p[1], p[2]);
            }
        }
        try z.write(indices);
    }
    try z.finish();
}

const Order = struct {
    height: u32,
    interlace: bool,
    pass: u3 = 0,
    y: u32 = 0,

    fn next(o: *Order) ?u32 {
        if (!o.interlace) {
            if (o.y >= o.height) return null;
            o.y += 1;
            return o.y - 1;
        }
        while (o.pass < 4) {
            if (o.y < o.height) {
                const y = o.y;
                o.y += passes[o.pass][1];
                return y;
            }
            o.pass += 1;
            if (o.pass < 4) o.y = passes[o.pass][0];
        }
        return null;
    }
};

fn order(height: u32, interlace: bool) Order {
    return .{ .height = height, .interlace = interlace };
}

// Tests: files go back through this package's decoder, frames composited
// as a player does, disposal applied before the next frame.

const Decoder = @import("Decoder.zig");

/// The canvas after each frame of `file`, as RGBA8.
const Decoded = struct { config: decode.Config, canvases: [][]u8, frames: []decode.Frame };

fn decodeAll(gpa: std.mem.Allocator, file: []const u8) !Decoded {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    const len = @as(usize, config.width) * config.height * 4;
    const canvas = try gpa.alloc(u8, len);
    defer gpa.free(canvas);
    const saved = try gpa.alloc(u8, len);
    defer gpa.free(saved);
    @memset(canvas, 0);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    var canvases: std.ArrayList([]u8) = .empty;
    var frames: std.ArrayList(decode.Frame) = .empty;
    const dst = try PixelBuffer.init(canvas, .rgba8, config.width, config.height);
    while (try d.decodeFrameConfig()) |f| {
        if (f.disposal == .previous) @memcpy(saved, canvas);
        _ = (try d.decodeFrame(dst, work)).?;
        try canvases.append(gpa, try gpa.dupe(u8, canvas));
        try frames.append(gpa, f);
        const region = dst.sub(f.x, f.y, f.width, f.height);
        switch (f.disposal) {
            .none => {},
            .background => for (0..f.height) |y| @memset(region.row(@intCast(y)), 0),
            .previous => @memcpy(canvas, saved),
        }
    }
    return .{ .config = config, .canvases = try canvases.toOwnedSlice(gpa), .frames = try frames.toOwnedSlice(gpa) };
}

fn freeAll(gpa: std.mem.Allocator, all: anytype) void {
    for (all.canvases) |c| gpa.free(c);
    gpa.free(all.canvases);
    gpa.free(all.frames);
}

/// RGBA8 as GIF stores it: alpha below 128 transparent black, the rest
/// opaque.
fn binarize(rgba: []u8) void {
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        if (rgba[i + 3] < alpha_opaque) @memset(rgba[i..][0..4], 0) else rgba[i + 3] = 255;
    }
}

fn encodeAlloc(gpa: std.mem.Allocator, src: PixelBuffer, options: EncodeOptions) ![]u8 {
    const work = try gpa.alloc(u8, workLen(options, src.width, src.height).?);
    defer gpa.free(work);
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try encode(&aw.writer, src, options, work);
    return aw.toOwnedSlice();
}

test "a still with at most 256 colors comes back exactly, from any format, interlaced or not" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    for ([_]u32{ 1, 7, 33, 100 }) |side_len| {
        const n = @as(usize, side_len) * side_len;
        const rgba = try gpa.alloc(u8, n * 4);
        defer gpa.free(rgba);
        // 200 colors, some transparent pixels with color under them.
        var colors: [200][4]u8 = undefined;
        for (&colors) |*c| random.bytes(c);
        for (0..n) |i| rgba[i * 4 ..][0..4].* = colors[random.uintLessThan(usize, 200)];
        const want = try gpa.dupe(u8, rgba);
        defer gpa.free(want);
        binarize(want);
        for ([_]PixelFormat{ .rgba8, .bgra8, .rgba16, .rgba_f32 }) |format| {
            const len = PixelBuffer.len(format, side_len, side_len).?;
            const pixels_ = try gpa.alloc(u8, len);
            defer gpa.free(pixels_);
            const src = try PixelBuffer.init(pixels_, format, side_len, side_len);
            Converter.init(format, .rgba8).run(pixels_, rgba, n);
            for ([_]bool{ false, true }) |interlace| {
                const file = try encodeAlloc(gpa, src, .{ .interlace = interlace });
                defer gpa.free(file);
                const all = try decodeAll(gpa, file);
                defer freeAll(gpa, all);
                try testing.expectEqual(1, all.canvases.len);
                try testing.expectEqualSlices(u8, want, all.canvases[0]);
            }
        }
    }
}

test "a still with more colors is quantized by each method, with and without dithering" {
    const gpa = testing.allocator;
    const w = 64;
    const h = 48;
    const rgb = try gpa.alloc(u8, w * h * 3);
    defer gpa.free(rgb);
    // A smooth gradient: thousands of colors.
    for (0..h) |y| for (0..w) |x| {
        rgb[(y * w + x) * 3 ..][0..3].* = .{ @intCast(x * 4), @intCast(y * 5), @intCast((x + y) * 2) };
    };
    const src = try PixelBuffer.init(rgb, .rgb8, w, h);
    const quantizers = [_]Quantizer{ .wu, .median_cut, .octree };
    for (quantizers) |q| for ([_]Dither{ .none, .floyd_steinberg }) |d| for ([_]bool{ false, true }) |interlace| {
        const file = try encodeAlloc(gpa, src, .{ .quantizer = q, .dither = d, .refine = 1, .interlace = interlace });
        defer gpa.free(file);
        const all = try decodeAll(gpa, file);
        defer freeAll(gpa, all);
        // Close to the source: a mean squared error of a few units.
        var sq: f64 = 0;
        for (0..w * h) |i| for (0..3) |c| {
            const e = @as(f64, @floatFromInt(all.canvases[0][i * 4 + c])) - @as(f64, @floatFromInt(rgb[i * 3 + c]));
            sq += e * e;
        };
        try testing.expect(sq / (w * h * 3) < 30);
        for (0..w * h) |i| try testing.expectEqual(255, all.canvases[0][i * 4 + 3]);
    };
}

test "an animation keeps every frame, crops to what changes, and stores its timing" {
    const gpa = testing.allocator;
    const w = 40;
    const h = 30;
    var bufs: [4][w * h * 4]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(5);
    const random = prng.random();
    for (&bufs[0]) |*b| b.* = random.uintLessThan(u8, 4) * 60 + 15;
    for (0..w * h) |i| bufs[0][i * 4 + 3] = 255;
    // Frame 1 changes a small square; frame 2 changes nothing; frame 3
    // makes a corner transparent and is cleared afterwards.
    bufs[1] = bufs[0];
    for (5..9) |y| for (10..20) |x| {
        bufs[1][(y * w + x) * 4 ..][0..3].* = .{ 1, 2, 3 };
    };
    bufs[2] = bufs[1];
    bufs[3] = bufs[2];
    for (0..5) |y| for (0..5) |x| {
        bufs[3][(y * w + x) * 4 + 3] = 0;
    };
    var frames: [4]AnimationFrame = undefined;
    for (&frames, 0..) |*f, i| f.* = .{
        .pixels = try PixelBuffer.init(&bufs[i], .rgba8, w, h),
        .duration = 7_056_000 * (i + 1),
    };
    frames[3].disposal = .background;
    const options: EncodeOptions = .{ .loop_count = 3 };
    const work = try gpa.alloc(u8, workLen(options, w, h).?);
    defer gpa.free(work);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try encodeAnimation(&aw.writer, w, h, &frames, options, work);
    const all = try decodeAll(gpa, aw.written());
    defer freeAll(gpa, all);
    try testing.expectEqual(3, all.config.loop_count);
    try testing.expectEqual(4, all.canvases.len);
    for (0..3) |i| try testing.expectEqualSlices(u8, &bufs[i], all.canvases[i]);
    // Frame 3 shows the transparent corner over frame 2's pixels.
    try testing.expectEqualSlices(u8, &bufs[2], all.canvases[3]);
    const f1 = all.frames[1];
    const got: [5]u64 = .{ f1.x, f1.y, f1.width, f1.height, f1.duration };
    try testing.expectEqual([5]u64{ 10, 5, 10, 4, 2 * 7_056_000 }, got);
    try testing.expectEqual(1, all.frames[2].width * all.frames[2].height);
    try testing.expectEqual(4 * 7_056_000, all.frames[3].duration);
    try testing.expectEqual(decode.Frame.Disposal.background, all.frames[3].disposal);
    try testing.expectEqual(w, all.frames[3].width);
}

test "the contract's errors" {
    const gpa = testing.allocator;
    var px: [16]u8 = @splat(0);
    const src = try PixelBuffer.init(&px, .rgba8, 2, 2);
    const need = workLen(.{}, 2, 2).?;
    const work = try gpa.alloc(u8, need);
    defer gpa.free(work);
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expectError(error.WorkTooSmall, encode(&w, src, .{}, work[0 .. need - 1]));
    try testing.expectError(error.EmptyImage, encode(&w, try PixelBuffer.init(&px, .rgba8, 0, 2), .{}, work));
    try testing.expectEqual(null, workLen(.{}, 65536, 1));
    try testing.expectError(error.BadFrame, encodeAnimation(&w, 2, 2, &.{}, .{}, work));
    try testing.expectError(error.BadFrame, encodeAnimation(&w, 2, 2, &.{.{ .pixels = src, .x = 1 }}, .{}, work));
}
