//! One frame's sections (ISO/IEC 18181-1, the frame and its table of
//! contents): the TOC, then LfGlobal, the LF groups, HfGlobal, and the pass
//! groups, read in file order. This stage decodes Modular frames into a
//! frame-sized `modular.Image` with the global transforms undone.

const std = @import("std");
const testing = std.testing;

const BitReader = @import("BitReader.zig");
const entropy = @import("entropy.zig");
const Arena = @import("Arena.zig");
const headers = @import("headers.zig");
const modular = @import("modular.zig");
const vardct = @import("vardct.zig");
const upsample = @import("upsample.zig");
const noise = @import("noise.zig");
const patches = @import("patches.zig");
const splines = @import("splines.zig");
pub const PatchSource = patches.Source;
const quant = @import("quant.zig");
const color = @import("color.zig");
const filters = @import("filters.zig");

pub const Error = vardct.Error;

const max_toc_entries = 65536;
const num_quant_tables = 17;

pub const Toc = struct {
    /// Section sizes in file order.
    sizes: []u32,
    /// The logical section in each file slot.
    ids: []u32,
    total: u64,

    pub fn permuted(t: *const Toc) bool {
        for (t.ids, 0..) |id, i| if (id != i) return true;
        return false;
    }
};

fn numEntries(d: *const headers.Dims, passes: u32) u64 {
    if (d.num_groups == 1 and passes == 1) return 1;
    return 2 + @as(u64, d.num_lf_groups) + @as(u64, d.num_groups) * passes;
}

/// Reads the table of contents, which follows the frame header.
pub fn readToc(br: *BitReader, arena: *Arena, d: *const headers.Dims, passes: u32) Error!Toc {
    const n64 = numEntries(d, passes);
    if (n64 > max_toc_entries) return error.BadHeader;
    const n: usize = @intCast(n64);
    const ids = try arena.alloc(u32, n);
    for (ids, 0..) |*id, i| id.* = @intCast(i);
    if (try br.boolean()) {
        const m = arena.mark();
        const perm = try arena.alloc(u32, n);
        try readPermutation(br, arena, perm);
        // File slot perm[i] holds logical section i.
        for (perm, 0..) |slot, i| ids[slot] = @intCast(i);
        arena.release(m);
    }
    try br.zeroPadToByte();
    const sizes = try arena.alloc(u32, n);
    var total: u64 = 0;
    for (sizes) |*s| {
        s.* = try br.u32Dist(.{ .b(10), .bo(14, 1024), .bo(22, 17408), .bo(30, 4211712) });
        total += s.*;
    }
    try br.zeroPadToByte();
    return .{ .sizes = sizes, .ids = ids, .total = total };
}

fn permContext(v: u32) usize {
    if (v == 0) return 0;
    return @min(7, 1 + std.math.log2_int(u32, v));
}

/// Reads a permutation of `order.len` entries as Lehmer codes.
fn readPermutation(br: *BitReader, arena: *Arena, order: []u32) Error!void {
    const size: u32 = @intCast(order.len);
    const code = try entropy.Code.read(br, arena, 8);
    var r: entropy.Reader = try .init(&code, br, arena, 0, size + 1);
    const end = try r.read(br, permContext(size));
    if (end > size) return error.BadHeader;
    const lehmer = try arena.alloc(u32, size);
    @memset(lehmer, 0);
    var last: u32 = 0;
    for (0..end) |i| {
        lehmer[i] = try r.read(br, permContext(last));
        last = lehmer[i];
        if (lehmer[i] >= size - i) return error.BadHeader;
    }
    if (!r.finalOk()) return error.BadEntropy;
    // The i-th entry is the lehmer[i]-th of those not yet used.
    const used = try arena.alloc(bool, size);
    @memset(used, false);
    for (order, lehmer) |*o, l| {
        var k = l;
        var v: u32 = 0;
        while (true) : (v += 1) {
            if (used[v]) continue;
            if (k == 0) break;
            k -= 1;
        }
        used[v] = true;
        o.* = v;
    }
}

/// What a frame decodes to.
pub const Decoded = struct {
    /// Frame-sized channels: the color channels (none, one, or three,
    /// unless `color` holds them) then the extra channels.
    img: modular.Image,
    num_color: u32,
    /// A VarDCT frame's color channels, as floats ready for output, rows
    /// of `color_stride`.
    color: ?[3][]f32 = null,
    color_stride: usize = 0,
    /// The extra channels as floats, when they are not in `img`
    /// (upsampled): planes of `w` by `h`.
    ec: ?[]const []f32 = null,
    /// The frame's size: after upsampling.
    w: u32,
    h: u32,
    /// Whether the frame's rows went to the `BandSink` instead.
    streamed: bool = false,
};

pub const Context = struct {
    image: *const headers.ImageHeader,
    fh: *const headers.FrameHeader,
    d: headers.Dims,
    tree: ?modular.Tree = null,
    full: modular.Image = undefined,
    num_color: u32 = 0,
    got_global: bool = false,
    done: []bool = &.{},
    vd: ?*vardct.Shared = null,
    lf_quant: [3]f32 = quant.default_dc_quant,
    lf_done: usize = 0,
    got_hf_global: bool = false,
    noise: ?noise.Params = null,
    patches: ?patches.Dictionary = null,
    splines: ?splines.Splines = null,
    refs: *const [4]?PatchSource,
    /// The frame counts that seed the noise (`noise.Frame`).
    counts: [2]u32,
    lf_in: ?LfImage,
    sink: ?vardct.CoeffSink = null,
    /// Where finished group rows go, when the frame streams.
    band: ?BandSink = null,
    /// The group rows whose groups are all in, and the bands written.
    rows_in: usize = 0,
    bands_out: usize = 0,
    /// A band's rows with their filter margins, and EPF's sigmas.
    window: [3][]f32 = undefined,
    sigmas: []f32 = &.{},
};

/// Receives a streamed frame's finished rows: `rows` rows from row `y0`.
/// A VarDCT frame's colors come filtered but before the color transform,
/// in three planes of rows of `stride` (at least the frame's width), and
/// `extra` holds the extra channels; a Modular frame's planes are null
/// and `extra` holds its colors, then its extra channels. `extra`'s
/// channels are final through those rows, which `Channel.row` finds
/// (they may be rings). The planes may be changed.
pub const BandSink = struct {
    ctx: *anyopaque,
    write: *const fn (
        ctx: *anyopaque,
        planes: ?[3][]f32,
        stride: usize,
        extra: *const modular.Image,
        y0: usize,
        rows: usize,
    ) void,
};

/// The rows of filter margin a band needs on each side: Gaborish's one and
/// EPF's three passes' three, two, and one, rounded up to a block, so a
/// window starts on a block row as EPF's sigmas and border rows need.
const band_margin = 8;

/// Whether a frame can stream: in one pass, its groups in order, without
/// what needs the whole frame (upsampling, patches, splines, noise, chroma
/// subsampling), not an LF frame, and VarDCT taller than the ring and a
/// window (`ringRows`), or Modular in integers (`needsFloat` false) of at
/// least two group rows, below which streaming saves nothing. Global
/// Modular transforms make `lfGlobal` decode the frame whole: they are
/// undone on the whole frame. The caller decides whether the frame is
/// shown as it is.
pub fn streams(image: *const headers.ImageHeader, fh: *const headers.FrameHeader, permuted: bool) bool {
    const whole = headers.flag_noise | headers.flag_patches | headers.flag_splines;
    const d: headers.Dims = .init(fh);
    const shape = if (fh.modular) !needsFloat(image, fh) and d.ysize_groups >= 2 else d.ysize_groups >= 5;
    return shape and fh.passes.num == 1 and !permuted and fh.kind == .regular and
        !upsampled(image, fh) and fh.flags & whole == 0 and fh.maxHShift() | fh.maxVShift() == 0;
}

/// The rows a streamed frame's frame-sized Modular channels keep: a
/// Modular frame writes each group row once its groups are in; a VarDCT
/// frame's extra channels are read a group row later, when the band
/// before is filtered.
fn modularRing(fh: *const headers.FrameHeader) u32 {
    const d: headers.Dims = .init(fh);
    return if (fh.modular) d.group_dim else 2 * d.group_dim;
}

/// The rows a streamed frame's VarDCT planes keep: three group rows, the
/// one being decoded and the two its finished neighbor's window reads.
pub fn ringRows(fh: *const headers.FrameHeader) usize {
    const d: headers.Dims = .init(fh);
    return 3 * @as(usize, d.group_dim);
}

/// An LF frame's output, which a frame with `flag_use_lf_frame` takes as
/// its dequantized LF: three planes of `w` by `h`, rows of `w`.
pub const LfImage = struct {
    planes: [3][]const f32,
    w: usize,
    h: usize,
};

/// Fails with `Unsupported` on what this stage does not decode yet.
pub fn checkSupported(image: *const headers.ImageHeader, fh: *const headers.FrameHeader) Error!void {
    if (fh.maxHShift() | fh.maxVShift() != 0) {
        if (fh.modular) return error.Unsupported;
        if (fh.flags & headers.flag_skip_adaptive_lf_smoothing == 0) return error.BadHeader;
    }
    if (image.xyb) _ = color.Xyb.init(image) catch return error.Unsupported;
}

/// Decodes a frame's sections after its header and TOC.
pub fn decode(
    br: *BitReader,
    arena: *Arena,
    image: *const headers.ImageHeader,
    fh: *const headers.FrameHeader,
    toc: *const Toc,
    counts: [2]u32,
    refs: *const [4]?PatchSource,
    lf_in: ?LfImage,
    sink: ?vardct.CoeffSink,
    band: ?BandSink,
) Error!Decoded {
    var ctx: Context = .{
        .image = image,
        .fh = fh,
        .d = .init(fh),
        .counts = counts,
        .refs = refs,
        .lf_in = lf_in,
        .sink = sink,
    };
    if (band != null and toc.sizes.len > 1 and streams(image, fh, toc.permuted())) ctx.band = band;
    ctx.done = try arena.alloc(bool, toc.sizes.len);
    @memset(ctx.done, false);
    if (toc.sizes.len == 1) {
        try br.beginSection(toc.sizes[0]);
        try lfGlobal(br, arena, &ctx);
        try lfGroup(br, arena, &ctx, 0);
        try hfGlobal(br, arena, &ctx);
        try passGroup(br, arena, &ctx, 0, 0);
        try br.endSection();
    } else {
        const nlf = ctx.d.num_lf_groups;
        for (toc.sizes, toc.ids) |size, id| {
            if (ctx.done[id]) return error.BadHeader;
            ctx.done[id] = true;
            if (id != 0 and !ctx.got_global) return error.Unsupported;
            try br.beginSection(size);
            if (id == 0) {
                try lfGlobal(br, arena, &ctx);
            } else if (id <= nlf) {
                try lfGroup(br, arena, &ctx, id - 1);
            } else if (id == nlf + 1) {
                try hfGlobal(br, arena, &ctx);
            } else {
                const k = id - nlf - 2;
                try passGroup(br, arena, &ctx, k / ctx.d.num_groups, k % ctx.d.num_groups);
                if (ctx.band != null) try groupIn(arena, &ctx, k);
            }
            try br.endSection();
        }
    }
    if (ctx.band != null) {
        if (ctx.bands_out != ctx.d.ysize_groups) return error.BadImage;
        return .{ .img = ctx.full, .num_color = ctx.num_color, .w = ctx.d.width, .h = ctx.d.height, .streamed = true };
    }
    try ctx.full.undoTransforms(arena);
    // The channels must be back to the frame's layout.
    const want = ctx.num_color + image.num_ec;
    if (ctx.full.len != want) return error.BadImage;
    for (ctx.full.channels(), 0..) |c, i| {
        const w, const h = if (i < ctx.num_color)
            .{ ctx.d.width, ctx.d.height }
        else
            ecDims(&ctx.d, fh.ec_upsampling[i - ctx.num_color]);
        if (c.w != w or c.h != h) return error.BadImage;
    }
    const pixels = if (sink) |k| k.pixels else true;
    if (!pixels) if (ctx.vd) |vd| {
        for (vd.passes_done) |p| if (p != fh.passes.num) return error.BadImage;
    };
    if (!needsFloat(image, fh) or !pixels) return .{
        .img = ctx.full,
        .num_color = ctx.num_color,
        .w = ctx.d.width,
        .h = ctx.d.height,
    };
    return toPlanes(arena, &ctx);
}

/// Whether the frame's color goes through float planes: VarDCT, XYB, and
/// the restoration filters.
pub fn needsFloat(image: *const headers.ImageHeader, fh: *const headers.FrameHeader) bool {
    return !fh.modular or image.xyb or fh.filter.gab or fh.filter.epf_iters != 0 or upsampled(image, fh) or
        fh.flags & (headers.flag_noise | headers.flag_patches | headers.flag_splines) != 0 or fh.ycbcr or
        fh.kind == .lf;
}

/// An extra channel's stored size, upsampled `up` times to the frame's.
fn ecDims(d: *const headers.Dims, up: u32) struct { u32, u32 } {
    return .{
        @intCast((@as(u64, d.width_up) + up - 1) / up),
        @intCast((@as(u64, d.height_up) + up - 1) / up),
    };
}

fn upsampled(image: *const headers.ImageHeader, fh: *const headers.FrameHeader) bool {
    if (fh.upsampling != 1) return true;
    for (fh.ec_upsampling[0..image.num_ec]) |u| if (u != 1) return true;
    return false;
}

/// The frame's color as float planes, filtered and color-transformed.
fn toPlanes(arena: *Arena, ctx: *Context) Error!Decoded {
    const image = ctx.image;
    const fh = ctx.fh;
    const w: usize = ctx.d.width;
    const h: usize = ctx.d.height;
    var bw = (w + 7) / 8;
    var bh = (h + 7) / 8;
    var planes: [3][]f32 = undefined;
    var stride: usize = undefined;
    var img = ctx.full;
    if (ctx.vd) |vd| {
        for (vd.passes_done) |p| if (p != fh.passes.num) return error.BadImage;
        vardct.upsampleChroma(vd, w, h);
        planes = vd.planes;
        stride = vd.bw * 8;
        bw = vd.bw;
        bh = vd.bh;
    } else {
        stride = w;
        for (&planes) |*p| p.* = try arena.alloc(f32, w * h);
        const nc = ctx.num_color;
        for (0..3) |c| {
            var c_in: usize = if (nc == 1) 0 else c;
            var factor_bits = image.depth;
            if (image.xyb) {
                if (c < 2) c_in = 1 - c;
                factor_bits = undefined;
            }
            const ch = &img.buf[c_in];
            for (0..h) |y| {
                const in = ch.row(y)[0..w];
                const out = planes[c][y * w ..][0..w];
                if (!image.xyb) {
                    toFloat(factor_bits, in, out);
                } else if (c == 2) {
                    const ys = img.buf[0].row(y)[0..w];
                    for (out, in, ys) |*o, b, yy| o.* = @as(f32, @floatFromInt(b +% yy)) * ctx.lf_quant[c];
                } else {
                    for (out, in) |*o, v| o.* = @as(f32, @floatFromInt(v)) * ctx.lf_quant[c];
                }
            }
        }
        // The color channels now live in the planes.
        img.buf = img.buf[nc..];
        img.len -= nc;
    }
    const pl: filters.Planes = .{ .p = planes, .stride = stride, .w = w, .h = h };
    const rf = &fh.filter;
    if (rf.gab) try filters.gaborish(arena, &pl, rf, null);
    if (rf.epf_iters != 0) {
        const m = arena.mark();
        defer arena.release(m);
        const sig = try arena.alloc(f32, bw * bh);
        if (ctx.vd) |vd| vardct.epfSigmas(vd, rf, sig) else filters.sigmas(sig, rf, true, 0, &.{}, &.{});
        if (rf.epf_iters >= 3) try filters.epf(arena, &pl, rf, 0, sig, bw);
        try filters.epf(arena, &pl, rf, 1, sig, bw);
        if (rf.epf_iters >= 2) try filters.epf(arena, &pl, rf, 2, sig, bw);
    }
    // The extra channels leave `img` as floats when they are upsampled
    // or patched; those upsampled by another factor than the colors are
    // upsampled first (and then cannot be patched).
    var ec: ?[][]f32 = null;
    const ne = image.num_ec;
    const dw: usize = ctx.d.width_up;
    const dh: usize = ctx.d.height_up;
    var late_ec = fh.upsampling != 1;
    for (fh.ec_upsampling[0..ne]) |u| late_ec = late_ec and u == fh.upsampling;
    const patched = ctx.patches != null;
    if (upsampled(image, fh) or patched) {
        if (patched and fh.upsampling != 1 and !late_ec) return error.BadImage;
        const ecs = try arena.alloc([]f32, ne);
        for (ecs, img.channels()[0..ne], fh.ec_upsampling[0..ne], 0..) |*o, *ch, u, e| {
            const sw: usize = ch.w;
            const sh: usize = ch.h;
            // Upsampled now to the frame's size, or later with the colors.
            o.* = try arena.alloc(f32, if (u == 1 or late_ec) sw * sh else dw * dh);
            if (u == 1 or late_ec) {
                for (0..sh) |y| toFloat(image.ec[e].depth, ch.row(y)[0..sw], o.*[y * sw ..][0..sw]);
                continue;
            }
            const m = arena.mark();
            defer arena.release(m);
            const tmp = try arena.alloc(f32, sw * sh);
            for (0..sh) |y| toFloat(image.ec[e].depth, ch.row(y)[0..sw], tmp[y * sw ..][0..sw]);
            const k: upsample.Kernel = .init(image, u);
            upsample.upsample(&k, tmp, sw, sh, sw, o.*, dw, dh);
        }
        ec = ecs;
        if (ctx.patches) |*dict| {
            const all = try arena.alloc([]f32, 3 + ne);
            @memcpy(all[0..3], &planes);
            @memcpy(all[3..], ecs);
            patches.apply(dict, image, ctx.refs, all, stride, w, h);
        }
    }
    const base: [2]f32 = if (ctx.vd) |vd| .{ vd.base_x, vd.base_b } else .{ 0, if (image.xyb) 1 else 0 };
    if (ctx.splines) |*sp| {
        try splines.draw(arena, sp, planes, stride, w, h, @as(u64, dw) * dh, base[0], base[1]);
    }
    if (fh.upsampling != 1) {
        const k: upsample.Kernel = .init(image, fh.upsampling);
        var up: [3][]f32 = undefined;
        for (&up, planes) |*o, p| {
            o.* = try arena.alloc(f32, dw * dh);
            upsample.upsample(&k, p, w, h, stride, o.*, dw, dh);
        }
        planes = up;
        stride = dw;
        if (late_ec) {
            for (ec.?) |*o| {
                const up_ec = try arena.alloc(f32, dw * dh);
                upsample.upsample(&k, o.*, w, h, w, up_ec, dw, dh);
                o.* = up_ec;
            }
        }
    }
    if (ctx.noise) |*np| {
        const d = &ctx.d;
        try noise.apply(arena, np, .{
            .w = dw,
            .h = dh,
            .group_dim = d.group_dim,
            .groups_x = d.xsize_groups,
            .groups_y = d.ysize_groups,
            .upsampling = fh.upsampling,
            .visible = ctx.counts[0],
            .nonvisible = ctx.counts[1],
        }, planes, stride, base[0], base[1]);
    }
    const grey = image.colour.space == .grey;
    return .{
        .img = img,
        .num_color = if (grey) 1 else 3,
        .color = planes,
        .color_stride = stride,
        .ec = ec,
        .w = @intCast(dw),
        .h = @intCast(dh),
    };
}

/// Applies the frame's color transform to a decoded frame's planes, once
/// it has been saved for reference before it, if it is.
pub fn colorTransform(image: *const headers.ImageHeader, fh: *const headers.FrameHeader, dec: *const Decoded) void {
    colorTransformPlanes(image, fh, dec.color orelse return);
}

/// `colorTransform` of three planes of samples.
pub fn colorTransformPlanes(image: *const headers.ImageHeader, fh: *const headers.FrameHeader, planes: [3][]f32) void {
    if (image.xyb) {
        // checkSupported has made sure this succeeds.
        const x = color.Xyb.init(image) catch return;
        x.apply(planes);
    } else if (fh.ycbcr) {
        color.ycbcrToRgb(planes);
    }
}

fn hfGlobal(br: *BitReader, arena: *Arena, ctx: *Context) Error!void {
    const vd = ctx.vd orelse return;
    if (ctx.lf_done != ctx.d.num_lf_groups) return error.Unsupported;
    const skip = headers.flag_skip_adaptive_lf_smoothing | headers.flag_use_lf_frame;
    if (ctx.fh.flags & skip == 0) try vardct.smoothLf(arena, vd);
    try vardct.readHfGlobal(br, arena, vd, if (ctx.tree) |*t| t else null, ctx.d.num_lf_groups);
    ctx.got_hf_global = true;
}

fn lfGlobal(br: *BitReader, arena: *Arena, ctx: *Context) Error!void {
    const image = ctx.image;
    const fh = ctx.fh;
    if (fh.flags & headers.flag_patches != 0) {
        const d = &ctx.d;
        ctx.patches = try patches.read(
            br,
            arena,
            @as(u64, d.xsize_blocks) * 8,
            @as(u64, d.ysize_blocks) * 8,
            image,
            ctx.refs,
        );
    }
    if (fh.flags & headers.flag_splines != 0) ctx.splines = try splines.read(
        br,
        arena,
        @as(u64, ctx.d.width) * ctx.d.height,
    );
    if (fh.flags & headers.flag_noise != 0) ctx.noise = try .read(br);
    // LF dequantization weights.
    var lf_quant = quant.default_dc_quant;
    if (!try br.boolean()) {
        for (&lf_quant) |*q| {
            q.* = try br.f16Field() / 128;
            if (q.* < 1e-8) return error.BadHeader;
        }
    }
    ctx.lf_quant = lf_quant;
    if (!fh.modular) {
        const ring = if (ctx.band != null) ringRows(fh) else 0;
        const vd = try vardct.Shared.init(arena, image, fh, &ctx.d, ctx.sink, ring);
        try vardct.readLfGlobal(br, arena, vd, lf_quant);
        if (ctx.lf_in) |lf| try vardct.takeLf(vd, lf.planes, lf.w, lf.h);
        ctx.vd = vd;
    }
    // GlobalModular.
    const grey = image.colour.space == .grey;
    var nb_color: u32 = if (grey and !fh.ycbcr and !image.xyb) 1 else 3;
    const nb_extra = image.num_ec;
    if (try br.boolean()) {
        const px = @as(u64, ctx.d.width) * ctx.d.height;
        const limit = @min(1 << 22, 1024 + px * (nb_color + nb_extra) / 16);
        ctx.tree = try modular.readTree(br, arena, @intCast(limit));
    }
    if (!fh.modular) nb_color = 0;
    const depth = image.depth;
    if (depth.bits >= 32 and nb_color > 0 and !image.xyb) {
        if (depth.bits == 32 and !depth.float) return error.Unsupported;
        if (depth.bits > 32) return error.BadHeader;
    }
    ctx.num_color = nb_color;
    var img: modular.Image = try .init(arena, nb_color + nb_extra, ctx.d.width, ctx.d.height, depth.bits);
    for (img.channels()[nb_color..], 0..) |*c, e| {
        const up = fh.ec_upsampling[e];
        c.w, c.h = ecDims(&ctx.d, up);
        const s: i32 = @as(i32, std.math.log2_int_ceil(u32, up)) - std.math.log2_int_ceil(u32, fh.upsampling);
        c.hshift = @intCast(s);
        c.vshift = @intCast(s);
    }
    try modular.decodeStream(br, arena, &img, 0, .{
        .max_chan_size = ctx.d.group_dim,
        .group_dim = ctx.d.group_dim,
        .global = if (ctx.tree) |*t| t else null,
        .undo = false,
        // Without transforms, a streaming frame's channels are rings.
        .ring = if (ctx.band != null) modularRing(fh) else 0,
    });
    ctx.full = img;
    if (ctx.band != null) {
        // Global transforms are undone on the whole frame, so then it is
        // decoded whole (and its channels were given all their rows).
        if (img.transforms.len != 0) ctx.band = null;
        if (ctx.vd) |vd| {
            if (ctx.band == null) vd.ring_rows = 0;
            try vd.allocPlanes(arena);
        }
    }
    ctx.got_global = true;
}

const Rect = struct {
    x0: u64,
    y0: u64,
    w: u64,
    h: u64,
};

fn clampedSize(pos: u64, size: u64, end: u64) u64 {
    if (pos + size <= end) return size;
    return if (end > pos) end - pos else 0;
}

/// Decodes the channels of one group (an LF group or a pass group) whose
/// shift falls in `min_shift..max_shift`, within `rect` of the frame, and
/// copies them into the full image.
fn group(
    br: *BitReader,
    arena: *Arena,
    ctx: *Context,
    rect: Rect,
    min_shift: i32,
    max_shift: i32,
    stream_id: u32,
) Error!void {
    const full = &ctx.full;
    const gd = ctx.d.group_dim;
    var begin = full.nb_meta;
    while (begin < full.len) : (begin += 1) {
        const c = &full.buf[begin];
        if (c.w > gd or c.h > gd) break;
    }
    var n: usize = 0;
    for (full.channels()[begin..]) |*c| {
        if (try groupRect(c, rect, min_shift, max_shift)) |_| n += 1;
    }
    if (n == 0) return;
    const m = arena.mark();
    defer arena.release(m);
    var sub: modular.Image = try .init(arena, n, 0, 0, full.bitdepth);
    var k: usize = 0;
    for (full.channels()[begin..]) |*c| {
        const r = try groupRect(c, rect, min_shift, max_shift) orelse continue;
        sub.buf[k] = .{ .w = @intCast(r.w), .h = @intCast(r.h), .hshift = c.hshift, .vshift = c.vshift };
        k += 1;
    }
    try modular.decodeStream(br, arena, &sub, stream_id, .{ .global = if (ctx.tree) |*t| t else null });
    if (sub.len != n) return error.BadImage;
    k = 0;
    for (full.channels()[begin..]) |*c| {
        const r = try groupRect(c, rect, min_shift, max_shift) orelse continue;
        const s = &sub.buf[k];
        k += 1;
        if (s.w != r.w or s.h != r.h) return error.BadImage;
        for (0..@intCast(r.h)) |y| {
            const src = s.row(y);
            const dst = c.row(@intCast(r.y0 + y))[@intCast(r.x0)..][0..@intCast(r.w)];
            @memcpy(dst, src);
        }
    }
}

/// The part of channel `c` a group at `rect` holds, if the channel's
/// shift is in range and the part is not empty.
fn groupRect(c: *const modular.Channel, rect: Rect, min_shift: i32, max_shift: i32) Error!?Rect {
    const shift = @min(c.hshift, c.vshift);
    if (shift > max_shift or shift < min_shift) return null;
    if (c.hshift < 0 or c.vshift < 0 or c.hshift > 63 or c.vshift > 63) return error.BadImage;
    const hs: u6 = @intCast(c.hshift);
    const vs: u6 = @intCast(c.vshift);
    const x0 = rect.x0 >> hs;
    const y0 = rect.y0 >> vs;
    const r: Rect = .{
        .x0 = x0,
        .y0 = y0,
        .w = clampedSize(x0, rect.w >> hs, c.w),
        .h = clampedSize(y0, rect.h >> vs, c.h),
    };
    if (r.w == 0 or r.h == 0) return null;
    return r;
}

fn lfGroup(br: *BitReader, arena: *Arena, ctx: *Context, g: u32) Error!void {
    const d = &ctx.d;
    const dim: u64 = @as(u64, d.group_dim) * 8;
    const gx = g % d.xsize_lf_groups;
    const gy = g / d.xsize_lf_groups;
    const rect: Rect = .{ .x0 = gx * dim, .y0 = gy * dim, .w = dim, .h = dim };
    const tree = if (ctx.tree) |*t| t else null;
    if (ctx.vd) |vd| if (ctx.lf_in == null) try vardct.readLf(br, arena, vd, g, tree, ctx.full.bitdepth);
    try group(br, arena, ctx, rect, 3, 1000, 1 + d.num_lf_groups + g);
    if (ctx.vd) |vd| try vardct.readHfMeta(br, arena, vd, g, d.num_lf_groups, tree, ctx.full.bitdepth);
    ctx.lf_done += 1;
}

/// After group `g` of a streamed frame, whose groups come in order: once a
/// group row is in, the band before it is finished (its window reaches
/// into this row), and after the last, the last band too.
fn groupIn(arena: *Arena, ctx: *Context, g: usize) Error!void {
    const d = &ctx.d;
    if (g != ctx.rows_in * d.xsize_groups + d.xsize_groups - 1 and g + 1 != d.num_groups) return;
    ctx.rows_in += 1;
    if (ctx.vd == null) {
        // A Modular frame's group row is final as it is: no filter reads
        // past it.
        const k = ctx.rows_in - 1;
        const y0 = k * d.group_dim;
        const rows = @min(d.group_dim, d.height - y0);
        const sink = ctx.band.?;
        sink.write(sink.ctx, null, 0, &ctx.full, y0, rows);
        ctx.bands_out += 1;
        return;
    }
    if (ctx.rows_in == 1) {
        // The window and sigmas, once the LF groups' fields are in.
        const vd = ctx.vd.?;
        const rows: usize = d.group_dim + 2 * band_margin;
        for (&ctx.window) |*p| p.* = try arena.alloc(f32, rows * vd.bw * 8);
        const rf = &ctx.fh.filter;
        if (rf.epf_iters != 0) {
            ctx.sigmas = try arena.alloc(f32, vd.bw * vd.bh);
            vardct.epfSigmas(vd, rf, ctx.sigmas);
        }
    }
    if (ctx.rows_in >= 2) try emitBand(arena, ctx, ctx.rows_in - 2);
    if (ctx.rows_in == d.ysize_groups) try emitBand(arena, ctx, ctx.rows_in - 1);
}

/// Filters group row `k`'s pixels on a window with `band_margin` rows of
/// the rows around it, then hands them to the band sink.
fn emitBand(arena: *Arena, ctx: *Context, k: usize) Error!void {
    const vd = ctx.vd.?;
    const d = &ctx.d;
    const h: usize = d.height;
    const gd: usize = d.group_dim;
    const stride = vd.bw * 8;
    const y0 = k * gd;
    const y1 = @min(h, y0 + gd);
    const ws = y0 -| band_margin;
    const we = @min(h, y1 + band_margin);
    const rf = &ctx.fh.filter;
    var win: [3][]f32 = undefined;
    for (&win, ctx.window, vd.planes) |*o, buf, plane| {
        o.* = buf[0 .. (we - ws) * stride];
        // Gaborish writes the window from the planes instead.
        if (!rf.gab) for (ws..we) |y| {
            @memcpy(o.*[(y - ws) * stride ..][0..stride], plane[vd.planeRow(y) * stride ..][0..stride]);
        };
    }
    // Mirrored at the window's edges, which are wrong only within the
    // margin, except at the frame's, where mirroring is right.
    const pl: filters.Planes = .{ .p = win, .stride = stride, .w = d.width, .h = we - ws };
    const src: filters.Source = .{ .p = vd.planes, .stride = stride, .y0 = ws, .ring_rows = vd.ring_rows };
    if (rf.gab) try filters.gaborish(arena, &pl, rf, src);
    if (rf.epf_iters != 0) {
        const sig = ctx.sigmas[(ws / 8) * vd.bw ..];
        if (rf.epf_iters >= 3) try filters.epf(arena, &pl, rf, 0, sig, vd.bw);
        try filters.epf(arena, &pl, rf, 1, sig, vd.bw);
        if (rf.epf_iters >= 2) try filters.epf(arena, &pl, rf, 2, sig, vd.bw);
    }
    var band: [3][]f32 = undefined;
    for (&band, win) |*o, p| o.* = p[(y0 - ws) * stride ..][0 .. (y1 - y0) * stride];
    const sink = ctx.band.?;
    sink.write(sink.ctx, band, stride, &ctx.full, y0, y1 - y0);
    ctx.bands_out += 1;
}

fn passGroup(br: *BitReader, arena: *Arena, ctx: *Context, pass: u32, g: u32) Error!void {
    const d = &ctx.d;
    const dim: u64 = d.group_dim;
    const gx = g % d.xsize_groups;
    const gy = g / d.xsize_groups;
    const rect: Rect = .{ .x0 = gx * dim, .y0 = gy * dim, .w = dim, .h = dim };
    if (ctx.vd) |vd| {
        if (!ctx.got_hf_global) return error.Unsupported;
        try vardct.readPassGroup(br, arena, vd, pass, g);
    }
    const b = bracket(&ctx.fh.passes, pass);
    const id = 1 + 3 * d.num_lf_groups + num_quant_tables + d.num_groups * pass + g;
    try group(br, arena, ctx, rect, b[0], b[1], id);
}

/// The range of channel shifts pass `pass` holds.
fn bracket(p: *const headers.Passes, pass: u32) [2]i32 {
    var max_shift: i32 = 2;
    var min_shift: i32 = 3;
    var i: u32 = 0;
    while (true) : (i += 1) {
        for (0..p.num_ds) |j| {
            if (i == p.last_pass[j]) {
                min_shift = switch (p.downsample[j]) {
                    8 => 3,
                    4 => 2,
                    2 => 1,
                    else => 0,
                };
            }
        }
        if (i == p.num - 1) min_shift = 0;
        if (i == pass) return .{ min_shift, max_shift };
        max_shift = min_shift - 1;
    }
}

/// Converts stored integers of `depth` to floats as the reference
/// decoder does: integers scaled by 1 / (2^bits - 1), floats unpacked.
pub fn toFloat(depth: headers.BitDepth, in: []const i32, out: []f32) void {
    if (depth.float) {
        for (in, out) |v, *o| o.* = intToFloat(v, depth.bits, depth.exp_bits);
        return;
    }
    const factor64 = 1.0 / @as(f64, @floatFromInt((@as(u64, 1) << @intCast(depth.bits)) - 1));
    if (depth.bits < 23) {
        const factor: f32 = @floatCast(factor64);
        for (in, out) |v, *o| o.* = @as(f32, @floatFromInt(v)) * factor;
    } else {
        for (in, out) |v, *o| o.* = @floatCast(@as(f64, @floatFromInt(v)) * factor64);
    }
}

/// A float of `bits` bits with `exp_bits` exponent bits, stored as an
/// integer, as a 32-bit float.
pub fn intToFloat(v: i32, bits: u32, exp_bits: u32) f32 {
    if (bits == 32) return @bitCast(v);
    var f: u32 = @bitCast(v);
    const bias: i32 = (@as(i32, 1) << @intCast(exp_bits - 1)) - 1;
    const sign_shift: u5 = @intCast(bits - 1);
    const mant_bits: u5 = @intCast(bits - exp_bits - 1);
    const mant_shift: u5 = @intCast(23 - @as(u32, mant_bits));
    const sign = (f >> sign_shift) & 1;
    f &= (@as(u32, 1) << sign_shift) - 1;
    if (f == 0) return if (sign == 1) -0.0 else 0.0;
    var exp: i32 = @intCast(f >> mant_bits);
    var mant: u32 = f & ((@as(u32, 1) << mant_bits) - 1);
    if (exp == (@as(i32, 1) << @intCast(exp_bits)) - 1) {
        const r: u32 = (sign << 31) | (0xff << 23) | (mant << mant_shift);
        return @bitCast(r);
    }
    mant <<= mant_shift;
    if (exp == 0 and exp_bits < 8) {
        while (mant & 0x800000 == 0) {
            mant <<= 1;
            exp -= 1;
        }
        exp += 1;
        mant &= 0x7fffff;
    }
    exp = exp - bias + 127;
    if (exp < 0) exp = 0;
    const r: u32 = (sign << 31) | (@as(u32, @intCast(exp)) << 23) | mant;
    return @bitCast(r);
}

test "bracket" {
    const one: headers.Passes = .{};
    try testing.expectEqual([2]i32{ 0, 2 }, bracket(&one, 0));
}

test "permutation" {
    // Nothing to read beyond the code: covered by the conformance files.
    try testing.expectEqual(@as(usize, 0), permContext(0));
    try testing.expectEqual(@as(usize, 7), permContext(1000));
}
