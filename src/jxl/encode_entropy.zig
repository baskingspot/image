//! Entropy coding for the JPEG XL encoder (ISO/IEC 18181-1, Annex on
//! entropy coding), the inverse of the decoder's entropy.zig: hybrid
//! integers, contexts clustered into at most 256 histograms through a
//! context map, and either ANS with the decoder's alias tables or prefix
//! codes in Brotli's format.
//!
//! A `Code` is built from per-context token counts (`Histograms`),
//! written with `Code.write`, and then encodes any number of token
//! streams (`Code.encode`), each one the stream a decoder's `Reader`
//! reads after the code: ANS streams start with the encoder's final state.

const std = @import("std");
const testing = std.testing;

const BitWriter = @import("encode_bits.zig").BitWriter;
const Bump = @import("encode_mem.zig").Bump;

const entropy = @import("entropy.zig");
pub const log_tab_size = entropy.log_tab_size;
pub const tab_size = entropy.tab_size;
const Alias = entropy.Alias;
const initAlias = entropy.initAlias;
/// Tokens are below this: every hybrid configuration here keeps 32-bit
/// values under 256 tokens.
pub const alphabet = 256;
pub const max_clusters = 256;
const prefix_max_bits = 15;

/// A hybrid integer configuration: values below 2^split_exp are tokens;
/// above, a token carries the exponent, `msb` bits after the top one, and
/// the low `lsb` bits, and the rest follow raw.
pub const Config = struct {
    split_exp: u5 = 4,
    msb: u5 = 2,
    lsb: u5 = 0,

    pub const Split = struct { token: u32, nbits: u5, extra: u32 };

    pub inline fn split(c: Config, v: u32) Split {
        if (v < @as(u32, 1) << c.split_exp) return .{ .token = v, .nbits = 0, .extra = 0 };
        const n: u5 = @intCast(31 - @clz(v));
        const ml = c.msb + c.lsb;
        const nbits: u5 = n - ml;
        const msb_bits = (v >> (n - c.msb)) & ((@as(u32, 1) << c.msb) - 1);
        const low = v & ((@as(u32, 1) << c.lsb) - 1);
        const token = (@as(u32, 1) << c.split_exp) + ((@as(u32, n) - c.split_exp) << ml) + (msb_bits << c.lsb) + low;
        const extra = (v >> c.lsb) & ((@as(u32, 1) << nbits) - 1);
        return .{ .token = token, .nbits = nbits, .extra = extra };
    }

    /// Whether the configuration is valid for an alphabet of 2^log_alpha
    /// and keeps every token below `alphabet`.
    pub fn valid(c: Config, log_alpha: u5) bool {
        if (c.split_exp > log_alpha) return false;
        if (c.split_exp != log_alpha and c.msb + c.lsb > c.split_exp) return false;
        return c.split(std.math.maxInt(u32)).token < alphabet;
    }

    fn write(c: Config, w: *BitWriter, log_alpha: u5) void {
        w.bits(c.split_exp, ceilLog2(@as(u32, log_alpha) + 1));
        if (c.split_exp == log_alpha) return;
        w.bits(c.msb, ceilLog2(@as(u32, c.split_exp) + 1));
        w.bits(c.lsb, ceilLog2(@as(u32, c.split_exp) - c.msb + 1));
    }
};

fn ceilLog2(x: u32) u6 {
    return if (x <= 1) 0 else @intCast(32 - @clz(x - 1));
}

pub fn packSigned(v: i32) u32 {
    const x: u32 = @bitCast(v);
    return if (v >= 0) x << 1 else ((~x) << 1) | 1;
}

/// One symbol of a stream: a context and the integer it codes.
pub const Token = struct {
    ctx: u32,
    value: u32,
};

/// Token counts per context, `alphabet` per context.
pub const Histograms = struct {
    counts: []u32,
    num_contexts: usize,

    pub fn init(mem: *Bump, num_contexts: usize) !Histograms {
        const counts = try mem.alloc(u32, num_contexts * alphabet);
        @memset(counts, 0);
        return .{ .counts = counts, .num_contexts = num_contexts };
    }

    pub fn of(h: *const Histograms, ctx: usize) []u32 {
        return h.counts[ctx * alphabet ..][0..alphabet];
    }

    pub inline fn add(h: *Histograms, ctx: usize, token: u32) void {
        h.counts[ctx * alphabet + token] += 1;
    }

    pub fn addTokens(h: *Histograms, tokens: []const Token, config: Config) void {
        for (tokens) |t| h.add(t.ctx, config.split(t.value).token);
    }
};

pub const BuildOptions = struct {
    use_prefix: bool = false,
    config: Config = .{},
    /// At most this many clusters.
    max_clusters: usize = max_clusters,
};

/// The most memory `Code.build` takes for `num_contexts` contexts.
pub fn buildMemory(num_contexts: usize) usize {
    const clusters: usize = @min(num_contexts, max_clusters);
    const per_cluster = 2 * alphabet * 4 + 2 * alphabet * 2 + alphabet + 2 * tab_size + @sizeOf(Config);
    return num_contexts * 13 + clusters * per_cluster + 256;
}

/// The most memory `Code.write` takes for `num_contexts` contexts.
pub fn writeMemory(num_contexts: usize) usize {
    return num_contexts * 2 * @sizeOf(Token) + 2 * (alphabet * 4 + buildMemory(1)) + 256;
}

pub const Code = struct {
    num_contexts: usize,
    context_map: []u8,
    num_clusters: usize,
    use_prefix: bool,
    log_alpha: u5,
    configs: []Config,
    /// Per cluster, `alphabet` entries: ANS frequencies (of 4096) or
    /// prefix code lengths.
    freq: []u16,
    /// ANS: per cluster, the start of each symbol's slots in `slots`.
    /// Prefix: each symbol's code, bit-reversed for LSB-first writing.
    start: []u16,
    /// ANS: per cluster, 4096 slot positions grouped by symbol, in the
    /// order of their offsets.
    slots: []u16,
    /// ANS: per cluster, how its histogram is written (`normalizeBest`).
    /// Prefix: the code lengths.
    lengths: []u8,
    /// Prefix: per cluster, one past the last symbol it codes.
    sizes: []u16,

    /// Builds a code for `h`, clustering its contexts.
    pub fn build(mem: *Bump, h: *const Histograms, options: BuildOptions) !Code {
        const n = h.num_contexts;
        const context_map = try mem.alloc(u8, n);
        const m = mem.mark();
        var merged: []u32 = undefined;
        const num_clusters = try cluster(mem, h, options.max_clusters, context_map, &merged);
        // Keep the merged counts past the scratch clustering used.
        mem.release(m);
        const counts = try mem.alloc(u32, num_clusters * alphabet);
        @memmove(counts[0 .. num_clusters * alphabet], merged[0 .. num_clusters * alphabet]);
        var code: Code = .{
            .num_contexts = n,
            .context_map = context_map,
            .num_clusters = num_clusters,
            .use_prefix = options.use_prefix,
            .log_alpha = 8,
            .configs = try mem.alloc(Config, num_clusters),
            .freq = try mem.alloc(u16, num_clusters * alphabet),
            .start = try mem.alloc(u16, num_clusters * alphabet),
            .slots = if (options.use_prefix) &.{} else try mem.alloc(u16, num_clusters * tab_size),
            .lengths = try mem.alloc(u8, num_clusters * alphabet),
            .sizes = try mem.alloc(u16, num_clusters),
        };
        @memset(code.configs, options.config);
        var max_token: usize = 0;
        for (0..num_clusters) |c| {
            const hc = counts[c * alphabet ..][0..alphabet];
            for (hc, 0..) |k, s| {
                if (k != 0) max_token = @max(max_token, s);
            }
        }
        if (!options.use_prefix) {
            code.log_alpha = @intCast(@max(5, ceilLog2(@intCast(max_token + 1)), options.config.split_exp));
            for (0..num_clusters) |c| code.buildAns(c, counts[c * alphabet ..][0..alphabet]);
        } else {
            code.log_alpha = prefix_max_bits;
            for (0..num_clusters) |c| code.buildPrefix(c, counts[c * alphabet ..][0..alphabet]);
        }
        return code;
    }

    fn buildAns(code: *Code, c: usize, counts: []const u32) void {
        const freq = code.freq[c * alphabet ..][0..alphabet];
        normalizeBest(counts, freq, &code.lengths[c * alphabet]);
        // The slots each symbol owns, by the decoder's alias table.
        var table: [256]Alias = undefined;
        const n = @as(usize, 1) << code.log_alpha;
        initAlias(freq[0..n], code.log_alpha, table[0..n]);
        const start = code.start[c * alphabet ..][0..alphabet];
        var at: u16 = 0;
        for (start, freq) |*s, f| {
            s.* = at;
            at +%= f;
        }
        const slots = code.slots[c * tab_size ..][0..tab_size];
        const log_entry: u5 = log_tab_size - code.log_alpha;
        for (0..tab_size) |pos| {
            const bucket = pos >> log_entry;
            const p = pos & ((@as(usize, 1) << log_entry) - 1);
            const a = table[bucket];
            var sym: usize = bucket;
            var offset: usize = p;
            if (p >= a.cutoff) {
                sym = a.right;
                offset = @as(u16, a.offset +% @as(u16, @intCast(p)));
            }
            slots[start[sym] + offset] = @intCast(pos);
        }
    }

    fn buildPrefix(code: *Code, c: usize, counts: []const u32) void {
        var size: u16 = 0;
        for (counts, 0..) |k, sym| {
            if (k != 0) size = @intCast(sym + 1);
        }
        code.sizes[c] = size;
        const lengths = code.lengths[c * alphabet ..][0..alphabet];
        huffmanLengths(counts, prefix_max_bits, lengths);
        const codes = code.start[c * alphabet ..][0..alphabet];
        canonicalCodes(lengths, codes);
        const freq = code.freq[c * alphabet ..][0..alphabet];
        for (freq, lengths) |*f, l| f.* = l;
    }

    /// Writes the code as `entropy.Code.read` reads it.
    pub fn write(code: *const Code, w: *BitWriter, mem: *Bump) error{WorkTooSmall}!void {
        // No LZ77.
        w.boolean(false);
        if (code.num_contexts > 1) try writeContextMap(w, mem, code.context_map, code.num_clusters);
        w.boolean(code.use_prefix);
        if (!code.use_prefix) w.bits(code.log_alpha - 5, 2);
        for (code.configs) |c| c.write(w, code.log_alpha);
        if (code.use_prefix) {
            for (0..code.num_clusters) |c| {
                const size: u32 = code.sizes[c];
                if (size <= 1) {
                    w.boolean(false);
                } else {
                    w.boolean(true);
                    if (size == 2) {
                        w.bits(0, 4);
                    } else {
                        const nbits: u5 = @intCast(31 - @clz(size - 1));
                        w.bits(nbits, 4);
                        w.bits(size - 1 - (@as(u32, 1) << nbits), nbits);
                    }
                }
            }
            for (0..code.num_clusters) |c| {
                const size = code.sizes[c];
                if (size > 1) writePrefixCode(w, code.lengths[c * alphabet ..][0..size]);
            }
        } else {
            for (0..code.num_clusters) |c| {
                writeHistogram(w, code.freq[c * alphabet ..][0..alphabet], code.lengths[c * alphabet]);
            }
        }
    }

    /// Encodes `tokens` as one stream. `scratch` holds a u32 per token
    /// for ANS.
    pub fn encode(code: *const Code, w: *BitWriter, tokens: []const Token, scratch: []u32) void {
        if (code.use_prefix) {
            for (tokens) |t| {
                const cl: usize = code.context_map[t.ctx];
                const s = code.configs[cl].split(t.value);
                const i = cl * alphabet + s.token;
                w.bits(code.start[i], @intCast(code.freq[i]));
                w.bits(s.extra, s.nbits);
            }
            return;
        }
        std.debug.assert(scratch.len >= tokens.len);
        var state: u32 = 0x130000;
        var i = tokens.len;
        while (i > 0) {
            i -= 1;
            const t = tokens[i];
            const cl: usize = code.context_map[t.ctx];
            const s = code.configs[cl].split(t.value);
            const k = cl * alphabet + s.token;
            const f: u32 = code.freq[k];
            var word: u32 = 0;
            if ((state >> (32 - log_tab_size)) >= f) {
                word = (state & 0xffff) | 0x10000;
                state >>= 16;
            }
            scratch[i] = word;
            const slot = code.slots[cl * tab_size + code.start[k] + state % f];
            state = ((state / f) << log_tab_size) + slot;
        }
        w.bits(state, 32);
        for (tokens, scratch[0..tokens.len]) |t, word| {
            if (word != 0) w.bits(word & 0xffff, 16);
            const cl: usize = code.context_map[t.ctx];
            const s = code.configs[cl].split(t.value);
            w.bits(s.extra, s.nbits);
        }
    }

    /// An estimate of the bits `tokens` take in this code, without the
    /// code itself.
    pub fn cost(code: *const Code, tokens: []const Token) f64 {
        var bits: f64 = 0;
        for (tokens) |t| {
            const cl: usize = code.context_map[t.ctx];
            const s = code.configs[cl].split(t.value);
            const f = code.freq[cl * alphabet + s.token];
            bits += @as(f64, @floatFromInt(s.nbits));
            const ff: f64 = @floatFromInt(@max(f, 1));
            bits += if (code.use_prefix) @as(f64, @floatFromInt(f)) else log_tab_size - std.math.log2(ff);
        }
        return bits;
    }
};

// Clustering.

inline fn entropyOf(counts: []const u32, total: u64) f32 {
    if (total == 0) return 0;
    var bits: f32 = 0;
    const lt = std.math.log2(@as(f32, @floatFromInt(total)));
    for (counts) |c| {
        if (c != 0) {
            const cf: f32 = @floatFromInt(c);
            bits += cf * (lt - std.math.log2(cf));
        }
    }
    return bits;
}

fn mergedEntropy(a: []const u32, b: []const u32) f32 {
    var total: u64 = 0;
    for (a, b) |x, y| total += @as(u64, x) + y;
    if (total == 0) return 0;
    const lt = std.math.log2(@as(f32, @floatFromInt(total)));
    var bits: f32 = 0;
    for (a, b) |x, y| {
        const c = x + y;
        if (c != 0) {
            const cf: f32 = @floatFromInt(c);
            bits += cf * (lt - std.math.log2(cf));
        }
    }
    return bits;
}

fn totalOf(counts: []const u32) u64 {
    var t: u64 = 0;
    for (counts) |c| t += c;
    return t;
}

/// A rough cost in bits of writing a histogram with `used` symbols.
fn headerCost(counts: []const u32) f32 {
    var used: f32 = 0;
    for (counts) |c| used += @floatFromInt(@intFromBool(c != 0));
    return 16 + 6 * used;
}

/// Clusters `h`'s contexts into at most `max` histograms: seeds chosen
/// farthest first by the bits a context would add to the nearest seed,
/// while a new histogram would pay for itself, then every context
/// assigned to its nearest seed. Fills `map` and returns the number of
/// clusters; `merged` gets their counts.
fn cluster(mem: *Bump, h: *const Histograms, max_in: usize, map: []u8, merged: *[]u32) !usize {
    const n = h.num_contexts;
    const max = @min(@max(max_in, 1), max_clusters, n);
    const self = try mem.alloc(f32, n);
    const dist = try mem.alloc(f32, n);
    const nearest = try mem.alloc(u32, n);
    var seeds: [max_clusters]u32 = undefined;
    var first: usize = 0;
    var best_total: u64 = 0;
    for (0..n) |i| {
        const c = h.of(i);
        const t = totalOf(c);
        self[i] = entropyOf(c, t);
        if (t > best_total) {
            best_total = t;
            first = i;
        }
    }
    var ns: usize = 1;
    seeds[0] = @intCast(first);
    for (0..n) |i| {
        dist[i] = mergedEntropy(h.of(i), h.of(first)) - self[i] - self[first];
        nearest[i] = 0;
    }
    while (ns < max) {
        var far: usize = 0;
        var far_d: f32 = -1;
        for (0..n) |i| {
            if (dist[i] > far_d) {
                far_d = dist[i];
                far = i;
            }
        }
        if (far_d <= headerCost(h.of(far))) break;
        seeds[ns] = @intCast(far);
        for (0..n) |i| {
            const d = mergedEntropy(h.of(i), h.of(far)) - self[i] - self[far];
            if (d < dist[i]) {
                dist[i] = d;
                nearest[i] = @intCast(ns);
            }
        }
        // The seed itself.
        dist[far] = 0;
        nearest[far] = @intCast(ns);
        ns += 1;
    }
    // Clusters in order of first use, as the context map wants none
    // skipped.
    var renum: [max_clusters]i16 = @splat(-1);
    var count: usize = 0;
    for (0..n) |i| {
        const s = nearest[i];
        if (renum[s] < 0) {
            renum[s] = @intCast(count);
            count += 1;
        }
        map[i] = @intCast(renum[s]);
    }
    const out = try mem.alloc(u32, count * alphabet);
    @memset(out, 0);
    for (0..n) |i| {
        const dst = out[@as(usize, map[i]) * alphabet ..][0..alphabet];
        for (dst, h.of(i)) |*d, s| d.* += s;
    }
    merged.* = out;
    return count;
}

// ANS histograms.

/// Normalizes `counts` to `freq` (summing to 4096) for the precision
/// shift that costs least, and returns whether it is written in full
/// (0 for one or no symbol, 2 for two, 1 for the general form) in
/// `kind`; `freq` then holds what the decoder reconstructs.
fn normalizeBest(counts: []const u32, freq: []u16, kind: *u8) void {
    @memset(freq, 0);
    var total: u64 = 0;
    var used: usize = 0;
    var syms: [2]usize = .{ 0, 0 };
    for (counts, 0..) |c, s| {
        if (c == 0) continue;
        total += c;
        if (used < 2) syms[used] = s;
        used += 1;
    }
    if (used <= 1) {
        freq[syms[0]] = tab_size;
        kind.* = 0;
        return;
    }
    if (used == 2) {
        // Two symbols: 12 bits of the first's count.
        const c0 = counts[syms[0]];
        var f0: u64 = (@as(u64, c0) * tab_size + total / 2) / total;
        f0 = std.math.clamp(f0, 1, tab_size - 1);
        freq[syms[0]] = @intCast(f0);
        freq[syms[1]] = @intCast(tab_size - f0);
        kind.* = 2;
        return;
    }
    var best_cost: f64 = std.math.inf(f64);
    var best: [alphabet]u16 = undefined;
    var best_shift: u8 = 0;
    var trial: [alphabet]u16 = undefined;
    var shift: u8 = 0;
    while (shift <= log_tab_size + 1) : (shift += 1) {
        if (!normalize(counts, total, shift, &trial)) continue;
        var bits: f64 = 0;
        for (counts, trial) |c, f| {
            if (c != 0) bits += @as(f64, @floatFromInt(c)) * (log_tab_size - std.math.log2(@as(f64, @floatFromInt(f))));
        }
        bits += histogramBits(&trial, shift);
        if (bits < best_cost) {
            best_cost = bits;
            best = trial;
            best_shift = shift;
        }
    }
    @memcpy(freq[0..alphabet], &best);
    kind.* = 16 + best_shift;
}

/// The floor of log2 of a count.
inline fn logCount(f: u32) u32 {
    return 31 - @clz(f);
}

/// The extra bits a count of log `lc` takes at precision `shift`.
inline fn bitCount(lc: u32, shift: u32) u32 {
    if (shift == 0 or lc == 0) return 0;
    const want = @as(i32, @intCast(shift)) - @as(i32, @intCast((log_tab_size - lc) >> 1));
    return @intCast(std.math.clamp(want, 0, @as(i32, @intCast(lc))));
}

/// The nearest count to `f` (at least 1) that the general form stores at
/// precision `shift`.
fn representable(f_in: u32, shift: u32) u32 {
    const f = @max(f_in, 1);
    const lc = logCount(f);
    const drop: u5 = @intCast(lc - bitCount(lc, shift));
    const step = @as(u32, 1) << drop;
    // Round to the nearest step, within [2^lc, 2^(lc+1)).
    var r = (f + step / 2) & ~(step - 1);
    if (r >= @as(u32, 2) << @intCast(lc)) r = (@as(u32, 2) << @intCast(lc)) - step;
    return r;
}

/// The symbol the decoder takes as omitted: the first of the largest
/// log count.
fn omitted(freq: []const u16) usize {
    var best: i32 = -1;
    var pos: usize = 0;
    for (freq, 0..) |f, s| {
        if (f == 0) continue;
        const lc: i32 = @intCast(logCount(f));
        if (lc > best) {
            best = lc;
            pos = s;
        }
    }
    return pos;
}

/// Normalizes `counts` at precision `shift` so that every count but the
/// omitted one is representable and the omitted one is what remains;
/// false when that fails.
fn normalize(counts: []const u32, total: u64, shift: u8, out: *[alphabet]u16) bool {
    var largest: usize = 0;
    for (counts, 0..) |c, s| {
        if (c > counts[largest]) largest = s;
    }
    var sum: u32 = 0;
    for (counts, 0..) |c, s| {
        if (c == 0) {
            out[s] = 0;
            continue;
        }
        const target: u32 = @intCast(@max(1, (@as(u64, c) * tab_size + total / 2) / total));
        out[s] = @intCast(@min(representable(target, shift), tab_size - 1));
        if (s != largest) sum += out[s];
    }
    // The largest symbol takes the rest; it must stay the omitted one.
    while (true) {
        if (sum >= tab_size) {
            // Take one step off the largest other count.
            var big: usize = alphabet;
            for (counts, 0..) |c, s| {
                if (c == 0 or s == largest or out[s] <= 1) continue;
                if (big == alphabet or out[s] > out[big]) big = s;
            }
            if (big == alphabet) return false;
            const old = out[big];
            const lower = representable(old - 1, shift);
            const next: u16 = @intCast(if (lower < old) lower else old - 1);
            if (representable(next, shift) != next) return false;
            out[big] = next;
            sum -= old - next;
            continue;
        }
        out[largest] = @intCast(tab_size - sum);
        // The omitted symbol must be the first of the largest log count.
        if (omitted(out[0..alphabet]) == largest) return true;
        // Otherwise lower the counts that compete with it.
        const lc = logCount(out[largest]);
        var changed = false;
        for (counts, 0..) |c, s| {
            if (c == 0 or s == largest) continue;
            if (logCount(out[s]) > lc or (logCount(out[s]) == lc and s < largest)) {
                const old = out[s];
                const next: u16 = @intCast((@as(u32, 1) << @intCast(lc)) - 1);
                const r = representable(next, shift);
                const v: u16 = @intCast(if (r <= next) r else next);
                if (representable(v, shift) != v or v >= old) return false;
                out[s] = v;
                sum -= old - v;
                changed = true;
            }
        }
        if (!changed) return false;
    }
}

const logcount_codes = [14]struct { code: u8, len: u8 }{
    .{ .code = 0b10001, .len = 5 }, // 0
    .{ .code = 0b1011, .len = 4 }, // 1
    .{ .code = 0b1111, .len = 4 }, // 2
    .{ .code = 0b0011, .len = 4 }, // 3
    .{ .code = 0b1001, .len = 4 }, // 4
    .{ .code = 0b0111, .len = 4 }, // 5
    .{ .code = 0b100, .len = 3 }, // 6
    .{ .code = 0b010, .len = 3 }, // 7
    .{ .code = 0b101, .len = 3 }, // 8
    .{ .code = 0b110, .len = 3 }, // 9
    .{ .code = 0b000, .len = 3 }, // 10
    .{ .code = 0b100001, .len = 6 }, // 11
    .{ .code = 0b0000001, .len = 7 }, // 12
    .{ .code = 0b1000001, .len = 7 }, // 13
};

fn u8Bits(x: u32) u32 {
    if (x == 0) return 1;
    return 4 + logCount(x);
}

fn writeU8(w: *BitWriter, x: u32) void {
    if (x == 0) {
        w.boolean(false);
        return;
    }
    w.boolean(true);
    const n: u5 = @intCast(logCount(x));
    w.bits(n, 3);
    w.bits(x - (@as(u32, 1) << n), n);
}

fn histogramLen(freq: []const u16) usize {
    var len: usize = 0;
    for (freq, 0..) |f, s| {
        if (f != 0) len = s + 1;
    }
    return @max(len, 3);
}

/// The bits the general form of `freq` takes at `shift`.
fn histogramBits(freq: []const u16, shift: u32) f64 {
    const len = histogramLen(freq);
    var bits: u32 = 2 + 4 + u8Bits(@intCast(len - 3));
    const omit = omitted(freq);
    for (freq[0..len], 0..) |f, s| {
        const v: usize = if (f == 0) 0 else logCount(f) + 1;
        bits += logcount_codes[v].len;
        if (f != 0 and s != omit) bits += bitCount(logCount(f), shift);
    }
    return @floatFromInt(bits);
}

fn writeHistogram(w: *BitWriter, freq: []const u16, kind: u8) void {
    if (kind == 0 or kind == 2) {
        w.boolean(true);
        var syms: [2]u32 = undefined;
        var n: usize = 0;
        for (freq, 0..) |f, s| {
            if (f != 0 and n < 2) {
                syms[n] = @intCast(s);
                n += 1;
            }
        }
        if (kind == 0) {
            w.boolean(false);
            writeU8(w, if (n == 0) 0 else syms[0]);
            return;
        }
        w.boolean(true);
        writeU8(w, syms[0]);
        writeU8(w, syms[1]);
        w.bits(freq[syms[0]], log_tab_size);
        return;
    }
    const shift: u32 = kind - 16;
    w.boolean(false);
    w.boolean(false);
    // The shift: unary log up to 3, then its bits.
    const v = shift + 1;
    const log: u5 = @intCast(logCount(v));
    for (0..log) |_| w.boolean(true);
    if (log < 3) w.boolean(false);
    w.bits(v - (@as(u32, 1) << log), log);
    const len = histogramLen(freq);
    writeU8(w, @intCast(len - 3));
    const omit = omitted(freq);
    for (freq[0..len]) |f| {
        const c = logcount_codes[if (f == 0) 0 else logCount(f) + 1];
        w.bits(c.code, @intCast(c.len));
    }
    for (freq[0..len], 0..) |f, s| {
        if (f == 0 or s == omit) continue;
        const lc = logCount(f);
        const bc = bitCount(lc, shift);
        if (bc == 0) continue;
        const extra = (f - (@as(u32, 1) << @intCast(lc))) >> @intCast(lc - bc);
        w.bits(extra, @intCast(bc));
    }
}

// Prefix codes.

/// Huffman code lengths for `counts`, at most `limit` bits; symbols with
/// no count get 0. With one used symbol its length is 0 too (a simple
/// code of one symbol).
fn huffmanLengths(counts: []const u32, limit: u5, lengths: []u8) void {
    @memset(lengths, 0);
    var scale: u5 = 0;
    while (true) : (scale += 1) {
        if (tryHuffman(counts, limit, scale, lengths)) return;
    }
}

fn tryHuffman(counts: []const u32, limit: u5, scale: u5, lengths: []u8) bool {
    const n = counts.len;
    const Node = struct { weight: u64, left: i32, right: i32 };
    var nodes: [2 * alphabet]Node = undefined;
    var leaves: [alphabet]u32 = undefined;
    var nl: usize = 0;
    for (counts, 0..) |c, s| {
        if (c == 0) continue;
        leaves[nl] = @intCast(s);
        nl += 1;
    }
    @memset(lengths[0..n], 0);
    if (nl <= 1) return true;
    // Leaves sorted by weight; then the two-queue method.
    const Ctx = struct {
        counts: []const u32,
        scale: u5,
        const Self = @This();
        fn w(ctx: Self, s: u32) u64 {
            return @max(1, ctx.counts[s] >> ctx.scale);
        }
        fn less(ctx: Self, a: u32, b: u32) bool {
            const wa = ctx.w(a);
            const wb = ctx.w(b);
            return wa < wb or (wa == wb and a < b);
        }
    };
    const ctx: Ctx = .{ .counts = counts, .scale = scale };
    std.sort.pdq(u32, leaves[0..nl], ctx, Ctx.less);
    for (0..nl) |i| nodes[i] = .{ .weight = ctx.w(leaves[i]), .left = -1, .right = @intCast(leaves[i]) };
    var nn = nl;
    var qi: usize = 0; // next leaf
    var qj: usize = nl; // next internal
    while (nn - nl < nl - 1) {
        var pick: [2]usize = undefined;
        for (&pick) |*p| {
            if (qi < nl and (qj >= nn or nodes[qi].weight <= nodes[qj].weight)) {
                p.* = qi;
                qi += 1;
            } else {
                p.* = qj;
                qj += 1;
            }
        }
        nodes[nn] = .{
            .weight = nodes[pick[0]].weight + nodes[pick[1]].weight,
            .left = @intCast(pick[0]),
            .right = @intCast(pick[1]),
        };
        nn += 1;
    }
    // Depths from the root down: internal nodes come after their children.
    var depth: [2 * alphabet]u8 = undefined;
    depth[nn - 1] = 0;
    var i = nn - 1;
    while (i >= nl) : (i -= 1) {
        const nd = nodes[i];
        const d = depth[i] + 1;
        if (d > limit) return false;
        depth[@intCast(nd.left)] = d;
        depth[@intCast(nd.right)] = d;
        if (i == nl) break;
    }
    for (0..nl) |k| lengths[@intCast(nodes[k].right)] = depth[k];
    return true;
}

/// Canonical codes for `lengths`, each bit-reversed so that writing it
/// LSB first sends its first bit first.
fn canonicalCodes(lengths: []const u8, codes: []u16) void {
    var count: [prefix_max_bits + 1]u16 = @splat(0);
    for (lengths) |l| count[l] += 1;
    count[0] = 0;
    var next: [prefix_max_bits + 2]u16 = undefined;
    var code: u16 = 0;
    next[1] = 0;
    for (1..prefix_max_bits + 1) |l| {
        code = (code + count[l - 1]) << 1;
        next[l] = code;
    }
    for (lengths, 0..) |l, s| {
        if (l == 0) {
            codes[s] = 0;
            continue;
        }
        const c = next[l];
        next[l] += 1;
        codes[s] = @bitReverse(c) >> @intCast(16 - @as(u32, l));
    }
}

/// Writes a prefix code over `lengths.len` symbols as `readPrefixCode`
/// reads it.
fn writePrefixCode(w: *BitWriter, lengths: []const u8) void {
    const alpha: u32 = @intCast(lengths.len);
    var used: [4]u16 = undefined;
    var nused: usize = 0;
    for (lengths, 0..) |l, s| {
        if (l != 0) {
            if (nused < 4) used[nused] = @intCast(s);
            nused += 1;
        }
    }
    if (nused <= 1) {
        // A simple code of one symbol.
        w.bits(1, 2);
        w.bits(0, 2);
        const max_bits: u5 = if (alpha > 1) @intCast(32 - @clz(alpha - 1)) else 0;
        // With no lengths, the one symbol is the last.
        w.bits(if (nused == 0) alpha - 1 else used[0], max_bits);
        return;
    }
    // Code length symbols with Brotli's repeat codes.
    var syms: [alphabet + 16]u8 = undefined;
    var extras: [alphabet + 16]u8 = undefined;
    var ns: usize = 0;
    var end = lengths.len;
    while (end > 0 and lengths[end - 1] == 0) end -= 1;
    var prev: u8 = 8;
    var i: usize = 0;
    while (i < end) {
        const v = lengths[i];
        var run: usize = 1;
        while (i + run < end and lengths[i + run] == v) run += 1;
        if (v == 0) {
            rleZeros(&syms, &extras, &ns, run);
        } else {
            rleValue(&syms, &extras, &ns, prev, v, run);
            prev = v;
        }
        i += run;
    }
    var hist: [18]u32 = @splat(0);
    for (syms[0..ns]) |s| hist[s] += 1;
    var cl: [18]u8 = undefined;
    huffmanLengths(&hist, 5, &cl);
    var cl_used: usize = 0;
    for (cl, 0..) |l, s| {
        _ = l;
        if (hist[s] != 0) cl_used += 1;
    }
    if (cl_used == 1) {
        for (&cl, hist) |*l, hcount| l.* = if (hcount != 0) 3 else 0;
    }
    var cl_codes: [18]u16 = undefined;
    canonicalCodes(&cl, &cl_codes);
    const order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var hskip: usize = 0;
    if (cl[order[0]] == 0 and cl[order[1]] == 0) {
        hskip = 2;
        if (cl[order[2]] == 0) hskip = 3;
    }
    w.bits(hskip, 2);
    // Fixed codes for code length code lengths 0..5.
    const fixed = [6]struct { code: u8, len: u6 }{
        .{ .code = 0b00, .len = 2 },
        .{ .code = 0b0111, .len = 4 },
        .{ .code = 0b011, .len = 3 },
        .{ .code = 0b10, .len = 2 },
        .{ .code = 0b01, .len = 2 },
        .{ .code = 0b1111, .len = 4 },
    };
    var space: i32 = 32;
    var k = hskip;
    while (k < 18) : (k += 1) {
        const l = cl[order[k]];
        w.bits(fixed[l].code, fixed[l].len);
        if (l != 0) {
            space -= @as(i32, 32) >> @intCast(l);
            if (space <= 0 and cl_used > 1) break;
        }
    }
    for (syms[0..ns], extras[0..ns]) |s, e| {
        if (cl_used > 1) w.bits(cl_codes[s], @intCast(cl[s]));
        if (s == 16) w.bits(e, 2);
        if (s == 17) w.bits(e, 3);
    }
}

fn rleZeros(syms: []u8, extras: []u8, ns: *usize, run_in: usize) void {
    var run = run_in;
    if (run == 11) {
        syms[ns.*] = 0;
        extras[ns.*] = 0;
        ns.* += 1;
        run -= 1;
    }
    if (run < 3) {
        for (0..run) |_| {
            syms[ns.*] = 0;
            extras[ns.*] = 0;
            ns.* += 1;
        }
        return;
    }
    const start = ns.*;
    run -= 3;
    while (true) {
        syms[ns.*] = 17;
        extras[ns.*] = @intCast(run & 7);
        ns.* += 1;
        run >>= 3;
        if (run == 0) break;
        run -= 1;
    }
    std.mem.reverse(u8, syms[start..ns.*]);
    std.mem.reverse(u8, extras[start..ns.*]);
}

fn rleValue(syms: []u8, extras: []u8, ns: *usize, prev: u8, v: u8, run_in: usize) void {
    var run = run_in;
    if (prev != v) {
        syms[ns.*] = v;
        extras[ns.*] = 0;
        ns.* += 1;
        run -= 1;
    }
    if (run == 7) {
        syms[ns.*] = v;
        extras[ns.*] = 0;
        ns.* += 1;
        run -= 1;
    }
    if (run < 3) {
        for (0..run) |_| {
            syms[ns.*] = v;
            extras[ns.*] = 0;
            ns.* += 1;
        }
        return;
    }
    const start = ns.*;
    run -= 3;
    while (true) {
        syms[ns.*] = 16;
        extras[ns.*] = @intCast(run & 3);
        ns.* += 1;
        run >>= 2;
        if (run == 0) break;
        run -= 1;
    }
    std.mem.reverse(u8, syms[start..ns.*]);
    std.mem.reverse(u8, extras[start..ns.*]);
}

// Context maps.

/// Writes a context map of `num_clusters` clusters as
/// `entropy.readContextMap` reads it.
fn writeContextMap(w: *BitWriter, mem: *Bump, map: []const u8, num_clusters: usize) error{WorkTooSmall}!void {
    const simple_bits: u6 = ceilLog2(@intCast(num_clusters));
    const simple_cost = 3 + @as(usize, simple_bits) * map.len;
    if (simple_bits <= 3 and (map.len <= 8 or simple_cost <= 64)) {
        w.boolean(true);
        w.bits(simple_bits, 2);
        for (map) |e| w.bits(e, simple_bits);
        return;
    }
    // Entropy coded, with move-to-front when it helps, in a prefix code
    // whose tokens are the entries.
    const m = mem.mark();
    defer mem.release(m);
    const plain = try mem.alloc(Token, map.len);
    const mtf = try mem.alloc(Token, map.len);
    for (plain, map) |*t, e| t.* = .{ .ctx = 0, .value = e };
    moveToFront(map, mtf);
    var best_bits: [2]f64 = undefined;
    var codes: [2]Code = undefined;
    // A configuration that makes every entry its own token.
    const direct: Config = .{ .split_exp = 8, .msb = 0, .lsb = 0 };
    for ([2][]Token{ plain, mtf }, 0..) |tokens, k| {
        var h: Histograms = try .init(mem, 1);
        h.addTokens(tokens, direct);
        codes[k] = try Code.build(mem, &h, .{ .use_prefix = true, .config = direct, .max_clusters = 1 });
        best_bits[k] = codes[k].cost(tokens);
    }
    const use_mtf = best_bits[1] < best_bits[0];
    const tokens = if (use_mtf) mtf else plain;
    const code = &codes[@intFromBool(use_mtf)];
    w.boolean(false);
    w.boolean(use_mtf);
    try code.write(w, mem);
    code.encode(w, tokens, &.{});
}

fn moveToFront(map: []const u8, out: []Token) void {
    var order: [256]u8 = undefined;
    for (&order, 0..) |*o, i| o.* = @intCast(i);
    for (map, out) |e, *o| {
        const idx = std.mem.findScalar(u8, &order, e).?;
        o.* = .{ .ctx = 0, .value = @intCast(idx) };
        @memmove(order[1 .. idx + 1], order[0..idx]);
        order[0] = e;
    }
}

// Tests: every code decodes with the decoder's entropy.zig.

const BitReader = @import("BitReader.zig");
const Arena = @import("Arena.zig");

fn roundTrip(tokens: []const Token, num_contexts: usize, options: BuildOptions) !void {
    const mem_buf = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(mem_buf);
    var mem: Bump = .init(mem_buf);
    var h: Histograms = try .init(&mem, num_contexts);
    h.addTokens(tokens, options.config);
    const code = try Code.build(&mem, &h, options);
    const out = try testing.allocator.alloc(u8, 1 << 16);
    defer testing.allocator.free(out);
    var w: BitWriter = .init(out);
    // The decoder's source wants a codestream signature.
    w.bits(0x0aff, 16);
    try code.write(&w, &mem);
    const scratch = try mem.alloc(u32, tokens.len);
    code.encode(&w, tokens, scratch);
    w.padToByte();
    // A section would pad the stream with zeros past its end.
    w.append(&@as([8]u8, @splat(0)));
    try testing.expect(!w.overflow);

    var r: std.Io.Reader = .fixed(w.bytes());
    var br: BitReader = .init(&r, null);
    _ = try br.bits(16);
    const arena_buf = try testing.allocator.alloc(u8, 8 << 20);
    defer testing.allocator.free(arena_buf);
    var arena: Arena = .init(arena_buf);
    const dcode = try entropy.Code.read(&br, &arena, num_contexts);
    var rd = try entropy.Reader.init(&dcode, &br, &arena, 0, tokens.len);
    for (tokens) |t| try testing.expectEqual(t.value, try rd.read(&br, t.ctx));
    try testing.expect(rd.finalOk());
}

test "hybrid integers match the decoder" {
    const configs = [_]Config{
        .{},
        .{ .split_exp = 4, .msb = 1, .lsb = 1 },
        .{ .split_exp = 0, .msb = 0, .lsb = 0 },
        .{ .split_exp = 8, .msb = 0, .lsb = 0 },
    };
    for (configs) |c| {
        try testing.expect(c.split_exp == 8 or c.valid(8));
        for ([_]u32{ 0, 1, 15, 16, 17, 100, 255, 256, 1000, 65535, 1 << 20, std.math.maxInt(u32) }) |v| {
            const s = c.split(v);
            var buf: [16]u8 = undefined;
            var w: BitWriter = .init(&buf);
            w.bits(0x0aff, 16);
            w.bits(s.extra, s.nbits);
            w.padToByte();
            var r: std.Io.Reader = .fixed(w.bytes());
            var br: BitReader = .init(&r, null);
            _ = try br.bits(16);
            const dc: entropy.UintConfig = .{
                .split_exp = c.split_exp,
                .msb = c.msb,
                .lsb = c.lsb,
                .split = @as(u32, 1) << c.split_exp,
            };
            try testing.expectEqual(v, try dc.value(s.token, &br));
        }
    }
}

test "codes round trip through the decoder" {
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    var tokens: [3000]Token = undefined;
    for (0..12) |trial| {
        const num_contexts: usize = 1 + trial % 5 * 7;
        for (&tokens, 0..) |*t, i| {
            const ctx = random.uintLessThan(u32, @intCast(num_contexts));
            // Skewed per context, with an occasional large value.
            const bound = 1 + ctx * 3 + @as(u32, @intCast(i % 4));
            const v: u32 = if (random.uintLessThan(u8, 50) == 0) random.int(u32) else random.uintLessThan(u32, bound);
            t.* = .{ .ctx = ctx, .value = v };
        }
        const n = 1 + random.uintLessThan(usize, tokens.len);
        try roundTrip(tokens[0..n], num_contexts, .{ .use_prefix = trial % 2 == 0 });
        try roundTrip(tokens[0..n], num_contexts, .{
            .use_prefix = trial % 2 == 1,
            .config = .{ .split_exp = 4, .msb = 1, .lsb = 1 },
        });
    }
}

test "one and two symbol codes" {
    var tokens: [10]Token = undefined;
    for (&tokens) |*t| t.* = .{ .ctx = 0, .value = 9 };
    try roundTrip(&tokens, 1, .{});
    try roundTrip(&tokens, 1, .{ .use_prefix = true });
    for (&tokens, 0..) |*t, i| t.* = .{ .ctx = 0, .value = if (i % 3 == 0) 2 else 5 };
    try roundTrip(&tokens, 1, .{});
    try roundTrip(&tokens, 1, .{ .use_prefix = true });
}

test "many contexts need an entropy-coded context map" {
    var tokens: [4000]Token = undefined;
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    for (&tokens, 0..) |*t, i| {
        const ctx: u32 = @intCast(i % 300);
        t.* = .{ .ctx = ctx, .value = random.uintLessThan(u32, 1 + (ctx % 40) * 5) };
    }
    try roundTrip(&tokens, 300, .{});
    try roundTrip(&tokens, 300, .{ .use_prefix = true });
}
