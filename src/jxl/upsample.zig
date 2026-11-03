//! Upsampling (ISO/IEC 18181-1, the frame's upsampling and the extra
//! channels' upsampling): each sample becomes an N by N block, N = 2, 4,
//! or 8, each output a weighted sum of the 5x5 neighbourhood around its
//! source sample, mirrored at the edges, and clamped to that
//! neighbourhood's range.

const std = @import("std");
const testing = std.testing;

const headers = @import("headers.zig");

/// The N*N kernels of 25 weights each, built from the image header's
/// weights for N: one quarter of the kernels is stored, as the upper
/// triangle of a symmetric 5N/2 square, and the others mirror it.
pub const Kernel = struct {
    n: usize,
    k: [64 * 25]f32,

    pub fn init(image: *const headers.ImageHeader, n: usize) Kernel {
        const weights: []const f32 = switch (n) {
            2 => &image.up2,
            4 => &image.up4,
            else => &image.up8,
        };
        var out: Kernel = .{ .n = n, .k = undefined };
        const half = n / 2;
        for (0..half) |ky| {
            for (0..half) |kx| {
                for (0..5) |py| {
                    for (0..5) |px| {
                        const i = 5 * kx + px;
                        const j = 5 * ky + py;
                        const lo = @min(i, j);
                        const hi = @max(i, j);
                        const w = weights[5 * half * lo - lo * (lo + 1) / 2 + hi];
                        out.k[(ky * n + kx) * 25 + py * 5 + px] = w;
                        out.k[(ky * n + n - 1 - kx) * 25 + py * 5 + 4 - px] = w;
                        out.k[((n - 1 - ky) * n + kx) * 25 + (4 - py) * 5 + px] = w;
                        out.k[((n - 1 - ky) * n + n - 1 - kx) * 25 + (4 - py) * 5 + 4 - px] = w;
                    }
                }
            }
        }
        return out;
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

/// Upsamples `src` (`sw` by `sh`, rows of `sstride`) into `dst` (`dw` by
/// `dh`, rows of `dw`), which is at most N times as large each way; what
/// falls past `dw` or `dh` is cropped.
pub fn upsample(
    kern: *const Kernel,
    src: []const f32,
    sw: usize,
    sh: usize,
    sstride: usize,
    dst: []f32,
    dw: usize,
    dh: usize,
) void {
    upsampleRows(kern, src, 0, sw, sh, sstride, 0, sh, dst, dw, dh, dw);
}

/// `upsample` of source rows `y0 .. y1` alone, into `dst`'s rows from
/// output row `y0 * N` (rows of `dstride`), with `src` holding the
/// source's rows from `src_y0`: those within two rows of `y0 .. y1`,
/// mirrored at the source's edges, must be there.
pub fn upsampleRows(
    kern: *const Kernel,
    src: []const f32,
    src_y0: usize,
    sw: usize,
    sh: usize,
    sstride: usize,
    y0: usize,
    y1: usize,
    dst: []f32,
    dw: usize,
    dh: usize,
    dstride: usize,
) void {
    const n = kern.n;
    var cols: [5]usize = undefined;
    var rows: [5][]const f32 = undefined;
    var win: [25]f32 = undefined;
    for (y0..y1) |y| {
        if (y * n >= dh) break;
        for (&rows, 0..) |*r, i| {
            const yy = mirror(@as(isize, @intCast(y + i)) - 2, sh);
            r.* = src[(yy - src_y0) * sstride ..][0..sw];
        }
        for (0..sw) |x| {
            if (x * n >= dw) break;
            for (&cols, 0..) |*c, i| c.* = mirror(@as(isize, @intCast(x + i)) - 2, sw);
            var lo: f32 = std.math.inf(f32);
            var hi: f32 = -std.math.inf(f32);
            for (0..5) |py| {
                for (0..5) |px| {
                    const v = rows[py][cols[px]];
                    win[py * 5 + px] = v;
                    lo = @min(lo, v);
                    hi = @max(hi, v);
                }
            }
            for (0..n) |oy| {
                const yo = y * n + oy;
                if (yo >= dh) break;
                const out = dst[(yo - y0 * n) * dstride ..][0..dw];
                for (0..n) |ox| {
                    const xo = x * n + ox;
                    if (xo >= dw) break;
                    const k = kern.k[(oy * n + ox) * 25 ..][0..25];
                    // In the reference's order: three accumulators over
                    // the weights by index modulo 3, then summed.
                    var acc = [3]f32{ win[0] * k[0], win[1] * k[1], win[2] * k[2] };
                    var i: usize = 3;
                    while (i < 24) : (i += 3) {
                        acc[0] = @mulAdd(f32, win[i], k[i], acc[0]);
                        acc[1] = @mulAdd(f32, win[i + 1], k[i + 1], acc[1]);
                        acc[2] = @mulAdd(f32, win[i + 2], k[i + 2], acc[2]);
                    }
                    acc[0] = @mulAdd(f32, win[24], k[24], acc[0]);
                    out[xo] = std.math.clamp((acc[1] + acc[2]) + acc[0], lo, hi);
                }
            }
        }
    }
}

test "upsampling keeps a flat image flat" {
    const image: headers.ImageHeader = .{};
    const src = [_]f32{0.25} ** (3 * 2);
    var dst: [6 * 4]f32 = undefined;
    for ([_]usize{ 2, 4, 8 }) |n| {
        const k: Kernel = .init(&image, n);
        // Each kernel sums to 1, so the result is the input up to rounding,
        // and the clamp makes it exact.
        for (0..n * n) |i| {
            var sum: f32 = 0;
            for (k.k[i * 25 ..][0..25]) |w| sum += w;
            try testing.expectApproxEqAbs(1, sum, 1e-3);
        }
        upsample(&k, &src, 3, 2, 3, &dst, 6, 4);
        for (dst) |v| try testing.expectEqual(0.25, v);
    }
}
