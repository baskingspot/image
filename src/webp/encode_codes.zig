//! The WebP lossless encoder's entropy coding (RFC 9649, section 3.7):
//! the bit writer, symbol histograms, length-limited canonical prefix
//! codes, and how a code's lengths are themselves written.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

/// The largest color cache the encoder uses.
pub const max_cache_bits = 10;
/// Green's alphabet before the color cache: literals and length prefixes.
pub const green_base = 256 + 24;
pub const max_green = green_base + (1 << max_cache_bits);
/// Where each of a group's five codes starts in `Group.lens` and
/// `Group.codes`: green, red, blue, alpha, distance.
pub const offsets = [5]usize{ 0, max_green, max_green + 256, max_green + 512, max_green + 768 };
const all_symbols = max_green + 768 + 40;

/// Counts bits instead of writing them, to size the stream before it is
/// written.
pub const Counter = struct {
    bits: u64 = 0,

    pub inline fn put(c: *Counter, v: u32, n: u32) void {
        _ = v;
        c.bits += n;
    }
};

/// Writes bits least significant first, as VP8L packs them, through a
/// buffer into `w`. A failed write is remembered and reported by `finish`.
pub const BitWriter = struct {
    w: *Io.Writer,
    acc: u64 = 0,
    n: u32 = 0,
    len: usize = 0,
    failed: bool = false,
    buf: [4096]u8 = undefined,

    /// `n` bits of `v`, at most 32.
    pub inline fn put(b: *BitWriter, v: u32, n: u32) void {
        b.acc |= @as(u64, v) << @intCast(b.n);
        b.n += n;
        if (b.n >= 32) {
            if (b.len + 4 > b.buf.len) b.drain();
            std.mem.writeInt(u32, b.buf[b.len..][0..4], @truncate(b.acc), .little);
            b.len += 4;
            b.acc >>= 32;
            b.n -= 32;
        }
    }

    fn drain(b: *BitWriter) void {
        if (!b.failed) b.w.writeAll(b.buf[0..b.len]) catch {
            b.failed = true;
        };
        b.len = 0;
    }

    /// Writes the last bits, padded with zeros to a byte.
    pub fn finish(b: *BitWriter) error{WriteFailed}!void {
        while (b.n > 0) {
            if (b.len == b.buf.len) b.drain();
            b.buf[b.len] = @truncate(b.acc);
            b.len += 1;
            b.acc >>= 8;
            b.n -|= 8;
        }
        b.drain();
        if (b.failed) return error.WriteFailed;
    }
};

/// How often each symbol of a group's five codes occurs.
pub const Histogram = struct {
    green: [max_green]u32,
    red: [256]u32,
    blue: [256]u32,
    alpha: [256]u32,
    dist: [40]u32,

    pub fn clear(h: *Histogram) void {
        @memset(std.mem.asBytes(h), 0);
    }

    pub fn add(h: *Histogram, o: *const Histogram) void {
        for (&h.green, o.green) |*a, b| a.* += b;
        for (&h.red, o.red) |*a, b| a.* += b;
        for (&h.blue, o.blue) |*a, b| a.* += b;
        for (&h.alpha, o.alpha) |*a, b| a.* += b;
        for (&h.dist, o.dist) |*a, b| a.* += b;
    }

    pub fn literal(h: *Histogram, px: u32) void {
        h.green[(px >> 8) & 0xff] += 1;
        h.red[(px >> 16) & 0xff] += 1;
        h.blue[px & 0xff] += 1;
        h.alpha[px >> 24] += 1;
    }

    pub fn copy(h: *Histogram, len: u32, dist_code: u32) void {
        h.green[256 + prefix(len).symbol] += 1;
        h.dist[prefix(dist_code).symbol] += 1;
    }

    /// The five codes' histograms, in group order.
    pub fn parts(h: *const Histogram, green_size: usize) [5][]const u32 {
        return .{ h.green[0..green_size], &h.red, &h.blue, &h.alpha, &h.dist };
    }
};

/// A length or distance code value split into its prefix symbol and extra
/// bits (section 3.6.2.2).
pub const Prefix = struct { symbol: u32, bits: u32, extra: u32 };

/// The extra bits after length or distance prefix symbol `symbol`.
pub inline fn extraBits(symbol: u32) u32 {
    return if (symbol < 4) 0 else (symbol - 2) >> 1;
}

pub inline fn prefix(value: u32) Prefix {
    if (value <= 4) return .{ .symbol = value - 1, .bits = 0, .extra = 0 };
    const v = value - 1;
    const high: u32 = 31 - @clz(v);
    const second = (v >> @intCast(high - 1)) & 1;
    const bits = high - 1;
    return .{ .symbol = 2 * high + second, .bits = bits, .extra = v & ((@as(u32, 1) << @intCast(bits)) - 1) };
}

/// The five prefix codes of one group: each symbol's length as written
/// and its code, bit-reversed for writing.
pub const Group = struct {
    lens: [all_symbols]u8,
    codes: [all_symbols]u16,
    green_size: u16,
    /// A code with one symbol (or none) takes no bits for it.
    single: [5]bool,

    pub inline fn emit(g: *const Group, bw: anytype, comptime k: usize, sym: usize) void {
        if (g.single[k]) return;
        const i = offsets[k] + sym;
        bw.put(g.codes[i], g.lens[i]);
    }

    pub fn lengths(g: *const Group, k: usize) []const u8 {
        const n: usize = if (k == 0) g.green_size else if (k == 4) 40 else 256;
        return g.lens[offsets[k]..][0..n];
    }

    /// Builds the codes from `h`, green's alphabet being `green_size`.
    pub fn build(g: *Group, h: *const Histogram, green_size: usize, s: *Scratch) void {
        g.green_size = @intCast(green_size);
        for (h.parts(green_size), 0..) |counts, k| {
            const lens = g.lens[offsets[k]..][0..counts.len];
            const codes = g.codes[offsets[k]..][0..counts.len];
            g.single[k] = buildLengths(counts, 15, lens, s) <= 1;
            assignCodes(lens, codes);
        }
    }

    /// The bits the symbols counted in `h` take with these codes, extra
    /// bits included.
    pub fn dataBits(g: *const Group, h: *const Histogram) u64 {
        var bits: u64 = 0;
        for (h.parts(g.green_size), 0..) |counts, k| {
            const base = offsets[k];
            for (counts, 0..) |c, sym| {
                if (c == 0) continue;
                var per: u64 = if (g.single[k]) 0 else g.lens[base + sym];
                if (k == 0 and sym >= 256 and sym < green_base) per += extraBits(@intCast(sym - 256));
                if (k == 4) per += extraBits(@intCast(sym));
                bits += c * per;
            }
        }
        return bits;
    }

    /// Writes the five codes.
    pub fn write(g: *const Group, bw: anytype, s: *Scratch) void {
        for (0..5) |k| writeCode(bw, g.lengths(k), s);
    }
};

/// Space for building and writing codes, so none of it is on the stack.
pub const Scratch = struct {
    sorted: [max_green]u64,
    /// The radix sort's other buffer.
    spare: [max_green]u64,
    weight: [2 * max_green]u64,
    parent: [2 * max_green]u16,
    depth: [2 * max_green]u8,
    tokens: [max_green]u8,
    extra: [max_green]u8,
};

/// Fills `lens` with prefix code lengths of at most `limit` bits for
/// `counts`, a complete code when two or more symbols occur. Returns how
/// many symbols occur; a lone symbol gets length 1, and none, all zeros.
pub fn buildLengths(counts: []const u32, limit: u5, lens: []u8, s: *Scratch) usize {
    @memset(lens, 0);
    var n: usize = 0;
    for (counts, 0..) |c, i| {
        if (c == 0) continue;
        s.sorted[n] = @as(u64, c) << 16 | i;
        n += 1;
    }
    if (n == 0) return 0;
    if (n == 1) {
        lens[@as(u16, @truncate(s.sorted[0]))] = 1;
        return 1;
    }
    sortKeys(s.sorted[0..n], s.spare[0..n]);
    // Huffman's algorithm with two queues: the leaves in order, and the
    // internal nodes in the order they are made, which is also by weight.
    // Nodes 0..n are the leaves, n.. the internal nodes.
    const weight = &s.weight;
    for (0..n) |i| weight[i] = s.sorted[i] >> 16;
    var leaf: usize = 0;
    var node: usize = n;
    var next: usize = n;
    while (next < 2 * n - 1) : (next += 1) {
        var pick: [2]usize = undefined;
        for (&pick) |*p| {
            if (leaf < n and (node >= next or weight[leaf] <= weight[node])) {
                p.* = leaf;
                leaf += 1;
            } else {
                p.* = node;
                node += 1;
            }
        }
        weight[next] = weight[pick[0]] + weight[pick[1]];
        s.parent[pick[0]] = @intCast(next);
        s.parent[pick[1]] = @intCast(next);
    }
    const root = 2 * n - 2;
    s.depth[root] = 0;
    var bl_count: [64]u32 = @splat(0);
    var i = root;
    while (i > 0) {
        i -= 1;
        s.depth[i] = s.depth[s.parent[i]] + 1;
        if (i < n) bl_count[s.depth[i]] += 1;
    }
    // Lengths past the limit: move leaves up, keeping the code complete
    // (the method of JPEG's Annex K.3).
    var l: usize = 63;
    while (l > limit) : (l -= 1) {
        while (bl_count[l] > 0) {
            var j = l - 2;
            while (bl_count[j] == 0) j -= 1;
            bl_count[l] -= 2;
            bl_count[l - 1] += 1;
            bl_count[j + 1] += 2;
            bl_count[j] -= 1;
        }
    }
    // The longest codes to the rarest symbols.
    var k: usize = 0;
    l = limit;
    while (l > 0) : (l -= 1) {
        for (0..bl_count[l]) |_| {
            lens[@as(u16, @truncate(s.sorted[k]))] = @intCast(l);
            k += 1;
        }
    }
    return n;
}

/// Sorts `keys` ascending, by bytes from the lowest (a radix sort), with
/// `spare` as the other buffer; bytes every key shares are skipped. Not
/// `std.sort.pdq`: LLVM widens its pivot selection to 512-bit vectors, and
/// this host lowers its clock after any (docs/slop/plan.md, the WebP
/// decode performance pass). The keys are distinct, so any sort orders
/// them the same.
fn sortKeys(keys: []u64, spare: []u64) void {
    var all_or: u64 = 0;
    var all_and: u64 = std.math.maxInt(u64);
    for (keys) |k| {
        all_or |= k;
        all_and &= k;
    }
    var from = keys;
    var to = spare;
    var shift: u6 = 0;
    while (true) : (shift += 8) {
        if (@as(u8, @truncate((all_or ^ all_and) >> shift)) != 0) {
            var at: [256]u32 = @splat(0);
            for (from) |k| at[@as(u8, @truncate(k >> shift))] += 1;
            var sum: u32 = 0;
            for (&at) |*c| {
                const n = c.*;
                c.* = sum;
                sum += n;
            }
            for (from) |k| {
                const d: u8 = @truncate(k >> shift);
                to[at[d]] = k;
                at[d] += 1;
            }
            std.mem.swap([]u64, &from, &to);
        }
        if (shift == 56) break;
    }
    if (from.ptr != keys.ptr) @memcpy(keys, from);
}

/// Canonical codes for `lens`, bit-reversed.
pub fn assignCodes(lens: []const u8, codes: []u16) void {
    var count: [16]u16 = @splat(0);
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var next: [16]u16 = undefined;
    var code: u16 = 0;
    for (1..16) |l| {
        code = (code + count[l - 1]) << 1;
        next[l] = code;
    }
    for (lens, codes) |l, *c| {
        if (l == 0) {
            c.* = 0;
            continue;
        }
        c.* = @bitReverse(next[l]) >> @intCast(16 - @as(u32, l));
        next[l] += 1;
    }
}

const code_length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// Writes one prefix code with lengths `lens` (section 3.7.2.1): the
/// simple form for at most two symbols below 256, the normal one
/// otherwise. A code with no symbols is written as one symbol, 0.
pub fn writeCode(bw: anytype, lens: []const u8, s: *Scratch) void {
    var syms: [2]usize = .{ 0, 0 };
    var n: usize = 0;
    for (lens, 0..) |l, i| {
        if (l == 0) continue;
        if (n < 2) syms[n] = i;
        n += 1;
        if (n > 2) break;
    }
    if (n <= 2 and syms[0] < 256 and syms[1] < 256) {
        bw.put(1, 1);
        bw.put(@intCast(@max(n, 1) - 1), 1);
        if (syms[0] < 2) {
            bw.put(0, 1);
            bw.put(@intCast(syms[0]), 1);
        } else {
            bw.put(1, 1);
            bw.put(@intCast(syms[0]), 8);
        }
        if (n == 2) bw.put(@intCast(syms[1]), 8);
        return;
    }
    bw.put(0, 1);
    // The lengths as code-length symbols: 0 to 15 for a length, 16 to
    // repeat the last nonzero length (8 at first) 3 to 6 times, 17 and 18
    // for runs of 3 to 10 and 11 to 138 zeros.
    var t: usize = 0;
    var prev: u8 = 8;
    var i: usize = 0;
    // Tokens before the zeros that end the alphabet.
    var t_used: usize = 0;
    while (i < lens.len) {
        const v = lens[i];
        var run: usize = 1;
        while (i + run < lens.len and lens[i + run] == v) run += 1;
        var r = run;
        if (v == 0) {
            while (r >= 11) {
                const k = @min(r, 138);
                s.tokens[t] = 18;
                s.extra[t] = @intCast(k - 11);
                t += 1;
                r -= k;
            }
            if (r >= 3) {
                s.tokens[t] = 17;
                s.extra[t] = @intCast(r - 3);
                t += 1;
                r = 0;
            }
            while (r > 0) : (r -= 1) {
                s.tokens[t] = 0;
                t += 1;
            }
        } else {
            if (v != prev) {
                s.tokens[t] = v;
                t += 1;
                r -= 1;
                prev = v;
            }
            while (r >= 3) {
                const k = @min(r, 6);
                s.tokens[t] = 16;
                s.extra[t] = @intCast(k - 3);
                t += 1;
                r -= k;
            }
            while (r > 0) : (r -= 1) {
                s.tokens[t] = v;
                t += 1;
            }
            t_used = t;
        }
        i += run;
    }
    // Either every symbol's length, or only those through the last used
    // one, counted as tokens (max_symbol), whichever is shorter.
    const full = lengthCodeCost(s, t, false);
    const trimmed = if (t_used >= 2 and t_used < t) lengthCodeCost(s, t_used, true) else std.math.maxInt(u64);
    const use_max = trimmed < full;
    const count = if (use_max) t_used else t;
    var hist: [19]u32 = @splat(0);
    for (s.tokens[0..count]) |tok| hist[tok] += 1;
    var cl_lens: [19]u8 = undefined;
    var cl_codes: [19]u16 = undefined;
    // Building a code touches neither `tokens` nor `extra`.
    const used = buildLengths(&hist, 7, &cl_lens, s);
    assignCodes(&cl_lens, &cl_codes);
    var num: usize = 19;
    while (num > 4 and cl_lens[code_length_order[num - 1]] == 0) num -= 1;
    bw.put(@intCast(num - 4), 4);
    for (code_length_order[0..num]) |c| bw.put(cl_lens[c], 3);
    if (use_max) {
        bw.put(1, 1);
        const k = maxSymbolBits(count);
        bw.put(@intCast(k), 3);
        bw.put(@intCast(count - 2), 2 + 2 * k);
    } else {
        bw.put(0, 1);
    }
    for (s.tokens[0..count], s.extra[0..count]) |tok, e| {
        if (used > 1) bw.put(cl_codes[tok], cl_lens[tok]);
        switch (tok) {
            16 => bw.put(e, 2),
            17 => bw.put(e, 3),
            18 => bw.put(e, 7),
            else => {},
        }
    }
}

/// The 3-bit field `k` that sizes max_symbol's field, 2 + 2k bits.
fn maxSymbolBits(count: usize) u32 {
    var k: u32 = 0;
    while (count - 2 >= @as(usize, 1) << @intCast(2 + 2 * k)) k += 1;
    return k;
}

/// Bits to write the first `count` code-length tokens with their own code.
fn lengthCodeCost(s: *Scratch, count: usize, use_max: bool) u64 {
    // Each count is at most `count`, a token per symbol at most, so the
    // counts fit 16 bits, and so does the sum of their lengths, at most 7
    // bits each: summed in 16 lanes of 16 bits, which keeps the sum out of
    // 512-bit vectors (see `sortKeys`).
    comptime std.debug.assert(max_green * 7 < 1 << 16);
    std.debug.assert(count <= max_green);
    var hist: [19]u32 = @splat(0);
    var hist16: [19]u16 = @splat(0);
    for (s.tokens[0..count]) |tok| {
        hist[tok] += 1;
        hist16[tok] += 1;
    }
    var cl_lens: [19]u8 = undefined;
    const used = buildLengths(&hist, 7, &cl_lens, s);
    var num: usize = 19;
    while (num > 4 and cl_lens[code_length_order[num - 1]] == 0) num -= 1;
    var bits: u64 = 4 + 3 * num + 1;
    if (use_max) bits += 3 + 2 + 2 * maxSymbolBits(count);
    if (used > 1) {
        const V = @Vector(16, u16);
        const h: V = hist16[0..16].*;
        const l: V = @as(@Vector(16, u8), cl_lens[0..16].*);
        bits += @reduce(.Add, h * l);
        for (16..19) |tok| bits += @as(u64, hist[tok]) * cl_lens[tok];
    }
    return bits + 2 * @as(u64, hist[16]) + 3 * @as(u64, hist[17]) + 7 * @as(u64, hist[18]);
}

test prefix {
    // Every value round-trips through the decoder's arithmetic.
    var v: u32 = 1;
    while (v < 1 << 20) : (v += 1 + v / 64) {
        const p = prefix(v);
        const back = if (p.symbol < 4) p.symbol + 1 else blk: {
            const extra = (p.symbol - 2) >> 1;
            try testing.expectEqual(extra, p.bits);
            break :blk ((2 + (p.symbol & 1)) << @intCast(extra)) + p.extra + 1;
        };
        try testing.expectEqual(v, back);
    }
    try testing.expectEqual(23, prefix(4096).symbol);
    try testing.expectEqual(39, prefix(1 << 20).symbol);
}

test buildLengths {
    var s: Scratch = undefined;
    var lens: [8]u8 = undefined;
    // Fibonacci weights make a deep tree: limited to 4 bits, the code must
    // stay complete.
    const counts = [8]u32{ 1, 1, 2, 3, 5, 8, 13, 21 };
    try testing.expectEqual(8, buildLengths(&counts, 4, &lens, &s));
    var kraft: u32 = 0;
    for (lens) |l| {
        try testing.expect(l >= 1 and l <= 4);
        kraft += @as(u32, 16) >> @intCast(l);
    }
    try testing.expectEqual(16, kraft);
    try testing.expect(lens[7] <= lens[0]);
    // Unlimited, the same weights give depths 7, 7, 6, 5, 4, 3, 2, 1.
    _ = buildLengths(&counts, 15, &lens, &s);
    try testing.expectEqualSlices(u8, &.{ 7, 7, 6, 5, 4, 3, 2, 1 }, &lens);
    try testing.expectEqual(1, buildLengths(&.{ 0, 9, 0 }, 15, lens[0..3], &s));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0 }, lens[0..3]);
}

test assignCodes {
    // Lengths 2, 1, 3, 3: canonical codes 10, 0, 110, 111, bit-reversed.
    var codes: [4]u16 = undefined;
    assignCodes(&.{ 2, 1, 3, 3 }, &codes);
    try testing.expectEqualSlices(u16, &.{ 0b01, 0b0, 0b011, 0b111 }, &codes);
}
