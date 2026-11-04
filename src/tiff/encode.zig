//! The TIFF encoder: classic TIFF 6.0, little endian, chunky strips,
//! uncompressed or compressed with PackBits, LZW, or Deflate (Adobe's
//! compression 8), with horizontal differencing (Predictor 2) before LZW
//! and Deflate. `encodePages` writes several pages, one IFD each.
//! src/encode.zig has the contract.
//!
//! - The file stores the source's channels, straight or associated alpha
//!   as the source has it (ExtraSamples 2 or 1), at 8 bits for 8-bit
//!   sources and 16 bits otherwise, so `image.tiff.Decoder` reads back the
//!   source converted by `image.convert` to that format. Gray is
//!   BlackIsZero; `cmyk8` and `cmyk16` are Separated with ink amounts,
//!   the maximum minus the inverted inks they hold (plan.md decision 15).
//! - An 8-bit RGB image of at most 256 colors is stored as a palette of 1,
//!   2, 4, or 8 bits when that makes the pixels and the color map smaller
//!   than the RGB pixels, its colors in order of first appearance.
//! - Strips hold about 8 KiB of stored rows, as libtiff makes by default
//!   (`EncodeOptions.rows_per_strip` overrides it).
//! - The layout reads forward: the header, then each page's IFD, the
//!   values it points to, and its strips, the next IFD after them. A
//!   writer cannot go back to fill in offsets, so the IFD comes first and
//!   needs the strips' byte counts before them. A compressed page is
//!   compressed once when its strips fit in the writer's free buffer (a
//!   fixed writer with room for the file), where they wait for the IFD to
//!   go in front of them; otherwise its strips are compressed twice, once
//!   to count and once to write.
//!
//! Nothing is allocated. The work memory is a strip of stored rows, its
//! compressed form, the codec's state, the palette, and a byte count per
//! strip, so it grows with the height only by four bytes a strip.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const zlib = @import("compress").zlib;

const shared = @import("../encode.zig");
const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const lzw = @import("encode_lzw.zig");
const packbits = @import("encode_packbits.zig");

pub const Compression = enum { none, packbits, lzw, deflate };

/// How hard Deflate works, at the PNG encoder's levels.
pub const Effort = enum {
    /// Greedy deflate (zlib level 6).
    fast,
    /// Lazy deflate with a short search.
    default,
    /// Lazy deflate with a long search: the smallest file, the slowest.
    best,
};

pub const EncodeOptions = struct {
    compression: Compression = .lzw,
    /// Horizontal differencing (Predictor 2) before LZW or Deflate, for
    /// every image but a palette.
    predictor: bool = true,
    /// Deflate's effort.
    effort: Effort = .default,
    /// Store an 8-bit RGB image of at most 256 colors as a palette when
    /// that is smaller.
    palette: bool = true,
    /// XResolution, YResolution, and ResolutionUnit: per inch, per
    /// centimeter (a per-meter density over 100), or none.
    density: ?decode.Density = null,
    /// The rows in each strip; null for strips of about 8 KiB.
    rows_per_strip: ?u32 = null,
};

pub const EncodeError = shared.Error || error{
    /// TIFF cannot store an image without rows or columns, or a file
    /// without pages.
    EmptyImage,
};

/// The stored bytes a strip holds by default.
const strip_target = 8192;
/// The widest stored pixel: 16-bit RGBA or CMYK.
const max_bpp = 8;
/// Classic TIFF's offsets are 32 bits.
const max_offset = std.math.maxInt(u32);

/// The work memory `encode` needs for a `width` by `height` image, and
/// `encodePages` for pages no wider and no taller; null when it does not
/// fit in `usize`.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    const lens = Lens.of(options, width, height) orelse return null;
    return lens.total();
}

/// The parts of the work memory, in bytes.
const Lens = struct {
    codec: usize,
    rgb_row: usize,
    strip: usize,
    out: usize,
    sizes: usize,

    fn of(options: EncodeOptions, width: u32, height: u32) ?Lens {
        const h: usize = @max(height, 1);
        const row = std.math.mul(usize, @max(width, 1), max_bpp) catch return null;
        const rows = rowsPerStrip(options, row, height);
        // A stored row is at most `row` bytes, and the default strip
        // holds at most the target or a single row.
        const strip = if (options.rows_per_strip != null)
            std.math.mul(usize, rows, row) catch return null
        else
            @min(std.math.mul(usize, h, row) catch return null, @max(row, strip_target));
        const strips = (h + rows - 1) / rows;
        const out: usize = switch (options.compression) {
            .none => 0,
            // Both write at most twice their input and a few bytes.
            .packbits, .lzw => (std.math.mul(usize, strip, 2) catch return null) +| 16,
            .deflate => std.math.add(usize, zlib.encode.maxCompressedLength(strip), 64) catch return null,
        };
        return .{
            .codec = switch (options.compression) {
                .none, .packbits => 0,
                .lzw => @sizeOf(lzw.State) + @alignOf(lzw.State),
                .deflate => @sizeOf(Deflate) + @alignOf(Deflate),
            },
            .rgb_row = if (options.palette) std.math.mul(usize, width, 3) catch return null else 0,
            .strip = strip,
            .out = out,
            .sizes = if (options.compression == .none) 0 else std.math.mul(usize, strips, 4) catch return null,
        };
    }

    fn total(l: Lens) ?usize {
        var sum: usize = @sizeOf(Palette) + @alignOf(Palette) + @alignOf(u32);
        for ([_]usize{ l.codec, l.rgb_row, l.strip, l.out, l.sizes }) |n| {
            sum = std.math.add(usize, sum, n) catch return null;
        }
        return sum;
    }
};

/// The rows in a strip of stored rows `row_len` bytes long.
fn rowsPerStrip(options: EncodeOptions, row_len: usize, height: u32) usize {
    const rows: usize = if (options.rows_per_strip) |r| @max(r, 1) else @max(1, strip_target / @max(row_len, 1));
    return @min(rows, @max(height, 1));
}

const Deflate = struct {
    zw: zlib.Writer,
    window: zlib.Writer.Buffer,
};

/// The work memory, carved.
const Memory = struct {
    palette: *Palette,
    lzw: *lzw.State,
    deflate: *Deflate,
    rgb_row: []u8,
    strip: []u8,
    out: []u8,
    sizes: []u32,

    fn carve(work: []u8, options: EncodeOptions, lens: Lens) Memory {
        var rest = work;
        var m: Memory = undefined;
        m.palette = take(Palette, &rest);
        switch (options.compression) {
            .lzw => {
                m.lzw = take(lzw.State, &rest);
                m.lzw.init();
            },
            .deflate => m.deflate = take(Deflate, &rest),
            .none, .packbits => {},
        }
        const pad = std.mem.alignForward(usize, @intFromPtr(rest.ptr), @alignOf(u32)) - @intFromPtr(rest.ptr);
        m.sizes = @ptrCast(@alignCast(rest[pad..][0..lens.sizes]));
        rest = rest[pad + lens.sizes ..];
        m.rgb_row = rest[0..lens.rgb_row];
        m.strip = rest[lens.rgb_row..][0..lens.strip];
        m.out = rest[lens.rgb_row + lens.strip ..][0..lens.out];
        return m;
    }

    fn take(comptime T: type, rest: *[]u8) *T {
        const at = std.mem.alignForward(usize, @intFromPtr(rest.ptr), @alignOf(T)) - @intFromPtr(rest.ptr);
        const p: *T = @ptrCast(@alignCast(rest.*[at..][0..@sizeOf(T)]));
        rest.* = rest.*[at + @sizeOf(T) ..];
        return p;
    }
};

/// Writes `src` as a one-page TIFF file.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    return encodePages(w, (&src)[0..1], options, work);
}

/// Writes `pages` as one TIFF file, a page each, in order. `work` holds at
/// least `workLen` for the widest and the tallest page. A compressed page
/// is compressed once when `w`'s free buffer holds it, and twice, the
/// first time only to count its bytes, when it does not.
pub fn encodePages(w: *Io.Writer, pages: []const PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    if (pages.len == 0) return error.EmptyImage;
    for (pages) |p| {
        try p.check();
        if (p.width == 0 or p.height == 0) return error.EmptyImage;
        const need = workLen(options, p.width, p.height) orelse return error.ImageTooLarge;
        if (work.len < need) return error.WorkTooSmall;
    }
    var out: Out = .{ .w = w };
    try out.bytes("II*\x00\x08\x00\x00\x00");
    for (pages, 0..) |p, i| try writePage(&out, p, options, work, i + 1 < pages.len);
}

/// The writer and the file offset it has reached.
const Out = struct {
    w: *Io.Writer,
    pos: u64 = 0,

    fn bytes(o: *Out, b: []const u8) EncodeError!void {
        try o.w.writeAll(b);
        o.pos += b.len;
    }

    fn int(o: *Out, comptime T: type, v: T) EncodeError!void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try o.bytes(&b);
    }
};

/// How a page is stored.
const Plan = struct {
    src: PixelBuffer,
    /// What the source's rows convert to: the stored format, or `rgb8`
    /// before a palette indexes it.
    format: PixelFormat,
    conv: Converter,
    /// The palette's index width, or 0 for none.
    palette_bits: u4,
    spp: u16,
    bits: u16,
    photometric: u16,
    /// ExtraSamples: 0 for none, 1 associated alpha, 2 straight.
    extra: u16,
    predictor: bool,
    /// Ink amounts, the inverted inks of `cmyk8` and `cmyk16`.
    invert: bool,
    row_len: usize,
    rows: usize,
    strips: usize,

    fn stripRows(p: *const Plan, s: usize) usize {
        return @min(p.rows, p.src.height - s * p.rows);
    }
};

/// The format a page of `f` is stored in, but for a palette.
fn storedFormat(f: PixelFormat) PixelFormat {
    if (f.isCmyk()) return f;
    const wide = f.sample() != .u8;
    const i: usize = if (!f.hasAlpha()) 0 else if (f.isPremultiplied()) 2 else 1;
    const formats: [2][3]PixelFormat = if (f.isGray())
        .{ .{ .gray8, .gray_alpha8, .gray_alpha8_premul }, .{ .gray16, .gray_alpha16, .gray_alpha16_premul } }
    else
        .{ .{ .rgb8, .rgba8, .rgba8_premul }, .{ .rgb16, .rgba16, .rgba16_premul } };
    return formats[@intFromBool(wide)][i];
}

fn makePlan(src: PixelBuffer, options: EncodeOptions, m: Memory) Plan {
    const format = storedFormat(src.format);
    const bits: u16 = if (format.sample() == .u8) 8 else 16;
    const spp: u16 = @intCast(format.channelCount());
    var p: Plan = .{
        .src = src,
        .format = format,
        .conv = .init(format, src.format),
        .palette_bits = 0,
        .spp = spp,
        .bits = bits,
        .photometric = if (format.isCmyk()) 5 else if (format.isGray()) 1 else 2,
        .extra = if (!format.hasAlpha()) 0 else if (format.isPremultiplied()) 1 else 2,
        .predictor = options.predictor and (options.compression == .lzw or options.compression == .deflate),
        .invert = format.isCmyk(),
        .row_len = @as(usize, src.width) * format.bytesPerPixel(),
        .rows = 0,
        .strips = 0,
    };
    if (format == .rgb8 and options.palette) {
        if (m.palette.scan(src, p.conv, m.rgb_row)) |pal_bits| {
            const w: u64 = src.width;
            const indices = (w * pal_bits + 7) / 8 * src.height;
            const map = @as(u64, 6) << pal_bits;
            if (indices + map < 3 * w * src.height) {
                p.palette_bits = pal_bits;
                p.spp = 1;
                p.bits = pal_bits;
                p.photometric = 3;
                p.predictor = false;
                p.row_len = @intCast((w * pal_bits + 7) / 8);
            }
        }
    }
    p.rows = rowsPerStrip(options, p.row_len, src.height);
    p.strips = (src.height + p.rows - 1) / p.rows;
    return p;
}

/// Up to 256 colors and a hash from color to index.
const Palette = struct {
    colors: [256][3]u8,
    len: u16,
    /// Index + 1 of the color hashed here, or 0.
    slots: [1024]u16,

    /// Collects the colors of `src` converted to `rgb8` by `conv`, and
    /// returns the index width they need, or null for more than 256.
    fn scan(p: *Palette, src: PixelBuffer, conv: Converter, rgb_row: []u8) ?u4 {
        p.len = 0;
        @memset(&p.slots, 0);
        for (0..src.height) |y| {
            const rgb = rgbRow(src, @intCast(y), conv, rgb_row);
            var last: ?[3]u8 = null;
            var x: usize = 0;
            while (x < rgb.len) : (x += 3) {
                const c = rgb[x..][0..3].*;
                if (last != null and std.mem.eql(u8, &last.?, &c)) continue;
                last = c;
                const s = p.slot(c);
                if (p.slots[s] != 0) continue;
                if (p.len == 256) return null;
                p.colors[p.len] = c;
                p.len += 1;
                p.slots[s] = p.len;
            }
        }
        return if (p.len <= 2) 1 else if (p.len <= 4) 2 else if (p.len <= 16) 4 else 8;
    }

    /// The slot holding `c`, or the empty slot it would go in.
    fn slot(p: *const Palette, c: [3]u8) usize {
        const key = @as(u32, c[0]) | @as(u32, c[1]) << 8 | @as(u32, c[2]) << 16;
        var s: usize = (key *% 0x9e3779b1) >> 22;
        while (true) : (s = (s + 1) % p.slots.len) {
            const v = p.slots[s];
            if (v == 0 or std.mem.eql(u8, &p.colors[v - 1], &c)) return s;
        }
    }

    fn index(p: *const Palette, c: [3]u8) u8 {
        return @intCast(p.slots[p.slot(c)] - 1);
    }
};

/// Row `y` of `src` as `rgb8`: the source's own row, or converted into
/// `buf`.
fn rgbRow(src: PixelBuffer, y: u32, conv: Converter, buf: []u8) []const u8 {
    const row = src.row(y);
    if (src.format == .rgb8) return row[0 .. @as(usize, src.width) * 3];
    const rgb = buf[0 .. @as(usize, src.width) * 3];
    conv.run(rgb, row, src.width);
    return rgb;
}

fn writePage(out: *Out, src: PixelBuffer, options: EncodeOptions, work: []u8, more: bool) EncodeError!void {
    const lens = Lens.of(options, src.width, src.height).?;
    const m: Memory = .carve(work, options, lens);
    const p = makePlan(src, options, m);

    var entries: [17]Entry = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(e: []Entry, k: *usize, entry: Entry) void {
            e[k.*] = entry;
            k.* += 1;
        }
    }.f;
    add(&entries, &n, .shortOrLong(256, src.width));
    add(&entries, &n, .shortOrLong(257, src.height));
    const bits: u32 = p.bits;
    add(&entries, &n, if (p.spp <= 2)
        .{ .tag = 258, .kind = Kind.short, .count = p.spp, .value = if (p.spp == 2) bits << 16 | bits else bits }
    else
        .{ .tag = 258, .kind = Kind.short, .count = p.spp, .outside = 2 * @as(u32, p.spp) });
    add(&entries, &n, .short(259, switch (options.compression) {
        .none => 1,
        .packbits => 32773,
        .lzw => 5,
        .deflate => 8,
    }));
    add(&entries, &n, .short(262, p.photometric));
    const strips: u32 = @intCast(p.strips);
    const offsets_at = n;
    const array_len: u32 = if (strips > 1) 4 * strips else 0;
    add(&entries, &n, .{ .tag = 273, .kind = Kind.long, .count = strips, .outside = array_len });
    add(&entries, &n, .short(277, p.spp));
    add(&entries, &n, .shortOrLong(278, @intCast(p.rows)));
    const counts_at = n;
    const short_counts = shortCounts(&p, options.compression);
    const counts_len: u32 = if (short_counts) 2 * strips else 4 * strips;
    add(&entries, &n, .{
        .tag = 279,
        .kind = if (short_counts) Kind.short else Kind.long,
        .count = strips,
        .outside = if (counts_len > 4) counts_len else 0,
    });
    const density = options.density;
    if (density != null) {
        add(&entries, &n, .{ .tag = 282, .kind = Kind.rational, .count = 1, .outside = 8 });
        add(&entries, &n, .{ .tag = 283, .kind = Kind.rational, .count = 1, .outside = 8 });
    }
    add(&entries, &n, .short(284, 1));
    if (density) |d| add(&entries, &n, .short(296, switch (d.unit) {
        .none => 1,
        .per_inch => 2,
        .per_meter => 3,
    }));
    if (p.predictor) add(&entries, &n, .short(317, 2));
    if (p.palette_bits != 0) {
        const colors = @as(u32, 1) << p.palette_bits;
        add(&entries, &n, .{ .tag = 320, .kind = Kind.short, .count = 3 * colors, .outside = 6 * colors });
    }
    if (p.extra != 0) add(&entries, &n, .short(338, p.extra));

    // Where everything goes: the IFD, the values outside it, and the
    // strips. The strip offsets and byte counts go last, after the values
    // a reader needs before them (the decoder reads them as it decodes).
    var order: [17]usize = undefined;
    var outside: usize = 0;
    for (0..2) |pass| for (entries[0..n], 0..) |e, i| {
        const arrays = e.tag == 273 or e.tag == 279;
        if (e.outside > 0 and arrays == (pass == 1)) {
            order[outside] = i;
            outside += 1;
        }
    };
    const ifd_at = out.pos;
    var at = ifd_at + 2 + 12 * n + 4;
    for (order[0..outside]) |i| {
        entries[i].value = std.math.cast(u32, at) orelse return error.ImageTooLarge;
        at += entries[i].outside;
    }
    const data_at = at;
    if (data_at > max_offset) return error.ImageTooLarge;
    const head_len: usize = @intCast(data_at - ifd_at);

    // The strips' byte counts. A compressed strip is compressed once to
    // count it; it also goes straight after the room for the IFD in the
    // writer's buffer while that has room, and when every strip fits
    // there, the IFD is filled in before them and nothing is compressed
    // again.
    var total: u64 = 0;
    var room = out.w.unusedCapacitySlice();
    var direct = options.compression != .none and room.len >= head_len;
    if (options.compression == .none) {
        total = @as(u64, p.row_len) * src.height;
    } else for (0..p.strips) |s| {
        const bytes = pack(&p, options, m, s);
        m.sizes[s] = @intCast(bytes.len);
        if (direct) {
            const to = head_len + total;
            if (room.len - to >= bytes.len) @memcpy(room[to..][0..bytes.len], bytes) else direct = false;
        }
        total += bytes.len;
    }

    const end = data_at + total;
    if (end > max_offset) return error.ImageTooLarge;
    if (strips == 1) {
        entries[offsets_at].value = @intCast(data_at);
        entries[counts_at].value = @intCast(total);
    } else if (counts_len == 4) {
        // Two SHORT counts, in the entry.
        const first: u32 = @intCast(stripLen(&p, options, m, 0));
        entries[counts_at].value = first | @as(u32, @intCast(stripLen(&p, options, m, 1))) << 16;
    }
    const next: u64 = if (more) std.mem.alignForward(u64, end, 2) else 0;
    if (next > max_offset) return error.ImageTooLarge;

    if (direct) {
        // The strips are in the buffer: the IFD goes in the room before
        // them, and the writer takes both at once.
        room = room[0..head_len];
        var fixed: Io.Writer = .fixed(room);
        var head: Out = .{ .w = &fixed, .pos = ifd_at };
        writeHead(&head, &p, options, m, entries[0..n], order[0..outside], data_at, next) catch unreachable;
        out.w.advance(@intCast(head_len + total));
        out.pos = end;
    } else {
        try writeHead(out, &p, options, m, entries[0..n], order[0..outside], data_at, next);
        for (0..p.strips) |s| {
            const bytes = pack(&p, options, m, s);
            std.debug.assert(bytes.len == stripLen(&p, options, m, s));
            try out.bytes(bytes);
        }
    }
    if (more and out.pos % 2 == 1) try out.bytes("\x00");
}

/// Writes the IFD whose entries are laid out, and the values outside it in
/// `order`, ending at `data_at`, where the strips go.
fn writeHead(
    out: *Out,
    p: *const Plan,
    options: EncodeOptions,
    m: Memory,
    entries: []const Entry,
    order: []const usize,
    data_at: u64,
    next: u64,
) EncodeError!void {
    try out.int(u16, @intCast(entries.len));
    for (entries) |e| {
        try out.int(u16, e.tag);
        try out.int(u16, e.kind);
        try out.int(u32, e.count);
        try out.int(u32, e.value);
    }
    try out.int(u32, @intCast(next));
    const short_counts = shortCounts(p, options.compression);
    const density = options.density;
    for (order) |i| switch (entries[i].tag) {
        258 => for (0..p.spp) |_| try out.int(u16, p.bits),
        273 => {
            var o: u64 = data_at;
            for (0..p.strips) |s| {
                try out.int(u32, @intCast(o));
                o += stripLen(p, options, m, s);
            }
        },
        279 => for (0..p.strips) |s| {
            const len = stripLen(p, options, m, s);
            if (short_counts) try out.int(u16, @intCast(len)) else try out.int(u32, @intCast(len));
        },
        282, 283 => {
            const d = density.?;
            try out.int(u32, if (entries[i].tag == 282) d.x else d.y);
            try out.int(u32, if (d.unit == .per_meter) 100 else 1);
        },
        320 => for (0..3) |c| for (0..@as(usize, 1) << p.palette_bits) |k| {
            const v: u16 = if (k < m.palette.len) m.palette.colors[k][c] else 0;
            try out.int(u16, v * 257);
        },
        else => unreachable,
    };
    std.debug.assert(out.pos == data_at);
}

/// The IFD's field types.
const Kind = struct {
    const short = 3;
    const long = 4;
    const rational = 5;
};

const Entry = struct {
    tag: u16,
    kind: u16,
    count: u32,
    /// The value when it fits in four bytes, left-justified; otherwise,
    /// once laid out, the offset of the `outside` bytes that hold it.
    value: u32 = 0,
    outside: u32 = 0,

    fn short(tag: u16, v: u16) Entry {
        return .{ .tag = tag, .kind = Kind.short, .count = 1, .value = v };
    }

    /// A SHORT when the value fits in one, as libtiff writes sizes.
    fn shortOrLong(tag: u16, v: u32) Entry {
        return .{ .tag = tag, .kind = if (v <= 0xffff) Kind.short else Kind.long, .count = 1, .value = v };
    }
};

/// Whether StripByteCounts is SHORT, as libtiff types it: for several
/// strips, when no strip could need more than 16 bits, judged from the
/// strip's stored size before compressing, as libtiff judges it, which
/// assumes LZW and Deflate may grow a strip tenfold and never trusts
/// PackBits. One strip's count is LONG.
fn shortCounts(p: *const Plan, compression: Compression) bool {
    if (p.strips == 1) return false;
    const strip = p.rows * p.row_len;
    return switch (compression) {
        .none => strip <= 0xffff,
        .lzw, .deflate => strip < 0xffff / 10,
        .packbits => false,
    };
}

/// Strip `s`'s byte count in the file.
fn stripLen(p: *const Plan, options: EncodeOptions, m: Memory, s: usize) usize {
    if (options.compression == .none) return p.stripRows(s) * p.row_len;
    return m.sizes[s];
}

/// Strip `s` as the file stores it: its rows, compressed.
fn pack(p: *const Plan, options: EncodeOptions, m: Memory, s: usize) []const u8 {
    const raw = fillStrip(p, m, s);
    return switch (options.compression) {
        .none => raw,
        .packbits => {
            var at: usize = 0;
            var r: usize = 0;
            while (r < raw.len) : (r += p.row_len) at += packbits.encodeRow(raw[r..][0..p.row_len], m.out[at..]);
            return m.out[0..at];
        },
        .lzw => m.out[0..lzw.encode(m.lzw, raw, m.out)],
        .deflate => {
            const d = m.deflate;
            var fixed: Io.Writer = .fixed(m.out);
            d.zw = .init(&fixed, &d.window, zlibOptions(options.effort));
            // `out` holds the most a strip compresses to.
            d.zw.writer.writeAll(raw) catch unreachable;
            d.zw.finish() catch unreachable;
            return fixed.buffered();
        },
    };
}

/// Whether `compress` has the lazy levels and the filtered strategy;
/// without them every effort is level 6, as in the PNG encoder.
const lazy_levels = @hasDecl(zlib.encode, "Strategy");

fn zlibOptions(effort: Effort) zlib.encode.Options {
    if (comptime lazy_levels) return switch (effort) {
        .fast => .{ .level = .@"6", .dict = null, .strategy = .default },
        .default => .{ .level = .@"7", .dict = null, .strategy = .filtered },
        .best => .{ .level = .@"9", .dict = null, .strategy = .filtered },
    };
    return .{ .level = .@"6", .dict = null };
}

/// Strip `s`'s stored rows, uncompressed, in `m.strip`.
fn fillStrip(p: *const Plan, m: Memory, s: usize) []u8 {
    const first = s * p.rows;
    const rows = p.stripRows(s);
    const raw = m.strip[0 .. rows * p.row_len];
    for (0..rows) |r| storeRow(p, m, @intCast(first + r), raw[r * p.row_len ..][0..p.row_len]);
    return raw;
}

/// Row `y` as the file stores it, before compression.
fn storeRow(p: *const Plan, m: Memory, y: u32, dst: []u8) void {
    const width: usize = p.src.width;
    if (p.palette_bits != 0) {
        const rgb = rgbRow(p.src, y, p.conv, m.rgb_row);
        const bits = p.palette_bits;
        if (bits == 8) {
            for (0..width) |x| dst[x] = m.palette.index(rgb[x * 3 ..][0..3].*);
            return;
        }
        @memset(dst, 0);
        var last: [3]u8 = rgb[0..3].*;
        var i = m.palette.index(last);
        for (0..width) |x| {
            const c = rgb[x * 3 ..][0..3].*;
            if (!std.mem.eql(u8, &c, &last)) {
                last = c;
                i = m.palette.index(c);
            }
            const bit = x * bits;
            dst[bit / 8] |= i << @intCast(8 - bits - bit % 8);
        }
        return;
    }
    const row = p.src.row(y);
    if (p.src.format == p.format) @memcpy(dst, row[0..dst.len]) else p.conv.run(dst, row, width);
    if (p.invert) for (dst) |*b| {
        b.* = ~b.*;
    };
    if (p.bits == 16 and builtin.target.cpu.arch.endian() == .big) {
        var i: usize = 0;
        while (i < dst.len) : (i += 2) std.mem.swap(u8, &dst[i], &dst[i + 1]);
    }
    if (p.predictor) predict(dst, p.spp, p.bits == 16);
}

/// Horizontal differencing: each sample less the same sample of the pixel
/// before it, from the right, in 16-bit little-endian samples when `wide`.
fn predict(row: []u8, spp: usize, wide: bool) void {
    if (!wide) {
        var i = row.len;
        while (i > spp) {
            i -= 1;
            row[i] -%= row[i - spp];
        }
        return;
    }
    const stride = 2 * spp;
    var i = row.len;
    while (i > stride) {
        i -= 2;
        const left = std.mem.readInt(u16, row[i - stride ..][0..2], .little);
        const v = std.mem.readInt(u16, row[i..][0..2], .little) -% left;
        std.mem.writeInt(u16, row[i..][0..2], v, .little);
    }
}

// Tests. Each file is read back by `image.tiff.Decoder`, forward only.

const Decoder = @import("Decoder.zig");
const convertBuffer = @import("../convert.zig").convertBuffer;

fn encodeAlloc(pages: []const PixelBuffer, options: EncodeOptions) ![]u8 {
    const gpa = testing.allocator;
    var wmax: u32 = 1;
    var hmax: u32 = 1;
    for (pages) |p| {
        wmax = @max(wmax, p.width);
        hmax = @max(hmax, p.height);
    }
    const work = try gpa.alloc(u8, workLen(options, wmax, hmax).?);
    defer gpa.free(work);
    // An empty growing buffer has no room for the first page's strips, so
    // they are compressed twice; a fixed buffer the file's size holds
    // them, so they are compressed once. The files must be the same.
    var w: Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try encodePages(&w.writer, pages, options, work);
    const file = w.written();
    const again = try gpa.alloc(u8, file.len);
    defer gpa.free(again);
    var fixed: Io.Writer = .fixed(again);
    try encodePages(&fixed, pages, options, work);
    try testing.expectEqualSlices(u8, file, fixed.buffered());
    return w.toOwnedSlice();
}

/// Decodes every page of `file` in its native format and checks each
/// against the source converted to it, through a seeker, and for one page
/// also reading forward only.
fn expectPages(file: []const u8, pages: []const PixelBuffer, natives: []const PixelFormat) !decode.Config {
    if (pages.len == 1) _ = try expectPagesWith(file, pages, natives, false);
    return expectPagesWith(file, pages, natives, true);
}

fn expectPagesWith(
    file: []const u8,
    pages: []const PixelBuffer,
    natives: []const PixelFormat,
    seek: bool,
) !decode.Config {
    const gpa = testing.allocator;
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{ .seeker = if (seek) .fixed(&r) else null });
    const config = try d.decodeConfig();
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    const canvas = try gpa.alloc(u8, PixelBuffer.len(config.native, config.width, config.height).?);
    defer gpa.free(canvas);
    const dst = try PixelBuffer.init(canvas, config.native, config.width, config.height);
    for (pages, natives) |src, native| {
        const frame = (try d.decodeFrame(dst, work)).?;
        try testing.expectEqual(src.width, frame.width);
        try testing.expectEqual(src.height, frame.height);
        const got = try gpa.alloc(u8, PixelBuffer.len(native, src.width, src.height).?);
        defer gpa.free(got);
        const want = try gpa.alloc(u8, got.len);
        defer gpa.free(want);
        const g = try PixelBuffer.init(got, native, src.width, src.height);
        try convertBuffer(g, dst.sub(0, 0, src.width, src.height));
        const wb = try PixelBuffer.init(want, native, src.width, src.height);
        try convertBuffer(wb, src);
        try testing.expectEqualSlices(u8, want, got);
    }
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    return config;
}

fn randomImage(random: std.Random, format: PixelFormat, w: u32, h: u32, colors: u32) !PixelBuffer {
    const gpa = testing.allocator;
    const px = try gpa.alloc(u8, PixelBuffer.len(format, w, h).?);
    const bpp = format.bytesPerPixel();
    var pick: [8][16]u8 = undefined;
    for (&pick) |*c| random.bytes(c);
    for (0..@as(usize, w) * h) |i| {
        const c = &pick[random.uintLessThan(usize, @min(colors, 8))];
        if (colors > 8) random.bytes(px[i * bpp ..][0..bpp]) else @memcpy(px[i * bpp ..][0..bpp], c[0..bpp]);
    }
    if (format.sample() == .f32) {
        const f: []align(1) f32 = @ptrCast(px);
        for (f) |*v| v.* = @as(f32, @floatFromInt(random.int(u8))) / 255;
    }
    return PixelBuffer.init(px, format, w, h);
}

test "every pixel format and compression round trips" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for (std.enums.values(PixelFormat)) |format| {
        for (std.enums.values(Compression)) |compression| {
            for ([_]bool{ false, true }) |predictor| {
                const w = 1 + random.uintLessThan(u32, 70);
                const h = 1 + random.uintLessThan(u32, 90);
                const src = try randomImage(random, format, w, h, if (random.boolean()) 3 else 100);
                defer gpa.free(src.pixels);
                const options: EncodeOptions = .{
                    .compression = compression,
                    .predictor = predictor,
                    .palette = random.boolean(),
                };
                const file = try encodeAlloc(&.{src}, options);
                defer gpa.free(file);
                const stored = storedFormat(format);
                _ = try expectPages(file, &.{src}, &.{stored});
            }
        }
    }
}

test "a palette when it is smaller, at the narrowest index width" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for ([_]u32{ 2, 3, 5, 17, 256, 257 }) |colors| {
        const w = 64;
        const h = 40;
        const px = try gpa.alloc(u8, w * h * 3);
        defer gpa.free(px);
        for (0..w * h) |i| {
            const c: u32 = if (i < colors) @intCast(i) else random.uintLessThan(u32, colors);
            px[i * 3 ..][0..3].* = .{ @truncate(c), @truncate(c >> 8), 7 };
        }
        const src = try PixelBuffer.init(px, .rgb8, w, h);
        const file = try encodeAlloc(&.{src}, .{ .compression = .none });
        defer gpa.free(file);
        _ = try expectPages(file, &.{src}, &.{.rgb8});
        const photometric = std.mem.readInt(u16, file[8 + 2 + 4 * 12 + 8 ..][0..2], .little);
        try testing.expectEqual(@as(u16, if (colors <= 256) 3 else 2), photometric);
        if (colors > 256) continue;
        // The palette's index width in BitsPerSample, the IFD's third entry.
        const bits = std.mem.readInt(u16, file[8 + 2 + 2 * 12 + 8 ..][0..2], .little);
        const want: u16 = if (colors <= 2) 1 else if (colors <= 4) 2 else if (colors <= 16) 4 else 8;
        try testing.expectEqual(want, bits);
    }
}

test "pages of different sizes and formats, read forward" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // Formats one native format holds, so the decoder takes every page.
    const a = try randomImage(random, .rgb8, 33, 20, 100);
    defer gpa.free(a.pixels);
    const b = try randomImage(random, .rgba16, 10, 70, 4);
    defer gpa.free(b.pixels);
    const c = try randomImage(random, .gray16, 5, 3, 100);
    defer gpa.free(c.pixels);
    for (std.enums.values(Compression)) |compression| {
        const file = try encodeAlloc(&.{ a, b, c }, .{ .compression = compression });
        defer gpa.free(file);
        const config = try expectPages(file, &.{ a, b, c }, &.{ .rgb8, .rgba16, .gray16 });
        try testing.expectEqual(3, config.frame_count);
        // Without a seeker the first page decodes, read forward.
        var r: Io.Reader = .fixed(file);
        var d: Decoder = .init(&r, .{});
        const first = try d.decodeConfig();
        try testing.expectEqual(.{ 33, 20 }, .{ first.width, first.height });
    }
}

test "density, strips, and the work memory" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const src = try randomImage(prng.random(), .rgb16, 30, 50, 100);
    defer gpa.free(src.pixels);
    for ([_]decode.Density{
        .{ .x = 300, .y = 150, .unit = .per_inch },
        .{ .x = 5000, .y = 2500, .unit = .per_meter },
        .{ .x = 2, .y = 1, .unit = .none },
    }) |density| {
        const file = try encodeAlloc(&.{src}, .{ .density = density, .rows_per_strip = 7 });
        defer gpa.free(file);
        const config = try expectPages(file, &.{src}, &.{.rgb16});
        try testing.expectEqual(density, config.metadata.density.?);
    }
    // About 8 KiB strips by default: 30 × 6 bytes a row, 45 rows.
    const file = try encodeAlloc(&.{src}, .{ .compression = .none });
    defer gpa.free(file);
    try testing.expectEqual(45, std.mem.readInt(u16, file[8 + 2 + 7 * 12 + 8 ..][0..2], .little));
    // One byte short of the work memory is refused.
    const work = try gpa.alloc(u8, workLen(.{}, 30, 50).?);
    defer gpa.free(work);
    var w: Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try testing.expectError(error.WorkTooSmall, encode(&w.writer, src, .{}, work[0 .. work.len - 1]));
    try testing.expectError(error.EmptyImage, encodePages(&w.writer, &.{}, .{}, work));
}

test "deflate's output buffer holds incompressible strips" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    for ([_]u32{ 1, 1000, 5000 }) |w| {
        const src = try randomImage(prng.random(), .rgba16, w, 3, 1000);
        defer gpa.free(src.pixels);
        for (std.enums.values(Compression)) |compression| {
            const file = try encodeAlloc(&.{src}, .{ .compression = compression, .predictor = false });
            defer gpa.free(file);
            _ = try expectPages(file, &.{src}, &.{.rgba16});
        }
    }
}
