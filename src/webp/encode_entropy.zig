//! The WebP lossless encoder's entropy image (RFC 9649, section
//! 3.7.2.2): which group of prefix codes each tile of the main image uses.
//! Tiles are clustered by their symbols: each starts in a group by how
//! many bits a pixel of it costs on its own, then each round moves every
//! tile to the group whose code would code it in the fewest bits, and
//! groups that cost more to describe than they save are folded into the
//! others.

const std = @import("std");
const testing = std.testing;
const codes = @import("encode_codes.zig");
const lz77 = @import("encode_lz77.zig");
const transform = @import("encode_transform.zig");

/// Symbols across a group's five codes, in `codes.offsets` order.
const symbols = codes.max_green + 768 + 40;

const mask_words = (symbols + 63) / 64;

/// A tile's symbol and how often it occurs there.
const Entry = packed struct(u32) { symbol: u16, count: u16 };

pub const Input = struct {
    px: []const u32,
    width: u32,
    tokens: []const u32,
    /// Tile size bits, at most 7.
    bits: u5,
    green_size: usize,
    max_groups: usize,
    rounds: u8,
    /// Each tile's group, written here.
    tile_group: []u32,
    /// Each group's histogram, written here; at least `max_groups`.
    histos: []codes.Histogram,
    mem: []u8,
    /// Which grouping to start from.
    start: u1 = 0,
};

/// The most entries the tiles' symbol lists take.
fn poolLen(tiles: u64, pixels: u64) u64 {
    return @min(tiles * symbols, 4 * pixels + tiles);
}

/// Bytes `cluster` needs for `tiles` tiles, `cols` to a row, of an image
/// of `pixels` pixels, into at most `groups` groups.
pub fn workLen(tiles: u64, cols: u64, pixels: u64, groups: u64) u64 {
    if (tiles == 0) return 0;
    const k = startGroups(tiles, pixels, groups);
    return poolLen(tiles, pixels) * 4 + (tiles + 1) * 4 + tiles * 4 + tiles * 16 +
        groups * symbols * 4 + k * k * 4 + cols * symbols * 2 + tiles * 4 + groups * 13 +
        (groups + cols) * mask_words * 8 + 72;
}

/// How many groups the clustering starts with, the most it ever has.
fn startGroups(tiles: u64, pixels: u64, max_groups: u64) u64 {
    return @max(1, @min(max_groups, tiles, pixels / 1024));
}

const Mem = struct {
    pool: []Entry,
    start: []u32,
    cost: []f32,
    feature: []f32,
    group_cost: []f32,
    /// Each pair of groups' cost together, by `histCost`, while the merge
    /// runs.
    pair: []f32,
    dense: []u16,
    order: []u32,
    cost_of: []f32,
    best_delta: []f32,
    best: []u32,
    alive: []bool,
    /// Each group's used symbols as bits.
    mask: [][mask_words]u64,
    /// Each tile of a row's used symbols as bits, while counting.
    seen: [][mask_words]u64,
    histos: []codes.Histogram,

    fn init(mem: []u8, tiles: usize, cols: usize, pixels: usize, groups: usize) Mem {
        var at: usize = std.mem.alignForward(usize, @intFromPtr(mem.ptr), 4) - @intFromPtr(mem.ptr);
        const pool_len: usize = @intCast(poolLen(tiles, pixels));
        const pool = take(Entry, mem, &at, pool_len);
        const start = take(u32, mem, &at, tiles + 1);
        const cost = take(f32, mem, &at, tiles);
        const feature = take(f32, mem, &at, 4 * tiles);
        const gc = take(f32, mem, &at, groups * symbols);
        const k: usize = @intCast(startGroups(tiles, pixels, groups));
        const pair = take(f32, mem, &at, k * k);
        const dense = take(u16, mem, &at, cols * symbols);
        at = std.mem.alignForward(usize, at, 4);
        const order = take(u32, mem, &at, tiles);
        const cost_of = take(f32, mem, &at, groups);
        const best_delta = take(f32, mem, &at, groups);
        const best = take(u32, mem, &at, groups);
        const alive = take(bool, mem, &at, groups);
        at = std.mem.alignForward(usize, at, 8);
        const mask = take([mask_words]u64, mem, &at, groups);
        const seen = take([mask_words]u64, mem, &at, cols);
        return .{
            .mask = mask,
            .seen = seen,
            .histos = undefined,
            .pool = pool,
            .start = start,
            .cost = cost,
            .feature = feature,
            .group_cost = gc,
            .pair = pair,
            .dense = dense,
            .order = order,
            .cost_of = cost_of,
            .best_delta = best_delta,
            .best = best,
            .alive = alive,
        };
    }

    fn take(comptime T: type, mem: []u8, at: *usize, n: usize) []T {
        const s = @as([*]T, @ptrCast(@alignCast(mem[at.*..].ptr)))[0..n];
        at.* += n * @sizeOf(T);
        return s;
    }
};

/// The symbols of one token, as indices into a group's symbols.
fn tokenSymbols(px: []const u32, tokens: []const u32, t: usize, p: usize, out: *[4]u16) usize {
    const tok = tokens[t];
    if (tok & lz77.copy_flag != 0) {
        out[0] = @intCast(256 + codes.prefix(tok & 0xffff).symbol);
        out[1] = @intCast(codes.offsets[4] + codes.prefix(tokens[t + 1]).symbol);
        return 2;
    }
    if (tok & lz77.cache_flag != 0) {
        out[0] = @intCast(codes.green_base + (tok & 0xffff));
        return 1;
    }
    const v = px[p];
    out[0] = @intCast((v >> 8) & 0xff);
    out[1] = @intCast(codes.offsets[1] + ((v >> 16) & 0xff));
    out[2] = @intCast(codes.offsets[2] + (v & 0xff));
    out[3] = @intCast(codes.offsets[3] + (v >> 24));
    return 4;
}

/// Clusters the tiles into groups, returning how many; each tile's group
/// goes into `in.tile_group` and each group's histogram into `in.histos`.
pub fn cluster(in: Input) usize {
    const w = in.width;
    const h: u32 = @intCast(in.px.len / w);
    const tw = transform.divRoundUp(w, in.bits);
    const th = transform.divRoundUp(h, in.bits);
    const tiles = @as(usize, tw) * th;
    std.debug.assert(in.bits <= 7);
    std.debug.assert(in.max_groups <= 1024);
    var m = Mem.init(in.mem, tiles, tw, in.px.len, in.max_groups);
    m.histos = in.histos;

    // Each tile's symbols as a list of counts, and its bits per pixel on
    // its own as its feature. A token belongs to the tile of its first
    // pixel. Each row of tiles is counted in one walk over its tokens,
    // with a dense count array per tile of the row.
    @memset(m.dense, 0);
    @memset(m.seen, @splat(0));
    var at: usize = 0;
    var t: usize = 0;
    var p: usize = 0;
    // Pixel `p`'s column.
    var x: usize = 0;
    for (0..th) |ty| {
        const y1 = @min(h, (ty + 1) << in.bits);
        while (t < in.tokens.len and p < y1 * @as(usize, w)) {
            const tx = x >> in.bits;
            var syms: [4]u16 = undefined;
            const k = tokenSymbols(in.px, in.tokens, t, p, &syms);
            const d = m.dense[tx * symbols ..][0..symbols];
            for (syms[0..k]) |sym| {
                d[sym] += 1;
                m.seen[tx][sym / 64] |= @as(u64, 1) << @intCast(sym % 64);
            }
            const copy = in.tokens[t] & lz77.copy_flag != 0;
            const len = if (copy) in.tokens[t] & 0xffff else 1;
            p += len;
            x += len;
            if (x >= w) x %= w;
            t += if (copy) 2 else 1;
        }
        for (0..tw) |tx| {
            const ti = ty * tw + tx;
            m.start[ti] = @intCast(at);
            const d = m.dense[tx * symbols ..][0..symbols];
            var total: u32 = 0;
            // The used symbols, in order, by their bits.
            for (&m.seen[tx], 0..) |*word, wi| {
                while (word.* != 0) : (word.* &= word.* - 1) {
                    const sym = wi * 64 + @ctz(word.*);
                    m.pool[at] = .{ .symbol = @intCast(sym), .count = d[sym] };
                    at += 1;
                    total += d[sym];
                    d[sym] = 0;
                }
            }
            // Green's (with lengths and cache codes), red's, and blue's
            // bits a pixel on their own.
            var sum: [3]u32 = @splat(0);
            var clogc: [3]f32 = @splat(0);
            for (m.pool[m.start[ti]..at]) |e| {
                const k: usize = if (e.symbol < codes.offsets[1])
                    0
                else if (e.symbol < codes.offsets[2])
                    1
                else if (e.symbol < codes.offsets[3])
                    2
                else
                    continue;
                sum[k] += e.count;
                clogc[k] += xlog2(e.count);
            }
            const area: f32 = @floatFromInt(@as(u32, 1) << (2 * in.bits));
            for (0..3) |k| m.feature[4 * ti + k] = (xlog2(sum[k]) - clogc[k]) / area;
            // And all of its symbols' together.
            var all: f32 = 0;
            for (m.pool[m.start[ti]..at]) |e| all += xlog2(e.count);
            m.feature[4 * ti + 3] = (xlog2(total) - all) / area;
        }
    }
    m.start[tiles] = @intCast(at);

    // Start 0: the tiles in order of their bits a pixel, cut into runs of
    // equal length. Start 1: the tiles binned by their three features,
    // each cut into even ranges.
    const k0: usize = @intCast(startGroups(tiles, in.px.len, in.max_groups));
    if (in.start == 0) {
        for (m.order[0..tiles], 0..) |*o, ti| o.* = @intCast(ti);
        std.sort.pdq(u32, m.order[0..tiles], m.feature, struct {
            fn less(f: []f32, a: u32, b: u32) bool {
                return f[4 * a + 3] < f[4 * b + 3];
            }
        }.less);
        for (m.order[0..tiles], 0..) |ti, r| in.tile_group[ti] = @intCast(r * k0 / tiles);
    } else binByFeatures(in, m, tiles, k0);
    return refine(in, m, tiles, compact(in, tiles));
}

fn binByFeatures(in: Input, m: Mem, tiles: usize, k0: usize) void {
    var q: u32 = 1;
    while ((q + 1) * (q + 1) * (q + 1) <= k0) q += 1;
    var lo: [3]f32 = @splat(std.math.inf(f32));
    var hi: [3]f32 = @splat(-std.math.inf(f32));
    for (0..tiles) |ti| for (0..3) |k| {
        lo[k] = @min(lo[k], m.feature[4 * ti + k]);
        hi[k] = @max(hi[k], m.feature[4 * ti + k]);
    };
    const qf: f32 = @floatFromInt(q);
    for (0..tiles) |ti| {
        var bin: u32 = 0;
        for (0..3) |k| {
            const span = if (hi[k] > lo[k]) hi[k] - lo[k] else 1;
            const v: u32 = @intFromFloat(@min(qf - 1, (m.feature[4 * ti + k] - lo[k]) / span * qf));
            bin = bin * q + v;
        }
        in.tile_group[ti] = bin;
    }
}

/// Merges and remaps the groups for `in.rounds` rounds, returning how many
/// are left; their histograms are left in `in.histos`.
fn refine(in: Input, m: Mem, tiles: usize, start_groups: usize) usize {
    var groups = start_groups;
    var round: u8 = 0;
    while (true) : (round += 1) {
        histograms(in, m, tiles, groups);
        merge(in, m, tiles, groups);
        groups = compact(in, tiles);
        histograms(in, m, tiles, groups);
        if (round + 1 >= in.rounds or groups == 1) break;
        // Each tile to the group that codes it in the fewest bits.
        costTables(in, m, groups);
        for (0..tiles) |ti| {
            var best = in.tile_group[ti];
            var best_cost = tileCost(m, ti, best);
            for (0..groups) |g| {
                const c = tileCost(m, ti, g);
                if (c < best_cost) {
                    best_cost = c;
                    best = @intCast(g);
                }
            }
            in.tile_group[ti] = best;
        }
        groups = compact(in, tiles);
    }
    return groups;
}

fn setMask(m: Mem, g: usize) void {
    const hg: [*]const u32 = @ptrCast(&m.histos[g]);
    m.mask[g] = @splat(0);
    for (0..symbols) |i| {
        if (hg[i] != 0) m.mask[g][i / 64] |= @as(u64, 1) << @intCast(i % 64);
    }
}

/// Merges groups, the pair that saves the most bits first, while a merge
/// saves any: what describing a group's codes costs against the bits its
/// symbols take apart and together.
fn merge(in: Input, m: Mem, tiles: usize, groups: usize) void {
    const gs = in.green_size;
    for (0..groups) |g| {
        setMask(m, g);
        m.cost_of[g] = histCost(m, g, g, false, gs);
        m.alive[g] = true;
    }
    // A pair's cost together stays until one of the two changes; the same
    // either way round.
    for (0..groups) |g| for (g + 1..groups) |k| {
        const c = histCost(m, g, k, true, gs);
        m.pair[g * groups + k] = c;
        m.pair[k * groups + g] = c;
    };
    for (0..groups) |g| bestPartner(m, groups, g);
    while (true) {
        var g: usize = groups;
        var low: f32 = 0;
        for (0..groups) |k| {
            if (m.alive[k] and m.best_delta[k] < low) {
                low = m.best_delta[k];
                g = k;
            }
        }
        if (g == groups) break;
        const h = m.best[g];
        in.histos[g].add(&in.histos[h]);
        for (&m.mask[g], m.mask[h]) |*a, b| a.* |= b;
        m.cost_of[g] = histCost(m, g, g, false, gs);
        m.alive[h] = false;
        for (in.tile_group[0..tiles]) |*t| {
            if (t.* == h) t.* = @intCast(g);
        }
        for (0..groups) |k| {
            if (!m.alive[k] or k == g) continue;
            const c = histCost(m, k, g, true, gs);
            m.pair[g * groups + k] = c;
            m.pair[k * groups + g] = c;
        }
        // The merged group's partners, and the groups whose best partner
        // was either of the two.
        bestPartner(m, groups, g);
        for (0..groups) |k| {
            if (!m.alive[k] or k == g) continue;
            if (m.best[k] == g or m.best[k] == h) {
                bestPartner(m, groups, k);
            } else {
                const d = m.pair[k * groups + g] - m.cost_of[k] - m.cost_of[g];
                if (d < m.best_delta[k]) {
                    m.best_delta[k] = d;
                    m.best[k] = @intCast(g);
                }
            }
        }
    }
}

fn bestPartner(m: Mem, groups: usize, g: usize) void {
    m.best_delta[g] = std.math.inf(f32);
    for (0..groups) |k| {
        if (!m.alive[k] or k == g) continue;
        const d = m.pair[g * groups + k] - m.cost_of[g] - m.cost_of[k];
        if (d < m.best_delta[g]) {
            m.best_delta[g] = d;
            m.best[g] = @intCast(k);
        }
    }
}

/// Estimated bits for the five codes of group `a`, plus group `b` when
/// `both`: their symbols' entropy and what writing each code's lengths
/// takes, about 3 bits a used symbol and one run code for up to 138
/// unused ones; unused symbols at the end cost nothing. Only the used
/// symbols are visited, by the groups' masks.
fn histCost(m: Mem, a: usize, b: usize, both: bool, green_size: usize) f32 {
    const pa: [*]const u32 = @ptrCast(&m.histos[a]);
    const pb: [*]const u32 = @ptrCast(&m.histos[b]);
    var bits: f32 = 0;
    for (0..5) |k| {
        const lo = codes.offsets[k];
        const end = lo + if (k == 0) green_size else @as(usize, if (k == 4) 40 else 256);
        var total: u32 = 0;
        var clogc: f32 = 0;
        var used: u32 = 0;
        var header: f32 = 0;
        var next = lo;
        var wi = lo / 64;
        while (wi * 64 < end) : (wi += 1) {
            var word = m.mask[a][wi] | if (both) m.mask[b][wi] else 0;
            if (wi * 64 < lo) word &= ~((@as(u64, 1) << @intCast(lo - wi * 64)) - 1);
            if (end - wi * 64 < 64) word &= (@as(u64, 1) << @intCast(end - wi * 64)) - 1;
            while (word != 0) : (word &= word - 1) {
                const i = wi * 64 + @ctz(word);
                const zeros: u32 = @intCast(i - next);
                if (zeros != 0) header += if (zeros < 3)
                    @as(f32, @floatFromInt(zeros))
                else
                    @as(f32, @floatFromInt((zeros + 137) / 138)) * 5;
                next = i + 1;
                const c = pa[i] + if (both) pb[i] else 0;
                used += 1;
                total += c;
                clogc += xlog2(c);
            }
        }
        bits += if (used <= 1) 4 else xlog2(total) - clogc + header + @as(f32, @floatFromInt(used)) * 1.5 + 20;
    }
    return bits;
}

/// x log2 x.
fn xlog2(x: u32) f32 {
    if (x < xlog_table.len) return xlog_table[x];
    return @as(f32, @floatFromInt(x)) * transform.log2(x);
}

const xlog_table = blk: {
    @setEvalBranchQuota(200_000);
    var t: [4096]f32 = undefined;
    t[0] = 0;
    for (1..t.len) |i| {
        const f: f32 = @floatFromInt(i);
        t[i] = f * std.math.log2(f);
    }
    break :blk t;
};

/// Renumbers the groups in use from 0, returning how many there are.
fn compact(in: Input, tiles: usize) usize {
    var map: [1024]u32 = @splat(std.math.maxInt(u32));
    var next: u32 = 0;
    for (in.tile_group[0..tiles]) |*g| {
        if (map[g.*] == std.math.maxInt(u32)) {
            map[g.*] = next;
            next += 1;
        }
        g.* = map[g.*];
    }
    return next;
}

/// Each group's histogram from its tiles' symbols.
fn histograms(in: Input, m: Mem, tiles: usize, groups: usize) void {
    for (in.histos[0..groups]) |*hg| hg.clear();
    for (0..tiles) |ti| {
        const hg: [*]u32 = @ptrCast(&in.histos[in.tile_group[ti]]);
        for (m.pool[m.start[ti]..m.start[ti + 1]]) |e| hg[symbolIndex(e.symbol)] += e.count;
    }
}

/// Where symbol `s` (in `codes.offsets` order) sits in a `Histogram`,
/// whose fields are laid out the same way.
inline fn symbolIndex(s: u16) usize {
    return s;
}

comptime {
    std.debug.assert(@offsetOf(codes.Histogram, "red") == codes.offsets[1] * 4);
    std.debug.assert(@offsetOf(codes.Histogram, "dist") == codes.offsets[4] * 4);
}

/// Each group's cost per symbol in bits: what its own code would give,
/// with a symbol it lacks costing as if it were rarer than any it has.
fn costTables(in: Input, m: Mem, groups: usize) void {
    for (0..groups) |g| {
        const hg: [*]const u32 = @ptrCast(&in.histos[g]);
        const ct = m.group_cost[g * symbols ..][0..symbols];
        for (0..5) |k| {
            const lo = codes.offsets[k];
            const n: usize = if (k == 0) in.green_size else if (k == 4) 40 else 256;
            var total: u64 = 0;
            for (hg[lo..][0..n]) |c| total += c;
            const t: f32 = @floatFromInt(total + 1);
            const lt = std.math.log2(t);
            for (hg[lo..][0..n], ct[lo..][0..n]) |c, *o| {
                o.* = if (c == 0) lt + 2 else lt - std.math.log2(@as(f32, @floatFromInt(c)));
            }
            // Symbols past green's alphabet are never used.
            if (k == 0) @memset(ct[n..codes.offsets[1]], 0);
        }
    }
}

fn tileCost(m: Mem, ti: usize, g: usize) f32 {
    const ct = m.group_cost[g * symbols ..][0..symbols];
    var bits: f32 = 0;
    for (m.pool[m.start[ti]..m.start[ti + 1]]) |e| bits += @as(f32, @floatFromInt(e.count)) * ct[e.symbol];
    return bits;
}
