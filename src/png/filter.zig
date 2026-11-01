//! Reversing PNG's row filters (PNG specification, section 9, filter method
//! 0), in place: `cur` holds a row's filtered bytes and becomes its
//! unfiltered bytes, given `prev`, the unfiltered row before it (zeros for
//! a pass's first row).

const std = @import("std");
const testing = std.testing;

pub const Error = error{BadFilter};

/// Unfilters `cur` with filter type `filter`. `bpp` is the bytes in a whole
/// pixel, at least 1 (section 9.2's "a" is that many bytes back), and
/// `cur` holds whole pixels. `prev` is at least as long as `cur`.
pub fn unfilter(filter: u8, cur: []u8, prev: []const u8, bpp: usize) Error!void {
    std.debug.assert(prev.len >= cur.len);
    switch (filter) {
        0 => {},
        1 => switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| sub(n, cur),
            else => unreachable,
        },
        2 => up(cur, prev),
        3 => switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| average(n, cur, prev),
            else => unreachable,
        },
        4 => switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| paeth(n, cur, prev),
            else => unreachable,
        },
        else => return error.BadFilter,
    }
}

fn sub(comptime bpp: usize, cur: []u8) void {
    if (bpp >= 2) return pixels(bpp, .sub, cur, cur);
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) cur[i] +%= cur[i - bpp];
}

fn up(cur: []u8, prev: []const u8) void {
    const V = @Vector(32, u8);
    var i: usize = 0;
    while (i + 32 <= cur.len) : (i += 32) {
        const a: V = cur[i..][0..32].*;
        const b: V = prev[i..][0..32].*;
        cur[i..][0..32].* = a +% b;
    }
    while (i < cur.len) : (i += 1) cur[i] +%= prev[i];
}

fn average(comptime bpp: usize, cur: []u8, prev: []const u8) void {
    if (bpp >= 3) return pixels(bpp, .average, cur, prev);
    const n = @min(bpp, cur.len);
    for (cur[0..n], prev[0..n]) |*x, b| x.* +%= b >> 1;
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) {
        const sum = @as(u16, cur[i - bpp]) + prev[i];
        cur[i] +%= @intCast(sum >> 1);
    }
}

fn paeth(comptime bpp: usize, cur: []u8, prev: []const u8) void {
    if (bpp >= 2) return pixels(bpp, .paeth, cur, prev);
    const n = @min(bpp, cur.len);
    // With no pixel to the left, a and c are 0 and the predictor is b.
    for (cur[0..n], prev[0..n]) |*x, b| x.* +%= b;
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) cur[i] +%= predict(cur[i - bpp], prev[i], prev[i - bpp]);
}

/// Sub, Average, and Paeth a whole pixel at a time: each byte of a pixel
/// depends only on the same byte of the pixel to its left, so a pixel's
/// bytes are lanes of a vector, the pixel to the left stays in a register,
/// and the predictors run without branches. Paeth picks lanes with
/// `@select`, which is section 9.4's predictor with its ties broken the
/// same way. Measured faster than the byte loops for 2-byte pixels and up
/// (Average from 3), and no faster for 1-byte pixels (docs/slop/png.md).
fn pixels(comptime bpp: usize, comptime kind: enum { sub, average, paeth }, cur: []u8, prev: []const u8) void {
    // The lanes are the pixel's bytes, padded to a power of two; a pixel
    // moves between memory and the vector as an integer of its own width.
    const lanes = comptime std.math.ceilPowerOfTwoAssert(usize, bpp);
    const Int = @Int(.unsigned, bpp * 8);
    const Wide = @Int(.unsigned, lanes * 8);
    const V = @Vector(lanes, i16);
    const B = @Vector(lanes, u8);
    std.debug.assert(cur.len % bpp == 0);
    var a: V = @splat(0);
    var c: V = @splat(0);
    var i: usize = 0;
    while (i < cur.len) : (i += bpp) {
        const x: B = @bitCast(@as(Wide, std.mem.readInt(Int, cur[i..][0..bpp], .little)));
        const above: Wide = if (kind == .sub) 0 else std.mem.readInt(Int, prev[i..][0..bpp], .little);
        const b: V = @as(B, @bitCast(above));
        const p: V = switch (kind) {
            .sub => a,
            .average => (a + b) >> @splat(1),
            .paeth => blk: {
                const pa = @abs(b - c);
                const pb = @abs(a - c);
                const pc = @abs(a + b - c - c);
                const use_a = (pa <= pb) & (pa <= pc);
                break :blk @select(i16, use_a, a, @select(i16, pb <= pc, b, c));
            },
        };
        const out = x +% @as(B, @truncate(@as(@Vector(lanes, u16), @bitCast(p))));
        std.mem.writeInt(Int, cur[i..][0..bpp], @truncate(@as(Wide, @bitCast(out))), .little);
        a = out;
        if (kind == .paeth) c = b;
    }
}

/// Section 9.4's Paeth predictor.
pub inline fn predict(a: u8, b: u8, c: u8) u8 {
    const ia: i16 = a;
    const ib: i16 = b;
    const ic: i16 = c;
    const pa = @abs(ib - ic);
    const pb = @abs(ia - ic);
    const pc = @abs(ia + ib - 2 * ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Section 9's definitions, byte by byte, as the reference for the tests.
fn reference(filter: u8, cur: []u8, prev: []const u8, bpp: usize) void {
    for (cur, 0..) |*x, i| {
        const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
        const b = prev[i];
        const c: u8 = if (i >= bpp) prev[i - bpp] else 0;
        x.* +%= switch (filter) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            4 => predict(a, b, c),
            else => unreachable,
        };
    }
}

test "unfilter matches the definitions" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var prev: [200]u8 = undefined;
    var row: [200]u8 = undefined;
    var want: [200]u8 = undefined;
    for (0..2000) |i| {
        const bpp = ([_]usize{ 1, 2, 3, 4, 6, 8 })[i % 6];
        // Rows are whole pixels.
        const len = random.uintAtMost(usize, row.len / bpp) * bpp;
        // Bytes near the ends of the range catch overflow in the predictors.
        for (prev[0..len], row[0..len]) |*p, *r| {
            p.* = if (random.boolean()) random.int(u8) else 255 - random.uintLessThan(u8, 3);
            r.* = random.int(u8);
        }
        const filter: u8 = @intCast(i / 6 % 5);
        @memcpy(want[0..len], row[0..len]);
        reference(filter, want[0..len], &prev, bpp);
        try unfilter(filter, row[0..len], &prev, bpp);
        try testing.expectEqualSlices(u8, want[0..len], row[0..len]);
    }
    try testing.expectError(error.BadFilter, unfilter(5, &row, &prev, 1));
}
