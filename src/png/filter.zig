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
    const n = @min(bpp, cur.len);
    for (cur[0..n], prev[0..n]) |*x, b| x.* +%= b >> 1;
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) {
        const sum = @as(u16, cur[i - bpp]) + prev[i];
        cur[i] +%= @intCast(sum >> 1);
    }
}

fn paeth(comptime bpp: usize, cur: []u8, prev: []const u8) void {
    const n = @min(bpp, cur.len);
    // With no pixel to the left, a and c are 0 and the predictor is b.
    for (cur[0..n], prev[0..n]) |*x, b| x.* +%= b;
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) cur[i] +%= predict(cur[i - bpp], prev[i], prev[i - bpp]);
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
