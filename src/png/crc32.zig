//! The CRC-32 every PNG chunk ends with (PNG specification, section 5.5 and
//! annex D): ISO 3309 and ITU-T V.42, reflected polynomial 0xEDB88320, the
//! register preset to all ones and complemented at the end.
//!
//! Slice-by-16: sixteen 256-entry tables, where `tables[k][b]` is the CRC
//! register after byte `b` followed by `k` zero bytes, so sixteen input
//! bytes advance the register with sixteen independent table loads. That
//! runs several times faster than annex D's byte-at-a-time loop.
//!
//! Private to PNG until `compress` exports its CRC-32 (docs/slop/png.md).

const std = @import("std");
const testing = std.testing;

const poly: u32 = 0xEDB8_8320;

const tables: [16][256]u32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [16][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = i;
        for (0..8) |_| c = if (c & 1 != 0) poly ^ (c >> 1) else c >> 1;
        t[0][i] = c;
    }
    for (1..16) |k| {
        for (0..256) |i| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :blk t;
};

/// The register before any byte.
pub const init: u32 = 0xffff_ffff;

/// Advances the register `crc` over `bytes`.
pub fn update(crc: u32, bytes: []const u8) u32 {
    var c = crc;
    var rest = bytes;
    while (rest.len >= 16) {
        const w0 = std.mem.readInt(u32, rest[0..4], .little) ^ c;
        const w1 = std.mem.readInt(u32, rest[4..8], .little);
        const w2 = std.mem.readInt(u32, rest[8..12], .little);
        const w3 = std.mem.readInt(u32, rest[12..16], .little);
        c = tables[15][w0 & 0xff] ^ tables[14][(w0 >> 8) & 0xff] ^
            tables[13][(w0 >> 16) & 0xff] ^ tables[12][w0 >> 24] ^
            tables[11][w1 & 0xff] ^ tables[10][(w1 >> 8) & 0xff] ^
            tables[9][(w1 >> 16) & 0xff] ^ tables[8][w1 >> 24] ^
            tables[7][w2 & 0xff] ^ tables[6][(w2 >> 8) & 0xff] ^
            tables[5][(w2 >> 16) & 0xff] ^ tables[4][w2 >> 24] ^
            tables[3][w3 & 0xff] ^ tables[2][(w3 >> 8) & 0xff] ^
            tables[1][(w3 >> 16) & 0xff] ^ tables[0][w3 >> 24];
        rest = rest[16..];
    }
    for (rest) |b| c = tables[0][(c ^ b) & 0xff] ^ (c >> 8);
    return c;
}

/// The CRC a register stands for: its complement.
pub fn final(crc: u32) u32 {
    return ~crc;
}

test "crc32 against std and the check value" {
    try testing.expectEqual(0xCBF4_3926, final(update(init, "123456789")));
    // The IEND chunk's CRC over its type.
    try testing.expectEqual(0xAE42_6082, final(update(init, "IEND")));
    var buf: [300]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    prng.random().bytes(&buf);
    for (0..buf.len) |n| {
        const want = std.hash.Crc32.hash(buf[0..n]);
        try testing.expectEqual(want, final(update(init, buf[0..n])));
        // Split anywhere, the same.
        const cut = n / 3;
        try testing.expectEqual(want, final(update(update(init, buf[0..cut]), buf[cut..n])));
    }
}
