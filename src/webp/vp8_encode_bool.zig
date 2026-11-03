//! The boolean entropy encoder of RFC 6386 section 7.3, the coding of
//! coefficient tokens (section 13), and what the encoder estimates from
//! them: each token's cost under a set of probabilities, and the counts
//! the probabilities are chosen from.
//!
//! `Writer` streams: a carry can only reach the last byte that is not
//! 0xff and the 0xff bytes after it, so those are held back until the
//! next byte that is not 0xff settles them. It counts the bytes it codes
//! even once its output is full, so that the encoder can code a partition
//! into spare memory and still learn its length when it does not fit.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const tables = @import("vp8_encode_tables.zig");
const bands = tables.bands;

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

/// How often each token was coded, by block type, band, context, whether
/// it followed a zero (and so had no end-of-block test), and its class:
/// 0 to 4 its magnitude, 5 to 10 DCT_CAT1 to DCT_CAT6, 11 the end of
/// block. `nodeCounts` turns them into the tree's counts.
pub const Hist = [4][8][3][2][12]u32;
const eob_class = 11;

/// Counts tokens by class instead of writing them: one count a token
/// rather than one for each tree node it passes.
pub const Tally = struct {
    counts: *[8][3][2][12]u32,

    inline fn token(e: Tally, band: u8, ctx: u2, after_zero: u1, class: u4) void {
        e.counts[band][ctx][after_zero][class] += 1;
    }
};

/// Each magnitude's token class, up to DCT_CAT5's last.
const class_of: [67]u4 = blk: {
    var t: [67]u4 = undefined;
    for (&t, 0..) |*c, a| {
        c.* = if (a <= 4) a else if (a <= 6) 5 else if (a <= 10) 6 else if (a <= 18) 7 else if (a <= 34) 8 else 9;
    }
    break :blk t;
};

/// One block's tokens, as `block` codes them, counted by class.
inline fn tallyBlock(e: Tally, ctx0: u2, first: u5, last: i32, levels: *const [16]i16) void {
    var n: u5 = first;
    var ctx = ctx0;
    var after_zero: u1 = 0;
    while (n <= last) : (n += 1) {
        const a: u32 = @abs(levels[n]);
        e.token(bands[n], ctx, after_zero, if (a < 67) class_of[a] else 10);
        after_zero = @intFromBool(a == 0);
        ctx = @intCast(@min(a, 2));
    }
    if (n < 16) e.token(bands[n], ctx, 0, eob_class);
}

/// The tree's counts (`Counts`) from token counts.
pub fn nodeCounts(h: *const Hist, out: *Counts) void {
    for (h, out) |*ht, *ot| for (ht, ot) |*hb, *ob| for (hb, ob) |*hc, *k| {
        k.* = std.mem.zeroes([11][2]u32);
        for (hc, 0..) |*row, after_zero| for (row, 0..) |n, class| {
            if (n == 0) continue;
            if (after_zero == 0) k[0][@intFromBool(class != eob_class)] += n;
            if (class == eob_class) continue;
            k[1][@intFromBool(class != 0)] += n;
            if (class == 0) continue;
            k[2][@intFromBool(class != 1)] += n;
            if (class == 1) continue;
            k[3][@intFromBool(class >= 5)] += n;
            if (class <= 4) {
                k[4][@intFromBool(class != 2)] += n;
                if (class != 2) k[5][@intFromBool(class == 4)] += n;
                continue;
            }
            k[6][@intFromBool(class >= 7)] += n;
            if (class <= 6) {
                k[7][@intFromBool(class == 6)] += n;
                continue;
            }
            const cat = class - 7;
            k[8][cat >> 1] += n;
            k[9 + (cat >> 1)][cat & 1] += n;
        };
    };
}

/// The tokens of one block (section 13): `levels` in coding order,
/// positions `first` to `last` (none when `last < first`), the first
/// coded in context `ctx0`.
pub inline fn block(e: anytype, ctx0: u2, first: u5, last: i32, levels: *const [16]i16) void {
    if (@TypeOf(e) == Tally) return tallyBlock(e, ctx0, first, last, levels);
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

    /// A token's cost is its class's path through the tree, which the
    /// probabilities set, plus its bits at fixed probabilities (a
    /// category's extra bits and the sign), which they do not: the paths
    /// are added up for each context, and the rest is a constant.
    pub fn init(c: *Costs, probs: *const Probs) void {
        for (0..4) |t| for (0..8) |b| for (0..3) |x| {
            const p = &probs[t][b][x];
            c.eob[t][b][x] = @intCast(tables.cost(p[0], 0));
            const more: u16 = @intCast(tables.cost(p[0], 1));
            var paths: @Vector(11, u16) = undefined;
            inline for (0..11) |k| {
                var sum: u32 = 0;
                const s: Sum(false) = .{ .sum = &sum, .p = p };
                if (k == 0) {
                    s.node(0, 0, 1, 0);
                } else {
                    s.node(0, 0, 1, 1);
                    magnitude(s, 0, 0, class_start[k]);
                }
                paths[k] = @intCast(sum);
            }
            const az = @shuffle(u16, paths, undefined, class_mask) + fixed_cost;
            c.after_zero[t][b][x] = az;
            c.lead[t][b][x] = az + @as(@Vector(68, u16), @splat(more));
        };
    }

    /// The first magnitude of each token class up to DCT_CAT6.
    const class_start = [11]u8{ 0, 1, 2, 3, 4, 5, 7, 11, 19, 35, 67 };

    /// Each magnitude's token class, as a shuffle mask.
    const class_mask: @Vector(68, i32) = blk: {
        var m: [68]i32 = undefined;
        for (&m, 0..) |*k, v| {
            k.* = 0;
            for (class_start, 0..) |s, i| if (v >= s) {
                k.* = i;
            };
        }
        break :blk m;
    };

    /// Each magnitude's bits at fixed probabilities, DCT_CAT6's extra
    /// bits left to `tables.cat6_cost`.
    const fixed_cost: @Vector(68, u16) = blk: {
        @setEvalBranchQuota(100_000);
        var t: [68]u16 = undefined;
        t[0] = 0;
        for (1..68) |v| {
            var sum: u32 = 256;
            const s: Sum(true) = .{ .sum = &sum, .p = undefined };
            magnitude(s, 0, 0, v);
            if (v == 67) sum -= tables.cat6_cost[0];
            t[v] = sum;
        }
        break :blk t;
    };

    /// Adds up the costs of the booleans at the tree's nodes, or of
    /// those at fixed probabilities.
    fn Sum(comptime fixed_only: bool) type {
        return struct {
            const Self = @This();
            sum: *u32,
            p: *const [11]u8,
            inline fn node(s: Self, _: u8, _: u2, i: u4, bit: u1) void {
                if (!fixed_only) s.sum.* += tables.cost(s.p[i], bit);
            }
            inline fn fixed(s: Self, p: u8, bit: u1) void {
                if (fixed_only) s.sum.* += tables.cost(p, bit);
            }
        };
    }

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

test "the writer's bytes decode, and it counts them when they do not fit" {
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
        var short_buf: [100]u8 = undefined;
        var short: Io.Writer = .fixed(short_buf[0 .. round % short_buf.len]);
        var c: Writer = .{ .out = &short };
        for (bits[0..n], probs[0..n]) |b, p| {
            w.put(p, b);
            c.put(p, b);
        }
        try w.finish();
        try testing.expectEqual(w.written, fw.end);
        if (c.finish()) {
            try testing.expectEqualSlices(u8, fw.buffered(), short.buffered());
        } else |_| try testing.expect(fw.end > short.buffer.len);
        try testing.expectEqual(w.written, c.written);
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

test "token counts give the tree's counts" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    // Every node a token passes, counted by walking the tree.
    const Nodes = struct {
        const Self = @This();
        counts: *[8][3][11][2]u32,
        fn node(s: Self, band: u8, ctx: u2, i: u4, bit: u1) void {
            s.counts[band][ctx][i][bit] += 1;
        }
        fn fixed(_: Self, _: u8, _: u1) void {}
    };
    var want = std.mem.zeroes(Counts);
    var hist = std.mem.zeroes(Hist);
    for (0..2000) |_| {
        const t = r.uintLessThan(usize, 4);
        const first: u5 = r.uintLessThan(u5, 2);
        const ctx0: u2 = @intCast(r.uintLessThan(u8, 3));
        var levels: [16]i16 = @splat(0);
        // Mostly small magnitudes and zeros, some of every category.
        for (levels[first..]) |*v| {
            const mag: i16 = switch (r.uintLessThan(u8, 10)) {
                0...3 => 0,
                4, 5 => 1,
                6 => r.intRangeAtMost(i16, 2, 10),
                7 => r.intRangeAtMost(i16, 11, 66),
                8 => r.intRangeAtMost(i16, 67, tables.max_level),
                else => r.intRangeAtMost(i16, 2, 4),
            };
            v.* = if (r.boolean()) mag else -mag;
        }
        var last: i32 = @as(i32, first) - 1;
        if (r.uintLessThan(u8, 8) != 0) {
            last = r.intRangeAtMost(i32, first, 15);
            if (levels[@intCast(last)] == 0) levels[@intCast(last)] = 3;
        }
        block(Nodes{ .counts = &want[t] }, ctx0, first, last, &levels);
        block(Tally{ .counts = &hist[t] }, ctx0, first, last, &levels);
    }
    var got: Counts = undefined;
    nodeCounts(&hist, &got);
    try testing.expectEqualDeep(want, got);
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
