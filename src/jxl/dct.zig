//! VarDCT's transforms (ISO/IEC 18181-1, the varblock transforms): the
//! inverse DCT of every size from 4 to 256 in each direction, the special
//! 8 by 8 transforms (identity, 2x2, 4x4, 4x8, 8x4, and AFV), and the
//! lowest frequencies of a large block recovered from its LF samples.
//!
//! Coefficients are stored with the block's smaller side as rows: a block
//! of R rows and C columns of pixels keeps C rows of R coefficients when
//! R >= C (row index the horizontal frequency) and R rows of C when R < C.
//! The DCT is scaled so that a block's coefficient 0 is its mean and
//! `x[n] = X[0] + sqrt(2) * sum X[k] cos(pi (2n + 1) k / 2N)`.

const std = @import("std");
const testing = std.testing;

pub const Strategy = enum(u8) {
    dct8,
    identity,
    dct2x2,
    dct4x4,
    dct16x16,
    dct32x32,
    dct16x8,
    dct8x16,
    dct32x8,
    dct8x32,
    dct32x16,
    dct16x32,
    dct4x8,
    dct8x4,
    afv0,
    afv1,
    afv2,
    afv3,
    dct64x64,
    dct64x32,
    dct32x64,
    dct128x128,
    dct128x64,
    dct64x128,
    dct256x256,
    dct256x128,
    dct128x256,

    pub const count = 27;

    const blocks_x = [count]u8{ 1, 1, 1, 1, 2, 4, 1, 2, 1, 4, 2, 4, 1, 1, 1, 1, 1, 1, 8, 4, 8, 16, 8, 16, 32, 16, 32 };
    const blocks_y = [count]u8{ 1, 1, 1, 1, 2, 4, 2, 1, 4, 1, 4, 2, 1, 1, 1, 1, 1, 1, 8, 8, 4, 16, 16, 8, 32, 32, 16 };
    /// The order (coefficient order and context) class of each strategy.
    pub const order_class = [count]u8{
        0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6, 1, 1, 1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12,
    };
    /// The dequantization table of each strategy.
    pub const quant_table = [count]u8{
        0, 1, 2, 3, 4, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10, 10, 11, 12, 12, 13, 14, 14, 15, 16, 16,
    };

    /// Width in 8 by 8 blocks.
    pub fn bx(s: Strategy) u32 {
        return blocks_x[@intFromEnum(s)];
    }
    /// Height in 8 by 8 blocks.
    pub fn by(s: Strategy) u32 {
        return blocks_y[@intFromEnum(s)];
    }
    pub fn covered(s: Strategy) u32 {
        return s.bx() * s.by();
    }
    pub fn log2Covered(s: Strategy) u5 {
        return @intCast(std.math.log2_int(u32, s.covered()));
    }
};

const sqrt2_f64: f64 = std.math.sqrt2;
const sqrt2: f32 = @floatCast(sqrt2_f64);

/// 1 / (2 cos(pi (2i + 1) / 2N)), the odd half's multipliers.
fn oddMultipliers(comptime n: usize) [n / 2]f32 {
    var m: [n / 2]f32 = undefined;
    for (&m, 0..) |*v, i| {
        const a = std.math.pi * @as(f64, @floatFromInt(2 * i + 1)) / @as(f64, @floatFromInt(2 * n));
        v.* = @floatCast(1.0 / (2.0 * @cos(a)));
    }
    return m;
}

/// The inverse DCT of `n` coefficients in place; `T` is f32 or a vector of
/// f32, transforming several columns at once.
pub fn idct1d(comptime T: type, comptime n: usize, x: *[n]T) void {
    if (n == 1) return;
    if (n == 2) {
        const a = x[0];
        const b = x[1];
        x[0] = a + b;
        x[1] = a - b;
        return;
    }
    const h = n / 2;
    var even: [h]T = undefined;
    var odd: [h]T = undefined;
    inline for (0..h) |i| {
        even[i] = x[2 * i];
        odd[i] = x[2 * i + 1];
    }
    // The odd half as a DCT of half the size: Y[i] = X[2i+1] + X[2i-1],
    // and Y[0] = sqrt(2) X[1].
    var i: usize = h - 1;
    while (i > 0) : (i -= 1) odd[i] += odd[i - 1];
    odd[0] *= splat(T, sqrt2);
    idct1d(T, h, &even);
    idct1d(T, h, &odd);
    const m = comptime oddMultipliers(n);
    inline for (0..h) |k| {
        const o = odd[k] * splat(T, m[k]);
        x[k] = even[k] + o;
        x[n - 1 - k] = even[k] - o;
    }
}

fn splat(comptime T: type, v: f32) T {
    return if (T == f32) v else @splat(v);
}

const lanes = 4;
const V = @Vector(lanes, f32);

/// The inverse DCT down each column of `m`, `rows` by `cols`, in place.
fn columns(comptime rows: usize, comptime cols: usize, m: *[rows * cols]f32) void {
    // Eight columns at a time when they come in eights.
    const l = if (cols % 8 == 0) 8 else lanes;
    const W = @Vector(l, f32);
    var c: usize = 0;
    while (c < cols) : (c += l) {
        var col: [rows]W = undefined;
        for (&col, 0..) |*v, r| v.* = m[r * cols + c ..][0..l].*;
        idct1d(W, rows, &col);
        for (col, 0..) |v, r| m[r * cols + c ..][0..l].* = v;
    }
}

fn transpose(comptime rows: usize, comptime cols: usize, in: *const [rows * cols]f32, out: *[rows * cols]f32) void {
    for (0..rows) |r| {
        for (0..cols) |c| out[c * rows + r] = in[r * cols + c];
    }
}

/// Pixels of an `r` by `c` DCT block from its coefficients in stored
/// layout, written to `out` with `stride`. `scratch` holds two blocks.
pub fn idct2d(
    comptime r: usize,
    comptime c: usize,
    coeffs: []const f32,
    out: []f32,
    stride: usize,
    scratch: []f32,
) void {
    const a: *[r * c]f32 = scratch[0 .. r * c];
    const b: *[r * c]f32 = scratch[r * c ..][0 .. r * c];
    // `a` as C rows (horizontal frequency) by R columns.
    if (r >= c) {
        @memcpy(a, coeffs[0 .. r * c]);
    } else {
        transpose(r, c, coeffs[0 .. r * c], a);
    }
    columns(c, r, a); // now x by vertical frequency
    transpose(c, r, a, b); // vertical frequency by x
    columns(r, c, b); // y by x
    for (0..r) |y| @memcpy(out[y * stride ..][0..c], b[y * c ..][0..c]);
}

/// The scaled forward DCT of an `r` by `c` block of LF samples, in natural
/// layout (row index the vertical frequency): the inverse of `idct2d`.
fn dct2d(r: usize, c: usize, in: []const f32, in_stride: usize, out: []f32) void {
    const br = &basis_table[std.math.log2_int(usize, r)];
    const bc = &basis_table[std.math.log2_int(usize, c)];
    // Separably: each row's horizontal frequencies, then the columns'.
    var rows: [32 * 32]f64 = undefined;
    for (0..r) |y| {
        for (0..c) |v| {
            var sum: f64 = 0;
            for (0..c) |x| sum += @as(f64, in[y * in_stride + x]) * bc[v][x];
            rows[y * c + v] = sum;
        }
    }
    for (0..r) |u| {
        for (0..c) |v| {
            var sum: f64 = 0;
            for (0..r) |y| sum += br[u][y] * rows[y * c + v];
            out[u * c + v] = @floatCast(sum / @as(f64, @floatFromInt(r * c)));
        }
    }
}

/// `basis(k, n, 1 << l)` at `[l][k][n]`, for the LF sizes `dct2d` takes.
const basis_table: [6][32][32]f64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [6][32][32]f64 = @splat(@splat(@splat(0)));
    for (0..6) |l| {
        const size = 1 << l;
        for (0..size) |k| for (0..size) |n| {
            t[l][k][n] = basis(k, n, size);
        };
    }
    break :blk t;
};

fn basis(k: usize, n: usize, size: usize) f64 {
    if (k == 0) return 1;
    const a = std.math.pi * @as(f64, @floatFromInt((2 * n + 1) * k)) / @as(f64, @floatFromInt(2 * size));
    return sqrt2_f64 * @cos(a);
}

/// How the mean of each 8 by 8 block of a size-`big` DCT basis function
/// `i` compares with the size-`small` basis function `i` (small = big / 8).
fn resampleScale(i: usize, big: usize, small: usize) f32 {
    if (i == 0) return 1;
    var sum: f64 = 0;
    for (0..8) |n| {
        sum += @cos(std.math.pi * @as(f64, @floatFromInt((2 * n + 1) * i)) / @as(f64, @floatFromInt(2 * big)));
    }
    const avg = sum / 8;
    const s = @cos(std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(2 * small)));
    return @floatCast(s / avg);
}

const resample: [6][32]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [6][32]f32 = undefined;
    for (0..6) |l| {
        const small = @as(usize, 1) << @intCast(l);
        for (0..32) |i| t[l][i] = if (i < small) resampleScale(i, small * 8, small) else 0;
    }
    break :blk t;
};

/// Writes a multi-block DCT's lowest frequencies, from its LF samples (`lf`
/// at the block's top left, with `lf_stride`), into `coeffs` in stored
/// layout.
pub fn llfFromLf(s: Strategy, lf: []const f32, lf_stride: usize, coeffs: []f32) void {
    const cy = s.by();
    const cx = s.bx();
    var tmp: [32 * 32]f32 = undefined;
    dct2d(cy, cx, lf, lf_stride, &tmp);
    const ly = std.math.log2_int(u32, cy);
    const lx = std.math.log2_int(u32, cx);
    // Stored layout: the smaller side's frequencies index rows.
    const row_len = @max(cx, cy) * 8;
    for (0..cy) |u| {
        for (0..cx) |v| {
            const val = tmp[u * cx + v] * resample[ly][u] * resample[lx][v];
            if (cy < cx) {
                coeffs[u * row_len + v] = val;
            } else {
                coeffs[v * row_len + u] = val;
            }
        }
    }
}

const afv_basis = [16][16]f32{
    .{ 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25 },
    .{
        0.876902929799142,    0.2206518106944235,   -0.10140050393753763, -0.1014005039375375,
        0.2206518106944236,   -0.10140050393753777, -0.10140050393753772, -0.10140050393753763,
        -0.10140050393753758, -0.10140050393753769, -0.1014005039375375,  -0.10140050393753768,
        -0.10140050393753768, -0.10140050393753759, -0.10140050393753763, -0.10140050393753741,
    },
    .{
        0.0,                  0.0,                  0.40670075830260755, 0.44444816619734445,
        0.0,                  0.0,                  0.19574399372042936, 0.2929100136981264,
        -0.40670075830260716, -0.19574399372042872, 0.0,                 0.11379074460448091,
        -0.44444816619734384, -0.29291001369812636, -0.1137907446044814, 0.0,
    },
    .{
        0.0,                  0.0,                  -0.21255748058288748, 0.3085497062849767,
        0.0,                  0.4706702258572536,   -0.1621205195722993,  0.0,
        -0.21255748058287047, -0.16212051957228327, -0.47067022585725277, -0.1464291867126764,
        0.3085497062849487,   0.0,                  -0.14642918671266536, 0.4251149611657548,
    },
    .{ 0.0, -0.7071067811865474, 0.0, 0.0, 0.7071067811865476, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    .{
        -0.4105377591765233,  0.6235485373547691,   -0.06435071657946274, -0.06435071657946266,
        0.6235485373547694,   -0.06435071657946284, -0.0643507165794628,  -0.06435071657946274,
        -0.06435071657946272, -0.06435071657946279, -0.06435071657946266, -0.06435071657946277,
        -0.06435071657946277, -0.06435071657946273, -0.06435071657946274, -0.0643507165794626,
    },
    .{
        0.0,                  0.0,                  -0.4517556589999482,   0.15854503551840063,
        0.0,                  -0.04038515160822202, 0.0074182263792423875, 0.39351034269210167,
        -0.45175565899994635, 0.007418226379244351, 0.1107416575309343,    0.08298163094882051,
        0.15854503551839705,  0.3935103426921022,   0.0829816309488214,    -0.45175565899994796,
    },
    .{
        0.0,                 0.0,                 -0.304684750724869,  0.5112616136591823,
        0.0,                 0.0,                 -0.290480129728998,  -0.06578701549142804,
        0.304684750724884,   0.2904801297290076,  0.0,                 -0.23889773523344604,
        -0.5112616136592012, 0.06578701549142545, 0.23889773523345467, 0.0,
    },
    .{
        0.0,                 0.0,                 0.3017929516615495,   0.25792362796341184,
        0.0,                 0.16272340142866204, 0.09520022653475037,  0.0,
        0.3017929516615503,  0.09520022653475055, -0.16272340142866173, -0.35312385449816297,
        0.25792362796341295, 0.0,                 -0.3531238544981624,  -0.6035859033230976,
    },
    .{
        0.0,                 0.0,                0.40824829046386274, 0.0,
        0.0,                 0.0,                0.0,                 -0.4082482904638628,
        -0.4082482904638635, 0.0,                0.0,                 -0.40824829046386296,
        0.0,                 0.4082482904638634, 0.408248290463863,   0.0,
    },
    .{
        0.0,                  0.0,                 0.1747866975480809,   0.0812611176717539,
        0.0,                  0.0,                 -0.3675398009862027,  -0.307882213957909,
        -0.17478669754808135, 0.3675398009862011,  0.0,                  0.4826689115059883,
        -0.08126111767175039, 0.30788221395790305, -0.48266891150598584, 0.0,
    },
    .{
        0.0,                  0.0,                  -0.21105601049335784, 0.18567180916109802,
        0.0,                  0.0,                  0.49215859013738733,  -0.38525013709251915,
        0.21105601049335806,  -0.49215859013738905, 0.0,                  0.17419412659916217,
        -0.18567180916109904, 0.3852501370925211,   -0.1741941265991621,  0.0,
    },
    .{
        0.0,                  0.0,                  -0.14266084808807264,  -0.3416446842253372,
        0.0,                  0.7367497537172237,   0.24627107722075148,   -0.08574019035519306,
        -0.14266084808807344, 0.24627107722075137,  0.14883399227113567,   -0.04768680350229251,
        -0.3416446842253373,  -0.08574019035519267, -0.047686803502292804, -0.14266084808807242,
    },
    .{
        0.0,                  0.0,                  -0.13813540350758585, 0.3302282550303788,
        0.0,                  0.08755115000587084,  -0.07946706605909573, -0.4613374887461511,
        -0.13813540350758294, -0.07946706605910261, 0.49724647109535086,  0.12538059448563663,
        0.3302282550303805,   -0.4613374887461554,  0.12538059448564315,  -0.13813540350758452,
    },
    .{
        0.0,                 0.0,                 -0.17437602599651067, 0.0702790691196284,
        0.0,                 -0.2921026642334881, 0.3623817333531167,   0.0,
        -0.1743760259965108, 0.36238173335311646, 0.29210266423348785,  -0.4326608024727445,
        0.07027906911962818, 0.0,                 -0.4326608024727457,  0.34875205199302267,
    },
    .{
        0.0,                  0.0,                 0.11354987314994337,  -0.07417504595810355,
        0.0,                  0.19402893032594343, -0.435190496523228,   0.21918684838857466,
        0.11354987314994257,  -0.4351904965232251, 0.5550443808910661,   -0.25468277124066463,
        -0.07417504595810233, 0.2191868483885728,  -0.25468277124066413, 0.1135498731499429,
    },
};

/// Writes the pixels of a block of strategy `s` from its dequantized
/// coefficients (with the lowest frequencies in place) to `out`.
/// `scratch` holds at least `2 * 64 * covered` floats.
pub fn toPixels(s: Strategy, coeffs: []f32, out: []f32, stride: usize, scratch: []f32) void {
    switch (s) {
        .dct8 => idct2d(8, 8, coeffs, out, stride, scratch),
        .dct16x16 => idct2d(16, 16, coeffs, out, stride, scratch),
        .dct32x32 => idct2d(32, 32, coeffs, out, stride, scratch),
        .dct16x8 => idct2d(16, 8, coeffs, out, stride, scratch),
        .dct8x16 => idct2d(8, 16, coeffs, out, stride, scratch),
        .dct32x8 => idct2d(32, 8, coeffs, out, stride, scratch),
        .dct8x32 => idct2d(8, 32, coeffs, out, stride, scratch),
        .dct32x16 => idct2d(32, 16, coeffs, out, stride, scratch),
        .dct16x32 => idct2d(16, 32, coeffs, out, stride, scratch),
        .dct64x64 => idct2d(64, 64, coeffs, out, stride, scratch),
        .dct64x32 => idct2d(64, 32, coeffs, out, stride, scratch),
        .dct32x64 => idct2d(32, 64, coeffs, out, stride, scratch),
        .dct128x128 => idct2d(128, 128, coeffs, out, stride, scratch),
        .dct128x64 => idct2d(128, 64, coeffs, out, stride, scratch),
        .dct64x128 => idct2d(64, 128, coeffs, out, stride, scratch),
        .dct256x256 => idct2d(256, 256, coeffs, out, stride, scratch),
        .dct256x128 => idct2d(256, 128, coeffs, out, stride, scratch),
        .dct128x256 => idct2d(128, 256, coeffs, out, stride, scratch),
        .identity => identity(coeffs, out, stride),
        .dct2x2 => dct2x2(coeffs, out, stride),
        .dct4x4 => dct4x4(coeffs, out, stride, scratch),
        .dct4x8 => {
            const dcs = [2]f32{ coeffs[0] + coeffs[8], coeffs[0] - coeffs[8] };
            for (0..2) |y| {
                var block: [32]f32 = undefined;
                for (0..4) |iy| {
                    for (0..8) |ix| block[iy * 8 + ix] = coeffs[(y + iy * 2) * 8 + ix];
                }
                block[0] = dcs[y];
                idct2d(4, 8, &block, out[y * 4 * stride ..], stride, scratch);
            }
        },
        .dct8x4 => {
            const dcs = [2]f32{ coeffs[0] + coeffs[8], coeffs[0] - coeffs[8] };
            for (0..2) |x| {
                var block: [32]f32 = undefined;
                for (0..4) |iy| {
                    for (0..8) |ix| block[iy * 8 + ix] = coeffs[(x + iy * 2) * 8 + ix];
                }
                block[0] = dcs[x];
                idct2d(8, 4, &block, out[x * 4 ..], stride, scratch);
            }
        },
        .afv0, .afv1, .afv2, .afv3 => afv(@intFromEnum(s) - @intFromEnum(Strategy.afv0), coeffs, out, stride, scratch),
    }
}

fn corners(coeffs: []const f32) [4]f32 {
    const c00 = coeffs[0];
    const c01 = coeffs[1];
    const c10 = coeffs[8];
    const c11 = coeffs[9];
    return .{ c00 + c01 + c10 + c11, c00 + c01 - c10 - c11, c00 - c01 + c10 - c11, c00 - c01 - c10 + c11 };
}

fn identity(coeffs: []const f32, out: []f32, stride: usize) void {
    const dcs = corners(coeffs);
    for (0..2) |y| {
        for (0..2) |x| {
            var residual: f32 = 0;
            for (0..4) |iy| {
                for (0..4) |ix| {
                    if (ix == 0 and iy == 0) continue;
                    residual += coeffs[(y + iy * 2) * 8 + x + ix * 2];
                }
            }
            const centre = dcs[y * 2 + x] - residual * (1.0 / 16.0);
            for (0..4) |iy| {
                for (0..4) |ix| {
                    if (ix == 1 and iy == 1) continue;
                    out[(y * 4 + iy) * stride + x * 4 + ix] = coeffs[(y + iy * 2) * 8 + x + ix * 2] + centre;
                }
            }
            out[(y * 4 + 1) * stride + x * 4 + 1] = centre;
            out[(y * 4) * stride + x * 4] = coeffs[(y + 2) * 8 + x + 2] + centre;
        }
    }
}

/// One level of the 2x2 transform over the top-left `s` by `s` corner.
fn idct2Top(comptime s: usize, b: *[64]f32) void {
    var tmp: [64]f32 = undefined;
    const h = s / 2;
    for (0..h) |y| {
        for (0..h) |x| {
            const c00 = b[y * 8 + x];
            const c01 = b[y * 8 + h + x];
            const c10 = b[(y + h) * 8 + x];
            const c11 = b[(y + h) * 8 + h + x];
            tmp[y * 16 + x * 2] = c00 + c01 + c10 + c11;
            tmp[y * 16 + x * 2 + 1] = c00 + c01 - c10 - c11;
            tmp[(y * 2 + 1) * 8 + x * 2] = c00 - c01 + c10 - c11;
            tmp[(y * 2 + 1) * 8 + x * 2 + 1] = c00 - c01 - c10 + c11;
        }
    }
    for (0..s) |y| @memcpy(b[y * 8 ..][0..s], tmp[y * 8 ..][0..s]);
}

fn dct2x2(coeffs: []const f32, out: []f32, stride: usize) void {
    var b: [64]f32 = coeffs[0..64].*;
    idct2Top(2, &b);
    idct2Top(4, &b);
    idct2Top(8, &b);
    for (0..8) |y| @memcpy(out[y * stride ..][0..8], b[y * 8 ..][0..8]);
}

fn dct4x4(coeffs: []const f32, out: []f32, stride: usize, scratch: []f32) void {
    const dcs = corners(coeffs);
    for (0..2) |y| {
        for (0..2) |x| {
            var block: [16]f32 = undefined;
            for (0..4) |iy| {
                for (0..4) |ix| block[iy * 4 + ix] = coeffs[(y + iy * 2) * 8 + x + ix * 2];
            }
            block[0] = dcs[y * 2 + x];
            idct2d(4, 4, &block, out[y * 4 * stride + x * 4 ..], stride, scratch);
        }
    }
}

fn afv(kind: usize, coeffs: []const f32, out: []f32, stride: usize, scratch: []f32) void {
    const afv_x = kind & 1;
    const afv_y = kind / 2;
    const b00 = coeffs[0];
    const b01 = coeffs[1];
    const b10 = coeffs[8];
    const dcs = [3]f32{ (b00 + b10 + b01) * 4.0, b00 + b10 - b01, b00 - b10 };
    // The 4x4 corner through the AFV basis.
    var c: [16]f32 = undefined;
    for (0..4) |iy| {
        for (0..4) |ix| c[iy * 4 + ix] = coeffs[iy * 2 * 8 + ix * 2];
    }
    c[0] = dcs[0];
    var px: [16]f32 = @splat(0);
    for (0..16) |j| {
        for (0..16) |i| px[i] += c[j] * afv_basis[j][i];
    }
    for (0..4) |iy| {
        for (0..4) |ix| {
            const sy = if (afv_y == 1) 3 - iy else iy;
            const sx = if (afv_x == 1) 3 - ix else ix;
            out[(iy + afv_y * 4) * stride + afv_x * 4 + ix] = px[sy * 4 + sx];
        }
    }
    // The 4x4 DCT beside it.
    var b4: [16]f32 = undefined;
    for (0..4) |iy| {
        for (0..4) |ix| b4[iy * 4 + ix] = coeffs[iy * 2 * 8 + ix * 2 + 1];
    }
    b4[0] = dcs[1];
    idct2d(4, 4, &b4, out[afv_y * 4 * stride + (if (afv_x == 1) @as(usize, 0) else 4) ..], stride, scratch);
    // The 4x8 DCT in the other half.
    var b8: [32]f32 = undefined;
    for (0..4) |iy| {
        for (0..8) |ix| b8[iy * 8 + ix] = coeffs[(1 + iy * 2) * 8 + ix];
    }
    b8[0] = dcs[2];
    idct2d(4, 8, &b8, out[(if (afv_y == 1) @as(usize, 0) else 4) * stride ..], stride, scratch);
}

/// Natural coefficient order of a strategy's class (`order[i]` is the
/// stored-layout index of the i-th coefficient), `64 * covered` entries.
pub fn naturalOrder(s: Strategy, order: []u32) void {
    var cx: usize = s.bx();
    var cy: usize = s.by();
    if (cy > cx) std.mem.swap(usize, &cx, &cy);
    const xs = cx / cy;
    const xsm = xs - 1;
    const xss: u6 = @intCast(std.math.log2_int_ceil(usize, xs));
    var cur: usize = cx * cy;
    const w = cx * 8;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        for (0..i + 1) |j| {
            var x = j;
            var y = i - j;
            if (i % 2 == 1) std.mem.swap(usize, &x, &y);
            if (y & xsm != 0) continue;
            y >>= xss;
            var val: usize = undefined;
            if (x < cx and y < cy) {
                val = y * cx + x;
            } else {
                val = cur;
                cur += 1;
            }
            order[val] = @intCast(y * w + x);
        }
    }
    var ip: usize = w - 1;
    while (ip > 0) : (ip -= 1) {
        const ii = ip - 1;
        for (0..ii + 1) |j| {
            var x = w - 1 - (ii - j);
            var y = w - 1 - j;
            if (ii % 2 == 1) std.mem.swap(usize, &x, &y);
            if (y & xsm != 0) continue;
            y >>= xss;
            order[cur] = @intCast(y * w + x);
            cur += 1;
        }
    }
}

fn naiveIdct(n: usize, x: []const f32, out: []f32) void {
    for (0..n) |i| {
        var s: f64 = 0;
        for (0..n) |k| s += @as(f64, x[k]) * basis(k, i, n);
        out[i] = @floatCast(s);
    }
}

test "idct1d matches the definition" {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    inline for (.{ 2, 4, 8, 16, 32, 64, 128, 256 }) |n| {
        var x: [n]f32 = undefined;
        for (&x) |*v| v.* = r.float(f32) * 2 - 1;
        var want: [n]f32 = undefined;
        naiveIdct(n, &x, &want);
        idct1d(f32, n, &x);
        for (x, want) |g, w| try testing.expectApproxEqAbs(w, g, 1e-4);
    }
}

test "idct2d inverts dct2d, in stored layout" {
    var prng: std.Random.DefaultPrng = .init(9);
    const r = prng.random();
    var scratch: [2 * 32 * 16]f32 = undefined;
    inline for (.{ .{ 8, 8 }, .{ 16, 8 }, .{ 8, 16 }, .{ 32, 16 }, .{ 4, 8 }, .{ 8, 4 } }) |rc| {
        const rows = rc[0];
        const cols = rc[1];
        var px: [rows * cols]f32 = undefined;
        for (&px) |*v| v.* = r.float(f32);
        var nat: [rows * cols]f32 = undefined;
        dct2d(rows, cols, &px, cols, &nat);
        var stored: [rows * cols]f32 = undefined;
        for (0..rows) |u| {
            for (0..cols) |v| {
                const at = if (rows >= cols) v * rows + u else u * cols + v;
                stored[at] = nat[u * cols + v];
            }
        }
        var out: [rows * cols]f32 = undefined;
        idct2d(rows, cols, &stored, &out, cols, &scratch);
        for (out, px) |g, w| try testing.expectApproxEqAbs(w, g, 1e-4);
    }
}

test "lowest frequencies reproduce the block means" {
    // A 16x16 block whose 2x2 LF samples are its 8x8 means: the inverse
    // of the lowest frequencies alone has those means.
    const lf = [4]f32{ 1.0, 0.5, -0.25, 2.0 };
    var coeffs: [256]f32 = @splat(0);
    llfFromLf(.dct16x16, &lf, 2, &coeffs);
    var out: [256]f32 = undefined;
    var scratch: [512]f32 = undefined;
    idct2d(16, 16, &coeffs, &out, 16, &scratch);
    for (0..2) |by| {
        for (0..2) |bx| {
            var sum: f32 = 0;
            for (0..8) |y| {
                for (0..8) |x| sum += out[(by * 8 + y) * 16 + bx * 8 + x];
            }
            try testing.expectApproxEqAbs(lf[by * 2 + bx], sum / 64, 1e-4);
        }
    }
}

test "natural order of a DCT8 starts with the zigzag" {
    var order: [64]u32 = undefined;
    naturalOrder(.dct8, &order);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 8, 16, 9, 2, 3, 10 }, order[0..8]);
    // Every index once.
    var seen: [64]bool = @splat(false);
    for (order) |o| seen[o] = true;
    for (seen) |s| try testing.expect(s);
}
