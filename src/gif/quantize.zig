//! Palettes for images with more colors than a GIF holds, and the pixels
//! mapped to them.
//!
//! Every method starts from one histogram of the opaque pixels at 5 bits
//! per channel, 32³ cells, each with its pixel count and the sums of its
//! pixels' channels and squared channels, so a palette entry is the mean of
//! the pixels it stands for, never a cell's center:
//!
//! - `wu`: Xiaolin Wu's quantizer ("Efficient Statistical Computations for
//!   Optimal Color Quantization", Graphics Gems II, 1991). Boxes of cells
//!   are cut in two, the box with the largest variance first, at the plane
//!   that leaves the least variance, read from cumulative moments in
//!   constant time per box.
//! - `median_cut`: Heckbert's median cut ("Color Image Quantization for
//!   Frame Buffer Display", SIGGRAPH 1982): the box with the most pixels
//!   times its longest side is cut across that side at its median pixel.
//! - `octree`: Gervautz and Purgathofer's octree ("A Simple Method for
//!   Color Quantization: Octree Quantization", 1988), over the cells: the
//!   deepest nodes merge their children, least populated first, until the
//!   leaves fit.
//!
//! `refine` then runs Lloyd's k-means over the cells (weighted by their
//! pixels) from that palette. A pixel maps to the palette entry nearest
//! its 6-bit cell's center (`Lookup`), found once per cell, optionally
//! with Floyd-Steinberg error diffusion (`Ditherer`). Distance is plain
//! squared RGB difference.

const std = @import("std");
const testing = std.testing;

pub const Method = enum { wu, median_cut, octree };

pub const Palette = struct {
    colors: [256][3]u8 = undefined,
    len: u16 = 0,
};

/// The cumulative tables' side: 32 cells per channel and a zero plane.
const side = 33;
const cells = side * side * side;

const Moment = struct { w: u64, r: u64, g: u64, b: u64, m2: u64 };

/// A nonempty cell: its pixels' mean color and count.
const Cell = struct { c: [3]f32, w: f32 };

/// The octree's levels above the cells: 8^0 to 8^4 nodes.
const node_count = 1 + 8 + 64 + 512 + 4096;
const level_start = [_]usize{ 0, 1, 9, 73, 585, 4681 };
const Node = struct { w: u64, r: u64, g: u64, b: u64 };

/// The quantizer's memory, in the encoder's work memory.
pub const Work = struct {
    /// Garbage but where `touched` says `add` wrote, so a frame clears
    /// only the bits, not the whole table (`raw`).
    moments: [cells]Moment,
    touched: [(cells + 63) / 64]u64,
    cells: [32 * 32 * 32]Cell,
    nodes: [node_count]Node,
    merged: [node_count]bool,
    order: [4096]u16,
};

inline fn cellIndex(r: u8, g: u8, b: u8) usize {
    return (@as(usize, r >> 3) + 1) * side * side + (@as(usize, g >> 3) + 1) * side + (@as(usize, b >> 3) + 1);
}

/// The histogram of the pixels added since `clear`.
pub const Histogram = struct {
    work: *Work,

    pub fn clear(h: Histogram) void {
        @memset(&h.work.touched, 0);
    }

    pub inline fn add(h: Histogram, r: u8, g: u8, b: u8) void {
        const i = cellIndex(r, g, b);
        const m = &h.work.moments[i];
        const sq = @as(u32, r) * r + @as(u32, g) * g + @as(u32, b) * b;
        const bit = @as(u64, 1) << @intCast(i & 63);
        if (h.work.touched[i >> 6] & bit == 0) {
            h.work.touched[i >> 6] |= bit;
            m.* = .{ .w = 1, .r = r, .g = g, .b = b, .m2 = sq };
            return;
        }
        m.w += 1;
        m.r += r;
        m.g += g;
        m.b += b;
        m.m2 += sq;
    }

    /// A palette of at most `max` colors (1 to 256) for the pixels added,
    /// which must be at least one; this consumes the histogram.
    pub fn palette(h: Histogram, method: Method, max: u16, refine: u8, out: *Palette) void {
        std.debug.assert(max >= 1);
        std.debug.assert(max <= 256);
        // Wu's method reads the moments; the others, and k-means, cells.
        const n = if (method == .wu and refine == 0) 0 else h.gatherCells();
        switch (method) {
            .wu => wu(h.work, max, out),
            .median_cut => medianCut(h.work.cells[0..n], max, out),
            .octree => octree(h.work, max, out),
        }
        if (refine > 0) kmeans(h.work.cells[0..n], refine, out);
    }

    /// Lists the nonempty cells, for every method but Wu's, and k-means.
    fn gatherCells(h: Histogram) usize {
        var n: usize = 0;
        for (1..side) |r| for (1..side) |g| for (1..side) |b| {
            const m = raw(h.work, (r * side + g) * side + b);
            if (m.w == 0) continue;
            const w: f64 = @floatFromInt(m.w);
            h.work.cells[n] = .{
                .c = .{
                    @floatCast(@as(f64, @floatFromInt(m.r)) / w),
                    @floatCast(@as(f64, @floatFromInt(m.g)) / w),
                    @floatCast(@as(f64, @floatFromInt(m.b)) / w),
                },
                .w = @floatCast(w),
            };
            n += 1;
        };
        return n;
    }
};

/// Cell `i`'s sums since `clear`: zero for a cell `add` never wrote.
fn raw(work: *const Work, i: usize) Moment {
    const bit = @as(u64, 1) << @intCast(i & 63);
    return if (work.touched[i >> 6] & bit != 0) work.moments[i] else std.mem.zeroes(Moment);
}

fn rawAt(work: *const Work, r: usize, g: usize, b: usize) Moment {
    return raw(work, (r * side + g) * side + b);
}

fn toByte(v: f64) u8 {
    return @intFromFloat(@min(255, @max(0, @round(v))));
}

// Wu's quantizer.

/// A box of cells, each bound exclusive below and inclusive above.
const Box = struct { lo: [3]u8, hi: [3]u8 };

fn at(m: *const [cells]Moment, r: usize, g: usize, b: usize) *const Moment {
    return &m[(r * side + g) * side + b];
}

/// The sums over `box`, from the cumulative moments.
fn volume(m: *const [cells]Moment, box: Box) Moment {
    const r0 = box.lo[0];
    const r1 = box.hi[0];
    const g0 = box.lo[1];
    const g1 = box.hi[1];
    const b0 = box.lo[2];
    const b1 = box.hi[2];
    var out: Moment = undefined;
    inline for (.{ "w", "r", "g", "b", "m2" }) |f| {
        // Added in an order that cannot go below zero.
        @field(out, f) = @field(at(m, r1, g1, b1), f) -% @field(at(m, r1, g1, b0), f) -%
            @field(at(m, r1, g0, b1), f) +% @field(at(m, r1, g0, b0), f) -%
            @field(at(m, r0, g1, b1), f) +% @field(at(m, r0, g1, b0), f) +%
            @field(at(m, r0, g0, b1), f) -% @field(at(m, r0, g0, b0), f);
    }
    return out;
}

/// The squared distance of a box's sum from the origin over its weight:
/// what a box's mean contributes, the term a cut maximizes.
fn spread(v: Moment) f64 {
    const r: f64 = @floatFromInt(v.r);
    const g: f64 = @floatFromInt(v.g);
    const b: f64 = @floatFromInt(v.b);
    return (r * r + g * g + b * b) / @as(f64, @floatFromInt(v.w));
}

fn variance(m: *const [cells]Moment, box: Box) f64 {
    const v = volume(m, box);
    if (v.w == 0) return 0;
    return @as(f64, @floatFromInt(v.m2)) - spread(v);
}

/// A moment's weight and color sums, the part a cut reads.
const Sums = @Vector(4, u64);

fn sums(m: *const Moment) Sums {
    return .{ m.w, m.r, m.g, m.b };
}

/// The sums over `box`'s cells whose coordinate on axis `d` is at most
/// `i`, less those at most 0 on it: the cumulative moments at the four
/// corners of that plane of the box.
fn plane(m: *const [cells]Moment, box: Box, d: usize, i: u8) Sums {
    const e = (d + 1) % 3;
    const f = (d + 2) % 3;
    var p: [3]usize = .{ box.hi[0], box.hi[1], box.hi[2] };
    p[d] = i;
    const hh = sums(at(m, p[0], p[1], p[2]));
    p[f] = box.lo[f];
    const hl = sums(at(m, p[0], p[1], p[2]));
    p[e] = box.lo[e];
    const ll = sums(at(m, p[0], p[1], p[2]));
    p[f] = box.hi[f];
    const lh = sums(at(m, p[0], p[1], p[2]));
    // Added in an order that cannot go below zero.
    return hh -% hl -% lh +% ll;
}

fn spreadOf(v: Sums) f64 {
    const r: f64 = @floatFromInt(v[1]);
    const g: f64 = @floatFromInt(v[2]);
    const b: f64 = @floatFromInt(v[3]);
    return (r * r + g * g + b * b) / @as(f64, @floatFromInt(v[0]));
}

/// Cuts `box` in two at the plane that leaves the least variance; false
/// when no plane leaves pixels on both sides. The sums below a plane at
/// `i` on axis `d` are the plane's less the box's lower face's, so each
/// plane costs four lookups.
fn cut(m: *const [cells]Moment, box: *Box, upper: *Box) bool {
    var best: f64 = -1;
    var best_dir: usize = 0;
    var best_at: u8 = 0;
    for (0..3) |d| {
        const base = plane(m, box.*, d, box.lo[d]);
        const whole = plane(m, box.*, d, box.hi[d]) -% base;
        var i = box.lo[d] + 1;
        while (i < box.hi[d]) : (i += 1) {
            const lower = plane(m, box.*, d, i) -% base;
            if (lower[0] == 0 or lower[0] == whole[0]) continue;
            const s = spreadOf(lower) + spreadOf(whole -% lower);
            if (s > best) {
                best = s;
                best_dir = d;
                best_at = i;
            }
        }
    }
    if (best < 0) return false;
    upper.* = box.*;
    upper.lo[best_dir] = best_at;
    box.hi[best_dir] = best_at;
    return true;
}

fn wu(work: *Work, max: u16, out: *Palette) void {
    const m = &work.moments;
    // Cumulative moments: each entry the sum over the box from the origin,
    // and the zero planes below the cells.
    const zero = std.mem.zeroes(Moment);
    for (0..side) |r| {
        var area: [side]Moment = @splat(zero);
        for (0..side) |g| {
            var line = zero;
            for (0..side) |b| {
                const i = (r * side + g) * side + b;
                if (r == 0 or g == 0 or b == 0) {
                    m[i] = zero;
                    continue;
                }
                const v = raw(work, i);
                inline for (.{ "w", "r", "g", "b", "m2" }) |f| {
                    @field(line, f) += @field(v, f);
                    @field(area[b], f) += @field(line, f);
                    @field(m[i], f) = @field(m[i - side * side], f) + @field(area[b], f);
                }
            }
        }
    }
    var boxes: [256]Box = undefined;
    var vv: [256]f64 = undefined;
    boxes[0] = .{ .lo = .{ 0, 0, 0 }, .hi = .{ 32, 32, 32 } };
    vv[0] = variance(m, boxes[0]);
    var n: usize = 1;
    var next: usize = 0;
    while (n < max) {
        if (cut(m, &boxes[next], &boxes[n])) {
            vv[next] = if (cellsIn(boxes[next]) > 1) variance(m, boxes[next]) else 0;
            vv[n] = if (cellsIn(boxes[n]) > 1) variance(m, boxes[n]) else 0;
            n += 1;
        } else {
            vv[next] = 0;
        }
        next = 0;
        for (vv[0..n], 0..) |v, i| {
            if (v > vv[next]) next = i;
        }
        if (vv[next] <= 0) break;
    }
    out.len = 0;
    for (boxes[0..n]) |box| {
        const v = volume(m, box);
        if (v.w == 0) continue;
        const w: f64 = @floatFromInt(v.w);
        out.colors[out.len] = .{
            toByte(@as(f64, @floatFromInt(v.r)) / w),
            toByte(@as(f64, @floatFromInt(v.g)) / w),
            toByte(@as(f64, @floatFromInt(v.b)) / w),
        };
        out.len += 1;
    }
}

fn cellsIn(box: Box) u32 {
    var n: u32 = 1;
    for (0..3) |d| n *= box.hi[d] - box.lo[d];
    return n;
}

// Median cut.

const CutBox = struct {
    start: usize,
    end: usize,
    w: f64,
    min: [3]f32,
    max: [3]f32,

    fn of(list: []const Cell, start: usize, end: usize) CutBox {
        var b: CutBox = .{ .start = start, .end = end, .w = 0, .min = @splat(255), .max = @splat(0) };
        for (list[start..end]) |c| {
            b.w += c.w;
            for (0..3) |d| {
                b.min[d] = @min(b.min[d], c.c[d]);
                b.max[d] = @max(b.max[d], c.c[d]);
            }
        }
        return b;
    }

    fn longest(b: CutBox) usize {
        var d: usize = 0;
        for (1..3) |e| {
            if (b.max[e] - b.min[e] > b.max[d] - b.min[d]) d = e;
        }
        return d;
    }

    fn score(b: CutBox) f64 {
        if (b.end - b.start < 2) return 0;
        const d = b.longest();
        return b.w * (b.max[d] - b.min[d]);
    }
};

fn medianCut(list: []Cell, max: u16, out: *Palette) void {
    var boxes: [256]CutBox = undefined;
    boxes[0] = .of(list, 0, list.len);
    var n: usize = 1;
    while (n < max) {
        var pick: usize = 0;
        for (boxes[0..n], 0..) |b, i| {
            if (b.score() > boxes[pick].score()) pick = i;
        }
        const b = boxes[pick];
        if (b.score() <= 0) break;
        const d = b.longest();
        const Ctx = struct {
            const Self = @This();
            d: usize,
            fn less(ctx: Self, x: Cell, y: Cell) bool {
                return x.c[ctx.d] < y.c[ctx.d];
            }
        };
        std.sort.pdq(Cell, list[b.start..b.end], Ctx{ .d = d }, Ctx.less);
        // The first cell past half the pixels starts the upper box, which
        // keeps at least one cell.
        var acc: f64 = 0;
        var mid = b.start + 1;
        for (list[b.start .. b.end - 1], b.start..) |c, i| {
            acc += c.w;
            mid = i + 1;
            if (acc >= b.w / 2) break;
        }
        boxes[pick] = .of(list, b.start, mid);
        boxes[n] = .of(list, mid, b.end);
        n += 1;
    }
    out.len = 0;
    for (boxes[0..n]) |b| {
        var sum: [3]f64 = @splat(0);
        for (list[b.start..b.end]) |c| {
            for (0..3) |d| sum[d] += @as(f64, c.c[d]) * c.w;
        }
        out.colors[out.len] = .{ toByte(sum[0] / b.w), toByte(sum[1] / b.w), toByte(sum[2] / b.w) };
        out.len += 1;
    }
}

// Octree, over the cells: level 5 is the cells, levels 0 to 4 the nodes
// above them, each 3 bits of a cell's coordinates deeper.

fn nodeIndex(level: usize, r: usize, g: usize, b: usize) usize {
    const s: u3 = @intCast(5 - level);
    const l: u4 = @intCast(level);
    return level_start[level] + ((r >> s) << (2 * l)) + ((g >> s) << l) + (b >> s);
}

fn octree(work: *Work, max: u16, out: *Palette) void {
    @memset(std.mem.asBytes(&work.nodes), 0);
    @memset(&work.merged, false);
    var leaves: usize = 0;
    for (0..32) |r| for (0..32) |g| for (0..32) |b| {
        const c = rawAt(work, r + 1, g + 1, b + 1);
        if (c.w == 0) continue;
        leaves += 1;
        for (0..5) |level| {
            const node = &work.nodes[nodeIndex(level, r, g, b)];
            node.w += c.w;
            node.r += c.r;
            node.g += c.g;
            node.b += c.b;
        }
    };
    // Each level's nodes merge their children, which are all leaves by
    // then, least populated first, until the leaves fit.
    var level: usize = 5;
    while (leaves > max and level > 0) {
        level -= 1;
        const first = level_start[level];
        const count = level_start[level + 1] - first;
        var n: usize = 0;
        for (0..count) |i| {
            if (work.nodes[first + i].w > 0) {
                work.order[n] = @intCast(i);
                n += 1;
            }
        }
        const Ctx = struct {
            const Self = @This();
            nodes: []const Node,
            fn less(ctx: Self, x: u16, y: u16) bool {
                return ctx.nodes[x].w < ctx.nodes[y].w;
            }
        };
        std.sort.pdq(u16, work.order[0..n], Ctx{ .nodes = work.nodes[first..][0..count] }, Ctx.less);
        for (work.order[0..n]) |i| {
            if (leaves <= max) break;
            const children = childLeaves(work, level, i);
            work.merged[first + i] = true;
            leaves -= children - 1;
        }
        // A level not done merging leaves its unmerged nodes' children as
        // they are; a finished one makes every node a leaf for the next.
        if (leaves > max) for (work.order[0..n]) |i| {
            work.merged[first + i] = true;
        };
    }
    out.len = 0;
    collect(work, 0, 0, 0, 0, 0, out);
}

/// The nonempty children of node `i` at `level`, which are leaves.
fn childLeaves(work: *const Work, level: usize, i: usize) usize {
    var n: usize = 0;
    const l: u4 = @intCast(level);
    const r = i >> (2 * l);
    const g = (i >> l) & ((@as(usize, 1) << l) - 1);
    const b = i & ((@as(usize, 1) << l) - 1);
    for (0..8) |k| {
        const cr = r * 2 + (k >> 2);
        const cg = g * 2 + ((k >> 1) & 1);
        const cb = b * 2 + (k & 1);
        const w = if (level == 4)
            rawAt(work, cr + 1, cg + 1, cb + 1).w
        else
            work.nodes[level_start[level + 1] + (cr << (2 * (l + 1))) + (cg << (l + 1)) + cb].w;
        if (w > 0) n += 1;
    }
    return n;
}

fn collect(work: *const Work, level: usize, r: usize, g: usize, b: usize, depth: usize, out: *Palette) void {
    _ = depth;
    var node: Node = undefined;
    if (level == 5) {
        const c = rawAt(work, r + 1, g + 1, b + 1);
        node = .{ .w = c.w, .r = c.r, .g = c.g, .b = c.b };
    } else {
        const l: u4 = @intCast(level);
        const i = level_start[level] + (r << (2 * l)) + (g << l) + b;
        node = work.nodes[i];
        if (node.w > 0 and !work.merged[i]) {
            for (0..8) |k| collect(work, level + 1, r * 2 + (k >> 2), g * 2 + ((k >> 1) & 1), b * 2 + (k & 1), 0, out);
            return;
        }
    }
    if (node.w == 0) return;
    const w: f64 = @floatFromInt(node.w);
    out.colors[out.len] = .{
        toByte(@as(f64, @floatFromInt(node.r)) / w),
        toByte(@as(f64, @floatFromInt(node.g)) / w),
        toByte(@as(f64, @floatFromInt(node.b)) / w),
    };
    out.len += 1;
}

// k-means.

fn kmeans(list: []const Cell, passes: u8, out: *Palette) void {
    const n = out.len;
    var pal: [256][3]f32 = undefined;
    for (out.colors[0..n], 0..) |c, i| pal[i] = .{ @floatFromInt(c[0]), @floatFromInt(c[1]), @floatFromInt(c[2]) };
    for (0..passes) |_| {
        var sum: [256][3]f64 = @splat(@splat(0));
        var weight: [256]f64 = @splat(0);
        for (list) |c| {
            var best: usize = 0;
            var best_d: f32 = std.math.inf(f32);
            for (pal[0..n], 0..) |p, i| {
                const dr = c.c[0] - p[0];
                const dg = c.c[1] - p[1];
                const db = c.c[2] - p[2];
                const d = dr * dr + dg * dg + db * db;
                if (d < best_d) {
                    best_d = d;
                    best = i;
                }
            }
            for (0..3) |d| sum[best][d] += @as(f64, c.c[d]) * c.w;
            weight[best] += c.w;
        }
        for (0..n) |i| {
            if (weight[i] == 0) continue;
            for (0..3) |d| pal[i][d] = @floatCast(sum[i][d] / weight[i]);
        }
    }
    for (0..n) |i| out.colors[i] = .{ toByte(pal[i][0]), toByte(pal[i][1]), toByte(pal[i][2]) };
}

// Mapping.

/// The palette entry nearest each 6-bit cell's center, found the first
/// time a pixel lands in the cell.
pub const Lookup = struct {
    index: [1 << 18]u8,
    known: [1 << 12]u64,
    /// The palette, each channel doubled, so a cell's center is an integer,
    /// padded to a whole vector with entries farther than any color.
    r: [256]i32,
    g: [256]i32,
    b: [256]i32,
    len: u16,

    const lanes = 16;
    const V = @Vector(lanes, i32);
    /// A padding entry's channels: farther from every cell center than any
    /// color, and small enough that a squared distance sum fits in i32.
    const far = 4096;

    pub fn init(l: *Lookup, palette: *const Palette) void {
        @memset(&l.known, 0);
        l.len = palette.len;
        for (palette.colors[0..palette.len], 0..) |c, i| {
            l.r[i] = @as(i32, c[0]) * 2;
            l.g[i] = @as(i32, c[1]) * 2;
            l.b[i] = @as(i32, c[2]) * 2;
        }
        const padded = std.mem.alignForward(usize, palette.len, lanes);
        for (palette.len..padded) |i| {
            l.r[i] = far;
            l.g[i] = far;
            l.b[i] = far;
        }
    }

    pub inline fn find(l: *Lookup, r: u8, g: u8, b: u8) u8 {
        const key = @as(u32, r >> 2) << 12 | @as(u32, g >> 2) << 6 | (b >> 2);
        const bit = @as(u64, 1) << @intCast(key & 63);
        if (l.known[key >> 6] & bit != 0) return l.index[key];
        const i = l.nearest(@as(i32, r & 0xfc) * 2 + 3, @as(i32, g & 0xfc) * 2 + 3, @as(i32, b & 0xfc) * 2 + 3);
        l.index[key] = i;
        l.known[key >> 6] |= bit;
        return i;
    }

    /// The palette entry nearest (r, g, b), the first of equals.
    fn nearest(l: *const Lookup, r: i32, g: i32, b: i32) u8 {
        const max: V = @splat(std.math.maxInt(i32));
        var best_d = max;
        var best_i: V = @splat(0);
        var idx = std.simd.iota(i32, lanes);
        var k: usize = 0;
        while (k < l.len) : (k += lanes) {
            const dr = @as(V, l.r[k..][0..lanes].*) - @as(V, @splat(r));
            const dg = @as(V, l.g[k..][0..lanes].*) - @as(V, @splat(g));
            const db = @as(V, l.b[k..][0..lanes].*) - @as(V, @splat(b));
            const d = dr * dr + dg * dg + db * db;
            // Strictly less, so each lane keeps its first of equals.
            const less = d < best_d;
            best_d = @select(i32, less, d, best_d);
            best_i = @select(i32, less, idx, best_i);
            idx += @splat(lanes);
        }
        const min = @reduce(.Min, best_d);
        const first = @select(i32, best_d == @as(V, @splat(min)), best_i, max);
        return @intCast(@reduce(.Min, first));
    }
};

/// The most error a pixel passes on, per channel.
const max_error = 16;
/// How close a pixel's color is to its entry, per channel, to pass on no
/// error.
const dead_zone = 1;

/// Floyd-Steinberg error diffusion over rows of RGBA, serpentine: even
/// rows left to right, odd rows right to left. A transparent pixel takes
/// no error and passes none on, and a pixel passes on at most `max_error`
/// per channel, which keeps error that builds up where the palette is
/// sparse from reaching a far color (stray dots of it). A pixel whose own
/// color is within `dead_zone` of its entry on every channel passes none
/// on either: an area of a color the palette nearly has stays one entry,
/// not a pattern of two, which LZW stores in fewer bytes. `errors` holds two
/// rows of `width + 2` pixels' errors, in sixteenths, a lane per channel.
pub const Ditherer = struct {
    cur: [][4]i16,
    next: [][4]i16,
    y: u32 = 0,

    const V = @Vector(4, i32);

    /// A pixel's errors fit in i16: at most 16 * 16 in sixteenths.
    fn narrow(v: V) [4]i16 {
        const n: @Vector(4, i16) = @intCast(v);
        return n;
    }

    pub fn init(errors: [][4]i16, width: u32) Ditherer {
        const n = @as(usize, width) + 2;
        @memset(errors[0 .. 2 * n], @splat(0));
        return .{ .cur = errors[0..n], .next = errors[n .. 2 * n] };
    }

    /// Maps one row: `rgba` is the row's pixels, `clear[x]` says whether
    /// pixel x is left transparent (index `transparent`), and `out` gets
    /// the indices.
    pub fn row(
        d: *Ditherer,
        l: *Lookup,
        palette: *const Palette,
        rgba: []const u8,
        clear: []const bool,
        transparent: u8,
        out: []u8,
    ) void {
        const width = out.len;
        const forward = d.y % 2 == 0;
        // The error the previous pixel passes ahead, 7/16 of its own.
        var carry: V = @splat(0);
        for (0..width) |k| {
            const x = if (forward) k else width - 1 - k;
            if (clear[x]) {
                out[x] = transparent;
                carry = @splat(0);
                continue;
            }
            const e = @as(V, d.cur[x + 1]) + carry;
            const px: V = .{ rgba[x * 4], rgba[x * 4 + 1], rgba[x * 4 + 2], 0 };
            const sum = (px * @as(V, @splat(16)) + e + @as(V, @splat(8))) >> @splat(4);
            const c = std.math.clamp(sum, @as(V, @splat(0)), @as(V, @splat(255)));
            const i = l.find(@intCast(c[0]), @intCast(c[1]), @intCast(c[2]));
            out[x] = i;
            const q = palette.colors[i];
            const p: V = .{ q[0], q[1], q[2], 0 };
            const err = if (@reduce(.Max, @abs(px - p)) <= dead_zone)
                @as(V, @splat(0))
            else
                std.math.clamp(c - p, @as(V, @splat(-max_error)), @as(V, @splat(max_error)));
            carry = err * @as(V, @splat(7));
            // Below behind, below, and below ahead; the row has a pixel of
            // padding at each end.
            const behind = if (forward) x else x + 2;
            const ahead = if (forward) x + 2 else x;
            d.next[behind] = narrow(@as(V, d.next[behind]) + err * @as(V, @splat(3)));
            d.next[x + 1] = narrow(@as(V, d.next[x + 1]) + err * @as(V, @splat(5)));
            d.next[ahead] = narrow(@as(V, d.next[ahead]) + err);
        }
        std.mem.swap([][4]i16, &d.cur, &d.next);
        @memset(d.next, @splat(0));
        d.y += 1;
    }
};

test "each method keeps a few colors exactly and fits many into the palette" {
    const gpa = testing.allocator;
    const work = try gpa.create(Work);
    defer gpa.destroy(work);
    const h: Histogram = .{ .work = work };
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    for ([_]Method{ .wu, .median_cut, .octree }) |method| {
        // Four colors in distinct cells come back exactly.
        h.clear();
        const four = [_][3]u8{ .{ 0, 0, 0 }, .{ 255, 0, 0 }, .{ 10, 200, 30 }, .{ 255, 255, 255 } };
        for (four, 0..) |c, i| for (0..i + 1) |_| h.add(c[0], c[1], c[2]);
        var p: Palette = .{};
        h.palette(method, 16, 0, &p);
        try testing.expectEqual(4, p.len);
        for (four) |c| {
            var found = false;
            for (p.colors[0..p.len]) |q| found = found or std.mem.eql(u8, &c, &q);
            try testing.expect(found);
        }
        // Noise fills the palette, every entry within the noise's range.
        h.clear();
        for (0..20000) |_| h.add(random.intRangeAtMost(u8, 20, 220), random.int(u8), random.intRangeAtMost(u8, 0, 99));
        h.palette(method, 256, 2, &p);
        try testing.expect(p.len > 200 and p.len <= 256);
        for (p.colors[0..p.len]) |q| try testing.expect(q[0] >= 20 and q[0] <= 220 and q[2] <= 99);
    }
}

test "Lookup finds the nearest entry to the cell's center" {
    const gpa = testing.allocator;
    const l = try gpa.create(Lookup);
    defer gpa.destroy(l);
    var p: Palette = .{ .len = 3 };
    p.colors[0] = .{ 0, 0, 0 };
    p.colors[1] = .{ 100, 100, 100 };
    p.colors[2] = .{ 255, 0, 0 };
    l.init(&p);
    try testing.expectEqual(0, l.find(10, 10, 10));
    try testing.expectEqual(1, l.find(60, 60, 60));
    try testing.expectEqual(2, l.find(200, 20, 0));
    // Cached: the same cell answers the same.
    try testing.expectEqual(2, l.find(201, 21, 1));

    // A palette ending inside a vector, with repeated entries: the first of
    // equals wins, as a scan in order finds it.
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    p.len = 37;
    for (p.colors[0..p.len]) |*c| random.bytes(c);
    p.colors[30] = p.colors[3];
    p.colors[36] = p.colors[17];
    l.init(&p);
    for (0..4000) |_| {
        var c: [3]u8 = undefined;
        random.bytes(&c);
        const center = [3]i32{ (c[0] & 0xfc) + 1, (c[1] & 0xfc) + 1, (c[2] & 0xfc) + 1 };
        var best: usize = 0;
        var best_d: i32 = std.math.maxInt(i32);
        for (p.colors[0..p.len], 0..) |e, i| {
            var d: i32 = 0;
            for (0..3) |ch| {
                const diff = 2 * @as(i32, e[ch]) - 2 * center[ch] - 1;
                d += diff * diff;
            }
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        try testing.expectEqual(best, l.find(c[0], c[1], c[2]));
    }
}

test "dithering never reaches a far color, however long the error builds up" {
    const gpa = testing.allocator;
    const l = try gpa.create(Lookup);
    defer gpa.destroy(l);
    // Flat gray 100 against black, gray 120, and white: unbounded error
    // diffusion keeps the mean by mixing in black dots; bounded, every
    // pixel stays gray.
    var p: Palette = .{ .len = 3 };
    p.colors[0] = .{ 0, 0, 0 };
    p.colors[1] = .{ 120, 120, 120 };
    p.colors[2] = .{ 255, 255, 255 };
    l.init(&p);
    const width = 64;
    var errors: [2 * (width + 2)][4]i16 = undefined;
    var d: Ditherer = .init(&errors, width);
    const rgba: [width * 4]u8 = @splat(100);
    const clear: [width]bool = @splat(false);
    var out: [width]u8 = undefined;
    for (0..64) |_| {
        d.row(l, &p, &rgba, &clear, 0, &out);
        for (out) |i| try testing.expectEqual(1, i);
    }
}

test "an area within a unit of a palette color dithers to that color alone" {
    const gpa = testing.allocator;
    const l = try gpa.create(Lookup);
    defer gpa.destroy(l);
    // Flat gray 101 between grays 100 and 102: diffusing the unit of error
    // each pixel leaves would mix the two; within the dead zone, it is one.
    var p: Palette = .{ .len = 3 };
    p.colors[0] = .{ 100, 100, 100 };
    p.colors[1] = .{ 102, 102, 102 };
    p.colors[2] = .{ 255, 255, 255 };
    l.init(&p);
    const width = 64;
    var errors: [2 * (width + 2)][4]i16 = undefined;
    var d: Ditherer = .init(&errors, width);
    const rgba: [width * 4]u8 = @splat(101);
    const clear: [width]bool = @splat(false);
    var out: [width]u8 = undefined;
    d.row(l, &p, &rgba, &clear, 0, &out);
    const first = out[0];
    try testing.expect(first < 2);
    for (0..16) |_| {
        d.row(l, &p, &rgba, &clear, 0, &out);
        for (out) |i| try testing.expectEqual(first, i);
    }
}
