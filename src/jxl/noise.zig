//! Noise synthesis (ISO/IEC 18181-1, the frame's noise): pseudo-random
//! planes from XorShift128+ seeded per group, a 5x5 high-pass
//! convolution, and noise added to X, Y, and B with a strength that
//! follows the intensity through an eight-point table.

const std = @import("std");
const testing = std.testing;

const Arena = @import("Arena.zig");
const BitReader = @import("BitReader.zig");

pub const Error = BitReader.Error || Arena.Error;

pub const Params = struct {
    lut: [8]f32,

    pub fn read(br: *BitReader) Error!Params {
        var p: Params = undefined;
        for (&p.lut) |*v| v.* = @as(f32, @floatFromInt(try br.bits(10))) / 1024;
        return p;
    }

    fn hasAny(p: *const Params) bool {
        for (p.lut) |v| if (@abs(v) > 1e-3) return true;
        return false;
    }

    /// The strength at intensity `x`, interpolated in the table and
    /// clamped to [0, 1].
    fn strength(p: *const Params, x: f32) f32 {
        const scale = 6;
        const scaled = @max(0, x * scale);
        var floor = @floor(scaled);
        var frac = scaled - floor;
        if (scaled >= scale + 1) {
            floor = scale;
            frac = 1;
        }
        const i: usize = @intFromFloat(floor);
        const lo = p.lut[i];
        const hi = p.lut[i + 1];
        return std.math.clamp(@mulAdd(f32, hi - lo, frac, lo), 0, 1);
    }
};

/// Eight XorShift128+ generators, their state seeded by SplitMix64 from
/// the frame's indices and a group's position.
const Rng = struct {
    s0: [8]u64,
    s1: [8]u64,

    fn splitMix(v: u64) u64 {
        var z = (v ^ (v >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn init(a: u32, b: u32, c: u32, d: u32) Rng {
        var r: Rng = undefined;
        r.s0[0] = splitMix(((@as(u64, a) << 32) +% b) +% 0x9E3779B97F4A7C15);
        r.s1[0] = splitMix(((@as(u64, c) << 32) +% d) +% 0x9E3779B97F4A7C15);
        for (1..8) |i| {
            r.s0[i] = splitMix(r.s0[i - 1]);
            r.s1[i] = splitMix(r.s1[i - 1]);
        }
        return r;
    }

    /// Sixteen floats in [1, 2): 23 random bits of mantissa each, from the
    /// low then high half of each generator's output.
    fn fill(r: *Rng, out: *[16]f32) void {
        for (0..8) |i| {
            var s1 = r.s0[i];
            const s0 = r.s1[i];
            const bits = s1 +% s0;
            r.s0[i] = s0;
            s1 ^= s1 << 23;
            s1 ^= s0 ^ (s1 >> 18) ^ (s0 >> 5);
            r.s1[i] = s1;
            out[2 * i] = @bitCast(@as(u32, @truncate(bits)) >> 9 | 0x3F800000);
            out[2 * i + 1] = @bitCast(@as(u32, @truncate(bits >> 32)) >> 9 | 0x3F800000);
        }
    }

    /// Fills the `w` by `h` rectangle of `plane` (rows of `stride`) at
    /// `x0`, `y0`, row by row, sixteen at a time: every row takes a fresh
    /// batch for its last (or only) part, even an empty row.
    fn image(r: *Rng, plane: []f32, stride: usize, x0: usize, y0: usize, w: usize, h: usize) void {
        var batch: [16]f32 = undefined;
        for (0..h) |y| {
            const row = plane[(y0 + y) * stride + x0 ..][0..w];
            var x: usize = 0;
            while (x + 16 < w) : (x += 16) {
                r.fill(&batch);
                @memcpy(row[x..][0..16], &batch);
            }
            r.fill(&batch);
            @memcpy(row[x..], batch[0 .. w - x]);
        }
    }
};

fn mirror(v: isize, size: usize) usize {
    var x = v;
    const n: isize = @intCast(size);
    while (x < 0 or x >= n) {
        x = if (x < 0) -x - 1 else 2 * n - 1 - x;
    }
    return @intCast(x);
}

pub const Frame = struct {
    /// The frame's size after upsampling, the group size and how many
    /// groups across, and the upsampling factor.
    w: usize,
    h: usize,
    group_dim: usize,
    groups_x: usize,
    groups_y: usize,
    upsampling: usize,
    /// The counts of frames shown before this one (counting it, if it is
    /// shown) and of frames not shown since.
    visible: u32,
    nonvisible: u32,
};

/// Adds the noise to the X, Y, and B planes (`w` by `h`, rows of
/// `stride`), with chroma from luma factors `ytox` and `ytob`.
pub fn apply(
    arena: *Arena,
    p: *const Params,
    f: Frame,
    planes: [3][]f32,
    stride: usize,
    ytox: f32,
    ytob: f32,
) Error!void {
    if (!p.hasAny()) return;
    const m = arena.mark();
    defer arena.release(m);
    const w = f.w;
    const h = f.h;
    var rnd: [3][]f32 = undefined;
    for (&rnd) |*r| r.* = try arena.alloc(f32, w * h);
    // Each group, upsampled, is `upsampling` squared generators' worth.
    const gd = f.group_dim;
    for (0..f.groups_y) |gy| {
        for (0..f.groups_x) |gx| {
            const gx1 = @min(w, (gx + 1) * gd * f.upsampling);
            const gy1 = @min(h, (gy + 1) * gd * f.upsampling);
            for (0..f.upsampling) |iy| {
                for (0..f.upsampling) |ix| {
                    const x0 = (gx * f.upsampling + ix) * gd;
                    const y0 = (gy * f.upsampling + iy) * gd;
                    const rw = if (x0 >= gx1) 0 else @min(gd, gx1 - x0);
                    const rh = if (y0 >= gy1) 0 else @min(gd, gy1 - y0);
                    var rng: Rng = .init(f.visible, f.nonvisible, @intCast(x0), @intCast(y0));
                    for (rnd) |r| rng.image(r, w, @min(x0, w), @min(y0, h), rw, rh);
                }
            }
        }
    }
    // The high-pass convolution, through a ring of five mirrored rows per
    // plane, then the noise added row by row.
    const row_len = w + 4;
    const ring = try arena.alloc(f32, 3 * 5 * row_len);
    const conv = try arena.alloc(f32, 3 * w);
    for (0..3) |c| {
        for (0..4) |i| loadRow(ring[c * 5 * row_len ..], row_len, rnd[c], w, h, @as(isize, @intCast(i)) - 2);
    }
    for (0..h) |y| {
        for (0..3) |c| {
            const rg = ring[c * 5 * row_len ..][0 .. 5 * row_len];
            loadRow(rg, row_len, rnd[c], w, h, @as(isize, @intCast(y)) + 2);
            var rows: [5][]const f32 = undefined;
            for (&rows, 0..) |*r, i| {
                const v: isize = @as(isize, @intCast(y + i)) - 2;
                r.* = rg[@as(usize, @intCast(@mod(v, 5))) * row_len ..][0..row_len];
            }
            for (conv[c * w ..][0..w], 0..) |*o, x| {
                const xi = x + 2;
                var others: f32 = 0;
                for (0..5) |i| {
                    others += rows[0][xi + i - 2];
                    others += rows[1][xi + i - 2];
                    others += rows[3][xi + i - 2];
                    others += rows[4][xi + i - 2];
                }
                others += rows[2][xi - 2];
                others += rows[2][xi - 1];
                others += rows[2][xi + 1];
                others += rows[2][xi + 2];
                o.* = @mulAdd(f32, others, 0.16, rows[2][xi] * -3.84);
            }
        }
        const px = planes[0][y * stride ..][0..w];
        const py = planes[1][y * stride ..][0..w];
        const pb = planes[2][y * stride ..][0..w];
        for (px, py, pb, 0..) |*vx, *vy, *vb, x| {
            const norm = 0.22;
            const nr = conv[x] * norm;
            const ng = conv[w + x] * norm;
            const nc = conv[2 * w + x] * norm;
            const str_g = p.strength((vy.* - vx.*) * 0.5);
            const str_r = p.strength((vy.* + vx.*) * 0.5);
            const corr = 0.9921875; // 127/128
            const ncorr = 0.0078125; // 1/128
            const red = str_r * @mulAdd(f32, ncorr, nr, corr * nc);
            const green = str_g * @mulAdd(f32, ncorr, ng, corr * nc);
            const rg = red + green;
            vx.* = @mulAdd(f32, ytox, rg, red - green) + vx.*;
            vy.* = vy.* + rg;
            vb.* = @mulAdd(f32, ytob, rg, vb.*);
        }
    }
}

fn loadRow(ring: []f32, row_len: usize, src: []const f32, w: usize, h: usize, v: isize) void {
    const dst = ring[@as(usize, @intCast(@mod(v, 5))) * row_len ..][0..row_len];
    const s = src[mirror(v, h) * w ..][0..w];
    @memcpy(dst[2..][0..w], s);
    for (0..2) |i| {
        dst[1 - i] = s[mirror(-1 - @as(isize, @intCast(i)), w)];
        dst[2 + w + i] = s[mirror(@as(isize, @intCast(w + i)), w)];
    }
}
