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

    /// Converts `n` samples of the X, Y, B planes in place.
    pub fn apply(x: *const Xyb, planes: [3][]f32) void {
        const px = planes[0];
        const py = planes[1];
        const pb = planes[2];
        var i: usize = 0;
        if (x.tf == .srgb or x.tf == .linear) {
            // Eight at a time.
            const m = &x.matrix;
            while (i + 8 <= px.len) : (i += 8) {
                const xv: V = px[i..][0..8].*;
                const yv: V = py[i..][0..8].*;
                const bv: V = pb[i..][0..8].*;
                const gr = yv + xv - @as(V, @splat(x.bias_cbrt[0]));
                const gg = yv - xv - @as(V, @splat(x.bias_cbrt[1]));
                const gb = bv - @as(V, @splat(x.bias_cbrt[2]));
                const mr = gr * gr * gr + @as(V, @splat(x.bias[0]));
                const mg = gg * gg * gg + @as(V, @splat(x.bias[1]));
                const mb = gb * gb * gb + @as(V, @splat(x.bias[2]));
                var out: [3]V = undefined;
                for (&out, m) |*o, row| {
                    o.* = @as(V, @splat(row[0])) * mr + @as(V, @splat(row[1])) * mg + @as(V, @splat(row[2])) * mb;
                    if (x.tf == .srgb) o.* = srgbV(o.*);
                }
                px[i..][0..8].* = out[0];
                py[i..][0..8].* = out[1];
                pb[i..][0..8].* = out[2];
            }
        }
        for (px[i..], py[i..], pb[i..]) |*xv, *yv, *bv| {
            const gr = yv.* + xv.* - x.bias_cbrt[0];
            const gg = yv.* - xv.* - x.bias_cbrt[1];
            const gb = bv.* - x.bias_cbrt[2];
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

/// The cube root of non-negative `a`: a guess from the exponent's bits,
/// then three Newton steps.
fn cbrtV(a: V) V {
    const U = @Vector(8, u32);
    const bits: U = @bitCast(a);
    var y: V = @bitCast(bits / @as(U, @splat(3)) + @as(U, @splat(709921077)));
    inline for (0..3) |_| y = y - (y * y * y - a) / (@as(V, @splat(3)) * y * y);
    return @select(f32, a == @as(V, @splat(0)), a, y);
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
