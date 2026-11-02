//! The few x86 instructions the hot loops need that LLVM does not choose
//! from portable vector code, each with a portable fallback: multiply-add
//! of 16-bit pairs (pmaddwd), packing 32-bit lanes to 16 with saturation
//! (packssdw), and the rounding high multiply (pmulhrsw). The vectors are
//! 256 bits, two 128-bit halves that the x86 instructions treat
//! separately, so the shuffles here stay within each half.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Sixteen 16-bit lanes.
pub const Y = @Vector(16, i16);
/// Eight 32-bit lanes.
pub const D = @Vector(8, i32);

pub const has_avx2 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// Each pair of lanes of `p` times `k0` and `k1`, summed (x86's pmaddwd).
pub inline fn madd(p: Y, comptime k0: i16, comptime k1: i16) D {
    if (has_avx2) {
        // LLVM sees through the pairs to the inputs they came from and
        // multiplies each separately, at twice the cost, so the
        // instruction is spelled out.
        const k: Y = @as([16]i16, [2]i16{ k0, k1 } ** 8);
        return asm ("vpmaddwd %[k], %[p], %[r]"
            : [r] "=x" (-> D),
            : [p] "x" (p),
              [k] "x" (k),
        );
    }
    const even: @Vector(8, i32) = .{ 0, 2, 4, 6, 8, 10, 12, 14 };
    const odd: @Vector(8, i32) = .{ 1, 3, 5, 7, 9, 11, 13, 15 };
    const a: D = @shuffle(i16, p, undefined, even);
    const b: D = @shuffle(i16, p, undefined, odd);
    return a * @as(D, @splat(k0)) + b * @as(D, @splat(k1));
}

/// Each pair of lanes of `a` times the same of `b`, summed (pmaddwd).
pub inline fn maddv(a: Y, b: Y) D {
    if (has_avx2) {
        return asm ("vpmaddwd %[b], %[a], %[r]"
            : [r] "=x" (-> D),
            : [a] "x" (a),
              [b] "x" (b),
        );
    }
    const even: @Vector(8, i32) = .{ 0, 2, 4, 6, 8, 10, 12, 14 };
    const odd: @Vector(8, i32) = .{ 1, 3, 5, 7, 9, 11, 13, 15 };
    const ae: D = @shuffle(i16, a, undefined, even);
    const ao: D = @shuffle(i16, a, undefined, odd);
    const be: D = @shuffle(i16, b, undefined, even);
    const bo: D = @shuffle(i16, b, undefined, odd);
    return ae * be +% ao * bo;
}

/// Shuffle masks that interleave two vectors within each 128-bit half,
/// as x86's unpack instructions do: the low or high half's 16-, 32-, or
/// 64-bit elements of each.
pub fn unpack(comptime kind: enum { lo16, hi16, lo32, hi32, lo64, hi64 }) @Vector(16, i32) {
    const size: usize, const start: usize = switch (kind) {
        .lo16 => .{ 1, 0 },
        .hi16 => .{ 1, 4 },
        .lo32 => .{ 2, 0 },
        .hi32 => .{ 2, 4 },
        .lo64 => .{ 4, 0 },
        .hi64 => .{ 4, 4 },
    };
    var m: [16]i32 = undefined;
    for (0..2) |half| {
        for (0..8) |i| {
            const element = i / size;
            const src = half * 8 + start + (element / 2) * size + i % size;
            m[half * 8 + i] = if (element % 2 == 0) @intCast(src) else ~@as(i32, @intCast(src));
        }
    }
    return m;
}

/// Two vectors of 32-bit lanes, each holding the low or high four of each
/// half's eight results, back into one of 16-bit lanes in order (x86's
/// packssdw). Every value fits, so saturating changes nothing.
pub fn pack(lo: D, hi: D) Y {
    if (has_avx2) {
        // Spelled out, as LLVM narrows each vector and then shuffles.
        return asm ("vpackssdw %[hi], %[lo], %[r]"
            : [r] "=x" (-> Y),
            : [lo] "x" (lo),
              [hi] "x" (hi),
        );
    }
    const l: @Vector(8, i16) = @intCast(@max(@min(lo, @as(D, @splat(32767))), @as(D, @splat(-32768))));
    const h: @Vector(8, i16) = @intCast(@max(@min(hi, @as(D, @splat(32767))), @as(D, @splat(-32768))));
    return @shuffle(i16, l, h, @Vector(16, i32){ 0, 1, 2, 3, -1, -2, -3, -4, 4, 5, 6, 7, -5, -6, -7, -8 });
}

/// Each lane of `a` times `m`, over 2^15, rounded half up (x86's
/// pmulhrsw).
pub inline fn mulhrs(a: Y, comptime m: i16) Y {
    if (has_avx2) {
        // LLVM widens to 32 bits instead.
        const k: Y = @splat(m);
        return asm ("vpmulhrsw %[k], %[a], %[r]"
            : [r] "=x" (-> Y),
            : [a] "x" (a),
              [k] "x" (k),
        );
    }
    const W = @Vector(16, i32);
    const p = @as(W, a) * @as(W, @splat(m));
    return @truncate((p + @as(W, @splat(1 << 14))) >> @splat(15));
}

/// The high 16 bits of each unsigned product of `a` and `b` (x86's
/// pmulhuw).
pub inline fn mulhu(a: @Vector(16, u16), b: @Vector(16, u16)) @Vector(16, u16) {
    if (has_avx2) {
        // LLVM widens to 32-bit lanes, which takes 512-bit registers.
        return asm ("vpmulhuw %[b], %[a], %[r]"
            : [r] "=x" (-> @Vector(16, u16)),
            : [a] "x" (a),
              [b] "x" (b),
        );
    }
    const W = @Vector(16, u32);
    return @truncate((@as(W, a) * @as(W, b)) >> @splat(16));
}

test "the instructions and their fallbacks agree" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for (0..1000) |_| {
        var a: [16]i16 = undefined;
        var b: [8]i32 = undefined;
        var c: [8]i32 = undefined;
        for (&a) |*v| v.* = random.int(i16);
        for (&b) |*v| v.* = random.int(i32);
        for (&c) |*v| v.* = random.int(i32);
        const p: [8]i32 = madd(a, 1234, -32768);
        const pv: [8]i32 = maddv(a, @splat(1234));
        const h: [16]i16 = mulhrs(a, -12345);
        var ua: [16]u16 = undefined;
        var ub: [16]u16 = undefined;
        for (&ua, &ub) |*x, *y| {
            x.* = random.int(u16);
            y.* = random.int(u16);
        }
        const hu: [16]u16 = mulhu(ua, ub);
        const k: [16]i16 = pack(b, c);
        for (0..16) |i| {
            if (i < 8) try testing.expectEqual(@as(i32, a[2 * i]) * 1234 + @as(i32, a[2 * i + 1]) * -32768, p[i]);
            if (i < 8) try testing.expectEqual((@as(i32, a[2 * i]) + a[2 * i + 1]) * 1234, pv[i]);
            try testing.expectEqual(@as(i16, @intCast((@as(i32, a[i]) * -12345 + (1 << 14)) >> 15)), h[i]);
            try testing.expectEqual(@as(u16, @intCast((@as(u32, ua[i]) * ub[i]) >> 16)), hu[i]);
            const src = if (i % 8 < 4) b[(i / 8) * 4 + i % 4] else c[(i / 8) * 4 + i % 4];
            try testing.expectEqual(@as(i16, @intCast(std.math.clamp(src, -32768, 32767))), k[i]);
        }
    }
}
