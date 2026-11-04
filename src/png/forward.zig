//! PNG's row filters in the encoding direction (PNG specification, section
//! 9, filter method 0), and the choice of filter for a row.
//!
//! Filtering a row reads only the unfiltered row and the one above it, so
//! every output byte is independent of the others: the filters run 32
//! bytes at a time, the pixel to the left (`a`) and above-left (`c`) loaded
//! `bpp` bytes back. The first `bpp` bytes, which have no pixel to their
//! left, run scalar.
//!
//! `choose` is the minimum sum of absolute differences heuristic the
//! specification suggests (section 12.7): filter the row every way, read
//! each filtered byte as signed, and keep the filter whose magnitudes sum
//! least.

const std = @import("std");
const testing = std.testing;

pub const Filter = enum(u8) { none = 0, sub = 1, up = 2, average = 3, paeth = 4 };

const lanes = 32;
const V = @Vector(lanes, u8);
const W = @Vector(lanes, i16);

/// Filters `cur` into `out` with filter `f`, given `prev`, the unfiltered
/// row above (zeros for the first row). `bpp` is the bytes in a whole
/// pixel, at least 1. Returns the sum of the filtered bytes' magnitudes
/// when `score` is set, and 0 otherwise.
pub fn apply(f: Filter, out: []u8, cur: []const u8, prev: []const u8, bpp: usize, comptime score: bool) u64 {
    std.debug.assert(out.len == cur.len);
    std.debug.assert(prev.len >= cur.len);
    std.debug.assert(bpp >= 1);
    std.debug.assert(bpp <= 8);
    return switch (f) {
        .none => {
            @memcpy(out, cur);
            return if (score) magnitude(cur) else 0;
        },
        inline else => |k| run(k, out, cur, prev, bpp, score),
    };
}

/// The sum of `bytes`' magnitudes as signed bytes.
fn magnitude(bytes: []const u8) u64 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + lanes <= bytes.len) : (i += lanes) {
        const v: V = bytes[i..][0..lanes].*;
        sum += reduceAbs(v);
    }
    while (i < bytes.len) : (i += 1) sum += @min(bytes[i], 0 -% bytes[i]);
    return sum;
}

inline fn reduceAbs(v: V) u64 {
    const zero: V = @splat(0);
    const m: @Vector(lanes, u16) = @min(v, zero -% v);
    return @reduce(.Add, m);
}

fn run(comptime f: Filter, out: []u8, cur: []const u8, prev: []const u8, bpp: usize, comptime score: bool) u64 {
    var sum: u64 = 0;
    const head = @min(bpp, cur.len);
    // The first pixel: a and c are zero.
    for (0..head) |i| {
        const x = cur[i];
        const b = prev[i];
        const o = x -% switch (f) {
            .sub => 0,
            .up => b,
            .average => b >> 1,
            .paeth => b, // Paeth of (0, b, 0) is b.
            .none => unreachable,
        };
        out[i] = o;
        if (score) sum += @min(o, 0 -% o);
    }
    var i: usize = head;
    while (i + lanes <= cur.len) : (i += lanes) {
        const x: V = cur[i..][0..lanes].*;
        const o: V = switch (f) {
            .sub => x -% @as(V, cur[i - bpp ..][0..lanes].*),
            .up => x -% @as(V, prev[i..][0..lanes].*),
            .average => blk: {
                const a: V = cur[i - bpp ..][0..lanes].*;
                const b: V = prev[i..][0..lanes].*;
                // (a + b) >> 1 without overflow.
                const avg = (a >> @splat(1)) +% (b >> @splat(1)) +% (a & b & @as(V, @splat(1)));
                break :blk x -% avg;
            },
            .paeth => x -% paethV(cur[i - bpp ..][0..lanes].*, prev[i..][0..lanes].*, prev[i - bpp ..][0..lanes].*),
            .none => unreachable,
        };
        out[i..][0..lanes].* = o;
        if (score) sum += reduceAbs(o);
    }
    while (i < cur.len) : (i += 1) {
        const x = cur[i];
        const a = cur[i - bpp];
        const b = prev[i];
        const c = prev[i - bpp];
        const o = x -% switch (f) {
            .sub => a,
            .up => b,
            .average => @as(u8, @intCast((@as(u16, a) + b) >> 1)),
            .paeth => paeth(a, b, c),
            .none => unreachable,
        };
        out[i] = o;
        if (score) sum += @min(o, 0 -% o);
    }
    return sum;
}

/// The Paeth predictor of section 9.4: whichever of a, b, and c is nearest
/// a + b - c, preferring a, then b.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

inline fn paethV(a8: V, b8: V, c8: V) V {
    const a: W = a8;
    const b: W = b8;
    const c: W = c8;
    const pa = @abs(b - c);
    const pb = @abs(a - c);
    const pc = @abs(b - c + a - c);
    const use_a = (pa <= pb) & (pa <= pc);
    const use_b = pb <= pc;
    return @select(u8, use_a, a8, @select(u8, use_b, b8, c8));
}

/// Picks the filter for a row by the minimum sum of magnitudes, writing
/// each candidate into its row of `outs`. Returns the filter, whose
/// filtered bytes are `outs[@backingInt(filter)]`.
pub fn choose(outs: *const [5][]u8, cur: []const u8, prev: []const u8, bpp: usize) Filter {
    var best: Filter = .none;
    var best_sum: u64 = std.math.maxInt(u64);
    inline for (comptime std.enums.values(Filter)) |f| {
        const sum = apply(f, outs[@backingInt(f)], cur, prev, bpp, true);
        if (sum < best_sum) {
            best = f;
            best_sum = sum;
        }
    }
    return best;
}

const unfilter = @import("filter.zig").unfilter;

test "each filter inverts the decoder's" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var cur: [200]u8 = undefined;
    var prev: [200]u8 = undefined;
    var out: [200]u8 = undefined;
    var back: [200]u8 = undefined;
    for (0..200) |round| {
        const bpp: usize = switch (round % 6) {
            0 => 1,
            1 => 2,
            2 => 3,
            3 => 4,
            4 => 6,
            else => 8,
        };
        const len = bpp * (1 + random.uintLessThan(usize, 200 / bpp));
        // Small ranges now and then, so that Paeth's ties come up.
        const mask: u8 = if (round % 3 == 0) 3 else 0xff;
        for (cur[0..len], prev[0..len]) |*x, *y| {
            x.* = random.int(u8) & mask;
            y.* = random.int(u8) & mask;
        }
        for (std.enums.values(Filter)) |f| {
            const sum = apply(f, out[0..len], cur[0..len], prev[0..len], bpp, true);
            var want: u64 = 0;
            for (out[0..len]) |o| want += @abs(@as(i8, @bitCast(o)));
            try testing.expectEqual(want, sum);
            try unfilter(@backingInt(f), back[0..len], out[0..len], prev[0..len], bpp);
            try testing.expectEqualSlices(u8, cur[0..len], back[0..len]);
        }
    }
}

test "choose keeps the smallest sum" {
    // A horizontal ramp: Sub leaves its step, and only Paeth, which ties
    // with it, does as well.
    var cur: [64]u8 = undefined;
    for (&cur, 0..) |*x, i| x.* = @intCast(i * 3);
    const prev: [64]u8 = @splat(0);
    var bufs: [5][64]u8 = undefined;
    const outs: [5][]u8 = .{ &bufs[0], &bufs[1], &bufs[2], &bufs[3], &bufs[4] };
    try testing.expectEqual(Filter.sub, choose(&outs, &cur, &prev, 1));
    // A row equal to the one above: Up leaves zeros.
    var row: [64]u8 = undefined;
    for (&row, 0..) |*x, i| x.* = @truncate(i * 37 + 11);
    try testing.expectEqual(Filter.up, choose(&outs, &row, &row, 4));
}
