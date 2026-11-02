//! The boolean entropy encoder of RFC 6386 section 7.3, the coding of
//! coefficient tokens (section 13), and what the encoder estimates from
//! them: each token's cost under a set of probabilities, and the counts
//! the probabilities are chosen from.
//!
//! A partition is coded twice: once by `Counter`, which only follows the
//! coder's range, since how many bytes a partition takes depends on how
//! many times the range renormalizes and on nothing else; then by `Writer`
//! into the caller's writer, once the sizes in the headers before it are
//! known. `Writer` streams: a carry can only reach the last byte that is
//! not 0xff and the 0xff bytes after it, so those are held back until the
//! next byte that is not 0xff settles them.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const tables = @import("vp8_encode_tables.zig");
const bands = tables.bands;

/// Follows a partition's range to count its bytes, without writing them.
pub const Counter = struct {
    range: u32 = 255,
    shifts: u64 = 0,

    pub inline fn put(c: *Counter, p: u8, bit: u1) void {
        const split = 1 + (((c.range - 1) * p) >> 8);
        c.range = if (bit == 1) c.range - split else split;
        const n: u5 = @clz(@as(u8, @intCast(c.range)));
        c.range <<= n;
        c.shifts += n;
    }

    /// The bytes `Writer` writes for the same booleans: one each time 8
    /// more bits are shifted out after the first 24, and 4 to finish.
    pub fn bytes(c: *const Counter) u64 {
        return 4 + if (c.shifts >= 24) (c.shifts - 24) / 8 + 1 else 0;
    }
};

/// Codes booleans into `out` (section 7.3's encoder).
pub const Writer = struct {
    range: u32 = 255,
    /// The low end of the interval; bit 32 is a carry into the bytes
    /// already formed.
    bottom: u64 = 0,
    /// Shifts until the next byte is formed.
    bit_count: u32 = 24,
    out: *Io.Writer,
    /// The last byte formed that is not 0xff, held for a carry, and the
    /// 0xff bytes after it.
    cache: u8 = 0,
    has_cache: bool = false,
    run: u64 = 0,
    written: u64 = 0,
    failed: bool = false,

    pub inline fn put(w: *Writer, p: u8, bit: u1) void {
        const split = 1 + (((w.range - 1) * p) >> 8);
        if (bit == 1) {
            w.bottom += split;
            w.range -= split;
        } else {
            w.range = split;
        }
        var n: u32 = @clz(@as(u8, @intCast(w.range)));
        w.range <<= @intCast(n);
        if (n < w.bit_count) {
            w.bottom <<= @intCast(n);
            w.bit_count -= n;
            return;
        }
        w.bottom <<= @intCast(w.bit_count);
        n -= w.bit_count;
        w.form(@truncate(w.bottom >> 32), @truncate(w.bottom >> 24));
        w.bottom = (w.bottom & 0xff_ffff) << @intCast(n);
        w.bit_count = 8 - n;
    }

    /// A byte formed, with the carry out of it into the bytes before.
    fn form(w: *Writer, carry: u1, byte: u8) void {
        if (carry == 1) {
            // The interval never passes 1, so a carry has a byte that is
            // not 0xff to stop at, and each byte takes at most one.
            std.debug.assert(w.has_cache);
            std.debug.assert(w.cache < 0xff);
            w.cache += 1;
            if (w.run > 0) {
                w.emit(w.cache);
                w.emitRun(0x00, w.run - 1);
                w.cache = 0;
                w.run = 0;
            }
        }
        if (byte == 0xff) {
            w.run += 1;
            return;
        }
        if (w.has_cache) w.emit(w.cache);
        w.emitRun(0xff, w.run);
        w.run = 0;
        w.cache = byte;
        w.has_cache = true;
    }

    fn emit(w: *Writer, b: u8) void {
        w.written += 1;
        if (w.failed) return;
        w.out.writeByte(b) catch {
            w.failed = true;
        };
    }

    fn emitRun(w: *Writer, b: u8, n: u64) void {
        w.written += n;
        if (w.failed) return;
        w.out.splatByteAll(b, @intCast(n)) catch {
            w.failed = true;
        };
    }

    /// Writes what is left: the bits of the interval's low end (section
    /// 7.3's `flush_bool_encoder`), and the bytes held for a carry.
    pub fn finish(w: *Writer) error{WriteFailed}!void {
        const v = w.bottom << @intCast(w.bit_count);
        w.form(@truncate(v >> 32), @truncate(v >> 24));
        w.form(0, @truncate(v >> 16));
        w.form(0, @truncate(v >> 8));
        w.form(0, @truncate(v));
        if (w.has_cache) w.emit(w.cache);
        w.emitRun(0xff, w.run);
        if (w.failed) return error.WriteFailed;
    }
};

/// `n` bits of `v`, most significant first, at even odds (L(n)).
pub inline fn literal(bw: anytype, n: u5, v: u32) void {
    var i = n;
    while (i > 0) {
        i -= 1;
        bw.put(128, @truncate(v >> i));
    }
}

/// An optional signed value: a flag, then the magnitude and sign.
pub fn maybeSigned(bw: anytype, n: u5, v: i32) void {
    bw.put(128, @intFromBool(v != 0));
    if (v == 0) return;
    literal(bw, n, @abs(v));
    bw.put(128, @intFromBool(v < 0));
}

/// Token probabilities: block type, band, context, tree node.
pub const Probs = [4][8][3][11]u8;
/// How often each node of each token tree was coded as 0 and as 1.
pub const Counts = [4][8][3][11][2]u32;

/// Writes the booleans of tokens with the probabilities `probs`.
pub fn Emit(comptime W: type) type {
    return struct {
        const Self = @This();
        w: *W,
        probs: *const [8][3][11]u8,

        inline fn node(e: Self, band: u8, ctx: u2, i: u4, bit: u1) void {
            e.w.put(e.probs[band][ctx][i], bit);
        }
        inline fn fixed(e: Self, p: u8, bit: u1) void {
            e.w.put(p, bit);
        }
    };
}

/// Counts the tree nodes of tokens instead of writing them.
pub const Tally = struct {
    counts: *[8][3][11][2]u32,

    inline fn node(e: Tally, band: u8, ctx: u2, i: u4, bit: u1) void {
        e.counts[band][ctx][i][bit] += 1;
    }
    inline fn fixed(_: Tally, _: u8, _: u1) void {}
};

/// The tokens of one block (section 13): `levels` in coding order,
/// positions `first` to `last` (none when `last < first`), the first
/// coded in context `ctx0`.
pub inline fn block(e: anytype, ctx0: u2, first: u5, last: i32, levels: *const [16]i16) void {
    var n: u5 = first;
    var ctx = ctx0;
    if (last < first) {
        e.node(bands[n], ctx, 0, 0);
        return;
    }
    var after_zero = false;
    while (n <= last) : (n += 1) {
        const band = bands[n];
        const v = levels[n];
        if (!after_zero) e.node(band, ctx, 0, 1);
        if (v == 0) {
            e.node(band, ctx, 1, 0);
            after_zero = true;
            ctx = 0;
            continue;
        }
        e.node(band, ctx, 1, 1);
        const a: u32 = @abs(v);
        magnitude(e, band, ctx, a);
        e.fixed(128, @intFromBool(v < 0));
        after_zero = false;
        ctx = if (a == 1) 1 else 2;
    }
    if (n < 16) e.node(bands[n], ctx, 0, 0);
}

/// A nonzero magnitude's tree path past the zero test, and its extra bits.
inline fn magnitude(e: anytype, band: u8, ctx: u2, a: u32) void {
    if (a == 1) return e.node(band, ctx, 2, 0);
    e.node(band, ctx, 2, 1);
    if (a <= 4) {
        e.node(band, ctx, 3, 0);
        if (a == 2) return e.node(band, ctx, 4, 0);
        e.node(band, ctx, 4, 1);
        return e.node(band, ctx, 5, @intFromBool(a == 4));
    }
    e.node(band, ctx, 3, 1);
    if (a <= 10) {
        e.node(band, ctx, 6, 0);
        if (a <= 6) {
            e.node(band, ctx, 7, 0);
            return e.fixed(tables.cat1[0], @intCast(a - 5));
        }
        e.node(band, ctx, 7, 1);
        e.fixed(tables.cat2[0], @intCast((a - 7) >> 1));
        return e.fixed(tables.cat2[1], @intCast((a - 7) & 1));
    }
    e.node(band, ctx, 6, 1);
    const cat: u2 = if (a < 19) 0 else if (a < 35) 1 else if (a < 67) 2 else 3;
    e.node(band, ctx, 8, @intCast(cat >> 1));
    e.node(band, ctx, @as(u4, 9) + (cat >> 1), @intCast(cat & 1));
    const extra = a - (3 + (@as(u32, 8) << cat));
    const ps = tables.cat3456[cat];
    for (ps, 0..) |p, i| e.fixed(p, @intCast((extra >> @intCast(ps.len - 1 - i)) & 1));
}

/// Token costs under one set of probabilities, in 1/256 bits, for the
/// encoder's rate estimates.
pub const Costs = struct {
    /// A token of magnitude 0 to 66, or DCT_CAT6's path for 67 and up
    /// (its extra bits are `tables.cat6_cost`), with its sign, after a
    /// zero: no end-of-block test before it.
    after_zero: [4][8][3][68]u16,
    /// The same, after a nonzero token or first in a block: with the
    /// end-of-block test coded as "more".
    lead: [4][8][3][68]u16,
    /// The end-of-block token.
    eob: [4][8][3]u16,

    pub fn init(c: *Costs, probs: *const Probs) void {
        for (0..4) |t| for (0..8) |b| for (0..3) |x| {
            const p = &probs[t][b][x];
            c.eob[t][b][x] = @intCast(tables.cost(p[0], 0));
            const more = tables.cost(p[0], 1);
            for (0..68) |v| {
                var sum: u32 = 0;
                const s: Sum = .{ .sum = &sum, .p = p };
                if (v == 0) {
                    s.node(0, 0, 1, 0);
                } else {
                    s.node(0, 0, 1, 1);
                    magnitude(s, 0, 0, @intCast(v));
                    sum += 256;
                }
                if (v == 67) sum -= tables.cat6_cost[0];
                c.after_zero[t][b][x][v] = @intCast(sum);
                c.lead[t][b][x][v] = @intCast(sum + more);
            }
        };
    }

    /// Adds up the costs of booleans one node set at a time.
    const Sum = struct {
        sum: *u32,
        p: *const [11]u8,
        inline fn node(s: Sum, _: u8, _: u2, i: u4, bit: u1) void {
            s.sum.* += tables.cost(s.p[i], bit);
        }
        inline fn fixed(s: Sum, p: u8, bit: u1) void {
            s.sum.* += tables.cost(p, bit);
        }
    };

    /// The cost of one block's tokens, as `block` codes them.
    pub fn blockCost(c: *const Costs, t: usize, ctx0: u2, first: u5, last: i32, levels: *const [16]i16) u32 {
        var ctx: usize = ctx0;
        if (last < first) return c.eob[t][bands[first]][ctx];
        var sum: u32 = 0;
        var n: usize = first;
        var after_zero = false;
        const end: usize = @intCast(last);
        while (n <= end) : (n += 1) {
            const a: u32 = @abs(levels[n]);
            const tab = if (after_zero) &c.after_zero[t][bands[n]][ctx] else &c.lead[t][bands[n]][ctx];
            if (a < 67) {
                sum += tab[a];
            } else {
                sum += tab[67] + tables.cat6_cost[@min(a, tables.max_level) - 67];
            }
            after_zero = a == 0;
            ctx = if (a == 0) 0 else if (a == 1) 1 else 2;
        }
        if (n < 16) sum += c.eob[t][bands[n]][ctx];
        return sum;
    }
};

test "the writer's bytes decode, and the counter counts them" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var bits: [5000]u1 = undefined;
    var probs: [5000]u8 = undefined;
    var out: [8000]u8 = undefined;
    for (0..50) |round| {
        const n = 1 + r.uintLessThan(usize, bits.len);
        for (bits[0..n], probs[0..n]) |*b, *p| {
            p.* = 1 + r.uintLessThan(u8, 255);
            // Mostly the likely value, sometimes not, sometimes at random.
            const likely: u1 = @intFromBool(p.* < 128);
            b.* = switch (r.uintLessThan(u8, 8)) {
                0 => r.int(u1),
                1 => ~likely,
                else => likely,
            };
            if (round % 5 == 0) p.* = if (round % 10 == 0) 255 else 1;
        }
        var fw: Io.Writer = .fixed(&out);
        var w: Writer = .{ .out = &fw };
        var c: Counter = .{};
        for (bits[0..n], probs[0..n]) |b, p| {
            w.put(p, b);
            c.put(p, b);
        }
        try w.finish();
        try testing.expectEqual(c.bytes(), fw.end);
        try testing.expectEqual(w.written, fw.end);
        // Section 7.3's decoder reads them back.
        const data = fw.buffered();
        var value: u32 = (@as(u32, data[0]) << 8) | data[1];
        var at: usize = 2;
        var range: u32 = 255;
        var bit_count: u32 = 0;
        for (bits[0..n], probs[0..n]) |b, p| {
            const split = 1 + (((range - 1) * p) >> 8);
            const big = split << 8;
            var got: u1 = 0;
            if (value >= big) {
                got = 1;
                range -= split;
                value -= big;
            } else {
                range = split;
            }
            while (range < 128) {
                value <<= 1;
                range <<= 1;
                bit_count += 1;
                if (bit_count == 8) {
                    bit_count = 0;
                    try testing.expect(at < data.len);
                    value |= data[at];
                    at += 1;
                }
            }
            try testing.expectEqual(b, got);
        }
    }
}

test "costs follow the tokens' booleans" {
    var c: Costs = undefined;
    const probs = tables.default_coeff_probs;
    c.init(&probs);
    var levels: [16]i16 = @splat(0);
    levels[0] = 3;
    levels[2] = -1;
    levels[3] = 90;
    const Sum = struct {
        const Self = @This();
        sum: u32 = 0,
        probs: *const [8][3][11]u8,
        fn node(s: *Self, band: u8, ctx: u2, i: u4, bit: u1) void {
            s.sum += tables.cost(s.probs[band][ctx][i], bit);
        }
        fn fixed(s: *Self, p: u8, bit: u1) void {
            s.sum += tables.cost(p, bit);
        }
    };
    var s: Sum = .{ .probs = &probs[3] };
    block(&s, 1, 0, 3, &levels);
    try testing.expectEqual(s.sum, c.blockCost(3, 1, 0, 3, &levels));
    var e: Sum = .{ .probs = &probs[0] };
    block(&e, 2, 1, 0, &levels);
    try testing.expectEqual(e.sum, c.blockCost(0, 2, 1, 0, &levels));
}
