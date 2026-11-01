//! TGA against Wuffs, the bar, stb_image, and ImageMagick
//! (test/oracle/tga.c).
//!
//! The three references disagree with each other on much of what the
//! specification leaves open, so this decoder agrees with one or two of
//! them on each point (docs/slop/tga.md has the choices):
//!
//! - Five-bit channels: Wuffs and this package widen by bit replication;
//!   stb_image truncates c * 255 / 31 and ImageMagick rounds it. `adapt`
//!   hands those two the colors already widened, so Wuffs checks the
//!   widening and all three check the rest.
//! - The attribute bit of 16-bit pixels: this package and ImageMagick read
//!   it as alpha when the descriptor names one attribute bit; Wuffs and
//!   stb_image ignore it. `comparable` leaves out Wuffs's answers with
//!   alpha for those files, and stb_image sees the widened file's alpha.
//!   ImageMagick also reads a 16-bit index's top bit as alpha.
//! - Run-length packets that cross a scan line: Wuffs rejects them, so
//!   `adapt` splits them for Wuffs. A packet past the last pixel: Wuffs and
//!   this package reject it; stb_image and ImageMagick drop the extra
//!   pixels.
//! - Right-to-left origins: Wuffs rejects them and stb_image ignores the
//!   bit, so `adapt` mirrors the file for both; ImageMagick reads it as it
//!   is and mirrors the rows, as this package does.
//! - Color maps: a first entry index other than 0 is unsupported in Wuffs,
//!   misread by stb_image (it skips that many bytes), and offsets the
//!   indices in ImageMagick and here; `adapt` hands Wuffs and stb_image the
//!   map with black entries in front instead. An index outside the map
//!   is opaque black in Wuffs and here, entry 0 in stb_image, and an error
//!   in ImageMagick; `adapt` hands stb_image a black entry after the map and
//!   the outside indices pointed at it. Wuffs misreads 16-bit
//!   indices, so `adapt` narrows them to 8 bits where the map leaves room
//!   and `comparable` drops its answers for a map of exactly 256 entries
//!   (it rejects longer maps); ImageMagick misreads them
//!   too (the top bit as alpha).
//! - 16-bit gray: gray and alpha in stb_image and here; Wuffs rejects it and
//!   ImageMagick reads it otherwise.
//! - A truncated file: stb_image fills the rest with zeros; the others
//!   reject it.
//! - A color map in a true-color or gray file: Wuffs and this package skip
//!   it, stb_image rejects the file, ImageMagick misreads it; and color-map
//!   fields that are not zero in a file without one, which Wuffs rejects.
//!   `adapt` hands every oracle the file without them.
//! - An empty image (zero width or height): Wuffs and this package decode
//!   it in some origins; stb_image and ImageMagick reject it. `comparable`
//!   leaves those files out.
//! - Asked for RGB from a file with alpha, Wuffs composites over black; the
//!   others drop the alpha (`image.convert`'s rule). `comparable` leaves
//!   out Wuffs's RGB answers for those files.

const std = @import("std");
const image = @import("image");

pub const name = "tga";
pub const Decoder = image.tga.Decoder;
pub const fuzz = @import("fuzz").tga;
pub const oracles = [_][]const u8{ "tga-wuffs", "tga-stb", "tga-magick" };
/// RGBA and RGB, which every oracle writes, and BGRA, Wuffs's and the
/// file's own order.
pub const formats = [_]image.PixelFormat{ .rgba8, .rgb8, .bgra8 };

/// Whether `op`'s answer in `format` counts: none for an empty image,
/// which only Wuffs decodes and only in some origins; not Wuffs's for
/// 16-bit indices `adapt` cannot narrow into a map it reads; not Wuffs's
/// alpha for a 16-bit file whose top bit is alpha, which it ignores; nor
/// Wuffs's RGB for a file with alpha, which it composites over black.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    const h = Header.parse(input) orelse return true;
    if (h.width == 0 or h.height == 0) return false;
    if (!std.mem.eql(u8, op, "tga-wuffs")) return true;
    // 16-bit indices into a map of exactly 256 entries, which Wuffs reads
    // (it rejects longer maps) and misreads, and `adapt` cannot narrow.
    const map_end = @as(usize, std.mem.readInt(u16, input[3..5], .little)) + std.mem.readInt(u16, input[5..7], .little);
    if (h.kind == 1 and h.depth == 16 and map_end == 256) return false;
    const alpha_bit = h.kind == 2 and h.depth == 16 and h.descriptor & 0xf != 0;
    if (alpha_bit and format.hasAlpha()) return false;
    // Wuffs reads such a file as opaque, so its RGB answer counts.
    const has_alpha = (h.kind == 2 and h.depth == 32) or (h.kind == 3 and h.depth == 16) or
        (h.kind == 1 and h.map_bits == 32);
    return !(has_alpha and format == .rgb8);
}

/// The input `op` sees, rewritten to an equivalent file where a reference
/// misreads the original:
///
/// - for every oracle, a true-color or gray file without its color map, and
///   with zero color-map fields when it has none (stb_image and ImageMagick
///   misread a map there, and Wuffs rejects nonzero fields);
/// - for Wuffs and stb_image, a color map that starts past entry 0 with
///   black entries in front, so it starts at 0;
/// - for stb_image and ImageMagick, 15- and 16-bit colors widened to 24
///   bits by bit replication (with the attribute bit as 8-bit alpha where
///   the descriptor names it), since each widens five bits its own way;
///   Wuffs widens as this package does and checks that;
/// - for stb_image, indices outside the color map pointed at an opaque
///   black entry added after it; for Wuffs, 16-bit indices as 8-bit ones;
/// - for Wuffs, run-length packets split at the end of each scan line;
/// - for Wuffs and stb_image, a right-to-left image mirrored into
///   left-to-right, its packets reversed in each line. ImageMagick reads
///   the original, so this package's mirroring is still checked.
///
/// A file whose pixels end early or run past the image keeps its pixels as
/// they are.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const wuffs = std.mem.eql(u8, op, "tga-wuffs");
    const stb = std.mem.eql(u8, op, "tga-stb");
    var file = try stripMap(input, arena);
    if (wuffs or stb) file = try rebaseMap(file, arena);
    var index: ?Reindex = null;
    if (stb) {
        // Out-of-range indices to a black entry appended to the map.
        if (try blackEntry(file, arena)) |z| {
            file = z.file;
            index = z.index;
        }
    } else if (wuffs) index = narrowIndex(file);
    if (!wuffs) file = try widenMap(file, arena);
    const h = Header.parse(file) orelse return file;
    const how: Repack = .{
        .mirror = h.descriptor & 0x10 != 0 and (wuffs or stb),
        .widen = !wuffs and h.kind == 2 and (h.depth == 15 or h.depth == 16),
        .index = index,
    };
    if (!how.mirror and !how.widen and how.index == null and !(h.rle and wuffs)) return file;
    return try repack(file, h, how, arena) orelse file;
}

/// How `repack` rewrites a color-mapped file's indices: those in
/// [first, first + len) stay, the rest become `outside`, each written in
/// `size` bytes.
const Reindex = struct { first: usize, len: usize, outside: usize, size: usize };

fn mapFields(f: []const u8) ?struct { first: usize, len: usize, entry: usize, index: usize } {
    if (f.len < 18 or f[1] != 1 or f[2] & ~@as(u8, 8) != 1 or (f[16] != 8 and f[16] != 16)) return null;
    return .{
        .first = std.mem.readInt(u16, f[3..5], .little),
        .len = std.mem.readInt(u16, f[5..7], .little),
        .entry = (@as(usize, f[7]) + 7) / 8,
        .index = f[16] / 8,
    };
}

/// For stb_image, which reads an index outside the map as entry 0: the
/// file with an opaque black entry after the map, which is what this
/// package reads such an index as, and the indices outside the map pointed
/// at it.
fn blackEntry(f: []const u8, arena: std.mem.Allocator) !?struct { file: []const u8, index: Reindex } {
    const m = mapFields(f) orelse return null;
    const end = m.first + m.len;
    if (m.entry > 4 or end >= @as(usize, 1) << @intCast(m.index * 8) or end >= 0xffff) return null;
    const at = 18 + @as(usize, f[0]) + m.len * m.entry;
    if (at > f.len) return null;
    const out = try arena.alloc(u8, f.len + m.entry);
    @memcpy(out[0..at], f[0..at]);
    @memcpy(out[at..][0..m.entry], black(m.entry));
    @memcpy(out[at + m.entry ..], f[at..]);
    std.mem.writeInt(u16, out[5..7], @intCast(m.len + 1), .little);
    return .{ .file = out, .index = .{ .first = m.first, .len = m.len + 1, .outside = end, .size = m.index } };
}

/// For Wuffs, which misreads 16-bit indices: 8-bit ones, when a map that
/// starts at entry 0 leaves index 255 outside it for the indices outside.
fn narrowIndex(f: []const u8) ?Reindex {
    const m = mapFields(f) orelse return null;
    if (m.index != 2 or m.first != 0 or m.len > 255) return null;
    return .{ .first = 0, .len = m.len, .outside = 255, .size = 1 };
}

const Header = struct {
    kind: u8,
    rle: bool,
    map_bits: u8,
    width: usize,
    height: usize,
    depth: u8,
    descriptor: u8,
    /// Bytes per stored pixel.
    bpp: usize,
    /// Where the pixels start.
    data: usize,

    fn parse(f: []const u8) ?Header {
        if (f.len < 18) return null;
        const entries: usize = std.mem.readInt(u16, f[5..7], .little);
        const map_bytes = if (f[1] == 1) entries * ((@as(usize, f[7]) + 7) / 8) else 0;
        return .{
            .kind = f[2] & ~@as(u8, 8),
            .rle = f[2] & 8 != 0,
            .map_bits = f[7],
            .width = std.mem.readInt(u16, f[12..14], .little),
            .height = std.mem.readInt(u16, f[14..16], .little),
            .depth = f[16],
            .descriptor = f[17],
            .bpp = @max(1, (@as(usize, f[16]) + 7) / 8),
            .data = 18 + @as(usize, f[0]) + map_bytes,
        };
    }
};

fn stripMap(input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (input.len < 18) return input;
    const kind = input[2] & ~@as(u8, 8);
    if (kind != 2 and kind != 3 or input[1] > 1) return input;
    if (input[1] == 0 and std.mem.allEqual(u8, input[3..8], 0)) return input;
    const map_len = @as(usize, std.mem.readInt(u16, input[5..7], .little)) * ((@as(usize, input[7]) + 7) / 8);
    const map_at = @min(input.len, 18 + @as(usize, input[0]));
    const skip = if (input[1] == 1) @min(input.len - map_at, map_len) else 0;
    const out = try arena.alloc(u8, input.len - skip);
    @memcpy(out[0..map_at], input[0..map_at]);
    @memcpy(out[map_at..], input[map_at + skip ..]);
    out[1] = 0;
    @memset(out[3..8], 0);
    return out;
}

/// A color-mapped file whose map starts past entry 0 with opaque black
/// entries in front, so its indices count from 0.
fn rebaseMap(f: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (f.len < 18 or f[1] != 1 or f[2] & ~@as(u8, 8) != 1) return f;
    const first: usize = std.mem.readInt(u16, f[3..5], .little);
    const entries: usize = std.mem.readInt(u16, f[5..7], .little);
    if (first == 0 or first + entries > 0xffff) return f;
    const size = (@as(usize, f[7]) + 7) / 8;
    if (size > 4) return f;
    const at = @min(f.len, 18 + @as(usize, f[0]));
    const out = try arena.alloc(u8, f.len + first * size);
    @memcpy(out[0..at], f[0..at]);
    for (0..first) |i| @memcpy(out[at + i * size ..][0..size], black(size));
    @memcpy(out[at + first * size ..], f[at..]);
    std.mem.writeInt(u16, out[3..5], 0, .little);
    std.mem.writeInt(u16, out[5..7], @intCast(first + entries), .little);
    return out;
}

/// An opaque black color-map entry of `size` bytes: alpha is the fourth
/// byte of a 32-bit entry, and 15- and 16-bit entries are opaque.
fn black(size: usize) []const u8 {
    return (&[4]u8{ 0, 0, 0, 255 })[0..size];
}

/// A color-mapped file's 15- or 16-bit map entries as 24-bit ones.
fn widenMap(f: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (f.len < 18 or f[1] != 1 or f[2] & ~@as(u8, 8) != 1 or (f[7] != 15 and f[7] != 16)) return f;
    const entries: usize = std.mem.readInt(u16, f[5..7], .little);
    const at = 18 + @as(usize, f[0]);
    if (at + entries * 2 > f.len) return f;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, f[0..at]);
    out.items[7] = 24;
    for (0..entries) |i| try out.appendSlice(arena, &widen5(std.mem.readInt(u16, f[at + i * 2 ..][0..2], .little)));
    try out.appendSlice(arena, f[at + entries * 2 ..]);
    return out.items;
}

/// Five-bit blue, green, and red, widened by bit replication.
fn widen5(v: u16) [3]u8 {
    var c: [3]u8 = undefined;
    for (&c, 0..) |*b, i| {
        const x: u8 = @intCast(v >> @intCast(5 * i) & 31);
        b.* = x << 3 | x >> 2;
    }
    return c;
}

const Repack = struct {
    /// Mirror right-to-left lines into left-to-right ones.
    mirror: bool,
    /// Widen 15- and 16-bit pixels to 24 or 32 bits.
    widen: bool,
    /// Rewrite color-map indices.
    index: ?Reindex = null,
};

/// One run-length packet, or a whole raw line for an uncompressed file:
/// `count` pixels of `bytes`, which hold one pixel for a run.
const Packet = struct { run: bool, count: usize, bytes: []const u8 };

/// `f` with its packets split at line ends, and mirrored and widened as
/// `how` says; null if the pixels end early or a packet runs past the
/// image.
fn repack(f: []const u8, h: Header, how: Repack, arena: std.mem.Allocator) !?[]const u8 {
    if (h.width == 0 or h.height == 0 or h.data > f.len) return null;
    const mirror = how.mirror;
    const alpha = how.widen and h.depth == 16 and h.descriptor & 0xf != 0;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, f[0..h.data]);
    if (mirror) out.items[17] &= ~@as(u8, 0x10);
    if (how.index) |r| out.items[16] = @intCast(r.size * 8);
    if (how.widen) {
        out.items[16] = if (alpha) 32 else 24;
        out.items[17] = out.items[17] & 0xf0 | @as(u8, if (alpha) 8 else 0);
    }
    var line: std.ArrayList(Packet) = .empty;
    var pos = h.data;
    // The part of a packet that runs into the next line.
    var pending: ?Packet = null;
    for (0..h.height) |_| {
        line.clearRetainingCapacity();
        var x: usize = 0;
        while (x < h.width) {
            var p: Packet = undefined;
            if (pending) |rest| {
                p = rest;
                pending = null;
            } else if (!h.rle) {
                const n = h.width * h.bpp;
                if (pos + n > f.len) return null;
                p = .{ .run = false, .count = h.width, .bytes = f[pos..][0..n] };
                pos += n;
            } else {
                if (pos >= f.len) return null;
                const count: usize = (f[pos] & 0x7f) + 1;
                const run = f[pos] & 0x80 != 0;
                const size = if (run) h.bpp else count * h.bpp;
                if (pos + 1 + size > f.len) return null;
                p = .{ .run = run, .count = count, .bytes = f[pos + 1 ..][0..size] };
                pos += 1 + size;
            }
            const k = @min(p.count, h.width - x);
            const bytes = if (p.run) p.bytes else p.bytes[0 .. k * h.bpp];
            try line.append(arena, .{ .run = p.run, .count = k, .bytes = bytes });
            if (k < p.count) pending = .{
                .run = p.run,
                .count = p.count - k,
                .bytes = if (p.run) p.bytes else p.bytes[k * h.bpp ..],
            };
            x += k;
        }
        const packets = line.items;
        if (mirror) std.mem.reverse(Packet, packets);
        for (packets) |p| {
            if (h.rle) try out.append(arena, @intCast(@as(usize, if (p.run) 0x80 else 0) | (p.count - 1)));
            const n = if (p.run) 1 else p.count;
            for (0..n) |j| {
                const i = if (mirror) n - 1 - j else j;
                const px = p.bytes[i * h.bpp ..][0..h.bpp];
                if (how.index) |r| {
                    const v: usize = if (h.bpp == 1) px[0] else std.mem.readInt(u16, px[0..2], .little);
                    const w = if (v >= r.first and v - r.first < r.len) v else r.outside;
                    if (r.size == 1) {
                        try out.append(arena, @intCast(w));
                    } else {
                        var le: [2]u8 = undefined;
                        std.mem.writeInt(u16, &le, @intCast(w), .little);
                        try out.appendSlice(arena, &le);
                    }
                    continue;
                }
                if (!how.widen) {
                    try out.appendSlice(arena, px);
                    continue;
                }
                const v = std.mem.readInt(u16, px[0..2], .little);
                try out.appendSlice(arena, &widen5(v));
                if (alpha) try out.append(arena, if (v & 0x8000 != 0) 255 else 0);
            }
        }
    }
    if (pending != null) return null;
    try out.appendSlice(arena, f[pos..]);
    return out.items;
}
