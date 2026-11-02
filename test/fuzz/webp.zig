//! The WebP fuzz target: the decoder properties in harness.zig, on mutated
//! corpus files and generated files: lossless bitstreams that reach every
//! transform, prefix code form, color cache size, entropy image, and
//! backward reference; lossy key frames with every header setting and
//! random macroblock data; and ALPH chunks, raw or lossless, with each
//! filter; inside simple and extended containers with metadata chunks.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "webp";

/// Seed directories, relative to the repository root (corpus/README.md),
/// and the extensions of the files in them to take. Of bench/corpus-gen/webp
/// only the small lossy files and the animations: the lossless photos and
/// the 50-megapixel mosaic cut inputs per second and, mutated in batches on
/// every core, run the oracle out of memory.
pub const corpus = [_][]const u8{
    "corpus/fetched",
    "corpus/vendor",
    "bench/corpus-gen/webp/lossy",
    "bench/corpus-gen/webp/anim",
};
pub const extensions = [_][]const u8{".webp"};

pub fn check(input: []const u8, choice: u64) !void {
    return harness.checkDecoder(image.webp.Decoder, input, choice);
}

/// VP8L's bit order: values least significant bit first. Bits past the
/// end of the buffer are dropped, so a file that runs out of room comes out
/// truncated.
const Bits = struct {
    out: []u8,
    len: usize = 0,
    acc: u64 = 0,
    count: u6 = 0,

    fn put(b: *Bits, v: u64, n: u6) void {
        b.acc |= (v & ((@as(u64, 1) << n) - 1)) << b.count;
        b.count += n;
        while (b.count >= 8) {
            if (b.len < b.out.len) b.out[b.len] = @truncate(b.acc);
            b.len += 1;
            b.acc >>= 8;
            b.count -= 8;
        }
    }

    fn flush(b: *Bits) void {
        if (b.count > 0) b.put(0, 8 - b.count);
    }

    fn written(b: *const Bits) usize {
        return @min(b.len, b.out.len);
    }
};

/// A complete prefix code over a few symbols of an alphabet, with each
/// symbol's length and canonical code.
const Code = struct {
    syms: [16]u16 = undefined,
    lens: [16]u4 = undefined,
    codes: [16]u16 = undefined,
    n: usize = 0,

    /// `n` distinct symbols below `alphabet` (always including `must`, if
    /// set), with the lengths of a random complete tree.
    fn random(r: std.Random, alphabet: u16, n_in: usize, must: ?u16) Code {
        var c: Code = .{};
        const n = @min(n_in, @as(usize, alphabet), 16);
        while (c.n < n) {
            const s = if (c.n == 0 and must != null) must.? else r.uintLessThan(u16, alphabet);
            if (std.mem.findScalar(u16, c.syms[0..c.n], s) != null) continue;
            c.syms[c.n] = s;
            c.n += 1;
        }
        // Split random leaves of a one-leaf tree until there are n.
        var depth: [16]u4 = undefined;
        depth[0] = 0;
        var leaves: usize = 1;
        while (leaves < n) {
            const i = r.uintLessThan(usize, leaves);
            if (depth[i] == 15) continue;
            depth[i] += 1;
            depth[leaves] = depth[i];
            leaves += 1;
        }
        @memcpy(c.lens[0..n], depth[0..n]);
        if (n == 1) c.lens[0] = 1;
        c.assign();
        return c;
    }

    /// Canonical codes: by length, then symbol.
    fn assign(c: *Code) void {
        var count: [16]u16 = @splat(0);
        for (c.lens[0..c.n]) |l| count[l] += 1;
        count[0] = 0;
        var next: [16]u16 = undefined;
        var code: u16 = 0;
        for (1..16) |l| {
            code = (code + count[l - 1]) << 1;
            next[l] = code;
        }
        // Symbols in increasing order, each taking the next code of its
        // length.
        var done: [16]bool = @splat(false);
        for (0..c.n) |_| {
            var best: usize = 0;
            var found = false;
            for (0..c.n) |i| {
                if (done[i]) continue;
                if (!found or c.syms[i] < c.syms[best]) best = i;
                found = true;
            }
            done[best] = true;
            c.codes[best] = next[c.lens[best]];
            next[c.lens[best]] += 1;
        }
    }

    fn index(c: *const Code, s: u16) ?usize {
        return std.mem.findScalar(u16, c.syms[0..c.n], s);
    }

    /// Writes the code's description: simple when it can be, and normal
    /// otherwise, with a flat code-length code.
    fn write(c: *const Code, b: *Bits, r: std.Random, alphabet: u16) void {
        if (c.n <= 2 and c.syms[0] < 256 and (c.n == 1 or c.syms[1] < 256) and r.uintLessThan(u8, 4) != 0) {
            b.put(1, 1);
            b.put(c.n - 1, 1);
            const first8 = c.syms[0] > 1 or r.boolean();
            b.put(@intFromBool(first8), 1);
            b.put(c.syms[0], if (first8) 8 else 1);
            if (c.n == 2) b.put(c.syms[1], 8);
            return;
        }
        b.put(0, 1);
        // Code lengths 0 to 15 at 4 bits each, 16 to 18 unused.
        b.put(19 - 4, 4);
        const order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        for (order) |i| b.put(if (i < 16) 4 else 0, 3);
        var last: u16 = 0;
        for (c.syms[0..c.n]) |s| last = @max(last, s);
        // With max_symbol, only as many lengths as reach the last symbol.
        var upto: u16 = alphabet;
        if (r.boolean() and last + 1 >= 2) {
            upto = last + 1;
            b.put(1, 1);
            b.put(7, 3);
            b.put(upto - 2, 16);
        } else b.put(0, 1);
        var s: u16 = 0;
        while (s < upto) : (s += 1) {
            const len: u4 = if (c.index(s)) |i| c.lens[i] else 0;
            b.put(@bitReverse(@as(u4, len)), 4);
        }
    }

    fn emit(c: *const Code, b: *Bits, s: u16) void {
        const i = c.index(s).?;
        if (c.n == 1) return;
        const l = c.lens[i];
        b.put(@bitReverse(c.codes[i]) >> @intCast(16 - @as(u5, l)), l);
    }

    fn pick(c: *const Code, r: std.Random) u16 {
        return c.syms[r.uintLessThan(usize, c.n)];
    }
};

const Group = struct {
    codes: [5]Code,
};

/// A group for a sub-image whose green values come from `greens`, with
/// one value each for red, blue, and alpha unless `wide`.
fn subGroup(r: std.Random, greens: u16, wide: bool) Group {
    var g: Group = undefined;
    g.codes[0] = Code.random(r, greens, 1 + r.uintLessThan(usize, @min(greens, 8)), null);
    for (1..4) |i| g.codes[i] = Code.random(r, 256, if (wide) 1 + r.uintLessThan(usize, 6) else 1, null);
    g.codes[4] = Code.random(r, 40, 1, null);
    return g;
}

fn writeGroup(b: *Bits, r: std.Random, g: *const Group, cache: u16) void {
    const alphabets = [5]u16{ 280 + cache, 256, 256, 256, 40 };
    for (&g.codes, alphabets) |*c, a| c.write(b, r, a);
}

/// The value of a length or distance prefix symbol with `extra`.
fn prefixValue(sym: u16, extra: u32) u32 {
    if (sym < 4) return sym + 1;
    const n: u5 = @intCast((sym - 2) >> 1);
    return ((2 + @as(u32, sym & 1)) << n) + extra + 1;
}

fn extraBits(sym: u16) u5 {
    return if (sym < 4) 0 else @intCast((sym - 2) >> 1);
}

const plane = [_][2]i8{ .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ -1, 1 }, .{ 0, 2 }, .{ 2, 0 }, .{ 1, 2 }, .{ -1, 2 } };

/// Entropy-coded pixels for a `w` by `h` image with `groups`, chosen per
/// pixel by `tiles` (or the first group), writing literals, backward
/// references that stay in the image, and cache codes.
fn pixels(
    b: *Bits,
    r: std.Random,
    groups: []const Group,
    tiles: ?[]const u16,
    tile_bits: u5,
    w: u32,
    h: u32,
    cache: u16,
) void {
    const total = w * h;
    var p: u32 = 0;
    while (p < total) {
        if (b.len >= b.out.len) return;
        const x = p % w;
        const y = p / w;
        const tiles_w = (w + (@as(u32, 1) << tile_bits) - 1) >> tile_bits;
        const gi: usize = if (tiles) |t| t[(y >> tile_bits) * tiles_w + (x >> tile_bits)] else 0;
        const g = &groups[gi];
        const green = &g.codes[0];
        const s = green.pick(r);
        if (s < 256) {
            green.emit(b, s);
            for (1..4) |i| g.codes[i].emit(b, g.codes[i].pick(r));
            p += 1;
        } else if (s < 280) {
            const ex = extraBits(s - 256);
            const extra = r.uintLessThan(u32, @as(u32, 1) << ex);
            var len = prefixValue(s - 256, extra);
            const dsym = g.codes[4].pick(r);
            const dex = extraBits(dsym);
            const dextra = r.uintLessThan(u32, @as(u32, 1) << dex);
            const code = prefixValue(dsym, dextra);
            var dist: i64 = @as(i64, code) - 120;
            if (code <= plane.len) dist = @max(1, plane[code - 1][0] + @as(i64, plane[code - 1][1]) * w);
            if (code > plane.len and code <= 120) dist = -1;
            const valid = dist >= 1 and dist <= p and len <= total - p;
            // Usually only references that decode; now and then any.
            if (!valid and r.uintLessThan(u16, 1024) != 0) {
                // A literal instead, if the group has one.
                var lit: ?u16 = null;
                for (green.syms[0..green.n]) |t| {
                    if (t < 256) lit = t;
                }
                if (lit) |l| {
                    green.emit(b, l);
                    for (1..4) |i| g.codes[i].emit(b, g.codes[i].pick(r));
                    p += 1;
                    continue;
                }
            }
            green.emit(b, s);
            b.put(extra, ex);
            g.codes[4].emit(b, dsym);
            b.put(dextra, dex);
            if (!valid) return;
            len = @min(len, total - p);
            p += len;
        } else {
            _ = cache;
            green.emit(b, s);
            p += 1;
        }
    }
}

/// An entropy-coded sub-image: color cache info, one group, and pixels.
fn subImage(b: *Bits, r: std.Random, w: u32, h: u32, greens: u16, wide: bool) void {
    const cache_bits: u16 = if (r.uintLessThan(u8, 4) == 0) 1 + r.uintLessThan(u16, 11) else 0;
    const cache: u16 = if (cache_bits == 0) 0 else @as(u16, 1) << @intCast(cache_bits);
    if (cache_bits == 0) b.put(0, 1) else {
        b.put(1, 1);
        b.put(cache_bits, 4);
    }
    const g = subGroup(r, greens, wide);
    writeGroup(b, r, &g, cache);
    pixels(b, r, (&g)[0..1], null, 0, w, h, cache);
}

/// A VP8L bitstream after the signature: the header, transforms, and the
/// main image.
fn bitstream(b: *Bits, r: std.Random, w: u32, h: u32) void {
    const alpha = r.boolean();
    b.put(w - 1, 14);
    b.put(h - 1, 14);
    b.put(@intFromBool(alpha), 1);
    b.put(if (r.uintLessThan(u8, 64) == 0) r.int(u3) else 0, 3);
    imageStream(b, r, w, h);
}

/// An image stream without the header: transforms, then the coded image.
fn imageStream(b: *Bits, r: std.Random, w: u32, h: u32) void {
    var cur_w = w;
    var kinds: [4]u2 = .{ 0, 1, 2, 3 };
    r.shuffle(u2, &kinds);
    const n_transforms = r.uintAtMost(usize, 4);
    for (kinds[0..n_transforms]) |k_in| {
        // Now and then a transform twice.
        const k = if (r.uintLessThan(u8, 64) == 0) kinds[0] else k_in;
        b.put(1, 1);
        b.put(k, 2);
        switch (k) {
            0, 1 => {
                const bits: u5 = @intCast(r.uintLessThan(u8, 4));
                b.put(bits, 3);
                const tb: u5 = bits + 2;
                const tw = (cur_w + (@as(u32, 1) << tb) - 1) >> tb;
                const th = (h + (@as(u32, 1) << tb) - 1) >> tb;
                subImage(b, r, tw, th, if (k == 0) 16 else 256, k == 1);
            },
            2 => {},
            3 => {
                const size: u32 = 1 + r.uintLessThan(u32, if (r.boolean()) 16 else 256);
                b.put(size - 1, 8);
                subImage(b, r, size, 1, 256, true);
                const wb: u5 = if (size <= 2) 3 else if (size <= 4) 2 else if (size <= 16) 1 else 0;
                cur_w = (cur_w + (@as(u32, 1) << wb) - 1) >> wb;
            },
        }
    }
    b.put(0, 1);

    // The main image: cache, then an entropy image or one group.
    const cache_bits: u16 = if (r.uintLessThan(u8, 3) == 0) 1 + r.uintLessThan(u16, 11) else 0;
    const cache: u16 = if (cache_bits == 0) 0 else @as(u16, 1) << @intCast(cache_bits);
    if (cache_bits == 0) b.put(0, 1) else {
        b.put(1, 1);
        b.put(if (r.uintLessThan(u8, 64) == 0) r.int(u4) else cache_bits, 4);
    }
    var groups: [6]Group = undefined;
    var tile_buf: [4096]u16 = undefined;
    var tiles: ?[]const u16 = null;
    var tile_bits: u5 = 0;
    var n_groups: usize = 1;
    if (r.boolean()) {
        b.put(1, 1);
        const bits: u5 = @intCast(r.uintLessThan(u8, 3));
        b.put(bits, 3);
        tile_bits = bits + 2;
        const tw = (cur_w + (@as(u32, 1) << tile_bits) - 1) >> tile_bits;
        const th = (h + (@as(u32, 1) << tile_bits) - 1) >> tile_bits;
        const n = tw * th;
        if (n > tile_buf.len) return;
        n_groups = 1 + r.uintLessThan(usize, groups.len);
        // The entropy image: group numbers in green (and red, rarely, to
        // name a group past those written).
        const sub_cache_bits: u16 = if (r.uintLessThan(u8, 4) == 0) 1 + r.uintLessThan(u16, 11) else 0;
        if (sub_cache_bits == 0) b.put(0, 1) else {
            b.put(1, 1);
            b.put(sub_cache_bits, 4);
        }
        const sub_cache: u16 = if (sub_cache_bits == 0) 0 else @as(u16, 1) << @intCast(sub_cache_bits);
        var eg: Group = undefined;
        // Every group index appears in the green code, so the image can
        // name the last; skipped indices are read and dropped.
        var greens: Code = .{};
        greens.n = n_groups;
        for (0..n_groups) |i| greens.syms[i] = @intCast(i);
        var depth: [16]u4 = undefined;
        depth[0] = 0;
        var leaves: usize = 1;
        while (leaves < n_groups) {
            const i = r.uintLessThan(usize, leaves);
            depth[i] += 1;
            depth[leaves] = depth[i];
            leaves += 1;
        }
        @memcpy(greens.lens[0..n_groups], depth[0..n_groups]);
        if (n_groups == 1) greens.lens[0] = 1;
        greens.assign();
        eg.codes[0] = greens;
        eg.codes[1] = Code.random(r, 256, 1, if (r.uintLessThan(u8, 32) == 0) 1 else 0);
        eg.codes[2] = Code.random(r, 256, 1, null);
        eg.codes[3] = Code.random(r, 256, 1, null);
        eg.codes[4] = Code.random(r, 40, 1, null);
        writeGroup(b, r, &eg, sub_cache);
        // Literals only, so the image is exactly the groups chosen, and
        // the last group is always named.
        for (0..n) |i| {
            const v: u16 = if (i == n - 1) @intCast(n_groups - 1) else r.uintLessThan(u16, @intCast(n_groups));
            tile_buf[i] = v;
            eg.codes[0].emit(b, v);
            for (1..4) |c| eg.codes[c].emit(b, eg.codes[c].syms[0]);
        }
        if (eg.codes[1].syms[0] != 0) return;
        tiles = tile_buf[0..n];
    } else b.put(0, 1);
    for (groups[0..n_groups]) |*g| {
        const nlit = 1 + r.uintLessThan(usize, 6);
        g.codes[0] = Code.random(r, 280 + cache, nlit + r.uintLessThan(usize, 6), r.uintLessThan(u16, 256));
        for (1..4) |i| g.codes[i] = Code.random(r, 256, 1 + r.uintLessThan(usize, if (r.boolean()) 1 else 8), null);
        g.codes[4] = Code.random(r, 40, 1 + r.uintLessThan(usize, 6), null);
        // Mostly short distances: neighborhood codes 1 to 8.
        if (r.boolean()) g.codes[4] = Code.random(r, 8, 1 + r.uintLessThan(usize, 4), null);
        writeGroup(b, r, g, cache);
    }
    pixels(b, r, groups[0..n_groups], tiles, tile_bits, cur_w, h, cache);
}

/// Writes into a buffer, dropping what does not fit.
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn put(o: *Out, bytes: []const u8) void {
        const n = @min(bytes.len, o.buf.len - o.len);
        @memcpy(o.buf[o.len..][0..n], bytes[0..n]);
        o.len += n;
    }

    fn int(o: *Out, comptime T: type, v: T) void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        o.put(&b);
    }

    fn chunk(o: *Out, r: std.Random, tag: *const [4]u8, data: []const u8) void {
        o.put(tag);
        var size: u32 = @intCast(data.len);
        // Now and then a wrong size.
        if (r.uintLessThan(u16, 200) == 0) size +%= r.int(u4) -% 8;
        o.int(u32, size);
        o.put(data);
        if (data.len & 1 == 1) o.put("\x00");
    }
};

var bits_buf: [1 << 16]u8 = undefined;

/// The boolean entropy encoder of RFC 6386 section 7.3.
const BoolWriter = struct {
    out: []u8,
    len: usize = 0,
    range: u32 = 255,
    bottom: u32 = 0,
    bit_count: i32 = 24,

    fn carry(e: *BoolWriter) void {
        var i = e.len;
        while (i > 0) {
            i -= 1;
            if (i >= e.out.len) continue;
            if (e.out[i] == 255) {
                e.out[i] = 0;
            } else {
                e.out[i] += 1;
                return;
            }
        }
    }

    fn byte(e: *BoolWriter, v: u8) void {
        if (e.len < e.out.len) e.out[e.len] = v;
        e.len += 1;
    }

    fn put(e: *BoolWriter, prob: u8, bit: bool) void {
        const split = 1 + (((e.range - 1) * prob) >> 8);
        if (bit) {
            e.bottom +%= split;
            e.range -= split;
        } else e.range = split;
        while (e.range < 128) {
            e.range <<= 1;
            if (e.bottom & (1 << 31) != 0) e.carry();
            e.bottom <<= 1;
            e.bit_count -= 1;
            if (e.bit_count == 0) {
                e.byte(@truncate(e.bottom >> 24));
                e.bottom &= (1 << 24) - 1;
                e.bit_count = 8;
            }
        }
    }

    fn literal(e: *BoolWriter, v: u32, n: u5) void {
        var i = n;
        while (i > 0) {
            i -= 1;
            e.put(128, (v >> i) & 1 == 1);
        }
    }

    fn signed(e: *BoolWriter, r: std.Random, n: u5) void {
        const present = r.boolean();
        e.put(128, present);
        if (!present) return;
        e.literal(r.int(u32), n);
        e.put(128, r.boolean());
    }

    fn flush(e: *BoolWriter) void {
        const c: u5 = @intCast(e.bit_count);
        var v = e.bottom;
        if (c < 32 and v & (@as(u32, 1) << @intCast(32 - @as(u6, c))) != 0) e.carry();
        v <<= c & 7;
        var k = c >> 3;
        while (k > 0) : (k -= 1) v <<= 8;
        for (0..4) |_| {
            e.byte(@truncate(v >> 24));
            v <<= 8;
        }
    }

    fn written(e: *const BoolWriter) usize {
        return @min(e.len, e.out.len);
    }
};

var vp8_buf: [1 << 15]u8 = undefined;

/// A VP8 key frame: the frame header, a first partition whose header
/// fields are encoded and whose probability updates, skip probability, and
/// modes are random bytes, and random token partitions.
fn keyFrame(r: std.Random, w: u32, h: u32) []u8 {
    var o: Out = .{ .buf = &vp8_buf };
    var hdr: [10]u8 = undefined;
    var e: BoolWriter = .{ .out = vp8_buf[10..] };
    e.literal(r.int(u2), 2); // color space, clamping
    const segments = r.boolean();
    e.put(128, segments);
    if (segments) {
        const update_map = r.boolean();
        const update_data = r.boolean();
        e.put(128, update_map);
        e.put(128, update_data);
        if (update_data) {
            e.put(128, r.boolean());
            for (0..4) |_| e.signed(r, 7);
            for (0..4) |_| e.signed(r, 6);
        }
        if (update_map) for (0..3) |_| {
            const set = r.boolean();
            e.put(128, set);
            if (set) e.literal(r.int(u8), 8);
        };
    }
    e.put(128, r.boolean()); // simple filter
    e.literal(if (r.uintLessThan(u8, 4) == 0) 0 else r.int(u6), 6);
    e.literal(r.int(u3), 3);
    const deltas = r.boolean();
    e.put(128, deltas);
    if (deltas) {
        const update = r.boolean();
        e.put(128, update);
        if (update) for (0..8) |_| e.signed(r, 6);
    }
    const log2_parts = r.int(u2);
    e.literal(log2_parts, 2);
    e.literal(r.int(u7), 7);
    for (0..5) |_| e.signed(r, 4);
    e.put(128, r.boolean()); // refresh_entropy_probs
    e.flush();
    // The rest of the first partition: random, so its booleans follow
    // their probabilities.
    const mbs = ((w + 15) / 16) * ((h + 15) / 16);
    const rest = r.uintLessThan(usize, 40 + 20 * mbs);
    for (0..rest) |_| e.byte(r.int(u8));
    const p0 = e.written();
    const first = if (r.uintLessThan(u8, 32) == 0) r.uintLessThan(u32, @intCast(p0 + 2)) else @as(u32, @intCast(p0));
    const tag: u32 = (first << 5) | (1 << 4) | (if (r.uintLessThan(u8, 64) == 0) @as(u32, r.int(u3)) << 1 else 0) |
        @intFromBool(r.uintLessThan(u8, 128) == 0);
    hdr[0] = @truncate(tag);
    hdr[1] = @truncate(tag >> 8);
    hdr[2] = @truncate(tag >> 16);
    @memcpy(hdr[3..6], "\x9d\x01\x2a");
    std.mem.writeInt(u16, hdr[6..8], @intCast(w | @as(u32, r.int(u2)) << 14), .little);
    std.mem.writeInt(u16, hdr[8..10], @intCast(h | @as(u32, r.int(u2)) << 14), .little);
    @memcpy(vp8_buf[0..10], &hdr);
    o.len = 10 + p0;
    // Token partitions: sizes, then random data, some of it too short.
    const n: usize = @as(usize, 1) << log2_parts;
    var lens: [8]usize = undefined;
    for (lens[0..n]) |*l| l.* = r.uintLessThan(usize, 8 + if (r.uintLessThan(u8, 8) == 0) 4 else 300 * mbs / n);
    for (lens[0 .. n - 1]) |l| {
        const v: u32 = @intCast(l);
        o.put(&.{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16) });
    }
    for (lens[0..n]) |l| for (0..l) |_| o.put(&.{r.int(u8)});
    return vp8_buf[0..o.len];
}

var alph_buf: [1 << 15]u8 = undefined;

/// An ALPH chunk's body: raw or lossless, with any filter.
fn alphChunk(r: std.Random, w: u32, h: u32) []u8 {
    const method: u8 = @intFromBool(r.boolean());
    var head: u8 = method | @as(u8, r.int(u2)) << 2 | @as(u8, @intFromBool(r.uintLessThan(u8, 8) == 0)) << 4;
    if (r.uintLessThan(u8, 64) == 0) head |= @as(u8, r.int(u2)) << 6;
    if (r.uintLessThan(u8, 64) == 0) head |= 2 << 4;
    alph_buf[0] = head;
    if (method == 0) {
        var n: usize = @min(w * h, alph_buf.len - 1);
        if (r.uintLessThan(u8, 16) == 0) n = r.uintLessThan(usize, n + 1);
        r.bytes(alph_buf[1..][0..n]);
        return alph_buf[0 .. 1 + n];
    }
    var b: Bits = .{ .out = alph_buf[1..] };
    imageStream(&b, r, w, h);
    b.flush();
    return alph_buf[0 .. 1 + b.written()];
}

/// A WebP file: usually a valid lossless image, simple or extended with
/// metadata chunks around it, sometimes broken.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    const w = 1 + random.uintLessThan(u32, if (random.uintLessThan(u8, 8) == 0) 300 else 24);
    const h = 1 + random.uintLessThan(u32, if (random.uintLessThan(u8, 8) == 0) 70 else 24);
    const lossy = random.boolean();
    var stream: []u8 = undefined;
    if (lossy) {
        stream = keyFrame(random, w, h);
    } else {
        var b: Bits = .{ .out = bits_buf[0..@min(bits_buf.len, buf.len)] };
        b.put(0x2f, 8);
        bitstream(&b, random, w, h);
        b.flush();
        stream = bits_buf[0..b.written()];
    }
    const image_tag: *const [4]u8 = if (lossy) "VP8 " else "VP8L";
    // Now and then cut short, or with a byte changed.
    if (random.uintLessThan(u8, 32) == 0 and stream.len > 1) stream = stream[0..random.uintLessThan(usize, stream.len)];
    if (random.uintLessThan(u8, 32) == 0 and stream.len > 5) {
        stream[5 + random.uintLessThan(usize, stream.len - 5)] = random.int(u8);
    }

    var o: Out = .{ .buf = buf };
    o.put("RIFF");
    o.int(u32, 0);
    o.put("WEBP");
    const extended = random.uintLessThan(u8, 3) == 0;
    if (extended) {
        var x: [10]u8 = @splat(0);
        x[0] = random.int(u8) & if (random.uintLessThan(u8, 16) == 0) @as(u8, 0xff) else 0x3c;
        var cw = w;
        var ch = h;
        if (random.uintLessThan(u8, 32) == 0) cw += 1;
        if (random.uintLessThan(u8, 32) == 0) ch += 1;
        std.mem.writeInt(u24, x[4..7], @intCast(cw - 1), .little);
        std.mem.writeInt(u24, x[7..10], @intCast(ch - 1), .little);
        o.chunk(random, "VP8X", &x);
        const exif = "II*\x00\x08\x00\x00\x00\x01\x00\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00";
        if (random.boolean()) o.chunk(random, "ICCP", "an icc profile");
        if (random.uintLessThan(u8, 4) == 0) o.chunk(random, "EXIF", exif);
        if (random.uintLessThan(u8, 8) == 0) o.chunk(random, "abcd", "unknown");
        if (lossy and random.uintLessThan(u8, 3) != 0) {
            o.chunk(random, "ALPH", alphChunk(random, cw, ch));
            if (random.uintLessThan(u8, 32) == 0) o.chunk(random, "ALPH", alphChunk(random, cw, ch));
        } else if (random.uintLessThan(u8, 8) == 0) o.chunk(random, "ALPH", "\x00\xff");
        o.chunk(random, image_tag, stream);
        if (random.boolean()) o.chunk(random, "EXIF", exif);
        if (random.boolean()) o.chunk(random, "XMP ", "<x:xmpmeta/>");
    } else {
        o.chunk(random, image_tag, stream);
        if (random.uintLessThan(u8, 8) == 0) o.chunk(random, "abcd", "trailing");
    }
    var size: u32 = @intCast(o.len - 8);
    if (random.uintLessThan(u8, 32) == 0) size +%= random.int(u4) -% 8;
    if (o.len >= 8) std.mem.writeInt(u32, buf[4..8], size, .little);
    return buf[0..o.len];
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk: cwebp's lossless 2x2 RGBA image, a 4x4 two-color palette
/// image, and a 5x3 gradient.
pub const seeds = [_][]const u8{
    "\x52\x49\x46\x46\x24\x00\x00\x00\x57\x45\x42\x50\x56\x50\x38\x4c\x17\x00\x00\x00\x2f\x01\x40\x00" ++
        "\x10\x0f\x10\xf3\xbf\xff\x0f\xfc\x0f\x07\x0a\x01\x04\x40\x41\x13\xd1\xff\x58\x00",
    "\x52\x49\x46\x46\x1e\x00\x00\x00\x57\x45\x42\x50\x56\x50\x38\x4c\x11\x00\x00\x00\x2f\x03\xc0\x00" ++
        "\x00\x07\xd0\xcc\x66\x36\xb3\xff\x81\x88\xe8\x7f\x00\x00",
    "\x52\x49\x46\x46\x26\x00\x00\x00\x57\x45\x42\x50\x56\x50\x38\x4c\x19\x00\x00\x00\x2f\x04\x80\x00" ++
        "\x00\x08\x01\x41\xd1\x74\xcf\x09\x08\x8a\xa6\x7b\xae\xff\xb1\x6d\xab\xaa\x2a\xdb\x36\x00",
};

test "webp on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
