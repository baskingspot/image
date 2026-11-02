//! The WebP lossless (VP8L) encoder, written from RFC 9649. src/encode.zig
//! has the contract: pixels in any format go in, a RIFF/WEBP file comes
//! out, nothing is allocated, and `workLen` states the work memory first.
//!
//! The file decodes to the source converted to `bgra8`, exactly, colors
//! under transparent pixels included. An image of at most 256 colors is
//! color-indexed (bundled when it has at most 16); others are subtract
//! green, predicted per tile, and color-transformed per tile. The pixels
//! are then LZ77-coded with two-dimensional distance codes and a color
//! cache, with prefix codes chosen per tile through an entropy image.
//! `EncodeOptions.effort` sets how hard each step searches. A file is
//! simple (one VP8L chunk) unless metadata needs VP8X.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

const shared = @import("../encode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const codes = @import("encode_codes.zig");
const lz77 = @import("encode_lz77.zig");
const transform = @import("encode_transform.zig");
const entropy = @import("encode_entropy.zig");

pub const EncodeOptions = struct {
    /// How hard the encoder works to make the file small, from 0 (fastest)
    /// to 9 (smallest), as cwebp's `-z` levels; values above 9 act as 9.
    effort: u4 = 5,
    /// An ICC profile, written as an ICCP chunk.
    icc: ?[]const u8 = null,
    /// EXIF metadata, starting with its TIFF header, as an EXIF chunk.
    exif: ?[]const u8 = null,
    /// XMP metadata, as an `XMP ` chunk.
    xmp: ?[]const u8 = null,
};

pub const EncodeError = shared.Error || error{
    /// WebP cannot store an image without rows or columns.
    EmptyImage,
    /// The metadata would make the file longer than RIFF can say.
    BadMetadata,
};

/// The largest width or height VP8L stores.
const max_side = 1 << 14;

/// What each effort level does.
const Plan = struct {
    pred_bits: u5 = 3,
    pred_cost: transform.PredictCost = .entropy,
    pred_modes: u14 = std.math.maxInt(u14),
    /// How many modes, of the smallest residuals, the entropy cost weighs.
    pred_keep: u4 = 6,
    /// Passes that choose the predictor modes again against the whole
    /// image's residuals.
    pred_refine: u8 = 0,
    cross: bool = true,
    cross_bits: u5 = 5,
    /// The color transform's search weighs every this many pixels.
    cross_sample: u8 = 1,
    lz: lz77.Params = .{ .chain = 16 },
    /// Color cache sizes to try, in bits; 0 is none.
    cache: []const u5 = &all_cache,
    /// The entropy image's smallest tile bits, or 0 for one group.
    meta_bits: u5 = 4,
    /// The most tiles the entropy image has, raising its tile bits.
    max_tiles: u32 = 2600,
    /// The most prefix code groups.
    clusters: u16 = 64,
    /// Passes of the clustering.
    rounds: u8 = 3,
    /// How many of the likeliest transform choices to encode, keeping the
    /// smallest.
    tries: u8 = 1,
    /// How many times to parse again along the cheapest path.
    passes: u8 = 1,
    /// How many of the cheapest distance codes, the nearest pixels, the
    /// optimal parse tries at each pixel besides the longest match.
    near: u32 = 2,
    /// How many of the clustering's starts to try, keeping the smaller.
    starts: u8 = 2,
    /// The analysis weighs every this many rows.
    analysis_step: u8 = 1,

    fn of(effort: u4) Plan {
        return switch (@min(effort, 9)) {
            0 => .{
                .analysis_step = 4,
                .pred_bits = 5,
                .pred_cost = .sad,
                .pred_modes = 1 << 1 | 1 << 2 | 1 << 11,
                .cross = false,
                .lz = .{ .chain = 0, .nice = 16 },
                .cache = &.{0},
                .meta_bits = 0,
                .passes = 0,
                .starts = 1,
            },
            1 => .{
                .pred_bits = 4,
                .pred_cost = .sad,
                .cross = false,
                .lz = .{ .chain = 4 },
                .meta_bits = 6,
                .clusters = 16,
                .rounds = 1,
                .starts = 1,
            },
            2 => .{
                .pred_bits = 4,
                .pred_keep = 2,
                .cross_bits = 6,
                .cross_sample = 4,
                .lz = .{ .chain = 8 },
                .meta_bits = 5,
                .clusters = 32,
                .rounds = 2,
                .starts = 1,
            },
            3 => .{
                .pred_bits = 4,
                .pred_keep = 4,
                .cross_sample = 4,
                .lz = .{ .chain = 8 },
                .clusters = 32,
                .rounds = 2,
                .starts = 1,
            },
            4 => .{
                .pred_bits = 4,
                .pred_keep = 4,
                .cross_sample = 4,
                .lz = .{ .chain = 8 },
                .clusters = 48,
                .starts = 1,
            },
            5 => .{ .pred_keep = 4, .cross_sample = 2, .lz = .{ .chain = 8 }, .starts = 1 },
            6 => .{ .pred_keep = 4, .cross_sample = 2, .lz = .{ .chain = 32 }, .starts = 1 },
            7 => .{ .lz = .{ .chain = 32 } },
            8 => .{ .lz = .{ .chain = 64 }, .clusters = 128, .rounds = 4 },
            else => .{ .lz = .{ .chain = 128 }, .clusters = 256, .rounds = 5, .tries = 2, .pred_refine = 1 },
        };
    }

    const all_cache = [_]u5{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    /// The entropy image's tile bits for a `width` by `height` image, or
    /// 0 for one group.
    fn metaBits(p: Plan, width: u32, height: u32) u5 {
        if (p.meta_bits == 0 or p.clusters < 2) return 0;
        var b = p.meta_bits;
        // At most 7, so a tile's symbol counts fit 16 bits.
        while (b < 7 and tiles(width, height, b) > p.max_tiles) b += 1;
        return if (tiles(width, height, b) > 1) b else 0;
    }
};

fn tiles(width: u32, height: u32, bits: u5) u64 {
    return @as(u64, transform.divRoundUp(width, bits)) * transform.divRoundUp(height, bits);
}

/// The transform images' groups and histograms, after the main image's.
const Sub = enum { predictor, color, palette, entropy, single };

const sub_count = @typeInfo(Sub).@"enum".fields.len;

/// Where each piece of work memory sits, in bytes from a 16-aligned base.
const Layout = struct {
    argb: usize,
    tokens: usize,
    matches: usize,
    head: usize,
    ring: usize,
    pred: usize,
    pred_tokens: usize,
    color: usize,
    color_tokens: usize,
    ent: usize,
    ent_tokens: usize,
    palette: usize,
    palette_tokens: usize,
    cache: usize,
    groups: usize,
    histos: usize,
    scratch: usize,
    pred_scratch: usize,
    color_scratch: usize,
    table: usize,
    cache_scratch: usize,
    cluster: usize,
    analysis: usize,
    costs: usize,
    cost: usize,
    cluster_len: usize,
    ring_len: usize,
    head_bits: u5,
    meta_bits: u5,
    /// The most prefix code groups the entropy image may have: the
    /// effort's limit, but no more than its tiles.
    clusters: u32,
    total: usize,

    fn init(plan: Plan, width: u32, height: u32) ?Layout {
        if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
        const n: u64 = @as(u64, width) * height;
        const ring_len = lz77.Chain.ringLen(@intCast(n));
        const head_bits = lz77.Chain.headBits(@intCast(n));
        const pred_tiles = tiles(width, height, plan.pred_bits);
        const color_tiles = if (plan.cross) tiles(width, height, plan.cross_bits) else 0;
        const meta_bits = plan.metaBits(width, height);
        const ent_tiles: u64 = if (meta_bits == 0) 0 else tiles(width, height, meta_bits);
        const ent_cols: u64 = if (meta_bits == 0) 0 else transform.divRoundUp(width, meta_bits);
        const clusters: u32 = @intCast(@min(plan.clusters, ent_tiles));
        const groups: u64 = clusters + sub_count;
        const cluster_len = entropy.workLen(ent_tiles, ent_cols, n, clusters);
        const sizes = [_]u64{
            n * 4,
            n * 4 + 8,
            n * 4,
            (@as(u64, 1) << head_bits) * 4,
            ring_len * 4,
            pred_tiles * 4,
            pred_tiles * 4 + 8,
            color_tiles * 4,
            color_tiles * 4 + 8,
            ent_tiles * 4,
            ent_tiles * 4 + 8,
            256 * 4,
            256 * 4 + 8,
            (2 << codes.max_cache_bits) * 4,
            groups * @sizeOf(codes.Group),
            groups * @sizeOf(codes.Histogram),
            @sizeOf(codes.Scratch),
            @sizeOf(transform.PredictScratch),
            if (plan.cross) @sizeOf(transform.ColorScratch) else 0,
            @sizeOf(transform.ColorTable),
            if (plan.cache.len > 1) @sizeOf(CacheScratch) else 0,
            cluster_len,
            @sizeOf(Analysis),
            if (plan.passes != 0) @sizeOf(lz77.Costs) else 0,
            if (plan.passes != 0) (n + 1) * 4 else 0,
        };
        const names = .{
            "argb",           "tokens",       "matches",       "head",
            "ring",           "pred",         "pred_tokens",   "color",
            "color_tokens",   "ent",          "ent_tokens",    "palette",
            "palette_tokens", "cache",        "groups",        "histos",
            "scratch",        "pred_scratch", "color_scratch", "table",
            "cache_scratch",  "cluster",      "analysis",      "costs",
            "cost",
        };
        var l: Layout = undefined;
        var at: u64 = 0;
        inline for (names, sizes) |name, s| {
            @field(l, name) = std.math.cast(usize, at) orelse return null;
            at = std.mem.alignForward(u64, at + s, 16);
        }
        l.cluster_len = std.math.cast(usize, cluster_len) orelse return null;
        l.ring_len = std.math.cast(usize, ring_len) orelse return null;
        l.head_bits = head_bits;
        l.meta_bits = meta_bits;
        l.clusters = clusters;
        // Slack to align the caller's buffer.
        l.total = std.math.cast(usize, at + 16) orelse return null;
        return l;
    }
};

/// The work memory `encode` needs for a `width` by `height` image, or null
/// when WebP cannot store it.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    const l = Layout.init(Plan.of(options.effort), width, height) orelse return null;
    return l.total;
}

/// Histograms of the literals' symbols with each color cache size, to
/// choose one.
const CacheScratch = struct {
    green: [codes.max_cache_bits + 1][256 + (1 << codes.max_cache_bits)]u32,
    rest: [codes.max_cache_bits + 1][3][256]u32,
    /// Every literal's channels, before any cache takes some.
    all: [4][256]u32,
};

/// An entropy-coded image, as the stream writes it.
const Coded = struct {
    px: []const u32,
    width: u32,
    tokens: []const u32,
    cache_bits: u5 = 0,
    groups: []const codes.Group,
    /// The histograms the groups were built from.
    histos: []const codes.Histogram,
    /// The entropy image, for the main image with more than one group: a
    /// tile's group is its pixel's red and green.
    meta_bits: u5 = 0,
    meta: ?*const Coded = null,

    /// The bits `emit` writes, from the histograms.
    fn bits(c: *const Coded, main: bool, s: *codes.Scratch) u64 {
        var n: u64 = if (c.cache_bits != 0) 5 else 1;
        if (main) n += if (c.meta) |m| 4 + m.bits(false, s) else 1;
        var header: codes.Counter = .{};
        for (c.groups) |*g| g.write(&header, s);
        n += header.bits;
        for (c.groups, c.histos) |*g, *h| n += g.dataBits(h);
        return n;
    }

    /// Writes the image: its color cache size, its entropy image if it is
    /// the main image, its codes, and its pixels.
    fn emit(c: *const Coded, bw: anytype, main: bool, s: *codes.Scratch) void {
        if (c.cache_bits != 0) {
            bw.put(1, 1);
            bw.put(c.cache_bits, 4);
        } else bw.put(0, 1);
        if (main) {
            if (c.meta) |m| {
                bw.put(1, 1);
                bw.put(c.meta_bits - 2, 3);
                m.emit(bw, false, s);
            } else bw.put(0, 1);
        }
        for (c.groups) |*g| g.write(bw, s);
        const w = c.width;
        const tw = if (c.meta != null) transform.divRoundUp(w, c.meta_bits) else 0;
        var x: u32 = 0;
        var y: u32 = 0;
        var p: usize = 0;
        var t: usize = 0;
        var g = &c.groups[0];
        while (t < c.tokens.len) {
            if (c.meta) |m| g = &c.groups[(m.px[(y >> c.meta_bits) * tw + (x >> c.meta_bits)] >> 8) & 0xffff];
            const tok = c.tokens[t];
            var len: u32 = 1;
            if (tok & lz77.copy_flag != 0) {
                len = tok & 0xffff;
                const lp = codes.prefix(len);
                g.emit(bw, 0, 256 + lp.symbol);
                bw.put(lp.extra, lp.bits);
                const dp = codes.prefix(c.tokens[t + 1]);
                g.emit(bw, 4, dp.symbol);
                bw.put(dp.extra, dp.bits);
                t += 2;
            } else if (tok & lz77.cache_flag != 0) {
                g.emit(bw, 0, codes.green_base + (tok & 0xffff));
                t += 1;
            } else {
                const v = c.px[p];
                g.emit(bw, 0, (v >> 8) & 0xff);
                g.emit(bw, 1, (v >> 16) & 0xff);
                g.emit(bw, 2, v & 0xff);
                g.emit(bw, 3, v >> 24);
                t += 1;
            }
            p += len;
            x += len;
            if (x >= w) {
                y += x / w;
                x %= w;
            }
        }
    }
};

const Kind = enum(u2) { predictor, color, subtract_green, color_index };

/// A transform as the stream writes it.
const Step = struct {
    kind: Kind,
    bits: u5 = 0,
    image: ?Coded = null,
};

/// The VP8L bitstream: header, transforms, and main image.
const Stream = struct {
    width: u32,
    height: u32,
    alpha: bool,
    /// Whether the stream starts with the VP8L header, which an ALPH
    /// chunk's leaves out.
    header: bool = true,
    steps: [3]Step = undefined,
    step_count: usize = 0,
    main: Coded,

    fn bits(st: *const Stream, s: *codes.Scratch) u64 {
        var n: u64 = if (st.header) 8 + 14 + 14 + 1 + 3 + 1 else 1;
        for (st.steps[0..st.step_count]) |*step| {
            n += 3 + @as(u64, switch (step.kind) {
                .predictor, .color => 3,
                .color_index => 8,
                .subtract_green => 0,
            });
            if (step.image) |*img| n += img.bits(false, s);
        }
        return n + st.main.bits(true, s);
    }

    fn emit(st: *const Stream, bw: anytype, s: *codes.Scratch) void {
        if (st.header) {
            bw.put(0x2f, 8);
            bw.put(st.width - 1, 14);
            bw.put(st.height - 1, 14);
            bw.put(@intFromBool(st.alpha), 1);
            bw.put(0, 3);
        }
        for (st.steps[0..st.step_count]) |*step| {
            bw.put(1, 1);
            bw.put(@intFromEnum(step.kind), 2);
            switch (step.kind) {
                .predictor, .color => bw.put(step.bits - 2, 3),
                .color_index => bw.put(step.image.?.width - 1, 8),
                .subtract_green => {},
            }
            if (step.image) |*img| img.emit(bw, false, s);
        }
        bw.put(0, 1);
        st.main.emit(bw, true, s);
    }
};

/// The memory one encode works in.
const Work = struct {
    mem: []align(16) u8,

    fn slice(wk: Work, comptime T: type, at: usize, n: usize) []T {
        return @as([*]T, @ptrCast(@alignCast(wk.mem[at..].ptr)))[0..n];
    }

    fn one(wk: Work, comptime T: type, at: usize) *T {
        return @ptrCast(@alignCast(wk.mem[at..].ptr));
    }

    fn chain(wk: Work, l: Layout) lz77.Chain {
        return .{
            .head = wk.slice(u32, l.head, @as(usize, 1) << l.head_bits),
            .ring = wk.slice(u32, l.ring, l.ring_len),
            .bits = l.head_bits,
        };
    }
};

/// How transform images are parsed: small, so a short chain.
const sub_params: lz77.Params = .{ .chain = 8 };

/// Codes `px`, the transform image `sub`, with `sub`'s one group and no
/// color cache, into `tokens`.
fn codeSub(wk: Work, l: Layout, sub: Sub, px: []const u32, width: u32, tokens: []u32) Coded {
    const k = l.clusters + @intFromEnum(sub);
    const group = &wk.slice(codes.Group, l.groups, k + 1)[k];
    const histo = &wk.slice(codes.Histogram, l.histos, k + 1)[k];
    const s = wk.one(codes.Scratch, l.scratch);
    const matches = wk.slice(u32, l.matches, px.len);
    lz77.findMatches(px, width, sub_params, wk.chain(l), matches);
    const t = lz77.parse(px, matches, .default, tokens);
    histo.clear();
    lz77.histogram(px, tokens[0..t], histo);
    group.build(histo, codes.green_base, s);
    return .{ .px = px, .width = width, .tokens = tokens[0..t], .groups = group[0..1], .histos = histo[0..1] };
}

/// Writes `src` as a lossless WebP file to `w`.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    try src.check();
    if (src.width == 0 or src.height == 0) return error.EmptyImage;
    var e: Encoding = undefined;
    try e.run(.{ .pixels = src }, src.width, src.height, options.effort, work);
    const st = &e.st;
    const s = e.s;
    const width = src.width;
    const height = src.height;
    const alpha = st.alpha;

    // The file: its size first, from the histograms.
    const bits = st.bits(s);
    if (builtin.is_test) {
        var counter: codes.Counter = .{};
        st.emit(&counter, s);
        std.debug.assert(counter.bits == bits);
    }
    const vp8l_len = std.math.cast(u32, (bits + 7) / 8) orelse return error.ImageTooLarge;
    const extended = options.icc != null or options.exif != null or options.xmp != null;
    var riff: u64 = 4 + chunkLen(vp8l_len);
    if (extended) riff += chunkLen(10);
    for ([_]?[]const u8{ options.icc, options.exif, options.xmp }) |m| {
        if (m) |b| riff += chunkLen(std.math.cast(u32, b.len) orelse return error.BadMetadata);
    }
    const riff_len = std.math.cast(u32, riff) orelse return error.BadMetadata;

    var head: [30]u8 = undefined;
    @memcpy(head[0..4], "RIFF");
    std.mem.writeInt(u32, head[4..8], riff_len, .little);
    @memcpy(head[8..12], "WEBP");
    var hl: usize = 12;
    if (extended) {
        @memcpy(head[12..16], "VP8X");
        std.mem.writeInt(u32, head[16..20], 10, .little);
        var flags: u8 = 0;
        if (options.icc != null) flags |= 0x20;
        if (alpha) flags |= 0x10;
        if (options.exif != null) flags |= 0x08;
        if (options.xmp != null) flags |= 0x04;
        head[20..24].* = .{ flags, 0, 0, 0 };
        std.mem.writeInt(u24, head[24..27], @intCast(width - 1), .little);
        std.mem.writeInt(u24, head[27..30], @intCast(height - 1), .little);
        hl = 30;
    }
    try w.writeAll(head[0..hl]);
    if (options.icc) |b| try chunk(w, "ICCP", b);
    try chunkHead(w, "VP8L", vp8l_len);
    var bw: codes.BitWriter = .{ .w = w };
    st.emit(&bw, s);
    try bw.finish();
    if (vp8l_len & 1 != 0) try w.writeByte(0);
    if (options.exif) |b| try chunk(w, "EXIF", b);
    if (options.xmp) |b| try chunk(w, "XMP ", b);
}

/// Writes `plane`, `width` by `height` alpha values, row after row, as
/// the lossless stream an ALPH chunk with compression method 1 holds: a
/// VP8L image stream without its header, the alpha in green (RFC 9649).
/// The caller writes the chunk's header byte and filters the plane first,
/// if it chooses a filter. `work` takes `workLen(.{ .effort = effort },
/// width, height)` bytes.
pub fn encodeAlpha(w: *Io.Writer, plane: []const u8, width: u32, height: u32, effort: u4, work: []u8) EncodeError!void {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (plane.len < @as(u64, width) * height) return error.BufferTooSmall;
    var e: Encoding = undefined;
    try e.run(.{ .alpha = plane }, width, height, effort, work);
    e.st.header = false;
    var bw: codes.BitWriter = .{ .w = w };
    e.st.emit(&bw, e.s);
    try bw.finish();
}

/// Where an encode's pixels come from.
const Source = union(enum) {
    pixels: PixelBuffer,
    /// One alpha value a pixel, for an ALPH chunk.
    alpha: []const u8,

    /// The pixels as ARGB words into `argb`.
    fn fill(source: Source, argb: []u32) void {
        switch (source) {
            .pixels => |p| toArgb(p, argb),
            .alpha => |a| for (argb, a[0..argb.len]) |*p, v| {
                p.* = 0xff000000 | @as(u32, v) << 8;
            },
        }
    }
};

/// An encode's stream, with the entropy image it points at, and the
/// scratch memory that writes it.
const Encoding = struct {
    st: Stream,
    meta: Coded,
    s: *codes.Scratch,

    /// Chooses the transforms and codes for `source` into `e.st`.
    fn run(e: *Encoding, source: Source, width: u32, height: u32, effort: u4, work: []u8) EncodeError!void {
        const plan = Plan.of(effort);
        const l = Layout.init(plan, width, height) orelse return error.ImageTooLarge;
        if (work.len < l.total) return error.WorkTooSmall;
        const base = std.mem.alignForward(usize, @intFromPtr(work.ptr), 16) - @intFromPtr(work.ptr);
        const wk: Work = .{ .mem = @alignCast(work[base..][0 .. l.total - 16]) };
        const n = @as(usize, width) * height;

        const argb = wk.slice(u32, l.argb, n);
        source.fill(argb);
        var alpha = false;
        for (argb) |p| {
            if (p >> 24 != 0xff) {
                alpha = true;
                break;
            }
        }

        // Which transforms to use: by estimate, and at the higher efforts
        // by encoding the likeliest few and counting their bits.
        e.s = wk.one(codes.Scratch, l.scratch);
        var order: [modes_n]Mode = undefined;
        const candidates = rankModes(argb, width, plan, wk, l, &order);
        e.st = .{ .width = width, .height = height, .alpha = alpha, .main = undefined };
        const tries = @min(plan.tries, candidates);
        if (tries > 1) {
            var best: usize = 0;
            var best_bits: u64 = std.math.maxInt(u64);
            for (order[0..tries], 0..) |mode, k| {
                if (k != 0) source.fill(argb);
                build(wk, l, plan, mode, &e.st, &e.meta);
                const bits = e.st.bits(e.s);
                if (bits < best_bits) {
                    best_bits = bits;
                    best = k;
                }
            }
            if (best != tries - 1) {
                source.fill(argb);
                build(wk, l, plan, order[best], &e.st, &e.meta);
            }
        } else build(wk, l, plan, order[0], &e.st, &e.meta);
    }
};

const Mode = enum { direct, subtract_green, spatial, spatial_green, palette };
const modes_n = @typeInfo(Mode).@"enum".fields.len;

/// The modes worth trying for `argb`, best estimate first, into `order`;
/// returns how many there are. The estimate is each mode's entropy over
/// the pixels that differ from their left and upper neighbors, which LZ77
/// would mostly cover otherwise.
fn rankModes(argb: []const u32, width: u32, plan: Plan, wk: Work, l: Layout, order: *[modes_n]Mode) usize {
    const h = wk.one(Analysis, l.analysis);
    @memset(std.mem.asBytes(h), 0);
    const w: usize = width;
    var y: usize = 0;
    while (y * w < argb.len) : (y += plan.analysis_step) for (y * w..(y + 1) * w) |i| {
        const p = argb[i];
        const left = if (i % w != 0) argb[i - 1] else 0xff000000;
        if (p == left or (i >= w and p == argb[i - w])) continue;
        const up = if (i >= w) argb[i - w] else left;
        const upleft = if (i > w and i % w != 0) argb[i - w - 1] else up;
        const r = transform.sub(p, select(left, up, upleft));
        const g = (p >> 8) & 0xff;
        const rg = (r >> 8) & 0xff;
        h.c[0][p >> 24] += 1;
        h.c[1][(p >> 16) & 0xff] += 1;
        h.c[2][g] += 1;
        h.c[3][p & 0xff] += 1;
        h.c[4][((p >> 16) -% g) & 0xff] += 1;
        h.c[5][(p -% g) & 0xff] += 1;
        h.c[6][r >> 24] += 1;
        h.c[7][(r >> 16) & 0xff] += 1;
        h.c[8][rg] += 1;
        h.c[9][r & 0xff] += 1;
        h.c[10][((r >> 16) -% rg) & 0xff] += 1;
        h.c[11][(r -% rg) & 0xff] += 1;
    };
    var bits: [12]f64 = undefined;
    for (&bits, &h.c) |*b, *c| b.* = shannon(c);
    var cost: [modes_n]f64 = .{
        bits[0] + bits[1] + bits[2] + bits[3],
        bits[0] + bits[4] + bits[2] + bits[5],
        bits[6] + bits[7] + bits[8] + bits[9],
        bits[6] + bits[10] + bits[8] + bits[11],
        std.math.inf(f64),
    };
    // A transform image costs about a byte a tile.
    const pt: f64 = @floatFromInt(tiles(width, @intCast(argb.len / w), plan.pred_bits) * 8 / plan.analysis_step);
    cost[2] += pt;
    cost[3] += pt;
    var n: usize = 4;
    {
        const table = wk.one(transform.ColorTable, l.table);
        const palette = wk.slice(u32, l.palette, 256);
        if (table.find(argb, palette[0..256])) |count| {
            // The indices' entropy over the same pixels, and the palette.
            var idx: [256]u32 = @splat(0);
            y = 0;
            while (y * w < argb.len) : (y += plan.analysis_step) for (y * w..(y + 1) * w) |i| {
                const p = argb[i];
                const left = if (i % w != 0) argb[i - 1] else 0xff000000;
                if (p == left or (i >= w and p == argb[i - w])) continue;
                idx[table.index(p)] += 1;
            };
            cost[4] = shannon(&idx) + @as(f64, @floatFromInt(count * 16 / plan.analysis_step));
            n += 1;
        }
    }
    // Palette, last, only when it can be.
    var all = [modes_n]Mode{ .direct, .subtract_green, .spatial, .spatial_green, .palette };
    std.sort.insertion(Mode, all[0..n], &cost, struct {
        fn less(c: *const [modes_n]f64, a: Mode, b: Mode) bool {
            return c[@intFromEnum(a)] < c[@intFromEnum(b)];
        }
    }.less);
    order.* = all;
    return n;
}

const Analysis = struct { c: [12][256]u32 };

/// Predictor mode 11, the nearer of left and top.
fn select(l: u32, t: u32, tl: u32) u32 {
    var dl: u32 = 0;
    var dt: u32 = 0;
    inline for (0..4) |k| {
        const sh = k * 8;
        const a: i32 = @intCast((l >> sh) & 0xff);
        const b: i32 = @intCast((t >> sh) & 0xff);
        const c: i32 = @intCast((tl >> sh) & 0xff);
        dl += @abs(b - c);
        dt += @abs(a - c);
    }
    return if (dl < dt) l else t;
}

/// Transforms `argb` for `mode` and codes the result into `st`, with the
/// entropy image in `meta`.
fn build(wk: Work, l: Layout, plan: Plan, mode: Mode, st: *Stream, meta: *Coded) void {
    const width = st.width;
    const height = st.height;
    const n = @as(usize, width) * height;
    const argb = wk.slice(u32, l.argb, n);
    const matches = wk.slice(u32, l.matches, n);
    st.step_count = 0;

    // Transforms, in the order they are applied and written.
    var cur_w = width;
    if (mode == .palette) {
        const palette = wk.slice(u32, l.palette, 256);
        const table = wk.one(transform.ColorTable, l.table);
        const count = table.find(argb, palette[0..256]).?;
        transform.applyPalette(argb, width, height, table, count);
        cur_w = transform.divRoundUp(width, transform.bundleBits(count));
        // Each entry as its difference from the one before.
        var k = count;
        while (k > 1) {
            k -= 1;
            palette[k] = transform.sub(palette[k], palette[k - 1]);
        }
        const tokens = wk.slice(u32, l.palette_tokens, 258);
        const image = codeSub(wk, l, .palette, palette[0..count], @intCast(count), tokens);
        st.steps[0] = .{ .kind = .color_index, .image = image };
        st.step_count = 1;
    }
    if (mode == .subtract_green or mode == .spatial_green) {
        transform.subtractGreen(argb);
        st.steps[st.step_count] = .{ .kind = .subtract_green };
        st.step_count += 1;
    }
    if (mode == .spatial or mode == .spatial_green) {
        const pn: usize = @intCast(tiles(width, height, plan.pred_bits));
        const img = wk.slice(u32, l.pred, pn);
        const scratch = wk.one(transform.PredictScratch, l.pred_scratch);
        transform.predict(
            argb,
            width,
            height,
            plan.pred_bits,
            plan.pred_cost,
            plan.pred_modes,
            plan.pred_keep,
            plan.pred_refine,
            img,
            scratch,
        );
        const tw = transform.divRoundUp(width, plan.pred_bits);
        const image = codeSub(wk, l, .predictor, img, tw, wk.slice(u32, l.pred_tokens, pn + 2));
        st.steps[st.step_count] = .{ .kind = .predictor, .bits = plan.pred_bits, .image = image };
        st.step_count += 1;
        if (plan.cross) {
            const cn: usize = @intCast(tiles(width, height, plan.cross_bits));
            const cimg = wk.slice(u32, l.color, cn);
            const cscratch = wk.one(transform.ColorScratch, l.color_scratch);
            transform.crossColor(argb, width, height, plan.cross_bits, plan.cross_sample, cimg, cscratch);
            const cw = transform.divRoundUp(width, plan.cross_bits);
            const cimage = codeSub(wk, l, .color, cimg, cw, wk.slice(u32, l.color_tokens, cn + 2));
            st.steps[st.step_count] = .{ .kind = .color, .bits = plan.cross_bits, .image = cimage };
            st.step_count += 1;
        }
    }

    // The main image: references, the color cache, and its groups.
    const main_px = argb[0 .. @as(usize, cur_w) * height];
    const tokens_all = wk.slice(u32, l.tokens, n + 2);
    // Before the optimal parse, references are cheap so it sees them all.
    const model: lz77.Model = .{ .literal = if (plan.passes != 0) 4 else if (mode == .palette) 6 else 12 };
    lz77.findMatches(main_px, cur_w, plan.lz, wk.chain(l), matches[0..main_px.len]);
    const first = lz77.parse(main_px, matches, model, tokens_all);
    const cache = wk.slice(u32, l.cache, 2 << codes.max_cache_bits);
    const cache_scratch = wk.one(CacheScratch, l.cache_scratch);
    const cache_bits = if (plan.cache.len == 1)
        plan.cache[0]
    else
        chooseCache(main_px, tokens_all[0..first], plan.cache, cache_scratch, cache);
    lz77.applyCache(main_px, tokens_all[0..first], cache_bits, cache);
    const green_size = codes.green_base + if (cache_bits == 0) 0 else @as(usize, 1) << cache_bits;
    var tokens = tokens_all[0..first];
    // Again along the cheapest path, by what the last parse's symbols
    // cost.
    for (0..plan.passes) |_| {
        const k = l.clusters + @intFromEnum(Sub.single);
        const h = &wk.slice(codes.Histogram, l.histos, k + 1)[k];
        h.clear();
        lz77.histogram(main_px, tokens, h);
        const costs = wk.slice(lz77.Costs, l.costs, 1);
        costs[0].init(h, green_size);
        const cost = wk.slice(f32, l.cost, n + 1);
        const len = lz77.parseOptimal(
            main_px,
            cur_w,
            matches,
            plan.lz.nice,
            plan.near,
            &costs[0],
            cache_bits,
            cache,
            tokens_all,
            cost,
        );
        tokens = tokens_all[0..len];
        lz77.applyCache(main_px, tokens, cache_bits, cache);
    }

    st.main = .{
        .px = main_px,
        .width = cur_w,
        .tokens = tokens,
        .cache_bits = cache_bits,
        .groups = undefined,
        .histos = undefined,
    };
    chooseGroups(st, wk, l, plan, green_size, meta);
}

/// Codes the main image in `st` with one group, or with groups per tile
/// when the entropy image (in `meta`) pays: both are counted exactly, and
/// the smaller is kept.
fn chooseGroups(st: *Stream, wk: Work, l: Layout, plan: Plan, green_size: usize, meta: *Coded) void {
    const s = wk.one(codes.Scratch, l.scratch);
    const group_mem = wk.slice(codes.Group, l.groups, l.clusters + sub_count);
    const histos = wk.slice(codes.Histogram, l.histos, l.clusters + sub_count);
    const sub_group = group_mem[l.clusters..];
    const sub_histo = histos[l.clusters..];
    const main_px = st.main.px;
    const tokens = st.main.tokens;
    const cur_w = st.main.width;
    const height = st.height;
    const single = &sub_group[@intFromEnum(Sub.single)];
    sub_histo[@intFromEnum(Sub.single)].clear();
    lz77.histogram(main_px, tokens, &sub_histo[@intFromEnum(Sub.single)]);
    single.build(&sub_histo[@intFromEnum(Sub.single)], green_size, s);
    st.main.groups = single[0..1];
    st.main.histos = sub_histo[@intFromEnum(Sub.single)..][0..1];
    st.main.meta = null;
    st.main.meta_bits = 0;
    if (l.meta_bits == 0) return;
    const ent = wk.slice(u32, l.ent, @intCast(tiles(cur_w, height, l.meta_bits)));
    const in: entropy.Input = .{
        .px = main_px,
        .width = cur_w,
        .tokens = tokens,
        .bits = l.meta_bits,
        .green_size = green_size,
        .max_groups = l.clusters,
        .rounds = plan.rounds,
        .tile_group = ent,
        .histos = histos[0..l.clusters],
        .mem = wk.slice(u8, l.cluster, l.cluster_len),
    };
    var best_bits = st.main.bits(true, s);
    var best: ?struct { start: u1, count: usize } = null;
    for (0..plan.starts) |k| {
        var at = in;
        at.start = @intCast(k);
        const count = entropy.cluster(at);
        if (count < 2) continue;
        const bits = groupedBits(st.main, ent, count, wk, l, green_size, meta);
        if (bits < best_bits) {
            best_bits = bits;
            best = .{ .start = at.start, .count = count };
        }
    }
    const b = best orelse return;
    // The best grouping again, unless it was the last made.
    if (b.start != plan.starts - 1) {
        var at = in;
        at.start = b.start;
        _ = groupedBits(st.main, ent, entropy.cluster(at), wk, l, green_size, meta);
    }
    st.main.groups = group_mem[0..b.count];
    st.main.histos = histos[0..b.count];
    st.main.meta = meta;
    st.main.meta_bits = l.meta_bits;
}

/// Builds the codes of `group_count` groups, whose tiles' groups `ent`
/// holds, and the entropy image coding them into `meta`; returns the main
/// image's bits with them.
fn groupedBits(
    main: Coded,
    ent: []u32,
    group_count: usize,
    wk: Work,
    l: Layout,
    green_size: usize,
    meta: *Coded,
) u64 {
    const s = wk.one(codes.Scratch, l.scratch);
    const group_mem = wk.slice(codes.Group, l.groups, l.clusters + sub_count);
    const histos = wk.slice(codes.Histogram, l.histos, l.clusters + sub_count);
    for (ent) |*e| e.* = 0xff000000 | e.* << 8;
    const ew = transform.divRoundUp(main.width, l.meta_bits);
    meta.* = codeSub(wk, l, .entropy, ent, ew, wk.slice(u32, l.ent_tokens, ent.len + 2));
    for (group_mem[0..group_count], histos[0..group_count]) |*g, *h| g.build(h, green_size, s);
    var multi = main;
    multi.groups = group_mem[0..group_count];
    multi.histos = histos[0..group_count];
    multi.meta = meta;
    multi.meta_bits = l.meta_bits;
    return multi.bits(true, s);
}

/// Bytes a chunk with `len` bytes of payload takes, padding included.
fn chunkLen(len: u32) u64 {
    return 8 + @as(u64, len) + (len & 1);
}

fn chunkHead(w: *Io.Writer, fourcc: *const [4]u8, len: u32) error{WriteFailed}!void {
    var h: [8]u8 = undefined;
    @memcpy(h[0..4], fourcc);
    std.mem.writeInt(u32, h[4..8], len, .little);
    try w.writeAll(&h);
}

fn chunk(w: *Io.Writer, fourcc: *const [4]u8, payload: []const u8) error{WriteFailed}!void {
    try chunkHead(w, fourcc, @intCast(payload.len));
    try w.writeAll(payload);
    if (payload.len & 1 != 0) try w.writeByte(0);
}

/// The source as ARGB words: `bgra8` bytes in little-endian order.
fn toArgb(src: PixelBuffer, argb: []u32) void {
    const w: usize = src.width;
    const conv: Converter = .init(.bgra8, src.format);
    for (0..src.height) |y| {
        const out = argb[y * w ..][0..w];
        const bytes = std.mem.sliceAsBytes(out);
        const row = src.row(@intCast(y));
        if (src.format == .bgra8) @memcpy(bytes, row[0 .. w * 4]) else conv.run(bytes, row, w);
        if (builtin.cpu.arch.endian() == .big) for (out) |*p| {
            p.* = @byteSwap(p.*);
        };
    }
}

/// The color cache size, of `candidates`, whose literals cost least, by
/// their histograms' entropy and a rough cost for the larger codes.
fn chooseCache(px: []const u32, tokens: []const u32, candidates: []const u5, cs: *CacheScratch, cache: []u32) u5 {
    var max: u5 = 0;
    for (candidates) |b| max = @max(max, b);
    for (candidates) |b| {
        @memset(cs.green[b][0 .. 256 + (@as(usize, 1) << b)], 0);
        for (&cs.rest[b]) |*r| @memset(r, 0);
    }
    for (&cs.all) |*a| @memset(a, 0);
    // One cache for each size, side by side: size 2^b starts at 2^b. Each
    // literal is counted once in `all`, and what each cache takes instead
    // in that cache's histograms, to subtract after.
    @memset(cache[0 .. @as(usize, 2) << max], 0);
    var p: usize = 0;
    var t: usize = 0;
    while (t < tokens.len) {
        const tok = tokens[t];
        if (tok & lz77.copy_flag != 0) {
            const len = tok & 0xffff;
            // A pixel like the one before goes where that one went.
            var last = px[p] +% 1;
            for (px[p..][0..len]) |v| {
                if (v == last) continue;
                last = v;
                for (candidates) |b| {
                    if (b != 0) cache[(@as(usize, 1) << b) + lz77.cacheIndex(v, b)] = v;
                }
            }
            p += len;
            t += 2;
            continue;
        }
        const v = px[p];
        const g = (v >> 8) & 0xff;
        const r = (v >> 16) & 0xff;
        const bl = v & 0xff;
        const a = v >> 24;
        cs.all[0][g] += 1;
        cs.all[1][r] += 1;
        cs.all[2][bl] += 1;
        cs.all[3][a] += 1;
        for (candidates) |b| {
            if (b == 0) continue;
            const k = lz77.cacheIndex(v, b);
            const slot = &cache[(@as(usize, 1) << b) + k];
            if (slot.* == v) {
                cs.green[b][256 + k] += 1;
                cs.green[b][g] += 1;
                cs.rest[b][0][r] += 1;
                cs.rest[b][1][bl] += 1;
                cs.rest[b][2][a] += 1;
            } else slot.* = v;
        }
        p += 1;
        t += 1;
    }
    for (candidates) |b| {
        for (cs.green[b][0..256], cs.all[0]) |*c, n| c.* = n - c.*;
        for (&cs.rest[b], cs.all[1..]) |*h, *all| {
            for (h, all) |*c, n| c.* = n - c.*;
        }
    }
    var best: u5 = 0;
    var best_cost: f64 = std.math.inf(f64);
    for (candidates) |b| {
        var bits = shannon(cs.green[b][0 .. 256 + (@as(usize, 1) << b)]);
        for (&cs.rest[b]) |*r| bits += shannon(r);
        // Each used cache symbol needs a code length written.
        bits += @floatFromInt(@as(u32, 1) << b);
        if (bits < best_cost) {
            best_cost = bits;
            best = b;
        }
    }
    return best;
}

/// Bits to code `counts` with their own ideal code.
fn shannon(counts: []const u32) f64 {
    var total: u64 = 0;
    var sum: f64 = 0;
    for (counts) |c| {
        if (c == 0) continue;
        total += c;
        const f: f64 = @floatFromInt(c);
        sum -= f * std.math.log2(f);
    }
    if (total == 0) return 0;
    const t: f64 = @floatFromInt(total);
    return sum + t * std.math.log2(t);
}

// Tests ------------------------------------------------------------------

const Decoder = @import("Decoder.zig");
const alpha_decode = @import("alpha.zig");

fn testEncode(src: PixelBuffer, options: EncodeOptions, out: []u8) ![]u8 {
    const work = try testing.allocator.alloc(u8, workLen(options, src.width, src.height).?);
    defer testing.allocator.free(work);
    var w: Io.Writer = .fixed(out);
    try encode(&w, src, options, work);
    return w.buffered();
}

fn testDecode(file: []const u8, out: []u8, width: u32, height: u32) !void {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    const work = try testing.allocator.alloc(u8, config.work_len);
    defer testing.allocator.free(work);
    _ = try d.decodeFrame(try PixelBuffer.init(out, .bgra8, width, height), work);
}

/// Pixels with runs, repeats from above, gradients, noise, and alpha, so
/// every transform and token kind has work to do.
fn testImage(px: []u8, width: u32, colors: u32, random: std.Random) void {
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const x = (i / 4) % width;
        const up: ?[4]u8 = if (i >= width * 4) px[i - width * 4 ..][0..4].* else null;
        const prev: [4]u8 = if (i == 0) .{ 0, 0, 0, 255 } else px[i - 4 ..][0..4].*;
        px[i..][0..4].* = if (colors != 0)
            std.mem.toBytes(std.mem.nativeToLittle(u32, random.uintLessThan(u32, colors) *% 0x01_23_45_67))
        else switch (random.uintLessThan(u8, 8)) {
            0, 1 => prev,
            2, 3 => up orelse prev,
            4 => .{ prev[0] +% 1, prev[1] +% 2, prev[2] +% @as(u8, @truncate(x)), prev[3] },
            5 => .{ prev[0] +% 9, prev[1] +% 7, prev[2] +% 3, prev[3] },
            6 => .{ random.int(u8), random.int(u8), random.int(u8), prev[3] },
            else => .{ random.int(u8), random.int(u8), random.int(u8), random.int(u8) },
        };
    }
}

test "round trips through the decoder at every effort" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 3, 2 }, .{ 17, 9 }, .{ 64, 64 }, .{ 200, 130 } };
    const px = try testing.allocator.alloc(u8, 200 * 130 * 4);
    defer testing.allocator.free(px);
    const back = try testing.allocator.alloc(u8, px.len);
    defer testing.allocator.free(back);
    const file = try testing.allocator.alloc(u8, px.len * 2 + 4096);
    defer testing.allocator.free(file);
    for (sizes) |size| {
        for ([_]u32{ 0, 2, 3, 16, 200, 300 }) |colors| {
            const len = size[0] * size[1] * 4;
            testImage(px[0..len], size[0], colors, random);
            const src = try PixelBuffer.init(px[0..len], .bgra8, size[0], size[1]);
            for (0..10) |effort| {
                const encoded = try testEncode(src, .{ .effort = @intCast(effort) }, file);
                try testDecode(encoded, back[0..len], size[0], size[1]);
                try testing.expectEqualSlices(u8, px[0..len], back[0..len]);
            }
        }
    }
}

test "metadata makes an extended file" {
    var px: [4 * 4 * 4]u8 = @splat(0x80);
    px[3] = 0;
    const src = try PixelBuffer.init(&px, .bgra8, 4, 4);
    var file: [512]u8 = undefined;
    const encoded = try testEncode(src, .{ .icc = "icc", .exif = "MM\x00\x2a", .xmp = "<x/>" }, &file);
    try testing.expectEqualStrings("VP8X", encoded[12..16]);
    try testing.expectEqual(0x20 | 0x10 | 0x08 | 0x04, encoded[20]);
    try testing.expectEqual(encoded.len - 8, std.mem.readInt(u32, encoded[4..8], .little));
    var back: [4 * 4 * 4]u8 = undefined;
    try testDecode(encoded, &back, 4, 4);
    try testing.expectEqualSlices(u8, &px, &back);
    // Without metadata, the file is simple, and writing it a byte short
    // fails.
    const simple = try testEncode(src, .{}, &file);
    try testing.expectEqualStrings("VP8L", simple[12..16]);
    const n = simple.len;
    var short: [512]u8 = undefined;
    try testing.expectError(error.WriteFailed, testEncode(src, .{}, short[0 .. n - 1]));
}

test "an alpha plane decodes through ALPH" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 17, 9 }, .{ 120, 70 } };
    var px: [120 * 70 * 4]u8 = undefined;
    var plane: [120 * 70]u8 = undefined;
    var back: [120 * 70]u8 = undefined;
    var chunk_body: [120 * 70 * 2 + 64]u8 = undefined;
    for (sizes) |size| {
        const n = size[0] * size[1];
        // Few values (color indexing) and many (the predictor).
        for ([_]u32{ 2, 0 }) |colors| {
            testImage(px[0 .. n * 4], size[0], colors, random);
            for (plane[0..n], 0..) |*a, i| a.* = px[i * 4 + 3];
            for ([_]u4{ 0, 5, 9 }) |effort| {
                const work = try testing.allocator.alloc(u8, workLen(.{ .effort = effort }, size[0], size[1]).?);
                defer testing.allocator.free(work);
                var w: Io.Writer = .fixed(&chunk_body);
                try w.writeByte(1); // Lossless, no filter, no preprocessing.
                try encodeAlpha(&w, plane[0..n], size[0], size[1], effort, work);
                const body = w.buffered();
                var r: Io.Reader = .fixed(body);
                const dwork = try testing.allocator.alloc(u8, alpha_decode.workLen(size[0], size[1], 256).?);
                defer testing.allocator.free(dwork);
                const result = try alpha_decode.decode(&r, body.len, size[0], size[1], 256, back[0..n], dwork);
                try testing.expectEqual(null, result.err);
                try testing.expectEqual(0, result.unread);
                try testing.expectEqualSlices(u8, plane[0..n], back[0..n]);
            }
        }
    }
}
