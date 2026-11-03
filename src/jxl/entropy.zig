//! Entropy decoding (ISO/IEC 18181-1, Annex on entropy coding): hybrid
//! integers over symbols from either an ANS code with alias tables or a
//! prefix code in Brotli's format, clustered contexts through a context
//! map, and optional LZ77 with the special distances of 2D image data.
//!
//! `Code.read` reads the histograms for a number of contexts; `Reader`
//! decodes symbols from them. Tables live in the caller's `Arena`.

const std = @import("std");
const vfill = @import("../fill.zig").fill;
const testing = std.testing;

const BitReader = @import("BitReader.zig");
const Arena = @import("Arena.zig");

pub const Error = BitReader.Error || Arena.Error || error{
    /// The entropy code is malformed: an invalid histogram, prefix code,
    /// context map, or hybrid integer configuration, or an ANS stream
    /// whose final state is wrong.
    BadEntropy,
};

pub const log_tab_size = 12;
pub const tab_size = 1 << log_tab_size;
const prefix_max_bits = 15;
const root_bits = 8;
pub const max_clusters = 256;
/// The LZ77 window, in symbols.
pub const window_size = 1 << 20;

pub const UintConfig = struct {
    split_exp: u8,
    msb: u8,
    lsb: u8,
    split: u32,

    fn read(br: *BitReader, log_alpha: u32) Error!UintConfig {
        const split_exp = try br.bits(ceilLog2(log_alpha + 1));
        var msb: u32 = 0;
        var lsb: u32 = 0;
        if (split_exp != log_alpha) {
            msb = try br.bits(ceilLog2(split_exp + 1));
            if (msb > split_exp) return error.BadEntropy;
            lsb = try br.bits(ceilLog2(split_exp - msb + 1));
        }
        if (msb + lsb > split_exp) return error.BadEntropy;
        return .{
            .split_exp = @intCast(split_exp),
            .msb = @intCast(msb),
            .lsb = @intCast(lsb),
            .split = @as(u32, 1) << @intCast(split_exp),
        };
    }

    /// The integer `token` and its extra bits stand for.
    pub inline fn value(c: UintConfig, token: u32, br: *BitReader) Error!u32 {
        if (token < c.split) return token;
        const ml: u5 = @intCast(c.msb + c.lsb);
        var nbits: u32 = c.split_exp - @as(u32, ml) + ((token - c.split) >> ml);
        nbits &= 31;
        const low = token & ((@as(u32, 1) << @intCast(c.lsb)) - 1);
        const t = token >> @intCast(c.lsb);
        const extra: u64 = try br.bits(@intCast(nbits));
        const top: u64 = (@as(u64, 1) << @intCast(c.msb)) | (t & ((@as(u32, 1) << @intCast(c.msb)) - 1));
        const ret = (((top << @intCast(nbits)) | extra) << @intCast(c.lsb)) | low;
        return @truncate(ret);
    }
};

fn ceilLog2(x: u32) u6 {
    std.debug.assert(x > 0);
    return @intCast(32 - @clz(x - 1));
}

const Lz77 = struct {
    enabled: bool = false,
    min_symbol: u32 = 224,
    min_length: u32 = 3,
    len_config: UintConfig = undefined,
};

/// One bucket of an alias table.
pub const Alias = struct {
    cutoff: u16,
    right: u16,
    /// The offset of the right part, minus the cutoff.
    offset: u16,
    freq0: u16,
    freq1: u16,
};

/// A prefix-code table entry: the symbol, and the bits it takes (or the
/// second-level table's width and offset, when over `root_bits`).
const Huff = packed struct(u32) {
    value: u16,
    bits: u8,
    _pad: u8 = 0,
};

pub const Code = struct {
    lz77: Lz77 = .{},
    context_map: []u8,
    num_clusters: u32,
    use_prefix: bool,
    log_alpha: u5,
    configs: []UintConfig,
    alias: []Alias = &.{},
    /// Each cluster's prefix table starts at `huff_start[cluster]`.
    huff: []Huff = &.{},
    huff_start: []u32 = &.{},
    /// Per cluster, the one symbol an ANS histogram can produce, or -1
    /// (always -1 for prefix codes).
    single: []i32 = &.{},

    /// Reads the histograms for `num_contexts` contexts.
    pub fn read(br: *BitReader, arena: *Arena, num_contexts_in: usize) Error!Code {
        return readImpl(br, arena, num_contexts_in, false);
    }

    fn readImpl(br: *BitReader, arena: *Arena, num_contexts_in: usize, disallow_lz77: bool) Error!Code {
        var lz77: Lz77 = .{};
        var num_contexts = num_contexts_in;
        lz77.enabled = try br.boolean();
        if (lz77.enabled) {
            lz77.min_symbol = try br.u32Dist(.{ .v(224), .v(512), .v(4096), .bo(15, 8) });
            lz77.min_length = try br.u32Dist(.{ .v(3), .v(4), .bo(2, 5), .bo(8, 9) });
            num_contexts += 1;
            lz77.len_config = try .read(br, 8);
            if (disallow_lz77) return error.BadEntropy;
        }
        const context_map = try arena.alloc(u8, num_contexts);
        var num_clusters: u32 = 1;
        if (num_contexts > 1) {
            num_clusters = try readContextMap(br, arena, context_map);
        } else {
            context_map[0] = 0;
        }
        var code: Code = .{
            .lz77 = lz77,
            .context_map = context_map,
            .num_clusters = num_clusters,
            .use_prefix = try br.boolean(),
            .log_alpha = undefined,
            .configs = try arena.alloc(UintConfig, num_clusters),
        };
        code.log_alpha = if (code.use_prefix) prefix_max_bits else @intCast(5 + try br.bits(2));
        for (code.configs) |*c| c.* = try .read(br, code.log_alpha);
        if (code.use_prefix) {
            try code.readPrefixCodes(br, arena);
        } else {
            code.alias = try arena.alloc(Alias, @as(usize, num_clusters) << code.log_alpha);
            code.single = try arena.alloc(i32, num_clusters);
            for (0..num_clusters) |c| {
                var counts: [tab_size + 512]u16 = undefined;
                const len = try readHistogram(br, &counts);
                if (len > @as(usize, 1) << code.log_alpha) return error.BadEntropy;
                var n = len;
                while (n > 0 and counts[n - 1] == 0) n -= 1;
                code.single[c] = if (n == 0) 0 else @intCast(n - 1);
                for (counts[0..n -| 1]) |k| {
                    if (k != 0) code.single[c] = -1;
                }
                const table_len = @as(usize, 1) << code.log_alpha;
                initAlias(counts[0..len], code.log_alpha, code.alias[c << code.log_alpha ..][0..table_len]);
            }
        }
        return code;
    }

    fn readPrefixCodes(code: *Code, br: *BitReader, arena: *Arena) Error!void {
        const n = code.num_clusters;
        var sizes: [max_clusters]u32 = undefined;
        var total: usize = 0;
        for (sizes[0..n]) |*s| {
            s.* = 1;
            if (try br.boolean()) {
                const nbits = try br.bits(4);
                s.* = if (nbits == 0) 2 else 1 + (@as(u32, 1) << @intCast(nbits)) + try br.bits(@intCast(nbits));
            }
            if (s.* > 1 << prefix_max_bits) return error.BadEntropy;
            total += if (s.* > 1) s.* + 376 else 1 << root_bits;
        }
        code.huff_start = try arena.alloc(u32, n);
        const table = try arena.alloc(Huff, total);
        var at: usize = 0;
        const m = arena.mark();
        const lengths = try arena.alloc(u8, 1 << prefix_max_bits);
        for (sizes[0..n], 0..) |s, c| {
            code.huff_start[c] = @intCast(at);
            if (s == 1) {
                @memset(table[at..][0 .. 1 << root_bits], .{ .value = 0, .bits = 0 });
                at += 1 << root_bits;
                continue;
            }
            at += try readPrefixCode(br, s, lengths[0..s], table[at..]);
        }
        arena.release(m);
        code.huff = table[0..at];
    }
};

/// Brotli's variable-length 8-bit integer: 0, or 2^n plus n bits.
fn readU8(br: *BitReader) Error!u32 {
    if (!try br.boolean()) return 0;
    const n = try br.bits(3);
    if (n == 0) return 1;
    return (@as(u32, 1) << @intCast(n)) + try br.bits(@intCast(n));
}

/// The prefix code for an ANS histogram's log-counts: 7 bits peeked, the
/// bits used, and the value (13 is the run-length symbol).
const logcount_lut = blk: {
    const codes = [_]struct { code: u8, len: u8, value: u8 }{
        .{ .code = 0b000, .len = 3, .value = 10 },
        .{ .code = 0b010, .len = 3, .value = 7 },
        .{ .code = 0b100, .len = 3, .value = 6 },
        .{ .code = 0b101, .len = 3, .value = 8 },
        .{ .code = 0b110, .len = 3, .value = 9 },
        .{ .code = 0b0011, .len = 4, .value = 3 },
        .{ .code = 0b0111, .len = 4, .value = 5 },
        .{ .code = 0b1001, .len = 4, .value = 4 },
        .{ .code = 0b1011, .len = 4, .value = 1 },
        .{ .code = 0b1111, .len = 4, .value = 2 },
        .{ .code = 0b10001, .len = 5, .value = 0 },
        .{ .code = 0b100001, .len = 6, .value = 11 },
        .{ .code = 0b0000001, .len = 7, .value = 12 },
        .{ .code = 0b1000001, .len = 7, .value = 13 },
    };
    @setEvalBranchQuota(10000);
    var lut: [128][2]u8 = undefined;
    for (0..128) |i| {
        for (codes) |c| {
            if (i & ((1 << c.len) - 1) == c.code) lut[i] = .{ c.len, c.value };
        }
    }
    break :blk lut;
};

/// Reads one ANS histogram into `counts`, summing to 4096, and returns
/// its length (trailing zeros included, as read).
fn readHistogram(br: *BitReader, counts: *[tab_size + 512]u16) Error!usize {
    if (try br.boolean()) {
        // Simple: one or two symbols.
        const two = try br.boolean();
        const s0 = try readU8(br);
        if (!two) {
            @memset(counts[0 .. s0 + 1], 0);
            counts[s0] = tab_size;
            return s0 + 1;
        }
        const s1 = try readU8(br);
        if (s0 == s1) return error.BadEntropy;
        const len = @max(s0, s1) + 1;
        @memset(counts[0..len], 0);
        counts[s0] = @intCast(try br.bits(log_tab_size));
        counts[s1] = tab_size - counts[s0];
        return len;
    }
    if (try br.boolean()) {
        // Flat.
        const n = try readU8(br) + 1;
        for (0..n) |i| counts[i] = @intCast(tab_size / n + @intFromBool(i < tab_size % n));
        return n;
    }
    var log: u32 = 0;
    while (log < 3) : (log += 1) {
        if (!try br.boolean()) break;
    }
    const shift = (try br.bits(@intCast(log)) | (@as(u32, 1) << @intCast(log))) - 1;
    if (shift > log_tab_size + 1) return error.BadEntropy;
    const len = try readU8(br) + 3;
    var logcounts: [258]i8 = @splat(0);
    var same: [258]u16 = @splat(0);
    var omit_log: i32 = -1;
    var omit_pos: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const e = logcount_lut[try br.peek(7)];
        br.consume(@intCast(e[0]));
        logcounts[i] = @as(i8, @intCast(e[1])) - 1;
        if (logcounts[i] == log_tab_size) {
            const rle = try readU8(br);
            same[i] = @intCast(rle + 5);
            i += rle + 3;
            continue;
        }
        if (logcounts[i] > omit_log) {
            omit_log = logcounts[i];
            omit_pos = i;
        }
    }
    if (omit_log < 0) return error.BadEntropy;
    if (omit_pos + 1 < len and logcounts[omit_pos + 1] == log_tab_size) return error.BadEntropy;
    var total: u32 = 0;
    var prev: u16 = 0;
    var numsame: u32 = 0;
    for (0..len) |k| {
        if (same[k] != 0) {
            numsame = same[k] - 1;
            prev = if (k > 0) counts[k - 1] else 0;
        }
        if (numsame > 0) {
            counts[k] = prev;
            numsame -= 1;
        } else {
            const code = logcounts[k];
            counts[k] = 0;
            if (k == omit_pos or code < 0) {
                continue;
            } else if (shift == 0 or code == 0) {
                counts[k] = @as(u16, 1) << @intCast(code);
            } else {
                const c: u32 = @intCast(code);
                const want = @as(i32, @intCast(shift)) - ((log_tab_size - @as(i32, code)) >> 1);
                const bitcount: u32 = @intCast(std.math.clamp(want, 0, code));
                const extra = try br.bits(@intCast(bitcount));
                counts[k] = @intCast((@as(u32, 1) << @intCast(c)) + (extra << @intCast(c - bitcount)));
            }
        }
        total += counts[k];
    }
    if (total >= tab_size) return error.BadEntropy;
    counts[omit_pos] = @intCast(tab_size - total);
    return len;
}

/// Builds the alias table of `counts` (summing to 4096) for an alphabet
/// of 2^`log_alpha` symbols.
pub fn initAlias(counts_in: []const u16, log_alpha: u5, table: []Alias) void {
    var counts = counts_in;
    while (counts.len > 0 and counts[counts.len - 1] == 0) counts = counts[0 .. counts.len - 1];
    const one = [1]u16{tab_size};
    if (counts.len == 0) counts = &one;
    const n = table.len;
    const entry_size: u32 = @as(u32, tab_size) >> log_alpha;
    for (counts, 0..) |c, s| {
        if (c == tab_size) {
            for (table, 0..) |*e, i| e.* = .{
                .cutoff = 0,
                .right = @intCast(s),
                .offset = @intCast(entry_size * i),
                .freq0 = 0,
                .freq1 = tab_size,
            };
            return;
        }
    }
    var cutoffs: [256]u32 = undefined;
    var under: [256]u16 = undefined;
    var over: [256]u16 = undefined;
    var nu: usize = 0;
    var no: usize = 0;
    for (0..n) |i| {
        cutoffs[i] = if (i < counts.len) counts[i] else 0;
        table[i] = .{ .cutoff = 0, .right = 0, .offset = 0, .freq0 = 0, .freq1 = 0 };
        if (cutoffs[i] > entry_size) {
            over[no] = @intCast(i);
            no += 1;
        } else if (cutoffs[i] < entry_size) {
            under[nu] = @intCast(i);
            nu += 1;
        }
    }
    while (no > 0) {
        no -= 1;
        const o = over[no];
        nu -= 1;
        const u = under[nu];
        const by = entry_size - cutoffs[u];
        cutoffs[o] -= by;
        table[u].right = o;
        table[u].offset = @intCast(cutoffs[o]);
        if (cutoffs[o] < entry_size) {
            under[nu] = o;
            nu += 1;
        } else if (cutoffs[o] > entry_size) {
            over[no] = o;
            no += 1;
        }
    }
    for (0..n) |i| {
        if (cutoffs[i] == entry_size) {
            table[i].right = @intCast(i);
            table[i].offset = 0;
            table[i].cutoff = 0;
        } else {
            table[i].offset -%= @intCast(cutoffs[i]);
            table[i].cutoff = @intCast(cutoffs[i]);
        }
        table[i].freq0 = if (i < counts.len) counts[i] else 0;
        const r = table[i].right;
        table[i].freq1 = if (r < counts.len) counts[r] else 0;
    }
}

/// Reads a context map for `map.len` contexts and returns the number of
/// clusters.
/// Reads a context map into `map` and returns the number of clusters.
pub fn readContextMap(br: *BitReader, arena: *Arena, map: []u8) Error!u32 {
    if (try br.boolean()) {
        const nbits = try br.bits(2);
        // Zero bits a context is a fill, of up to 7 KB.
        if (nbits == 0) vfill(u8, map, 0) else for (map) |*e| e.* = @intCast(try br.bits(@intCast(nbits)));
    } else {
        const use_mtf = try br.boolean();
        const m = arena.mark();
        defer arena.release(m);
        const code = try Code.readImpl(br, arena, 1, map.len <= 2);
        var r = try Reader.init(&code, br, arena, 0, map.len);
        var maxsym: u32 = 0;
        for (map) |*e| {
            const s = try r.read(br, 0);
            maxsym = @max(maxsym, s);
            e.* = @truncate(s);
        }
        if (maxsym >= max_clusters) return error.BadEntropy;
        if (!r.finalOk()) return error.BadEntropy;
        if (use_mtf) inverseMtf(map);
    }
    var seen: [max_clusters]bool = @splat(false);
    var max: u32 = 0;
    for (map) |e| {
        seen[e] = true;
        max = @max(max, e);
    }
    for (seen[0 .. max + 1]) |s| if (!s) return error.BadEntropy;
    return max + 1;
}

fn inverseMtf(v: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*m, i| m.* = @intCast(i);
    for (v) |*e| {
        const idx = e.*;
        const val = mtf[idx];
        e.* = val;
        @memmove(mtf[1 .. @as(usize, idx) + 1], mtf[0..idx]);
        mtf[0] = val;
    }
}

/// Reads a prefix code over `alphabet` symbols into `table` and returns the
/// entries used. `lengths` is scratch of `alphabet` bytes.
fn readPrefixCode(br: *BitReader, alphabet: u32, lengths: []u8, table: []Huff) Error!usize {
    const hskip = try br.bits(2);
    if (hskip == 1) return readSimplePrefix(br, alphabet, table);
    const order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    // The fixed code for code length code lengths: 4 bits peeked.
    const lut = [16][2]u8{
        .{ 2, 0 }, .{ 2, 4 }, .{ 2, 3 }, .{ 3, 2 }, .{ 2, 0 }, .{ 2, 4 }, .{ 2, 3 }, .{ 4, 1 },
        .{ 2, 0 }, .{ 2, 4 }, .{ 2, 3 }, .{ 3, 2 }, .{ 2, 0 }, .{ 2, 4 }, .{ 2, 3 }, .{ 4, 5 },
    };
    var cl_lengths: [18]u8 = @splat(0);
    var space: i32 = 32;
    var num_codes: u32 = 0;
    var i: usize = hskip;
    while (i < 18 and space > 0) : (i += 1) {
        const e = lut[try br.peek(4)];
        br.consume(@intCast(e[0]));
        cl_lengths[order[i]] = e[1];
        if (e[1] != 0) {
            space -= @as(i32, 32) >> @intCast(e[1]);
            num_codes += 1;
        }
    }
    if (!(num_codes == 1 or space == 0)) return error.BadEntropy;
    var cl_table: [32]Huff = undefined;
    if (buildTable(&cl_table, 5, &cl_lengths) == 0) return error.BadEntropy;

    // The symbols' code lengths, with Brotli's repeat codes.
    var symbol: u32 = 0;
    var prev_len: u8 = 8;
    var repeat: u32 = 0;
    var repeat_len: u8 = 0;
    var left: i32 = 32768;
    while (symbol < alphabet and left > 0) {
        const e = cl_table[try br.peek(5)];
        br.consume(@intCast(e.bits));
        const len: u8 = @intCast(e.value);
        if (len < 16) {
            repeat = 0;
            lengths[symbol] = len;
            symbol += 1;
            if (len != 0) {
                prev_len = len;
                left -= @as(i32, 32768) >> @intCast(len);
            }
        } else {
            const extra: u5 = @intCast(len - 14);
            const new_len: u8 = if (len == 16) prev_len else 0;
            if (repeat_len != new_len) {
                repeat = 0;
                repeat_len = new_len;
            }
            const old = repeat;
            if (repeat > 0) {
                repeat -= 2;
                repeat <<= extra;
            }
            repeat += try br.bits(extra) + 3;
            const delta = repeat - old;
            if (symbol + delta > alphabet) return error.BadEntropy;
            @memset(lengths[symbol..][0..delta], repeat_len);
            symbol += delta;
            if (repeat_len != 0) left -= @as(i32, @intCast(delta)) << @intCast(15 - repeat_len);
        }
    }
    if (left != 0) return error.BadEntropy;
    @memset(lengths[symbol..alphabet], 0);
    const n = buildTable(table, root_bits, lengths[0..alphabet]);
    if (n == 0) return error.BadEntropy;
    return n;
}

fn readSimplePrefix(br: *BitReader, alphabet: u32, table: []Huff) Error!usize {
    const max_bits: u6 = if (alphabet > 1) @intCast(32 - @clz(alphabet - 1)) else 0;
    var n = try br.bits(2) + 1;
    var s: [4]u16 = @splat(0);
    for (s[0..n]) |*x| {
        x.* = @intCast(try br.bits(max_bits));
        if (x.* >= alphabet) return error.BadEntropy;
    }
    for (0..n) |a| for (a + 1..n) |b| {
        if (s[a] == s[b]) return error.BadEntropy;
    };
    if (n == 4) n += try br.bits(1);
    var t: [8]Huff = undefined;
    var size: usize = 1;
    switch (n) {
        1 => t[0] = .{ .value = s[0], .bits = 0 },
        2 => {
            std.mem.sort(u16, s[0..2], {}, std.sort.asc(u16));
            t[0] = .{ .value = s[0], .bits = 1 };
            t[1] = .{ .value = s[1], .bits = 1 };
            size = 2;
        },
        3 => {
            std.mem.sort(u16, s[1..3], {}, std.sort.asc(u16));
            t[0] = .{ .value = s[0], .bits = 1 };
            t[2] = .{ .value = s[0], .bits = 1 };
            t[1] = .{ .value = s[1], .bits = 2 };
            t[3] = .{ .value = s[2], .bits = 2 };
            size = 4;
        },
        4 => {
            std.mem.sort(u16, s[0..4], {}, std.sort.asc(u16));
            t[0] = .{ .value = s[0], .bits = 2 };
            t[2] = .{ .value = s[1], .bits = 2 };
            t[1] = .{ .value = s[2], .bits = 2 };
            t[3] = .{ .value = s[3], .bits = 2 };
            size = 4;
        },
        else => {
            std.mem.sort(u16, s[2..4], {}, std.sort.asc(u16));
            t[0] = .{ .value = s[0], .bits = 1 };
            t[1] = .{ .value = s[1], .bits = 2 };
            t[2] = .{ .value = s[0], .bits = 1 };
            t[3] = .{ .value = s[2], .bits = 3 };
            t[4] = .{ .value = s[0], .bits = 1 };
            t[5] = .{ .value = s[1], .bits = 2 };
            t[6] = .{ .value = s[0], .bits = 1 };
            t[7] = .{ .value = s[3], .bits = 3 };
            size = 8;
        },
    }
    for (0..1 << root_bits) |i| table[i] = t[i % size];
    return 1 << root_bits;
}

/// The next code, bit-reversed, after `key` of `len` bits.
fn nextKey(key: u32, len: u32) u32 {
    var step = @as(u32, 1) << @intCast(len - 1);
    while (key & step != 0) step >>= 1;
    return (key & (step -% 1)) + step;
}

fn replicate(table: []Huff, step: u32, end_in: u32, h: Huff) void {
    var end = end_in;
    while (true) {
        end -= step;
        table[end] = h;
        if (end == 0) break;
    }
}

/// Builds a two-level decoding table for canonical code `lengths` with a
/// first level of `root` bits; returns its size, or 0 for an invalid code.
fn buildTable(table: []Huff, root: u5, lengths: []const u8) usize {
    var count: [prefix_max_bits + 1]u32 = @splat(0);
    for (lengths) |l| count[l] += 1;
    var offset: [prefix_max_bits + 1]u32 = undefined;
    var sum: u32 = 0;
    var max_len: u32 = 1;
    for (1..prefix_max_bits + 1) |len| {
        offset[len] = sum;
        if (count[len] != 0) {
            sum += count[len];
            max_len = @intCast(len);
        }
    }
    var sorted: [1 << prefix_max_bits]u16 = undefined;
    for (lengths, 0..) |l, s| {
        if (l != 0) {
            sorted[offset[l]] = @intCast(s);
            offset[l] += 1;
        }
    }
    var table_bits: u32 = root;
    var table_size: u32 = @as(u32, 1) << root;
    var total: u32 = table_size;
    if (offset[prefix_max_bits] == 1) {
        for (table[0..total]) |*e| e.* = .{ .value = sorted[0], .bits = 0 };
        return total;
    }
    if (table_bits > max_len) {
        table_bits = max_len;
        table_size = @as(u32, 1) << @intCast(table_bits);
    }
    var key: u32 = 0;
    var symbol: u32 = 0;
    var bits: u32 = 1;
    var step: u32 = 2;
    while (bits <= table_bits) : ({
        bits += 1;
        step <<= 1;
    }) {
        while (count[bits] != 0) : (count[bits] -= 1) {
            replicate(table[key..], step, table_size, .{ .value = sorted[symbol], .bits = @intCast(bits) });
            symbol += 1;
            key = nextKey(key, bits);
        }
    }
    while (total != table_size) {
        @memcpy(table[table_size..][0..table_size], table[0..table_size]);
        table_size <<= 1;
    }
    const mask = total - 1;
    var low: u32 = std.math.maxInt(u32);
    var sub: u32 = 0;
    var len: u32 = @as(u32, root) + 1;
    step = 2;
    while (len <= max_len) : ({
        len += 1;
        step <<= 1;
    }) {
        while (count[len] != 0) : (count[len] -= 1) {
            if (key & mask != low) {
                sub += table_size;
                // The next second-level table's width.
                var l = len;
                var left = @as(u32, 1) << @intCast(l - root);
                while (l < prefix_max_bits) {
                    if (left <= count[l]) break;
                    left -= count[l];
                    l += 1;
                    left <<= 1;
                }
                table_bits = l - root;
                table_size = @as(u32, 1) << @intCast(table_bits);
                total += table_size;
                if (total > table.len) return 0;
                low = key & mask;
                table[low] = .{ .value = @intCast(sub - low), .bits = @intCast(table_bits + root) };
            }
            const entry: Huff = .{ .value = sorted[symbol], .bits = @intCast(len - root) };
            replicate(table[sub + (key >> root) ..], step, table_size, entry);
            symbol += 1;
            key = nextKey(key, len);
        }
    }
    return total;
}

const special_distances = [120][2]i8{
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

/// Decodes symbols from a `Code`: the ANS state and the LZ77 window.
pub const Reader = struct {
    code: *const Code,
    state: u32,
    /// The LZ77 window (a power of two long), when LZ77 is on.
    window: []u32 = &.{},
    num_to_copy: u32 = 0,
    copy_pos: u32 = 0,
    num_decoded: u32 = 0,
    dist_multiplier: u32,

    /// Starts a stream. `max_symbols` bounds how many symbols it will
    /// decode, which sizes the LZ77 window.
    pub fn init(
        code: *const Code,
        br: *BitReader,
        arena: *Arena,
        dist_multiplier: u32,
        max_symbols: usize,
    ) Error!Reader {
        var r: Reader = .{
            .code = code,
            .state = if (code.use_prefix) 0x130000 else try br.bits(32),
            .dist_multiplier = dist_multiplier,
        };
        if (code.lz77.enabled) {
            const n = std.math.ceilPowerOfTwo(usize, @max(1, @min(max_symbols, window_size))) catch window_size;
            r.window = try arena.alloc(u32, n);
        }
        return r;
    }

    /// Whether the ANS state ended where the encoder started it.
    pub fn finalOk(r: *const Reader) bool {
        return r.state == 0x130000;
    }

    inline fn symbol(r: *Reader, br: *BitReader, cluster: u32) Error!u32 {
        const code = r.code;
        if (code.use_prefix) {
            const t = code.huff[code.huff_start[cluster]..];
            const idx = try br.peek(root_bits);
            var e = t[idx];
            if (e.bits > root_bits) {
                br.consume(root_bits);
                const n: u6 = @intCast(e.bits - root_bits);
                e = t[idx + @as(usize, e.value) + try br.peek(n)];
            }
            br.consume(@intCast(e.bits));
            return e.value;
        }
        const res = r.state & (tab_size - 1);
        const log_entry: u5 = @intCast(log_tab_size - @as(u32, code.log_alpha));
        const a = code.alias[(@as(usize, cluster) << code.log_alpha) + (res >> log_entry)];
        const pos = res & ((@as(u32, 1) << log_entry) - 1);
        var sym: u32 = undefined;
        var offset: u32 = undefined;
        var freq: u32 = undefined;
        if (pos >= a.cutoff) {
            sym = a.right;
            offset = @as(u32, a.offset) + pos;
            freq = a.freq1;
        } else {
            sym = res >> log_entry;
            offset = pos;
            freq = a.freq0;
        }
        r.state = freq * (r.state >> log_tab_size) + offset;
        if (r.state < 1 << 16) r.state = (r.state << 16) | try br.bits(16);
        return sym;
    }

    /// The value every one of the next `count` reads in context `ctx`
    /// would return, when its histogram has one symbol and no extra bits;
    /// then those reads are done. Null otherwise, and nothing is read.
    pub fn singleValue(r: *Reader, ctx: usize, count: usize) ?u32 {
        const code = r.code;
        if (code.use_prefix or r.num_to_copy != 0) return null;
        const cluster = code.context_map[ctx];
        const s = code.single[cluster];
        if (s < 0) return null;
        const v: u32 = @intCast(s);
        if (v >= code.configs[cluster].split) return null;
        if (code.lz77.enabled) {
            if (v >= code.lz77.min_symbol) return null;
            const mask = r.window.len - 1;
            const n = @min(count, r.window.len);
            for (0..n) |i| r.window[(r.num_decoded +% @as(u32, @intCast(count - n + i))) & mask] = v;
            r.num_decoded +%= @truncate(count);
        }
        return v;
    }

    /// Decodes the next integer in context `ctx`.
    pub fn read(r: *Reader, br: *BitReader, ctx: usize) Error!u32 {
        return r.readCluster(br, r.code.context_map[ctx]);
    }

    /// Decodes the next integer with `cluster`'s histogram.
    pub fn readCluster(r: *Reader, br: *BitReader, cluster: u32) Error!u32 {
        return r.readClusterInline(br, cluster);
    }

    /// `read`, inlined into a hot loop.
    pub inline fn readInline(r: *Reader, br: *BitReader, ctx: usize) Error!u32 {
        return r.readClusterInline(br, r.code.context_map[ctx]);
    }

    /// `readCluster`, inlined into a hot loop; an LZ77 match starts out of
    /// line.
    pub inline fn readClusterInline(r: *Reader, br: *BitReader, cluster: u32) Error!u32 {
        const code = r.code;
        if (r.num_to_copy > 0) return r.copy();
        const token = try r.symbol(br, cluster);
        if (code.lz77.enabled and token >= code.lz77.min_symbol) return r.match(br, token);
        const v = try code.configs[cluster].value(token, br);
        if (code.lz77.enabled) {
            r.window[r.num_decoded & (r.window.len - 1)] = v;
            r.num_decoded +%= 1;
        }
        return v;
    }

    /// Starts the LZ77 match that `token` begins, and returns its first
    /// value.
    fn match(r: *Reader, br: *BitReader, token: u32) Error!u32 {
        const code = r.code;
        const len = try code.lz77.len_config.value(token - code.lz77.min_symbol, br);
        r.num_to_copy = len +% code.lz77.min_length;
        const dctx = code.context_map[code.context_map.len - 1];
        const dtoken = try r.symbol(br, dctx);
        var distance: u64 = try code.configs[dctx].value(dtoken, br);
        if (r.dist_multiplier == 0) {
            distance += 1;
        } else if (distance < 120) {
            const sd = special_distances[@intCast(distance)];
            const d = @as(i64, sd[0]) + @as(i64, r.dist_multiplier) * sd[1];
            distance = @intCast(@max(1, d));
        } else {
            distance -= 119;
        }
        distance = @min(distance, r.num_decoded, window_size);
        r.copy_pos = r.num_decoded -% @as(u32, @intCast(distance));
        if (distance == 0) @memset(r.window[0..@min(r.window.len, r.num_to_copy)], 0);
        if (r.num_to_copy < code.lz77.min_length) {
            // The length wrapped: corrupt.
            return error.BadEntropy;
        }
        return r.copy();
    }

    inline fn copy(r: *Reader) u32 {
        const mask = r.window.len - 1;
        const v = r.window[r.copy_pos & mask];
        r.copy_pos +%= 1;
        r.num_to_copy -= 1;
        r.window[r.num_decoded & mask] = v;
        r.num_decoded +%= 1;
        return v;
    }
};

test "alias table single and flat" {
    var t: [32]Alias = undefined;
    var counts = [_]u16{ 0, tab_size };
    initAlias(&counts, 5, &t);
    try testing.expectEqual(@as(u16, 1), t[3].right);
    try testing.expectEqual(@as(u16, 3 * 128), t[3].offset);
    // Every value maps to a symbol whose frequency covers it once.
    var flat: [5]u16 = undefined;
    for (&flat, 0..) |*f, i| f.* = @intCast(@as(u32, tab_size / 5) + @intFromBool(i < tab_size % 5));
    initAlias(&flat, 5, &t);
    var hits: [5][tab_size]bool = @splat(@splat(false));
    for (0..tab_size) |x| {
        const a = t[x >> 7];
        const pos: u32 = @intCast(x & 127);
        const s: usize = if (pos >= a.cutoff) a.right else x >> 7;
        const off: u32 = if (pos >= a.cutoff) a.offset + pos else pos;
        try testing.expect(off < flat[s]);
        try testing.expect(!hits[s][off]);
        hits[s][off] = true;
    }
}

test "prefix table" {
    // Lengths 1, 2, 3, 3: codes 0, 10, 110, 111 (read most significant
    // first), so the LSB-first peek of 0b011 is symbol 2.
    const lengths = [_]u8{ 1, 2, 3, 3 };
    var table: [256 + 376]Huff = undefined;
    const n = buildTable(&table, root_bits, &lengths);
    try testing.expectEqual(@as(usize, 256), n);
    try testing.expectEqual(@as(u16, 0), table[0b000].value);
    try testing.expectEqual(@as(u16, 1), table[0b01].value);
    try testing.expectEqual(@as(u16, 2), table[0b011].value);
    try testing.expectEqual(@as(u16, 3), table[0b111].value);
    try testing.expectEqual(@as(u8, 3), table[0b111].bits);
}

test "hybrid uint" {
    // split_exponent 4, msb 1, lsb 1: token 16 is 16 + ...
    const c: UintConfig = .{ .split_exp = 4, .msb = 1, .lsb = 1, .split = 16 };
    var r: std.Io.Reader = .fixed(&.{ 0xff, 0x0a, 0b101, 0 });
    var br: BitReader = .init(&r, null);
    _ = try br.bits(16);
    try testing.expectEqual(@as(u32, 5), try c.value(5, &br));
    // token 16: nbits = 4 - 2 + 0 = 2; low = 0; msb part = 1|0 = 2 -> (2 << 2 | 0b01) << 1 = 18
    try testing.expectEqual(@as(u32, 18), try c.value(16, &br));
}

test "inverse mtf" {
    var v = [_]u8{ 1, 1, 0, 2 };
    inverseMtf(&v);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 2 }, &v);
}
