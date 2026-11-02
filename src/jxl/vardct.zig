//! VarDCT frames (ISO/IEC 18181-1, the VarDCT parts of LfGlobal, LfGroup,
//! HfGlobal, and the pass groups): the quantizer, block contexts, and
//! chroma from luma; each LF group's quantized LF image and HF metadata
//! (block transforms, quantization field, chroma-from-luma factors, EPF
//! sharpness); the dequantization tables, coefficient orders, and HF
//! histograms; then each group's coefficients, dequantized and transformed
//! into three float planes (X, Y, B, or Y, Cb, Cr) of the frame.

const std = @import("std");
const testing = std.testing;

const BitReader = @import("BitReader.zig");
const entropy = @import("entropy.zig");
const Arena = @import("Arena.zig");
const headers = @import("headers.zig");
const modular = @import("modular.zig");
const quant = @import("quant.zig");
const dct = @import("dct.zig");
const filters = @import("filters.zig");
const Strategy = dct.Strategy;

pub const Error = modular.Error || headers.Error;

const num_orders = 13;
const nonzero_buckets = 37;
const zero_density_contexts = 458;
const max_passes = 11;
/// Blocks of a pass group, which is 256 pixels square in VarDCT.
const group_blocks = 32;
const quant_max = 256;
const unset: u8 = 0xff;

const coeff_freq_context = [64]u16{
    0,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
};
const coeff_num_nonzero_context = [64]u16{
    0,   0,   31,  62,  62,  93,  93,  93,  93,  123, 123, 123, 123, 152, 152, 152,
    152, 152, 152, 152, 152, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180,
    180, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
};
const default_ctx_map = [3 * num_orders]u8{
    0, 1, 2, 2, 3,  3,  4,  5,  6,  6,  6,  6,  6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
};

/// The block contexts: thresholds on the quantized LF and the quantization
/// field, and the map from (channel, order, thresholds) to a context.
const BlockCtx = struct {
    dc_thr: [3][15]i32 = undefined,
    n_dc: [3]u32 = .{ 0, 0, 0 },
    qf_thr: [15]u32 = undefined,
    n_qf: u32 = 0,
    map: []const u8 = &default_ctx_map,
    num_ctxs: u32 = 15,
    num_dc_ctxs: u32 = 1,

    fn read(br: *BitReader, arena: *Arena) Error!BlockCtx {
        var b: BlockCtx = .{};
        if (try br.boolean()) return b;
        b.num_dc_ctxs = 1;
        for (0..3) |j| {
            b.n_dc[j] = try br.bits(4);
            b.num_dc_ctxs *= b.n_dc[j] + 1;
            for (b.dc_thr[j][0..b.n_dc[j]]) |*t| {
                t.* = headers.unpackSigned(try br.u32Dist(.{ .b(4), .bo(8, 16), .bo(16, 272), .bo(32, 65808) }));
            }
        }
        b.n_qf = try br.bits(4);
        for (b.qf_thr[0..b.n_qf]) |*t| t.* = try br.u32Dist(.{ .b(2), .bo(3, 4), .bo(5, 12), .bo(8, 44) }) + 1;
        if (b.num_dc_ctxs * (b.n_qf + 1) > 64) return error.BadImage;
        const map = try arena.alloc(u8, 3 * num_orders * b.num_dc_ctxs * (b.n_qf + 1));
        b.num_ctxs = try entropy.readContextMap(br, arena, map);
        if (b.num_ctxs > 16) return error.BadImage;
        b.map = map;
        return b;
    }

    fn context(b: *const BlockCtx, dc_idx: u32, qf: i32, ord: u32, c: usize) u32 {
        var qf_idx: u32 = 0;
        for (b.qf_thr[0..b.n_qf]) |t| {
            if (qf > t) qf_idx += 1;
        }
        var idx: u32 = if (c < 2) @intCast(c ^ 1) else 2;
        idx = idx * num_orders + ord;
        idx = idx * (b.n_qf + 1) + qf_idx;
        idx = idx * b.num_dc_ctxs + dc_idx;
        return b.map[idx];
    }

    fn numAcContexts(b: *const BlockCtx) u32 {
        return b.num_ctxs * (nonzero_buckets + zero_density_contexts);
    }
};

/// One frame's VarDCT state, in work memory.
pub const Shared = struct {
    bw: usize,
    bh: usize,
    /// LF groups across, and their size in blocks.
    lf_groups_x: usize,
    lf_dim: usize,
    groups_x: usize,
    num_groups: usize,
    passes: *const headers.Passes,
    x_dm: f32,
    b_dm: f32,
    quant_bias: [3]f32,
    quant_bias_numerator: f32,

    global_scale: u32 = 0,
    quant_lf: u32 = 0,
    mul_lf: [3]f32 = undefined,
    block_ctx: BlockCtx = .{},
    color_factor: u32 = 84,
    base_x: f32 = 0,
    base_b: f32 = 1,
    lf_cfl: [3]f32 = .{ 0, 0, 0 },
    /// Each channel's chroma subsampling shifts.
    hs: [3]u5,
    vs: [3]u5,

    /// The dequantized LF image, three planes of `bw * bh`.
    lf: [3][]f32,
    /// Per block: the LF context bucket, the strategy (`raw << 1 | first`,
    /// or `unset`), the quantization field, and the EPF sharpness.
    qdc: []u8,
    acs: []u8,
    qf: []i32,
    sharp: []u8,
    /// Chroma from luma factors per 64-pixel tile.
    cfl_x: []i8,
    cfl_b: []i8,
    tiles_x: usize,
    used_acs: u32 = 0,

    mults: [quant.num_tables][]f32 = @splat(&.{}),
    num_histograms: u32 = 1,
    /// Per pass and order class, the three channels' coefficient orders.
    orders: [max_passes][num_orders][]u16 = undefined,
    codes: [max_passes]entropy.Code = undefined,
    /// Coefficients kept between passes, per group, when there are
    /// several passes.
    coeffs: []i32 = &.{},
    passes_done: []u8 = &.{},

    /// The frame's pixels before the filters: three planes of `bw * 8`
    /// by `bh * 8`.
    planes: [3][]f32,

    pub fn init(
        arena: *Arena,
        image: *const headers.ImageHeader,
        fh: *const headers.FrameHeader,
        d: *const headers.Dims,
    ) Error!*Shared {
        const s = try arena.create(Shared);
        const bw: usize = d.xsize_blocks;
        const bh: usize = d.ysize_blocks;
        const n = bw * bh;
        const tx = (bw + 7) / 8;
        const ty = (bh + 7) / 8;
        s.* = .{
            .bw = bw,
            .bh = bh,
            .lf_groups_x = d.xsize_lf_groups,
            .lf_dim = d.group_dim,
            .groups_x = d.xsize_groups,
            .num_groups = d.num_groups,
            .passes = &fh.passes,
            .x_dm = std.math.pow(f32, 0.8, @as(f32, @floatFromInt(fh.x_qm_scale)) - 2),
            .b_dm = std.math.pow(f32, 0.8, @as(f32, @floatFromInt(fh.b_qm_scale)) - 2),
            .quant_bias = image.opsin.quant_bias,
            .quant_bias_numerator = image.opsin.quant_bias_numerator,
            .lf = undefined,
            .qdc = try arena.alloc(u8, n),
            .acs = try arena.alloc(u8, n),
            .qf = try arena.alloc(i32, n),
            .sharp = try arena.alloc(u8, n),
            .cfl_x = try arena.alloc(i8, tx * ty),
            .cfl_b = try arena.alloc(i8, tx * ty),
            .tiles_x = tx,
            .planes = undefined,
            .hs = .{ @intCast(fh.hShift(0)), @intCast(fh.hShift(1)), @intCast(fh.hShift(2)) },
            .vs = .{ @intCast(fh.vShift(0)), @intCast(fh.vShift(1)), @intCast(fh.vShift(2)) },
        };
        if (!image.xyb) s.base_b = 0;
        for (&s.lf) |*p| p.* = try arena.alloc(f32, n);
        @memset(s.acs, unset);
        @memset(s.cfl_x, 0);
        @memset(s.cfl_b, 0);
        for (&s.planes) |*p| {
            p.* = try arena.alloc(f32, n * 64);
            @memset(p.*, 0);
        }
        if (fh.passes.num > 1) {
            const gd = group_blocks * 8;
            s.coeffs = try arena.alloc(i32, s.num_groups * gd * gd * 3);
            @memset(s.coeffs, 0);
        }
        s.passes_done = try arena.alloc(u8, s.num_groups);
        @memset(s.passes_done, 0);
        return s;
    }

    fn subsampled(s: *const Shared) bool {
        return s.hs[0] | s.hs[1] | s.hs[2] | s.vs[0] | s.vs[1] | s.vs[2] != 0;
    }

    fn ratioX(s: *const Shared, f: i32) f32 {
        return s.base_x + @as(f32, @floatFromInt(f)) / @as(f32, @floatFromInt(s.color_factor));
    }
    fn ratioB(s: *const Shared, f: i32) f32 {
        return s.base_b + @as(f32, @floatFromInt(f)) / @as(f32, @floatFromInt(s.color_factor));
    }
};

/// The VarDCT part of LfGlobal, after the LF dequantization weights
/// `lf_quant` (and before GlobalModular).
pub fn readLfGlobal(br: *BitReader, arena: *Arena, s: *Shared, lf_quant: [3]f32) Error!void {
    s.global_scale = try br.u32Dist(.{ .bo(11, 1), .bo(11, 2049), .bo(12, 4097), .bo(16, 8193) });
    s.quant_lf = try br.u32Dist(.{ .v(16), .bo(5, 1), .bo(8, 1), .bo(16, 1) });
    const inv_global: f32 = 65536.0 / @as(f32, @floatFromInt(s.global_scale));
    const inv_quant_lf = inv_global / @as(f32, @floatFromInt(s.quant_lf));
    for (&s.mul_lf, lf_quant) |*m, q| m.* = inv_quant_lf * q;
    s.block_ctx = try .read(br, arena);
    // Chroma from luma.
    var ytox: i32 = 0;
    var ytob: i32 = 0;
    if (!try br.boolean()) {
        s.color_factor = try br.u32Dist(.{ .v(84), .v(256), .bo(8, 2), .bo(16, 258) });
        s.base_x = try br.f16Field();
        if (@abs(s.base_x) > 4) return error.BadImage;
        s.base_b = try br.f16Field();
        if (@abs(s.base_b) > 4) return error.BadImage;
        ytox = @as(i32, @intCast(try br.bits(8))) - 128;
        ytob = @as(i32, @intCast(try br.bits(8))) - 128;
    }
    s.lf_cfl = .{ s.ratioX(ytox), 0, s.ratioB(ytob) };
}

pub const Rect = struct { x0: usize, y0: usize, w: usize, h: usize };

/// LF group `g`'s rectangle in blocks.
pub fn lfRect(s: *const Shared, g: usize) Rect {
    const x0 = (g % s.lf_groups_x) * s.lf_dim;
    const y0 = (g / s.lf_groups_x) * s.lf_dim;
    return .{ .x0 = x0, .y0 = y0, .w = @min(s.lf_dim, s.bw - x0), .h = @min(s.lf_dim, s.bh - y0) };
}

/// Takes an LF frame's output (`w` by `h`) as the dequantized LF, with
/// every block in the first LF context.
pub fn takeLf(s: *Shared, planes: [3][]const f32, w: usize, h: usize) Error!void {
    if (w != s.bw or h != s.bh or s.subsampled()) return error.BadImage;
    for (s.lf, planes) |dst, src| @memcpy(dst, src[0 .. w * h]);
    @memset(s.qdc, 0);
}

/// The quantized LF of LF group `g`, at the start of its section.
pub fn readLf(
    br: *BitReader,
    arena: *Arena,
    s: *Shared,
    g: usize,
    tree: ?*const modular.Tree,
    bitdepth: u32,
) Error!void {
    const r = lfRect(s, g);
    const m = arena.mark();
    defer arena.release(m);
    const extra = try br.bits(2);
    const mul = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << @intCast(extra)));
    var img: modular.Image = try .init(arena, 3, @intCast(r.w), @intCast(r.h), bitdepth);
    // Channels Y, X, B, each at its subsampling.
    const mc = [3]usize{ 1, 0, 2 };
    for (0..3) |c| {
        img.buf[mc[c]].w = @intCast(r.w >> s.hs[c]);
        img.buf[mc[c]].h = @intCast(r.h >> s.vs[c]);
    }
    var dims: [3][2]usize = undefined;
    for (&dims, img.channels()) |*d, c| d.* = .{ c.w, c.h };
    try modular.decodeStream(br, arena, &img, @intCast(1 + g), .{ .global = tree });
    if (img.len != 3) return error.BadImage;
    for (dims, img.channels()) |d, c| if (c.w != d[0] or c.h != d[1]) return error.BadImage;
    const qy = &img.buf[0];
    const qx = &img.buf[1];
    const qb = &img.buf[2];
    const fx = s.mul_lf[0] * mul;
    const fy = s.mul_lf[1] * mul;
    const fb = s.mul_lf[2] * mul;
    const bc = &s.block_ctx;
    if (s.subsampled()) {
        const f = [3]f32{ fx, fy, fb };
        for (0..3) |c| {
            const ch = &img.buf[mc[c]];
            for (0..ch.h) |y| {
                const row = ch.row(y);
                const at = ((r.y0 >> s.vs[c]) + y) * s.bw + (r.x0 >> s.hs[c]);
                for (s.lf[c][at..][0..ch.w], row[0..ch.w]) |*o, v| o.* = @as(f32, @floatFromInt(v)) * f[c];
            }
        }
        for (0..r.h) |y| {
            const rx = qx.row(y >> s.vs[0]);
            const ry = qy.row(y >> s.vs[1]);
            const rb = qb.row(y >> s.vs[2]);
            for (0..r.w) |x| {
                var bx: u32 = 0;
                var by: u32 = 0;
                var bb: u32 = 0;
                for (bc.dc_thr[0][0..bc.n_dc[0]]) |t| bx += @intFromBool(rx[x >> s.hs[0]] > t);
                for (bc.dc_thr[1][0..bc.n_dc[1]]) |t| by += @intFromBool(ry[x >> s.hs[1]] > t);
                for (bc.dc_thr[2][0..bc.n_dc[2]]) |t| bb += @intFromBool(rb[x >> s.hs[2]] > t);
                s.qdc[(r.y0 + y) * s.bw + r.x0 + x] = @intCast((bx * (bc.n_dc[2] + 1) + bb) * (bc.n_dc[1] + 1) + by);
            }
        }
        return;
    }
    for (0..r.h) |y| {
        const rx = qx.row(y);
        const ry = qy.row(y);
        const rb = qb.row(y);
        const at = (r.y0 + y) * s.bw + r.x0;
        for (0..r.w) |x| {
            const vy = @as(f32, @floatFromInt(ry[x])) * fy;
            s.lf[1][at + x] = vy;
            s.lf[0][at + x] = @as(f32, @floatFromInt(rx[x])) * fx + vy * s.lf_cfl[0];
            s.lf[2][at + x] = @as(f32, @floatFromInt(rb[x])) * fb + vy * s.lf_cfl[2];
            var bx: u32 = 0;
            var by: u32 = 0;
            var bb: u32 = 0;
            for (bc.dc_thr[0][0..bc.n_dc[0]]) |t| bx += @intFromBool(rx[x] > t);
            for (bc.dc_thr[1][0..bc.n_dc[1]]) |t| by += @intFromBool(ry[x] > t);
            for (bc.dc_thr[2][0..bc.n_dc[2]]) |t| bb += @intFromBool(rb[x] > t);
            s.qdc[at + x] = @intCast((bx * (bc.n_dc[2] + 1) + bb) * (bc.n_dc[1] + 1) + by);
        }
    }
}

/// LF group `g`'s HF metadata, at the end of its section.
pub fn readHfMeta(
    br: *BitReader,
    arena: *Arena,
    s: *Shared,
    g: usize,
    num_lf_groups: usize,
    tree: ?*const modular.Tree,
    bitdepth: u32,
) Error!void {
    const r = lfRect(s, g);
    const m = arena.mark();
    defer arena.release(m);
    const upper = r.w * r.h;
    const count: u32 = try br.bits(@intCast(std.math.log2_int_ceil(usize, upper))) + 1;
    const cw = (r.w + 7) / 8;
    const ch = (r.h + 7) / 8;
    var img: modular.Image = try .init(arena, 4, 0, 0, bitdepth);
    img.buf[0] = .{ .w = @intCast(cw), .h = @intCast(ch), .hshift = 3, .vshift = 3 };
    img.buf[1] = .{ .w = @intCast(cw), .h = @intCast(ch), .hshift = 3, .vshift = 3 };
    img.buf[2] = .{ .w = count, .h = 2 };
    img.buf[3] = .{ .w = @intCast(r.w), .h = @intCast(r.h) };
    try modular.decodeStream(br, arena, &img, @intCast(1 + 2 * num_lf_groups + g), .{ .global = tree });
    if (img.len != 4) return error.BadImage;
    if (img.buf[0].w != cw or img.buf[0].h != ch or img.buf[1].w != cw or img.buf[1].h != ch) return error.BadImage;
    if (img.buf[2].w != count or img.buf[2].h != 2 or img.buf[3].w != r.w or img.buf[3].h != r.h) return error.BadImage;
    for (0..ch) |y| {
        for (0..cw) |x| {
            const at = (r.y0 / 8 + y) * s.tiles_x + r.x0 / 8 + x;
            s.cfl_x[at] = @intCast(std.math.clamp(img.buf[0].row(y)[x], -128, 127));
            s.cfl_b[at] = @intCast(std.math.clamp(img.buf[1].row(y)[x], -128, 127));
        }
    }
    const strategies = img.buf[2].row(0);
    const quants = img.buf[2].row(1);
    var num: usize = 0;
    for (0..r.h) |iy| {
        const y = r.y0 + iy;
        const sharp = img.buf[3].row(iy);
        for (0..r.w) |ix| {
            const x = r.x0 + ix;
            const at = y * s.bw + x;
            if (sharp[ix] < 0 or sharp[ix] >= 8) return error.BadImage;
            s.sharp[at] = @intCast(sharp[ix]);
            if (s.acs[at] != unset) continue;
            if (num >= count) return error.BadImage;
            const raw = strategies[num];
            if (raw < 0 or raw >= Strategy.count) return error.BadImage;
            const st: Strategy = @enumFromInt(raw);
            s.used_acs |= @as(u32, 1) << @intCast(raw);
            const nx = x + st.bx();
            const ny = y + st.by();
            if (nx > (x / group_blocks + 1) * group_blocks or nx > r.x0 + r.w) return error.BadImage;
            if (ny > (y / group_blocks + 1) * group_blocks or ny > r.y0 + r.h) return error.BadImage;
            for (0..st.by()) |dy| {
                for (0..st.bx()) |dx| {
                    const p = (y + dy) * s.bw + x + dx;
                    if (s.acs[p] != unset) return error.BadImage;
                    s.acs[p] = @as(u8, @intCast(raw)) << 1 | @intFromBool(dx == 0 and dy == 0);
                }
            }
            s.qf[at] = 1 + std.math.clamp(quants[num], 0, quant_max - 1);
            num += 1;
        }
    }
}

/// Smooths the LF image where it is flat (the adaptive LF smoothing),
/// once every LF group is in.
pub fn smoothLf(arena: *Arena, s: *Shared) Error!void {
    const w = s.bw;
    const h = s.bh;
    if (w <= 2 or h <= 2) return;
    const m = arena.mark();
    defer arena.release(m);
    // Three rows of each plane, the originals around the row smoothed.
    const rows = try arena.alloc(f32, 3 * 3 * w);
    const w1: f32 = 0.20345139757231578;
    const w2: f32 = 0.0334829185968739;
    const w0: f32 = 1.0 - 4.0 * (w1 + w2);
    for (0..3) |c| {
        @memcpy(rows[(c * 3 + 0) * w ..][0..w], s.lf[c][0..w]);
        @memcpy(rows[(c * 3 + 1) * w ..][0..w], s.lf[c][w..][0..w]);
    }
    for (1..h - 1) |y| {
        for (0..3) |c| @memcpy(rows[(c * 3 + (y + 1) % 3) * w ..][0..w], s.lf[c][(y + 1) * w ..][0..w]);
        for (1..w - 1) |x| {
            var mc: [3]f32 = undefined;
            var sm: [3]f32 = undefined;
            var gap: f32 = 0.5;
            for (0..3) |c| {
                const t = rows[(c * 3 + (y - 1) % 3) * w ..][0..w];
                const r = rows[(c * 3 + y % 3) * w ..][0..w];
                const b = rows[(c * 3 + (y + 1) % 3) * w ..][0..w];
                mc[c] = r[x];
                const corner = (t[x - 1] + t[x + 1]) + (b[x - 1] + b[x + 1]);
                const side = (r[x - 1] + r[x + 1]) + (t[x] + b[x]);
                sm[c] = corner * w2 + (side * w1 + mc[c] * w0);
                gap = @max(gap, @abs((mc[c] - sm[c]) / s.mul_lf[c]));
            }
            const factor = @max(0, 3.0 - 4.0 * gap);
            for (0..3) |c| s.lf[c][y * w + x] = (sm[c] - mc[c]) * factor + mc[c];
        }
    }
}

/// Reads HfGlobal: the dequantization tables, the histogram count, and
/// each pass's coefficient orders and histograms.
pub fn readHfGlobal(
    br: *BitReader,
    arena: *Arena,
    s: *Shared,
    tree: ?*const modular.Tree,
    num_lf_groups: usize,
) Error!void {
    var enc: [quant.num_tables]quant.Encoding = undefined;
    try quant.read(br, arena, .{ .tree = tree, .first_stream = @intCast(1 + 3 * num_lf_groups) }, &enc);
    for (0..Strategy.count) |k| {
        if (s.used_acs & (@as(u32, 1) << @intCast(k)) == 0) continue;
        const t = Strategy.quant_table[k];
        if (s.mults[t].len != 0) continue;
        const len = 3 * 64 * @as(usize, quant.size_x[t]) * quant.size_y[t];
        s.mults[t] = try arena.alloc(f32, len);
        try quant.multipliers(&enc[t], t, s.mults[t]);
    }
    const nbits: u6 = @intCast(std.math.log2_int_ceil(usize, s.num_groups));
    s.num_histograms = 1 + try br.bits(nbits);
    for (0..s.passes.num) |p| {
        const used_orders = try br.u32Dist(.{ .v(0x5F), .v(0x13), .v(0), .b(13) });
        try readOrders(br, arena, s, p, used_orders);
        const n = s.num_histograms * s.block_ctx.numAcContexts();
        s.codes[p] = try entropy.Code.read(br, arena, n);
    }
}

fn permContext(v: u32) usize {
    if (v == 0) return 0;
    return @min(7, 1 + std.math.log2_int(u32, v));
}

fn readOrders(br: *BitReader, arena: *Arena, s: *Shared, pass: usize, used_orders: u32) Error!void {
    // Which order classes the frame's strategies use.
    var used_classes: u32 = 0;
    for (0..Strategy.count) |k| {
        if (s.used_acs & (@as(u32, 1) << @intCast(k)) == 0) continue;
        used_classes |= @as(u32, 1) << @intCast(Strategy.order_class[k]);
    }
    var code: entropy.Code = undefined;
    var reader: entropy.Reader = undefined;
    if (used_orders != 0) {
        code = try entropy.Code.read(br, arena, 8);
        reader = try .init(&code, br, arena, 0, 1 << 20);
    }
    var done: u32 = 0;
    for (0..Strategy.count) |k| {
        const ord = Strategy.order_class[k];
        if (done & (@as(u32, 1) << @intCast(ord)) != 0) continue;
        done |= @as(u32, 1) << @intCast(ord);
        const st: Strategy = @enumFromInt(k);
        const size = 64 * @as(usize, st.covered());
        const used = used_classes & (@as(u32, 1) << @intCast(ord)) != 0;
        const coded = used_orders & (@as(u32, 1) << @intCast(ord)) != 0;
        s.orders[pass][ord] = &.{};
        if (!used and !coded) continue;
        var out: []u16 = &.{};
        if (used) out = try arena.alloc(u16, 3 * size);
        const m = arena.mark();
        defer arena.release(m);
        const nat = try arena.alloc(u32, size);
        dct.naturalOrder(st, nat);
        if (coded) {
            const perm = try arena.alloc(u32, size);
            const tree = try arena.alloc(u32, size);
            for (0..3) |c| {
                try readCoeffPermutation(br, &reader, st.covered(), perm, tree);
                // order[k] = natural[perm[k]].
                if (used) for (out[c * size ..][0..size], perm) |*o, pk| {
                    o.* = @intCast(nat[pk]);
                };
            }
        } else {
            for (0..3) |c| for (out[c * size ..][0..size], nat) |*o, n| {
                o.* = @intCast(n);
            };
        }
        s.orders[pass][ord] = out;
    }
    if (used_orders != 0 and !reader.finalOk()) return error.BadEntropy;
}

/// Reads one channel's coefficient permutation into `perm` (the first
/// `skip` entries stay in place), with `tree` as scratch of `perm.len`.
fn readCoeffPermutation(br: *BitReader, r: *entropy.Reader, skip: usize, perm: []u32, tree: []u32) Error!void {
    const size = perm.len;
    const end = @as(usize, try r.read(br, permContext(@intCast(size)))) + skip;
    if (end > size) return error.BadImage;
    // perm holds Lehmer codes first.
    @memset(perm, 0);
    var last: u32 = 0;
    for (skip..end) |i| {
        const l = try r.read(br, permContext(last));
        last = l;
        if (l >= size - i) return error.BadImage;
        perm[i] = l;
    }
    decodeLehmer(perm, tree);
}

/// Replaces the Lehmer code in `perm` with its permutation: each entry
/// picks the entry-th smallest value not yet picked, which the bound
/// checks above keep in range. A Fenwick tree over the values still free
/// finds each in log time, where scanning would take quadratic time on a
/// 256x256 transform's 65536 coefficients.
fn decodeLehmer(perm: []u32, tree: []u32) void {
    const n = perm.len;
    // tree[i - 1] counts the free values in (i - lowbit(i), i]; all are free.
    for (tree, 1..) |*t, i| t.* = @intCast(i & (~i +% 1));
    const top = if (n == 0) 0 else @as(usize, 1) << @intCast(std.math.log2_int(usize, n));
    for (perm) |*p| {
        // The largest position whose prefix of free values is at most the
        // code, which is the picked value.
        var rem = p.*;
        var pos: usize = 0;
        var step = top;
        while (step > 0) : (step >>= 1) {
            if (pos + step <= n and tree[pos + step - 1] <= rem) {
                pos += step;
                rem -= tree[pos - 1];
            }
        }
        p.* = @intCast(pos);
        var i = pos + 1;
        while (i <= n) : (i += i & (~i +% 1)) tree[i - 1] -= 1;
    }
}

/// Pass group `g`'s rectangle in blocks.
fn groupRect(s: *const Shared, g: usize) Rect {
    const x0 = (g % s.groups_x) * group_blocks;
    const y0 = (g / s.groups_x) * group_blocks;
    return .{ .x0 = x0, .y0 = y0, .w = @min(group_blocks, s.bw - x0), .h = @min(group_blocks, s.bh - y0) };
}

/// Decodes pass `pass` of group `g`'s coefficients, and once the group has
/// every pass, its pixels.
pub fn readPassGroup(br: *BitReader, arena: *Arena, s: *Shared, pass: usize, g: usize) Error!void {
    if (s.passes_done[g] != pass) return error.Unsupported;
    const r = groupRect(s, g);
    const m = arena.mark();
    defer arena.release(m);
    const hbits: u6 = @intCast(std.math.log2_int_ceil(u32, s.num_histograms));
    const histo = if (hbits == 0) 0 else try br.bits(hbits);
    if (histo >= s.num_histograms) return error.BadImage;
    const code = &s.codes[pass];
    var reader: entropy.Reader = try .init(code, br, arena, 0, 3 * r.w * r.h * 64);
    const ctx_offset = histo * s.block_ctx.numAcContexts();
    const nz = try arena.alloc(i32, 3 * r.w * r.h);
    const last = pass + 1 == s.passes.num;
    const keep = s.coeffs.len != 0;
    const gsize = group_blocks * group_blocks * 64;
    const q = try arena.alloc(i32, 3 * 64 * 1024);
    const scratch = try arena.alloc(f32, 3 * 64 * 1024 + 2 * 64 * 1024);
    var offset: usize = 0;
    for (0..r.h) |by| {
        var bx: usize = 0;
        while (bx < r.w) {
            const at = (r.y0 + by) * s.bw + r.x0 + bx;
            const a = s.acs[at];
            if (a == unset) return error.BadImage;
            const st: Strategy = @enumFromInt(a >> 1);
            if (a & 1 == 0) {
                bx += st.bx();
                continue;
            }
            const size = 64 * @as(usize, st.covered());
            var blocks: [3][]i32 = undefined;
            for (0..3) |c| {
                if (keep) {
                    blocks[c] = s.coeffs[(g * 3 + c) * gsize + offset ..][0..size];
                } else {
                    blocks[c] = q[c * size ..][0..size];
                    @memset(blocks[c], 0);
                }
            }
            const shift: u5 = @intCast(s.passes.shift[pass]);
            for ([3]usize{ 1, 0, 2 }) |c| {
                // A subsampled channel has a block only where its
                // coordinates are a multiple of the subsampling.
                if ((bx >> s.hs[c]) << s.hs[c] != bx or (by >> s.vs[c]) << s.vs[c] != by) continue;
                try decodeBlock(
                    br,
                    &reader,
                    s,
                    code,
                    ctx_offset,
                    nz[c * r.w * r.h ..][0 .. r.w * r.h],
                    r.w,
                    bx >> s.hs[c],
                    by >> s.vs[c],
                    st,
                    at,
                    c,
                    s.orders[pass][Strategy.order_class[a >> 1]],
                    blocks[c],
                    shift,
                );
            }
            offset += size;
            if (last) reconstruct(s, st, r.x0 + bx, r.y0 + by, blocks, scratch);
            bx += st.bx();
        }
    }
    if (!reader.finalOk()) return error.BadEntropy;
    s.passes_done[g] += 1;
}

fn decodeBlock(
    br: *BitReader,
    reader: *entropy.Reader,
    s: *const Shared,
    code: *const entropy.Code,
    ctx_offset: u32,
    nz: []i32,
    stride: usize,
    bx: usize,
    by: usize,
    st: Strategy,
    at: usize,
    c: usize,
    orders: []const u16,
    block: []i32,
    shift: u5,
) Error!void {
    const covered: usize = st.covered();
    const log2c = st.log2Covered();
    const size = covered * 64;
    const ord = Strategy.order_class[@intFromEnum(st)];
    const order = orders[c * size ..][0..size];
    // Predicted non-zeros from the blocks above and to the left.
    var pred: i32 = 32;
    if (bx == 0) {
        if (by > 0) pred = nz[(by - 1) * stride];
    } else if (by == 0) {
        pred = nz[by * stride + bx - 1];
    } else {
        pred = @divTrunc(nz[(by - 1) * stride + bx] + nz[by * stride + bx - 1] + 1, 2);
    }
    const bc = &s.block_ctx;
    const block_ctx = bc.context(s.qdc[at], s.qf[at], ord, c);
    const p: u32 = @intCast(@min(pred, 64));
    const nz_ctx = (if (p < 8) p else 4 + p / 2) * bc.num_ctxs + block_ctx + ctx_offset;
    var nzeros: usize = try readCtx(reader, br, code, nz_ctx);
    if (nzeros > size - covered) return error.BadImage;
    const per_block: i32 = @intCast((nzeros + covered - 1) >> log2c);
    for (0..st.by()) |y| {
        for (0..st.bx()) |x| nz[(by + y) * stride + bx + x] = per_block;
    }
    const histo = ctx_offset + bc.num_ctxs * nonzero_buckets + zero_density_contexts * block_ctx;
    var prev: usize = if (nzeros > size / 16) 0 else 1;
    var k = covered;
    while (k < size and nzeros != 0) : (k += 1) {
        const nl = (nzeros + covered - 1) >> log2c;
        const kk = k >> log2c;
        const ctx = histo + (coeff_num_nonzero_context[@min(nl, 63)] + coeff_freq_context[kk]) * 2 + prev;
        const u = try readCtx(reader, br, code, ctx);
        const mag: i32 = @bitCast(u >> 1);
        const val: i32 = if (u & 1 == 1) -%mag -% 1 else mag;
        block[order[k]] +%= val << shift;
        prev = @intFromBool(u != 0);
        nzeros -= prev;
    }
    if (nzeros != 0) return error.BadImage;
}

/// Reads in context `ctx`, whose cluster is 0 past the map's end.
inline fn readCtx(reader: *entropy.Reader, br: *BitReader, code: *const entropy.Code, ctx: usize) Error!u32 {
    const map = code.context_map;
    const n = map.len - @intFromBool(code.lz77.enabled);
    return reader.readCluster(br, if (ctx < n) map[ctx] else 0);
}

/// Dequantizes a block's coefficients and writes its pixels.
fn reconstruct(s: *Shared, st: Strategy, bx: usize, by: usize, blocks: [3][]i32, scratch: []f32) void {
    const covered: usize = st.covered();
    const size = covered * 64;
    const at = by * s.bw + bx;
    const inv_global: f32 = 65536.0 / @as(f32, @floatFromInt(s.global_scale));
    const scaled = inv_global / @as(f32, @floatFromInt(s.qf[at]));
    const mul = [3]f32{ scaled * s.x_dm, scaled, scaled * s.b_dm };
    const tile = (by / 8) * s.tiles_x + bx / 8;
    const x_cc = s.ratioX(s.cfl_x[tile]);
    const b_cc = s.ratioB(s.cfl_b[tile]);
    const mat = s.mults[Strategy.quant_table[@intFromEnum(st)]];
    const coef = scratch[0 .. 3 * size];
    // Eight coefficients at a time (every size is a multiple of 64).
    const V = @Vector(8, f32);
    const Vi = @Vector(8, i32);
    for (0..3) |c| {
        const mc = mat[c * size ..][0..size];
        const out = coef[c * size ..][0..size];
        const bias: V = @splat(s.quant_bias[c]);
        const num: V = @splat(s.quant_bias_numerator);
        const m: V = @splat(mul[c]);
        var k: usize = 0;
        while (k < size) : (k += 8) {
            const q: Vi = blocks[c][k..][0..8].*;
            const f: V = @floatFromInt(q);
            // adjustBias: 0 stays, +-1 become +-bias, others q - num / q.
            const big = f - num / f;
            const one = @select(f32, q < @as(Vi, @splat(0)), -bias, bias);
            const small = @select(f32, q == @as(Vi, @splat(0)), @as(V, @splat(0)), one);
            const adj = @select(f32, @abs(q) <= @as(@Vector(8, u32), @splat(1)), small, big);
            const w: V = mc[k..][0..8].*;
            out[k..][0..8].* = adj * w * m;
        }
    }
    const xc: V = @splat(x_cc);
    const bcc: V = @splat(b_cc);
    var k: usize = 0;
    while (k < size) : (k += 8) {
        const y: V = coef[size + k ..][0..8].*;
        coef[k..][0..8].* = coef[k..][0..8].* + xc * y;
        coef[2 * size + k ..][0..8].* = coef[2 * size + k ..][0..8].* + bcc * y;
    }
    const stride = s.bw * 8;
    for (0..3) |c| {
        const sbx = bx >> s.hs[c];
        const sby = by >> s.vs[c];
        if (sbx << s.hs[c] != bx or sby << s.vs[c] != by) continue;
        const cc = coef[c * size ..][0..size];
        const lf_at = sby * s.bw + sbx;
        if (covered == 1) {
            cc[0] = s.lf[c][lf_at];
        } else {
            dct.llfFromLf(st, s.lf[c][lf_at..], s.bw, cc);
        }
        const out = s.planes[c][sby * 8 * stride + sbx * 8 ..];
        dct.toPixels(st, cc, out, stride, scratch[3 * size ..]);
    }
}

/// Each block's inverse EPF sigma: a transform's quantization over its
/// blocks, scaled by each block's sharpness.
pub fn epfSigmas(s: *const Shared, rf: *const headers.RestorationFilter, out: []f32) void {
    const quant_scale = @as(f32, @floatFromInt(s.global_scale)) / 65536.0;
    for (0..s.bh) |by| {
        for (0..s.bw) |bx| {
            const a = s.acs[by * s.bw + bx];
            if (a & 1 == 0 or a == unset) continue;
            const st: Strategy = @enumFromInt(a >> 1);
            const q: f32 = @floatFromInt(s.qf[by * s.bw + bx]);
            const sigma_quant = rf.epf_quant_mul / (quant_scale * q * filters.inv_sigma_num);
            for (0..st.by()) |dy| {
                for (0..st.bx()) |dx| {
                    const p = (by + dy) * s.bw + bx + dx;
                    const sigma = @min(-1e-4, sigma_quant * rf.epf_sharp_lut[s.sharp[p]]);
                    out[p] = 1 / sigma;
                }
            }
        }
    }
}

/// Upsamples the subsampled channels to the frame's size, in place:
/// each new pixel is 3/4 of the nearer pixel and 1/4 of the farther, with
/// the edges mirrored at the channel's size, `w` by `h` before shifting.
pub fn upsampleChroma(s: *Shared, w: usize, h: usize) void {
    const stride = s.bw * 8;
    for (0..3) |c| {
        const p = s.planes[c];
        if (s.hs[c] != 0) {
            const n = (w + 1) >> 1;
            const rows = (h + (@as(usize, 1) << s.vs[c]) - 1) >> s.vs[c];
            for (0..rows) |y| {
                const row = p[y * stride ..][0..stride];
                var x = n;
                while (x > 0) {
                    x -= 1;
                    const l = row[if (x == 0) 0 else x - 1];
                    const m = row[x];
                    const r = row[if (x + 1 == n) x else x + 1];
                    if (2 * x + 1 < stride) row[2 * x + 1] = 0.75 * m + 0.25 * r;
                    row[2 * x] = 0.75 * m + 0.25 * l;
                }
            }
        }
        if (s.vs[c] != 0) {
            const n = (h + 1) >> 1;
            const rows = s.bh * 8;
            var y = n;
            while (y > 0) {
                y -= 1;
                const up = p[(if (y == 0) 0 else y - 1) * stride ..][0..stride];
                const mid = p[y * stride ..][0..stride];
                const down = p[(if (y + 1 == n) y else y + 1) * stride ..][0..stride];
                if (2 * y + 1 < rows) {
                    for (p[(2 * y + 1) * stride ..][0..stride], mid, down) |*o, m, d| o.* = 0.75 * m + 0.25 * d;
                }
                for (p[2 * y * stride ..][0..stride], mid, up) |*o, m, u| o.* = 0.75 * m + 0.25 * u;
            }
        }
    }
}

test "Lehmer codes decode as by scanning for the k-th free value" {
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    var code: [300]u32 = undefined;
    var got: [300]u32 = undefined;
    var tree: [300]u32 = undefined;
    var used: [300]bool = undefined;
    for ([_]usize{ 1, 2, 7, 64, 255, 256, 300 }) |n| {
        for (code[0..n], 0..) |*c, i| c.* = if (random.boolean()) 0 else random.uintLessThan(u32, @intCast(n - i));
        @memcpy(got[0..n], code[0..n]);
        decodeLehmer(got[0..n], tree[0..n]);
        @memset(used[0..n], false);
        for (code[0..n], got[0..n]) |c, g| {
            var k = c;
            var v: usize = 0;
            while (used[v] or k > 0) : (v += 1) {
                if (!used[v]) k -= 1;
            }
            used[v] = true;
            try testing.expectEqual(@as(u32, @intCast(v)), g);
        }
    }
}
