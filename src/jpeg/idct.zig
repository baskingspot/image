//! Dequantization and the inverse DCT, at the full 8×8 size and at the
//! reduced 4×4, 2×2, and 1×1 sizes that DCT-domain scaling uses.
//!
//! The arithmetic is the accurate integer IDCT of Loeffler, Ligtenberg,
//! and Moschytz ("Practical fast 1-D DCT algorithms with 11
//! multiplications", ICASSP 1989), with 13-bit fixed-point constants, two
//! fractional bits kept between the column and row passes for 8-bit
//! samples and one for 12-bit, and the reduced sizes computed from the
//! low-frequency coefficients with the same constants. Owner decision 2
//! (docs/slop/plan.md) is to match libjpeg-turbo's output bit for bit, so
//! the rounding, the order of operations, and the handling of results out
//! of range are the ones its `JDCT_ISLOW` method uses (docs/slop/jpeg.md):
//!
//! - Quantization values are 16-bit signed multipliers for 8-bit samples,
//!   so a value past 32767 is negative, and unsigned for 12-bit ones: its
//!   12-bit code is built without SIMD, where the multiplier type is `int`
//!   rather than `short`.
//! - The column pass's results are kept to 32 bits.
//! - A result is wrapped to 10 bits (14 for 12-bit samples) around the
//!   center before it is clamped, so wildly out-of-range values from
//!   corrupt data wrap instead of saturating.
//!
//! Real images never come near overflowing 32-bit arithmetic, but corrupt
//! data can, and the reference computes in 64 bits. So a block whose
//! dequantized coefficients sum (in magnitude) to at most `safe_sum` runs
//! in 32-bit vectors, which cannot overflow then (the largest weight any
//! one coefficient has on an intermediate value is under 2^17.1, for the
//! 8×8 row pass), and any other block in 64 bits. 12-bit blocks always use
//! 64 bits.

const std = @import("std");
const testing = std.testing;
const simd = @import("simd.zig");
const Y = simd.Y;
const D = simd.D;
const madd = simd.madd;
const pack = simd.pack;
const unpack = simd.unpack;

/// The largest sum of dequantized coefficient magnitudes that the 32-bit
/// path takes. The largest weight of one coefficient on any intermediate
/// is 139,663 (8×8), 107,615 (4×4), and 131,072 (2×2), so a sum of 15,000
/// keeps every intermediate under 2^31 with room for the rounding terms.
const safe_sum = 15000;

/// The largest sum of dequantized coefficient magnitudes that the 16-bit
/// path (`pair`) takes. Each output of a pass is the sum of its inputs
/// times weights of at most 11,363 (2^13 times 1.387), so the column
/// pass's results, descaled by 2^11, stay under 5.55 times the sum: within
/// 16 bits for a sum up to 5,900, and the row pass's products and sums
/// within 32.
const fast_sum = 5900;

/// The sample type for a precision.
pub fn Sample(comptime bits: u8) type {
    return if (bits == 8) u8 else u16;
}

/// Dequantizes `block` (natural order) by `q` and writes its `size`×`size`
/// inverse DCT (size 8, 4, 2, or 1) to `out`, rows `stride` samples apart.
pub fn idct(
    comptime bits: u8,
    comptime size: u4,
    block: *const [64]i16,
    q: *const [64]i16,
    out: []Sample(bits),
    stride: usize,
) void {
    if (size == 1) {
        // The DC term alone: dequantized, divided by 8, rounded.
        const dc: i64 = @as(i32, block[0]) * quant(bits, q[0]);
        store(bits, @truncate((dc + 4) >> 3), out[0..1]);
        return;
    }
    if (bits == 8) {
        const sum = sumAbs(block, q);
        if (size == 8 and sum <= fast_sum) {
            const j: Job = .{ .block = block, .q = q, .out = out, .stride = stride };
            return pair(j, j);
        }
        if (sum <= safe_sum) return kernel(i32, bits, size, block, q, out, stride);
    }
    kernel(i64, bits, size, block, q, out, stride);
}

/// Whether every coefficient but the DC is zero: then every sample is the
/// same, from the DC alone.
pub fn dcOnly(comptime bits: u8, comptime size: u4, dc: i16, q0: i16, out: []Sample(bits), stride: usize) void {
    // The column pass makes dc·q·2^pass1 (kept to 32 bits), and the row
    // pass rounds it down by pass1 + 3 bits.
    const pass1 = if (bits == 8) 2 else 1;
    const ws: i32 = @truncate(@as(i64, @as(i32, dc) * quant(bits, q0)) << pass1);
    const v: i32 = @truncate((@as(i64, ws) + (1 << (pass1 + 2))) >> (pass1 + 3));
    const s = limit(bits, v);
    const n: usize = size;
    for (0..n) |y| @memset(out[y * stride ..][0..n], s);
}

/// A quantization value as the reference multiplies by it: signed for
/// 8-bit samples, unsigned for 12-bit ones.
fn quant(comptime bits: u8, q: i16) i32 {
    return if (bits == 8) q else @as(u16, @bitCast(q));
}

fn sumAbs(block: *const [64]i16, q: *const [64]i16) i32 {
    const V = @Vector(8, i32);
    var sum: V = @splat(0);
    inline for (0..8) |r| {
        const c: V = @as(@Vector(8, i16), block[r * 8 ..][0..8].*);
        const m: V = @as(@Vector(8, i16), q[r * 8 ..][0..8].*);
        // |c·m| is at most 2^30, so clamping it first keeps the sum small.
        sum += @min(@abs(c * m), @as(@Vector(8, u32), @splat(1 << 14)));
    }
    return @reduce(.Add, sum);
}

/// One sample from a row-pass result `v`, already shifted down: wrapped to
/// 10 (or 14) bits around zero, then centered and clamped.
fn limit(comptime bits: u8, v: i32) Sample(bits) {
    const max = (1 << bits) - 1;
    const wrap = 4 << bits;
    const half = wrap / 2;
    const w = ((v +% half) & (wrap - 1)) - half + (1 << (bits - 1));
    return @intCast(std.math.clamp(w, 0, max));
}

fn store(comptime bits: u8, v: i32, out: []Sample(bits)) void {
    out[0] = limit(bits, v);
}

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
// The reduced sizes' odd parts: sums and differences of the cosines above.
const fix_0_211164243 = 1730;
const fix_0_509795579 = 4176;
const fix_0_601344887 = 4926;
const fix_0_720959822 = 5906;
const fix_0_850430095 = 6967;
const fix_1_061594337 = 8697;
const fix_1_272758580 = 10426;
const fix_1_451774981 = 11893;
const fix_2_172734803 = 17799;
const fix_3_624509785 = 29692;

const const_bits = 13;

/// The 1-D transform of eight inputs at the full size: `x[k]` is the k-th
/// frequency, lanes are independent. Returns the eight outputs scaled by
/// 2^13 (before rounding).
fn butterfly8(comptime V: type, x: [8]V) [8]V {
    const T = @typeInfo(V).vector.child;
    const c = struct {
        fn k(comptime v: comptime_int) V {
            return @splat(@as(T, v));
        }
    }.k;
    // Even part.
    var z2 = x[2];
    var z3 = x[6];
    var z1 = (z2 +% z3) *% c(fix_0_541196100);
    var tmp2 = z1 +% z3 *% c(-fix_1_847759065);
    var tmp3 = z1 +% z2 *% c(fix_0_765366865);
    z2 = x[0];
    z3 = x[4];
    var tmp0 = (z2 +% z3) *% c(1 << const_bits);
    var tmp1 = (z2 -% z3) *% c(1 << const_bits);
    const tmp10 = tmp0 +% tmp3;
    const tmp13 = tmp0 -% tmp3;
    const tmp11 = tmp1 +% tmp2;
    const tmp12 = tmp1 -% tmp2;
    // Odd part.
    tmp0 = x[7];
    tmp1 = x[5];
    tmp2 = x[3];
    tmp3 = x[1];
    z1 = tmp0 +% tmp3;
    z2 = tmp1 +% tmp2;
    z3 = tmp0 +% tmp2;
    var z4 = tmp1 +% tmp3;
    const z5 = (z3 +% z4) *% c(fix_1_175875602);
    tmp0 = tmp0 *% c(fix_0_298631336);
    tmp1 = tmp1 *% c(fix_2_053119869);
    tmp2 = tmp2 *% c(fix_3_072711026);
    tmp3 = tmp3 *% c(fix_1_501321110);
    z1 = z1 *% c(-fix_0_899976223);
    z2 = z2 *% c(-fix_2_562915447);
    z3 = z3 *% c(-fix_1_961570560);
    z4 = z4 *% c(-fix_0_390180644);
    z3 +%= z5;
    z4 +%= z5;
    tmp0 +%= z1 +% z3;
    tmp1 +%= z2 +% z4;
    tmp2 +%= z2 +% z3;
    tmp3 +%= z1 +% z4;
    return .{
        tmp10 +% tmp3, tmp11 +% tmp2, tmp12 +% tmp1, tmp13 +% tmp0,
        tmp13 -% tmp0, tmp12 -% tmp1, tmp11 -% tmp2, tmp10 -% tmp3,
    };
}

/// The 4-point outputs from eight inputs (input 4 unused), scaled by 2^14.
fn butterfly4(comptime V: type, x: [8]V) [4]V {
    const T = @typeInfo(V).vector.child;
    const c = struct {
        fn k(comptime v: comptime_int) V {
            return @splat(@as(T, v));
        }
    }.k;
    const tmp0 = x[0] *% c(1 << (const_bits + 1));
    const tmp2 = x[2] *% c(fix_1_847759065) +% x[6] *% c(-fix_0_765366865);
    const tmp10 = tmp0 +% tmp2;
    const tmp12 = tmp0 -% tmp2;
    const z1 = x[7];
    const z2 = x[5];
    const z3 = x[3];
    const z4 = x[1];
    const o0 = z1 *% c(-fix_0_211164243) +% z2 *% c(fix_1_451774981) +%
        z3 *% c(-fix_2_172734803) +% z4 *% c(fix_1_061594337);
    const o2 = z1 *% c(-fix_0_509795579) +% z2 *% c(-fix_0_601344887) +%
        z3 *% c(fix_0_899976223) +% z4 *% c(fix_2_562915447);
    return .{ tmp10 +% o2, tmp12 +% o0, tmp12 -% o0, tmp10 -% o2 };
}

/// The 2-point outputs from the odd inputs and the DC, scaled by 2^15.
fn butterfly2(comptime V: type, x: [8]V) [2]V {
    const T = @typeInfo(V).vector.child;
    const c = struct {
        fn k(comptime v: comptime_int) V {
            return @splat(@as(T, v));
        }
    }.k;
    const tmp10 = x[0] *% c(1 << (const_bits + 2));
    const tmp0 = x[7] *% c(-fix_0_720959822) +% x[5] *% c(fix_0_850430095) +%
        x[3] *% c(-fix_1_272758580) +% x[1] *% c(fix_3_624509785);
    return .{ tmp10 +% tmp0, tmp10 -% tmp0 };
}

/// An 8×8 transpose in three rounds of two-vector shuffles: pairs of
/// lanes, then pairs of pairs, then halves.
fn transpose(comptime V: type, m: [8]V) [8]V {
    const lo1: @Vector(8, i32) = .{ 0, ~@as(i32, 0), 1, ~@as(i32, 1), 4, ~@as(i32, 4), 5, ~@as(i32, 5) };
    const hi1: @Vector(8, i32) = .{ 2, ~@as(i32, 2), 3, ~@as(i32, 3), 6, ~@as(i32, 6), 7, ~@as(i32, 7) };
    const lo2: @Vector(8, i32) = .{ 0, 1, ~@as(i32, 0), ~@as(i32, 1), 4, 5, ~@as(i32, 4), ~@as(i32, 5) };
    const hi2: @Vector(8, i32) = .{ 2, 3, ~@as(i32, 2), ~@as(i32, 3), 6, 7, ~@as(i32, 6), ~@as(i32, 7) };
    const lo3: @Vector(8, i32) = .{ 0, 1, 2, 3, ~@as(i32, 0), ~@as(i32, 1), ~@as(i32, 2), ~@as(i32, 3) };
    const hi3: @Vector(8, i32) = .{ 4, 5, 6, 7, ~@as(i32, 4), ~@as(i32, 5), ~@as(i32, 6), ~@as(i32, 7) };
    const T = @typeInfo(V).vector.child;
    var a: [8]V = undefined;
    inline for (0..4) |i| {
        a[2 * i] = @shuffle(T, m[2 * i], m[2 * i + 1], lo1);
        a[2 * i + 1] = @shuffle(T, m[2 * i], m[2 * i + 1], hi1);
    }
    // a[0]: rows 0, 1 of columns 0, 1, 4, 5; a[1]: of columns 2, 3, 6, 7.
    var b: [8]V = undefined;
    inline for (0..2) |h| {
        inline for (0..2) |k| {
            const x = a[4 * h + k];
            const y = a[4 * h + 2 + k];
            b[4 * h + 2 * k] = @shuffle(T, x, y, lo2);
            b[4 * h + 2 * k + 1] = @shuffle(T, x, y, hi2);
        }
    }
    // b[4h + c]: rows 4h..4h+3 of columns c and c + 4.
    var t: [8]V = undefined;
    inline for (0..4) |c| {
        t[c] = @shuffle(T, b[c], b[4 + c], lo3);
        t[c + 4] = @shuffle(T, b[c], b[4 + c], hi3);
    }
    return t;
}

fn kernel(
    comptime T: type,
    comptime bits: u8,
    comptime size: u4,
    block: *const [64]i16,
    q: *const [64]i16,
    out: []Sample(bits),
    stride: usize,
) void {
    const V = @Vector(8, T);
    const pass1 = if (bits == 8) 2 else 1;
    // Extra bits each size's butterfly carries: 8 → 0, 4 → 1, 2 → 2.
    const extra = switch (size) {
        8 => 0,
        4 => 1,
        2 => 2,
        else => unreachable,
    };
    var rows: [8]V = undefined;
    inline for (0..8) |r| {
        const coef: @Vector(8, i32) = @as(@Vector(8, i16), block[r * 8 ..][0..8].*);
        const raw: @Vector(8, i16) = q[r * 8 ..][0..8].*;
        const mult: @Vector(8, i32) = if (bits == 8) raw else @as(@Vector(8, u16), @bitCast(raw));
        rows[r] = coef * mult;
    }
    // Column pass: lanes are columns, so row k of `rows` is frequency k of
    // every column. Its results are kept to 32 bits, as the reference
    // stores them.
    const shift1 = const_bits - pass1 + extra;
    const round1: V = @splat(1 << (shift1 - 1));
    var ws: [8]V = @splat(@splat(0));
    switch (size) {
        8 => {
            const o = butterfly8(V, rows);
            inline for (0..8) |k| ws[k] = keep32(V, (o[k] +% round1) >> @splat(shift1));
        },
        4 => {
            const o = butterfly4(V, rows);
            inline for (0..4) |k| ws[k] = keep32(V, (o[k] +% round1) >> @splat(shift1));
        },
        2 => {
            const o = butterfly2(V, rows);
            inline for (0..2) |k| ws[k] = keep32(V, (o[k] +% round1) >> @splat(shift1));
        },
        else => unreachable,
    }
    // Row pass: transposed, lanes are the work rows.
    const t = transpose(V, ws);
    const shift2 = const_bits + pass1 + 3 + extra;
    const round2: V = @splat(1 << (shift2 - 1));
    var cols: [8]V = undefined;
    switch (size) {
        8 => {
            const o = butterfly8(V, t);
            inline for (0..8) |k| cols[k] = (o[k] +% round2) >> @splat(shift2);
        },
        4 => {
            const o = butterfly4(V, t);
            inline for (0..4) |k| cols[k] = (o[k] +% round2) >> @splat(shift2);
            inline for (4..8) |k| cols[k] = @splat(0);
        },
        2 => {
            const o = butterfly2(V, t);
            inline for (0..2) |k| cols[k] = (o[k] +% round2) >> @splat(shift2);
            inline for (2..8) |k| cols[k] = @splat(0);
        },
        else => unreachable,
    }
    const samples = transpose(V, cols);
    const I = @Vector(8, i32);
    const max: I = @splat((1 << bits) - 1);
    const half: I = @splat(2 << bits);
    const mask: I = @splat((4 << bits) - 1);
    const center: I = @splat(1 << (bits - 1));
    inline for (0..size) |r| {
        const v: I = @truncate(samples[r]);
        const w = ((v +% half) & mask) - half + center;
        const c = @max(@min(w, max), @as(I, @splat(0)));
        // A truncate, not @intCast: Zig 0.17 marks a signed-to-unsigned
        // vector @intCast `trunc nsw`, which lets LLVM pack with signed
        // saturation, so 128-255 became 127
        // (docs/slop/results/zig017-20261104.md).
        const s: @Vector(8, Sample(bits)) = @truncate(c);
        const a: [8]Sample(bits) = s;
        @memcpy(out[r * stride ..][0..size], a[0..size]);
    }
}

/// One block for `pair`: its coefficients in natural order, quantization
/// table, and output rows.
pub const Job = struct {
    block: *const [64]i16,
    q: *const [64]i16,
    out: []u8,
    stride: usize,
};

/// Full-size 8-bit blocks on their way to `pair`, which transforms two
/// at a time: blocks that are DC only, or whose coefficients are too large
/// for 16 bits, go their own way at once, and the rest wait for a partner.
/// A held block is copied, so the caller may reuse its memory; its output
/// is written by the next `put` or by `flush`.
pub const Queue = struct {
    held: ?Job = null,
    copy: [64]i16 = undefined,

    pub fn put(qu: *Queue, j: Job) void {
        // Whether the AC coefficients are all zero, and the sum of the
        // dequantized coefficients' magnitudes, each pair's capped at
        // 2^14, past both paths' limits.
        var c: [4]Y = undefined;
        var any: Y = @splat(0);
        var sums: D = @splat(0);
        inline for (0..4) |i| {
            c[i] = j.block[i * 16 ..][0..16].*;
            const no_dc: Y = .{ 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
            any |= if (i == 0) c[0] & no_dc else c[i];
            const m: Y = j.q[i * 16 ..][0..16].*;
            const cap: @Vector(16, u16) = @splat(32767);
            const ca: Y = @intCast(@min(@abs(c[i]), cap));
            const ma: Y = @intCast(@min(@abs(m), cap));
            sums += @min(simd.maddv(ca, ma), @as(D, @splat(1 << 14)));
        }
        if (@reduce(.Or, any) == 0) return dcOnly(8, 8, j.block[0], j.q[0], j.out, j.stride);
        const sum = @reduce(.Add, sums);
        if (sum > fast_sum) {
            if (sum <= safe_sum) return kernel(i32, 8, 8, j.block, j.q, j.out, j.stride);
            return kernel(i64, 8, 8, j.block, j.q, j.out, j.stride);
        }
        if (qu.held) |h| {
            pair(h, j);
            qu.held = null;
        } else {
            qu.copy = j.block.*;
            qu.held = j;
            qu.held.?.block = &qu.copy;
        }
    }

    pub fn flush(qu: *Queue) void {
        if (qu.held) |h| pair(h, h);
        qu.held = null;
    }
};

/// Whether every coefficient but the DC is zero.
pub fn acZero(block: *const [64]i16) bool {
    const V = @Vector(16, i16);
    var any: V = @as(V, block[0..16].*) & @as(V, .{ 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 });
    inline for (1..4) |i| any |= @as(V, block[i * 16 ..][0..16].*);
    return @reduce(.Or, any) == 0;
}

// The 16-bit path. Two blocks share each vector, one in each 128-bit half
// (`Y`), so that every shuffle stays within a half, as x86's unpack and
// pack instructions do, and each product pair is one multiply-add of
// 16-bit lanes into 32 (pmaddwd). The arithmetic is `kernel`'s with the
// constants regrouped so that each output is four such pairs, which is
// exact in integers: each output's weight on each input is the sum of the
// weights the butterflies give it.
/// The full-size transforms of two 8-bit blocks whose coefficient sums
/// pass `fast_sum`.
fn pair(a: Job, b: Job) void {
    var x: [8]Y = undefined;
    // Each product is under fast_sum, so 16 bits hold it.
    inline for (0..8) |r| {
        const H = @Vector(8, i16);
        const c = std.simd.join(@as(H, a.block[r * 8 ..][0..8].*), @as(H, b.block[r * 8 ..][0..8].*));
        const m = std.simd.join(@as(H, a.q[r * 8 ..][0..8].*), @as(H, b.q[r * 8 ..][0..8].*));
        x[r] = c *% m;
    }
    // Column pass, lanes as columns, rounded and descaled by 2^11.
    var ws: [8]Y = undefined;
    {
        const lo = pass16(x, unpack(.lo16), 1 << 10);
        const hi = pass16(x, unpack(.hi16), 1 << 10);
        inline for (0..8) |k| ws[k] = pack(lo[k] >> @splat(11), hi[k] >> @splat(11));
    }
    // Row pass, lanes as rows, rounded and descaled by 2^18 with 512 added
    // (2^18 · 512 before the shift), so that wrapping to 10 bits around the
    // center, as `kernel` does, is a mask.
    const t = transpose16(ws);
    const round = (1 << 17) + (512 << 18);
    const lo = pass16(t, unpack(.lo16), round);
    const hi = pass16(t, unpack(.hi16), round);
    var cols: [8]Y = undefined;
    inline for (0..8) |k| {
        const v = pack(lo[k] >> @splat(18), hi[k] >> @splat(18));
        const w = (v & @as(Y, @splat(1023))) - @as(Y, @splat(512 - 128));
        cols[k] = @max(@min(w, @as(Y, @splat(255))), @as(Y, @splat(0)));
    }
    const rows = transpose16(cols);
    inline for (0..8) |r| {
        // A truncate, not @intCast, as in `kernel`.
        const s: @Vector(16, u8) = @truncate(@as(@Vector(16, u16), @bitCast(rows[r])));
        const half: [2][8]u8 = @bitCast(s);
        a.out[r * a.stride ..][0..8].* = half[0];
        b.out[r * b.stride ..][0..8].* = half[1];
    }
}

/// One pass of `pair` over half of each row's lanes, the half `mask`
/// picks: the eight outputs of the 1-D transform of the eight inputs `x`,
/// scaled by 2^13, plus `round`.
fn pass16(x: [8]Y, comptime mask: @Vector(16, i32), comptime round: i32) [8]D {
    const p04 = @shuffle(i16, x[0], x[4], mask);
    const p26 = @shuffle(i16, x[2], x[6], mask);
    const p75 = @shuffle(i16, x[7], x[5], mask);
    const p31 = @shuffle(i16, x[3], x[1], mask);
    // Even part: tmp0 and tmp1 are (x0 ± x4)·2^13; tmp2 and tmp3 take the
    // rotation z1 = (x2 + x6)·c(0.541) into each weight.
    const tmp0 = madd(p04, 1 << const_bits, 1 << const_bits) +% @as(D, @splat(round));
    const tmp1 = madd(p04, 1 << const_bits, -(1 << const_bits)) +% @as(D, @splat(round));
    const tmp2 = madd(p26, fix_0_541196100, fix_0_541196100 - fix_1_847759065);
    const tmp3 = madd(p26, fix_0_541196100 + fix_0_765366865, fix_0_541196100);
    const tmp10 = tmp0 +% tmp3;
    const tmp13 = tmp0 -% tmp3;
    const tmp11 = tmp1 +% tmp2;
    const tmp12 = tmp1 -% tmp2;
    // Odd part, inputs t0..t3 = x7, x5, x3, x1: each output's weight on
    // each input gathers its own constant, the z1..z4 rotations it takes
    // part in, and z5 = (t0 + t1 + t2 + t3)·c(1.176).
    const c5 = fix_1_175875602;
    const o0 = madd(p75, fix_0_298631336 - fix_0_899976223 - fix_1_961570560 + c5, c5) +%
        madd(p31, c5 - fix_1_961570560, c5 - fix_0_899976223);
    const o1 = madd(p75, c5, fix_2_053119869 - fix_2_562915447 - fix_0_390180644 + c5) +%
        madd(p31, c5 - fix_2_562915447, c5 - fix_0_390180644);
    const o2 = madd(p75, c5 - fix_1_961570560, c5 - fix_2_562915447) +%
        madd(p31, fix_3_072711026 - fix_2_562915447 - fix_1_961570560 + c5, c5);
    const o3 = madd(p75, c5 - fix_0_899976223, c5 - fix_0_390180644) +%
        madd(p31, c5, fix_1_501321110 - fix_0_899976223 - fix_0_390180644 + c5);
    return .{
        tmp10 +% o3, tmp11 +% o2, tmp12 +% o1, tmp13 +% o0,
        tmp13 -% o0, tmp12 -% o1, tmp11 -% o2, tmp10 -% o3,
    };
}

/// Each half's 8×8 transpose, in three rounds of unpacks.
fn transpose16(m: [8]Y) [8]Y {
    var a: [8]Y = undefined;
    inline for (0..4) |i| {
        a[2 * i] = @shuffle(i16, m[2 * i], m[2 * i + 1], unpack(.lo16));
        a[2 * i + 1] = @shuffle(i16, m[2 * i], m[2 * i + 1], unpack(.hi16));
    }
    // a[2i]: rows 2i and 2i + 1 of columns 0-3, interleaved; a[2i + 1]:
    // of columns 4-7.
    var b: [8]Y = undefined;
    inline for (0..2) |h| {
        inline for (0..2) |k| {
            const x = a[4 * h + k];
            const y = a[4 * h + 2 + k];
            b[4 * h + 2 * k] = @shuffle(i16, x, y, unpack(.lo32));
            b[4 * h + 2 * k + 1] = @shuffle(i16, x, y, unpack(.hi32));
        }
    }
    // b[4h + j]: rows 4h..4h + 3 of columns 2j and 2j + 1.
    var t: [8]Y = undefined;
    inline for (0..4) |j| {
        t[2 * j] = @shuffle(i16, b[j], b[4 + j], unpack(.lo64));
        t[2 * j + 1] = @shuffle(i16, b[j], b[4 + j], unpack(.hi64));
    }
    return t;
}

fn keep32(comptime V: type, v: V) V {
    if (@typeInfo(V).vector.child == i32) return v;
    const w: @Vector(8, i32) = @truncate(v);
    return w;
}

/// The reference arithmetic, one value at a time in 64 bits as its C
/// does, for the tests.
const reference = struct {
    fn run(comptime bits: u8, comptime size: u4, block: *const [64]i16, q: *const [64]i16, out: []Sample(bits)) void {
        if (size == 1) {
            const dc: i64 = @as(i32, block[0]) * quant(bits, q[0]);
            out[0] = limit(bits, @truncate((dc + 4) >> 3));
            return;
        }
        const V = @Vector(1, i64);
        const pass1 = if (bits == 8) 2 else 1;
        const extra = switch (size) {
            8 => 0,
            4 => 1,
            else => 2,
        };
        var ws: [8][8]i32 = @splat(@splat(0));
        for (0..8) |col| {
            var x: [8]V = undefined;
            for (0..8) |r| x[r] = @splat(@as(i32, block[r * 8 + col]) * quant(bits, q[r * 8 + col]));
            const shift = const_bits - pass1 + extra;
            switch (size) {
                8 => for (butterfly8(V, x), 0..) |o, r| {
                    ws[r][col] = @truncate((o[0] + (1 << (shift - 1))) >> shift);
                },
                4 => for (butterfly4(V, x), 0..) |o, r| {
                    ws[r][col] = @truncate((o[0] + (1 << (shift - 1))) >> shift);
                },
                else => for (butterfly2(V, x), 0..) |o, r| {
                    ws[r][col] = @truncate((o[0] + (1 << (shift - 1))) >> shift);
                },
            }
        }
        for (0..size) |r| {
            var x: [8]V = undefined;
            for (0..8) |k| x[k] = @splat(ws[r][k]);
            const shift = const_bits + pass1 + 3 + extra;
            switch (size) {
                8 => for (butterfly8(V, x), 0..) |o, c| {
                    out[r * size + c] = limit(bits, @truncate((o[0] + (1 << (shift - 1))) >> shift));
                },
                4 => for (butterfly4(V, x), 0..) |o, c| {
                    out[r * size + c] = limit(bits, @truncate((o[0] + (1 << (shift - 1))) >> shift));
                },
                else => for (butterfly2(V, x), 0..) |o, c| {
                    out[r * size + c] = limit(bits, @truncate((o[0] + (1 << (shift - 1))) >> shift));
                },
            }
        }
    }
};

test "the 32-bit path matches the 64-bit arithmetic" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    inline for (.{ 8, 12 }) |bits| {
        inline for (.{ 8, 4, 2, 1 }) |size| {
            for (0..3000) |i| {
                var block: [64]i16 = @splat(0);
                var q: [64]i16 = undefined;
                for (&q) |*v| v.* = random.intRangeAtMost(i16, 1, 40);
                const kind = i % 4;
                for (&block, 0..) |*v, k| {
                    v.* = switch (kind) {
                        // Sparse low frequencies, as photographs have.
                        0 => if (k < 20 and random.boolean()) random.intRangeAtMost(i16, -60, 60) else 0,
                        // Large sums near the 32-bit path's limit, or
                        // the 16-bit path's.
                        1 => random.intRangeAtMost(i16, -12, 12) >> @intCast(i % 3),
                        // Anything, as corrupt data has.
                        2 => random.int(i16),
                        else => if (random.uintLessThan(u8, 8) == 0) random.int(i16) else 0,
                    };
                }
                if (kind == 2) for (&q) |*v| {
                    v.* = random.int(i16);
                };
                var got: [64]Sample(bits) = undefined;
                var want: [64]Sample(bits) = undefined;
                idct(bits, size, &block, &q, &got, size);
                reference.run(bits, size, &block, &q, &want);
                const n = @as(usize, size) * size;
                try testing.expectEqualSlices(Sample(bits), want[0..n], got[0..n]);
            }
        }
    }
}

test "the queue pairs blocks without mixing them up" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const n = 7;
    var blocks: [n][64]i16 = undefined;
    var qs: [n][64]i16 = undefined;
    var got: [n * 64]u8 = undefined;
    var want: [n * 64]u8 = undefined;
    for (0..300) |round| {
        for (&blocks, &qs, 0..) |*b, *q, i| {
            for (q) |*v| v.* = random.intRangeAtMost(i16, 1, 60);
            b.* = @splat(0);
            // A mix of the queue's routes: DC only, small enough to
            // pair, and too large for 16 bits or for 32.
            const kind = (round + i) % 4;
            for (b, 0..) |*v, k| v.* = switch (kind) {
                0 => if (k == 0) random.intRangeAtMost(i16, -100, 100) else 0,
                1 => if (k < 24 and random.boolean()) random.intRangeAtMost(i16, -20, 20) else 0,
                2 => random.intRangeAtMost(i16, -8, 8),
                else => random.intRangeAtMost(i16, -40, 40),
            };
        }
        var qu: Queue = .{};
        for (&blocks, &qs, 0..) |*b, *q, i| {
            // The caller may reuse a block's memory once it is queued.
            var scratch = b.*;
            qu.put(.{ .block = &scratch, .q = q, .out = got[i * 64 ..], .stride = 8 });
            scratch = @splat(0x7fff);
        }
        qu.flush();
        for (&blocks, &qs, 0..) |*b, *q, i| reference.run(8, 8, b, q, want[i * 64 ..][0..64]);
        try testing.expectEqualSlices(u8, &want, &got);
    }
}

test "a DC-only block is flat" {
    var block: [64]i16 = @splat(0);
    var q: [64]i16 = @splat(16);
    for ([_]i16{ 0, 5, -5, 64, -64, 100, -100, 32767, -32768 }) |dc| {
        for ([_]i16{ 1, 16, 255, -1, 32767 }) |q0| {
            block[0] = dc;
            q[0] = q0;
            inline for (.{ 8, 12 }) |bits| {
                inline for (.{ 8, 4, 2, 1 }) |size| {
                    var want: [64]Sample(bits) = undefined;
                    var got: [64]Sample(bits) = undefined;
                    idct(bits, size, &block, &q, &want, size);
                    dcOnly(bits, size, dc, q0, &got, size);
                    const n = @as(usize, size) * size;
                    try testing.expectEqualSlices(Sample(bits), want[0..n], got[0..n]);
                }
            }
        }
    }
}

test "known values" {
    // A flat block of DC 80 at quantizer 8 is 128 + 80·8/8 = 208.
    var block: [64]i16 = @splat(0);
    const q: [64]i16 = @splat(8);
    block[0] = 80;
    var out: [64]u8 = undefined;
    idct(8, 8, &block, &q, &out, 8);
    for (out) |s| try testing.expectEqual(208, s);
    // Out of range values wrap at ±512 before clamping.
    block[0] = 600 * 8 / 8;
    idct(8, 1, &block, &q, &out, 1);
    try testing.expectEqual(0, out[0]);
    block[0] = 300;
    idct(8, 1, &block, &q, &out, 1);
    try testing.expectEqual(255, out[0]);
}
