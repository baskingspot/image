//! The WebP lossless encoder's backward references and color cache (RFC
//! 9649, sections 3.6.2.2 and 3.6.2.3): a hash-chain match finder over
//! pairs of pixels, the distance codes that name nearby pixels in two
//! dimensions, and turning literals the cache holds into cache codes.
//!
//! The parse is a list of tokens, one `u32` each: 0 for a literal (its
//! pixel is the image's), `cache_flag | index` for a color cache code, and
//! `copy_flag | length` followed by the distance code for a backward
//! reference. A reference covers at least two pixels, so the tokens never
//! outnumber the pixels.

const std = @import("std");
const vfill = @import("../fill.zig").fill;
const builtin = @import("builtin");
const testing = std.testing;
const codes = @import("encode_codes.zig");

pub const copy_flag: u32 = 0x8000_0000;
pub const cache_flag: u32 = 0x4000_0000;
pub const max_length = 4096;
/// The longest distance used: codes 1 to 120 are the neighborhood, and
/// keeping a distance's code below 2^20 lets a length and a code share a
/// word in the optimal parse.
pub const max_distance = (1 << 20) - 121;
/// The match finder's chain is a ring this long at most, longer than any
/// distance, so the positions in reach never share a slot.
pub const max_ring = 1 << 20;

/// The neighborhood a distance code of 1 to 120 names (section 4.2 of the
/// lossless specification): (columns left, rows up).
const plane = [120][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },  .{ 1, 2 },  .{ -1, 2 },
    .{ 2, 1 },  .{ -2, 1 }, .{ 2, 2 },  .{ -2, 2 }, .{ 0, 3 },  .{ 3, 0 },  .{ 1, 3 },  .{ -1, 3 },
    .{ 3, 1 },  .{ -3, 1 }, .{ 2, 3 },  .{ -2, 3 }, .{ 3, 2 },  .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },
    .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 }, .{ 3, 3 },  .{ -3, 3 }, .{ 2, 4 },  .{ -2, 4 },
    .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },  .{ 3, 4 },  .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },
    .{ 1, 5 },  .{ -1, 5 }, .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 },
    .{ 4, 4 },  .{ -4, 4 }, .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 }, .{ 0, 6 },  .{ 6, 0 },
    .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 }, .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },  .{ -6, 2 },
    .{ 4, 5 },  .{ -4, 5 }, .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 }, .{ 6, 3 },  .{ -6, 3 },
    .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },  .{ -5, 5 }, .{ 7, 1 },  .{ -7, 1 },
    .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 }, .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 },
    .{ 3, 7 },  .{ -3, 7 }, .{ 7, 3 },  .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 },
    .{ 8, 0 },  .{ 4, 7 },  .{ -4, 7 }, .{ 7, 4 },  .{ -7, 4 }, .{ 8, 1 },  .{ 8, 2 },  .{ 6, 6 },
    .{ -6, 6 }, .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 }, .{ 7, 5 },  .{ -7, 5 }, .{ 8, 4 },  .{ 6, 7 },
    .{ -6, 7 }, .{ 7, 6 },  .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },  .{ 8, 7 },
};

/// Distance codes for an image `width` pixels wide: the smallest code that
/// names each distance.
pub const Distances = struct {
    width: u32,
    /// The code for distance `xi + yi * width`, by `yi` and `xi + 8`, or 0
    /// when none of the 120 names it.
    near: [8][17]u8,
    /// The smallest code meaning distance 1: codes whose neighbor lies at
    /// or past the current pixel mean 1 too.
    one: u8,
    /// The codes for the pixel above and the one to the left.
    up: u32 = 0,
    left: u32 = 0,

    pub fn init(width: u32) Distances {
        var d: Distances = .{ .width = width, .near = @splat(@splat(0)), .one = 2 };
        var c: usize = 120;
        while (c > 0) : (c -= 1) {
            const xy = plane[c - 1];
            d.near[@intCast(xy[1])][@intCast(xy[0] + 8)] = @intCast(c);
            if (@as(i64, xy[0]) + @as(i64, xy[1]) * width <= 1) d.one = @intCast(c);
        }
        d.up = d.code(width);
        d.left = d.code(1);
        return d;
    }

    /// The distance code for `dist`, at least 1.
    pub fn code(d: *const Distances, dist: u32) u32 {
        var best: u32 = dist + 120;
        // The neighborhood reaches 7 rows up and 8 columns over.
        if (dist > 7 * @as(u64, d.width) + 8) return best;
        // Each row up the neighborhood could name it, with xi in -8..8;
        // codes whose distance is below 1 mean 1.
        const w: i64 = d.width;
        const yi_low: i64 = @divFloor(@as(i64, dist) - 8, w);
        var yi = @max(0, yi_low);
        while (yi <= 7) : (yi += 1) {
            const xi = @as(i64, dist) - yi * w;
            if (xi < -8) break;
            if (xi <= 8) {
                const c = d.near[@intCast(yi)][@intCast(xi + 8)];
                if (c != 0 and c < best) best = c;
            }
        }
        if (dist == 1) best = @min(best, d.one);
        return best;
    }
};

/// How the match finder searches.
pub const Params = struct {
    /// Hash chain candidates tried per position, besides the pixel to the
    /// left and the one above.
    chain: u32,
    /// A match this long ends the search; the next position takes it a
    /// pixel shorter without searching, and the optimal parse takes it
    /// whole, without weighing the positions inside it.
    nice: u32 = 256,
};

/// Estimated bits, for choosing between literals and references.
pub const Model = struct {
    /// What a literal pixel costs, on average.
    literal: u32,

    pub const default: Model = .{ .literal = 12 };

    inline fn copyCost(m: Model, len: u32, dist_code: u32) i64 {
        _ = m;
        const l = codes.prefix(len);
        const d = codes.prefix(dist_code);
        return 5 + @as(i64, l.bits) + 5 + @as(i64, d.bits) + @as(i64, d.symbol >> 2);
    }

    inline fn gain(m: Model, len: u32, dist_code: u32) i64 {
        return @as(i64, len) * m.literal - m.copyCost(len, dist_code);
    }
};

/// The hash chain's memory.
pub const Chain = struct {
    head: []u32,
    ring: []u32,
    bits: u5,

    /// Head table bits for `pixels` pixels.
    pub fn headBits(pixels: usize) u5 {
        var b: u5 = 8;
        while (b < 18 and (@as(usize, 1) << b) < pixels) b += 1;
        return b;
    }

    pub fn ringLen(pixels: usize) usize {
        return @min(max_ring, std.math.ceilPowerOfTwo(usize, @max(pixels, 2)) catch max_ring);
    }

    inline fn hash(c: *const Chain, a: u32, b: u32) u32 {
        const v = (@as(u64, b) << 32 | a) *% 0x9e37_79b9_7f4a_7c15;
        return @intCast(v >> @intCast(64 - @as(u32, c.bits)));
    }
};

/// An empty chain entry.
pub const none = std.math.maxInt(u32);

/// The number of pixels from `a` and `b` that match, at most `max`.
inline fn matchLen(px: []const u32, a: usize, b: usize, max: usize) usize {
    // Most candidates differ in their first two pixels.
    if (max >= 2 and (px[a] != px[b] or px[a + 1] != px[b + 1])) return @intFromBool(px[a] == px[b]);
    var k: usize = 0;
    const V = @Vector(8, u32);
    while (k + 8 <= max) {
        const x: V = px[a + k ..][0..8].*;
        const y: V = px[b + k ..][0..8].*;
        const ne = x != y;
        if (@reduce(.Or, ne)) {
            // A bool vector's bits run from lane 0 up only on little-endian
            // targets; elsewhere, ask for the first lane.
            if (builtin.cpu.arch.endian() == .little) return k + @ctz(@as(u8, @bitCast(ne)));
            return k + std.simd.firstTrue(ne).?;
        }
        k += 8;
    }
    while (k < max and px[a + k] == px[b + k]) k += 1;
    return k;
}

/// What is known of the matches at one distance from a long match before:
/// the pixels before `end` match, and when `exact`, the one at `end` does
/// not.
const Known = struct {
    end: usize = 0,
    exact: bool = false,

    /// `matchLen(px, i, i - d, max)`, from what an earlier pixel's match at
    /// distance `d` showed: in a long match, each pixel's is the one
    /// before's less one.
    inline fn len(k: *Known, px: []const u32, i: usize, d: usize, max: usize) usize {
        if (k.end > i) {
            const known = k.end - i;
            if (known >= max) return max;
            if (k.exact) return known;
            const l = known + matchLen(px, i + known, i - d + known, max - known);
            k.* = .{ .end = i + l, .exact = l < max };
            return l;
        }
        const l = matchLen(px, i, i - d, max);
        if (l >= 2) k.* = .{ .end = i + l, .exact = l < max };
        return l;
    }
};

/// Finds each pixel's longest reference into `matches`, as its length
/// less one above bit 20 and its distance code below, or 0 for none.
/// Distance codes stay below 2^20 (`max_distance`). The chain's head
/// starts empty, every entry `none`, and is left empty.
pub fn findMatches(px: []const u32, width: u32, params: Params, chain: Chain, matches: []u32) void {
    const n = px.len;
    const dists = Distances.init(width);
    const mask = chain.ring.len - 1;
    var prev: u32 = 0;
    // The first pixel of the run of equal pixels that pixel `i` is in.
    var run_start: usize = 0;
    var left: Known = .{};
    var up: Known = .{};
    for (0..n) |i| {
        if (i + 1 >= n) {
            matches[i] = 0;
            break;
        }
        // Inside a run that goes on past `i`, the chain starts with the
        // run's pixels before `i`, newest first: each matches only to the
        // run's end, as the left pixel does, so the search passes them by.
        var skip: usize = 0;
        if (params.chain != 0) {
            if (i > 0 and px[i] != px[i - 1]) run_start = i;
            if (px[i + 1] == px[i]) skip = i - run_start;
        }
        const m = if ((prev >> 20) >= params.nice) prev - (1 << 20) else m: {
            // The left and upper pixels first, keeping them on equal
            // lengths.
            const max = @min(max_length, n - i);
            var longest: usize = 1;
            var code: u32 = 0;
            if (i >= 1) {
                const len = left.len(px, i, 1, max);
                if (len > longest) {
                    longest = len;
                    code = dists.left;
                }
            }
            if (i >= width and width != 1) {
                const len = up.len(px, i, width, max);
                if (len > longest) {
                    longest = len;
                    code = dists.up;
                }
            }
            break :m longestMatch(px, i, &dists, params, chain, skip, max, longest, code);
        };
        matches[i] = m;
        prev = m;
        if (params.chain != 0) insert(chain, px, i, mask);
    }
    // Emptied by the entries filled, when they are few: a transform
    // image's search is short beside clearing a head sized for the main
    // image.
    if (params.chain == 0) return;
    if (n * 32 < chain.head.len) {
        for (0..n - 1) |i| chain.head[chain.hash(px[i], px[i + 1])] = none;
    } else vfill(u32, chain.head, none);
}

inline fn insert(chain: Chain, px: []const u32, i: usize, mask: usize) void {
    const h = chain.hash(px[i], px[i + 1]);
    chain.ring[i & mask] = chain.head[h];
    chain.head[h] = @intCast(i);
}

inline fn pack(len: usize, code: u32) u32 {
    return @as(u32, @intCast(len - 1)) << 20 | code;
}

/// The longest reference from pixel `i`, which has a pixel after it, at
/// most `max` long: the hash chain's, when longer than `longest`, the
/// left or upper pixel's, whose code is `code`. The chain's first `skip`
/// entries, pixels `i - 1` down to `i - skip`, cannot be longer.
fn longestMatch(
    px: []const u32,
    i: usize,
    dists: *const Distances,
    params: Params,
    chain: Chain,
    skip: usize,
    max: usize,
    longest_in: usize,
    code_in: u32,
) u32 {
    const w = dists.width;
    var longest = longest_in;
    var code = code_in;
    if (params.chain > skip and longest < @min(max, params.nice)) {
        const mask = chain.ring.len - 1;
        var j = if (skip != 0) chain.ring[(i - skip) & mask] else chain.head[chain.hash(px[i], px[i + 1])];
        var left = params.chain - skip;
        while (j != none and left > 0) : (left -= 1) {
            const d = i - j;
            if (d > max_distance) break;
            if (px[j + longest] == px[i + longest] and d != 1 and d != w) {
                const len = matchLen(px, i, j, max);
                if (len > longest) {
                    longest = len;
                    code = dists.code(@intCast(d));
                    if (len >= @min(max, params.nice)) break;
                }
            }
            j = chain.ring[j & mask];
        }
    }
    return if (longest >= 2) pack(longest, code) else 0;
}

/// Parses `px` greedily from its `matches` into `tokens`, returning how
/// many there are: a reference wherever `model` says it saves bits.
pub fn parse(px: []const u32, matches: []const u32, model: Model, tokens: []u32) usize {
    const n = px.len;
    var t: usize = 0;
    var i: usize = 0;
    while (i < n) {
        const m = matches[i];
        if (m != 0) {
            const len = (m >> 20) + 1;
            if (model.gain(len, m & 0xfffff) > 0) {
                tokens[t] = copy_flag | len;
                tokens[t + 1] = m & 0xfffff;
                t += 2;
                i += len;
                continue;
            }
        }
        tokens[t] = 0;
        t += 1;
        i += 1;
    }
    return t;
}

/// Bits each symbol costs, for the optimal parse.
pub const Costs = struct {
    green: [codes.max_green]f32,
    red: [256]f32,
    blue: [256]f32,
    alpha: [256]f32,
    dist: [40]f32,
    /// Each length's prefix symbol and extra bits.
    length: [max_length + 1]f32,

    /// Costs from a histogram of a parse: a symbol's information content,
    /// and a little more than the rarest for one that did not occur.
    pub fn init(c: *Costs, h: *const codes.Histogram, green_size: usize) void {
        fill(c.green[0..green_size], h.green[0..green_size]);
        fill(&c.red, &h.red);
        fill(&c.blue, &h.blue);
        fill(&c.alpha, &h.alpha);
        fill(&c.dist, &h.dist);
        for (1..max_length + 1) |l| {
            const p = codes.prefix(@intCast(l));
            c.length[l] = c.green[256 + p.symbol] + @as(f32, @floatFromInt(p.bits));
        }
    }

    fn fill(out: []f32, counts: []const u32) void {
        var total: u64 = 0;
        for (counts) |n| total += n;
        const lt = std.math.log2(@as(f32, @floatFromInt(total + 1)));
        for (out, counts) |*o, n| o.* = if (n == 0) lt + 2 else lt - std.math.log2(@as(f32, @floatFromInt(n)));
    }

    inline fn literal(c: *const Costs, v: u32) f32 {
        return c.green[(v >> 8) & 0xff] + c.red[(v >> 16) & 0xff] + c.blue[v & 0xff] + c.alpha[v >> 24];
    }

    inline fn distance(c: *const Costs, code: u32) f32 {
        const p = codes.prefix(code);
        return c.dist[p.symbol] + @as(f32, @floatFromInt(p.bits));
    }
};

/// Parses `px` into `tokens` along the cheapest path by `costs`: each
/// pixel as a literal, a color cache code (`cache_bits`, with `cache` of
/// 2^cache_bits entries) or the start of a reference. The cache holds the
/// same colors at each pixel whatever the parse, so its hits are known
/// as the pixels are walked. `cost` holds a float per pixel and one more.
/// Returns the tokens' count; cache codes are left to `applyCache`.
pub fn parseOptimal(
    px: []const u32,
    width: u32,
    matches: []const u32,
    nice: u32,
    near_codes: u32,
    costs: *const Costs,
    cache_bits: u5,
    cache: []u32,
    tokens: []u32,
    cost: []f32,
) usize {
    const n = px.len;
    const dists = Distances.init(width);
    const c = cache[0 .. @as(usize, 1) << cache_bits];
    @memset(c, 0);
    // `from` holds, at each pixel, the token that ends there, packed as in
    // `matches`; 0 for a literal.
    const from = tokens[0 .. n + 1];
    @memset(cost[1 .. n + 1], std.math.inf(f32));
    cost[0] = 0;
    var skip_to: usize = 0;
    // The first `near_codes` neighborhood codes, each distance once.
    var near: [120]struct { dist: u32, code: u32 } = undefined;
    var near_n: usize = 0;
    var known: [120]Known = @splat(.{});
    for (plane[0..@min(near_codes, 120)], 1..) |xy, code| {
        const raw = @as(i64, xy[0]) + @as(i64, xy[1]) * width;
        const d: u32 = if (raw < 1) 1 else @intCast(raw);
        if (dists.code(d) != code) continue;
        near[near_n] = .{ .dist = d, .code = @intCast(code) };
        near_n += 1;
    }
    for (0..n) |i| {
        const v = px[i];
        var lit = costs.literal(v);
        if (cache_bits != 0) {
            const k = cacheIndex(v, cache_bits);
            if (c[k] == v) lit = @min(lit, costs.green[codes.green_base + k]) else c[k] = v;
        }
        if (i < skip_to) continue;
        const here = cost[i];
        if (here + lit < cost[i + 1]) {
            cost[i + 1] = here + lit;
            from[i + 1] = 0;
        }
        const m = matches[i];
        if (m == 0) continue;
        const len = (m >> 20) + 1;
        if (len >= nice) {
            relax(cost, from, i, len, here + costs.distance(m & 0xfffff) + costs.length[len], m & 0xfffff);
            skip_to = i + len;
            continue;
        }
        relaxAll(cost, from, i, len, here, m & 0xfffff, costs);
        // The nearest pixels' matches too, when not the longest: their
        // codes are the cheapest.
        const max = @min(len, n - i);
        const longest_dist = costs.distance(m & 0xfffff);
        for (near[0..near_n], known[0..near_n]) |nd, *k| {
            if (nd.dist > i or nd.code == m & 0xfffff) continue;
            const l = k.len(px, i, nd.dist, max);
            if (l < 2) continue;
            // Not when it never beats the longest match: its code costs as
            // much or more, and the longest reaches every length it would
            // weigh, all to 32 and past it each length prefix's longest.
            if (costs.distance(nd.code) >= longest_dist and (l <= 32 or l == len or isTop(@intCast(l)))) continue;
            relaxAll(cost, from, i, @intCast(l), here, nd.code, costs);
        }
    }
    // Back from the end, each token moved to where it starts; then
    // forward, the tokens in order, which never overtake the walk.
    var j = n;
    var e = from[n];
    while (j > 0) {
        const len: usize = (e >> 20) + 1;
        const start = j - len;
        const next = from[start];
        from[start] = e;
        j = start;
        e = next;
    }
    var t: usize = 0;
    var i: usize = 0;
    while (i < n) {
        const tok = from[i];
        if (tok == 0) {
            tokens[t] = 0;
            t += 1;
            i += 1;
        } else {
            const len = (tok >> 20) + 1;
            tokens[t] = copy_flag | len;
            tokens[t + 1] = tok & 0xfffff;
            t += 2;
            i += len;
        }
    }
    return t;
}

/// Every length of a match up to 32; past it, each length prefix's
/// longest and the match's own, as the lengths a prefix covers cost the
/// same.
inline fn relaxAll(cost: []f32, from: []u32, i: usize, len: u32, here: f32, code: u32, costs: *const Costs) void {
    const dc = here + costs.distance(code);
    const short = @min(len, 32);
    var l: u32 = 2;
    // Eight lengths at a time: each writes its own entry, so this is the
    // loop below, reordered. `l + 7 <= short <= len` keeps the entries
    // within `cost[0..i + len + 1]`.
    const F = @Vector(8, f32);
    const U = @Vector(8, u32);
    while (l + 7 <= short) : (l += 8) {
        const at = i + l;
        const old: F = cost[at..][0..8].*;
        const total = @as(F, @splat(dc)) + @as(F, costs.length[l..][0..8].*);
        const better = total < old;
        cost[at..][0..8].* = @select(f32, better, total, old);
        const tok = (@as(U, @splat(l - 1)) + std.simd.iota(u32, 8)) << @splat(20) | @as(U, @splat(code));
        from[at..][0..8].* = @select(u32, better, tok, @as(U, from[at..][0..8].*));
    }
    while (l <= short) : (l += 1) relax(cost, from, i, l, dc + costs.length[l], code);
    while (l <= len) {
        const p = codes.prefix(l);
        const top = @min(len, l + ((@as(u32, 1) << @intCast(p.bits)) - 1 - p.extra));
        relax(cost, from, i, top, dc + costs.length[top], code);
        l = top + 1;
    }
}

/// Whether `len` is the longest of the lengths its prefix code covers.
inline fn isTop(len: u32) bool {
    const p = codes.prefix(len);
    return p.extra == (@as(u32, 1) << @intCast(p.bits)) - 1;
}

inline fn relax(cost: []f32, from: []u32, i: usize, len: u32, total: f32, code: u32) void {
    if (total < cost[i + len]) {
        cost[i + len] = total;
        from[i + len] = (len - 1) << 20 | code;
    }
}

/// The color cache's index for `px` with `bits` bits.
pub inline fn cacheIndex(px: u32, bits: u5) u32 {
    return (0x1e35a7bd *% px) >> @intCast(32 - @as(u32, bits));
}

/// Turns the literals that a color cache of `bits` bits holds into cache
/// codes, in place. `cache` has at least 2^bits entries.
pub fn applyCache(px: []const u32, tokens: []u32, bits: u5, cache: []u32) void {
    if (bits == 0) return;
    const c = cache[0 .. @as(usize, 1) << bits];
    @memset(c, 0);
    var p: usize = 0;
    var t: usize = 0;
    while (t < tokens.len) {
        const tok = tokens[t];
        if (tok & copy_flag != 0) {
            const len = tok & 0xffff;
            for (px[p..][0..len]) |v| c[cacheIndex(v, bits)] = v;
            p += len;
            t += 2;
            continue;
        }
        const v = px[p];
        const k = cacheIndex(v, bits);
        if (c[k] == v) tokens[t] = cache_flag | k else c[k] = v;
        p += 1;
        t += 1;
    }
}

/// Adds the parse's symbols to `h`, a group's histogram.
pub fn histogram(px: []const u32, tokens: []const u32, h: *codes.Histogram) void {
    var p: usize = 0;
    var t: usize = 0;
    while (t < tokens.len) {
        const tok = tokens[t];
        if (tok & copy_flag != 0) {
            const len = tok & 0xffff;
            h.copy(len, tokens[t + 1]);
            p += len;
            t += 2;
        } else if (tok & cache_flag != 0) {
            h.green[codes.green_base + (tok & 0xffff)] += 1;
            p += 1;
            t += 1;
        } else {
            h.literal(px[p]);
            p += 1;
            t += 1;
        }
    }
}

test Distances {
    // Every code from 1 to 120 maps back to its own distance, and a
    // distance far away needs no neighborhood code.
    for ([_]u32{ 1, 2, 3, 7, 8, 9, 16, 17, 100, 16384 }) |w| {
        const d = Distances.init(w);
        for (plane, 1..) |xy, c| {
            const raw = @as(i64, xy[0]) + @as(i64, xy[1]) * w;
            const dist: u32 = if (raw < 1) 1 else @intCast(raw);
            const got = d.code(dist);
            try testing.expect(got <= c);
            const back_xy = plane[got - 1];
            const back_raw = @as(i64, back_xy[0]) + @as(i64, back_xy[1]) * w;
            try testing.expectEqual(dist, if (back_raw < 1) 1 else @as(u32, @intCast(back_raw)));
        }
    }
    const d = Distances.init(1000);
    try testing.expectEqual(1, d.code(1000));
    try testing.expectEqual(2, d.code(1));
    try testing.expectEqual(50_000 + 120, d.code(50_000));
}

test parse {
    // A row repeated below itself becomes one reference to the pixel
    // above; a run, a reference to the left.
    var px: [64]u32 = undefined;
    for (px[0..16], 0..) |*p, k| p.* = @intCast(k * 77);
    @memcpy(px[16..32], px[0..16]);
    @memset(px[32..], 5);
    var head: [256]u32 = @splat(none);
    var ring: [64]u32 = undefined;
    var tokens: [64]u32 = undefined;
    var matches: [64]u32 = undefined;
    const chain: Chain = .{ .head = &head, .ring = &ring, .bits = 8 };
    findMatches(&px, 16, .{ .chain = 8 }, chain, &matches);
    const n = parse(&px, &matches, .default, &tokens);
    try testing.expectEqual(16 + 2 + 1 + 2, n);
    try testing.expectEqual(copy_flag | 16, tokens[16]);
    try testing.expectEqual(1, tokens[17]);
    try testing.expectEqual(0, tokens[18]);
    try testing.expectEqual(copy_flag | 31, tokens[19]);
    try testing.expectEqual(2, tokens[20]);
}
