//! TIFF's structure (TIFF 6.0, sections 2 and 8; BigTIFF): the header, the
//! image file directories (IFDs), and the fields this decoder reads, with
//! the defaults the specification gives. `Input` is the byte-level reader
//! every part of the decoder shares: it counts the bytes it has consumed,
//! reads integers in the file's byte order, and moves to an offset forward
//! by skipping or back through the caller's seeker.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Endian = std.builtin.Endian;

const decode = @import("../decode.zig");

pub const Error = decode.Error || error{
    /// An offset lies before the reader's position and there is no seeker.
    DataBehind,
};

pub fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

pub const Input = struct {
    r: *Io.Reader,
    seeker: ?decode.Seeker,
    /// The offset of the reader's next byte in the input.
    pos: u64 = 0,
    endian: Endian = .little,
    big: bool = false,

    pub fn takeArray(in: *Input, comptime n: usize) Error!*[n]u8 {
        const b = in.r.takeArray(n) catch |e| return mapRead(e);
        in.pos += n;
        return b;
    }

    pub fn read(in: *Input, dst: []u8) Error!void {
        in.r.readSliceAll(dst) catch |e| return mapRead(e);
        in.pos += dst.len;
    }

    pub fn int(in: *Input, comptime T: type) Error!T {
        return std.mem.readInt(T, try in.takeArray(@sizeOf(T)), in.endian);
    }

    /// An offset or count: four bytes in classic TIFF, eight in BigTIFF.
    pub fn word(in: *Input) Error!u64 {
        return if (in.big) try in.int(u64) else try in.int(u32);
    }

    /// Moves to `offset`: forward by skipping, back with the seeker.
    pub fn goTo(in: *Input, offset: u64) Error!void {
        if (offset >= in.pos) {
            // In steps a reader can add to its position without overflow.
            var left = offset - in.pos;
            while (left > 0) {
                const n: usize = @intCast(@min(left, 1 << 30));
                in.r.discardAll(n) catch |e| return mapRead(e);
                left -= n;
                in.pos += n;
            }
            return;
        }
        const s = in.seeker orelse return error.DataBehind;
        try s.seek(s.context, offset);
        in.pos = offset;
    }
};

pub const Header = struct {
    endian: Endian,
    big: bool,
    first: u64,
};

/// Reads the 8-byte classic or 16-byte BigTIFF header.
pub fn readHeader(in: *Input) Error!Header {
    const h = try in.takeArray(4);
    const endian: Endian = if (std.mem.eql(u8, h[0..2], "II"))
        .little
    else if (std.mem.eql(u8, h[0..2], "MM"))
        .big
    else
        return error.BadSignature;
    in.endian = endian;
    switch (std.mem.readInt(u16, h[2..4], endian)) {
        42 => {
            in.big = false;
            return .{ .endian = endian, .big = false, .first = try in.int(u32) };
        },
        43 => {
            const b = try in.takeArray(4);
            // The offset size, 8, and a reserved zero.
            if (std.mem.readInt(u16, b[0..2], endian) != 8 or std.mem.readInt(u16, b[2..4], endian) != 0)
                return error.BadHeader;
            in.big = true;
            return .{ .endian = endian, .big = true, .first = try in.int(u64) };
        },
        else => return error.BadSignature,
    }
}

/// Field types (section 2, and BigTIFF's three), by their bytes per value;
/// 0 for a type this decoder does not know, whose fields it skips.
pub fn typeSize(t: u16) u8 {
    return switch (t) {
        1, 2, 6, 7 => 1,
        3, 8 => 2,
        4, 9, 11, 13 => 4,
        5, 10, 12, 16, 17, 18 => 8,
        else => 0,
    };
}

/// A field whose value is stored elsewhere in the file, or inline in the
/// entry when it fits (`at` is then null and `raw` holds it).
pub const Field = struct {
    type: u16 = 0,
    count: u64 = 0,
    /// Where the value is, when it is not inline.
    at: ?u64 = null,
    raw: [8]u8 = @splat(0),

    pub fn present(f: Field) bool {
        return f.count != 0;
    }

    pub fn size(f: Field) u8 {
        return typeSize(f.type);
    }

    /// The value's bytes, or null if they overflow.
    pub fn len(f: Field) ?u64 {
        return std.math.mul(u64, f.count, f.size()) catch null;
    }

    /// Value `i` of an integer field held inline or in `bytes` (its value
    /// read from the file), in the file's byte order.
    pub fn get(f: Field, bytes: []const u8, i: usize, endian: Endian) u64 {
        const b = if (f.at == null) f.raw[0..] else bytes;
        return intAt(f.type, b, i, endian);
    }
};

/// Value `i` of an unsigned integer type in `b`; other types read as 0.
pub fn intAt(t: u16, b: []const u8, i: usize, endian: Endian) u64 {
    return switch (t) {
        1, 7 => b[i],
        3 => std.mem.readInt(u16, b[2 * i ..][0..2], endian),
        4, 13 => std.mem.readInt(u32, b[4 * i ..][0..4], endian),
        16, 18 => std.mem.readInt(u64, b[8 * i ..][0..8], endian),
        else => 0,
    };
}

pub const Model = enum {
    gray,
    rgb,
    palette,
    cmyk,
    ycbcr,

    /// The color channels, before any extra samples.
    pub fn channels(m: Model) u16 {
        return switch (m) {
            .gray, .palette => 1,
            .rgb, .ycbcr => 3,
            .cmyk => 4,
        };
    }
};
pub const SampleKind = enum { uint, int, float };

/// One IFD: an image's fields, defaults filled in.
pub const Page = struct {
    /// Where the IFD is, and the file's byte order.
    offset: u64 = 0,
    endian: Endian = .little,
    width: u32 = 0,
    height: u32 = 0,
    bits: u16 = 1,
    spp: u16 = 1,
    sample: SampleKind = .uint,
    compression: u16 = 1,
    photometric: ?u16 = null,
    fill_order: u16 = 1,
    planar: u16 = 1,
    predictor: u16 = 1,
    rows_per_strip: u64 = std.math.maxInt(u32),
    tile_width: ?u64 = null,
    tile_height: ?u64 = null,
    ink_set: u16 = 1,
    /// The first ExtraSamples value, and how many there are.
    extra: u16 = 0,
    extra_count: u64 = 0,
    subsampling: [2]u16 = .{ 2, 2 },
    t4: u32 = 0,
    t6: u32 = 0,
    orientation: u16 = 1,
    res_unit: u16 = 2,
    density: ?[2]u32 = null,
    /// RefBlackWhite and YCbCrCoefficients, defaulted for YCbCr.
    ref_bw: [6]f32 = .{ 0, 255, 128, 255, 128, 255 },
    coefs: [3]f32 = .{ 0.299, 0.587, 0.114 },

    offsets: Field = .{},
    counts: Field = .{},
    bits_field: Field = .{},
    format_field: Field = .{},
    extra_field: Field = .{},
    colormap: Field = .{},
    xres: Field = .{},
    yres: Field = .{},
    ref_bw_field: Field = .{},
    coefs_field: Field = .{},
    jpeg_tables: Field = .{},
    icc: Field = .{},
    xmp: Field = .{},
    has_width: bool = false,
    has_height: bool = false,
    /// The next IFD's offset, 0 for the last.
    next: u64 = 0,

    /// Either tile dimension makes a page tiled, as in libtiff; one
    /// without the other is then an error.
    pub fn tiled(p: *const Page) bool {
        return p.tile_width != null or p.tile_height != null;
    }

    pub fn model(p: *const Page) Model {
        return switch (p.photometric.?) {
            0, 1 => .gray,
            2 => .rgb,
            3 => .palette,
            5 => .cmyk,
            6 => .ycbcr,
            else => unreachable,
        };
    }

    /// The color channels before the extra samples.
    pub fn colorChannels(p: *const Page) u16 {
        return p.model().channels();
    }

    /// Whether the first extra sample is alpha, associated (premultiplied)
    /// or not.
    pub fn alpha(p: *const Page) ?enum { straight, premul } {
        if (p.spp <= p.colorChannels()) return null;
        return switch (p.extra) {
            1 => .premul,
            2 => .straight,
            else => null,
        };
    }

    pub fn subsampled(p: *const Page) bool {
        return p.model() == .ycbcr and (p.subsampling[0] != 1 or p.subsampling[1] != 1);
    }
};

/// Reads the IFD at the reader's position: its entries, keeping the fields
/// this decoder uses, and the next IFD's offset. Values stored elsewhere
/// are only located; `loadValues` reads them.
pub fn readIfd(in: *Input, p: *Page) Error!void {
    p.offset = in.pos;
    p.endian = in.endian;
    const n = if (in.big) try in.int(u64) else try in.int(u16);
    var seen: std.StaticBitSet(48) = .initEmpty();
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const e = if (in.big) try in.takeArray(20) else try in.takeArray(12);
        const tag = std.mem.readInt(u16, e[0..2], in.endian);
        var f: Field = .{ .type = std.mem.readInt(u16, e[2..4], in.endian) };
        const inline_len: u8 = if (in.big) 8 else 4;
        f.count = if (in.big) std.mem.readInt(u64, e[4..12], in.endian) else std.mem.readInt(u32, e[4..8], in.endian);
        const value = if (in.big) e[12..20] else e[8..12];
        const total = (if (f.size() == 0 or f.count == 0) null else f.len()) orelse switch (tag) {
            // The fields the layout rests on must be readable, as libtiff
            // requires; others of an unknown type, with no values, or with
            // more than fit in 64 bits are skipped, as libtiff skips them.
            // libtiff skips an ExtraSamples with no values too.
            338 => if (f.size() != 0 and f.count == 0) continue else return error.BadHeader,
            256, 257, 258, 259, 273, 277, 278, 279, 284, 322, 323, 324, 325, 339 => return error.BadHeader,
            else => continue,
        };
        if (total <= inline_len) {
            @memcpy(f.raw[0..inline_len], value);
        } else {
            f.at = if (in.big)
                std.mem.readInt(u64, value[0..8], in.endian)
            else
                std.mem.readInt(u32, value[0..4], in.endian);
        }
        const slot = slotOf(tag) orelse continue;
        // The first of a repeated tag wins.
        if (seen.isSet(slot)) continue;
        seen.set(slot);
        setField(in.endian, p, tag, f) catch |err| switch (tag) {
            // A field of the wrong type or count is ignored, as libtiff
            // ignores it, where the decoder has a default or can do
            // without.
            262, 266, 274, 292, 293, 296, 317, 332, 530 => {},
            else => return err,
        };
    }
    // A next-IFD offset cut off by the input's end ends the chain, as in
    // libtiff.
    p.next = in.word() catch |e| switch (e) {
        error.Truncated => 0,
        else => return e,
    };
}

const known_tags = [_]u16{
    256, 257, 258, 259, 262, 266, 273, 274, 277, 278, 279, 282, 283, 284, 292, 293,
    296, 317, 320, 322, 323, 324, 325, 332, 338, 339, 347, 529, 530, 532, 700, 34675,
};

fn slotOf(tag: u16) ?usize {
    for (known_tags, 0..) |t, i| if (t == tag) return i;
    return null;
}

/// A single-valued integer field.
fn scalar(f: Field, endian: Endian) Error!u64 {
    if (f.count != 1 or f.at != null) return error.BadHeader;
    const v: i64 = switch (f.type) {
        1, 3, 4, 16 => return intAt(f.type, &f.raw, 0, endian),
        6 => @as(i8, @bitCast(f.raw[0])),
        8 => std.mem.readInt(i16, f.raw[0..2], endian),
        9 => std.mem.readInt(i32, f.raw[0..4], endian),
        17 => std.mem.readInt(i64, f.raw[0..8], endian),
        else => return error.BadHeader,
    };
    return std.math.cast(u64, v) orelse error.BadHeader;
}

fn small(f: Field, endian: Endian) Error!u16 {
    return std.math.cast(u16, try scalar(f, endian)) orelse error.BadHeader;
}

fn setField(endian: Endian, p: *Page, tag: u16, f: Field) Error!void {
    switch (tag) {
        256 => {
            p.width = std.math.cast(u32, try scalar(f, endian)) orelse return error.ImageTooLarge;
            p.has_width = true;
        },
        257 => {
            p.height = std.math.cast(u32, try scalar(f, endian)) orelse return error.ImageTooLarge;
            p.has_height = true;
        },
        258 => {
            if (f.type != 3) return error.BadHeader;
            p.bits_field = f;
            if (f.at == null) p.bits = @intCast(intAt(3, &f.raw, 0, endian));
        },
        259 => p.compression = try small(f, endian),
        262 => p.photometric = try small(f, endian),
        266 => p.fill_order = try small(f, endian),
        273, 324 => p.offsets = f,
        279, 325 => p.counts = f,
        274 => p.orientation = try small(f, endian),
        277 => p.spp = try small(f, endian),
        278 => p.rows_per_strip = try scalar(f, endian),
        282 => p.xres = f,
        283 => p.yres = f,
        284 => p.planar = try small(f, endian),
        292 => p.t4 = std.math.cast(u32, try scalar(f, endian)) orelse return error.BadHeader,
        293 => p.t6 = std.math.cast(u32, try scalar(f, endian)) orelse return error.BadHeader,
        296 => p.res_unit = try small(f, endian),
        317 => p.predictor = try small(f, endian),
        320 => p.colormap = f,
        322 => p.tile_width = try scalar(f, endian),
        323 => p.tile_height = try scalar(f, endian),
        332 => p.ink_set = try small(f, endian),
        338 => {
            p.extra_field = f;
            p.extra_count = f.count;
            if (f.at == null) p.extra = @intCast(@min(0xffff, intAt(f.type, &f.raw, 0, endian)));
        },
        339 => {
            if (f.type != 3) return error.BadHeader;
            p.format_field = f;
            if (f.at == null) p.sample = try sampleKind(@intCast(intAt(3, &f.raw, 0, endian)));
        },
        347 => p.jpeg_tables = f,
        529 => p.coefs_field = f,
        530 => {
            // libtiff ignores a count other than 2.
            if (f.type != 3 or f.count != 2) return error.BadHeader;
            p.subsampling = .{ @intCast(intAt(3, &f.raw, 0, endian)), @intCast(intAt(3, &f.raw, 1, endian)) };
        },
        532 => p.ref_bw_field = f,
        700 => p.xmp = f,
        34675 => p.icc = f,
        else => unreachable,
    }
}

fn sampleKind(v: u16) Error!SampleKind {
    return switch (v) {
        1 => .uint,
        2 => .int,
        3 => .float,
        // 4 is "undefined": read the bits as unsigned integers, as libtiff
        // does.
        4 => .uint,
        else => error.Unsupported,
    };
}

/// Which stored values `loadValues` reads.
pub const Values = struct {
    /// BitsPerSample, SampleFormat, ExtraSamples: what the layout and the
    /// native format depend on.
    layout: bool = true,
    /// The color map, YCbCr fields, and the metadata.
    rest: bool = false,
};

/// Reads the values stored outside the IFD, in the order they are in the
/// file. `colormap`, when the page has one and `which.rest` is set,
/// receives it. Metadata blobs go to `sink`, and blobs and density that are
/// behind the reader without a seeker are skipped rather than failing.
pub fn loadValues(
    in: *Input,
    p: *Page,
    which: Values,
    colormap: *[3][256]u16,
    sink: ?decode.BlobSink,
    metadata: *decode.Metadata,
) Error!void {
    const Item = struct { field: *Field, kind: ValueKind };
    var items: [10]Item = undefined;
    var n: usize = 0;
    const all = [_]Item{
        .{ .field = &p.bits_field, .kind = .bits },
        .{ .field = &p.format_field, .kind = .format },
        .{ .field = &p.extra_field, .kind = .extra },
        .{ .field = &p.colormap, .kind = .colormap },
        .{ .field = &p.xres, .kind = .xres },
        .{ .field = &p.yres, .kind = .yres },
        .{ .field = &p.ref_bw_field, .kind = .ref_bw },
        .{ .field = &p.coefs_field, .kind = .coefs },
        .{ .field = &p.icc, .kind = .icc },
        .{ .field = &p.xmp, .kind = .xmp },
    };
    for (all) |item| {
        const layout = switch (item.kind) {
            .bits, .format, .extra => true,
            else => false,
        };
        if (layout and !which.layout or !layout and !which.rest) continue;
        if (!item.field.present()) continue;
        if (item.kind == .colormap and p.photometric != 3) continue;
        items[n] = item;
        n += 1;
    }
    std.mem.sort(Item, items[0..n], {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return (a.field.at orelse 0) < (b.field.at orelse 0);
        }
    }.less);
    for (items[0..n]) |item| {
        const optional = switch (item.kind) {
            .bits, .format, .extra => false,
            else => true,
        };
        loadValue(in, p, item.kind, item.field, colormap, sink, metadata) catch |e| {
            // A value that cannot be read is ignored, as libtiff ignores
            // it, unless the layout depends on it; a color map the page
            // needs is then missing. The reader stopped somewhere past the
            // value, so the next move seeks.
            if (!optional or e != error.Truncated) return e;
            item.field.* = .{};
            in.pos = std.math.maxInt(u64);
        };
    }
}

const ValueKind = enum { bits, format, extra, colormap, xres, yres, ref_bw, coefs, icc, xmp };

fn loadValue(
    in: *Input,
    p: *Page,
    kind: ValueKind,
    field: *Field,
    colormap: *[3][256]u16,
    sink: ?decode.BlobSink,
    metadata: *decode.Metadata,
) Error!void {
    const f = field.*;
    // Inline values are read through a reader of their own.
    var raw: Io.Reader = .fixed(&field.raw);
    var inline_in: Input = .{ .r = &raw, .seeker = null, .endian = in.endian, .big = in.big };
    const src = if (f.at) |at| blk: {
        const skippable = switch (kind) {
            .icc, .xmp, .xres, .yres => true,
            else => false,
        };
        if (skippable and at < in.pos and in.seeker == null) return;
        try in.goTo(at);
        break :blk in;
    } else &inline_in;
    switch (kind) {
        .bits => {
            const first = try readInt(src, f);
            for (1..@max(1, @min(f.count, p.spp))) |_| if (try readInt(src, f) != first) return error.Unsupported;
            p.bits = std.math.cast(u16, first) orelse return error.BadHeader;
            try checkEnd(src, f);
        },
        .format => {
            const first = try readInt(src, f);
            for (1..@max(1, @min(f.count, p.spp))) |_| if (try readInt(src, f) != first) return error.Unsupported;
            p.sample = try sampleKind(std.math.cast(u16, first) orelse return error.Unsupported);
            try checkEnd(src, f);
        },
        .extra => {
            // One value per extra sample, each a meaning the specification
            // defines, as libtiff requires.
            if (f.count > p.spp) return error.BadHeader;
            for (0..@intCast(f.count)) |i| {
                const v = try readInt(src, f);
                if (v > 2) return error.BadHeader;
                if (i == 0) p.extra = @intCast(v);
            }
        },
        .colormap => {
            // Its length is checked against BitsPerSample, which may come
            // later in the file, by the caller.
            if (f.type != 3 or f.count % 3 != 0) {
                // Ignored, as libtiff ignores it.
                field.* = .{};
                return;
            }
            if (f.count > 3 * 256) {
                // A 16-bit map, if it is there: one past the end of the
                // input is ignored, as libtiff ignores it.
                try src.goTo(f.at.? + 2 * f.count - 1);
                _ = try src.takeArray(1);
                return error.Unsupported;
            }
            const entries: usize = @intCast(f.count / 3);
            for (0..3) |c| {
                for (0..entries) |i| colormap[c][i] = @intCast(try readInt(src, f));
            }
        },
        .xres, .yres => {
            const v = try rational(src, f) orelse return;
            const d = metadataDensity(p);
            d[if (kind == .xres) 0 else 1] = v;
        },
        .ref_bw => if (f.count >= 6) for (&p.ref_bw) |*v| {
            v.* = try rationalF(src, f);
        },
        .coefs => if (f.count >= 3) for (&p.coefs) |*v| {
            v.* = try rationalF(src, f);
        },
        .icc, .xmp => {
            const blob_kind: decode.Blob.Kind = if (kind == .icc) .icc else .xmp;
            const len = f.len() orelse return error.BadHeader;
            const blob: decode.Blob = .{ .kind = blob_kind, .offset = f.at orelse return, .len = len };
            if (blob_kind == .icc) metadata.icc = blob else metadata.xmp = blob;
            const s = sink orelse return;
            var at: u64 = 0;
            while (at < len) {
                const got = in.r.peekGreedy(1) catch |e| return mapRead(e);
                const take: usize = @intCast(@min(got.len, len - at));
                s.put(blob, at, got[0..take]);
                in.r.toss(take);
                in.pos += take;
                at += take;
            }
        },
    }
}

/// Checks that the rest of a per-sample array whose first values were
/// read from `in` is in the input, as libtiff reads it whole.
fn checkEnd(in: *Input, f: Field) Error!void {
    const at = f.at orelse return;
    const len = f.len() orelse return error.BadHeader;
    const end = std.math.add(u64, at, len) catch return error.BadHeader;
    if (end > in.pos) {
        try in.goTo(end - 1);
        _ = try in.takeArray(1);
    }
}

fn metadataDensity(p: *Page) *[2]u32 {
    if (p.density == null) p.density = .{ 0, 0 };
    return &p.density.?;
}

/// The next value of an integer field, from `in`, which is at the
/// field's value.
fn readInt(in: *Input, f: Field) Error!u64 {
    return switch (f.type) {
        1, 7 => (try in.takeArray(1))[0],
        3 => try in.int(u16),
        4, 13 => try in.int(u32),
        16, 18 => try in.int(u64),
        else => error.BadHeader,
    };
}

/// A RATIONAL value rounded to an integer, or null for a zero denominator
/// or another type.
fn rational(in: *Input, f: Field) Error!?u32 {
    if (f.type != 5) return null;
    const num = try in.int(u32);
    const den = try in.int(u32);
    if (den == 0) return null;
    return std.math.cast(u32, (@as(u64, num) + den / 2) / den);
}

/// The next value of a field that should be RATIONAL; integer and float
/// types are read too, as libtiff reads them.
fn rationalF(in: *Input, f: Field) Error!f32 {
    const num: f64, const den: f64 = switch (f.type) {
        5 => .{ @floatFromInt(try in.int(u32)), @floatFromInt(try in.int(u32)) },
        10 => .{ @floatFromInt(try in.int(i32)), @floatFromInt(try in.int(i32)) },
        3 => .{ @floatFromInt(try in.int(u16)), 1 },
        4 => .{ @floatFromInt(try in.int(u32)), 1 },
        11 => .{ @as(f32, @bitCast(try in.int(u32))), 1 },
        12 => .{ @as(f64, @bitCast(try in.int(u64))), 1 },
        else => return error.BadHeader,
    };
    return if (den == 0) 0 else @floatCast(num / den);
}

/// The density the page names, for `Metadata`.
pub fn density(p: *const Page) ?decode.Density {
    const d = p.density orelse return null;
    if (d[0] == 0 or d[1] == 0) return null;
    return switch (p.res_unit) {
        1 => .{ .x = d[0], .y = d[1], .unit = .none },
        2 => .{ .x = d[0], .y = d[1], .unit = .per_inch },
        3 => .{
            .x = std.math.cast(u32, @as(u64, d[0]) * 100) orelse return null,
            .y = std.math.cast(u32, @as(u64, d[1]) * 100) orelse return null,
            .unit = .per_meter,
        },
        else => null,
    };
}

test "header" {
    var r: Io.Reader = .fixed("II*\x00\x08\x00\x00\x00");
    var in: Input = .{ .r = &r, .seeker = null };
    const h = try readHeader(&in);
    try testing.expectEqual(.{ Endian.little, false, 8 }, .{ h.endian, h.big, h.first });
    r = .fixed("MM\x00\x2b\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10");
    in = .{ .r = &r, .seeker = null };
    const b = try readHeader(&in);
    try testing.expectEqual(.{ Endian.big, true, 16 }, .{ b.endian, b.big, b.first });
    r = .fixed("MM\x00\x2b\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10");
    in = .{ .r = &r, .seeker = null };
    try testing.expectError(error.BadHeader, readHeader(&in));
    r = .fixed("IM*\x00\x08\x00\x00\x00");
    in = .{ .r = &r, .seeker = null };
    try testing.expectError(error.BadSignature, readHeader(&in));
}
