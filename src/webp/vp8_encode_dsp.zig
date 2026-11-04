//! The VP8 encoder's arithmetic on blocks: the forward DCT and WHT, the
//! inverse transforms and intra prediction a decoder runs (RFC 6386
//! sections 12 and 14), quantization, and distortion.
//!
//! The inverse transforms and the predictors are the decoder's
//! (`vp8.zig`), copied so the encoder reconstructs exactly what a decoder
//! will, and predicts the next block from it. The forward transforms are
//! the inverses' transposes, in fixed point: the inverse DCT is half an
//! orthonormal 4x4 DCT, so the forward one is twice it, and the inverse WHT
//! divides by 8 what the forward one multiplies by 2.

const std = @import("std");
const testing = std.testing;
const tables = @import("vp8_encode_tables.zig");
const zigzag = tables.zigzag;

/// The forward DCT of a 4x4 residual in raster order: coefficient
/// (u, v) at `u * 4 + v`, vertical frequency first, twice the orthonormal
/// transform, so a decoder's inverse gives back the residual. Four rows or
/// columns at a time.
pub fn fdct(in: *const [16]i16, out: *[16]i16) void {
    const V = @Vector(4, i32);
    // cos(pi/8) * sqrt(2) and sin(pi/8) * sqrt(2), times 2^12.
    const k1: V = @splat(5352);
    const k2: V = @splat(2217);
    const all: @Vector(16, i32) = @as(@Vector(16, i16), in.*);
    // The columns, so the first pass runs along every row at once.
    const x: [4]V = @bitCast(@shuffle(i32, all, undefined, transpose_mask));
    const a = x[0] + x[3];
    const b = x[1] + x[2];
    const c = x[1] - x[2];
    const d = x[0] - x[3];
    // Eight times the pass's output, for precision; t[k] is column k.
    const t: [4]V = .{
        (a + b) << @splat(3),
        (d * k1 + c * k2 + @as(V, @splat(256))) >> @splat(9),
        (a - b) << @splat(3),
        (d * k2 - c * k1 + @as(V, @splat(256))) >> @splat(9),
    };
    // Its rows, so the second pass runs down every column at once.
    const y: [4]V = @bitCast(@shuffle(i32, @as(@Vector(16, i32), @bitCast(t)), undefined, transpose_mask));
    const a2 = y[0] + y[3];
    const b2 = y[1] + y[2];
    const c2 = y[1] - y[2];
    const d2 = y[0] - y[3];
    const o: [4]V = .{
        (a2 + b2 + @as(V, @splat(8))) >> @splat(4),
        (d2 * k1 + c2 * k2 + @as(V, @splat(32768))) >> @splat(16),
        (a2 - b2 + @as(V, @splat(8))) >> @splat(4),
        (d2 * k2 - c2 * k1 + @as(V, @splat(32768))) >> @splat(16),
    };
    out.* = @as(@Vector(16, i16), @intCast(@as(@Vector(16, i32), @bitCast(o))));
}

const transpose_mask = [16]i32{ 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15 };

/// The forward WHT of a macroblock's 16 luma DC coefficients, in raster
/// order of their blocks, into the Y2 block (section 14.3 inverted).
pub fn fwht(in: *const [16]i32, out: *[16]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const s01 = in[i * 4 + 0] + in[i * 4 + 1];
        const s23 = in[i * 4 + 2] + in[i * 4 + 3];
        const t01 = in[i * 4 + 0] - in[i * 4 + 1];
        const t23 = in[i * 4 + 2] - in[i * 4 + 3];
        tmp[i * 4 + 0] = s01 + s23;
        tmp[i * 4 + 1] = s01 - s23;
        tmp[i * 4 + 2] = t01 - t23;
        tmp[i * 4 + 3] = t01 + t23;
    }
    for (0..4) |k| {
        const s01 = tmp[k] + tmp[4 + k];
        const s23 = tmp[8 + k] + tmp[12 + k];
        const t01 = tmp[k] - tmp[4 + k];
        const t23 = tmp[8 + k] - tmp[12 + k];
        out[k] = @intCast((s01 + s23 + 1) >> 1);
        out[4 + k] = @intCast((s01 - s23 + 1) >> 1);
        out[8 + k] = @intCast((t01 - t23 + 1) >> 1);
        out[12 + k] = @intCast((t01 + t23 + 1) >> 1);
    }
}

/// The inverse WHT (section 14.3), in 32 bits as libwebp computes it, into
/// the DC of each luma block (`vp8.zig`'s).
pub fn inverseWht(in: *const [16]i16, out: *[16][16]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[0 + i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[0 + i]) - in[12 + i];
        tmp[0 + i] = a0 + a1;
        tmp[8 + i] = a0 - a1;
        tmp[4 + i] = a3 + a2;
        tmp[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = tmp[0 + i * 4] + 3;
        const a0 = dc + tmp[3 + i * 4];
        const a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
        const a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
        const a3 = dc - tmp[3 + i * 4];
        out[i * 4 + 0][0] = @truncate((a0 + a1) >> 3);
        out[i * 4 + 1][0] = @truncate((a3 + a2) >> 3);
        out[i * 4 + 2][0] = @truncate((a0 - a1) >> 3);
        out[i * 4 + 3][0] = @truncate((a3 - a2) >> 3);
    }
}

fn clamp255(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// The inverse DCT of section 14.4 added to `dst`, every intermediate
/// wrapped to 16 bits (`vp8.zig`'s).
pub fn idctFull(in: *const [16]i16, dst: []u8, stride: usize) void {
    const V = @Vector(4, i16);
    const k1: i16 = 20091;
    const k2: i16 = -30068; // 35468 - 65536
    const rows: [4]V = @bitCast(in.*);
    const t = transpose4(pass(rows[0], rows[1], rows[2], rows[3], k1, k2));
    const o = transpose4(pass(t[0] +% @as(V, @splat(4)), t[1], t[2], t[3], k1, k2));
    for (0..4) |r| {
        const row = dst[r * stride ..][0..4];
        const px: @Vector(4, i16) = row.*;
        const sum = px + (o[r] >> @splat(3));
        row.* = @as(@Vector(4, u8), @intCast(@min(@max(sum, @as(V, @splat(0))), @as(V, @splat(255)))));
    }
}

inline fn pass(
    x0: @Vector(4, i16),
    x1: @Vector(4, i16),
    x2: @Vector(4, i16),
    x3: @Vector(4, i16),
    k1: i16,
    k2: i16,
) [4]@Vector(4, i16) {
    const a = x0 +% x2;
    const b = x0 -% x2;
    const c = (mulhiV(x1, k2) -% mulhiV(x3, k1)) +% (x1 -% x3);
    const d = (mulhiV(x1, k1) +% mulhiV(x3, k2)) +% (x1 +% x3);
    return .{ a +% d, b +% c, b -% c, a -% d };
}

inline fn mulhiV(x: @Vector(4, i16), k: i16) @Vector(4, i16) {
    const W = @Vector(4, i32);
    return @truncate((@as(W, x) * @as(W, @splat(k))) >> @splat(16));
}

inline fn transpose4(m: [4]@Vector(4, i16)) [4]@Vector(4, i16) {
    const all: @Vector(16, i16) = @bitCast(m);
    const t = @shuffle(i16, all, undefined, [16]i32{ 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15 });
    return @bitCast(t);
}

fn mul1(a: i32) i32 {
    return ((a * 20091) >> 16) + a;
}

fn mul2(a: i32) i32 {
    return (a * 35468) >> 16;
}

inline fn addRow(row: *[4]u8, v: @Vector(4, i32)) void {
    const W = @Vector(4, i32);
    const px: @Vector(4, u8) = row.*;
    const sum = @as(W, px) + v;
    row.* = @as(@Vector(4, u8), @intCast(@min(@max(sum, @as(W, @splat(0))), @as(W, @splat(255)))));
}

/// The inverse DCT of a block whose only coefficients are 0, 1, and 4, in
/// 32 bits (`vp8.zig`'s).
pub fn idctAc3(in: *const [16]i16, dst: []u8, stride: usize) void {
    const W = @Vector(4, i32);
    const a: i32 = @as(i32, in[0]) + 4;
    const c4 = mul2(in[4]);
    const d4 = mul1(in[4]);
    const c1 = mul2(in[1]);
    const d1 = mul1(in[1]);
    const cd: W = .{ d1, c1, -c1, -d1 };
    const vert = [4]i32{ d4, c4, -c4, -d4 };
    for (0..4) |r| addRow(dst[r * stride ..][0..4], (@as(W, @splat(a + vert[r])) + cd) >> @splat(3));
}

/// The inverse DCT of a block with only a DC coefficient, in 32 bits.
pub fn idctDc(in: *const [16]i16, dst: []u8, stride: usize) void {
    const dc: @Vector(4, i32) = @splat((@as(i32, in[0]) + 4) >> 3);
    for (0..4) |r| addRow(dst[r * stride ..][0..4], dc);
}

/// Adds a block's inverse transform to `dst`, choosing the transform as a
/// decoder does from the position after its last token (`end`) and its
/// DC: the full one past the third position, the three-coefficient one
/// within it, the DC one for a DC alone.
pub fn inverse(end: i32, in: *const [16]i16, dst: []u8, stride: usize) void {
    if (end > 3) {
        idctFull(in, dst, stride);
    } else if (end > 1) {
        idctAc3(in, dst, stride);
    } else if (in[0] != 0) {
        idctDc(in, dst, stride);
    }
}

// Prediction modes, numbered as in the decoder: the 16x16 and chroma
// modes, and the subblock modes in the order of section 11.2.
pub const dc_pred = 0;
pub const v_pred = 1;
pub const h_pred = 2;
pub const tm_pred = 3;
pub const b_dc = 0;
pub const b_tm = 1;
pub const b_ve = 2;
pub const b_he = 3;
pub const b_ld = 4;
pub const b_rd = 5;
pub const b_vr = 6;
pub const b_vl = 7;
pub const b_hd = 8;
pub const b_hu = 9;

// The reconstruction scratch for one macroblock, laid out as the
// decoder's: rows -1 to 15 and columns -1 to 19 of luma, and rows -1 to 7
// and columns -1 to 7 of each chroma plane.
pub const ys = 32;
pub const y0 = ys + 8;
pub const cs = 16;
pub const c0 = cs + 8;

pub fn avg2(x: u8, y: u8) u8 {
    return @intCast((@as(u16, x) + y + 1) >> 1);
}

pub fn avg3(x: u8, y: u8, z: u8) u8 {
    return @intCast((@as(u16, x) + 2 * @as(u16, y) + z + 2) >> 2);
}

/// A 16x16 or 8x8 block's prediction (sections 12.2, 12.3), from the
/// neighbors of the block at `at` in `buf` (stride `s`), into `out`, `n`
/// wide. DC prediction averages only the edges inside the frame.
pub fn predictBlock(
    comptime n: usize,
    buf: []const u8,
    at: usize,
    s: usize,
    mode: u8,
    has_top: bool,
    has_left: bool,
    out: *[n * n]u8,
) void {
    const shift = std.math.log2_int(usize, n);
    switch (mode) {
        dc_pred => {
            var sum: u32 = 0;
            var v: u8 = 128;
            if (has_top and has_left) {
                for (0..n) |i| sum += @as(u32, buf[at - s + i]) + buf[at + i * s - 1];
                v = @intCast((sum + n) >> (shift + 1));
            } else if (has_top) {
                for (0..n) |i| sum += buf[at - s + i];
                v = @intCast((sum + n / 2) >> shift);
            } else if (has_left) {
                for (0..n) |i| sum += buf[at + i * s - 1];
                v = @intCast((sum + n / 2) >> shift);
            }
            @memset(out, v);
        },
        v_pred => for (0..n) |r| @memcpy(out[r * n ..][0..n], buf[at - s ..][0..n]),
        h_pred => for (0..n) |r| @memset(out[r * n ..][0..n], buf[at + r * s - 1]),
        else => {
            const p: i32 = buf[at - s - 1];
            for (0..n) |r| {
                const l: i32 = @as(i32, buf[at + r * s - 1]) - p;
                for (0..n) |c| out[r * n + c] = clamp255(l + buf[at - s + c]);
            }
        },
    }
}

/// A 4x4 subblock's prediction (section 12.3) from the neighbors of the
/// subblock at `at` in the luma scratch, into `out` (`vp8.zig`'s).
pub fn predictSub(buf: *const [ys * 17]u8, at: usize, mode: u8, out: *[16]u8) void {
    const s = ys;
    var a: [9]u8 = undefined;
    @memcpy(&a, buf[at - s - 1 ..][0..9]);
    const p = a[0];
    const above = a[1..9];
    const left = [4]u8{ buf[at - 1], buf[at + s - 1], buf[at + 2 * s - 1], buf[at + 3 * s - 1] };
    const edge = [9]u8{ left[3], left[2], left[1], left[0], p, above[0], above[1], above[2], above[3] };
    var B: [4][4]u8 = undefined;
    switch (mode) {
        b_dc => {
            var v: u32 = 4;
            for (0..4) |i| v += @as(u32, above[i]) + left[i];
            B = @splat(@splat(@intCast(v >> 3)));
        },
        b_tm => for (0..4) |r| for (0..4) |c| {
            B[r][c] = clamp255(@as(i32, left[r]) + above[c] - p);
        },
        b_ve => for (0..4) |c| {
            const v = avg3(if (c == 0) p else above[c - 1], above[c], above[c + 1]);
            for (0..4) |r| B[r][c] = v;
        },
        b_he => {
            B[0] = @splat(avg3(p, left[0], left[1]));
            B[1] = @splat(avg3(left[0], left[1], left[2]));
            B[2] = @splat(avg3(left[1], left[2], left[3]));
            B[3] = @splat(avg3(left[2], left[3], left[3]));
        },
        b_ld => for (0..4) |r| for (0..4) |c| {
            const i = r + c;
            B[r][c] = if (i == 6) avg3(above[6], above[7], above[7]) else avg3(above[i], above[i + 1], above[i + 2]);
        },
        b_rd => for (0..4) |r| for (0..4) |c| {
            const i = 4 + c - r;
            B[r][c] = avg3(edge[i - 1], edge[i], edge[i + 1]);
        },
        b_vr => {
            B[3][0] = avg3(edge[1], edge[2], edge[3]);
            B[2][0] = avg3(edge[2], edge[3], edge[4]);
            B[3][1] = avg3(edge[3], edge[4], edge[5]);
            B[1][0] = B[3][1];
            B[2][1] = avg2(edge[4], edge[5]);
            B[0][0] = B[2][1];
            B[3][2] = avg3(edge[4], edge[5], edge[6]);
            B[1][1] = B[3][2];
            B[2][2] = avg2(edge[5], edge[6]);
            B[0][1] = B[2][2];
            B[3][3] = avg3(edge[5], edge[6], edge[7]);
            B[1][2] = B[3][3];
            B[2][3] = avg2(edge[6], edge[7]);
            B[0][2] = B[2][3];
            B[1][3] = avg3(edge[6], edge[7], edge[8]);
            B[0][3] = avg2(edge[7], edge[8]);
        },
        b_vl => {
            B[0][0] = avg2(above[0], above[1]);
            B[1][0] = avg3(above[0], above[1], above[2]);
            B[2][0] = avg2(above[1], above[2]);
            B[0][1] = B[2][0];
            B[1][1] = avg3(above[1], above[2], above[3]);
            B[3][0] = B[1][1];
            B[2][1] = avg2(above[2], above[3]);
            B[0][2] = B[2][1];
            B[3][1] = avg3(above[2], above[3], above[4]);
            B[1][2] = B[3][1];
            B[2][2] = avg2(above[3], above[4]);
            B[0][3] = B[2][2];
            B[3][2] = avg3(above[3], above[4], above[5]);
            B[1][3] = B[3][2];
            B[2][3] = avg3(above[4], above[5], above[6]);
            B[3][3] = avg3(above[5], above[6], above[7]);
        },
        b_hd => {
            B[3][0] = avg2(edge[0], edge[1]);
            B[3][1] = avg3(edge[0], edge[1], edge[2]);
            B[2][0] = avg2(edge[1], edge[2]);
            B[3][2] = B[2][0];
            B[2][1] = avg3(edge[1], edge[2], edge[3]);
            B[3][3] = B[2][1];
            B[2][2] = avg2(edge[2], edge[3]);
            B[1][0] = B[2][2];
            B[2][3] = avg3(edge[2], edge[3], edge[4]);
            B[1][1] = B[2][3];
            B[1][2] = avg2(edge[3], edge[4]);
            B[0][0] = B[1][2];
            B[1][3] = avg3(edge[3], edge[4], edge[5]);
            B[0][1] = B[1][3];
            B[0][2] = avg3(edge[4], edge[5], edge[6]);
            B[0][3] = avg3(edge[5], edge[6], edge[7]);
        },
        else => { // b_hu
            B[0][0] = avg2(left[0], left[1]);
            B[0][1] = avg3(left[0], left[1], left[2]);
            B[0][2] = avg2(left[1], left[2]);
            B[1][0] = B[0][2];
            B[0][3] = avg3(left[1], left[2], left[3]);
            B[1][1] = B[0][3];
            B[1][2] = avg2(left[2], left[3]);
            B[2][0] = B[1][2];
            B[1][3] = avg3(left[2], left[3], left[3]);
            B[2][1] = B[1][3];
            B[2][2] = left[3];
            B[2][3] = left[3];
            B[3] = @splat(left[3]);
        },
    }
    out.* = @bitCast(B);
}

/// The quantizer of one block type, by coding position: the step a
/// decoder multiplies by (the DC step at position 0, the AC step after),
/// and the encoder's reciprocal and rounding bias.
pub const Quant = struct {
    q: U16x,
    /// ceil(2^17 / q).
    iq: U16x,
    /// Added to a magnitude before dividing: the step times the rounding
    /// in 1/128.
    bias: U16x,

    /// Steps `dc` and `ac`, rounding magnitudes up from `rdc` and `rac`
    /// 128ths of a step.
    pub fn init(dc: u32, ac: u32, rdc: u32, rac: u32) Quant {
        var m: Quant = .{
            .q = @splat(ac),
            .iq = @splat(((1 << 17) + ac - 1) / ac),
            .bias = @splat((ac * rac) >> 7),
        };
        m.q[0] = dc;
        m.iq[0] = ((1 << 17) + dc - 1) / dc;
        m.bias[0] = (dc * rdc) >> 7;
        return m;
    }
};

const U16x = @Vector(16, u32);
const I16x = @Vector(16, i32);

/// The inverse of `zigzag`: the coding position of each raster position.
pub const unzigzag = blk: {
    var t: [16]i32 = undefined;
    for (zigzag, 0..) |j, n| t[j] = n;
    break :blk t;
};
pub const zigzag_mask = blk: {
    var t: [16]i32 = undefined;
    for (zigzag, 0..) |j, n| t[n] = j;
    break :blk t;
};

/// Quantizes a block's coefficients (raster order) from position `first`
/// with `m`: `levels` in coding order, and `deq` the dequantized
/// coefficients in raster order, which a decoder reconstructs. Returns the
/// last nonzero position, or -1.
pub fn quantize(coefs: *const [16]i16, m: *const Quant, first: u5, levels: *[16]i16, deq: *[16]i16) i32 {
    const c: I16x = @as(@Vector(16, i16), coefs.*);
    const z = @shuffle(i32, c, undefined, zigzag_mask);
    var l: U16x = @min(((@abs(z) + m.bias) * m.iq) >> @splat(17), @as(U16x, @splat(tables.max_level)));
    if (first == 1) l[0] = 0;
    const li: I16x = @intCast(l);
    const v = @select(i32, z < @as(I16x, @splat(0)), -li, li);
    levels.* = @as(@Vector(16, i16), @intCast(v));
    const dz = v * @as(I16x, @intCast(m.q));
    deq.* = @as(@Vector(16, i16), @intCast(@shuffle(i32, dz, undefined, unzigzag)));
    // A bool vector's lane 0 is the integer's low bit.
    const nz: u16 = @bitCast(l != @as(U16x, @splat(0)));
    return @as(i32, 15) - @clz(nz);
}

/// The sum of absolute values of the 4x4 Hadamard transform of `a - b`
/// (both packed 4 wide): a cheap estimate of what coding the difference
/// costs.
pub fn satd4(a: *const [16]u8, b: *const [16]u8) u32 {
    const V = @Vector(16, i16);
    // Four butterfly stages across the 16 lanes: rows 0 and 1 and rows 2
    // and 3, then the sums and differences two rows apart, then the same
    // for columns. Values stay within 16 * 255.
    // The last is folded into the sum, as in `satdStrip`.
    var d: V = @as(V, @as(@Vector(16, u8), a.*)) - @as(V, @as(@Vector(16, u8), b.*));
    d = d * sign(16, .{ 1, -1, 1, -1 }, 4) + @shuffle(i16, d, undefined, swapMask(16, 4));
    d = d * sign(16, .{ 1, 1, -1, -1 }, 4) + @shuffle(i16, d, undefined, swapMask(16, 8));
    d = d * sign(16, .{ 1, -1, 1, -1 }, 1) + @shuffle(i16, d, undefined, swapMask(16, 1));
    const h = @abs(d);
    return @reduce(.Add, @as(@Vector(16, u32), @max(h, @shuffle(u16, h, undefined, swapMask(16, 2)))));
}

/// `satd4` summed over the 4x4 blocks of a strip four rows high and `w`
/// wide (8 or 16), both packed `w` wide.
pub fn satdStrip(comptime w: usize, a: *const [4 * w]u8, b: *const [4 * w]u8) u32 {
    const V = @Vector(w, i16);
    var r: [4]V = undefined;
    for (&r, 0..) |*x, i| {
        x.* = @as(V, @as(@Vector(w, u8), a[i * w ..][0..w].*)) - @as(V, @as(@Vector(w, u8), b[i * w ..][0..w].*));
    }
    // Down the columns, a row to a vector, then across each block's
    // columns. The last stage is folded into the sum, since
    // |x + y| + |x - y| = 2 max(|x|, |y|): each pair's maximum lands in
    // both its lanes. Values stay within 16 * 255.
    const s01 = r[0] + r[1];
    const d01 = r[0] - r[1];
    const s23 = r[2] + r[3];
    const d23 = r[2] - r[3];
    const low = comptime blk: {
        var m: [w]bool = undefined;
        for (&m, 0..) |*x, i| x.* = i & 1 == 0;
        break :blk m;
    };
    var sum: @Vector(w, u16) = @splat(0);
    for ([4]V{ s01 + s23, s01 - s23, d01 - d23, d01 + d23 }) |x| {
        const y = @shuffle(i16, x, undefined, swapMask(w, 1));
        const h = @abs(@select(i16, low, x + y, y - x));
        sum += @max(h, @shuffle(u16, h, undefined, swapMask(w, 2)));
    }
    return @reduce(.Add, @as(@Vector(w, u32), sum));
}

/// Lane `i` of a butterfly's sign: `s[(i / stride) % 4]`.
fn sign(comptime n: usize, comptime s: [4]i16, comptime stride: usize) @Vector(n, i16) {
    var v: [n]i16 = undefined;
    for (&v, 0..) |*x, i| x.* = s[(i / stride) % 4];
    return v;
}

/// Each lane's partner `k` lanes away in its group of `2k`.
fn swapMask(comptime n: usize, comptime k: usize) [n]i32 {
    var m: [n]i32 = undefined;
    for (&m, 0..) |*x, i| x.* = @intCast(i ^ k);
    return m;
}

/// The sum of squared differences of two `n`-wide blocks, `a` with stride
/// `sa` and `b` packed.
pub fn sse(comptime w: usize, comptime h: usize, a: []const u8, sa: usize, b: []const u8) u32 {
    var sum: u32 = 0;
    for (0..h) |r| {
        const x: @Vector(w, u8) = a[r * sa ..][0..w].*;
        const y: @Vector(w, u8) = b[r * w ..][0..w].*;
        const d = @as(@Vector(w, i32), x) - @as(@Vector(w, i32), y);
        sum += @intCast(@reduce(.Add, d * d));
    }
    return sum;
}

test "the forward transforms invert" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    for (0..2000) |_| {
        var res: [16]i16 = undefined;
        const range: i16 = if (r.boolean()) 127 else 20;
        for (&res) |*v| v.* = r.intRangeAtMost(i16, -range, range);
        var coefs: [16]i16 = undefined;
        fdct(&res, &coefs);
        // Unquantized, the inverse gives back the residual, added to a
        // mid-gray prediction, within a step of rounding.
        var out: [16]u8 = @splat(128);
        idctFull(&coefs, &out, 4);
        for (out, res) |o, v| try testing.expect(@abs(@as(i32, o) - (128 + v)) <= 1);
    }
    for (0..500) |_| {
        var dcs: [16]i32 = undefined;
        for (&dcs) |*d| d.* = r.intRangeAtMost(i32, -2040, 2040);
        var y2: [16]i16 = undefined;
        fwht(&dcs, &y2);
        var blocks: [16][16]i16 = undefined;
        inverseWht(&y2, &blocks);
        for (blocks, dcs) |b, d| try testing.expect(@abs(@as(i32, b[0]) - d) <= 1);
    }
}

test "satd is the Hadamard transform's absolute sum" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    for (0..200) |_| {
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        r.bytes(&a);
        r.bytes(&b);
        const h = [4][4]i32{ .{ 1, 1, 1, 1 }, .{ 1, 1, -1, -1 }, .{ 1, -1, -1, 1 }, .{ 1, -1, 1, -1 } };
        var want: u32 = 0;
        for (0..4) |u| for (0..4) |v| {
            var t: i32 = 0;
            for (0..4) |y| for (0..4) |x| {
                t += h[u][y] * h[v][x] * (@as(i32, a[y * 4 + x]) - b[y * 4 + x]);
            };
            want += @abs(t);
        };
        try testing.expectEqual(want, satd4(&a, &b));
    }
    // A strip's is the sum of its blocks'.
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    r.bytes(&a);
    r.bytes(&b);
    inline for (.{ 8, 16 }) |w| {
        var want: u32 = 0;
        for (0..w / 4) |k| {
            var x: [16]u8 = undefined;
            var y: [16]u8 = undefined;
            for (0..4) |row| {
                x[row * 4 ..][0..4].* = a[row * w + 4 * k ..][0..4].*;
                y[row * 4 ..][0..4].* = b[row * w + 4 * k ..][0..4].*;
            }
            want += satd4(&x, &y);
        }
        try testing.expectEqual(want, satdStrip(w, a[0 .. 4 * w], b[0 .. 4 * w]));
    }
}

test "quantization rounds within its bias" {
    var coefs: [16]i16 = @splat(0);
    coefs[0] = 100;
    coefs[1] = -37;
    coefs[4] = 5;
    var levels: [16]i16 = undefined;
    var deq: [16]i16 = undefined;
    const m: Quant = .init(10, 12, 64, 64);
    const last = quantize(&coefs, &m, 0, &levels, &deq);
    try testing.expectEqual(1, last);
    try testing.expectEqual(10, levels[0]);
    try testing.expectEqual(-3, levels[1]);
    try testing.expectEqual(0, levels[2]);
    try testing.expectEqual(-36, deq[1]);
}
