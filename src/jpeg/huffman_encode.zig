//! Huffman coding for the encoder: code tables from a DHT-style
//! specification (T.81 C.2 and C.3), optimal specifications from symbol
//! counts (T.81 K.2), and the bit writer with its byte stuffing.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Spec = @import("huffman.zig").Spec;
const standard = @import("huffman.zig").standard;

/// Each symbol's code, right-aligned, and its length; length 0 for a
/// symbol the table leaves out.
pub const Codes = struct {
    code: [256]u16,
    size: [256]u8,

    pub fn init(spec: *const Spec) Codes {
        var c: Codes = .{ .code = @splat(0), .size = @splat(0) };
        var code: u32 = 0;
        var i: usize = 0;
        for (spec.counts, 1..) |n, len| {
            for (0..n) |_| {
                const v = spec.values[i];
                c.code[v] = @intCast(code);
                c.size[v] = @intCast(len);
                code += 1;
                i += 1;
            }
            code <<= 1;
        }
        return c;
    }
};

/// The optimal table for the symbol counts `freq`, by T.81 K.2's
/// procedure: a reserved symbol of count 1 keeps any code from being all
/// ones; of equally rare symbols the one with the larger value is merged
/// first (libjpeg-turbo's choice, which the encoder matches); codes longer
/// than 16 bits are shortened as Figure K.3 does; and the symbols are
/// listed by code length, then value.
pub fn optimal(freq: *const [256]u64) Spec {
    const n = 257;
    var f: [n]u64 = undefined;
    @memcpy(f[0..256], freq);
    f[256] = 1;
    // The symbols in use, in increasing order: the searches visit only
    // them, in the same order, so ties go the same way.
    var used: [n]u16 = undefined;
    var m: usize = 0;
    for (f, 0..) |x, i| if (x != 0) {
        used[m] = @intCast(i);
        m += 1;
    };
    var size: [n]u16 = @splat(0);
    var others: [n]i16 = @splat(-1);
    while (true) {
        var c1: i16 = -1;
        var v: u64 = std.math.maxInt(u64);
        for (used[0..m]) |i| if (f[i] != 0 and f[i] <= v) {
            v = f[i];
            c1 = @intCast(i);
        };
        var c2: i16 = -1;
        v = std.math.maxInt(u64);
        for (used[0..m]) |i| if (f[i] != 0 and f[i] <= v and i != c1) {
            v = f[i];
            c2 = @intCast(i);
        };
        if (c2 < 0) break;
        var a: usize = @intCast(c1);
        var b: usize = @intCast(c2);
        f[a] += f[b];
        f[b] = 0;
        size[a] += 1;
        while (others[a] >= 0) {
            a = @intCast(others[a]);
            size[a] += 1;
        }
        others[a] = c2;
        size[b] += 1;
        while (others[b] >= 0) {
            b = @intCast(others[b]);
            size[b] += 1;
        }
    }
    // A code can be up to 256 bits long before adjustment.
    var bits: [n + 1]u16 = @splat(0);
    for (size) |s| if (s != 0) {
        bits[s] += 1;
    };
    var i: usize = n;
    while (i > 16) : (i -= 1) {
        while (bits[i] > 0) {
            var j = i - 2;
            while (bits[j] == 0) j -= 1;
            bits[i] -= 2;
            bits[i - 1] += 1;
            bits[j + 1] += 2;
            bits[j] -= 1;
        }
    }
    // Drop the reserved symbol's code, one of the longest.
    i = 16;
    while (i > 0 and bits[i] == 0) i -= 1;
    if (i > 0) bits[i] -= 1;
    var spec: Spec = .{ .counts = undefined, .values = @splat(0) };
    for (&spec.counts, bits[1..17]) |*c, b| c.* = @intCast(b);
    // By code length before adjustment, then value: each length's place
    // from the counts of the shorter ones.
    var at: [n + 1]u16 = @splat(0);
    for (size[0..256]) |s| at[s] += 1;
    var p: u16 = 0;
    for (at[1..]) |*x| {
        const c = x.*;
        x.* = p;
        p += c;
    }
    for (size[0..256], 0..) |s, sym| if (s != 0) {
        spec.values[at[s]] = @intCast(sym);
        at[s] += 1;
    };
    return spec;
}

/// Writes entropy-coded data: codes and bits packed from the most
/// significant end, each 0xff byte followed by a stuffed 0 (T.81 B.1.1.5),
/// staged in `buf` and written to the writer in large pieces. Bits move
/// out 64 at a time, and a word without a 0xff byte is stored whole.
pub const BitWriter = struct {
    w: *Io.Writer,
    state: Fast.State = .{},
    len: usize = 0,
    buf: [4096]u8 = undefined,

    /// More bytes than a block's codes take, every byte stuffed: 64
    /// codes and values of at most 27 bits in a sequential scan, and in a
    /// progressive refinement scan an EOB run's code and 1,000 held
    /// correction bits as well.
    pub const block_room = 1024;

    /// The writer's state in a value the compiler can keep in registers
    /// while a block is coded, with room for the block in `buf` (`begin`
    /// makes it), so `put` neither checks for room nor fails; `end` puts
    /// the state back.
    pub const Fast = struct {
        s: State,
        len: usize,
        buf: *[4096]u8,

        const State = struct {
            /// The pending bits, the last `64 - free` of them.
            acc: u64 = 0,
            free: u32 = 64,
        };

        /// Appends `size` bits, 1 to 32, of `v`, which has no others set.
        pub inline fn put(f: *Fast, v: u32, size: u32) void {
            if (size < f.s.free) {
                f.s.acc = (f.s.acc << @intCast(size)) | v;
                f.s.free -= size;
                return;
            }
            // The high bits fill the word, the rest start the next; the
            // bits of `v` already written leave by the next word.
            const over = size - f.s.free;
            const word = (f.s.acc << @intCast(f.s.free)) | (@as(u64, v) >> @intCast(over));
            f.s.acc = v;
            f.s.free = 64 - over;
            // The test for a 0xff byte is a vector compare, whose constant
            // takes a vector register rather than two general ones.
            const bytes: @Vector(8, u8) = @bitCast(word);
            if (!@reduce(.Or, bytes == @as(@Vector(8, u8), @splat(0xff)))) {
                std.mem.writeInt(u64, f.buf[f.len..][0..8], word, .big);
                f.len += 8;
            } else {
                // Rare, so a loop: unrolled, or called, it would take
                // registers from the loop around `put`.
                var w = word;
                for (0..8) |_| {
                    f.byte(@truncate(w >> 56));
                    w <<= 8;
                }
            }
        }

        inline fn byte(f: *Fast, b: u8) void {
            f.buf[f.len] = b;
            f.len += 1;
            if (b == 0xff) {
                f.buf[f.len] = 0;
                f.len += 1;
            }
        }
    };

    pub fn begin(bw: *BitWriter) Io.Writer.Error!Fast {
        if (bw.len > bw.buf.len - block_room) try bw.flush();
        return .{ .s = bw.state, .len = bw.len, .buf = &bw.buf };
    }

    pub fn end(bw: *BitWriter, f: *const Fast) void {
        bw.state = f.s;
        bw.len = f.len;
    }

    /// Appends the low `size` bits of `v` (`size` at most 32).
    pub fn put(bw: *BitWriter, v: u32, size: u6) Io.Writer.Error!void {
        if (size == 0) return;
        var f = try bw.begin();
        f.put(v & @as(u32, @truncate((@as(u64, 1) << size) - 1)), size);
        bw.end(&f);
    }

    /// Writes the staged bytes to the writer.
    pub fn flush(bw: *BitWriter) Io.Writer.Error!void {
        try bw.w.writeAll(bw.buf[0..bw.len]);
        bw.len = 0;
    }

    /// Pads the last byte with one bits (T.81 F.1.2.3) and writes
    /// everything.
    pub fn finish(bw: *BitWriter) Io.Writer.Error!void {
        var f = try bw.begin();
        var n = 64 - f.s.free;
        const pad = (8 - n % 8) % 8;
        const acc = (f.s.acc << @intCast(pad)) | ((@as(u64, 1) << @intCast(pad)) - 1);
        n += pad;
        while (n > 0) {
            n -= 8;
            f.byte(@truncate(acc >> @intCast(n)));
        }
        f.s = .{};
        bw.end(&f);
        try bw.flush();
    }
};

test "standard tables give their published codes" {
    const c: Codes = .init(&standard.dc_luma);
    try testing.expectEqual(2, c.size[0]);
    try testing.expectEqual(0b00, c.code[0]);
    try testing.expectEqual(3, c.size[1]);
    try testing.expectEqual(0b010, c.code[1]);
    try testing.expectEqual(9, c.size[11]);
    try testing.expectEqual(0b111111110, c.code[11]);
    const ac: Codes = .init(&standard.ac_luma);
    // EOB 1010, ZRL 11111111001 (T.81 Table K.5).
    try testing.expectEqual(4, ac.size[0x00]);
    try testing.expectEqual(0b1010, ac.code[0x00]);
    try testing.expectEqual(11, ac.size[0xf0]);
    try testing.expectEqual(0b11111111001, ac.code[0xf0]);
}

test "optimal tables are prefix-free, at most 16 bits, and never all ones" {
    var prng: std.Random.DefaultPrng = .init(3);
    const r = prng.random();
    for (0..200) |round| {
        var freq: [256]u64 = @splat(0);
        const used = 1 + r.uintLessThan(usize, 256);
        for (0..used) |_| {
            // Geometric counts make long codes that need shortening.
            const count = if (round % 2 == 0) r.uintLessThan(u64, 1000) + 1 else @as(u64, 1) << r.uintLessThan(u6, 40);
            freq[r.int(u8)] += count;
        }
        const spec = optimal(&freq);
        var total: usize = 0;
        for (freq) |x| total += @intFromBool(x != 0);
        try testing.expectEqual(total, spec.count());
        // Kraft: the codes, with one left for the reserved symbol, fill
        // no more than the code space.
        var kraft: u64 = 0;
        for (spec.counts, 1..) |c, len| kraft += @as(u64, c) << @intCast(16 - len);
        try testing.expect(kraft < 1 << 16);
        const codes: Codes = .init(&spec);
        for (freq, 0..) |x, sym| if (x != 0) {
            const s = codes.size[sym];
            try testing.expect(s >= 1 and s <= 16);
            try testing.expect(codes.code[sym] != (@as(u32, 1) << @intCast(s)) - 1);
        };
    }
}

var big: [20000]u8 = undefined;

test "the bit writer stuffs 0xff bytes and pads with ones" {
    var out: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var bw: BitWriter = .{ .w = &w };
    try bw.put(0xff, 8);
    try bw.put(0b101, 3);
    try bw.finish();
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0b1011_1111 }, w.buffered());
    // Whole words, with and without 0xff bytes, across the staging
    // buffer's end.
    w = .fixed(&big);
    bw = .{ .w = &w };
    for (0..3000) |i| try bw.put(if (i % 3 == 0) 0xffff_ff00 else 0x1234_5678, 32);
    try bw.put(1, 1);
    try bw.finish();
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    for (0..3000) |i| {
        const stuffed = [_]u8{ 0xff, 0, 0xff, 0, 0xff, 0, 0x00 };
        const plain = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
        const bytes: []const u8 = if (i % 3 == 0) &stuffed else &plain;
        try want.appendSlice(testing.allocator, bytes);
    }
    try want.append(testing.allocator, 0xff);
    try want.append(testing.allocator, 0);
    try testing.expectEqualSlices(u8, want.items, w.buffered());
}
