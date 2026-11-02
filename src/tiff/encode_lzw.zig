//! TIFF's LZW (TIFF 6.0, section 13), encoding one strip at a time into a
//! buffer the caller sizes with `bound`.
//!
//! Codes are 9 to 12 bits, most significant bit first. Each strip starts
//! with Clear (256) and ends with EOI (257). The table is a hash of
//! (prefix code, byte) pairs to codes. The width grows one code early, as
//! the specification has it: to 10 bits once the next free entry is 512,
//! which is when a decoder, an entry behind, has 511. When the next free
//! entry would be 4094, the encoder writes Clear and starts over, so a
//! decoder's table never needs a 13th bit.

const std = @import("std");
const testing = std.testing;

const clear = 256;
const eoi = 257;
const first_free = 258;
/// Clear is written when the next free entry reaches this.
const table_end = 4094;
const hash_bits = 13;
const hash_len = 1 << hash_bits;

/// The table, in the caller's work memory. `keys[i]` holds the pair
/// `prefix << 8 | byte` tagged with the table's generation in its top 12
/// bits, so starting over needs no clearing until the generation wraps.
pub const State = struct {
    keys: [hash_len]u32,
    codes: [hash_len]u16,
    generation: u32,

    pub fn init(s: *State) void {
        @memset(&s.keys, 0);
        s.generation = 0;
    }

    fn reset(s: *State) void {
        s.generation += 1;
        if (s.generation == 1 << 12) {
            @memset(&s.keys, 0);
            s.generation = 1;
        }
    }
};

/// The most bytes `encode` writes for `n` input bytes: a 12-bit code per
/// byte, Clear and EOI, and a Clear every 3836 codes.
pub fn bound(n: usize) usize {
    return (n + 3 + n / 3836) * 3 / 2 + 2;
}

/// Writes `src` as one LZW stream to `dst`, which holds at least
/// `bound(src.len)` bytes, and returns its length.
pub fn encode(s: *State, src: []const u8, dst: []u8) usize {
    std.debug.assert(dst.len >= bound(src.len));
    var out: Bits = .{ .dst = dst };
    s.reset();
    out.put(clear, 9);
    if (src.len == 0) {
        out.put(eoi, 9);
        return out.end();
    }
    var next: u16 = first_free;
    var width: u4 = 9;
    var tag = s.generation << 20;
    var omega: u16 = src[0];
    for (src[1..]) |b| {
        const key = tag | @as(u32, omega) << 8 | b;
        var h = hash(key);
        while (true) : (h = (h + 1) & (hash_len - 1)) {
            const k = s.keys[h];
            if (k == key) {
                omega = s.codes[h];
                break;
            }
            if (k >> 20 != s.generation) {
                // A miss: write the string so far and make it one longer.
                out.put(omega, width);
                s.keys[h] = key;
                s.codes[h] = next;
                next += 1;
                if (next == table_end) {
                    out.put(clear, width);
                    s.reset();
                    tag = s.generation << 20;
                    next = first_free;
                    width = 9;
                } else if (next == @as(u16, 1) << width) width += 1;
                omega = b;
                break;
            }
        }
    }
    out.put(omega, width);
    // A decoder adds an entry for the last code before it reads EOI.
    if (next + 1 == @as(u16, 1) << width and width < 12) width += 1;
    out.put(eoi, width);
    return out.end();
}

fn hash(key: u32) u32 {
    return (key *% 0x9e3779b1) >> (32 - hash_bits);
}

const Bits = struct {
    dst: []u8,
    at: usize = 0,
    acc: u64 = 0,
    n: u6 = 0,

    fn put(b: *Bits, code: u16, width: u4) void {
        b.acc = b.acc << width | code;
        b.n += width;
        while (b.n >= 8) {
            b.n -= 8;
            b.dst[b.at] = @truncate(b.acc >> b.n);
            b.at += 1;
        }
    }

    fn end(b: *Bits) usize {
        if (b.n > 0) {
            b.dst[b.at] = @truncate(b.acc << (8 - @as(u6, b.n)));
            b.at += 1;
            b.n = 0;
        }
        return b.at;
    }
};

const lzw = @import("lzw.zig");

fn roundTrip(s: *State, data: []const u8) !void {
    const gpa = testing.allocator;
    const z = try gpa.alloc(u8, bound(data.len));
    defer gpa.free(z);
    const n = encode(s, data, z);
    // The same stream as the decoder's own test encoder, which follows
    // the specification's pseudocode.
    const want = try lzw.testEncode(gpa, data, false);
    defer gpa.free(want);
    try testing.expectEqualSlices(u8, want, z[0..n]);
    var r: std.Io.Reader = .fixed(z[0..n]);
    const work = try gpa.alloc(u8, lzw.work_len);
    defer gpa.free(work);
    var d: lzw.Decoder = .init(&r, work, false);
    const out = try gpa.alloc(u8, data.len);
    defer gpa.free(out);
    try d.read(out);
    try testing.expectEqualSlices(u8, data, out);
}

test "round trips through every code width and table clears" {
    const gpa = testing.allocator;
    const s = try gpa.create(State);
    defer gpa.destroy(s);
    s.init();
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const data = try gpa.alloc(u8, 200_000);
    defer gpa.free(data);
    for (0..6) |round| {
        var i: usize = 0;
        const alphabet: u8 = if (round % 2 == 0) 4 else 255;
        while (i < data.len) {
            const n = @min(data.len - i, 1 + random.uintLessThan(usize, 300));
            const run = random.boolean();
            const v = random.uintLessThan(u8, alphabet);
            for (data[i..][0..n]) |*b| b.* = if (run) v else random.uintLessThan(u8, alphabet);
            i += n;
        }
        const len = random.uintLessThan(usize, data.len) + 1;
        try roundTrip(s, data[0..len]);
    }
    for ([_][]const u8{ "", "a", "ab", "aaaaaaaaaaaaaaaa" }) |d| try roundTrip(s, d);
}

test "the bound holds for incompressible data, and generations wrap" {
    const gpa = testing.allocator;
    const s = try gpa.create(State);
    defer gpa.destroy(s);
    s.init();
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    var data: [20_000]u8 = undefined;
    prng.random().bytes(&data);
    var z: [bound(data.len)]u8 = undefined;
    for (0..5000) |_| _ = encode(s, data[0..3], &z);
    const n = encode(s, &data, &z);
    try testing.expect(n <= z.len);
    try roundTrip(s, &data);
}
