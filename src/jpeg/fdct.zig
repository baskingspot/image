//! The forward DCT and quantization of 8-bit samples.
//!
//! The arithmetic is the accurate integer DCT of Loeffler, Ligtenberg, and
//! Moschytz ("Practical fast 1-D DCT algorithms with 11 multiplications",
//! ICASSP 1989), the inverse of idct.zig's, with the same 13-bit
//! fixed-point constants: a row pass that keeps two fractional bits, then
//! a column pass, each output scaled by 8 overall. Quantization divides by
//! eight times the table's value and rounds half away from zero (T.81
//! A.3.4). The encoder's output is meant to be libjpeg-turbo's byte for
//! byte for the same settings (docs/slop/jpeg.md, "Encoding"), so the
//! rounding points are those of its `JDCT_ISLOW` method: each output of
//! a pass is an exact integer sum of products, descaled once.
//!
//! Two blocks share each vector, one in each 128-bit half, as in idct.zig,
//! and the products are multiply-adds of 16-bit pairs into 32 bits
//! (pmaddwd), with the constants regrouped so that each output is at most
//! two of them; regrouping is exact, as each output's weight on each input
//! is the sum of the weights the butterflies give it. Samples of 8 bits
//! keep the sums within 16 bits and the products within 32: a row pass
//! output is at most 4,096 in magnitude, and a sum the column pass forms
//! at most 16,384.

const std = @import("std");
const testing = std.testing;
const natural = @import("huffman.zig").natural;
const simd = @import("simd.zig");
const Y = simd.Y;
const D = simd.D;
const madd = simd.madd;
const pack = simd.pack;
const unpack = simd.unpack;

const fix_0_298631336 = 2446;
const fix_0_390180644 = 3196;
const fix_0_541196100 = 4433;
const fix_0_765366865 = 6270;
const fix_0_899976223 = 7373;
const fix_1_175875602 = 9633;
const fix_1_501321110 = 12299;
const fix_1_847759065 = 15137;
const fix_1_961570560 = 16069;
const fix_2_053119869 = 16819;
const fix_2_562915447 = 20995;
const fix_3_072711026 = 25172;

const const_bits = 13;
const pass1_bits = 2;

/// A quantization table prepared for division: per coefficient in natural
/// order, the divisor's rounding offset, and two 16-bit multipliers whose
/// high halves, taken in turn, divide any dividend below 2^14 exactly: the
/// first is 2^s / d rounded up, for s = 14 + log2(d) rounded up, and the
/// second shifts the rest of the way to 2^s (Granlund and Montgomery,
/// "Division by invariant integers using multiplication", 1994, theorem
/// 4.2).
pub const Divisors = struct {
    half: [64]u16,
    mul: [64]u16,
    post: [64]u16,

    /// From `q`, the table in zigzag order, each value 1 to 255.
    pub fn init(q: *const [64]u16) Divisors {
        var d: Divisors = undefined;
        for (q, 0..) |v, z| {
            const k = natural[z];
            const div: u32 = @as(u32, v) * 8;
            const l: u6 = @intCast(std.math.log2_int_ceil(u32, div));
            const s = 14 + l;
            d.half[k] = @intCast(div / 2);
            d.mul[k] = @intCast(((@as(u64, 1) << s) + div - 1) / div);
            d.post[k] = @as(u16, 1) << @intCast(32 - @as(u32, s));
        }
        return d;
    }
};

/// The quantized DCTs of the 8×8 blocks of samples at `a` and `b` (rows
/// `stride` apart), in natural order, into `out_a` and `out_b`.
pub fn forwardPair(
    a: []const u8,
    b: []const u8,
    stride: usize,
    div: *const Divisors,
    out_a: *[64]i16,
    out_b: *[64]i16,
) void {
    var x: [8]Y = undefined;
    inline for (0..8) |r| {
        const H = @Vector(8, u8);
        const v = std.simd.join(@as(H, a[r * stride ..][0..8].*), @as(H, b[r * stride ..][0..8].*));
        x[r] = @as(Y, @intCast(v)) - @as(Y, @splat(128));
    }
    // The row pass works on the transposed rows, each lane a row, and the
    // column pass on its transpose, each lane a column.
    const c = pass(transpose16(pass(transpose16(x), .rows)), .columns);
    // Quantized, row by row of each block.
    const U16 = @Vector(16, u16);
    var q: [2][8]@Vector(8, i16) = undefined;
    inline for (0..8) |v| {
        const H = @Vector(8, u16);
        const half: U16 = std.simd.join(@as(H, div.half[v * 8 ..][0..8].*), @as(H, div.half[v * 8 ..][0..8].*));
        const mul: U16 = std.simd.join(@as(H, div.mul[v * 8 ..][0..8].*), @as(H, div.mul[v * 8 ..][0..8].*));
        const post: U16 = std.simd.join(@as(H, div.post[v * 8 ..][0..8].*), @as(H, div.post[v * 8 ..][0..8].*));
        const n: U16 = @abs(c[v]) + half;
        const r: Y = @bitCast(simd.mulhu(simd.mulhu(n, mul), post));
        const signed = @select(i16, c[v] < @as(Y, @splat(0)), -r, r);
        const halves: [2]@Vector(8, i16) = @bitCast(signed);
        q[0][v] = halves[0];
        q[1][v] = halves[1];
    }
    out_a.* = @bitCast(q[0]);
    out_b.* = @bitCast(q[1]);
}

/// One pass of the 1-D DCT on sixteen lanes at once: `x[i]` holds input
/// `i` of each lane's transform, and the result output `i`, descaled.
fn pass(x: [8]Y, comptime which: Pass) [8]Y {
    const t: Terms = .{
        .tmp10 = (x[0] + x[7]) + (x[3] + x[4]),
        .tmp13 = (x[0] + x[7]) - (x[3] + x[4]),
        .tmp11 = (x[1] + x[6]) + (x[2] + x[5]),
        .tmp12 = (x[1] + x[6]) - (x[2] + x[5]),
        .tmp4 = x[3] - x[4],
        .tmp5 = x[2] - x[5],
        .tmp6 = x[1] - x[6],
        .tmp7 = x[0] - x[7],
    };
    const lo = halfPass(t, unpack(.lo16), which);
    const hi = halfPass(t, unpack(.hi16), which);
    var o: [8]Y = undefined;
    inline for (0..8) |k| o[k] = pack(lo[k], hi[k]);
    return o;
}

const Pass = enum { rows, columns };

/// The sums and differences of a pass's inputs that its products take.
const Terms = struct { tmp10: Y, tmp11: Y, tmp12: Y, tmp13: Y, tmp4: Y, tmp5: Y, tmp6: Y, tmp7: Y };

/// The outputs for the half of each 128-bit half's lanes that `mask`
/// picks, as 32-bit lanes.
fn halfPass(t: Terms, comptime mask: @Vector(16, i32), comptime which: Pass) [8]D {
    const p1011 = @shuffle(i16, t.tmp10, t.tmp11, mask);
    const p1213 = @shuffle(i16, t.tmp12, t.tmp13, mask);
    const p45 = @shuffle(i16, t.tmp4, t.tmp5, mask);
    const p67 = @shuffle(i16, t.tmp6, t.tmp7, mask);
    const bits = if (which == .rows) const_bits - pass1_bits else const_bits + pass1_bits;
    const r: D = @splat(1 << (bits - 1));
    var o: [8]D = undefined;
    if (which == .rows) {
        o[0] = madd(p1011, 1 << pass1_bits, 1 << pass1_bits);
        o[4] = madd(p1011, 1 << pass1_bits, -(1 << pass1_bits));
    } else {
        const r1: D = @splat(1 << (pass1_bits - 1));
        o[0] = (madd(p1011, 1, 1) + r1) >> @splat(pass1_bits);
        o[4] = (madd(p1011, 1, -1) + r1) >> @splat(pass1_bits);
    }
    // Even part: z1 = (tmp12 + tmp13)·c(0.541) taken into each weight.
    o[2] = (madd(p1213, fix_0_541196100, fix_0_541196100 + fix_0_765366865) + r) >> @splat(bits);
    o[6] = (madd(p1213, fix_0_541196100 - fix_1_847759065, fix_0_541196100) + r) >> @splat(bits);
    // Odd part: each output's weight on tmp4..tmp7 gathers its own
    // constant, the z1..z4 rotations it takes part in, and
    // z5 = (tmp4 + tmp5 + tmp6 + tmp7)·c(1.176).
    const c5 = fix_1_175875602;
    const b1 = fix_0_899976223;
    const b2 = fix_2_562915447;
    const b3 = fix_1_961570560;
    const b4 = fix_0_390180644;
    o[7] = (madd(p45, fix_0_298631336 - b1 - b3 + c5, c5) + madd(p67, c5 - b3, c5 - b1) + r) >> @splat(bits);
    o[5] = (madd(p45, c5, fix_2_053119869 - b2 - b4 + c5) + madd(p67, c5 - b2, c5 - b4) + r) >> @splat(bits);
    o[3] = (madd(p45, c5 - b3, c5 - b2) + madd(p67, fix_3_072711026 - b2 - b3 + c5, c5) + r) >> @splat(bits);
    o[1] = (madd(p45, c5 - b1, c5 - b4) + madd(p67, c5, fix_1_501321110 - b1 - b4 + c5) + r) >> @splat(bits);
    return o;
}

/// Each half's 8×8 transpose, in three rounds of unpacks.
fn transpose16(m: [8]Y) [8]Y {
    var a: [8]Y = undefined;
    inline for (0..4) |i| {
        a[2 * i] = @shuffle(i16, m[2 * i], m[2 * i + 1], unpack(.lo16));
        a[2 * i + 1] = @shuffle(i16, m[2 * i], m[2 * i + 1], unpack(.hi16));
    }
    var b: [8]Y = undefined;
    inline for (0..2) |h| {
        inline for (0..2) |k| {
            const x = a[4 * h + k];
            const y = a[4 * h + 2 + k];
            b[4 * h + 2 * k] = @shuffle(i16, x, y, unpack(.lo32));
            b[4 * h + 2 * k + 1] = @shuffle(i16, x, y, unpack(.hi32));
        }
    }
    var t: [8]Y = undefined;
    inline for (0..4) |j| {
        t[2 * j] = @shuffle(i16, b[j], b[4 + j], unpack(.lo64));
        t[2 * j + 1] = @shuffle(i16, b[j], b[4 + j], unpack(.hi64));
    }
    return t;
}

/// The same transform in 32-bit lanes, one block at a time, as the
/// butterflies of the paper's figure 1 compute it: the tests' reference.
const reference = struct {
    const V = @Vector(8, i32);

    fn forward(samples: []const u8, stride: usize, q: *const [64]u16) [64]i16 {
        var rows: [8]V = undefined;
        for (&rows, 0..) |*r, y| {
            const s: @Vector(8, u8) = samples[y * stride ..][0..8].*;
            r.* = @as(V, s) - @as(V, @splat(128));
        }
        const coef: [64]i32 = @bitCast(pass1d(transpose(pass1d(transpose(rows), .rows)), .columns));
        var out: [64]i16 = undefined;
        for (&out, 0..) |*o, n| {
            const x = coef[n];
            const d: i32 = @as(i32, q[pos(n)]) * 8;
            const a = @divTrunc(@as(i32, @intCast(@abs(x))) + @divTrunc(d, 2), d);
            o.* = @intCast(if (x < 0) -a else a);
        }
        return out;
    }

    /// The zigzag position of natural index `n`.
    fn pos(n: usize) usize {
        return std.mem.findScalar(u8, natural[0..64], @intCast(n)).?;
    }

    fn transpose(m: [8]V) [8]V {
        const a: [64]i32 = @bitCast(m);
        var b: [64]i32 = undefined;
        for (0..8) |y| for (0..8) |x| {
            b[x * 8 + y] = a[y * 8 + x];
        };
        return @bitCast(b);
    }

    fn descale(x: V, comptime n: u5) V {
        return (x + @as(V, @splat(1 << (n - 1)))) >> @splat(n);
    }

    fn k(comptime c: i32) V {
        return @splat(c);
    }

    fn pass1d(d: [8]V, comptime which: Pass) [8]V {
        const tmp0 = d[0] + d[7];
        const tmp7 = d[0] - d[7];
        const tmp1 = d[1] + d[6];
        const tmp6 = d[1] - d[6];
        const tmp2 = d[2] + d[5];
        const tmp5 = d[2] - d[5];
        const tmp3 = d[3] + d[4];
        const tmp4 = d[3] - d[4];
        const tmp10 = tmp0 + tmp3;
        const tmp13 = tmp0 - tmp3;
        const tmp11 = tmp1 + tmp2;
        const tmp12 = tmp1 - tmp2;
        var o: [8]V = undefined;
        const bits = if (which == .rows) const_bits - pass1_bits else const_bits + pass1_bits;
        if (which == .rows) {
            o[0] = (tmp10 + tmp11) << @splat(pass1_bits);
            o[4] = (tmp10 - tmp11) << @splat(pass1_bits);
        } else {
            o[0] = descale(tmp10 + tmp11, pass1_bits);
            o[4] = descale(tmp10 - tmp11, pass1_bits);
        }
        const z1 = (tmp12 + tmp13) * k(fix_0_541196100);
        o[2] = descale(z1 + tmp13 * k(fix_0_765366865), bits);
        o[6] = descale(z1 + tmp12 * k(-fix_1_847759065), bits);
        const z5 = (tmp4 + tmp6 + tmp5 + tmp7) * k(fix_1_175875602);
        const p4 = tmp4 * k(fix_0_298631336);
        const p5 = tmp5 * k(fix_2_053119869);
        const p6 = tmp6 * k(fix_3_072711026);
        const p7 = tmp7 * k(fix_1_501321110);
        const q1 = (tmp4 + tmp7) * k(-fix_0_899976223);
        const q2 = (tmp5 + tmp6) * k(-fix_2_562915447);
        const q3 = (tmp4 + tmp6) * k(-fix_1_961570560) + z5;
        const q4 = (tmp5 + tmp7) * k(-fix_0_390180644) + z5;
        o[7] = descale(p4 + q1 + q3, bits);
        o[5] = descale(p5 + q2 + q4, bits);
        o[3] = descale(p6 + q2 + q3, bits);
        o[1] = descale(p7 + q1 + q4, bits);
        return o;
    }
};

test "the paired 16-bit DCT is the butterflies' arithmetic exactly" {
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    for (0..2000) |round| {
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        // Noise, the extremes, and blocks near them, which give the
        // largest coefficients.
        for (&a, &b) |*x, *y| {
            x.* = switch (round % 4) {
                0 => r.int(u8),
                1 => if (r.boolean()) 255 else 0,
                2 => 255 - r.uintLessThan(u8, 4),
                else => r.uintLessThan(u8, 4),
            };
            y.* = r.int(u8);
        }
        var q: [64]u16 = undefined;
        for (&q) |*v| v.* = if (round % 3 == 0) 1 else 1 + r.uintLessThan(u16, 255);
        const div: Divisors = .init(&q);
        var out_a: [64]i16 = undefined;
        var out_b: [64]i16 = undefined;
        forwardPair(&a, &b, 8, &div, &out_a, &out_b);
        try testing.expectEqualSlices(i16, &reference.forward(&a, 8, &q), &out_a);
        try testing.expectEqualSlices(i16, &reference.forward(&b, 8, &q), &out_b);
    }
}

test "a flat block has only a DC coefficient" {
    var samples: [64]u8 = @splat(200);
    var q: [64]u16 = @splat(1);
    const div: Divisors = .init(&q);
    var out: [64]i16 = undefined;
    var other: [64]i16 = undefined;
    forwardPair(&samples, &samples, 8, &div, &out, &other);
    // (200 - 128) times 8, the DC basis's gain.
    try testing.expectEqual(576, out[0]);
    for (out[1..]) |c| try testing.expectEqual(0, c);
    samples = @splat(0);
    q[0] = 16;
    forwardPair(&samples, &samples, 8, &.init(&q), &out, &other);
    // -128 times 8 is -1024, over 16: -64 exactly.
    try testing.expectEqual(-64, out[0]);
}

test "the DCT agrees with its definition within rounding" {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const q: [64]u16 = @splat(1);
    const div: Divisors = .init(&q);
    for (0..200) |_| {
        var samples: [64]u8 = undefined;
        r.bytes(&samples);
        var out: [64]i16 = undefined;
        var other: [64]i16 = undefined;
        forwardPair(&samples, &samples, 8, &div, &out, &other);
        for (0..64) |n| {
            const u = n % 8;
            const v = n / 8;
            var sum: f64 = 0;
            for (0..8) |y| for (0..8) |x| {
                const s = @as(f64, @floatFromInt(samples[y * 8 + x])) - 128;
                sum += s * @cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16) *
                    @cos(@as(f64, @floatFromInt((2 * y + 1) * v)) * std.math.pi / 16);
            };
            const cu: f64 = if (u == 0) std.math.sqrt1_2 else 1;
            const cv: f64 = if (v == 0) std.math.sqrt1_2 else 1;
            const want = sum * cu * cv / 4;
            try testing.expect(@abs(@as(f64, @floatFromInt(out[n])) - want) < 1.5);
        }
    }
}

test "quantization divides exactly, rounding half away from zero" {
    // Every table value, and every dividend a block can give: at most
    // 8,192 from the DCT, plus half the divisor.
    for (1..256) |v| {
        const q: [64]u16 = @splat(@intCast(v));
        const div: Divisors = .init(&q);
        const d: u32 = @as(u32, @intCast(v)) * 8;
        var a: u32 = 0;
        while (a <= 8192) : (a += 1) {
            const n = a + div.half[0];
            const t = (n * div.mul[0]) >> 16;
            try testing.expectEqual((a + d / 2) / d, (t * div.post[0]) >> 16);
        }
    }
}
