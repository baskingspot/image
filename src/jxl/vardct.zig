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
const vfill = @import("../fill.zig").fill;
const headers = @import("headers.zig");
const modular = @import("modular.zig");
const quant = @import("quant.zig");
const dct = @import("dct.zig");
const filters = @import("filters.zig");
const zigzag = @import("jbrd.zig").zigzag;
const Strategy = dct.Strategy;
const Decoder = @import("Decoder.zig");

pub const Error = modular.Error || headers.Error || error{
    /// The frame cannot hold a recompressed JPEG (`decodeJpeg`).
    NotJpeg,
};

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

/// Receives a VarDCT frame's quantized coefficients before they are
/// dequantized, for rebuilding a recompressed JPEG from them (the `jbrd`
/// box, ISO/IEC 18181-2): each LF group's quantized LF as its section is
/// read, and each varblock's coefficients once its last pass is in. A
/// frame whose LF comes from an LF frame has no quantized LF to report.
pub const CoeffSink = struct {
    ctx: *anyopaque,
    /// Whether the frame's pixels are made too.
    pixels: bool = true,
    lf: *const fn (ctx: *anyopaque, s: *const Shared, lf: QuantLf) Error!void,
    block: *const fn (ctx: *anyopaque, s: *const Shared, b: QuantBlock) Error!void,
};

/// LF group `rect`'s quantized LF: per channel X, Y, B (Cb, Y, Cr for
/// YCbCr), rows of `rect.w >> Shared.hs[c]` samples, `rect.h >> Shared.vs[c]`
/// of them, scaled up by `1 << extra_precision` over the LF quantization.
pub const QuantLf = struct {
    rect: Rect,
    channels: [3]*const modular.Channel,
    extra_precision: u2,
};

/// A varblock's quantized coefficients, after every pass, in the layout
/// `dct.toPixels` takes: for a transform of `rows` by `cols` coefficients
/// with `rows >= cols`, coefficient (u, v) (vertical frequency u) is at
/// `v * rows + u`, so a DCT8's is transposed from JPEG's natural order;
/// with `rows < cols`, at `u * cols + v`. The lowest frequencies, which
/// the LF holds, are zero. `bx` and `by` are the block's top left in the
/// frame's blocks; a channel subsampled away at this position is null.
pub const QuantBlock = struct {
    strategy: Strategy,
    bx: usize,
    by: usize,
    coeffs: [3]?[]const i32,
    /// The block's quantization field, and its 64-pixel tile's chroma from
    /// luma factors (`Shared.color_factor` is their denominator).
    qf: i32,
    x_factor: i8,
    b_factor: i8,
};

/// A recompressed JPEG's image data, as `Decoder.decodeJpeg` reads it from
/// the codestream for rebuilding the JPEG from its `jbrd` box: per JPEG
/// component (Y, Cb, Cr, which are channels Y, X, B), the sampling, the
/// quantization table, and the quantized coefficients with chroma from
/// luma undone. A grey JPEG is component 0.
pub const Jpeg = struct {
    /// JPEG sampling factors, 1 or 2.
    h: [3]u4,
    v: [3]u4,
    /// Each component's blocks across and down: whole MCUs.
    blocks_x: [3]u32,
    blocks_y: [3]u32,
    /// Each component's quantization table, in natural order.
    quant: [3][64]u16,
    /// Each component's quantized coefficients, 64 a block in zigzag
    /// order (the order a JPEG's scans code them, so the writer reorders
    /// nothing), rows of `blocks_x` blocks.
    coefs: [3][]i16,
    got_quant: bool = false,
    /// Per component and coefficient in zigzag order, the ratio of the
    /// luma and the component's quantization steps in `cfl_bits` fixed
    /// point, which chroma from luma scales by.
    ratio: [3][64]i32 = undefined,

    /// The JPEG component of channels X, Y, B.
    const component = [3]usize{ 1, 0, 2 };
    /// Chroma from luma's fixed-point precision.
    const cfl_bits = 11;

    /// The most coefficients any sampling of a `width` by `height` image
    /// takes: 12 blocks a 16-pixel square (three components unsubsampled).
    pub fn maxCoefs(width: u32, height: u32) usize {
        return @as(usize, (width + 15) / 16) * ((height + 15) / 16) * 12 * 64;
    }

    /// Lays out the coefficients of frame `fh` in `mem`.
    pub fn init(fh: *const headers.FrameHeader, d: *const headers.Dims, mem: []i16) Error!Jpeg {
        const mh: u5 = @intCast(fh.maxHShift());
        const mv: u5 = @intCast(fh.maxVShift());
        var j: Jpeg = .{
            .h = undefined,
            .v = undefined,
            .blocks_x = undefined,
            .blocks_y = undefined,
            .quant = undefined,
            .coefs = undefined,
        };
        var at: usize = 0;
        for (0..3) |c| {
            const jc = component[c];
            const hs: u5 = @intCast(fh.hShift(c));
            const vs: u5 = @intCast(fh.vShift(c));
            j.h[jc] = @intCast(@as(u32, 1) << (mh - hs));
            j.v[jc] = @intCast(@as(u32, 1) << (mv - vs));
            // The frame's blocks are whole MCUs already.
            j.blocks_x[jc] = d.xsize_blocks >> hs;
            j.blocks_y[jc] = d.ysize_blocks >> vs;
        }
        for (0..3) |jc| {
            const n = @as(usize, j.blocks_x[jc]) * j.blocks_y[jc] * 64;
            if (mem.len - at < n) return error.TooComplex;
            j.coefs[jc] = mem[at..][0..n];
            vfill(i16, j.coefs[jc], 0);
            at += n;
        }
        return j;
    }

    pub fn sink(j: *Jpeg) CoeffSink {
        return .{ .ctx = j, .pixels = false, .lf = onLf, .block = onBlock };
    }

    fn onLf(ctx: *anyopaque, s: *const Shared, q: QuantLf) Error!void {
        const j: *Jpeg = @ptrCast(@alignCast(ctx));
        if (s.lf_cfl[0] != 0 or s.lf_cfl[2] != 0) return error.NotJpeg;
        // The DC is the LF over `1 << extra_precision`, truncated and
        // clamped to a JPEG's ±2047, as libjxl rebuilds it.
        const scale = @as(i32, 1) << q.extra_precision;
        for (q.channels, 0..) |ch, c| {
            const jc = component[c];
            const x0 = q.rect.x0 >> s.hs[c];
            const y0 = q.rect.y0 >> s.vs[c];
            for (0..ch.h) |y| {
                const row = j.coefs[jc][((y0 + y) * j.blocks_x[jc] + x0) * 64 ..];
                for (ch.row(@intCast(y))[0..ch.w], 0..) |v, x| {
                    row[x * 64] = @intCast(std.math.clamp(@divTrunc(v, scale), -2047, 2047));
                }
            }
        }
    }

    fn onBlock(ctx: *anyopaque, s: *const Shared, b: QuantBlock) Error!void {
        const j: *Jpeg = @ptrCast(@alignCast(ctx));
        if (b.strategy != .dct8 or s.base_x != 0 or s.base_b != 0 or s.color_factor != 84) return error.NotJpeg;
        if (!j.got_quant) {
            const t = s.raw_dct8 orelse return error.NotJpeg;
            for (0..3) |c| for (0..64) |k| {
                const v = t[c * 64 + (k % 8) * 8 + k / 8];
                j.quant[component[c]][k] = std.math.cast(u16, v) orelse return error.NotJpeg;
            };
            // Raw tables are positive (`quant.zig`).
            for (0..3) |jc| for (0..64) |k| {
                const n = zigzag[k];
                j.ratio[jc][k] = @intCast((@as(u32, j.quant[0][n]) << cfl_bits) / j.quant[jc][n]);
            };
            j.got_quant = true;
        }
        // The luma block at this position, which chroma from luma adds
        // back. Ranges are checked once a block: an error union a
        // coefficient stalls the loop on reloading it.
        var y: [64]i32 = undefined;
        if (b.coeffs[1]) |q| {
            for (&y, gather) |*o, g| o.* = q[g];
            try checkI16(i32, &y);
        }
        for (b.coeffs, 0..) |co, c| {
            const q = co orelse continue;
            const jc = component[c];
            const bx = b.bx >> s.hs[c];
            const by = b.by >> s.vs[c];
            const out = j.coefs[jc][(by * j.blocks_x[jc] + bx) * 64 ..][0..64];
            const f: i64 = if (c == 0) b.x_factor else if (c == 2) b.b_factor else 0;
            var v: [64]i64 = undefined;
            for (&v, gather) |*o, g| o.* = q[g];
            if (f != 0 and b.coeffs[1] != null) {
                // Chroma from luma in integers, as djxl rebuilds a JPEG
                // (docs/slop/jxl.md): the factor and the ratio of the
                // luma and chroma quantization steps in 11-bit fixed point.
                const m = @divTrunc(f << cfl_bits, s.color_factor);
                for (&v, j.ratio[jc], y) |*o, ratio, l| {
                    const scale = (m * ratio + (1 << (cfl_bits - 1))) >> cfl_bits;
                    o.* += (scale * l + (1 << (cfl_bits - 1))) >> cfl_bits;
                }
            }
            // The lowest frequency is the LF's.
            v[0] = 0;
            try checkI16(i64, &v);
            for (out[1..], v[1..]) |*o, x| o.* = @intCast(x);
        }
    }

    const gather: [64]u8 = blk: {
        var t: [64]u8 = undefined;
        for (&t, zigzag) |*o, n| o.* = (n % 8) * 8 + n / 8;
        break :blk t;
    };

    fn checkI16(comptime T: type, v: *const [64]T) Error!void {
        const vec: @Vector(64, T) = v.*;
        const lo = @reduce(.Min, vec);
        const hi = @reduce(.Max, vec);
        if (lo < std.math.minInt(i16) or hi > std.math.maxInt(i16)) return error.NotJpeg;
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

    mults: [quant.num_tables][]const f32 = @splat(&.{}),
    /// The DCT8 table's raw entries (channels X, Y, B, each 64 in stored
    /// layout), when it is raw: a recompressed JPEG's quantization tables.
    raw_dct8: ?[]const i32 = null,
    num_histograms: u32 = 1,
    /// Per pass and order class, the three channels' coefficient orders.
    orders: [max_passes][num_orders][]u16 = undefined,
    codes: [max_passes]entropy.Code = undefined,
    /// Coefficients kept between passes, per group, when there are
    /// several passes.
    coeffs: []i32 = &.{},
    passes_done: []u8 = &.{},
    sink: ?CoeffSink = null,

    /// The frame's pixels before the filters: three planes of `bw * 8`
    /// by `bh * 8`, or with `ring_rows`, a ring of that many rows where
    /// row y is at `y % ring_rows` (whole group rows, which no varblock
    /// crosses).
    planes: [3][]f32,
    ring_rows: usize = 0,
    /// With a ring, copies of rows `tail_y .. tail_y + tail_rows` of the
    /// channels not subsampled vertically, which the ring has dropped
    /// while a band's window still reads them (`pixelRow`).
    tail: [3][]f32 = @splat(&.{}),
    tail_y: usize = 0,
    tail_rows: usize = 0,

    /// Takes the planes: whole, or with `ring_rows`, the ring. They are
    /// cleared only with subsampled channels: otherwise every block has a
    /// strategy (`readPassGroup` refuses an unset one), and the last pass
    /// writes all of each varblock's pixels in every channel before the
    /// filters or a later stage read them.
    pub fn allocPlanes(s: *Shared, arena: *Arena) Error!void {
        const rows: usize = if (s.ring_rows == 0) s.bh * 8 else s.ring_rows;
        if (s.pixels()) for (&s.planes) |*p| {
            p.* = try arena.alloc(f32, s.bw * 8 * rows);
            if (s.subsampled()) vfill(f32, p.*, 0);
        };
    }

    /// Where row `y` of the frame is in the planes.
    pub fn planeRow(s: *const Shared, y: usize) usize {
        return if (s.ring_rows == 0) y else y % s.ring_rows;
    }

    /// Row `y` of channel `c`'s plane: from the tail, when it holds it,
    /// else the planes.
    pub fn pixelRow(s: *const Shared, c: usize, y: usize) []f32 {
        const stride = s.bw * 8;
        if (y -% s.tail_y < s.tail_rows and s.vs[c] == 0) return s.tail[c][(y - s.tail_y) * stride ..][0..stride];
        return s.planes[c][s.planeRow(y) * stride ..][0..stride];
    }

    /// Copies rows `y .. y + rows` of the channels not subsampled
    /// vertically to the tail, before the ring drops them.
    pub fn keepTail(s: *Shared, y: usize, rows: usize) void {
        s.tail_rows = 0;
        for (0..3) |c| {
            if (s.vs[c] != 0) continue;
            for (0..rows) |i| @memcpy(s.tail[c][i * s.bw * 8 ..][0 .. s.bw * 8], s.pixelRow(c, y + i));
        }
        s.tail_y = y;
        s.tail_rows = rows;
    }

    /// `ring_rows`, when not 0, keeps only that many rows of pixels (a
    /// multiple of the group size): the frame is filtered and written a
    /// group row at a time. Its planes are left to `allocPlanes`, once the
    /// caller knows whether the frame streams.
    pub fn init(
        arena: *Arena,
        image: *const headers.ImageHeader,
        fh: *const headers.FrameHeader,
        d: *const headers.Dims,
        sink: ?CoeffSink,
        ring_rows: usize,
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
            .planes = @splat(&.{}),
            .sink = sink,
            .ring_rows = ring_rows,
            .hs = .{ @intCast(fh.hShift(0)), @intCast(fh.hShift(1)), @intCast(fh.hShift(2)) },
            .vs = .{ @intCast(fh.vShift(0)), @intCast(fh.vShift(1)), @intCast(fh.vShift(2)) },
        };
        if (!image.xyb) s.base_b = 0;
        for (&s.lf) |*p| p.* = try arena.alloc(f32, n);
        @memset(s.acs, unset);
        @memset(s.cfl_x, 0);
        @memset(s.cfl_b, 0);
        if (ring_rows == 0) try s.allocPlanes(arena);
        if (fh.passes.num > 1) {
            const gd = group_blocks * 8;
            s.coeffs = try arena.alloc(i32, s.num_groups * gd * gd * 3);
            vfill(i32, s.coeffs, 0);
        }
        s.passes_done = try arena.alloc(u8, s.num_groups);
        @memset(s.passes_done, 0);
        return s;
    }

    pub fn pixels(s: *const Shared) bool {
        return if (s.sink) |k| k.pixels else true;
    }

    pub fn subsampled(s: *const Shared) bool {
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
    if (s.sink) |k| try k.lf(k.ctx, s, .{ .rect = r, .channels = .{ qx, qy, qb }, .extra_precision = @intCast(extra) });
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
            const st: Strategy = @fromBackingInt(@intCast(raw));
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
    const default = try quant.read(br, arena, .{ .tree = tree, .first_stream = @intCast(1 + 3 * num_lf_groups) }, &enc);
    // A JPEG's tables are stored with the denominator 1/(8·255) (f16
    // 0x1004); with any other the table is not a JPEG's.
    s.raw_dct8 = switch (enc[0]) {
        .raw => |r| if (@abs(r.den - 1.0 / (8.0 * 255.0)) <= 1e-8) r.table[0 .. 3 * 64] else null,
        else => null,
    };
    for (0..Strategy.count) |k| {
        if (s.used_acs & (@as(u32, 1) << @intCast(k)) == 0) continue;
        const t = Strategy.quant_table[k];
        if (s.mults[t].len != 0) continue;
        if (default & (@as(u32, 1) << @intCast(t)) != 0) {
            if (quant.defaultMultipliers(t)) |m| {
                s.mults[t] = m;
                continue;
            }
        }
        const len = 3 * 64 * @as(usize, quant.size_x[t]) * quant.size_y[t];
        const m = try arena.alloc(f32, len);
        try quant.multipliers(&enc[t], t, m);
        s.mults[t] = m;
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
        // Each coded class's permutations: per channel, a length and at
        // most a value a coefficient (which bounds the LZ77 window).
        var symbols: usize = 0;
        var counted: u32 = 0;
        for (0..Strategy.count) |k| {
            const bit = @as(u32, 1) << @intCast(Strategy.order_class[k]);
            if (used_orders & bit == 0 or counted & bit != 0) continue;
            counted |= bit;
            symbols += 3 * (1 + 64 * @as(usize, @as(Strategy, @fromBackingInt(@intCast(k))).covered()));
        }
        code = try entropy.Code.read(br, arena, 8);
        reader = try .init(&code, br, arena, 0, symbols);
    }
    var done: u32 = 0;
    for (0..Strategy.count) |k| {
        const ord = Strategy.order_class[k];
        if (done & (@as(u32, 1) << @intCast(ord)) != 0) continue;
        done |= @as(u32, 1) << @intCast(ord);
        const st: Strategy = @fromBackingInt(@intCast(k));
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
/// The most bytes one pass's coefficient orders take in a frame of `bw`
/// by `bh` blocks: orders are kept for the classes the frame uses, and a
/// strategy is used only where it fits in the frame and a group.
pub fn ordersBytes(bw: u64, bh: u64) u64 {
    var counted: u32 = 0;
    var total: u64 = 0;
    for (0..Strategy.count) |k| {
        const st: Strategy = @fromBackingInt(@intCast(k));
        if (st.bx() > @min(group_blocks, bw) or st.by() > @min(group_blocks, bh)) continue;
        const bit = @as(u32, 1) << @intCast(Strategy.order_class[k]);
        if (counted & bit != 0) continue;
        counted |= bit;
        total += 3 * 64 * @as(u64, st.covered()) * @sizeOf(u16);
    }
    return total;
}

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
    const kind = reader.kind();
    const ctx_offset = histo * s.block_ctx.numAcContexts();
    const nz = try arena.alloc(i32, 3 * r.w * r.h);
    const last = pass + 1 == s.passes.num;
    const keep = s.coeffs.len != 0;
    const gsize = group_blocks * group_blocks * 64;
    // One pass's coefficients, a channel's at a time `max_coeffs` apart,
    // kept zero between blocks: zeroed to the largest block so far, and
    // after each block only where it was decoded.
    const max_coeffs = 64 * 1024;
    const q = try arena.alloc(i32, 3 * max_coeffs);
    var zeroed: usize = 0;
    const scratch: []f32 = if (s.pixels()) try arena.alloc(f32, 3 * 64 * 1024 + 2 * 64 * 1024) else &.{};
    var offset: usize = 0;
    for (0..r.h) |by| {
        var bx: usize = 0;
        while (bx < r.w) {
            const at = (r.y0 + by) * s.bw + r.x0 + bx;
            const a = s.acs[at];
            if (a == unset) return error.BadImage;
            const st: Strategy = @fromBackingInt(@intCast(a >> 1));
            if (a & 1 == 0) {
                bx += st.bx();
                continue;
            }
            const size = 64 * @as(usize, st.covered());
            var blocks: [3][]i32 = undefined;
            if (!keep and zeroed < size) {
                for (0..3) |c| vfill(i32, q[c * max_coeffs + zeroed .. c * max_coeffs + size], 0);
                zeroed = size;
            }
            for (0..3) |c| {
                blocks[c] = if (keep)
                    s.coeffs[(g * 3 + c) * gsize + offset ..][0..size]
                else
                    q[c * max_coeffs ..][0..size];
            }
            const shift: u5 = @intCast(s.passes.shift[pass]);
            const orders = s.orders[pass][Strategy.order_class[a >> 1]];
            // Where each channel's decoded coefficients end in its order.
            var ends: [3]usize = @splat(st.covered());
            for ([3]usize{ 1, 0, 2 }) |c| {
                // A subsampled channel has a block only where its
                // coordinates are a multiple of the subsampling.
                if ((bx >> s.hs[c]) << s.hs[c] != bx or (by >> s.vs[c]) << s.vs[c] != by) continue;
                ends[c] = switch (kind) {
                    inline else => |k| try decodeBlock(
                        k,
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
                        orders,
                        blocks[c],
                        shift,
                    ),
                };
            }
            offset += size;
            if (last) {
                if (s.sink) |k| {
                    var coeffs: [3]?[]const i32 = undefined;
                    for (&coeffs, blocks, 0..) |*o, b, c| {
                        const here = (bx >> s.hs[c]) << s.hs[c] == bx and (by >> s.vs[c]) << s.vs[c] == by;
                        o.* = if (here) b else null;
                    }
                    const tile = ((r.y0 + by) / 8) * s.tiles_x + (r.x0 + bx) / 8;
                    try k.block(k.ctx, s, .{
                        .strategy = st,
                        .bx = r.x0 + bx,
                        .by = r.y0 + by,
                        .coeffs = coeffs,
                        .qf = s.qf[at],
                        .x_factor = s.cfl_x[tile],
                        .b_factor = s.cfl_b[tile],
                    });
                }
                if (s.pixels()) reconstruct(s, st, r.x0 + bx, r.y0 + by, blocks, scratch);
            }
            if (!keep) for (blocks, ends, 0..) |b, end, c| {
                for (orders[c * size ..][st.covered()..end]) |o| b[o] = 0;
            };
            bx += st.bx();
        }
    }
    if (!reader.finalOk()) return error.BadEntropy;
    s.passes_done[g] += 1;
}

/// Adds a varblock's coefficients in channel `c` to `block`, and returns
/// where they end in its order: every one it wrote is before that.
fn decodeBlock(
    comptime kind: entropy.Reader.Kind,
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
) Error!usize {
    const covered: usize = st.covered();
    const log2c = st.log2Covered();
    const size = covered * 64;
    const ord = Strategy.order_class[@backingInt(st)];
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
    var nzeros: usize = try readCtx(kind, reader, br, code, nz_ctx);
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
        const u = try readCtx(kind, reader, br, code, ctx);
        const mag: i32 = @bitCast(u >> 1);
        const val: i32 = if (u & 1 == 1) -%mag -% 1 else mag;
        block[order[k]] +%= val << shift;
        prev = @intFromBool(u != 0);
        nzeros -= prev;
    }
    if (nzeros != 0) return error.BadImage;
    return k;
}

/// Reads in context `ctx`, whose cluster is 0 past the map's end.
inline fn readCtx(
    comptime kind: entropy.Reader.Kind,
    reader: *entropy.Reader,
    br: *BitReader,
    code: *const entropy.Code,
    ctx: usize,
) Error!u32 {
    const map = code.context_map;
    const n = map.len - @intFromBool(code.lz77.enabled);
    return reader.readClusterAs(kind, br, if (ctx < n) map[ctx] else 0);
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
    const mat = s.mults[Strategy.quant_table[@backingInt(st)]];
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
        const out = s.planes[c][s.planeRow(sby * 8) * stride + sbx * 8 ..];
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
            const st: Strategy = @fromBackingInt(@intCast(a >> 1));
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
/// Across first, then down.
pub fn upsampleChroma(s: *Shared, w: usize, h: usize) void {
    const stride = s.bw * 8;
    for (0..3) |c| {
        const p = s.planes[c];
        if (s.hs[c] != 0) {
            const rows = (h + (@as(usize, 1) << s.vs[c]) - 1) >> s.vs[c];
            for (0..rows) |y| upsampleAcross(p[y * stride ..][0..stride], w);
        }
        if (s.vs[c] != 0) {
            const n = (h + 1) >> 1;
            const rows = s.bh * 8;
            var y = n;
            while (y > 0) {
                y -= 1;
                const mid = p[y * stride ..][0..stride];
                if (2 * y + 1 < rows) upsampleDown(p[(2 * y + 1) * stride ..][0..stride], mid, p, stride, y, n, true);
                upsampleDown(p[2 * y * stride ..][0..stride], mid, p, stride, y, n, false);
            }
        }
    }
}

/// A streamed frame's rows `ws .. we` of each channel, at the frame's
/// size, into `win` (rows of the planes' stride), as `upsampleChroma`
/// leaves them. The rings' subsampled rows are upsampled across in place
/// once each: `done[c]` counts those of channel `c` already done.
pub fn chromaWindow(s: *const Shared, done: *[3]usize, w: usize, h: usize, ws: usize, we: usize, win: [3][]f32) void {
    const stride = s.bw * 8;
    const n = (h + 1) >> 1;
    for (0..3) |c| {
        const p = s.planes[c];
        const vs = s.vs[c] != 0;
        // The last row the window's rows read, before upsampling down.
        const last = if (vs) @min(n - 1, ((we - 1) >> 1) + 1) else we - 1;
        if (s.hs[c] != 0) while (done[c] <= last) : (done[c] += 1) {
            upsampleAcross(p[s.planeRow(done[c]) * stride ..][0..stride], w);
        };
        for (ws..we) |y| {
            const out = win[c][(y - ws) * stride ..][0..stride];
            if (!vs) {
                @memcpy(out, s.pixelRow(c, y));
                continue;
            }
            const yc = y >> 1;
            const near = if (y & 1 == 0) (if (yc == 0) 0 else yc - 1) else (if (yc + 1 == n) yc else yc + 1);
            const mid = p[s.planeRow(yc) * stride ..][0..stride];
            for (out, mid, p[s.planeRow(near) * stride ..][0..stride]) |*o, m, d| o.* = 0.75 * m + 0.25 * d;
        }
    }
}

/// Upsamples one row across, in place: its first `(w + 1) / 2` pixels to
/// `w`, mirrored at its ends.
fn upsampleAcross(row: []f32, w: usize) void {
    const n = (w + 1) >> 1;
    var x = n;
    while (x > 0) {
        x -= 1;
        const l = row[if (x == 0) 0 else x - 1];
        const m = row[x];
        const r = row[if (x + 1 == n) x else x + 1];
        if (2 * x + 1 < row.len) row[2 * x + 1] = 0.75 * m + 0.25 * r;
        row[2 * x] = 0.75 * m + 0.25 * l;
    }
}

/// Row `2y` (`odd` false) or `2y + 1` of a channel upsampled down, from
/// its row `y` and the one above or below, mirrored at row `n - 1`.
fn upsampleDown(out: []f32, mid: []const f32, p: []const f32, stride: usize, y: usize, n: usize, odd: bool) void {
    const near = if (odd) (if (y + 1 == n) y else y + 1) else (if (y == 0) 0 else y - 1);
    for (out, mid, p[near * stride ..][0..stride]) |*o, m, d| o.* = 0.75 * m + 0.25 * d;
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

test "decodeJpeg rebuilds a recompressed JPEG's coefficients and tables" {
    // A 16 by 8 4:4:4 JPEG of a photograph's crop, with uneven quantization
    // tables, through `cjxl --lossless_jpeg=1`, which chose chroma from
    // luma. The expected values are libjpeg's jpeg_read_coefficients of the
    // source JPEG; the chroma blocks include coefficients that rounding the
    // exact quotient, or the quantization steps' ratio, would get wrong.
    const file =
        "\x00\x00\x00\x0c\x4a\x58\x4c\x20\x0d\x0a\x87\x0a\x00\x00\x00\x14\x66\x74\x79\x70\x6a\x78\x6c\x20" ++
        "\x00\x00\x00\x00\x6a\x78\x6c\x20\x00\x00\x00\x11\x6a\x78\x6c\x70\x00\x00\x00\x00\xff\x0a\xc1\x41" ++
        "\x24\x00\x00\x01\xe0\x6a\x62\x72\x64\xc0\x6d\x03\x08\x82\x20\xb4\x0c\x08\x80\x50\xa3\x40\xc8\x55" ++
        "\x25\x00\x00\x20\xe4\xa8\x6c\xc1\x50\x9c\xff\x13\x44\xc6\x08\x65\x9c\x53\x0a\xda\x8f\x90\x21\xcc" ++
        "\x52\x07\x19\x66\xa0\x74\x87\x1a\xac\x0f\x19\x4e\x3e\x66\xc0\x21\x07\x15\x16\x39\x68\xd8\x81\xed" ++
        "\xa3\x86\xfe\xfd\x91\x65\x0e\x3b\xee\x40\x43\xd1\xfd\x2f\xc6\x38\x63\x92\x4b\x36\xf9\x64\x94\x53" ++
        "\x9e\x99\xe6\x9a\x6d\xbe\x19\xe7\x9c\x85\x1e\x9a\xe8\xa2\x8d\x3e\x1a\xe9\xa4\xa5\x9e\x9a\xea\xaa" ++
        "\xad\xbe\x1a\xeb\xac\xc5\x1e\x9b\xec\xb2\xcd\x3e\x1b\xed\xb4\xe5\x9e\x9b\xee\xba\xed\xbe\x1b\xef" ++
        "\xbc\x05\x1f\x9c\xf0\xc2\x0d\x3f\x1c\xf1\xc4\x23\x97\x7c\x72\xca\x2b\xb7\xfc\x72\xcc\x33\x0f\x5d" ++
        "\xf4\xd1\x49\x2f\xdd\xf4\xd3\x51\x4f\x3d\x76\xd9\x67\xa7\xbd\x76\xdb\x6f\xc7\x3d\xf7\xe0\x85\x1f" ++
        "\x9e\xf8\xe2\x8d\x3f\x1e\xf9\xe4\xa3\x97\x7e\x7a\xea\xab\xb7\xfe\x7a\xec\xb3\x07\x3f\x7c\xf1\xc7" ++
        "\x27\xbf\x7c\xf3\xcf\x47\x3f\x7d\xf8\xe3\x97\x7f\x7e\xfa\xeb\xb7\xff\x7e\xfc\xf3\xff\x57\x30\x55" ++
        "\x55\x02\x00\x20\xe4\xa8\x6c\xc1\x50\x9c\xff\x17\x44\x42\x29\xa3\xac\x53\x8a\xc4\x78\x40\xc8\x66" ++
        "\xd4\x20\xc3\xa4\x3a\xd0\x50\x3d\xd8\x70\xee\x21\xc7\x0c\x28\xc8\x07\x0d\x39\xe8\xb0\x03\x1b\x8b" ++
        "\x2c\x73\xd4\xef\xf6\x61\xc7\x0d\xad\xe8\x8f\x3c\x33\xf8\x24\xc3\xfb\x5f\x8c\x71\xc6\x25\x9b\x7c" ++
        "\x32\xca\x29\xd3\x5c\xb3\xcd\x37\xe3\x9c\xb3\xd0\x43\x13\x5d\xb4\xd1\x47\x23\x9d\xb4\xd4\x53\x53" ++
        "\x5d\xb5\xd5\x57\x63\x9d\xb5\xd8\x63\x93\x5d\xb6\xd9\x67\xa3\x9d\xb6\xdc\x73\xd3\x5d\xb7\xdd\x77" ++
        "\xe3\x9d\x77\xe0\x82\x0f\x4e\x78\xe1\x86\x1f\x8e\x78\xe2\x91\x4b\x3e\x39\xe5\x95\x5b\x7e\x39\xe6" ++
        "\x99\x87\x2e\xfa\xe8\xa4\x97\x6e\xfa\xe9\xa8\xa7\x1e\xbb\xec\xb3\xd3\x5e\xbb\xed\xb7\xe3\x9e\x7b" ++
        "\xf0\xc2\x0f\x4f\x7c\xf1\xc6\x1f\x8f\x7c\xf2\xd1\x4b\x3f\x3d\xf5\xd5\x5b\x7f\x3d\xf6\xd9\x87\x2f" ++
        "\xfe\xf8\xe4\x97\x6f\xfe\xf9\xe8\xa7\x1f\xbf\xfc\xf3\xd3\x5f\xbf\xfd\xf7\xe3\x9f\xff\xbf\xc0\x0f" ++
        "\x00\x54\x16\x00\x0b\x08\x80\xe0\x00\x10\x4a\x46\x49\x46\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" ++
        "\x03\x00\x00\x01\x15\x6a\x78\x6c\x70\x80\x00\x00\x01\xe0\x5b\x00\x10\x00\x08\x04\x08\x71\x0c\x6c" ++
        "\x08\x71\xfe\xff\x0e\x80\x88\x11\x00\x85\xc6\xc6\x6e\x00\x00\x00\x05\x00\x00\xf0\x03\x00\x00\x00" ++
        "\x00\x00\x00\x00\x10\xb0\x24\x71\x8c\xb8\x9b\xeb\x21\x94\xc9\x5a\xdc\x03\x85\xc2\x88\x14\x14\x48" ++
        "\x85\x51\x3b\x6c\xa3\xa3\xa3\xa3\x1d\x23\x63\x10\x23\x4d\x61\x38\x27\x02\x00\xce\x48\x3c\x98\xa2" ++
        "\x0f\xd0\x98\x00\x00\x80\xc0\x02\x00\xe0\x04\x10\xb3\xef\xeb\x01\x60\x65\x9f\x99\x1f\x1c\xcb\x63" ++
        "\xda\x7d\x43\x0a\xe2\xfc\xb8\xb9\xfb\x1c\x1b\xbf\xc2\xe2\x38\x67\x29\x31\x5d\x28\x29\x4d\x18\xb6" ++
        "\xd7\xe7\xd9\xd3\x7c\xe6\xca\xfa\x16\xa9\xe8\x06\xc9\x35\x10\x1f\xe4\x60\x64\x54\xb0\x51\x52\xd5" ++
        "\xd2\x80\x42\xd2\x3a\x08\x81\x7f\x0a\xf8\x2c\x5f\x79\xe0\x66\x21\x07\xc9\x32\x9a\xb6\x9b\x34\x65" ++
        "\x23\x6f\xfe\xae\x3e\xab\xbd\xaf\x0c\xf7\x3d\x09\x1b\x4d\x57\x8f\x6e\x8f\xd6\x6e\xc6\xed\x14\x00" ++
        "\x00\x00\x00\x00\x00\x28\xa4\x40\x0e\x6c\x51\x31\xc6\xbb\x8b\x77\x91\x91\x31\x1e\x58\x94\x1c\x01" ++
        "\x6a\x6c\x4e\x32\x2a\xaf\x9c\x2c\x0c\xc5\xd4\x1a\x38\x30\x44\xdb\xcb\xeb\x80\x0a\x9c\x21\xf0\x5c" ++
        "\x60\x7c\xe5\xa1\x36\xe9\x2f\xb4\x51\xba\x8e\x60\x03\x01";
    const tables = [2][64]u16{
        .{
            6, 9, 2,  3,  5,  3, 2, 5, 5, 2, 4,  5,  3, 8, 12, 5,
            7, 3, 10, 9,  10, 9, 6, 2, 5, 2, 4,  8,  2, 5, 1,  11,
            2, 5, 2,  11, 5,  2, 5, 3, 8, 1, 6,  10, 8, 5, 11, 3,
            2, 9, 5,  3,  4,  5, 2, 4, 4, 6, 11, 6,  9, 4, 6,  8,
        },
        .{
            9,  12, 4, 5, 7,  14, 1,  5,  2,  1, 1,  13, 9,  10, 4,  9,
            9,  5,  8, 3, 12, 14, 11, 8,  12, 9, 10, 14, 7,  9,  6,  12,
            4,  5,  6, 4, 14, 12, 13, 11, 3,  7, 7,  2,  14, 3,  1,  2,
            11, 13, 5, 8, 4,  2,  2,  12, 14, 7, 15, 9,  12, 6,  11, 5,
        },
    };
    const want = [3][2][64]i16{
        .{
            .{
                79, -7, -3, -2, 0, 0, 0, 0, -13, 13, 0, 0, 0, 0, 0, 0,
                -2, 0,  0,  0,  0, 0, 0, 0, -1,  1,  0, 0, 0, 0, 0, 0,
                -1, 0,  1,  0,  0, 0, 0, 0, 0,   1,  0, 0, 0, 0, 0, 0,
                0,  0,  0,  0,  0, 0, 0, 0, 0,   0,  0, 0, 0, 0, 0, 0,
            },
            .{
                78, 8,  -5, 1, 0, 1, -1, 0, -24, 1, 1, -1, 1, 0, 0, 0,
                -1, -3, 0,  0, 0, 0, 0,  0, -1,  0, 0, 0,  0, 0, 0, 0,
                0,  0,  2,  0, 0, 0, 0,  0, 0,   0, 0, 0,  0, 0, 0, 0,
                0,  0,  0,  0, 0, 0, 0,  0, 0,   0, 0, 0,  0, 0, 0, 0,
            },
        },
        .{
            .{
                19, 3, 1, 1, 0, 0,  0, 0, 26, -17, -1, 0, 0, 0, 0, 0,
                1,  0, 0, 0, 0, 0,  0, 0, 0,  0,   0,  0, 0, 0, 0, 0,
                0,  0, 0, 0, 0, 0,  0, 0, 1,  0,   0,  0, 0, 0, 0, 0,
                0,  0, 0, 0, 0, -1, 0, 0, 0,  0,   0,  0, 0, 0, 0, 0,
            },
            .{
                22, -4, 1, -1, 0, 0, 1, 0, 37, 7, -3, 0, 0, 0, 0, 0,
                0,  1,  0, 0,  0, 0, 0, 0, 0,  0, 0,  0, 0, 0, 0, 0,
                0,  0,  0, 0,  0, 0, 0, 0, 1,  0, 0,  0, 0, 0, 0, 0,
                0,  0,  0, 0,  0, 0, 0, 0, 0,  0, 0,  0, 0, 0, 0, 0,
            },
        },
        .{
            .{
                -3, 0, 0, 0, 0, 0, 0, 0, -4, 2, 0, 0, 0, 0, 0,  0,
                0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0,  0,
                0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, -1, 0,
                0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0,  0,
            },
            .{
                -4, 1, 0, 0, 0, 0, 0, 0, -6, -1, 0, 0, 0, 0, 0,  0,
                0,  0, 0, 0, 0, 0, 0, 0, 0,  0,  0, 0, 0, 0, 0,  0,
                0,  0, 0, 0, 0, 0, 0, 0, 0,  0,  0, 0, 0, 0, -1, 0,
                0,  0, 0, 0, 0, 0, 0, 0, 0,  0,  0, 0, 0, 0, 0,  0,
            },
        },
    };
    var r: std.Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    _ = try d.decodeConfig();
    const work = try testing.allocator.alloc(u8, try d.jpegWorkLen());
    defer testing.allocator.free(work);
    var coefs: [Jpeg.maxCoefs(16, 8)]i16 = undefined;
    const j = try d.decodeJpeg(&coefs, work);
    try testing.expectEqual([3]u4{ 1, 1, 1 }, j.h);
    try testing.expectEqual([3]u4{ 1, 1, 1 }, j.v);
    try testing.expectEqual([3]u32{ 2, 2, 2 }, j.blocks_x);
    try testing.expectEqual([3]u32{ 1, 1, 1 }, j.blocks_y);
    for (0..3) |c| {
        try testing.expectEqualSlices(u16, &tables[@min(c, 1)], &j.quant[c]);
        for (0..2) |b| try testing.expectEqualSlices(i16, &zigzagged(want[c][b]), j.coefs[c][b * 64 ..][0..64]);
    }
    // The same with its raw table's denominator a step from 1/(8·255) (f16
    // 0x1005 for 0x1004, in byte 634): not a JPEG's table, as libjxl says.
    var odd = file[0..file.len].*;
    odd[634] ^= 1;
    var r2: std.Io.Reader = .fixed(&odd);
    var d2: Decoder = .init(&r2, .{});
    _ = try d2.decodeConfig();
    try testing.expectError(error.NotJpeg, d2.decodeJpeg(&coefs, work));
    // With extra_precision 1 (byte 614, bit 3) each DC is the LF halved
    // toward zero (79 to 39, -3 to -1), as djxl rebuilds the same file.
    // A colour factor of 256 instead of 84 (byte 575, bit 3): not a JPEG's
    // chroma from luma, which djxl will not rebuild either.
    var factor = file[0..file.len].*;
    factor[575] |= 1 << 3;
    var r4: std.Io.Reader = .fixed(&factor);
    var d4: Decoder = .init(&r4, .{});
    _ = try d4.decodeConfig();
    try testing.expectError(error.NotJpeg, d4.decodeJpeg(&coefs, work));
    var halved = file[0..file.len].*;
    halved[614] |= 1 << 3;
    var r3: std.Io.Reader = .fixed(&halved);
    var d3: Decoder = .init(&r3, .{});
    _ = try d3.decodeConfig();
    const h = try d3.decodeJpeg(&coefs, work);
    for (0..3) |c| for (0..2) |b| {
        var w = want[c][b];
        w[0] = @divTrunc(w[0], 2);
        try testing.expectEqualSlices(i16, &zigzagged(w), h.coefs[c][b * 64 ..][0..64]);
    };
}

/// A test's block in natural order, in zigzag order.
fn zigzagged(natural: [64]i16) [64]i16 {
    var z: [64]i16 = undefined;
    for (&z, zigzag) |*o, n| o.* = natural[n];
    return z;
}
