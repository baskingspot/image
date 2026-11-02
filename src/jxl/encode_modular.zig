//! Modular image data for the JPEG XL encoder (ISO/IEC 18181-1, Annex on
//! modular mode): the predictors and properties the decoder computes, the
//! weighted predictor, a meta-adaptive tree learned from sampled pixels,
//! and the tokens a channel's residuals become under a tree.
//!
//! The predictors and the weighted predictor are the decoder's
//! (modular.zig): a residual is only right if both sides compute the same
//! prediction. Properties 2 to 14 still repeat the specification's, as the
//! decoder computes them inline.

const std = @import("std");
const testing = std.testing;

const ent = @import("encode_entropy.zig");
const dec = @import("modular.zig");
const Arena = @import("Arena.zig");
const Token = ent.Token;
const Bump = @import("encode_mem.zig").Bump;

pub const num_props = 16;
/// Earlier channels whose values may be properties, four properties each.
pub const max_refs = 3;
pub const max_props = num_props + 4 * max_refs;
/// Property 15: the weighted predictor's largest neighbouring error.
pub const wp_prop = 15;

pub const Predictor = dec.Predictor;

/// A tree node. A split tests `props[property] > value`: true goes to
/// `child`, false to `child + 1`. A leaf (property -1) has its predictor
/// and its context, numbered in node order.
pub const Node = struct {
    property: i16 = -1,
    predictor: Predictor = .gradient,
    value: i32 = 0,
    child: u32 = 0,
};

pub const Tree = struct {
    nodes: []Node,
    num_leaves: u32,

    /// Numbers the leaves in node order, as the decoder does.
    pub fn numberLeaves(t: *Tree) void {
        var n: u32 = 0;
        for (t.nodes) |*nd| {
            if (nd.property < 0) {
                nd.child = n;
                n += 1;
            }
        }
        t.num_leaves = n;
    }

    /// The tree's tokens in its six contexts (modular.readTree).
    pub fn tokens(t: *const Tree, out: []Token) []Token {
        var n: usize = 0;
        for (t.nodes) |nd| {
            if (nd.property < 0) {
                out[n..][0..5].* = .{
                    .{ .ctx = 1, .value = 0 },
                    .{ .ctx = 2, .value = @intFromEnum(nd.predictor) },
                    .{ .ctx = 3, .value = 0 },
                    .{ .ctx = 4, .value = 0 },
                    .{ .ctx = 5, .value = 0 },
                };
                n += 5;
            } else {
                out[n..][0..2].* = .{
                    .{ .ctx = 1, .value = @intCast(nd.property + 1) },
                    .{ .ctx = 0, .value = ent.packSigned(nd.value) },
                };
                n += 2;
            }
        }
        return out[0..n];
    }
};

/// A tree walked two levels a step: node i tests its own property and
/// both children's at once (a leaf child tests nothing and is reached
/// either way) and goes to one of four grandchildren, so the walk's chain
/// of dependent loads is half as long. Indices are the tree's.
pub const Flat = struct {
    prop: [3]u8,
    leaf: bool,
    predictor: Predictor,
    value: [3]i32,
    /// The grandchildren, or for a leaf its context in `next[0]`.
    next: [4]u32,

    pub fn build(tree: *const Tree, out: []Flat) []Flat {
        const nodes = tree.nodes;
        for (nodes, out[0..nodes.len]) |nd, *f| {
            if (nd.property < 0) {
                f.* = .{
                    .prop = @splat(0),
                    .leaf = true,
                    .predictor = nd.predictor,
                    .value = @splat(0),
                    .next = .{ nd.child, 0, 0, 0 },
                };
                continue;
            }
            f.* = .{ .prop = undefined, .leaf = false, .predictor = .zero, .value = undefined, .next = undefined };
            f.prop[0] = @intCast(nd.property);
            f.value[0] = nd.value;
            for (0..2) |c| {
                const ci: u32 = nd.child + @as(u32, @intCast(c));
                const ch = nodes[ci];
                if (ch.property < 0) {
                    // Tests property 0 against itself's maximum: either
                    // way the leaf.
                    f.prop[1 + c] = 0;
                    f.value[1 + c] = 0;
                    f.next[2 * c] = ci;
                    f.next[2 * c + 1] = ci;
                } else {
                    f.prop[1 + c] = @intCast(ch.property);
                    f.value[1 + c] = ch.value;
                    f.next[2 * c] = ch.child;
                    f.next[2 * c + 1] = ch.child + 1;
                }
            }
        }
        return out[0..nodes.len];
    }

    /// The leaf `props` reach from node `start`.
    pub inline fn walk(flat: []const Flat, start: u32, props: *const [max_props]i32) u32 {
        var f = start;
        while (!flat[f].leaf) {
            const nd = &flat[f];
            const c0 = props[nd.prop[0]] > nd.value[0];
            const ca = props[nd.prop[1]] > nd.value[1];
            const cb = props[nd.prop[2]] > nd.value[2];
            const sel: usize = if (c0) @intFromBool(!ca) else 2 + @as(usize, @intFromBool(!cb));
            f = nd.next[sel];
        }
        return f;
    }
};

/// A channel: `w` by `h` samples, row after row.
pub const Plane = struct {
    w: u32,
    h: u32,
    data: []i32,
};

// Pixels.

pub const Neighbours = dec.Neighbours;
pub const clampedGradient = dec.clampedGradient;
pub const predictOne = dec.predictOne;

/// The decoder's neighbours of (x, y) in `ch`, edge rules included.
pub inline fn neighbours(ch: *const dec.Channel, x: usize, y: usize) Neighbours {
    return dec.neighbours(ch, x, y);
}

/// The packed residual of `v` predicted as `g`. It wraps to 32 bits as
/// the decoder's reconstruction does: the weighted predictor's guesses
/// are not bounded by the samples' range.
pub inline fn residual(v: i32, g: i64) u32 {
    return ent.packSigned(@truncate(v - g));
}

/// Properties 2 to 14 at (x, y); `prev9` is property 9 of the pixel to
/// the left (0 at the start of a row) and becomes this pixel's.
pub inline fn pixelProps(props: *[max_props]i32, n: Neighbours, x: usize, y: usize, prev9: *i32) void {
    props[2] = @intCast(y);
    props[3] = @intCast(x);
    props[4] = @truncate(if (n.top > 0) n.top else -n.top);
    props[5] = @truncate(if (n.left > 0) n.left else -n.left);
    props[6] = @truncate(n.top);
    props[7] = @truncate(n.left);
    props[8] = @truncate(n.left - prev9.*);
    props[9] = @truncate(n.left + n.top - n.topleft);
    prev9.* = props[9];
    props[10] = @truncate(n.left - n.topleft);
    props[11] = @truncate(n.topleft - n.top);
    props[12] = @truncate(n.top - n.topright);
    props[13] = @truncate(n.top - n.toptop);
    props[14] = @truncate(n.left - n.leftleft);
}

/// The reference properties at (x, y): for each of `refs`, nearest first,
/// |v|, v, |v - g|, v - g, where g is its clamped gradient prediction
/// (with modular.zig's edge rules for references).
pub inline fn refProps(props: *[max_props]i32, refs: []const Plane, x: usize, y: usize) void {
    for (refs, 0..) |r, k| {
        const w: usize = r.w;
        const rp = r.data[y * w ..];
        const v: i64 = rp[x];
        const vleft: i64 = if (x > 0) rp[x - 1] else 0;
        const vtop: i64 = if (y > 0) r.data[(y - 1) * w + x] else vleft;
        const vtopleft: i64 = if (x > 0 and y > 0) r.data[(y - 1) * w + x - 1] else vleft;
        const g = clampedGradient(vleft, vtop, vtopleft);
        const o = props[num_props + 4 * k ..][0..4];
        o[0] = @truncate(if (v < 0) -v else v);
        o[1] = @truncate(v);
        o[2] = @truncate(if (v - g < 0) g - v else v - g);
        o[3] = @truncate(v - g);
    }
}

/// The decoder's weighted predictor, with the default header, for a
/// channel `w` wide, its memory from `mem`.
pub const Wp = struct {
    /// Five arrays, each aligned by the decoder's Arena: to its element,
    /// or to a cache line from 4 KiB up.
    pub fn memory(w: usize) usize {
        return 5 * ((w + 2) * 2 * 4 + 64);
    }

    pub fn init(mem: *Bump, w: usize) !dec.Wp {
        var arena: Arena = .init(try mem.alloc(u8, memory(w)));
        return dec.Wp.init(&arena, .{}, w) catch unreachable;
    }
};

/// The weighted predictor's guess at (x, y), and property 15 in `prop`.
inline fn predictWp(wp: *dec.Wp, x: usize, y: usize, n: Neighbours, prop: *i32) i64 {
    var max_err: i64 = undefined;
    const g = wp.predict(x, y, n.top, n.left, n.topright, n.topleft, n.toptop, &max_err);
    prop.* = @truncate(max_err);
    return g;
}

// Tokens.

/// What a channel needs from the tree once its static properties are
/// known: where to start, and whether the weighted predictor runs.
const Plan = struct {
    start: u32,
    uses_wp: bool,
};

fn plan(nodes: []const Node, chan: i32, stream: i32) Plan {
    const statics = [2]i32{ chan, stream };
    var start: u32 = 0;
    while (nodes[start].property >= 0 and nodes[start].property < 2) {
        const nd = nodes[start];
        start = if (statics[@intCast(nd.property)] > nd.value) nd.child else nd.child + 1;
    }
    // Whether any node below uses the weighted predictor.
    var stack: [2050]u32 = undefined;
    var sp: usize = 1;
    stack[0] = start;
    var uses_wp = false;
    while (sp > 0) {
        sp -= 1;
        const nd = nodes[stack[sp]];
        if (nd.property < 0) {
            uses_wp = uses_wp or nd.predictor == .weighted;
            continue;
        }
        uses_wp = uses_wp or nd.property == wp_prop;
        stack[sp] = nd.child;
        stack[sp + 1] = nd.child + 1;
        sp += 2;
    }
    return .{ .start = start, .uses_wp = uses_wp };
}

/// Appends the tokens of channel `ch` (index `chan` in stream `stream`)
/// under `tree` to `out` and returns how many. `mem` holds the weighted
/// predictor's rows.
pub fn tokenize(
    mem: *Bump,
    ch: Plane,
    chan: u32,
    stream: u32,
    tree: *const Tree,
    flat: []const Flat,
    refs: []const Plane,
    out: []Token,
) !usize {
    const w: usize = ch.w;
    const h: usize = ch.h;
    if (w == 0 or h == 0) return 0;
    const nodes = tree.nodes;
    const p = plan(nodes, @intCast(chan), @bitCast(stream));
    const d = ch.data;
    const c: dec.Channel = .{ .w = ch.w, .h = ch.h, .data = ch.data };
    var k: usize = 0;
    if (nodes[p.start].property < 0 and nodes[p.start].predictor != .weighted) {
        const leaf = nodes[p.start];
        const ctx = leaf.child;
        for (0..h) |y| {
            for (0..w) |x| {
                const g = predictOne(leaf.predictor, neighbours(&c, x, y), 0);
                out[k] = .{ .ctx = ctx, .value = residual(d[y * w + x], g) };
                k += 1;
            }
        }
        return k;
    }
    const m = mem.mark();
    defer mem.release(m);
    var t: Tokenizer = .{
        .ch = c,
        .d = d,
        .w = w,
        .flat = flat,
        .start = p.start,
        .refs = refs,
        .out = out,
        .wp = if (p.uses_wp) try Wp.init(mem, w) else undefined,
    };
    t.props[0] = @intCast(chan);
    t.props[1] = @bitCast(stream);
    if (p.uses_wp) {
        if (refs.len > 0) t.rows(true, true, h) else t.rows(true, false, h);
    } else {
        if (refs.len > 0) t.rows(false, true, h) else t.rows(false, false, h);
    }
    return t.k;
}

/// A channel's tokenization, with what varies per call fixed at compile
/// time: whether the weighted predictor runs, whether there are
/// reference channels, and whether a pixel's neighbours are all inside.
const Tokenizer = struct {
    ch: dec.Channel,
    d: []const i32,
    w: usize,
    flat: []const Flat,
    start: u32,
    refs: []const Plane,
    out: []Token,
    wp: dec.Wp,
    props: [max_props]i32 = @splat(0),
    k: usize = 0,

    fn rows(t: *Tokenizer, comptime uses_wp: bool, comptime has_refs: bool, h: usize) void {
        const w = t.w;
        for (0..h) |y| {
            var prev9: i32 = 0;
            if (y >= 2 and w >= 5) {
                t.pixel(uses_wp, has_refs, false, 0, y, &prev9);
                t.pixel(uses_wp, has_refs, false, 1, y, &prev9);
                for (2..w - 2) |x| t.pixel(uses_wp, has_refs, true, x, y, &prev9);
                t.pixel(uses_wp, has_refs, false, w - 2, y, &prev9);
                t.pixel(uses_wp, has_refs, false, w - 1, y, &prev9);
            } else {
                for (0..w) |x| t.pixel(uses_wp, has_refs, false, x, y, &prev9);
            }
        }
    }

    inline fn pixel(
        t: *Tokenizer,
        comptime uses_wp: bool,
        comptime has_refs: bool,
        comptime inside: bool,
        x: usize,
        y: usize,
        prev9: *i32,
    ) void {
        const d = t.d;
        const w = t.w;
        const n = if (inside) neighboursInside(d, w, x, y) else neighbours(&t.ch, x, y);
        pixelProps(&t.props, n, x, y, prev9);
        if (has_refs) refProps(&t.props, t.refs, x, y);
        var wp_pred: i64 = 0;
        if (uses_wp) wp_pred = predictWp(&t.wp, x, y, n, &t.props[wp_prop]);
        const leaf = &t.flat[Flat.walk(t.flat, t.start, &t.props)];
        const v = d[y * w + x];
        const g = predictOne(leaf.predictor, n, wp_pred);
        t.out[t.k] = .{ .ctx = leaf.next[0], .value = residual(v, g) };
        t.k += 1;
        if (uses_wp) t.wp.update(v, x, y);
    }
};

/// `neighbours` for a pixel at least two from the left, right, and top
/// edges, where every neighbour is inside.
inline fn neighboursInside(d: []const i32, w: usize, x: usize, y: usize) Neighbours {
    const i = y * w + x;
    return .{
        .left = d[i - 1],
        .top = d[i - w],
        .topleft = d[i - w - 1],
        .topright = d[i - w + 1],
        .leftleft = d[i - 2],
        .toptop = d[i - 2 * w],
        .toprightright = d[i - w + 2],
    };
}

// Learning a tree.

pub const LearnOptions = struct {
    /// The predictors a leaf may choose from.
    predictors: []const Predictor,
    /// Whether the weighted predictor's property may be split on.
    wp_prop: bool,
    /// Earlier channels whose values are properties.
    refs: u32 = 0,
    /// The hybrid integers residuals are counted as.
    config: ent.Config = .{},
    /// Thresholds per property.
    max_thresholds: u32 = 32,
    max_leaves: u32 = 256,
    /// A split must save this many bits, in the whole image's terms.
    split_cost: f32 = 48,
    /// And this many bits per token the node uses, in the samples'
    /// terms: splitting samples at random lowers their entropy by about
    /// half a bit per token, which is noise, not gain.
    noise: f32 = 1,
    /// Samples a split is judged on, at most.
    split_samples: u32 = 16384,
    /// Splits are judged with this many of the node's cheapest
    /// predictors; 0 for all.
    search_predictors: u32 = 0,
};

/// Samples for learning a tree: each sampled pixel's properties and the
/// token of its residual under every candidate predictor (capped at
/// `learn_tokens - 1`). Until `thr` is set, properties are kept whole, for
/// choosing thresholds from; after, only their buckets, a byte each.
pub const Samples = struct {
    props: []i32,
    buckets: []u8,
    tokens: []u8,
    thr: ?*const Thresholds = null,
    num_pred: usize,
    /// Properties per sample: 16 and four per reference channel.
    nprops: usize,
    cap: usize,
    len: usize = 0,
    /// Pixels seen, sampled or not.
    seen: u64 = 0,
    /// Take one pixel of every `stride`.
    stride: u32 = 1,
    phase: u32 = 0,
    /// When not 0, the state of a generator that picks the pixels instead,
    /// so that their positions do not repeat with the stride.
    random: u32 = 0,

    /// For up to `cap` samples, `whole` of them with whole properties.
    pub fn memory(cap: usize, whole: usize, num_pred: usize, refs: usize) usize {
        const nprops = num_props + 4 * refs;
        return whole * nprops * 4 + cap * (nprops + num_pred) + 64;
    }

    pub fn init(mem: *Bump, cap: usize, whole: usize, num_pred: usize, refs: usize) !Samples {
        const nprops = num_props + 4 * refs;
        return .{
            .props = try mem.alloc(i32, whole * nprops),
            .buckets = try mem.alloc(u8, cap * nprops),
            .tokens = try mem.alloc(u8, cap * num_pred),
            .num_pred = num_pred,
            .nprops = nprops,
            .cap = cap,
        };
    }

    /// Replaces the whole properties taken so far with their buckets.
    pub fn bucketize(s: *Samples, thr: *const Thresholds) void {
        s.thr = thr;
        const np = s.nprops;
        for (0..s.len) |i| thr.bucketsOf(s.props[i * np ..][0..np], s.buckets[i * np ..][0..np]);
    }
};

/// Each property's thresholds, which divide its values into buckets.
pub const Thresholds = struct {
    count: [max_props]u32 = @splat(0),
    /// Ascending, then padded with the largest value, so that a value's
    /// bucket is how many lie below it.
    values: [max_props][max_buckets - 1]i32 = @splat(@splat(std.math.maxInt(i32))),
    /// The lanes worth comparing: 16, 32, or 64.
    lanes: u32 = 16,

    fn bucketsOf(t: *const Thresholds, props: []const i32, out: []u8) void {
        switch (t.lanes) {
            16 => t.bucketsIn(16, props, out),
            32 => t.bucketsIn(32, props, out),
            else => t.bucketsIn(64, props, out),
        }
    }

    inline fn bucketsIn(t: *const Thresholds, comptime lanes: u32, props: []const i32, out: []u8) void {
        const V = @Vector(lanes, i32);
        const Mask = @Int(.unsigned, lanes);
        for (props, out, 0..) |v, *o, p| {
            const tv: V = t.values[p][0..lanes].*;
            const below: Mask = @bitCast(tv < @as(V, @splat(v)));
            o.* = @popCount(below);
        }
    }

    /// Chooses thresholds from an even share of `m` of `s`'s whole
    /// properties.
    pub fn choose(s: *const Samples, m_max: usize, options: *const LearnOptions) Thresholds {
        var t: Thresholds = .{};
        const max_thr: usize = @min(options.max_thresholds, max_buckets - 1);
        t.lanes = if (max_thr <= 16) 16 else if (max_thr <= 32) 32 else 64;
        const n = s.len;
        if (n == 0) return t;
        const nprops = s.nprops;
        const m = @min(n, m_max, max_threshold_samples);
        var hist: [sort_range]u32 = undefined;
        var sort_buf: [max_threshold_samples]i32 = undefined;
        for (0..nprops) |p| {
            if (p == 1 or (p == wp_prop and !options.wp_prop)) continue;
            const sorted = sort_buf[0..m];
            for (sorted, 0..) |*v, i| v.* = s.props[(i * n / m) * nprops + p];
            sortValues(sorted, &hist);
            // Thresholds: every distinct value when there are few, else half
            // at even quantiles of the samples and half spread over the
            // distinct values, so that a long tail still gets some. A
            // threshold splits values above it from the rest, so the largest
            // value is never one.
            var cand: [2 * max_buckets]i32 = undefined;
            var nc: usize = 0;
            const top = sorted[m - 1];
            // Quantiles of the samples, before `sorted` loses its repeats.
            const half = max_thr / 2;
            var quant: [max_buckets]i32 = undefined;
            const nq = max_thr - half;
            for (quant[0..nq], 0..) |*v, q| v.* = sorted[(q * 2 + 1) * m / (nq * 2)];
            var u: usize = 0;
            for (sorted) |v| {
                if (u == 0 or sorted[u - 1] != v) {
                    sorted[u] = v;
                    u += 1;
                }
            }
            // `sorted` is now the distinct values.
            if (u - 1 <= max_thr) {
                for (sorted[0 .. u - 1]) |v| {
                    cand[nc] = v;
                    nc += 1;
                }
            } else {
                for (0..half) |q| {
                    cand[nc] = sorted[(q * 2 + 1) * (u - 1) / (half * 2)];
                    nc += 1;
                }
                @memcpy(cand[nc..][0..nq], quant[0..nq]);
                nc += nq;
            }
            std.sort.pdq(i32, cand[0..nc], {}, std.sort.asc(i32));
            var vals: [max_buckets - 1]i32 = @splat(std.math.maxInt(i32));
            var k: u32 = 0;
            for (cand[0..nc]) |v| {
                if (v >= top) continue;
                if (k > 0 and vals[k - 1] >= v) continue;
                vals[k] = v;
                k += 1;
            }
            t.count[p] = k;
            t.values[p] = vals;
        }
        return t;
    }
};

/// Adds the pixels of rows `y0` to `y1` of channel `ch` to `s`, one in
/// `s.stride`. The weighted predictor starts afresh at `y0`, so past the
/// first row its state differs from the encoder's, which is close enough
/// for learning.
pub fn sample(
    mem: *Bump,
    s: *Samples,
    ch: Plane,
    chan: u32,
    stream: u32,
    options: *const LearnOptions,
    refs: []const Plane,
    y0: usize,
    y1: usize,
) !void {
    const w: usize = ch.w;
    if (w == 0 or y1 <= y0) return;
    const d = ch.data;
    const c: dec.Channel = .{ .w = ch.w, .h = ch.h, .data = ch.data };
    var uses_wp = options.wp_prop;
    for (options.predictors) |pr| uses_wp = uses_wp or pr == .weighted;
    const m = mem.mark();
    defer mem.release(m);
    var wp: dec.Wp = undefined;
    if (uses_wp) wp = try Wp.init(mem, w);
    var props: [max_props]i32 = @splat(0);
    props[0] = @intCast(chan);
    props[1] = @bitCast(stream);
    const nr = @min(refs.len, (s.nprops - num_props) / 4);
    for (y0..y1) |y| {
        var prev9: i32 = 0;
        for (0..w) |x| {
            const n = neighbours(&c, x, y);
            pixelProps(&props, n, x, y, &prev9);
            if (nr > 0) refProps(&props, refs[0..nr], x, y);
            var wp_pred: i64 = 0;
            if (uses_wp) wp_pred = predictWp(&wp, x, y, n, &props[wp_prop]);
            const v = d[y * w + x];
            if (s.random != 0) {
                // xorshift32: one pixel in `stride` at random.
                s.random ^= s.random << 13;
                s.random ^= s.random >> 17;
                s.random ^= s.random << 5;
                if (s.random % s.stride == 0) s.phase = s.stride;
            } else s.phase += 1;
            if (s.phase >= s.stride and s.len < s.cap) {
                s.phase = 0;
                if (s.thr) |thr| {
                    thr.bucketsOf(props[0..s.nprops], s.buckets[s.len * s.nprops ..][0..s.nprops]);
                } else {
                    @memcpy(s.props[s.len * s.nprops ..][0..s.nprops], props[0..s.nprops]);
                }
                const tk = s.tokens[s.len * s.num_pred ..][0..s.num_pred];
                for (options.predictors, tk) |pr, *t| {
                    const tok = options.config.split(residual(v, predictOne(pr, n, wp_pred))).token;
                    t.* = @intCast(@min(tok, learn_tokens - 1));
                }
                s.len += 1;
            }
            if (uses_wp) wp.update(v, x, y);
        }
    }
    s.seen += w * (y1 - y0);
}

/// Tokens counted in learning: larger tokens share the last.
const learn_tokens = 64;
/// Samples the thresholds are chosen from: a sixteenth of the samples,
/// between 1024 and `max_threshold_samples`.
pub fn thresholdSamples(n: usize) usize {
    return @min(n, std.math.clamp(n / 16, 1024, max_threshold_samples));
}
pub const max_threshold_samples = 4096;
const max_predictors = 14;
const max_buckets = 65;

/// The bits a token's extra bits take under `config`.
fn extraBits(config: ent.Config, token: u32) f32 {
    const split = @as(u32, 1) << config.split_exp;
    if (token < split) return 0;
    const ml = config.msb + config.lsb;
    return @floatFromInt(@as(u32, config.split_exp) - ml + ((token - split) >> ml));
}

/// x * log2(x), from a table for small x.
const xlog_table = blk: {
    @setEvalBranchQuota(100000);
    var t: [4096]f32 = undefined;
    t[0] = 0;
    for (1..4096) |i| {
        const x: f64 = @floatFromInt(i);
        t[i] = @floatCast(x * @log2(x));
    }
    break :blk t;
};

inline fn xlog(c: u32) f32 {
    if (c < xlog_table.len) return xlog_table[c];
    const x: f32 = @floatFromInt(c);
    return x * @log2(x);
}

/// The memory `learn` takes for `s`.
pub fn learnMemory(cap: usize, options: LearnOptions) usize {
    const np = options.predictors.len;
    const nprops = num_props + 4 * options.refs;
    return cap * 4 + // indices
        nprops * max_buckets * np * learn_tokens * 2 + // counts
        nprops * max_buckets * np * 8 + // their masks
        nprops * max_buckets * 4 + // samples per bucket
        (2 * options.max_leaves + 1) * (@sizeOf(Node) + @sizeOf(Range)) + 1024;
}

const Range = struct { begin: u32, end: u32 };

/// Learns a tree from `s`. `scale` is the pixels each sample stands for.
pub fn learn(mem: *Bump, s: *const Samples, options: LearnOptions, nodes_out: []Node) !Tree {
    const thr = s.thr.?;
    const n = s.len;
    const np = options.predictors.len;
    const nprops = s.nprops;
    const scale: f32 = if (n == 0) 1 else @as(f32, @floatFromInt(s.seen)) / @as(f32, @floatFromInt(n));
    if (n == 0) {
        nodes_out[0] = .{ .predictor = options.predictors[0] };
        var t: Tree = .{ .nodes = nodes_out[0..1], .num_leaves = 1 };
        t.numberLeaves();
        return t;
    }
    const buckets = s.buckets;
    const nthr = &thr.count;
    // Tokens per predictor, capped for counting, and their extra bits.
    const toks = s.tokens;
    const config = options.config;
    var extra: [learn_tokens]f32 = undefined;
    for (&extra, 0..) |*e, t| e.* = extraBits(config, @intCast(t));
    const idx = try mem.alloc(u32, n);
    for (idx, 0..) |*v, i| v.* = @intCast(i);
    // A node judges at most `split_samples` samples, so u16 counts hold.
    std.debug.assert(options.split_samples <= std.math.maxInt(u16));
    const counts = try mem.alloc(u16, nprops * max_buckets * np * learn_tokens);
    const bucket_n = try mem.alloc(u32, nprops * max_buckets);
    @memset(bucket_n, 0);
    // Per row of `counts`, which of its entries are not zero, so that a
    // sweep visits only those.
    const masks = try mem.alloc(u64, nprops * max_buckets * np);
    @memset(masks, 0);
    // `counts` is zero up to here, and each node clears what it counted,
    // so a small node costs little.
    var clean: usize = 0;
    var leaf_cost: f64 = 0;

    const max_nodes = 2 * @as(usize, options.max_leaves) - 1;
    const nodes = nodes_out[0..@min(nodes_out.len, max_nodes)];
    const ranges = try mem.alloc(Range, nodes.len);
    nodes[0] = .{};
    ranges[0] = .{ .begin = 0, .end = @intCast(n) };
    var num_nodes: usize = 1;
    var leaves: usize = 1;
    var cur: usize = 0;
    while (cur < num_nodes) : (cur += 1) {
        const r = ranges[cur];
        const items = idx[r.begin..r.end];
        // The node as a leaf.
        var total: [max_predictors][learn_tokens]u32 = undefined;
        for (total[0..np]) |*t| @memset(t, 0);
        for (items) |i| {
            for (0..np) |k| total[k][toks[i * np + k]] += 1;
        }
        // The predictors by their cost as a leaf; splits are judged with
        // the cheapest few.
        var pcost: [max_predictors]f32 = undefined;
        var sel: [max_predictors]u8 = undefined;
        for (0..np) |k| {
            pcost[k] = cost(&total[k], &extra, @intCast(items.len));
            sel[k] = @intCast(k);
        }
        for (1..np) |a| {
            var b = a;
            while (b > 0 and pcost[sel[b]] < pcost[sel[b - 1]]) : (b -= 1) std.mem.swap(u8, &sel[b], &sel[b - 1]);
        }
        leaf_cost = pcost[sel[0]];
        const ns: usize = if (options.search_predictors == 0) np else @min(np, options.search_predictors);
        nodes[cur] = .{ .predictor = options.predictors[sel[0]] };
        if (leaves >= options.max_leaves or num_nodes + 2 > nodes.len or items.len < 2) continue;
        // No split saves more than the whole node costs.
        if (leaf_cost * scale <= options.split_cost) continue;
        // The best split over every property and threshold. Counts are
        // per property, bucket, predictor, and token in use.
        var amap: [learn_tokens]u8 = undefined;
        var active: [learn_tokens]u8 = undefined;
        var na: usize = 0;
        for (0..learn_tokens) |t| {
            var any = false;
            for (sel[0..ns]) |k| any = any or total[k][t] != 0;
            amap[t] = @intCast(na);
            if (any) {
                active[na] = @intCast(t);
                na += 1;
            }
        }
        var rows: usize = 0;
        var off: [num_props + 4 * max_refs]usize = undefined;
        for (0..nprops) |p| {
            off[p] = rows;
            if (nthr[p] > 0) rows += nthr[p] + 1;
        }
        const cn = counts[0 .. rows * ns * na];
        if (cn.len > clean) {
            @memset(counts[clean..cn.len], 0);
            clean = cn.len;
        }
        // A large node's split is judged on an even share of its samples.
        const sub_step = (items.len + options.split_samples - 1) / options.split_samples;
        var sub_total: [max_predictors][learn_tokens]u32 = undefined;
        if (sub_step > 1) {
            for (sub_total[0..ns]) |*t| @memset(t, 0);
            var q: usize = 0;
            while (q < items.len) : (q += sub_step) {
                const i = items[q];
                for (sel[0..ns], 0..) |k, j| sub_total[j][toks[i * np + k]] += 1;
            }
        }
        // Indexed by position in `sel`.
        if (sub_step == 1) {
            for (sel[0..ns], 0..) |k, j| sub_total[j] = total[k];
        }
        const judged = &sub_total;
        var n_items: u32 = 0;
        for (judged[0]) |c| n_items += c;
        var sub_cost: f64 = std.math.inf(f64);
        for (0..ns) |j| sub_cost = @min(sub_cost, cost(&judged[j], &extra, n_items));
        var q: usize = 0;
        while (q < items.len) : (q += sub_step) {
            const i = items[q];
            const b = buckets[i * nprops ..][0..nprops];
            const tk = toks[i * np ..][0..np];
            for (0..nprops) |p| {
                if (nthr[p] == 0) continue;
                bucket_n[off[p] + b[p]] += 1;
                const base = (off[p] + b[p]) * ns;
                for (sel[0..ns], 0..) |k, j| {
                    const a = amap[tk[k]];
                    cn[(base + j) * na + a] += 1;
                    masks[base + j] |= @as(u64, 1) << @intCast(a);
                }
            }
        }
        var tot: [max_predictors][learn_tokens]u32 = undefined;
        var tot_xlog: [max_predictors]f64 = undefined;
        var tot_extra: [max_predictors]f64 = undefined;
        for (0..ns) |k| {
            tot_xlog[k] = 0;
            tot_extra[k] = 0;
            for (active[0..na], 0..) |t, a| {
                tot[k][a] = judged[k][t];
                tot_xlog[k] += xlog(judged[k][t]);
                tot_extra[k] += @as(f64, @floatFromInt(judged[k][t])) * extra[t];
            }
        }
        const noise_bits: f64 = options.noise * @as(f32, @floatFromInt(na));
        const sub_scale = scale * @as(f64, @floatFromInt(items.len)) / @as(f64, @floatFromInt(n_items));
        var best_gain: f64 = 0;
        var best_p: usize = 0;
        var best_j: u32 = 0;
        for (0..nprops) |p| {
            const k_thr = nthr[p];
            if (k_thr == 0) continue;
            var left: [max_predictors][learn_tokens]u32 = undefined;
            var sum_l: [max_predictors]f64 = undefined;
            var sum_r: [max_predictors]f64 = undefined;
            var extra_l: [max_predictors]f64 = undefined;
            for (0..ns) |k| {
                @memset(left[k][0..na], 0);
                sum_l[k] = 0;
                sum_r[k] = tot_xlog[k];
                extra_l[k] = 0;
            }
            var left_n: u32 = 0;
            // Buckets 0..j go to the "not above" side.
            for (0..k_thr) |j| {
                const base = (off[p] + j) * ns;
                const add = bucket_n[off[p] + j];
                if (add == 0) continue;
                left_n += add;
                if (left_n == n_items) break;
                for (0..ns) |k| {
                    const row = cn[(base + k) * na ..][0..na];
                    var nonzero = masks[base + k];
                    while (nonzero != 0) : (nonzero &= nonzero - 1) {
                        const a = @ctz(nonzero);
                        const c: u32 = row[a];
                        const old = left[k][a];
                        const new = old + c;
                        left[k][a] = new;
                        sum_l[k] += xlog(new) - xlog(old);
                        sum_r[k] += xlog(tot[k][a] - new) - xlog(tot[k][a] - old);
                        extra_l[k] += @as(f64, @floatFromInt(c)) * extra[active[a]];
                    }
                }
                var cl: f64 = std.math.inf(f64);
                var cr: f64 = std.math.inf(f64);
                const xl: f64 = xlog(left_n);
                const xr: f64 = xlog(n_items - left_n);
                for (0..ns) |k| {
                    cl = @min(cl, xl - sum_l[k] + extra_l[k]);
                    cr = @min(cr, xr - sum_r[k] + tot_extra[k] - extra_l[k]);
                }
                const gain = (sub_cost - cl - cr - noise_bits) * sub_scale;
                if (gain > best_gain) {
                    best_gain = gain;
                    best_p = p;
                    best_j = @intCast(j);
                }
            }
        }
        // Clear the counts: sample by sample when there are few.
        const judged_n = (items.len + sub_step - 1) / sub_step;
        if (judged_n * nprops * ns < cn.len) {
            q = 0;
            while (q < items.len) : (q += sub_step) {
                const i = items[q];
                const b = buckets[i * nprops ..][0..nprops];
                const tk = toks[i * np ..][0..np];
                for (0..nprops) |p| {
                    if (nthr[p] == 0) continue;
                    bucket_n[off[p] + b[p]] = 0;
                    const base = (off[p] + b[p]) * ns;
                    for (sel[0..ns], 0..) |k, j| cn[(base + j) * na + amap[tk[k]]] = 0;
                    @memset(masks[base..][0..ns], 0);
                }
            }
        } else {
            @memset(cn, 0);
            @memset(bucket_n[0..rows], 0);
            @memset(masks[0 .. rows * ns], 0);
        }
        if (best_gain <= options.split_cost) continue;
        // Split: samples above the threshold first.
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            if (buckets[items[lo] * nprops + best_p] > best_j) {
                lo += 1;
            } else {
                hi -= 1;
                std.mem.swap(u32, &items[lo], &items[hi]);
            }
        }
        nodes[cur] = .{
            .property = @intCast(best_p),
            .value = thr.values[best_p][best_j],
            .child = @intCast(num_nodes),
        };
        nodes[num_nodes] = .{};
        nodes[num_nodes + 1] = .{};
        ranges[num_nodes] = .{ .begin = r.begin, .end = r.begin + @as(u32, @intCast(lo)) };
        ranges[num_nodes + 1] = .{ .begin = r.begin + @as(u32, @intCast(lo)), .end = r.end };
        num_nodes += 2;
        leaves += 1;
    }
    var t: Tree = .{ .nodes = nodes[0..num_nodes], .num_leaves = 0 };
    t.numberLeaves();
    return t;
}

/// Values spanning fewer than this are sorted by counting.
const sort_range = 4096;

/// Sorts `v` ascending: by counting when its values span less than
/// `sort_range`, as most properties' do, else by comparison.
fn sortValues(v: []i32, hist: *[sort_range]u32) void {
    if (v.len == 0) return;
    var lo = v[0];
    var hi = v[0];
    for (v) |x| {
        lo = @min(lo, x);
        hi = @max(hi, x);
    }
    const span = @as(i64, hi) - lo;
    if (span >= sort_range) return std.sort.pdq(i32, v, {}, std.sort.asc(i32));
    const h = hist[0..@intCast(span + 1)];
    @memset(h, 0);
    for (v) |x| h[@intCast(x - lo)] += 1;
    var at: usize = 0;
    for (h, 0..) |c, k| {
        @memset(v[at..][0..c], lo + @as(i32, @intCast(k)));
        at += c;
    }
}

/// Bits to code `c`'s tokens with their own histogram.
fn cost(c: *const [learn_tokens]u32, extra: *const [learn_tokens]f32, total: u32) f32 {
    if (total == 0) return 0;
    var bits: f32 = xlog(total);
    for (c, extra) |k, e| {
        if (k == 0) continue;
        bits += @as(f32, @floatFromInt(k)) * e - xlog(k);
    }
    return bits;
}
