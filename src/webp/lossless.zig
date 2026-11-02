//! WebP lossless image streams (VP8L, RFC 9649 section 3): the bit reader,
//! prefix codes, the four transforms, and the LZ77 and color-cache coded
//! pixels, written from the specification. The container (Decoder.zig)
//! reads the 5-byte header; `decode` reads the rest of the stream and hands
//! each finished row to a `Sink` as ARGB.
//!
//! Work memory (`workLen`) is fixed by the image's size and the cap on
//! prefix code groups, before any of the stream is read:
//!
//! - the entropy-coded pixels, which LZ77 references reach back into: the
//!   whole image when it holds at most about a megapixel, and otherwise a
//!   ring of the last 2^20 + 2 rows' worth, since no distance is longer;
//! - two rows for the inverse transforms;
//! - the predictor, color transform, and entropy images, each at most one
//!   pixel per 4 by 4 block, and the 256-entry color table;
//! - the color cache, at most 2^11 entries;
//! - the prefix code tables: at most `max_groups` groups (and never more
//!   than the entropy image has pixels), each at most 10,024 bytes.
//!
//! Only what a stream uses is touched. Strict, as libwebp is: an
//! incomplete or oversubscribed prefix code, a backward reference before
//! the first pixel or past the last, a repeated transform, or a stream that
//! needs bits past its chunk is an error.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const Error = error{
    ReadFailed,
    Truncated,
    /// A prefix code is empty, incomplete, or oversubscribed, or reads past
    /// its alphabet.
    BadPrefixCode,
    /// The stream breaks the specification otherwise: a transform used
    /// twice, a color cache size outside 1 to 11 bits, or a backward
    /// reference before the first pixel or past the last.
    BadLossless,
    /// The image uses more prefix code groups than `max_groups`.
    Unsupported,
};

/// The longest backward reference distance, in pixels: distance codes
/// reach 2^20 - 120, and the neighborhood codes 7 rows and 8 pixels.
const max_distance = 1 << 20;
const green_base = 256 + 24;
const max_cache_bits = 11;
const max_green = green_base + (1 << max_cache_bits);

/// The most entries a two-level table with an 8-bit root takes for an
/// alphabet of `n` symbols and codes of at most 15 bits: zlib's
/// examples/enough.c gives n + 374 for 256 to 408 symbols (and the same
/// pattern holds above), and 410 for 40.
fn maxTable(n: usize) usize {
    return if (n <= 40) 410 else n + 374;
}

/// Table entries one group of five codes can take.
const group_entries = maxTable(max_green) + 3 * maxTable(256) + maxTable(40);

/// What a group cap of zero means: the most groups libwebp's encoder can
/// write, one per entropy image pixel at its largest (2600 pixels).
pub const default_max_groups = 2600;

/// Where each piece of work memory sits, in bytes from an 8-aligned base.
const Layout = struct {
    ring_pixels: usize,
    tiles: usize,
    groups: usize,
    ring: usize,
    rows: usize,
    pred: usize,
    color: usize,
    palette: usize,
    entropy: usize,
    cache: usize,
    used: usize,
    rank: usize,
    desc: usize,
    tables: usize,
    total: usize,

    fn init(width: u32, height: u32, max_groups: u32) ?Layout {
        const w: u64 = width;
        const h: u64 = height;
        const pixels = w * h;
        const tiles = ((w + 3) / 4) * ((h + 3) / 4);
        const ring_pixels = @min(pixels, max_distance + 2 * w);
        const groups = @max(1, @min(tiles, if (max_groups == 0) default_max_groups else max_groups));
        var l: Layout = undefined;
        var at: u64 = 0;
        const sizes = [_]u64{
            ring_pixels * 4,
            (2 * w + 1) * 4,
            tiles * 4,
            tiles * 4,
            256 * 4,
            tiles * 4,
            (1 << max_cache_bits) * 4,
            1024 * 8,
            1024 * 4,
            (groups + 1) * @sizeOf(Group),
            (groups + 1) * group_entries * 2,
        };
        var offsets: [sizes.len]u64 = undefined;
        for (sizes, &offsets) |s, *o| {
            o.* = at;
            at = std.mem.alignForward(u64, at + s, 8);
        }
        l = .{
            .ring_pixels = std.math.cast(usize, ring_pixels) orelse return null,
            .tiles = std.math.cast(usize, tiles) orelse return null,
            .groups = std.math.cast(usize, groups) orelse return null,
            .ring = std.math.cast(usize, offsets[0]) orelse return null,
            .rows = std.math.cast(usize, offsets[1]) orelse return null,
            .pred = std.math.cast(usize, offsets[2]) orelse return null,
            .color = std.math.cast(usize, offsets[3]) orelse return null,
            .palette = std.math.cast(usize, offsets[4]) orelse return null,
            .entropy = std.math.cast(usize, offsets[5]) orelse return null,
            .cache = std.math.cast(usize, offsets[6]) orelse return null,
            .used = std.math.cast(usize, offsets[7]) orelse return null,
            .rank = std.math.cast(usize, offsets[8]) orelse return null,
            .desc = std.math.cast(usize, offsets[9]) orelse return null,
            .tables = std.math.cast(usize, offsets[10]) orelse return null,
            // Slack to align the caller's buffer.
            .total = std.math.cast(usize, at + 8) orelse return null,
        };
        return l;
    }
};

/// Bytes of work memory `decode` needs for a `width` by `height` stream,
/// with at most `max_groups` prefix code groups (0 for
/// `default_max_groups`), or null if that overflows `usize`.
pub fn workLen(width: u32, height: u32, max_groups: u32) ?usize {
    const l = Layout.init(width, height, max_groups) orelse return null;
    return l.total;
}

/// Reads a chunk's bits least significant first, as VP8L packs them,
/// pulling from the container's reader no further than the chunk's end.
/// Past the end it reads zeros and remembers how many, so a stream that
/// needed them fails with `Truncated` at the next check.
pub const BitReader = struct {
    reader: *Io.Reader,
    /// Bytes of the chunk not yet taken from `reader`.
    left: u64,
    /// Bytes taken from the reader's buffer, not yet in `bits`. They stay
    /// valid until the reader is next called, which is only once `win`
    /// is empty.
    win: []const u8 = &.{},
    bits: u64 = 0,
    /// Bits in `bits`, real and zero padding.
    count: u32 = 0,
    /// Zero bits appended past the chunk's end, in all; the stream has
    /// overrun its chunk once `count < pad`.
    pad: u64 = 0,
    /// Why the reader stopped before the chunk's end.
    failed: ?Error = null,
    /// The chunk's bytes.
    size: u64,

    pub fn init(reader: *Io.Reader, len: u64) BitReader {
        return .{ .reader = reader, .left = len, .size = len };
    }

    /// Bytes of the chunk not yet read into bits, which the container
    /// skips after the stream.
    pub fn unread(br: *const BitReader) u64 {
        return br.left + br.win.len;
    }

    inline fn fill(br: *BitReader) void {
        if (br.count < 32) br.refill();
    }

    fn refill(br: *BitReader) void {
        if (br.win.len >= 8) {
            // Eight bytes at once. The bytes past `count` that land in
            // `bits` are the next ones in the stream, so loading them again
            // later ORs in the same values.
            const v = std.mem.readInt(u64, br.win[0..8], .little);
            br.bits |= v << @intCast(br.count);
            const k = (63 - br.count) >> 3;
            br.win = br.win[k..];
            br.count += k * 8;
            return;
        }
        br.refillSlow();
    }

    fn refillSlow(br: *BitReader) void {
        while (br.count <= 56) {
            if (br.win.len == 0 and !br.pull()) {
                // Past the chunk's end: zeros.
                br.bits &= (@as(u64, 1) << @intCast(br.count)) - 1;
                const n = (63 - br.count) & ~@as(u32, 7);
                br.count += n;
                br.pad += n;
                return;
            }
            br.bits |= @as(u64, br.win[0]) << @intCast(br.count);
            br.win = br.win[1..];
            br.count += 8;
        }
    }

    fn pull(br: *BitReader) bool {
        if (br.left == 0 or br.failed != null) return false;
        const got = br.reader.peekGreedy(1) catch |e| {
            br.failed = switch (e) {
                error.EndOfStream => error.Truncated,
                error.ReadFailed => error.ReadFailed,
            };
            return false;
        };
        const n: usize = @intCast(@min(got.len, br.left));
        br.win = got[0..n];
        br.reader.toss(n);
        br.left -= n;
        return true;
    }

    inline fn consume(br: *BitReader, n: u32) void {
        br.bits >>= @intCast(n);
        br.count -= n;
    }

    /// `n` bits, at most 24.
    pub fn read(br: *BitReader, n: u5) u32 {
        br.fill();
        const v: u32 = @truncate(br.bits & ((@as(u64, 1) << n) - 1));
        br.consume(n);
        return v;
    }

    /// Fails if the stream has read past its chunk.
    pub fn check(br: *const BitReader) Error!void {
        if (br.count < br.pad) return br.failed orelse error.Truncated;
    }
};

/// A prefix code's table: where it starts in the tables, and its root
/// bits. An entry is 16 bits, the low 12 a symbol (or a second-level
/// table's offset) and the high 4 a length: in the root, at most the root
/// bits for a symbol, and 8 plus a second-level table's bits for a link.
const Group = extern struct {
    table: [5]u32,
    root: [5]u8,
    /// Red, blue, and alpha each have one symbol, so a literal's other
    /// channels are `literal` with green ORed in.
    trivial: bool,
    _pad: [2]u8 = .{ 0, 0 },
    literal: u32,
};

const Code = struct { table: u32, root: u8 };

/// Decodes one symbol with the code at `table` (root bits `root`).
inline fn readSymbol(br: *BitReader, tables: []const u16, table: u32, root: u8) u16 {
    br.fill();
    const mask = (@as(u32, 1) << @intCast(root)) - 1;
    const e = tables[table + (@as(u32, @truncate(br.bits)) & mask)];
    const len = e >> 12;
    if (len <= 8) {
        br.consume(len);
        return e & 0xfff;
    }
    br.consume(8);
    const sub = (@as(u32, 1) << @intCast(len - 8)) - 1;
    const e2 = tables[table + (e & 0xfff) + (@as(u32, @truncate(br.bits)) & sub)];
    br.consume(e2 >> 12);
    return e2 & 0xfff;
}

/// A `BitReader`'s bit buffer held in locals by the pixel loop, so the
/// compiler keeps it in registers; the rest of the reader stays put.
const Hot = struct {
    bits: u64,
    count: u32,

    fn store(h: *const Hot, br: *BitReader) void {
        br.bits = h.bits;
        br.count = h.count;
    }

    inline fn fill(h: *Hot, br: *BitReader) void {
        if (h.count >= 32) return;
        if (br.win.len >= 8) {
            const v = std.mem.readInt(u64, br.win[0..8], .little);
            h.bits |= v << @intCast(h.count);
            const k = (63 - h.count) >> 3;
            br.win = br.win[k..];
            h.count += k * 8;
            return;
        }
        h.store(br);
        br.refillSlow();
        h.bits = br.bits;
        h.count = br.count;
    }

    inline fn consume(h: *Hot, n: u32) void {
        h.bits >>= @intCast(n);
        h.count -= n;
    }

    inline fn symbol(h: *Hot, br: *BitReader, tables: []const u16, table: u32, root: u8) u16 {
        h.fill(br);
        const mask = (@as(u32, 1) << @intCast(root)) - 1;
        const e = tables[table + (@as(u32, @truncate(h.bits)) & mask)];
        const len = e >> 12;
        if (len <= 8) {
            h.consume(len);
            return e & 0xfff;
        }
        h.consume(8);
        const sub = (@as(u32, 1) << @intCast(len - 8)) - 1;
        const e2 = tables[table + (e & 0xfff) + (@as(u32, @truncate(h.bits)) & sub)];
        h.consume(e2 >> 12);
        return e2 & 0xfff;
    }

    inline fn prefix(h: *Hot, br: *BitReader, sym: u32) u32 {
        if (sym < 4) return sym + 1;
        const extra: u5 = @intCast((sym - 2) >> 1);
        h.fill(br);
        const v: u32 = @truncate(h.bits & ((@as(u64, 1) << extra) - 1));
        h.consume(extra);
        return ((2 + (sym & 1)) << extra) + v + 1;
    }
};

/// The next code in canonical order, bit-reversed as the table indexes
/// it, after `key` of length `len`.
fn nextKey(key: u32, len: u32) u32 {
    var step = @as(u32, 1) << @intCast(len - 1);
    while (key & step != 0) step >>= 1;
    return if (step != 0) (key & (step - 1)) + step else 0;
}

fn entry(len: u32, value: u32) u16 {
    return @intCast(len << 12 | value);
}

/// Builds the table for the code whose lengths are `lengths` into the
/// front of `out`, returning its root bits and the entries it took.
fn build(out: []u16, lengths: []const u8) Error!struct { root: u8, len: usize } {
    var count: [16]u16 = @splat(0);
    for (lengths) |l| count[l] += 1;
    const n = lengths.len - count[0];
    if (n == 0) return error.BadPrefixCode;
    if (n == 1) {
        const sym = for (lengths, 0..) |l, i| {
            if (l != 0) break i;
        } else unreachable;
        if (out.len < 1) return error.Unsupported;
        out[0] = entry(0, @intCast(sym));
        return .{ .root = 0, .len = 1 };
    }
    // Complete: the lengths fill the code space exactly.
    var left: i32 = 1;
    var max_len: u32 = 0;
    for (1..16) |l| {
        left = left * 2 - count[l];
        if (left < 0) return error.BadPrefixCode;
        if (count[l] != 0) max_len = @intCast(l);
    }
    if (left != 0) return error.BadPrefixCode;

    var offsets: [16]u16 = undefined;
    offsets[1] = 0;
    for (1..15) |l| offsets[l + 1] = offsets[l] + count[l];
    var sorted: [max_green]u16 = undefined;
    for (lengths, 0..) |l, i| {
        if (l == 0) continue;
        sorted[offsets[l]] = @intCast(i);
        offsets[l] += 1;
    }

    const root: u32 = @min(8, max_len);
    const root_size = @as(u32, 1) << @intCast(root);
    if (out.len < root_size) return error.Unsupported;
    var key: u32 = 0;
    var s: usize = 0;
    var l: u32 = 1;
    while (l <= root) : (l += 1) {
        var k = count[l];
        while (k > 0) : (k -= 1) {
            const e = entry(l, sorted[s]);
            s += 1;
            var i = key;
            while (i < root_size) : (i += @as(u32, 1) << @intCast(l)) out[i] = e;
            key = nextKey(key, l);
        }
    }
    var end: u32 = root_size;
    var low: u32 = std.math.maxInt(u32);
    var sub_at: u32 = 0;
    var sub_bits: u32 = 0;
    var remaining = count;
    while (l <= max_len) : (l += 1) {
        while (remaining[l] > 0) : (remaining[l] -= 1) {
            if (key & (root_size - 1) != low) {
                // A new second-level table, as large as the codes that
                // share this root need.
                var ll = l;
                var room: i32 = @as(i32, 1) << @intCast(ll - root);
                while (ll < 15) {
                    room -= remaining[ll];
                    if (room <= 0) break;
                    ll += 1;
                    room <<= 1;
                }
                sub_bits = ll - root;
                sub_at = end;
                end += @as(u32, 1) << @intCast(sub_bits);
                if (end > out.len or sub_at > 0xfff) return error.Unsupported;
                low = key & (root_size - 1);
                out[low] = entry(8 + sub_bits, sub_at);
            }
            const e = entry(l - root, sorted[s]);
            s += 1;
            const size = @as(u32, 1) << @intCast(sub_bits);
            var i = key >> @intCast(root);
            while (i < size) : (i += @as(u32, 1) << @intCast(l - root)) out[sub_at + i] = e;
            key = nextKey(key, l);
        }
    }
    return .{ .root = @intCast(root), .len = end };
}

const code_length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// Reads one prefix code over `alphabet` symbols and builds its table at
/// the front of `out`.
fn readCode(br: *BitReader, alphabet: usize, out: []u16) Error!struct { root: u8, len: usize } {
    var lengths: [max_green]u8 = undefined;
    const lens = lengths[0..alphabet];
    @memset(lens, 0);
    if (br.read(1) == 1) {
        // Simple: one or two symbols of length 1. A symbol outside the
        // alphabet is dropped, as libwebp drops it.
        const two = br.read(1) == 1;
        const first = br.read(if (br.read(1) == 1) 8 else 1);
        if (first < alphabet) lens[first] = 1;
        if (two) {
            const second = br.read(8);
            if (second < alphabet) lens[second] = 1;
        }
    } else {
        var cl: [19]u8 = @splat(0);
        const n = 4 + br.read(4);
        for (code_length_order[0..n]) |i| cl[i] = @intCast(br.read(3));
        var cl_table: [128]u16 = undefined;
        const clt = try build(&cl_table, &cl);
        var max_symbol: usize = alphabet;
        if (br.read(1) == 1) {
            const nbits: u5 = @intCast(2 + 2 * br.read(3));
            max_symbol = 2 + br.read(nbits);
            if (max_symbol > alphabet) return error.BadPrefixCode;
        }
        var prev: u8 = 8;
        var sym: usize = 0;
        while (sym < alphabet) {
            if (max_symbol == 0) break;
            max_symbol -= 1;
            const c = readSymbol(br, &cl_table, 0, clt.root);
            if (c < 16) {
                lens[sym] = @intCast(c);
                sym += 1;
                if (c != 0) prev = @intCast(c);
                continue;
            }
            const repeat: usize = switch (c) {
                16 => 3 + br.read(2),
                17 => 3 + br.read(3),
                else => 11 + br.read(7),
            };
            if (sym + repeat > alphabet) return error.BadPrefixCode;
            @memset(lens[sym..][0..repeat], if (c == 16) prev else 0);
            sym += repeat;
        }
    }
    try br.check();
    const b = try build(out, lens);
    return .{ .root = b.root, .len = b.len };
}

/// Reads a group's five codes into the tables at `at`, returning the
/// group and the entries it took.
fn readGroup(br: *BitReader, cache_size: usize, tables: []u16, at: usize) Error!struct { group: Group, len: usize } {
    const alphabets = [5]usize{ green_base + cache_size, 256, 256, 256, 40 };
    var g: Group = .{ .table = undefined, .root = undefined, .trivial = false, .literal = 0 };
    var used: usize = 0;
    for (alphabets, 0..) |a, i| {
        const c = try readCode(br, a, tables[at + used ..]);
        g.table[i] = @intCast(at + used);
        g.root[i] = c.root;
        used += c.len;
    }
    // One symbol each in red, blue, and alpha: a literal needs only green.
    g.trivial = g.root[1] == 0 and g.root[2] == 0 and g.root[3] == 0;
    if (g.trivial) {
        const r: u32 = tables[g.table[1]] & 0xfff;
        const b: u32 = tables[g.table[2]] & 0xfff;
        const a: u32 = tables[g.table[3]] & 0xfff;
        g.literal = a << 24 | r << 16 | b;
    }
    return .{ .group = g, .len = used };
}

/// A length or distance from its prefix symbol and extra bits.
inline fn prefixValue(br: *BitReader, sym: u32) u32 {
    if (sym < 4) return sym + 1;
    const extra: u5 = @intCast((sym - 2) >> 1);
    const offset = (2 + (sym & 1)) << extra;
    return offset + br.read(extra) + 1;
}

/// The neighborhood a distance code of 1 to 120 names: (columns left,
/// rows up) as (xi, yi).
const plane = [120][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },  .{ 1, 2 },  .{ -1, 2 },
    .{ 2, 1 },  .{ -2, 1 }, .{ 2, 2 },  .{ -2, 2 }, .{ 0, 3 },  .{ 3, 0 },  .{ 1, 3 },  .{ -1, 3 },
    .{ 3, 1 },  .{ -3, 1 }, .{ 2, 3 },  .{ -2, 3 }, .{ 3, 2 },  .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },
    .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 }, .{ 3, 3 },  .{ -3, 3 }, .{ 2, 4 },  .{ -2, 4 },
    .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },  .{ 3, 4 },  .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },
    .{ 1, 5 },  .{ -1, 5 }, .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 },
    .{ 4, 4 },  .{ -4, 4 }, .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 }, .{ 0, 6 },  .{ 6, 0 },
    .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 }, .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },  .{ -6, 2 },
    .{ 4, 5 },  .{ -4, 5 }, .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 }, .{ 6, 3 },  .{ -6, 3 },
    .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },  .{ -5, 5 }, .{ 7, 1 },  .{ -7, 1 },
    .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 }, .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 },
    .{ 3, 7 },  .{ -3, 7 }, .{ 7, 3 },  .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 },
    .{ 8, 0 },  .{ 4, 7 },  .{ -4, 7 }, .{ 7, 4 },  .{ -7, 4 }, .{ 8, 1 },  .{ 8, 2 },  .{ 6, 6 },
    .{ -6, 6 }, .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 }, .{ 7, 5 },  .{ -7, 5 }, .{ 8, 4 },  .{ 6, 7 },
    .{ -6, 7 }, .{ 7, 6 },  .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },  .{ 8, 7 },
};

fn distance(code: u32, width: u32) u32 {
    if (code > 120) return code - 120;
    const xy = plane[code - 1];
    const d = @as(i64, xy[0]) + @as(i64, xy[1]) * width;
    return if (d < 1) 1 else @intCast(d);
}

/// Receives each decoded row of the image, `width` ARGB pixels (alpha in
/// the high byte), which it may overwrite.
pub const Sink = struct {
    context: *anyopaque,
    row: *const fn (context: *anyopaque, y: u32, argb: []u32) void,
};

const Kind = enum(u2) { predictor, color, subtract_green, color_index };

const Transform = struct {
    kind: Kind,
    /// Block size bits, or for color indexing the bundling bits.
    bits: u5 = 0,
    /// The width the transform sees: its output's, except for color
    /// indexing, whose input is bundled and whose output is `full`.
    width: u32,
    full: u32 = 0,
    data: []const u32 = &.{},
};

/// The state of one stream's decode, over the caller's work memory.
const Stream = struct {
    br: *BitReader,
    width: u32,
    height: u32,
    max_groups: usize,
    ring: []u32,
    rows: []u32,
    pred: []u32,
    color: []u32,
    palette: []u32,
    entropy: []u32,
    cache: []u32,
    used: []u64,
    rank: []u32,
    groups: []Group,
    tables: []u16,
    transforms: [4]Transform = undefined,
    n_transforms: u8 = 0,
    /// The largest group index the entropy image names.
    max_index: u32 = 0,
    /// Groups read for the main image.
    n_groups: usize = 0,
    /// An ALPH chunk's stream, which libwebp reads in its own way when it
    /// can (`tailRead`).
    alpha: bool,
    /// Whether the stream may read past its end in its last symbol.
    tail_read: bool = false,
    sink: Sink,

    /// The entropy-coded pixels of a `w` by `h` image into `out` (a ring
    /// of whole rows when `main`), with the codes that follow.
    fn image(s: *Stream, comptime main: bool, out: []u32, w: u32, h: u32) Error!void {
        const br = s.br;
        var cache_bits: u5 = 0;
        if (br.read(1) == 1) {
            const b = br.read(4);
            if (b < 1 or b > max_cache_bits) return error.BadLossless;
            cache_bits = @intCast(b);
        }
        const cache_size: usize = if (cache_bits == 0) 0 else @as(usize, 1) << cache_bits;
        var tile_bits: u5 = 31;
        var tiles_w: u32 = 1;
        var meta = false;
        if (main and br.read(1) == 1) {
            meta = true;
            tile_bits = @intCast(br.read(3) + 2);
            tiles_w = divRoundUp(w, tile_bits);
            const tiles_h = divRoundUp(h, tile_bits);
            const n = @as(usize, tiles_w) * tiles_h;
            try s.image(false, s.entropy[0..n], tiles_w, tiles_h);
            try s.remap(s.entropy[0..n]);
        }
        try s.readGroups(meta, cache_size);
        try br.check();
        if (main) s.tail_read = s.tailRead(cache_bits);
        @memset(s.cache[0..cache_size], 0);
        try s.pixels(main, out, w, h, cache_bits, tile_bits, tiles_w);
    }

    /// Replaces each entropy image pixel by the slot of its group among
    /// the groups used, which `readGroups` stores in order.
    fn remap(s: *Stream, ent: []u32) Error!void {
        @memset(s.used, 0);
        var max: u32 = 0;
        for (ent) |e| {
            const v = (e >> 8) & 0xffff;
            s.used[v >> 6] |= @as(u64, 1) << @intCast(v & 63);
            max = @max(max, v);
        }
        var total: u32 = 0;
        for (s.used, s.rank) |u, *r| {
            r.* = total;
            total += @popCount(u);
        }
        if (total > s.max_groups) return error.Unsupported;
        for (ent) |*e| {
            const v = (e.* >> 8) & 0xffff;
            const below = s.used[v >> 6] & ((@as(u64, 1) << @intCast(v & 63)) - 1);
            e.* = s.rank[v >> 6] + @popCount(below);
        }
        s.max_index = max;
    }

    fn readGroups(s: *Stream, meta: bool, cache_size: usize) Error!void {
        const count: u32 = if (meta) s.max_index + 1 else 1;
        var at: usize = 0;
        var slot: usize = 0;
        for (0..count) |gi| {
            const used = !meta or s.used[gi >> 6] & (@as(u64, 1) << @intCast(gi & 63)) != 0;
            const r = try readGroup(s.br, cache_size, s.tables, at);
            // An unused group is read into the space after the last used
            // one, and dropped.
            if (used) {
                s.groups[slot] = r.group;
                slot += 1;
                at += r.len;
            }
        }
        s.n_groups = slot;
    }

    /// libwebp decodes an alpha stream whose only transform is color
    /// indexing, without a color cache, and whose literals are green
    /// alone, a byte a pixel, checking for its end only between symbols
    /// that leave pixels to decode: the last symbol may read past the end,
    /// zeros for a literal. Other streams fail if they read past it at all.
    fn tailRead(s: *const Stream, cache_bits: u5) bool {
        if (!s.alpha or cache_bits != 0) return false;
        if (s.n_transforms != 1 or s.transforms[0].kind != .color_index) return false;
        for (s.groups[0..s.n_groups]) |g| if (!g.trivial) return false;
        return true;
    }

    fn pixels(
        s: *Stream,
        comptime main: bool,
        out: []u32,
        w: u32,
        h: u32,
        cache_bits: u5,
        tile_bits: u5,
        tiles_w: u32,
    ) Error!void {
        const br = s.br;
        // The bits live in locals for the loop, so they stay in registers;
        // `br` has them again before anything else reads it.
        var hot: Hot = .{ .bits = br.bits, .count = br.count };
        defer hot.store(br);
        const tables = s.tables;
        const total = w * h;
        // The ring holds whole rows; a sub-image is never a ring.
        const rows_kept: u32 = if (main) @intCast(@min(h, out.len / w)) else h;
        const ring_len = rows_kept * w;
        const ring = out[0..ring_len];
        const cache = s.cache;
        const shift: u5 = if (cache_bits == 0) 0 else @intCast(32 - @as(u32, cache_bits));
        const use_cache = cache_bits != 0;
        const tile_mask: u32 = if (tile_bits == 31) std.math.maxInt(u32) else (@as(u32, 1) << tile_bits) - 1;
        var p: u32 = 0;
        var x: u32 = 0;
        var y: u32 = 0;
        var ri: u32 = 0;
        var g = &s.groups[0];
        // libwebp's bit window is eight bytes: a stream shorter than that
        // reads as zeros to the window's end, which this does not do.
        const tail_read = main and s.tail_read and br.size >= 8;
        while (p < total) {
            // The real bits left, for a last literal that reads past them.
            var real: i64 = 0;
            if (tail_read) {
                if (hot.count < br.pad) return br.failed orelse error.Truncated;
                real = @as(i64, hot.count) - @as(i64, @intCast(br.pad)) + 8 * @as(i64, @intCast(br.win.len + br.left));
            }
            if (x & tile_mask == 0) {
                if (tile_bits != 31) g = &s.groups[s.entropy[(y >> tile_bits) * tiles_w + (x >> tile_bits)]];
            }
            const sym = hot.symbol(br, tables, g.table[0], g.root[0]);
            if (sym < 256) {
                if (tail_read and hot.count < br.pad) {
                    // libwebp looks the code up in its last eight bytes
                    // with zeros above, 8 bits and then the rest; a lookup
                    // that starts at or past their end wraps around to
                    // their start instead.
                    const len = real + @as(i64, @intCast(br.pad)) - hot.count;
                    if (real == 0 or (len > 8 and real <= 8)) return br.failed orelse error.Truncated;
                }
                var c: u32 = undefined;
                if (g.trivial) {
                    c = g.literal | @as(u32, sym) << 8;
                } else {
                    const r: u32 = hot.symbol(br, tables, g.table[1], g.root[1]);
                    const b: u32 = hot.symbol(br, tables, g.table[2], g.root[2]);
                    const a: u32 = hot.symbol(br, tables, g.table[3], g.root[3]);
                    c = a << 24 | r << 16 | @as(u32, sym) << 8 | b;
                }
                ring[ri] = c;
                if (use_cache) cache[(0x1e35a7bd *% c) >> shift] = c;
                p += 1;
                x += 1;
                ri += 1;
            } else if (sym < green_base) {
                const len = hot.prefix(br, sym - 256);
                const dsym = hot.symbol(br, tables, g.table[4], g.root[4]);
                const dist = distance(hot.prefix(br, dsym), w);
                // libwebp reads a backward reference's code past the end
                // in its own way: only a last literal may read zeros.
                if (tail_read and hot.count < br.pad) return br.failed orelse error.Truncated;
                if (dist > p or len > total - p) return error.BadLossless;
                var left = len;
                while (true) {
                    const n = @min(left, w - x);
                    const dst = ring[ri..][0..n];
                    const si = if (ri >= dist) ri - dist else ri + ring_len - dist;
                    if (si + n <= ring_len) {
                        // Forward, so an overlapping copy repeats its
                        // pattern, as LZ77 means.
                        const src = ring[si..][0..n];
                        for (dst, src) |*d, v| d.* = v;
                    } else {
                        const k = ring_len - si;
                        for (dst[0..k], ring[si..ring_len]) |*d, v| d.* = v;
                        for (dst[k..], ring[0 .. n - k]) |*d, v| d.* = v;
                    }
                    if (use_cache) for (dst) |c| {
                        cache[(0x1e35a7bd *% c) >> shift] = c;
                    };
                    p += n;
                    x += n;
                    ri += n;
                    left -= n;
                    if (left == 0) break;
                    // The copy reached the end of the row.
                    if (main) {
                        hot.store(br);
                        try s.rowDone(y, ring[ri - w .. ri]);
                    }
                    x = 0;
                    y += 1;
                    if (ri == ring_len) ri = 0;
                }
                if (x & tile_mask != 0 and tile_bits != 31) {
                    g = &s.groups[s.entropy[(y >> tile_bits) * tiles_w + (x >> tile_bits)]];
                }
            } else {
                const c = cache[sym - green_base];
                ring[ri] = c;
                cache[(0x1e35a7bd *% c) >> shift] = c;
                p += 1;
                x += 1;
                ri += 1;
            }
            if (x == w) {
                if (main) {
                    hot.store(br);
                    try s.rowDone(y, ring[ri - w .. ri]);
                }
                x = 0;
                y += 1;
                if (ri == ring_len) ri = 0;
            }
        }
        hot.store(br);
        if (!tail_read) return br.check();
        if (br.count < br.pad) if (br.failed) |f| return f;
    }

    /// Row `y` of the entropy-coded image is whole: undo the transforms
    /// and hand the row to the sink.
    fn rowDone(s: *Stream, y: u32, coded: []const u32) Error!void {
        if (!s.tail_read) try s.br.check();
        const row = s.rows[0..s.width];
        const prev = s.rows[s.width..];
        @memcpy(row[0..coded.len], coded);
        var i = s.n_transforms;
        while (i > 0) {
            i -= 1;
            const t = &s.transforms[i];
            switch (t.kind) {
                .predictor => {
                    predictRow(t, y, row[0..t.width], prev[0 .. t.width + 1]);
                    @memcpy(prev[0..t.width], row[0..t.width]);
                },
                .color => colorRow(t, y, row[0..t.width]),
                .subtract_green => addGreen(row[0..t.width]),
                .color_index => indexRow(t, row[0..t.full]),
            }
        }
        s.sink.row(s.sink.context, y, row);
    }
};

fn divRoundUp(n: u32, bits: u5) u32 {
    return @intCast((@as(u64, n) + (@as(u64, 1) << bits) - 1) >> bits);
}

/// Adds two pixels channel by channel, modulo 256.
inline fn add(a: u32, b: u32) u32 {
    const ag = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const rb = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}

const Px = @Vector(4, u8);
const Wide = @Vector(4, i16);

inline fn lanes(c: u32) Px {
    return @bitCast(std.mem.nativeToLittle(u32, c));
}

inline fn pixel(v: Px) u32 {
    return std.mem.littleToNative(u32, @bitCast(v));
}

/// The channel-wise average of two pixels' lanes, rounded down.
inline fn avgV(a: Px, b: Px) Px {
    return (a & b) +% ((a ^ b) >> @splat(1));
}

inline fn sadV(a: Px, b: Px) u16 {
    return @reduce(.Add, @as(@Vector(4, u16), @max(a, b) - @min(a, b)));
}

inline fn clampV(v: Wide) Px {
    return @intCast(@min(@max(v, @as(Wide, @splat(0))), @as(Wide, @splat(255))));
}

/// Predictor `mode` from the left, top-left, top, and top-right pixels.
inline fn predict(comptime mode: u4, l: Px, tl: Px, t: Px, tr: Px) Px {
    return switch (mode) {
        1 => l,
        2 => t,
        3 => tr,
        4 => tl,
        5 => avgV(avgV(l, tr), t),
        6 => avgV(l, tl),
        7 => avgV(l, t),
        8 => avgV(tl, t),
        9 => avgV(t, tr),
        10 => avgV(avgV(l, tl), avgV(t, tr)),
        // |estimate - L| is |T - TL|, and |estimate - T| is |L - TL|.
        11 => if (sadV(t, tl) < sadV(l, tl)) l else t,
        12 => clampV(@as(Wide, l) + @as(Wide, t) - @as(Wide, tl)),
        13 => blk: {
            const a: Wide = avgV(l, t);
            break :blk clampV(a + @divTrunc(a - @as(Wide, tl), @as(Wide, @splat(2))));
        },
        // 0, and 14 and 15, which libwebp reads as 0.
        else => .{ 0, 0, 0, 255 },
    };
}

/// Whether `mode` predicts from the row above alone, so a run of pixels can
/// be predicted at once.
fn fromAbove(mode: u4) bool {
    return switch (mode) {
        0, 2, 3, 4, 8, 9, 14, 15 => true,
        else => false,
    };
}

/// Undoes the predictor transform on row `y` in place. `prev` is the
/// row above, after this transform, with one more element for the
/// rightmost pixel's top-right, which is the row's own first pixel.
fn predictRow(t: *const Transform, y: u32, row: []u32, prev: []u32) void {
    const w = row.len;
    if (y == 0) {
        row[0] = add(row[0], 0xff000000);
        for (1..w) |x| row[x] = add(row[x], row[x - 1]);
        return;
    }
    row[0] = add(row[0], prev[0]);
    prev[w] = row[0];
    const tw = divRoundUp(t.width, t.bits);
    const modes = t.data[(y >> t.bits) * tw ..];
    var x: usize = 1;
    while (x < w) {
        const end = @min(w, ((x >> t.bits) + 1) << t.bits);
        const mode: u4 = @truncate(modes[x >> t.bits] >> 8);
        switch (mode) {
            inline else => |m| if (comptime fromAbove(m)) {
                predictAbove(m, row[x..end], prev[x - 1 .. end + 1]);
            } else {
                var l = lanes(row[x - 1]);
                for (x..end) |i| {
                    l = lanes(row[i]) +% predict(m, l, lanes(prev[i - 1]), lanes(prev[i]), lanes(prev[i + 1]));
                    row[i] = pixel(l);
                }
            },
        }
        x = end;
    }
}

/// A run of pixels whose predictor reads only the row above: `above` is
/// that row from one pixel left of the run to one right of it.
fn predictAbove(comptime mode: u4, run: []u32, above: []const u32) void {
    const n = 8;
    const V = @Vector(n * 4, u8);
    var i: usize = 0;
    while (i + n <= run.len) : (i += n) {
        const tl: V = @bitCast(above[i..][0..n].*);
        const t: V = @bitCast(above[i + 1 ..][0..n].*);
        const tr: V = @bitCast(above[i + 2 ..][0..n].*);
        const p: V = switch (mode) {
            2 => t,
            3 => tr,
            4 => tl,
            8 => (tl & t) +% ((tl ^ t) >> @splat(1)),
            9 => (t & tr) +% ((t ^ tr) >> @splat(1)),
            else => @bitCast(@as(@Vector(n, u32), @splat(0xff000000))),
        };
        const r: V = @bitCast(run[i..][0..n].*);
        run[i..][0..n].* = @bitCast(r +% p);
    }
    for (i..run.len) |k| {
        const p = predict(mode, undefined, lanes(above[k]), lanes(above[k + 1]), lanes(above[k + 2]));
        run[k] = pixel(lanes(run[k]) +% p);
    }
}

/// Undoes the subtract green transform: green is added to red and blue,
/// eight pixels at a time.
fn addGreen(row: []u32) void {
    const V = @Vector(8, u32);
    var i: usize = 0;
    while (i + 8 <= row.len) : (i += 8) {
        const c: V = row[i..][0..8].*;
        const g = (c >> @splat(8)) & @as(V, @splat(0xff));
        const rb = ((c & @as(V, @splat(0x00ff00ff))) +% (g << @splat(16) | g)) & @as(V, @splat(0x00ff00ff));
        row[i..][0..8].* = (c & @as(V, @splat(0xff00ff00))) | rb;
    }
    for (row[i..]) |*px| {
        const g = (px.* >> 8) & 0xff;
        px.* = (px.* & 0xff00ff00) | (((px.* & 0x00ff00ff) +% (g << 16 | g)) & 0x00ff00ff);
    }
}

inline fn delta(t: u32, c: u32) u32 {
    const a: i32 = @as(i8, @bitCast(@as(u8, @truncate(t))));
    const b: i32 = @as(i8, @bitCast(@as(u8, @truncate(c))));
    return @bitCast((a * b) >> 5);
}

fn colorRow(t: *const Transform, y: u32, row: []u32) void {
    const tw = divRoundUp(t.width, t.bits);
    const elems = t.data[(y >> t.bits) * tw ..];
    var x: usize = 0;
    while (x < row.len) {
        const end = @min(row.len, ((x >> t.bits) + 1) << t.bits);
        colorSpan(elems[x >> t.bits], row[x..end]);
        x = end;
    }
}

/// The inverse color transform with one element, eight pixels at a time:
/// red gains green times green_to_red, and blue gains green times
/// green_to_blue and the new red times red_to_blue, each product of signed
/// bytes shifted right 5.
fn colorSpan(e: u32, span: []u32) void {
    const n = 8;
    const V = @Vector(n, u32);
    const S = @Vector(n, i32);
    const g2r: S = @splat(@as(i8, @bitCast(@as(u8, @truncate(e)))));
    const g2b: S = @splat(@as(i8, @bitCast(@as(u8, @truncate(e >> 8)))));
    const r2b: S = @splat(@as(i8, @bitCast(@as(u8, @truncate(e >> 16)))));
    const byte: V = @splat(0xff);
    var i: usize = 0;
    while (i + n <= span.len) : (i += n) {
        const c: V = span[i..][0..n].*;
        const g: S = @as(S, @bitCast(c << @splat(16))) >> @splat(24);
        const r = (c >> @splat(16)) +% @as(V, @bitCast((g2r * g) >> @splat(5)));
        const rs: S = @as(S, @bitCast(r << @splat(24))) >> @splat(24);
        const b = c +% @as(V, @bitCast((g2b * g) >> @splat(5))) +% @as(V, @bitCast((r2b * rs) >> @splat(5)));
        span[i..][0..n].* = (c & @as(V, @splat(0xff00ff00))) | ((r & byte) << @splat(16)) | (b & byte);
    }
    for (span[i..]) |*px| {
        const c = px.*;
        const g = c >> 8;
        const r = ((c >> 16) +% delta(e, g)) & 0xff;
        const b = (c +% delta(e >> 8, g) +% delta(e >> 16, r)) & 0xff;
        px.* = (c & 0xff00ff00) | r << 16 | b;
    }
}

/// Undoes color indexing in place: each pixel's index, bundled into the
/// first `t.width` pixels, becomes its color. Right to left, since a
/// bundled pixel is never to the right of the pixels it holds.
fn indexRow(t: *const Transform, row: []u32) void {
    const pal = t.data[0..256];
    if (t.bits == 0) {
        for (row) |*px| px.* = pal[(px.* >> 8) & 0xff];
        return;
    }
    const bpp: u5 = @intCast(@as(u32, 8) >> t.bits);
    const per_mask = (@as(u32, 1) << t.bits) - 1;
    const mask = (@as(u32, 1) << bpp) - 1;
    var x = row.len;
    while (x > 0) {
        x -= 1;
        const packed_px = row[x >> t.bits];
        const shift: u5 = @intCast(8 + (x & per_mask) * bpp);
        row[x] = pal[(packed_px >> shift) & mask];
    }
}

/// Decodes an image stream, the part of a VP8L stream after its header
/// and all of a lossless ALPH chunk's: a `width` by `height` image (at
/// most 2^14 on a side), handing each row to `sink`. `work` holds at least
/// `workLen(width, height, max_groups)` bytes. `alpha` says it is an ALPH
/// chunk's.
pub fn decode(
    br: *BitReader,
    width: u32,
    height: u32,
    max_groups: u32,
    alpha: bool,
    work: []u8,
    sink: Sink,
) Error!void {
    const l = Layout.init(width, height, max_groups).?;
    std.debug.assert(work.len >= l.total);
    const base = std.mem.alignForward(usize, @intFromPtr(work.ptr), 8) - @intFromPtr(work.ptr);
    const mem: []align(8) u8 = @alignCast(work[base..][0 .. l.total - 8]);
    const w: usize = width;
    var s: Stream = .{
        .br = br,
        .width = width,
        .height = height,
        .max_groups = l.groups,
        .ring = u32s(mem, l.ring, l.ring_pixels),
        .rows = u32s(mem, l.rows, 2 * w + 1),
        .pred = u32s(mem, l.pred, l.tiles),
        .color = u32s(mem, l.color, l.tiles),
        .palette = u32s(mem, l.palette, 256),
        .entropy = u32s(mem, l.entropy, l.tiles),
        .cache = u32s(mem, l.cache, 1 << max_cache_bits),
        .used = @as([*]u64, @ptrCast(@alignCast(mem[l.used..].ptr)))[0..1024],
        .rank = u32s(mem, l.rank, 1024),
        .groups = @as([*]Group, @ptrCast(@alignCast(mem[l.desc..].ptr)))[0 .. l.groups + 1],
        .tables = @as([*]u16, @ptrCast(@alignCast(mem[l.tables..].ptr)))[0 .. (l.groups + 1) * group_entries],
        .alpha = alpha,
        .sink = sink,
    };
    var cur_w = width;
    var seen: u4 = 0;
    while (br.read(1) == 1) {
        const kind: Kind = @enumFromInt(br.read(2));
        const bit = @as(u4, 1) << @intFromEnum(kind);
        if (seen & bit != 0) return error.BadLossless;
        seen |= bit;
        var t: Transform = .{ .kind = kind, .width = cur_w };
        switch (kind) {
            .predictor, .color => {
                t.bits = @intCast(br.read(3) + 2);
                const tw = divRoundUp(cur_w, t.bits);
                const th = divRoundUp(height, t.bits);
                const dst = (if (kind == .predictor) s.pred else s.color)[0 .. @as(usize, tw) * th];
                try s.image(false, dst, tw, th);
                t.data = dst;
            },
            .subtract_green => {},
            .color_index => {
                const size = br.read(8) + 1;
                try s.image(false, s.palette[0..size], size, 1);
                // Each entry is stored as its difference from the one
                // before, channel by channel.
                for (1..size) |i| s.palette[i] = add(s.palette[i], s.palette[i - 1]);
                @memset(s.palette[size..], 0);
                t.bits = if (size <= 2) 3 else if (size <= 4) 2 else if (size <= 16) 1 else 0;
                t.full = cur_w;
                cur_w = divRoundUp(cur_w, t.bits);
                t.width = cur_w;
                t.data = s.palette;
            },
        }
        s.transforms[s.n_transforms] = t;
        s.n_transforms += 1;
    }
    try s.image(true, s.ring, cur_w, height);
}

fn u32s(mem: []align(8) u8, at: usize, n: usize) []u32 {
    return @as([*]u32, @ptrCast(@alignCast(mem[at..].ptr)))[0..n];
}

test "prefix code tables" {
    var out: [1024]u16 = undefined;
    // Lengths 1, 2, 3, 3: codes 0, 10, 110, 111, read least significant
    // bit first.
    const b = try build(&out, &.{ 1, 2, 3, 3 });
    try testing.expectEqual(3, b.root);
    try testing.expectEqual(8, b.len);
    for (0..8) |i| {
        const want: u16 = if (i & 1 == 0) 0 else if (i & 2 == 0) 1 else if (i & 4 == 0) 2 else 3;
        try testing.expectEqual(want, out[i] & 0xfff);
    }
    try testing.expectError(error.BadPrefixCode, build(&out, &.{ 1, 1, 1 }));
    try testing.expectError(error.BadPrefixCode, build(&out, &.{ 1, 2 }));
    try testing.expectError(error.BadPrefixCode, build(&out, &.{ 0, 0 }));
    const one = try build(&out, &.{ 0, 5, 0 });
    try testing.expectEqual(0, one.root);
    try testing.expectEqual(1, out[0] & 0xfff);
}
