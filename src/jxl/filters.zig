//! The restoration filters (ISO/IEC 18181-1, the loop filters): Gaborish,
//! a 3x3 convolution, and the edge-preserving filter's three passes, each
//! over the frame's three color planes in place. Every pass reads the
//! frame mirrored at its edges, through a ring of the rows it still needs.

const std = @import("std");
const testing = std.testing;

const Arena = @import("Arena.zig");
const headers = @import("headers.zig");

pub const Error = Arena.Error;

/// The inverse sigma numerator, and the inverse sigma below which a block
/// is left alone.
pub const inv_sigma_num: f32 = -1.1715728752538099024;
const min_sigma: f32 = -3.90524291751269967465540850526868;

pub const Planes = struct {
    p: [3][]f32,
    stride: usize,
    w: usize,
    h: usize,
};

fn mirror(v: isize, size: usize) usize {
    var x = v;
    const n: isize = @intCast(size);
    while (x < 0 or x >= n) {
        x = if (x < 0) -x - 1 else 2 * n - 1 - x;
    }
    return @intCast(x);
}

/// The original rows `y - r ..= y + r` of the three planes, mirrored at
/// the edges and padded by `r` mirrored columns on each side, while the
/// planes are overwritten row by row.
const Ring = struct {
    r: usize,
    rows: []f32,
    row_len: usize,
    n: usize,

    fn init(arena: *Arena, r: usize, w: usize) Error!Ring {
        const n = 2 * r + 1;
        const row_len = w + 2 * r;
        return .{ .r = r, .rows = try arena.alloc(f32, 3 * n * row_len), .row_len = row_len, .n = n };
    }

    fn slot(g: *const Ring, c: usize, v: isize) []f32 {
        const k: usize = @intCast(@mod(v, @as(isize, @intCast(g.n))));
        return g.rows[(c * g.n + k) * g.row_len ..][0..g.row_len];
    }

    /// Row `v` (virtual, mirrored) of channel `c`, where index `r` is
    /// column 0.
    fn row(g: *const Ring, c: usize, v: isize) []f32 {
        return g.slot(c, v);
    }

    /// Loads virtual row `v` while rows above `next` are overwritten.
    fn load(g: *Ring, pl: *const Planes, v: isize, next: usize) void {
        const m = mirror(v, pl.h);
        for (0..3) |c| {
            const dst = g.slot(c, v);
            if (m >= next) {
                const src = pl.p[c][m * pl.stride ..][0..pl.w];
                @memcpy(dst[g.r..][0..pl.w], src);
                for (0..g.r) |i| {
                    dst[g.r - 1 - i] = src[mirror(-1 - @as(isize, @intCast(i)), pl.w)];
                    dst[g.r + pl.w + i] = src[mirror(@as(isize, @intCast(pl.w + i)), pl.w)];
                }
            } else {
                @memcpy(dst, g.slot(c, @intCast(m)));
            }
        }
    }

    fn start(g: *Ring, pl: *const Planes) void {
        const r: isize = @intCast(g.r);
        var v: isize = -r;
        while (v < r) : (v += 1) g.load(pl, v, 0);
    }

    /// Before writing row `y`.
    fn advance(g: *Ring, pl: *const Planes, y: usize) void {
        g.load(pl, @as(isize, @intCast(y + g.r)), y);
    }
};

pub fn gaborish(arena: *Arena, pl: *const Planes, rf: *const headers.RestorationFilter) Error!void {
    const m = arena.mark();
    defer arena.release(m);
    var ring: Ring = try .init(arena, 1, pl.w);
    ring.start(pl);
    var w: [3][3]f32 = undefined;
    for (0..3) |c| {
        const div = 1 + 4 * (rf.gab_weights[c][0] + rf.gab_weights[c][1]);
        w[c] = .{ 1 / div, rf.gab_weights[c][0] / div, rf.gab_weights[c][1] / div };
    }
    for (0..pl.h) |y| {
        ring.advance(pl, y);
        const yi: isize = @intCast(y);
        for (0..3) |c| {
            const t = ring.row(c, yi - 1)[1..];
            const r = ring.row(c, yi)[1..];
            const b = ring.row(c, yi + 1)[1..];
            const out = pl.p[c][y * pl.stride ..][0..pl.w];
            const tm1 = ring.row(c, yi - 1);
            const rm1 = ring.row(c, yi);
            const bm1 = ring.row(c, yi + 1);
            for (out, 0..) |*o, x| {
                const side = (rm1[x] + r[x + 1]) + (t[x] + b[x]);
                const corner = (tm1[x] + t[x + 1]) + (bm1[x] + b[x + 1]);
                o.* = corner * w[c][2] + (side * w[c][1] + r[x] * w[c][0]);
            }
        }
    }
}

/// The inverse sigma of each block, from the quantization field and the
/// sharpness (VarDCT), or the one Modular value.
pub fn sigmas(
    out: []f32,
    rf: *const headers.RestorationFilter,
    modular: bool,
    quant_scale: f32,
    qf: []const i32,
    sharp: []const u8,
) void {
    if (modular) {
        @memset(out, inv_sigma_num / rf.epf_sigma_for_modular);
        return;
    }
    for (out, qf, sharp) |*o, q, s| {
        const sigma_quant = rf.epf_quant_mul / (quant_scale * @as(f32, @floatFromInt(q)) * inv_sigma_num);
        const sigma = @min(-1e-4, sigma_quant * rf.epf_sharp_lut[s]);
        o.* = 1 / sigma;
    }
}

const lanes = 8;
const V = @Vector(lanes, f32);

/// Pass `pass` (0, 1, or 2) of the edge-preserving filter, with each
/// block's inverse sigma in `inv_sigma` (`bw` per row; multi-block
/// transforms repeat theirs over their blocks). Eight pixels at a time,
/// one block's row: each lane sums its differences in the same order a
/// pixel at a time would.
pub fn epf(
    arena: *Arena,
    pl: *const Planes,
    rf: *const headers.RestorationFilter,
    pass: u32,
    inv_sigma: []const f32,
    bw: usize,
) Error!void {
    const m = arena.mark();
    defer arena.release(m);
    const r: usize = switch (pass) {
        0 => 3,
        1 => 2,
        else => 1,
    };
    // Ring rows padded to whole blocks, so every block reads whole
    // vectors; the padding's values reach only lanes past the edge.
    const w8 = (pl.w + lanes - 1) / lanes * lanes;
    var ring: Ring = try .init(arena, r, w8);
    @memset(ring.rows, 0);
    ring.start(pl);
    const sm: f32 = switch (pass) {
        0 => rf.epf_pass0_sigma_scale * 1.65,
        1 => 1.65,
        else => rf.epf_pass2_sigma_scale * 1.65,
    };
    const bsm = sm * rf.epf_border_sad_mul;
    // The SAD multiplier per lane: the block's border columns, or the
    // whole row on its border rows.
    var inner: V = @splat(sm);
    inner[0] = bsm;
    inner[lanes - 1] = bsm;
    const border: V = @splat(bsm);
    const scale: [3]V = .{
        @splat(rf.epf_channel_scale[0]),
        @splat(rf.epf_channel_scale[1]),
        @splat(rf.epf_channel_scale[2]),
    };
    const ri: isize = @intCast(r);
    const zero: V = @splat(0);
    const one: V = @splat(1);
    for (0..pl.h) |y| {
        ring.advance(pl, y);
        const yi: isize = @intCast(y);
        const mul = if (y % 8 == 0 or y % 8 == 7) border else inner;
        // Rows -3..3 of each channel, each from 3 columns left of x.
        var rows: [3][7][]const f32 = undefined;
        for (0..3) |c| {
            for (0..7) |k| rows[c][k] = &.{};
            var k: isize = -ri;
            while (k <= ri) : (k += 1) rows[c][@intCast(k + 3)] = ring.row(c, yi + k);
        }
        const sig_row = inv_sigma[(y / 8) * bw ..];
        var x: usize = 0;
        while (x < pl.w) : (x += lanes) {
            const n = @min(lanes, pl.w - x);
            const s = sig_row[x / 8];
            const px = x + r;
            if (s < min_sigma) {
                for (0..3) |c| @memcpy(pl.p[c][y * pl.stride + x ..][0..n], rows[c][3][px..][0..n]);
                continue;
            }
            const isg = mul * @as(V, @splat(s));
            const centre: [3]V = .{ load(rows[0][3], px), load(rows[1][3], px), load(rows[2][3], px) };
            var acc = centre;
            var wsum = one;
            switch (pass) {
                0, 1 => {
                    const offs0 = [12][2]i8{
                        .{ -2, 0 },
                        .{ -1, -1 },
                        .{ -1, 0 },
                        .{ -1, 1 },
                        .{ 0, -2 },
                        .{ 0, -1 },
                        .{ 0, 1 },
                        .{ 0, 2 },
                        .{ 1, -1 },
                        .{ 1, 0 },
                        .{ 1, 1 },
                        .{ 2, 0 },
                    };
                    const offs1 = [4][2]i8{ .{ -1, 0 }, .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 } };
                    const offs: []const [2]i8 = if (pass == 0) &offs0 else &offs1;
                    const plus = [5][2]i8{ .{ 0, 0 }, .{ -1, 0 }, .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 } };
                    for (offs) |o| {
                        var sad = zero;
                        for (0..3) |c| {
                            var sc = zero;
                            for (plus) |q| {
                                const a = load(rows[c][@intCast(3 + q[0])], shift(px, q[1]));
                                const b = load(rows[c][@intCast(3 + o[0] + q[0])], shift(px, o[1] + q[1]));
                                sc += @abs(a - b);
                            }
                            sad += sc * scale[c];
                        }
                        const wt = @max(zero, sad * isg + one);
                        wsum += wt;
                        for (0..3) |c| acc[c] += wt * load(rows[c][@intCast(3 + o[0])], shift(px, o[1]));
                    }
                },
                else => {
                    const offs = [4][2]i8{ .{ -1, 0 }, .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 } };
                    for (offs) |o| {
                        var sad = zero;
                        var v: [3]V = undefined;
                        for (0..3) |c| {
                            v[c] = load(rows[c][@intCast(3 + o[0])], shift(px, o[1]));
                            sad += @abs(v[c] - centre[c]) * scale[c];
                        }
                        const wt = @max(zero, sad * isg + one);
                        wsum += wt;
                        for (0..3) |c| acc[c] += wt * v[c];
                    }
                },
            }
            const inv = one / wsum;
            for (0..3) |c| {
                const out: [lanes]f32 = acc[c] * inv;
                @memcpy(pl.p[c][y * pl.stride + x ..][0..n], out[0..n]);
            }
        }
    }
}

inline fn shift(px: usize, d: i8) usize {
    return @intCast(@as(isize, @intCast(px)) + d);
}

inline fn load(row: []const f32, at: usize) V {
    return row[at..][0..lanes].*;
}

test "mirror" {
    try testing.expectEqual(@as(usize, 0), mirror(-1, 5));
    try testing.expectEqual(@as(usize, 1), mirror(-2, 5));
    try testing.expectEqual(@as(usize, 4), mirror(5, 5));
    try testing.expectEqual(@as(usize, 3), mirror(6, 5));
}

test "gaborish keeps a flat image flat" {
    var buf: [3 * 4 * 5]f32 = @splat(0.25);
    var arena: Arena = .init(&(struct {
        var b: [4096]u8 = undefined;
    }).b);
    const pl: Planes = .{ .p = .{ buf[0..20], buf[20..40], buf[40..60] }, .stride = 5, .w = 5, .h = 4 };
    try gaborish(&arena, &pl, &.{});
    for (buf) |v| try testing.expectApproxEqAbs(@as(f32, 0.25), v, 1e-6);
}
