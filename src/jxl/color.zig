//! Color transforms after reconstruction (ISO/IEC 18181-1, the XYB and
//! YCbCr transforms; the transfer functions of 18181-1's color encoding):
//! XYB to linear RGB through the opsin inverse matrix, then to the image's
//! color encoding, as the reference decoder writes XYB images when the
//! encoding is not an ICC profile (linear sRGB otherwise); and YCbCr to RGB.

const std = @import("std");
const testing = std.testing;

const headers = @import("headers.zig");

pub const Error = error{Unsupported};

/// How XYB samples become output samples.
pub const Xyb = struct {
    matrix: [3][3]f32,
    bias: [3]f32,
    bias_cbrt: [3]f32,
    tf: Tf,
    grey: bool,

    pub fn init(image: *const headers.ImageHeader) Error!Xyb {
        const c = &image.colour;
        const o = &image.opsin;
        var x: Xyb = .{
            .matrix = o.matrix,
            .bias = o.bias,
            .bias_cbrt = undefined,
            .tf = .linear,
            .grey = c.space == .grey,
        };
        for (&x.bias_cbrt, o.bias) |*b, v| b.* = std.math.cbrt(v);
        const scale = 255.0 / image.tone.intensity_target;
        for (&x.matrix) |*row| for (row) |*v| {
            v.* *= scale;
        };
        // An ICC profile gets linear sRGB.
        if (!c.want_icc) {
            if (c.space != .grey and c.primaries != .srgb) return error.Unsupported;
            if (c.white_point != .d65) return error.Unsupported;
            x.tf = try Tf.of(c);
        }
        if (x.grey) {
            // Luma from linear sRGB.
            const lum = [3]f32{ 0.2126, 0.7152, 0.0722 };
            var m: [3]f32 = @splat(0);
            for (0..3) |j| {
                for (0..3) |i| m[j] += lum[i] * x.matrix[i][j];
            }
            x.matrix = .{ m, m, m };
        }
        return x;
    }

    /// Converts the X, Y, B planes in place.
    pub fn apply(x: *const Xyb, planes: [3][]f32) void {
        x.applyTo(planes, planes);
    }

    /// Converts the X, Y, B samples of `in` into R, G, B in `to`, the
    /// same length, which may be `in`.
    pub fn applyTo(x: *const Xyb, in: [3][]const f32, to: [3][]f32) void {
        const ix = in[0];
        const iy = in[1];
        const ib = in[2];
        const px = to[0];
        const py = to[1];
        const pb = to[2];
        var i: usize = 0;
        {
            // Eight at a time.
            const m = &x.matrix;
            while (i + 8 <= px.len) : (i += 8) {
                const xv: V = ix[i..][0..8].*;
                const yv: V = iy[i..][0..8].*;
                const bv: V = ib[i..][0..8].*;
                const gr = yv + xv - @as(V, @splat(x.bias_cbrt[0]));
                const gg = yv - xv - @as(V, @splat(x.bias_cbrt[1]));
                const gb = bv - @as(V, @splat(x.bias_cbrt[2]));
                const mr = gr * gr * gr + @as(V, @splat(x.bias[0]));
                const mg = gg * gg * gg + @as(V, @splat(x.bias[1]));
                const mb = gb * gb * gb + @as(V, @splat(x.bias[2]));
                var out: [3]V = undefined;
                for (&out, m) |*o, row| {
                    o.* = @as(V, @splat(row[0])) * mr + @as(V, @splat(row[1])) * mg + @as(V, @splat(row[2])) * mb;
                    o.* = x.tf.encodeV(o.*);
                }
                px[i..][0..8].* = out[0];
                py[i..][0..8].* = out[1];
                pb[i..][0..8].* = out[2];
            }
        }
        for (ix[i..px.len], iy[i..px.len], ib[i..px.len], px[i..], py[i..], pb[i..]) |xi, yi, bi, *xv, *yv, *bv| {
            const gr = yi + xi - x.bias_cbrt[0];
            const gg = yi - xi - x.bias_cbrt[1];
            const gb = bi - x.bias_cbrt[2];
            const mr = gr * gr * gr + x.bias[0];
            const mg = gg * gg * gg + x.bias[1];
            const mb = gb * gb * gb + x.bias[2];
            const m = &x.matrix;
            const r = m[0][0] * mr + m[0][1] * mg + m[0][2] * mb;
            const g = m[1][0] * mr + m[1][1] * mg + m[1][2] * mb;
            const b = m[2][0] * mr + m[2][1] * mg + m[2][2] * mb;
            xv.* = x.tf.encode(r);
            yv.* = x.tf.encode(g);
            bv.* = x.tf.encode(b);
        }
    }
};

/// A transfer function, from linear light to encoded samples.
pub const Tf = union(enum) {
    linear,
    srgb,
    bt709,
    dci,
    /// Encoded = linear ^ gamma (the stored gamma, at most 1).
    gamma: f32,

    pub fn of(c: *const headers.ColourEncoding) Error!Tf {
        if (c.have_gamma) return .{ .gamma = @as(f32, @floatFromInt(c.gamma)) / 1e7 };
        return switch (c.transfer) {
            .linear => .linear,
            .srgb => .srgb,
            .bt709 => .bt709,
            .dci => .dci,
            else => error.Unsupported,
        };
    }

    pub fn encode(t: Tf, v: f32) f32 {
        return switch (t) {
            .linear => v,
            .srgb => srgb(v),
            .bt709 => bt709(v),
            .dci => signedPow(v, 1.0 / 2.6),
            .gamma => |g| signedPow(v, g),
        };
    }

    /// `encode` eight at a time.
    pub fn encodeV(t: Tf, v: V) V {
        return switch (t) {
            .linear => v,
            .srgb => srgbV(v),
            .bt709 => bt709V(v),
            .dci => signedPowV(v, 1.0 / 2.6),
            .gamma => |g| signedPowV(v, g),
        };
    }
};

fn signedPow(v: f32, e: f32) f32 {
    const a = @abs(v);
    const r = std.math.pow(f32, a, e);
    return if (v < 0) -r else r;
}

fn srgb(v: f32) f32 {
    const a = @abs(v);
    const r = if (a <= 0.0031308) a * 12.92 else 1.055 * std.math.pow(f32, a, 1.0 / 2.4) - 0.055;
    return if (v < 0) -r else r;
}

const V = @Vector(8, f32);

/// `srgb` eight at a time, with a^(1/2.4) as a^(1/4) times a^(1/6): two
/// square roots and a cube root by Newton's method, to within a few ulp.
fn srgbV(v: V) V {
    const a = @abs(v);
    const cb = cbrtV(a);
    const p = @sqrt(@sqrt(a)) * @sqrt(cb);
    const hi = @as(V, @splat(1.055)) * p - @as(V, @splat(0.055));
    const lo = a * @as(V, @splat(12.92));
    const r = @select(f32, a <= @as(V, @splat(0.0031308)), lo, hi);
    return @select(f32, v < @as(V, @splat(0)), -r, r);
}

/// The cube root of non-negative `a`, to within 2 ulp: a guess at
/// a^(-1/3) from the exponent's bits, two Newton steps for it, which need
/// no division, then one Newton step for the cube root itself.
fn cbrtV(a: V) V {
    const U = @Vector(8, u32);
    const bits: U = @bitCast(a);
    var r: V = @bitCast(@as(U, @splat(0x54a0fc5c)) -% bits / @as(U, @splat(3)));
    const a3 = a * @as(V, @splat(1.0 / 3.0));
    inline for (0..2) |_| r = r * (@as(V, @splat(4.0 / 3.0)) - a3 * r * r * r);
    var y = a * r * r;
    y = y - (y * y * y - a) / (@as(V, @splat(3)) * y * y);
    return @select(f32, a == @as(V, @splat(0)), a, y);
}

fn bt709V(v: V) V {
    const a = @abs(v);
    const hi = @as(V, @splat(1.099)) * powV(a, 0.45) - @as(V, @splat(0.099));
    const lo = a * @as(V, @splat(4.5));
    const r = @select(f32, a <= @as(V, @splat(0.018)), lo, hi);
    return @select(f32, v < @as(V, @splat(0)), -r, r);
}

fn signedPowV(v: V, e: f32) V {
    const r = powV(@abs(v), e);
    return @select(f32, v < @as(V, @splat(0)), -r, r);
}

/// a^e for non-negative `a` and 0 < e <= 1, as 2^(e·log2 a), to within a
/// few ulp: log2 from the exponent and an odd series in
/// t = (m - 1) / (m + 1) for the mantissa m in [√½, √2), and 2^x from its
/// integer part and a degree-6 polynomial on [-½, ½]. Zero and values
/// below the smallest normal give 0.
fn powV(a: V, e: f32) V {
    const U = @Vector(8, u32);
    const I = @Vector(8, i32);
    const bits: U = @bitCast(a);
    // The mantissa, scaled into [√½, √2), and the matching exponent.
    const shifted = bits -% @as(U, @splat(0x3f3504f3));
    const k: I = @as(I, @bitCast(shifted)) >> @splat(23);
    const m: V = @bitCast(bits -% (@as(U, @bitCast(k)) << @splat(23)));
    const t = (m - @as(V, @splat(1))) / (m + @as(V, @splat(1)));
    const t2 = t * t;
    var poly: V = @splat(2.0 / 9.0);
    poly = poly * t2 + @as(V, @splat(2.0 / 7.0));
    poly = poly * t2 + @as(V, @splat(2.0 / 5.0));
    poly = poly * t2 + @as(V, @splat(2.0 / 3.0));
    poly = poly * t2 + @as(V, @splat(2.0));
    const log2a = @as(V, @floatFromInt(k)) + t * poly * @as(V, @splat(std.math.log2e));
    // 2^x with x = e·log2 a, held to the normal exponents; NaN (from
    // hostile planes) becomes the smallest, so the conversion to integers
    // below cannot trap.
    const raw = @as(V, @splat(e)) * log2a;
    const lo: V = @splat(-126);
    const x = @select(f32, raw == raw, @min(@max(raw, lo), @as(V, @splat(127))), lo);
    const n = @round(x);
    const f = x - n;
    var p: V = @splat(1.5403530393381606e-4);
    p = p * f + @as(V, @splat(1.3333558146428443e-3));
    p = p * f + @as(V, @splat(9.618129107628477e-3));
    p = p * f + @as(V, @splat(5.550410866482158e-2));
    p = p * f + @as(V, @splat(2.402265069591007e-1));
    p = p * f + @as(V, @splat(6.931471805599453e-1));
    p = p * f + @as(V, @splat(1));
    const scale: V = @bitCast(@as(U, @bitCast(@as(I, @intFromFloat(n)) + @as(I, @splat(127)))) << @splat(23));
    const r = p * scale;
    return @select(f32, a < @as(V, @splat(std.math.floatMin(f32))), @as(V, @splat(0)), r);
}

fn bt709(v: f32) f32 {
    const a = @abs(v);
    const r = if (a <= 0.018) a * 4.5 else 1.099 * std.math.pow(f32, a, 0.45) - 0.099;
    return if (v < 0) -r else r;
}

/// YCbCr (as JPEG stores it, centred on zero) to RGB, in place on the
/// Y, Cb, Cr planes, writing R, G, B.
pub fn ycbcrToRgb(planes: [3][]f32) void {
    // Planes hold (Cb, Y, Cr) in the VarDCT channel order (X, Y, B).
    for (planes[0], planes[1], planes[2]) |*cb, *y, *cr| {
        const yv = y.* + 128.0 / 255.0;
        const r = yv + 1.402 * cr.*;
        const g = yv + (-0.299 * 1.402 / 0.587) * cr.* + (-0.114 * 1.772 / 0.587) * cb.*;
        const b = yv + 1.772 * cb.*;
        cb.* = r;
        y.* = g;
        cr.* = b;
    }
}

test "srgb transfer" {
    const probes: [8]f32 = .{ -0.3, 0.002, 0.0031308, 0.01, 0.21404114, 0.5, 1, 3.5 };
    const got: [8]f32 = srgbV(probes);
    for (probes, got) |p, g| try testing.expectApproxEqRel(srgb(p), g, 3e-7);
    try testing.expectApproxEqAbs(@as(f32, 0.5), srgb(0.21404114), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), srgb(1.0), 1e-6);
}

test "power transfer functions" {
    const probes: [8]f32 = .{ 1e-6, 0.002, 0.018, 0.05, 0.21404114, 0.5, 0.999, 3.5 };
    for ([_]Tf{ .bt709, .dci, .{ .gamma = 0.45455 }, .{ .gamma = 1.0 / 2.2 } }) |t| {
        for ([_]f32{ 1, -1 }) |sign| {
            const v: V = @as(V, probes) * @as(V, @splat(sign));
            const got: [8]f32 = t.encodeV(v);
            for (probes, got) |p, g| try testing.expectApproxEqRel(t.encode(p * sign), g, 1e-6);
        }
    }
    // Zero, values below the normals, and hostile planes stay finite.
    const odd: V = .{ 0, 1e-40, -1e-40, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 1e30, 1 };
    const got: [8]f32 = signedPowV(odd, 0.45);
    for (got[0..3]) |g| try testing.expectEqual(@as(f32, 0), g);
    try testing.expectApproxEqRel(@as(f32, 1), got[7], 1e-6);
}
