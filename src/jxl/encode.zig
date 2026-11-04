//! The JPEG XL lossless encoder (ISO/IEC 18181-1): one Modular frame in a
//! bare codestream. src/encode.zig has the contract; nothing is
//! allocated, and the work memory holds one group's channels and tokens,
//! the samples a tree is learned from, and the compressed sections, which
//! must all be known before the table of contents that precedes them.
//!
//! - The file decodes to the source converted by `image.convert` to the
//!   stored format: the source's channels (CMYK becomes RGB), straight or
//!   premultiplied as the source is, at 8 bits for 8-bit sources and 16
//!   otherwise. Alpha is an extra channel, `alpha_associated` when the
//!   source is premultiplied. Color is sRGB.
//! - The image is split into groups of 256 by 256. One tree, learned from
//!   pixels sampled across the groups, and one set of histograms code
//!   every group. A palette replaces the colors when there are few, and
//!   otherwise a reversible color transform, chosen by a cost estimate on
//!   sampled rows, decorrelates RGB.
//! - Effort trades speed for size: the predictors a leaf may choose, the
//!   weighted predictor, the samples, and the tree's size.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const shared = @import("../encode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const BitWriter = @import("encode_bits.zig").BitWriter;
const Bump = @import("encode_mem.zig").Bump;
const ent = @import("encode_entropy.zig");
const mod = @import("encode_modular.zig");
const Plane = mod.Plane;
const Token = ent.Token;

/// How hard the encoder works to make the file small.
pub const Effort = enum {
    /// The gradient predictor, a small tree, few samples.
    fast,
    /// A choice of four predictors with the weighted predictor and its
    /// property.
    default,
    /// Every predictor, more samples and thresholds, a larger tree.
    best,
};

pub const EncodeOptions = struct {
    effort: Effort = .default,
};

pub const EncodeError = shared.Error || error{
    /// JPEG XL cannot store an image without rows or columns.
    EmptyImage,
};

const group_dim = 256;
const group_shift = 1; // 128 << 1
/// The largest side the size header holds.
const max_side = 1 << 30;
/// The most sections a frame may have (the decoder's limit).
const max_toc_entries = 65536;
const num_quant_tables = 17;

const Params = struct {
    predictors: []const mod.Predictor,
    wp_prop: bool,
    /// Samples learning takes: one in 16 of the image's (four a pixel),
    /// from `samples` to `samples_max`.
    samples: usize,
    samples_max: usize,
    thresholds: u32,
    max_leaves: u32,
    split_cost: f32,
    palette_max: u32,
    /// Pixels the color transform search looks at.
    rct_pixels: usize,
    /// Earlier channels whose values are properties.
    refs: u32,
    /// Samples a split is judged on, at most.
    split_samples: u32,
    /// Splits are judged with this many of a node's cheapest predictors;
    /// 0 for all.
    search_predictors: u32,
};

fn params(effort: Effort) Params {
    return switch (effort) {
        .fast => .{
            .predictors = &.{.gradient},
            .wp_prop = false,
            .samples = 1 << 15,
            .samples_max = 1 << 15,
            .thresholds = 16,
            .max_leaves = 256,
            .split_cost = 64,
            .palette_max = 256,
            .rct_pixels = 1 << 10,
            .refs = 0,
            .split_samples = 4096,
            .search_predictors = 0,
        },
        .default => .{
            .predictors = &.{ .gradient, .weighted, .left, .top },
            .wp_prop = true,
            .samples = 1 << 18,
            .samples_max = 1 << 20,
            .thresholds = 32,
            .max_leaves = 1024,
            .split_cost = 48,
            .palette_max = 1024,
            .rct_pixels = 1 << 15,
            .refs = 2,
            .split_samples = 16384,
            .search_predictors = 2,
        },
        .best => .{
            .predictors = &.{
                .gradient,  .weighted, .left,      .top,      .zero,     .average0, .select,
                .top_right, .top_left, .left_left, .average1, .average2, .average3, .average4,
            },
            .wp_prop = true,
            .samples = 1 << 19,
            .samples_max = 1 << 19,
            .thresholds = 64,
            .max_leaves = 2048,
            .split_cost = 40,
            .palette_max = 1024,
            .rct_pixels = 1 << 16,
            .refs = 3,
            .split_samples = 16384,
            .search_predictors = 0,
        },
    };
}

/// What the file stores.
const Layout = struct {
    stored: PixelFormat,
    /// Color channels: 1 or 3.
    nc: u32,
    alpha: bool,
    premul: bool,
    bits: u32,
    w: u32,
    h: u32,
    xg: u32,
    yg: u32,
    num_groups: u32,
    num_lf_groups: u32,

    fn init(format: PixelFormat, w: u32, h: u32) Layout {
        const stored: PixelFormat = switch (format) {
            .bgr8, .cmyk8 => .rgb8,
            .bgra8 => .rgba8,
            .bgra8_premul => .rgba8_premul,
            .bgr16, .cmyk16 => .rgb16,
            .bgra16, .rgba_f32 => .rgba16,
            .bgra16_premul, .rgba_f32_premul => .rgba16_premul,
            .rgb_f32 => .rgb16,
            .gray_f32 => .gray16,
            .gray8, .gray_alpha8, .gray_alpha8_premul, .rgb8, .rgba8, .rgba8_premul => format,
            .gray16, .gray_alpha16, .gray_alpha16_premul, .rgb16, .rgba16, .rgba16_premul => format,
        };
        const xg = (w + group_dim - 1) / group_dim;
        const yg = (h + group_dim - 1) / group_dim;
        const lf = group_dim * 8;
        const xlg = (w + lf - 1) / lf;
        const ylg = (h + lf - 1) / lf;
        return .{
            .stored = stored,
            .nc = if (stored.isGray()) 1 else 3,
            .alpha = stored.hasAlpha(),
            .premul = stored.isPremultiplied(),
            .bits = if (stored.sample() == .u8) 8 else 16,
            .w = w,
            .h = h,
            .xg = xg,
            .yg = yg,
            .num_groups = xg * yg,
            .num_lf_groups = xlg * ylg,
        };
    }

    fn channels(l: *const Layout) u32 {
        return l.nc + @intFromBool(l.alpha);
    }

    fn single(l: *const Layout) bool {
        return l.num_groups == 1;
    }

    fn tocEntries(l: *const Layout) u64 {
        if (l.single()) return 1;
        return 2 + @as(u64, l.num_lf_groups) + l.num_groups;
    }

    /// The largest tree the decoder accepts (modular.readTree's limit for
    /// a global tree).
    fn treeLimit(l: *const Layout) u64 {
        const px = @as(u64, l.w) * l.h;
        return @min(1 << 22, 1024 + px * l.channels() / 16);
    }
};

/// The widest stored pixel: 16-bit RGBA.
const max_channels = 4;
const max_bpp = 8;

/// The work memory's parts, sized for the worst source format.
const Sizes = struct {
    out: usize,
    toc: usize,
    planes: usize,
    rows: usize,
    tokens: usize,
    hash: usize,
    samples: usize,
    learn: usize,
    nodes: usize,
    histograms: usize,
    code: usize,
    write: usize,
    wp: usize,
    store: usize,
    streams: usize,

    fn init(p: Params, w: u32, h: u32) ?Sizes {
        if (w == 0 or h == 0 or w > max_side or h > max_side) return null;
        const lay: Layout = .init(.rgba16, w, h);
        if (lay.tocEntries() > max_toc_entries) return null;
        const gw: usize = @min(w, group_dim);
        const gh: usize = @min(h, group_dim);
        const pal: usize = p.palette_max;
        // A stream's samples; also room for two rows of the color
        // transform search.
        const stream_samples = @max(max_channels * gw * gh + pal * max_channels, 2 * max_channels * group_dim);
        const pixels = @as(u64, w) * h;
        const all_samples = std.math.mul(u64, pixels, max_channels) catch return null;
        const leaves: usize = maxLeaves(p, &lay);
        const clusters = maxClusters(w, h);
        // Sections: six bytes a sample at most (see `encodeImpl`), the tree,
        // its context map and histograms, and each stream's header and
        // padding.
        const sample_bytes = std.math.mul(u64, all_samples + pal * max_channels, 6) catch return null;
        const fixed = 64 * (@as(u64, lay.num_groups) + 2) + leaves * 2 * 5 * 8 + 7 * 256 * 4 +
            leaves * 8 + clusters * (256 * 3 + 4) + 4096;
        const out = std.math.add(u64, sample_bytes, fixed) catch return null;
        if (out > std.math.maxInt(usize)) return null;
        return .{
            .out = @intCast(out),
            .toc = @intCast(lay.tocEntries() * 4 + 4096),
            .planes = stream_samples * 4,
            .rows = @max(gw, pal) * max_bpp,
            .tokens = stream_samples * @sizeOf(Token) + @max(stream_samples, (2 * leaves + 1) * 5) * 4,
            // The palette's hash, keys, colors, and order, its plane,
            // and the rows its search reads.
            .hash = hash_size * 2 + pal * 8 + pal * max_channels * 2 + pal * 2 + pal * max_channels * 4 +
                max_channels * @max(gw, pal) * 4,
            .samples = samplesMemory(p, w, h),
            .learn = mod.learnMemory(learnOptions(p, @intCast(leaves))),
            .nodes = (2 * leaves + 1) * (@sizeOf(mod.Node) + @sizeOf(mod.Flat)) + (2 * leaves + 1) * 5 * @sizeOf(Token),
            .histograms = leaves * ent.alphabet * 4 + 6 * ent.alphabet * 4,
            .code = ent.buildMemory(leaves, clusters) + ent.buildMemory(6, 6),
            .write = ent.writeMemory(leaves),
            .wp = mod.Wp.memory(@max(gw, pal)),
            .store = @as(usize, @intCast(@min(all_samples + pal * max_channels, store_tokens))) * 4,
            // The streams' lengths and transforms, and the sections' sizes.
            .streams = (lay.num_groups + 1) * 4 + 2 * lay.num_groups + @as(usize, @intCast(lay.tocEntries())) * 4,
        };
    }

    /// Learning's memory is released before the tokens are counted, so
    /// the samples and the parts made after them share it.
    fn total(s: Sizes) ?usize {
        var t: usize = 0;
        var learning: usize = 0;
        var after: usize = 0;
        inline for (@typeInfo(Sizes).@"struct".field_names) |name| {
            const part = std.math.add(usize, @field(s, name), 64) catch return null;
            const sum = if (comptime isLearning(name))
                &learning
            else if (comptime isAfterLearning(name))
                &after
            else
                &t;
            sum.* = std.math.add(usize, sum.*, part) catch return null;
        }
        return std.math.add(usize, t, @max(learning, after)) catch null;
    }

    fn isLearning(comptime name: []const u8) bool {
        return std.mem.eql(u8, name, "samples") or std.mem.eql(u8, name, "learn");
    }

    fn isAfterLearning(comptime name: []const u8) bool {
        inline for (.{ "histograms", "store", "code", "write" }) |n| {
            if (std.mem.eql(u8, name, n)) return true;
        }
        return false;
    }
};

/// The most leaves an image's tree may have: the effort's, the decoder's
/// limit, and one in 64 of its samples (at least 16), since a split must
/// pay for itself and a small image's trees are small. Work tables are
/// sized by it.
fn maxLeaves(p: Params, lay: *const Layout) u32 {
    const samples = @as(u64, lay.w) * lay.h * max_channels;
    return @intCast(@min(p.max_leaves, (lay.treeLimit() + 1) / 2, @max(16, samples / 64)));
}

/// The most histograms an image's code may have: one in 1024 of its
/// samples, from 16 to the coder's 256. Few tokens do not pay for many
/// histograms, and each costs the code 11 KiB of tables.
fn maxClusters(w: u32, h: u32) usize {
    const samples = @as(u64, w) * h * max_channels;
    return @intCast(std.math.clamp(samples / 1024, 16, ent.max_clusters));
}

fn samplesMemory(p: Params, w: u32, h: u32) usize {
    const cap = sampleCap(p, w, h);
    const room = sampleRoom(p, w, h);
    const whole = if (cap <= single_pass_samples) cap else mod.thresholdSamples(cap);
    return mod.Samples.memory(room, @min(whole, room), &learnOptions(p, 0), packRows(p, w, h));
}

/// Whether the samples' rows are packed: when the image is sampled in two
/// passes and its rows would otherwise take more memory than the token
/// store, which reuses theirs, so that they would set the peak.
fn packRows(p: Params, w: u32, h: u32) bool {
    if (sampleCap(p, w, h) <= single_pass_samples) return false;
    const store = @min(@as(u64, w) * h * max_channels + p.palette_max * max_channels, store_tokens) * 4;
    return sampleRoom(p, w, h) * mod.Samples.rowBytes(&learnOptions(p, 0), false) > store;
}

/// The samples an image can give, at most: its channels hold at most four
/// samples a pixel, and a palette's channel is one a pixel plus at most an
/// eighth of the pixels' colors in four (`usePalette`). `sampleCap`
/// allows for the palette on top, so this is what its samples need.
fn sampleRoom(p: Params, w: u32, h: u32) usize {
    return @intCast(@min(sampleCap(p, w, h), @as(u64, w) * h * max_channels));
}

/// Images with at most this many samples choose thresholds from all of
/// them.
const single_pass_samples = 1 << 15;

/// Samples a band of rows from every stream into `smp`, one pixel in its
/// stride, up to its cap. A band is `share` of a channel's rows, at an
/// offset that moves from stream to stream.
fn sampleStreams(
    mem: *Bump,
    c: *Ctx,
    smp: *mod.Samples,
    lo: *const mod.LearnOptions,
    max_refs: u32,
    plane_list: *[max_channels + 1]Plane,
    share: f64,
) !void {
    const ns = numStreams(&c.lay);
    var k: u32 = 0;
    while (k < ns) : (k += 1) {
        const s = streamAt(c, k);
        const n = buildPlanes(c, s, plane_list);
        for (plane_list[0..n], 0..) |pl, ci| {
            // The palette is sampled whole.
            const meta = s.meta and ci == 0;
            const want: u32 = @intFromFloat(@ceil(share * @as(f64, @floatFromInt(pl.h))));
            const rows: u32 = if (meta) pl.h else @max(1, want);
            const y0: u32 = if (rows >= pl.h) 0 else @intCast((@as(u64, k) * 2654435761) % (pl.h - rows + 1));
            var rb: [mod.max_refs]Plane = undefined;
            const refs = refsOf(plane_list[0..n], ci, s.meta, max_refs, &rb);
            try mod.sample(mem, smp, pl, @intCast(ci), s.id, lo, refs, y0, y0 + rows);
        }
    }
}

/// The samples a tree is learned from: the effort's, more for a large
/// image at an effort that scales them, or every sample of a smaller
/// image.
fn sampleCap(p: Params, w: u32, h: u32) usize {
    const pixels = @as(u64, w) * h;
    const want = std.math.clamp(pixels * max_channels / 16, p.samples, p.samples_max);
    return @intCast(@min(want, pixels * max_channels + p.palette_max * max_channels));
}

fn learnOptions(p: Params, leaves: u32) mod.LearnOptions {
    return .{
        .predictors = p.predictors,
        .wp_prop = p.wp_prop,
        .max_thresholds = p.thresholds,
        .max_leaves = leaves,
        .split_cost = p.split_cost,
        .refs = p.refs,
        .split_samples = p.split_samples,
        .search_predictors = p.search_predictors,
    };
}

/// The work memory `encode` needs for a `width` by `height` image, or
/// null when JPEG XL (or this encoder) cannot store it.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    const s = Sizes.init(params(options.effort), width, height) orelse return null;
    return s.total();
}

const hash_size = 4096;
/// The most tokens kept between counting and writing (16 MiB).
const store_tokens = 1 << 22;

/// The image's distinct colors, when there are at most `max`.
const Palette = struct {
    /// Per slot, the color's index plus one, or 0 when empty.
    slots: []u16,
    keys: []u64,
    /// Colors in insertion order, channel by channel within a color.
    colors: []u16,
    /// The index each color gets after sorting.
    order: []u16,
    len: usize = 0,
    nch: usize,
    max: usize,

    fn hash(k: u64) usize {
        return @intCast((k *% 0x9E3779B97F4A7C15) >> (64 - 12));
    }

    /// Adds `key`; false when the palette is full.
    inline fn add(p: *Palette, key: u64, color: []const u16) bool {
        var i = hash(key);
        while (true) : (i = (i + 1) & (hash_size - 1)) {
            const s = p.slots[i];
            if (s == 0) break;
            if (p.keys[s - 1] == key) return true;
        }
        if (p.len == p.max) return false;
        p.keys[p.len] = key;
        @memcpy(p.colors[p.len * p.nch ..][0..p.nch], color);
        p.len += 1;
        p.slots[i] = @intCast(p.len);
        return true;
    }

    fn reset(p: *Palette) void {
        @memset(p.slots, 0);
        p.len = 0;
    }

    inline fn index(p: *const Palette, key: u64) i32 {
        var i = hash(key);
        while (true) : (i = (i + 1) & (hash_size - 1)) {
            const s = p.slots[i];
            if (p.keys[s - 1] == key) return p.order[s - 1];
        }
    }
};

/// The pixels of a row, deinterleaved into `nch` channels of u16.
const RowReader = struct {
    src: PixelBuffer,
    conv: Converter,
    lay: *const Layout,
    buf: []u8,

    fn read(r: *const RowReader, x0: u32, y: u32, w: u32, out: *[max_channels][]i32) void {
        const bpp = r.src.format.bytesPerPixel();
        const in = r.src.row(y)[@as(usize, x0) * bpp ..][0 .. @as(usize, w) * bpp];
        r.conv.run(r.buf, in, w);
        const nch = r.lay.channels();
        if (r.lay.bits == 8) {
            for (0..w) |x| {
                for (0..nch) |c| out[c][x] = r.buf[x * nch + c];
            }
        } else {
            const s: []align(1) const u16 = @ptrCast(r.buf[0 .. @as(usize, w) * nch * 2]);
            for (0..w) |x| {
                for (0..nch) |c| out[c][x] = s[x * nch + c];
            }
        }
    }
};

inline fn colorKey(v: *const [max_channels]i32, nch: usize) u64 {
    var k: u64 = 0;
    for (0..nch) |c| k |= @as(u64, @as(u16, @intCast(v[c]))) << @intCast(16 * c);
    return k;
}

// Reversible color transforms.

/// The channels in the order a transform of type `t` takes them.
inline fn permute(t: u32, v: [3]i32) [3]i32 {
    const perm = t / 7;
    return .{ v[perm % 3], v[(perm + 1 + perm / 3) % 3], v[(perm + 2 - perm / 3) % 3] };
}

/// The forward transform of type `t` (the inverse of modular.invRct).
inline fn rct(t: u32, v_in: [3]i32) [3]i32 {
    const v = permute(t, v_in);
    const custom = t % 7;
    if (custom == 0) return v;
    if (custom == 6) {
        const co = v[0] - v[2];
        const tmp = v[2] + (co >> 1);
        const cg = v[1] - tmp;
        return .{ tmp + (cg >> 1), co, cg };
    }
    const a = v[0];
    var s = v[1];
    var c = v[2];
    const second = custom >> 1;
    if (second == 1) s -= a else if (second == 2) s -= (a + c) >> 1;
    if (custom & 1 == 1) c -= a;
    return .{ a, s, c };
}

/// The 42 transforms' 126 channels hold fewer distinct functions of R, G,
/// and B: `unique` has one transform and channel for each, and `of` maps
/// each transform's channels to them. Functions are told apart by their
/// values on a few colors.
const rct_channels = blk: {
    @setEvalBranchQuota(100000);
    const probes = [_][3]i32{
        .{ 0, 0, 0 },        .{ 1, 0, 0 },      .{ 0, 1, 0 },     .{ 0, 0, 1 },
        .{ 255, 3, 70 },     .{ 9, 200, 31 },   .{ 77, 12, 254 }, .{ -5, 300, 41 },
        .{ 1000, -999, 13 }, .{ 7, 7, 65535 },  .{ 123, 45, 67 }, .{ 31, 63, 127 },
        .{ 3, 1, 2 },        .{ 65535, 2, 99 }, .{ 50, 51, 49 },  .{ 600, 17, 333 },
    };
    var unique: [126][2]u32 = undefined;
    var sig: [126][probes.len]i32 = undefined;
    var nu: usize = 0;
    var of: [42][3]u8 = undefined;
    for (0..42) |t| {
        for (0..3) |c| {
            var v: [probes.len]i32 = undefined;
            for (probes, 0..) |pr, i| v[i] = rct(t, pr)[c];
            const e = for (sig[0..nu], 0..) |s, i| {
                if (std.mem.eql(i32, &s, &v)) break i;
            } else new: {
                sig[nu] = v;
                unique[nu] = .{ t, c };
                nu += 1;
                break :new nu - 1;
            };
            of[t][c] = e;
        }
    }
    const unique_final = unique[0..nu].*;
    const of_final = of;
    break :blk struct {
        unique: [nu][2]u32,
        of: [42][3]u8,
    }{ .unique = unique_final, .of = of_final };
};

/// Estimated bits of a region's channels: their clamped-gradient residuals
/// on row segments, as many as they are wide, spread over the region, about
/// `pixels` pixels in all.
const Costs = struct {
    /// Each RCT's three channels, for RGB.
    rct: [42]f64 = @splat(0),
    /// The channels no RCT takes: gray, and alpha.
    rest: f64 = 0,
    /// The palette's indices, when there is a palette.
    pal: f64 = 0,
    /// Pixels sampled.
    pixels: f64 = 0,

    /// The RCT that costs least.
    fn best(c: *const Costs) u32 {
        var b: u32 = 6;
        for (0..42) |t| {
            // Prefer YCoCg on ties.
            if (c.rct[t] < c.rct[b]) b = @intCast(t);
        }
        return b;
    }
};

fn regionCosts(c: *Ctx, r: Rect, rows: *[2][max_channels][]i32, pixels: usize, pal: ?*const Palette) Costs {
    const w = r.w;
    var out: Costs = .{};
    if (r.h < 2 or w < 2) return out;
    const lay = &c.lay;
    const nch = lay.channels();
    const n_rows: u32 = @intCast(@max(1, @min(r.h - 1, std.math.sqrt(pixels))));
    const seg: u32 = @intCast(@max(2, @min(w, group_dim, pixels / n_rows)));
    const step = (r.h - 1) / n_rows;
    var counts: [rct_channels.unique.len][64]u32 = @splat(@splat(0));
    var rest: [max_channels][64]u32 = @splat(@splat(0));
    var idx: [64]u32 = @splat(0);
    const cfg: ent.Config = .{};
    var k: u32 = 0;
    while (k < n_rows) : (k += 1) {
        const y = r.y0 + 1 + k * step;
        const x0: u32 = r.x0 + @as(u32, @intCast((@as(u64, k) * 2654435761) % (w - seg + 1)));
        const n = seg;
        c.rr.read(x0, y - 1, n, &rows[0]);
        c.rr.read(x0, y, n, &rows[1]);
        if (lay.nc == 3) {
            // Each distinct transformed channel, specialized, over the two
            // rows at once.
            inline for (rct_channels.unique, 0..) |tc, e| {
                var tr: [2][group_dim]i32 = undefined;
                for (0..2) |i| {
                    for (0..n) |x| tr[i][x] = rct(tc[0], .{ rows[i][0][x], rows[i][1][x], rows[i][2][x] })[tc[1]];
                }
                gradientHist(tr[0][0..n], tr[1][0..n], &counts[e], cfg);
            }
        }
        // The rest only matters next to a palette.
        if (pal == null) continue;
        for (if (lay.nc == 3) 3 else 0..nch) |ch| gradientHist(rows[0][ch][0..n], rows[1][ch][0..n], &rest[ch], cfg);
        if (pal) |p| {
            var ix: [2][group_dim]i32 = undefined;
            var px: [max_channels]i32 = undefined;
            for (0..2) |i| {
                for (0..n) |x| {
                    for (0..nch) |ch| px[ch] = rows[i][ch][x];
                    ix[i][x] = p.index(colorKey(&px, nch));
                }
            }
            gradientHist(ix[0][0..n], ix[1][0..n], &idx, cfg);
        }
    }
    out.pixels = @floatFromInt(@as(u64, n_rows) * (seg - 1));
    if (lay.nc == 3) {
        var cost: [rct_channels.unique.len]f64 = undefined;
        for (&cost, &counts) |*o, *h| o.* = histCost(h, cfg);
        for (0..42) |t| {
            for (0..3) |ch| out.rct[t] += cost[rct_channels.of[t][ch]];
        }
    }
    for (&rest) |*h| out.rest += histCost(h, cfg);
    out.pal = histCost(&idx, cfg);
    return out;
}

fn gradientHist(up: []const i32, cur: []const i32, hist: *[64]u32, cfg: ent.Config) void {
    for (1..cur.len) |x| {
        const g = mod.clampedGradient(up[x], cur[x - 1], up[x - 1]);
        const tok = cfg.split(ent.packSigned(@truncate(cur[x] - g))).token;
        hist[@min(tok, 63)] += 1;
    }
}

fn histCost(c: *const [64]u32, cfg: ent.Config) f64 {
    var total: u64 = 0;
    for (c) |k| total += k;
    if (total == 0) return 0;
    const lt = std.math.log2(@as(f64, @floatFromInt(total)));
    var bits: f64 = 0;
    for (c, 0..) |k, t| {
        if (k == 0) continue;
        const kf: f64 = @floatFromInt(k);
        const split = @as(u32, 1) << cfg.split_exp;
        const above: u32 = if (t < split) 0 else (@as(u32, @intCast(t)) - split) >> (cfg.msb + cfg.lsb);
        const extra: f64 = if (t < split) 0 else @floatFromInt(@as(u32, cfg.split_exp) - cfg.msb - cfg.lsb + above);
        bits += kf * (lt - std.math.log2(kf) + extra);
    }
    return bits;
}

// Streams.

/// The transforms a stream declares, or that its channels follow.
const Transforms = struct {
    palette: ?*const Palette = null,
    rct: u32 = 0,
};

/// A group's own transform: an RCT type, or a palette of its colors.
const local_palette = 255;
/// How much cheaper, estimated, a group's best RCT must be than the
/// image's for the group to take it. The tree is shared, and channels
/// that differ from group to group fit it worse.
const rct_margin = 0.03;
/// Estimated bits of a palette entry's sample.
const pal_entry_bits = 5.0;
/// A group with at most this many colors takes a palette whatever the
/// estimate says.
const few_colors = 8;
/// When this share of the groups can take a palette, they all do. The
/// estimate, without the tree's contexts, undervalues palettes on text.
const pal_majority = 0.7;

const Ctx = struct {
    lay: Layout,
    /// The global stream's transforms.
    tr: Transforms,
    /// Each group's own transform, when the global stream declares none
    /// and there are several groups; else empty.
    local: []u8 = &.{},
    /// A group's palette, made again whenever the group is.
    local_pal: *Palette,
    rr: RowReader,
    /// Channel buffers for one stream.
    planes: []i32,
    rows: [max_channels][]i32,
    pal_plane: []i32,
};

const Rect = struct {
    x0: u32,
    y0: u32,
    w: u32,
    h: u32,
};

/// A stream: the global one (with the palette, and with the image's
/// channels when there is one group) or a group's.
const Stream = struct {
    id: u32,
    rect: Rect,
    /// Whether the palette's meta channel comes first.
    meta: bool,
    /// The transforms the stream's channels follow.
    tr: Transforms,
    /// Whether the stream declares `tr` itself.
    declares: bool,
};

fn groupRect(lay: *const Layout, g: u32) Rect {
    const x0 = (g % lay.xg) * group_dim;
    const y0 = (g / lay.xg) * group_dim;
    return .{ .x0 = x0, .y0 = y0, .w = @min(group_dim, lay.w - x0), .h = @min(group_dim, lay.h - y0) };
}

/// Stream `k`, with a group's palette made in `c.local_pal` when it has
/// one.
fn streamAt(c: *Ctx, k: u32) Stream {
    const lay = &c.lay;
    const has_palette = c.tr.palette != null;
    if (k == 0) {
        // With several groups, the global stream holds no pixels.
        const r: Rect = .{ .x0 = 0, .y0 = 0, .w = if (lay.single()) lay.w else 0, .h = if (lay.single()) lay.h else 0 };
        return .{ .id = 0, .rect = r, .meta = has_palette, .tr = c.tr, .declares = true };
    }
    const g = k - 1;
    const r = groupRect(lay, g);
    var s: Stream = .{
        .id = 1 + 3 * lay.num_lf_groups + num_quant_tables + g,
        .rect = r,
        .meta = false,
        .tr = c.tr,
        .declares = false,
    };
    if (c.local.len != 0) {
        s.declares = true;
        s.tr = .{};
        if (c.local[g] == local_palette) {
            const p = c.local_pal;
            p.reset();
            const fits = findPalette(c, p, r);
            std.debug.assert(fits);
            sortPalette(p);
            s.tr.palette = p;
            s.meta = true;
        } else {
            s.tr.rct = c.local[g];
        }
    }
    return s;
}

fn numStreams(lay: *const Layout) u32 {
    return if (lay.single()) 1 else 1 + lay.num_groups;
}

/// Fills `out` with stream `s`'s channels, in the decoder's order, and
/// returns how many.
fn buildPlanes(c: *Ctx, s: Stream, out: *[max_channels + 1]Plane) usize {
    var n: usize = 0;
    if (s.meta) {
        const p = s.tr.palette.?;
        const nch = c.lay.channels();
        for (0..p.len) |i| {
            const ord = p.order[i];
            for (0..nch) |ch| c.pal_plane[ch * p.len + ord] = p.colors[i * nch + ch];
        }
        out[0] = .{ .w = @intCast(p.len), .h = nch, .data = c.pal_plane[0 .. p.len * nch] };
        n = 1;
    }
    const r = s.rect;
    if (r.w == 0 or r.h == 0) return n;
    const area = @as(usize, r.w) * r.h;
    const nch = c.lay.channels();
    const n_img: usize = if (s.tr.palette != null) 1 else nch;
    for (0..n_img) |k| out[n + k] = .{ .w = r.w, .h = r.h, .data = c.planes[k * area ..][0..area] };
    var px: [max_channels]i32 = undefined;
    for (0..r.h) |y| {
        c.rr.read(r.x0, r.y0 + @as(u32, @intCast(y)), r.w, &c.rows);
        const row = y * r.w;
        if (s.tr.palette) |p| {
            const d = out[n].data[row..][0..r.w];
            var last_key: u64 = undefined;
            var last: i32 = -1;
            for (0..r.w) |x| {
                for (0..nch) |ch| px[ch] = c.rows[ch][x];
                const key = colorKey(&px, nch);
                if (last < 0 or key != last_key) {
                    last = p.index(key);
                    last_key = key;
                }
                d[x] = last;
            }
            continue;
        }
        for (0..nch) |ch| @memcpy(out[n + ch].data[row..][0..r.w], c.rows[ch][0..r.w]);
        if (s.tr.rct != 0) {
            const a = out[n].data[row..][0..r.w];
            const b = out[n + 1].data[row..][0..r.w];
            const cc = out[n + 2].data[row..][0..r.w];
            for (a, b, cc) |*x0, *x1, *x2| {
                const v = rct(s.tr.rct, .{ x0.*, x1.*, x2.* });
                x0.* = v[0];
                x1.* = v[1];
                x2.* = v[2];
            }
        }
    }
    return n + n_img;
}

// Headers.

fn writeSize(bw: *BitWriter, w: u32, h: u32) void {
    const d: [4]BitWriter.Dist = .{ .bo(9, 1), .bo(13, 1), .bo(18, 1), .bo(30, 1) };
    const ratios = [7][2]u64{ .{ 1, 1 }, .{ 12, 10 }, .{ 4, 3 }, .{ 3, 2 }, .{ 16, 9 }, .{ 5, 4 }, .{ 2, 1 } };
    var ratio: u32 = 0;
    for (ratios, 1..) |r, i| {
        if (@as(u64, h) * r[0] % r[1] == 0 and @as(u64, h) * r[0] / r[1] == w) {
            ratio = @intCast(i);
            break;
        }
    }
    const small_h = h % 8 == 0 and h <= 256;
    const small_w = w % 8 == 0 and w <= 256;
    const small = small_h and (small_w or ratio != 0);
    bw.boolean(small);
    if (small) bw.bits(h / 8 - 1, 5) else bw.u32Dist(h, d);
    bw.bits(ratio, 3);
    if (ratio == 0) {
        if (small) bw.bits(w / 8 - 1, 5) else bw.u32Dist(w, d);
    }
}

fn writeBitDepth(bw: *BitWriter, bits: u32) void {
    bw.boolean(false);
    bw.u32Dist(bits, .{ .v(8), .v(10), .v(12), .bo(6, 1) });
}

fn writeImageHeader(bw: *BitWriter, lay: *const Layout) void {
    bw.bits(0x0aff, 16);
    writeSize(bw, lay.w, lay.h);
    // ImageMetadata, not all default, without the extra fields.
    bw.boolean(false);
    bw.boolean(false);
    writeBitDepth(bw, lay.bits);
    bw.boolean(lay.bits <= 12);
    bw.u32Dist(@intFromBool(lay.alpha), .{ .v(0), .v(1), .bo(4, 2), .bo(12, 1) });
    if (lay.alpha) {
        if (lay.bits == 8 and !lay.premul) {
            bw.boolean(true);
        } else {
            bw.boolean(false);
            bw.enumField(0);
            writeBitDepth(bw, lay.bits);
            bw.u32Dist(0, .{ .v(0), .v(3), .v(4), .bo(3, 1) });
            bw.u32Dist(0, .{ .v(0), .b(4), .bo(5, 16), .bo(10, 48) });
            bw.boolean(lay.premul);
        }
    }
    // Not XYB.
    bw.boolean(false);
    if (lay.nc == 3) {
        bw.boolean(true);
    } else {
        bw.boolean(false);
        bw.boolean(false); // want_icc
        bw.enumField(1); // grey
        bw.enumField(1); // D65
        bw.boolean(false); // have_gamma
        bw.enumField(13); // sRGB transfer
        bw.enumField(1); // relative intent
    }
    bw.u64Field(0);
    // CustomTransformData, all default.
    bw.boolean(true);
    bw.padToByte();
}

fn writeFrameHeader(bw: *BitWriter, lay: *const Layout) void {
    bw.boolean(false);
    bw.bits(0, 2); // regular frame
    bw.boolean(true); // modular
    bw.u64Field(0); // flags
    bw.boolean(false); // ycbcr
    const sel0: [4]BitWriter.Dist = .{ .v(1), .v(2), .v(4), .v(8) };
    bw.u32Dist(1, sel0); // upsampling
    if (lay.alpha) bw.u32Dist(1, sel0);
    bw.bits(group_shift, 2);
    bw.u32Dist(1, .{ .v(1), .v(2), .v(3), .bo(3, 4) }); // one pass
    bw.boolean(false); // no crop
    const blend: [4]BitWriter.Dist = .{ .v(0), .v(1), .v(2), .bo(2, 3) };
    bw.u32Dist(0, blend);
    if (lay.alpha) bw.u32Dist(0, blend);
    bw.boolean(true); // is_last
    bw.u32Dist(0, .{ .v(0), .b(4), .bo(5, 16), .bo(10, 48) }); // no name
    // Restoration filter: no Gaborish, no edge-preserving filter.
    bw.boolean(false);
    bw.boolean(false);
    bw.bits(0, 2);
    bw.u64Field(0);
    bw.u64Field(0);
}

/// The stream header every stream has: the global tree, the default
/// weighted predictor, and the transforms the stream declares.
fn writeStreamHeader(bw: *BitWriter, s: *const Stream, nch: u32) void {
    bw.boolean(true);
    bw.boolean(true);
    const t: Transforms = if (s.declares) s.tr else .{};
    const n: u32 = @intFromBool(t.palette != null or t.rct != 0);
    bw.u32Dist(n, .{ .v(0), .v(1), .bo(4, 2), .bo(8, 18) });
    const begin: [4]BitWriter.Dist = .{ .b(3), .bo(6, 8), .bo(10, 72), .bo(13, 1096) };
    if (t.palette) |p| {
        bw.bits(1, 2);
        bw.u32Dist(0, begin);
        bw.u32Dist(nch, .{ .v(1), .v(3), .v(4), .bo(13, 1) });
        bw.u32Dist(@intCast(p.len), .{ .bo(8, 0), .bo(10, 256), .bo(12, 1280), .bo(16, 5376) });
        bw.u32Dist(0, .{ .v(0), .bo(8, 1), .bo(10, 257), .bo(16, 1281) });
        bw.bits(0, 4);
    } else if (t.rct != 0) {
        bw.bits(0, 2);
        bw.u32Dist(0, begin);
        bw.u32Dist(t.rct, .{ .v(6), .b(2), .bo(4, 2), .bo(6, 10) });
    }
}

// Encoding.

pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    if (src.width == 0 or src.height == 0) return error.EmptyImage;
    try src.check();
    const p = params(options.effort);
    const sizes = Sizes.init(p, src.width, src.height) orelse return error.ImageTooLarge;
    if (work.len < sizes.total().?) return error.WorkTooSmall;
    var mem: Bump = .init(work);
    encodeImpl(w, src, p, sizes, &mem) catch |e| return switch (e) {
        error.WriteFailed => error.WriteFailed,
        // `workLen` covers every allocation, so this would be a bug in it;
        // an error is safer than trusting that.
        error.WorkTooSmall => error.WorkTooSmall,
    };
}

fn encodeImpl(
    w: *Io.Writer,
    src: PixelBuffer,
    p: Params,
    sizes: Sizes,
    mem: *Bump,
) error{ WriteFailed, WorkTooSmall }!void {
    const lay: Layout = .init(src.format, src.width, src.height);
    const nch = lay.channels();
    const out_buf = try mem.alloc(u8, sizes.out);
    const toc_buf = try mem.alloc(u8, sizes.toc);
    var c: Ctx = .{
        .lay = lay,
        .tr = .{},
        .rr = .{
            .src = src,
            .conv = .init(lay.stored, src.format),
            .lay = undefined,
            .buf = try mem.alloc(u8, sizes.rows),
        },
        .planes = try mem.alloc(i32, sizes.planes / 4),
        .rows = undefined,
        .pal_plane = try mem.alloc(i32, p.palette_max * max_channels),
        .local_pal = undefined,
    };
    c.rr.lay = &c.lay;
    const row_w = @max(@min(lay.w, group_dim), p.palette_max);
    for (&c.rows) |*r| r.* = try mem.alloc(i32, row_w);

    // A palette when the image has few colors; otherwise each group's
    // own palette or color transform, or with one group, the image's.
    var pal: Palette = .{
        .slots = try mem.alloc(u16, hash_size),
        .keys = try mem.alloc(u64, p.palette_max),
        .colors = try mem.alloc(u16, p.palette_max * max_channels),
        .order = try mem.alloc(u16, p.palette_max),
        .nch = nch,
        .max = p.palette_max,
    };
    @memset(pal.slots, 0);
    c.local_pal = &pal;
    const pixels = @as(u64, lay.w) * lay.h;
    // Two rows of channels in the stream planes, as scratch.
    var rows2: [2][max_channels][]i32 = undefined;
    for (0..2) |r| {
        for (0..max_channels) |ch| rows2[r][ch] = c.planes[(r * max_channels + ch) * group_dim ..][0..group_dim];
    }
    const image: Rect = .{ .x0 = 0, .y0 = 0, .w = lay.w, .h = lay.h };
    // The samples the image's channels hold, after the transforms.
    var total_px: u64 = pixels * nch;
    if (findPalette(&c, &pal, image) and usePalette(&lay, pal.len, pixels)) {
        sortPalette(&pal);
        c.tr.palette = &pal;
        total_px = pixels;
    } else if (lay.single()) {
        if (lay.nc == 3) c.tr.rct = regionCosts(&c, image, &rows2, p.rct_pixels, null).best();
    } else {
        const local = try mem.alloc(u8, lay.num_groups);
        const g_rct: u32 = if (lay.nc == 3) regionCosts(&c, image, &rows2, p.rct_pixels, null).best() else 0;
        const qual = try mem.alloc(bool, lay.num_groups);
        var n_qual: usize = 0;
        for (local, qual, 0..) |*t, *q, g| {
            const r = groupRect(&lay, @intCast(g));
            const area = @as(u64, r.w) * r.h;
            pal.reset();
            const has_pal = findPalette(&c, &pal, r) and usePalette(&lay, pal.len, area);
            if (has_pal) sortPalette(&pal);
            q.* = has_pal;
            n_qual += @intFromBool(has_pal);
            const cost = regionCosts(&c, r, &rows2, p.rct_pixels, if (has_pal) &pal else null);
            var rgb: u32 = g_rct;
            if (lay.nc == 3) {
                const b = cost.best();
                if (cost.rct[b] < cost.rct[g_rct] * (1 - rct_margin)) rgb = b;
            }
            const plain = cost.rct[rgb] + cost.rest;
            // The palette's samples, in the sampled pixels' terms.
            const share = cost.pixels / @as(f64, @floatFromInt(area));
            const meta = @as(f64, @floatFromInt(pal.len * nch)) * pal_entry_bits * share;
            t.* = if (has_pal and (pal.len <= few_colors or cost.pal + meta < plain)) local_palette else @intCast(rgb);
        }
        const all_pal = @as(f64, @floatFromInt(n_qual)) >= pal_majority * @as(f64, @floatFromInt(lay.num_groups));
        var any = false;
        total_px = 0;
        for (local, qual, 0..) |*t, q, g| {
            if (all_pal and q) t.* = local_palette;
            const r = groupRect(&lay, @intCast(g));
            const area = @as(u64, r.w) * r.h;
            total_px += if (t.* == local_palette) area else area * nch;
            any = any or t.* != 0;
        }
        if (any) c.local = local;
    }

    const ns = numStreams(&lay);
    const stream_samples = sizes.planes / 4;
    const tokens = try mem.alloc(Token, stream_samples);
    const leaves = maxLeaves(p, &lay);
    const scratch = try mem.alloc(u32, @max(stream_samples, (2 * @as(usize, leaves) + 1) * 5));
    var plane_list: [max_channels + 1]Plane = undefined;

    // Learn the tree from samples.
    const nodes = try mem.alloc(mod.Node, 2 * @as(usize, leaves) + 1);
    var tree: mod.Tree = undefined;
    {
        const m = mem.mark();
        defer mem.release(m);
        const lo = learnOptions(p, leaves);
        const cap = sampleCap(p, lay.w, lay.h);
        // Thresholds come from samples with whole properties: all of
        // them for a small image, else a first, smaller set, after which
        // the samples keep only buckets.
        const single = cap <= single_pass_samples;
        const whole = if (single) cap else mod.thresholdSamples(cap);
        const room = sampleRoom(p, lay.w, lay.h);
        var smp: mod.Samples = try .init(mem, room, @min(whole, room), &lo, packRows(p, lay.w, lay.h));
        // A band of rows from every stream, as tall as the share of the
        // image the samples can cover.
        const budget: u64 = @as(u64, cap) * 4;
        const share: f64 = @min(1.0, @as(f64, @floatFromInt(budget)) / @as(f64, @floatFromInt(total_px)));
        const stride: u32 = @intCast(@max(1, @min(total_px, budget) / cap));
        var thr: mod.Thresholds = undefined;
        if (!single) {
            // The same pixels, more sparsely.
            smp.cap = whole;
            smp.stride = stride * @as(u32, @intCast((cap + whole - 1) / whole));
            smp.random = 0x9e3779b9;
            try sampleStreams(mem, &c, &smp, &lo, p.refs, &plane_list, share);
            thr = .choose(&smp, smp.len, &lo);
            smp = .{
                .props = smp.props,
                .rows = smp.rows,
                .row_bytes = smp.row_bytes,
                .bucket_bits = smp.bucket_bits,
                .token_bits = smp.token_bits,
                .thr = &thr,
                .num_pred = smp.num_pred,
                .nprops = smp.nprops,
                .cap = room,
            };
        }
        smp.stride = stride;
        try sampleStreams(mem, &c, &smp, &lo, p.refs, &plane_list, share);
        if (single) {
            thr = .choose(&smp, mod.thresholdSamples(smp.len), &lo);
            smp.bucketize(&thr);
        }
        // Samples stand for the whole image.
        smp.seen = total_px;
        tree = try mod.learn(mem, &smp, lo, nodes);
    }

    const flat = mod.Flat.build(&tree, try mem.alloc(mod.Flat, tree.nodes.len));
    // Count tokens, then build the histograms. When every stream's
    // tokens fit the store, packed, they are kept for writing; otherwise
    // they are made again.
    var hist: ent.Histograms = try .init(mem, tree.num_leaves);
    const store = try mem.alloc(u32, sizes.store / 4);
    var stored: usize = 0;
    var keep = true;
    const stream_len = try mem.alloc(u32, ns);
    {
        var k: u32 = 0;
        while (k < ns) : (k += 1) {
            const s = streamAt(&c, k);
            const n = try streamTokens(mem, &c, s, &tree, flat, tokens, &plane_list);
            hist.addTokens(tokens[0..n], .{});
            stream_len[k] = @intCast(n);
            if (!keep) continue;
            if (n > store.len - stored) {
                keep = false;
                continue;
            }
            for (tokens[0..n], store[stored..][0..n]) |t, *o| {
                if (t.value >= 1 << 21 or t.ctx >= 1 << 11) keep = false;
                o.* = t.ctx | t.value << 11;
            }
            stored += n;
        }
    }
    const code = try ent.Code.build(mem, &hist, .{ .max_clusters = maxClusters(lay.w, lay.h) });

    // The sections.
    var bw: BitWriter = .init(out_buf);
    const sec_sizes = try mem.alloc(u32, @intCast(lay.tocEntries()));
    @memset(sec_sizes, 0);
    // LfGlobal: default LF dequantization, the global tree, its code,
    // and the global stream.
    bw.boolean(true);
    bw.boolean(true);
    {
        const m = mem.mark();
        defer mem.release(m);
        const tt = tree.tokens(try mem.alloc(Token, tree.nodes.len * 5));
        var th: ent.Histograms = try .init(mem, 6);
        th.addTokens(tt, .{});
        const tcode = try ent.Code.build(mem, &th, .{});
        try tcode.write(&bw, mem);
        tcode.encode(&bw, tt, scratch);
    }
    try code.write(&bw, mem);
    var start: usize = 0;
    var start_token: usize = 0;
    var k: u32 = 0;
    while (k < ns) : (k += 1) {
        const s = streamAt(&c, k);
        writeStreamHeader(&bw, &s, nch);
        const n = stream_len[k];
        if (keep) {
            for (tokens[0..n], store[start_token..][0..n]) |*t, v| t.* = .{ .ctx = v & 0x7ff, .value = v >> 11 };
            start_token += n;
        } else {
            _ = try streamTokens(mem, &c, s, &tree, flat, tokens, &plane_list);
        }
        // Even a stream without tokens (the global one, when every
        // channel is coded in groups) carries its ANS state: decoders
        // differ on whether they read it, and jxl-oxide does.
        code.encode(&bw, tokens[0..n], scratch);
        bw.padToByte();
        const end = bw.len;
        // Sections in TOC order: LfGlobal, the LF groups and HfGlobal
        // (empty), then the pass groups.
        const slot: usize = if (k == 0) 0 else 1 + lay.num_lf_groups + k;
        sec_sizes[slot] = @intCast(end - start);
        start = end;
    }
    // A sample costs at most 45 bits: a symbol at most 15 (a prefix
    // code's longest; an ANS symbol's frequency is at least 1/4096, so
    // 12), and a residual, which wraps to 32 bits, at most 30 extra bits.
    // `Sizes.out` allows six bytes a sample, so the buffer cannot fill.
    std.debug.assert(!bw.overflow);

    // The headers and the table of contents, then the sections.
    var hw: BitWriter = .init(toc_buf);
    writeImageHeader(&hw, &lay);
    writeFrameHeader(&hw, &lay);
    hw.boolean(false); // no permutation
    hw.padToByte();
    for (sec_sizes) |sz| hw.u32Dist(sz, .{ .b(10), .bo(14, 1024), .bo(22, 17408), .bo(30, 4211712) });
    hw.padToByte();
    std.debug.assert(!hw.overflow);
    try w.writeAll(hw.bytes());
    try w.writeAll(bw.bytes());
}

/// Stream `s`'s tokens into `tokens`; returns how many.
fn streamTokens(
    mem: *Bump,
    c: *Ctx,
    s: Stream,
    tree: *const mod.Tree,
    flat: []const mod.Flat,
    tokens: []Token,
    plane_list: *[max_channels + 1]Plane,
) !usize {
    const n = buildPlanes(c, s, plane_list);
    // The reference channels the tree tests.
    var nref: usize = 0;
    for (tree.nodes) |nd| {
        if (nd.property >= mod.num_props) nref = @max(nref, @as(usize, @intCast(nd.property - mod.num_props)) / 4 + 1);
    }
    var len: usize = 0;
    for (plane_list[0..n], 0..) |pl, ci| {
        var rb: [mod.max_refs]Plane = undefined;
        const refs = refsOf(plane_list[0..n], ci, s.meta, nref, &rb);
        len += try mod.tokenize(mem, pl, @intCast(ci), s.id, tree, flat, refs, tokens[len..]);
    }
    return len;
}

/// Channel `ci`'s reference channels: up to `max` earlier channels of its
/// shape, nearest first, as the decoder finds them. A palette's meta
/// channel has a shape of its own.
fn refsOf(planes: []const Plane, ci: usize, meta: bool, max: usize, buf: *[mod.max_refs]Plane) []Plane {
    if (meta and ci == 0) return buf[0..0];
    var n: usize = 0;
    var j = ci;
    const first: usize = @intFromBool(meta);
    while (j > first and n < max) {
        j -= 1;
        if (planes[j].w != planes[ci].w or planes[j].h != planes[ci].h) continue;
        buf[n] = planes[j];
        n += 1;
    }
    return buf[0..n];
}

/// Collects the image's colors into `pal`; false if there are more than
/// it holds.
fn findPalette(c: *Ctx, pal: *Palette, r: Rect) bool {
    const nch = c.lay.channels();
    var px: [max_channels]i32 = undefined;
    var color: [max_channels]u16 = undefined;
    var y: u32 = r.y0;
    while (y < r.y0 + r.h) : (y += 1) {
        var x0: u32 = r.x0;
        while (x0 < r.x0 + r.w) : (x0 += group_dim) {
            const n = @min(group_dim, r.x0 + r.w - x0);
            c.rr.read(x0, y, n, &c.rows);
            var last: u64 = undefined;
            for (0..n) |x| {
                for (0..nch) |ch| px[ch] = c.rows[ch][x];
                const key = colorKey(&px, nch);
                if (x > 0 and key == last) continue;
                last = key;
                for (0..nch) |ch| color[ch] = @intCast(px[ch]);
                if (!pal.add(key, color[0..nch])) return false;
            }
        }
    }
    return true;
}

fn usePalette(lay: *const Layout, n: usize, pixels: u64) bool {
    const nch = lay.channels();
    // The palette's own samples must be few next to the image's.
    if (@as(u64, n) * nch * 8 > pixels * nch) return false;
    if (nch == 1) return n * 4 <= (@as(usize, 1) << @intCast(lay.bits));
    return true;
}

/// Orders the colors by alpha, then by luma, so that nearby indices are
/// similar colors.
fn sortPalette(pal: *Palette) void {
    const nch = pal.nch;
    const Order = struct {
        pal: *const Palette,
        const Self = @This();
        fn key(ctx: Self, i: u16) u64 {
            const p = ctx.pal;
            const col = p.colors[@as(usize, i) * p.nch ..][0..p.nch];
            const a: u64 = if (p.nch == 2 or p.nch == 4) col[p.nch - 1] else 0;
            const y: u64 = if (p.nch >= 3)
                @as(u64, col[0]) * 299 + @as(u64, col[1]) * 587 + @as(u64, col[2]) * 114
            else
                @as(u64, col[0]) * 1000;
            return (a << 40) | y;
        }
        fn less(ctx: Self, a: u16, b: u16) bool {
            const ka = ctx.key(a);
            const kb = ctx.key(b);
            return ka < kb or (ka == kb and a < b);
        }
    };
    _ = nch;
    var idx: [4096]u16 = undefined;
    for (idx[0..pal.len], 0..) |*v, i| v.* = @intCast(i);
    std.sort.pdq(u16, idx[0..pal.len], Order{ .pal = pal }, Order.less);
    for (idx[0..pal.len], 0..) |orig, rank| pal.order[orig] = @intCast(rank);
}

// Tests: images round trip through our decoder.

const Decoder = @import("Decoder.zig");

fn roundTrip(format: PixelFormat, width: u32, height: u32, pixels: []const u8, effort: Effort) !void {
    const gpa = testing.allocator;
    const src = try PixelBuffer.init(@constCast(pixels), format, width, height);
    const len = workLen(.{ .effort = effort }, width, height).?;
    const work = try gpa.alloc(u8, len);
    defer gpa.free(work);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try encode(&aw.writer, src, .{ .effort = effort }, work);
    const file = aw.written();

    var r: Io.Reader = .fixed(file);
    var d = Decoder.init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(width, config.width);
    try testing.expectEqual(height, config.height);
    const n = PixelBuffer.len(config.native, width, height).?;
    const got = try gpa.alloc(u8, n);
    defer gpa.free(got);
    const want = try gpa.alloc(u8, n);
    defer gpa.free(want);
    const dwork = try gpa.alloc(u8, config.work_len);
    defer gpa.free(dwork);
    const dst = try PixelBuffer.init(got, config.native, width, height);
    _ = try d.decodeFrame(dst, dwork);
    const conv: Converter = .init(config.native, format);
    for (0..height) |y| conv.run(want[y * n / height ..], src.row(@intCast(y)), width);
    try testing.expectEqualSlices(u8, want, got);
}

fn testImage(gpa: std.mem.Allocator, format: PixelFormat, w: u32, h: u32, kind: u8) ![]u8 {
    const len = PixelBuffer.len(format, w, h).?;
    const buf = try gpa.alloc(u8, len);
    var prng: std.Random.DefaultPrng = .init(kind);
    const random = prng.random();
    const bpp = format.bytesPerPixel();
    for (0..h) |y| {
        for (0..w) |x| {
            const px = buf[(y * w + x) * bpp ..][0..bpp];
            for (px, 0..) |*b, i| {
                b.* = switch (kind) {
                    0 => @truncate(x * 3 + y * 5 + i * 40),
                    1 => random.int(u8),
                    2 => @truncate(((x / 7 + y / 5) % 4) * 60 + i),
                    else => @truncate((x ^ y) + i),
                };
            }
        }
    }
    if (format.sample() == .f32) {
        const f: []align(1) f32 = @ptrCast(buf);
        for (f, 0..) |*v, i| v.* = @as(f32, @floatFromInt(buf[i * 4] % 200)) / 199;
    }
    return buf;
}

test "images round trip through our decoder" {
    const gpa = testing.allocator;
    const formats = [_]PixelFormat{
        .rgb8,   .rgba8, .gray8,        .gray_alpha8,   .rgb16, .rgba16,   .rgb_f32,
        .gray16, .bgra8, .rgba8_premul, .rgba16_premul, .cmyk8, .rgba_f32, .gray_f32,
    };
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 17, 9 }, .{ 100, 12 } };
    for (formats) |f| {
        for (sizes) |s| {
            for ([_]u8{ 0, 1, 2 }) |kind| {
                const px = try testImage(gpa, f, s[0], s[1], kind);
                defer gpa.free(px);
                const efforts: []const Effort = if (kind == 2) &.{ .fast, .default } else &.{.default};
                for (efforts) |e| {
                    roundTrip(f, s[0], s[1], px, e) catch |err| {
                        std.debug.print("{t} {d}x{d} kind {d} effort {t}\n", .{ f, s[0], s[1], kind, e });
                        return err;
                    };
                }
            }
        }
    }
}

test "several groups" {
    const gpa = testing.allocator;
    const px = try testImage(gpa, .rgba8, 520, 270, 0);
    defer gpa.free(px);
    try roundTrip(.rgba8, 520, 270, px, .default);
    const px2 = try testImage(gpa, .rgb8, 300, 260, 2);
    defer gpa.free(px2);
    try roundTrip(.rgb8, 300, 260, px2, .best);
    // Groups of their own kinds: noise, few colors, and a gradient, so
    // that groups take palettes and color transforms of their own.
    const w = 700;
    const h = 300;
    const px3 = try testImage(gpa, .rgba8, w, h, 1);
    defer gpa.free(px3);
    for (0..h) |y| {
        for (0..w) |x| {
            const p = px3[(y * w + x) * 4 ..][0..4];
            if (x >= 512) {
                p.* = .{ @truncate(x), @truncate(y * 2), @truncate(x + y), 255 };
            } else if (x >= 256 or y >= 256) {
                p.* = if ((x / 3 + y / 5) % 3 == 0) .{ 250, 250, 250, 255 } else .{ @truncate(x / 40), 30, 90, 200 };
            }
        }
    }
    for ([_]Effort{ .fast, .default }) |e| try roundTrip(.rgba8, w, h, px3, e);
}
