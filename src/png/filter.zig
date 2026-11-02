//! Reversing PNG's row filters (PNG specification, section 9, filter method
//! 0): `src` holds a row's filtered bytes and `cur` receives its unfiltered
//! bytes, given `prev`, the unfiltered row before it (zeros for a pass's
//! first row). `src` may be `cur`.

const std = @import("std");
const testing = std.testing;

pub const Error = error{BadFilter};

/// Unfilters `src` into `cur` with filter type `filter`. `bpp` is the bytes
/// in a whole pixel, at least 1 (section 9.2's "a" is that many bytes
/// back), and `cur` holds whole pixels. `src` and `prev` are at least as
/// long as `cur`; `src` is `cur` or does not overlap it.
pub fn unfilter(filter: u8, cur: []u8, src: []const u8, prev: []const u8, bpp: usize) Error!void {
    std.debug.assert(prev.len >= cur.len);
    std.debug.assert(src.len >= cur.len);
    switch (filter) {
        0 => if (src.ptr != cur.ptr) @memcpy(cur, src[0..cur.len]),
        1 => switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| sub(n, cur, src),
            else => unreachable,
        },
        2 => up(cur, src, prev),
        3 => switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| average(n, cur, src, prev),
            else => unreachable,
        },
        4 => switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| paeth(n, cur, src, prev),
            else => unreachable,
        },
        else => return error.BadFilter,
    }
}

fn sub(comptime bpp: usize, cur: []u8, src: []const u8) void {
    if (bpp >= 2) return pixels(bpp, .sub, cur, src, src);
    const n = @min(bpp, cur.len);
    for (cur[0..n], src[0..n]) |*x, b| x.* = b;
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) cur[i] = src[i] +% cur[i - bpp];
}

fn up(cur: []u8, src: []const u8, prev: []const u8) void {
    const V = @Vector(32, u8);
    var i: usize = 0;
    while (i + 32 <= cur.len) : (i += 32) {
        const a: V = src[i..][0..32].*;
        const b: V = prev[i..][0..32].*;
        cur[i..][0..32].* = a +% b;
    }
    while (i < cur.len) : (i += 1) cur[i] = src[i] +% prev[i];
}

fn average(comptime bpp: usize, cur: []u8, src: []const u8, prev: []const u8) void {
    if (bpp >= 3) return pixels(bpp, .average, cur, src, prev);
    const n = @min(bpp, cur.len);
    for (cur[0..n], src[0..n], prev[0..n]) |*x, s, b| x.* = s +% (b >> 1);
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) {
        const sum = @as(u16, cur[i - bpp]) + prev[i];
        cur[i] = src[i] +% @as(u8, @intCast(sum >> 1));
    }
}

fn paeth(comptime bpp: usize, cur: []u8, src: []const u8, prev: []const u8) void {
    if (bpp >= 2) return pixels(bpp, .paeth, cur, src, prev);
    const n = @min(bpp, cur.len);
    // With no pixel to the left, a and c are 0 and the predictor is b.
    for (cur[0..n], src[0..n], prev[0..n]) |*x, s, b| x.* = s +% b;
    var i: usize = bpp;
    while (i < cur.len) : (i += 1) cur[i] = src[i] +% predict(cur[i - bpp], prev[i], prev[i - bpp]);
}

/// Sub, Average, and Paeth a whole pixel at a time: each byte of a pixel
/// depends only on the same byte of the pixel to its left, so a pixel's
/// bytes are lanes of a vector, the pixel to the left stays in a register,
/// and the predictors run without branches. Paeth picks lanes with
/// `@select`, which is section 9.4's predictor with its ties broken the
/// same way. Measured faster than the byte loops for 2-byte pixels and up
/// (Average from 3), and no faster for 1-byte pixels (docs/slop/png.md).
fn pixels(
    comptime bpp: usize,
    comptime kind: enum { sub, average, paeth },
    cur: []u8,
    src: []const u8,
    prev: []const u8,
) void {
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
        const x: B = @bitCast(@as(Wide, std.mem.readInt(Int, src[i..][0..bpp], .little)));
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
        // From another buffer, then in place.
        var out: [200]u8 = undefined;
        try unfilter(filter, out[0..len], row[0..len], &prev, bpp);
        try testing.expectEqualSlices(u8, want[0..len], out[0..len]);
        try unfilter(filter, row[0..len], row[0..len], &prev, bpp);
        try testing.expectEqualSlices(u8, want[0..len], row[0..len]);
    }
    try testing.expectError(error.BadFilter, unfilter(5, &row, &row, &prev, 1));
}

/// Unfilters two consecutive rows that both use filter type `filter`,
/// Average (3) or Paeth (4): `src0` into `cur0` given `prev`, and `src1`
/// into `cur1` given that first row. Each row's pixels depend on the pixel
/// to the left, and the two rows' chains run side by side, the second two
/// pixels behind, as the halves of one vector. `src0` may be `cur0`, and
/// `cur1` may be `prev`: the second row writes a pixel two after the first
/// row read it. Otherwise the buffers do not overlap.
pub fn unfilter2(
    filter: u8,
    bpp: usize,
    cur0: []u8,
    src0: []const u8,
    cur1: []u8,
    src1: []const u8,
    prev: []const u8,
) void {
    switch (filter) {
        inline 3, 4 => |f| switch (bpp) {
            inline 1, 2, 3, 4, 6, 8 => |n| rows2(f, n, cur0, src0, cur1, src1, prev),
            else => unreachable,
        },
        else => unreachable,
    }
}

fn rows2(
    comptime filter: u8,
    comptime bpp: usize,
    cur0: []u8,
    src0: []const u8,
    cur1: []u8,
    src1: []const u8,
    prev: []const u8,
) void {
    const lanes = comptime std.math.ceilPowerOfTwoAssert(usize, bpp);
    const Int = @Int(.unsigned, bpp * 8);
    const Half = @Int(.unsigned, lanes * 8);
    const Both = @Int(.unsigned, lanes * 16);
    const V = @Vector(2 * lanes, i16);
    const B = @Vector(2 * lanes, u8);
    const w = cur0.len / bpp;
    std.debug.assert(cur0.len % bpp == 0);
    std.debug.assert(cur1.len == cur0.len);
    std.debug.assert(src0.len >= cur0.len);
    std.debug.assert(src1.len >= cur0.len);
    std.debug.assert(prev.len >= cur0.len);
    const S = struct {
        const Self = @This();

        a: V = @splat(0),
        c: V = @splat(0),
        // The first row's last two pixels, the second row's next two
        // pixels above.
        held: Half = 0,
        pend: Half = 0,

        inline fn step(
            s: *Self,
            comptime first: bool,
            comptime second: bool,
            i: usize,
            c0: []u8,
            s0: []const u8,
            c1: []u8,
            s1: []const u8,
            p: []const u8,
        ) void {
            const x0: Half = if (first) std.mem.readInt(Int, s0[i * bpp ..][0..bpp], .little) else 0;
            const b0: Half = if (first) std.mem.readInt(Int, p[i * bpp ..][0..bpp], .little) else 0;
            const x1: Half = if (second) std.mem.readInt(Int, s1[(i - 2) * bpp ..][0..bpp], .little) else 0;
            const x: B = @bitCast(@as(Both, x0) | @as(Both, x1) << (lanes * 8));
            const b: V = @as(B, @bitCast(@as(Both, b0) | @as(Both, s.held) << (lanes * 8)));
            const a = s.a;
            const pred = switch (filter) {
                3 => (a + b) >> @splat(1),
                4 => blk: {
                    const c = s.c;
                    const pa = @abs(b - c);
                    const pb = @abs(a - c);
                    const pc = @abs(a + b - c - c);
                    const use_a = (pa <= pb) & (pa <= pc);
                    break :blk @select(i16, use_a, a, @select(i16, pb <= pc, b, c));
                },
                else => unreachable,
            };
            const out = x +% @as(B, @truncate(@as(@Vector(2 * lanes, u16), @bitCast(pred))));
            const bits: Both = @bitCast(out);
            const out0: Half = @truncate(bits);
            if (first) std.mem.writeInt(Int, c0[i * bpp ..][0..bpp], @truncate(out0), .little);
            if (second) std.mem.writeInt(Int, c1[(i - 2) * bpp ..][0..bpp], @truncate(bits >> (lanes * 8)), .little);
            s.a = @as(B, out);
            if (filter == 4) s.c = b;
            s.held = s.pend;
            s.pend = out0;
        }
    };
    var s: S = .{};
    var i: usize = 0;
    // Pixel i of the first row and i - 2 of the second.
    while (i < @min(2, w)) : (i += 1) s.step(true, false, i, cur0, src0, cur1, src1, prev);
    while (i < 2) : (i += 1) s.step(false, false, i, cur0, src0, cur1, src1, prev);
    while (i < w) : (i += 1) s.step(true, true, i, cur0, src0, cur1, src1, prev);
    while (i < w + 2) : (i += 1) s.step(false, true, i, cur0, src0, cur1, src1, prev);
}

test "unfilter2 unfilters two rows" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var prev: [200]u8 = undefined;
    var r0: [200]u8 = undefined;
    var r1: [200]u8 = undefined;
    var want0: [200]u8 = undefined;
    var want1: [200]u8 = undefined;
    for (0..6000) |i| {
        const bpp = ([_]usize{ 1, 2, 3, 4, 6, 8 })[i % 6];
        const filter: u8 = if (i / 6 % 2 == 0) 3 else 4;
        const len = random.uintAtMost(usize, r0.len / bpp) * bpp;
        for (prev[0..len], r0[0..len], r1[0..len]) |*p, *x, *y| {
            p.* = if (random.boolean()) random.int(u8) else 255 - random.uintLessThan(u8, 3);
            x.* = random.int(u8);
            y.* = random.int(u8);
        }
        @memcpy(want0[0..len], r0[0..len]);
        reference(filter, want0[0..len], &prev, bpp);
        @memcpy(want1[0..len], r1[0..len]);
        reference(filter, want1[0..len], &want0, bpp);
        var out0: [200]u8 = undefined;
        var out1: [200]u8 = undefined;
        unfilter2(filter, bpp, out0[0..len], r0[0..len], out1[0..len], r1[0..len], prev[0..len]);
        try testing.expectEqualSlices(u8, want0[0..len], out0[0..len]);
        try testing.expectEqualSlices(u8, want1[0..len], out1[0..len]);
        // The first row in place, the second over the row above it.
        @memcpy(out0[0..len], r0[0..len]);
        unfilter2(filter, bpp, out0[0..len], out0[0..len], prev[0..len], r1[0..len], prev[0..len]);
        try testing.expectEqualSlices(u8, want0[0..len], out0[0..len]);
        try testing.expectEqualSlices(u8, want1[0..len], prev[0..len]);
    }
}
