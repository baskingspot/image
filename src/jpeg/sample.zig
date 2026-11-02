//! Upsampling and color conversion, row by row, as libjpeg-turbo does them
//! by default (owner decision 2, docs/slop/jpeg.md):
//!
//! - "Fancy" upsampling for the 2:1 ratios: a triangle filter, 3/4 of the
//!   nearer sample and 1/4 of the farther, horizontally (h2v1), vertically
//!   (h1v2), or both (h2v2, 9:3:3:1), with the rounding that alternates
//!   between the two output samples of each input. Every other integral
//!   ratio, and the 2:1 ones when a component is at most two samples wide
//!   or when scaling to 1/8, replicates samples.
//! - YCbCr to RGB with T.871's equations in 16-bit fixed point, and the
//!   naive CMYK to RGB that multiplies each ink's inverse by black's.

const std = @import("std");
const testing = std.testing;
const simd = @import("simd.zig");

/// How one component reaches the output's resolution.
pub const Up = union(enum) {
    full,
    h2v1,
    h1v2,
    h2v2,
    /// Replication by integral factors.
    box: struct { h: u8, v: u8 },

    /// The vertical ratio from the component's rows to the output's.
    pub fn vexp(u: Up) u32 {
        return switch (u) {
            .full, .h2v1 => 1,
            .h1v2, .h2v2 => 2,
            .box => |b| b.v,
        };
    }

    pub fn hexp(u: Up) u32 {
        return switch (u) {
            .full, .h1v2 => 1,
            .h2v1, .h2v2 => 2,
            .box => |b| b.h,
        };
    }

    /// Whether it reads the rows above and below.
    pub fn context(u: Up) bool {
        return u == .h1v2 or u == .h2v2;
    }
};

/// h2v1: `w` samples (at least 3) to `2w`.
pub fn h2v1(comptime S: type, out: []S, in: []const S, w: usize) void {
    const o = out[0 .. 2 * w];
    const s = in[0..w];
    o[0] = s[0];
    o[1] = @intCast((@as(u32, s[0]) * 3 + s[1] + 2) >> 2);
    var i: usize = 1;
    if (S == u8) {
        // Sixteen inputs at a time, each from its neighbors on both sides.
        const V = @Vector(16, u16);
        while (i + 17 <= w) : (i += 16) {
            const c: V = s[i..][0..16].*;
            const l: V = s[i - 1 ..][0..16].*;
            const r: V = s[i + 1 ..][0..16].*;
            const c3 = c * @as(V, @splat(3));
            const even: @Vector(16, u8) = @intCast((c3 + l + @as(V, @splat(1))) >> @splat(2));
            const odd: @Vector(16, u8) = @intCast((c3 + r + @as(V, @splat(2))) >> @splat(2));
            o[2 * i ..][0..32].* = std.simd.interlace(.{ even, odd });
        }
    }
    while (i < w - 1) : (i += 1) {
        const c = @as(u32, s[i]) * 3;
        o[2 * i] = @intCast((c + s[i - 1] + 1) >> 2);
        o[2 * i + 1] = @intCast((c + s[i + 1] + 2) >> 2);
    }
    o[2 * w - 2] = @intCast((@as(u32, s[w - 1]) * 3 + s[w - 2] + 1) >> 2);
    o[2 * w - 1] = s[w - 1];
}

/// h1v2: one output row from the nearer row and the farther one, with
/// rounding `bias` 1 above and 2 below.
pub fn h1v2(comptime S: type, out: []S, near: []const S, far: []const S, w: usize, bias: u32) void {
    for (out[0..w], near[0..w], far[0..w]) |*o, a, b| o.* = @intCast((@as(u32, a) * 3 + b + bias) >> 2);
}

/// h2v2: one output row, `2w` samples, from the nearer row and the farther
/// one (`w` at least 3).
pub fn h2v2(comptime S: type, out: []S, near: []const S, far: []const S, w: usize) void {
    const o = out[0 .. 2 * w];
    const a = near[0..w];
    const b = far[0..w];
    var last: u32 = @as(u32, a[0]) * 3 + b[0];
    var this = last;
    var next: u32 = @as(u32, a[1]) * 3 + b[1];
    o[0] = @intCast((this * 4 + 8) >> 4);
    o[1] = @intCast((this * 3 + next + 7) >> 4);
    var i: usize = 1;
    if (S == u8) {
        // Sixteen inputs at a time: the column sums of each input's
        // neighbors are recomputed rather than carried.
        const V = @Vector(16, u16);
        const k3: V = @splat(3);
        while (i + 17 <= w) : (i += 16) {
            const t = @as(V, a[i..][0..16].*) * k3 + @as(V, b[i..][0..16].*);
            const l = @as(V, a[i - 1 ..][0..16].*) * k3 + @as(V, b[i - 1 ..][0..16].*);
            const r = @as(V, a[i + 1 ..][0..16].*) * k3 + @as(V, b[i + 1 ..][0..16].*);
            const t3 = t * k3;
            const even: @Vector(16, u8) = @intCast((t3 + l + @as(V, @splat(8))) >> @splat(4));
            const odd: @Vector(16, u8) = @intCast((t3 + r + @as(V, @splat(7))) >> @splat(4));
            o[2 * i ..][0..32].* = std.simd.interlace(.{ even, odd });
        }
        this = @as(u32, a[i - 1]) * 3 + b[i - 1];
        next = @as(u32, a[i]) * 3 + b[i];
    }
    while (i < w - 1) : (i += 1) {
        last = this;
        this = next;
        next = @as(u32, a[i + 1]) * 3 + b[i + 1];
        o[2 * i] = @intCast((this * 3 + last + 8) >> 4);
        o[2 * i + 1] = @intCast((this * 3 + next + 7) >> 4);
    }
    last = this;
    this = next;
    o[2 * w - 2] = @intCast((this * 3 + last + 8) >> 4);
    o[2 * w - 1] = @intCast((this * 4 + 7) >> 4);
}

/// Replicates each of `w` samples `h` times.
pub fn box(comptime S: type, out: []S, in: []const S, w: usize, h: u32) void {
    if (h == 1) return @memcpy(out[0..w], in[0..w]);
    if (h == 2) {
        for (in[0..w], 0..) |s, i| out[2 * i ..][0..2].* = .{ s, s };
        return;
    }
    for (in[0..w], 0..) |s, i| @memset(out[i * h ..][0..h], s);
}

// T.871's YCbCr to RGB in 16-bit fixed point:
// R = Y + 1.402 Cr', G = Y - 0.34414 Cb' - 0.71414 Cr', B = Y + 1.772 Cb'.
const fix_1_402 = 91881;
const fix_1_772 = 116130;
const fix_0_71414 = 46802;
const fix_0_34414 = 22554;

/// One pixel's RGB from YCbCr, `bits` per sample.
pub inline fn ycc(comptime bits: u8, y: i32, cb: i32, cr: i32) [3]i32 {
    const center = 1 << (bits - 1);
    const max = (1 << bits) - 1;
    const b = cb - center;
    const r = cr - center;
    return .{
        std.math.clamp(y + ((fix_1_402 * r + 32768) >> 16), 0, max),
        std.math.clamp(y + ((-fix_0_34414 * b + 32768 - fix_0_71414 * r) >> 16), 0, max),
        std.math.clamp(y + ((fix_1_772 * b + 32768) >> 16), 0, max),
    };
}

/// `n` pixels of YCbCr rows to interleaved RGB.
pub fn yccToRgb(out: []u8, y: []const u8, cb: []const u8, cr: []const u8, n: usize) void {
    const lanes = 16;
    const V = @Vector(lanes, i32);
    const B = @Vector(lanes, u8);
    var i: usize = 0;
    if (simd.has_avx2) {
        // In 16-bit lanes: R's and B's terms are each one rounding high
        // multiply, with constants an exhaustive search over the 256
        // chroma values found to give the 32-bit formula's results
        // exactly, and G's two products are one multiply-add, Cr doubled
        // to halve its constant into 16 bits. The final clamp is the
        // narrowing to bytes.
        const Y = simd.Y;
        while (i + lanes <= n) : (i += lanes) {
            const yv: Y = @as(B, y[i..][0..lanes].*);
            const b = @as(Y, @as(B, cb[i..][0..lanes].*)) - @as(Y, @splat(128));
            const r = @as(Y, @as(B, cr[i..][0..lanes].*)) - @as(Y, @splat(128));
            const rr = yv + r + simd.mulhrs(r, 13172);
            const bb = yv + b + simd.mulhrs(b, 25297);
            const r2 = r + r;
            const half: simd.D = @splat(32768);
            const g_lo = simd.madd(@shuffle(i16, b, r2, simd.unpack(.lo16)), -fix_0_34414, -fix_0_71414 / 2);
            const g_hi = simd.madd(@shuffle(i16, b, r2, simd.unpack(.hi16)), -fix_0_34414, -fix_0_71414 / 2);
            const lo = (g_lo + half) >> @splat(16);
            const hi = (g_hi + half) >> @splat(16);
            const gg = yv + simd.pack(lo, hi);
            const lo8: Y = @splat(0);
            const hi8: Y = @splat(255);
            const r8: B = @intCast(@min(@max(rr, lo8), hi8));
            const g8: B = @intCast(@min(@max(gg, lo8), hi8));
            const b8: B = @intCast(@min(@max(bb, lo8), hi8));
            out[i * 3 ..][0 .. 3 * lanes].* = std.simd.interlace(.{ r8, g8, b8 });
        }
    }
    while (i + lanes <= n) : (i += lanes) {
        const yv: V = @as(B, y[i..][0..lanes].*);
        const b: V = @as(V, @as(B, cb[i..][0..lanes].*)) - @as(V, @splat(128));
        const r: V = @as(V, @as(B, cr[i..][0..lanes].*)) - @as(V, @splat(128));
        const half: V = @splat(32768);
        const rr = yv + ((@as(V, @splat(fix_1_402)) * r + half) >> @splat(16));
        const gg = yv + ((@as(V, @splat(-fix_0_34414)) * b + half - @as(V, @splat(fix_0_71414)) * r) >> @splat(16));
        const bb = yv + ((@as(V, @splat(fix_1_772)) * b + half) >> @splat(16));
        const lo: V = @splat(0);
        const hi: V = @splat(255);
        const r8: B = @intCast(@min(@max(rr, lo), hi));
        const g8: B = @intCast(@min(@max(gg, lo), hi));
        const b8: B = @intCast(@min(@max(bb, lo), hi));
        out[i * 3 ..][0 .. 3 * lanes].* = std.simd.interlace(.{ r8, g8, b8 });
    }
    while (i < n) : (i += 1) {
        const p = ycc(8, y[i], cb[i], cr[i]);
        out[i * 3 ..][0..3].* = .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]) };
    }
}

/// libjpeg-turbo's naive CMYK to RGB for inks stored inverted, as Adobe
/// writes them: each channel is the ink's sample times black's, over the
/// maximum, rounded.
pub inline fn cmyk(comptime bits: u8, c: u32, k: u32) u32 {
    const max = (1 << bits) - 1;
    return (2 * c * k + max) / (2 * max);
}

test "fancy upsampling rounds as the reference does" {
    var out: [8]u8 = undefined;
    h2v1(u8, &out, &.{ 10, 20, 30, 41 }, 4);
    // 3/4 nearer + 1/4 farther, +1 on the left output, +2 on the right.
    try testing.expectEqualSlices(u8, &.{ 10, 13, 17, 23, 27, 33, 38, 41 }, &out);
    h2v2(u8, &out, &.{ 10, 20, 30, 40 }, &.{ 50, 60, 70, 80 }, 4);
    // Column sums 80, 120, 160, 200; +8 on the left output, +7 on the right.
    try testing.expectEqualSlices(u8, &.{ 20, 22, 28, 32, 38, 42, 48, 50 }, &out);
    h1v2(u8, out[0..2], &.{ 10, 11 }, &.{ 20, 20 }, 2, 1);
    try testing.expectEqualSlices(u8, &.{ 12, 13 }, out[0..2]);
    box(u8, &out, &.{ 1, 2 }, 2, 4);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 2, 2, 2, 2 }, &out);
}

test "fancy upsampling's vector and scalar paths agree" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rand = prng.random();
    var a: [80]u8 = undefined;
    var b: [80]u8 = undefined;
    var out: [160]u8 = undefined;
    var want: [160]u8 = undefined;
    for (3..a.len) |w| {
        rand.bytes(&a);
        rand.bytes(&b);
        // Each output from the column sums (h2v2) or samples (h2v1) beside
        // it, the edges repeating.
        h2v2(u8, &out, &a, &b, w);
        for (0..2 * w) |x| {
            const k = x / 2;
            const other = if (x % 2 == 0) k -| 1 else @min(k + 1, w - 1);
            const t = @as(u32, a[k]) * 3 + b[k];
            const u = @as(u32, a[other]) * 3 + b[other];
            want[x] = @intCast((t * 3 + u + @as(u32, if (x % 2 == 0) 8 else 7)) >> 4);
        }
        try testing.expectEqualSlices(u8, want[0 .. 2 * w], out[0 .. 2 * w]);
        h2v1(u8, &out, &a, w);
        for (0..2 * w) |x| {
            const k = x / 2;
            const other = if (x % 2 == 0) k -| 1 else @min(k + 1, w - 1);
            want[x] = @intCast((@as(u32, a[k]) * 3 + a[other] + @as(u32, if (x % 2 == 0) 1 else 2)) >> 2);
        }
        try testing.expectEqualSlices(u8, want[0 .. 2 * w], out[0 .. 2 * w]);
    }
}

test "ycc vector and scalar paths agree" {
    var y: [37]u8 = undefined;
    var cb: [37]u8 = undefined;
    var cr: [37]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    for (0..200) |_| {
        prng.random().bytes(&y);
        prng.random().bytes(&cb);
        prng.random().bytes(&cr);
        var out: [37 * 3]u8 = undefined;
        yccToRgb(&out, &y, &cb, &cr, 37);
        for (0..37) |i| {
            const p = ycc(8, y[i], cb[i], cr[i]);
            const want: [3]u8 = .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]) };
            try testing.expectEqualSlices(u8, &want, out[i * 3 ..][0..3]);
        }
    }
    // Every chroma pair, with luma across the range.
    for (0..256) |b| {
        for (0..256) |r| {
            var yy: [16]u8 = undefined;
            for (&yy, 0..) |*v, i| v.* = @truncate(b * 7 + r * 13 + i * 17);
            const bs: [16]u8 = @splat(@intCast(b));
            const rs: [16]u8 = @splat(@intCast(r));
            var out: [48]u8 = undefined;
            yccToRgb(&out, &yy, &bs, &rs, 16);
            for (0..16) |i| {
                const p = ycc(8, yy[i], @intCast(b), @intCast(r));
                const want: [3]u8 = .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]) };
                try testing.expectEqualSlices(u8, &want, out[i * 3 ..][0..3]);
            }
        }
    }
    // Gray stays gray; pure red's chroma.
    try testing.expectEqual([3]i32{ 100, 100, 100 }, ycc(8, 100, 128, 128));
    try testing.expectEqual([3]i32{ 254, 0, 0 }, ycc(8, 76, 85, 255));
}

test "cmyk" {
    try testing.expectEqual(255, cmyk(8, 255, 255));
    try testing.expectEqual(0, cmyk(8, 0, 255));
    try testing.expectEqual(64, cmyk(8, 128, 127));
    try testing.expectEqual(4095, cmyk(12, 4095, 4095));
}
