//! The QOI fuzz target: the decoder properties in harness.zig, on mutated
//! corpus files and generated chunk streams.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "qoi";

/// Seed directories, relative to the repository root (corpus/README.md),
/// and the extensions of the files in them to take.
pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/qoi" };
pub const extensions = [_][]const u8{".qoi"};

pub fn check(input: []const u8, choice: u64) !void {
    return harness.checkDecoder(image.qoi.Decoder, input, choice);
}

/// A QOI file of random chunks: usually a valid header and a stream that
/// covers the pixels and ends with the end marker, sometimes not.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    const w = random.uintAtMost(u32, if (random.uintLessThan(u8, 8) == 0) 300 else 24);
    const h = random.uintAtMost(u32, 24);
    @memcpy(buf[0..4], "qoif");
    std.mem.writeInt(u32, buf[4..8], w, .big);
    std.mem.writeInt(u32, buf[8..12], h, .big);
    buf[12] = if (random.uintLessThan(u8, 32) == 0) random.int(u8) else 3 + random.uintLessThan(u8, 2);
    buf[13] = random.uintLessThan(u8, 2);
    var len: usize = 14;
    var left: u64 = @as(u64, w) * h;
    const end = buf.len - 8;
    const exact = random.uintLessThan(u8, 8) != 0;
    while (len + 5 <= end and (left > 0 or !exact and random.uintLessThan(u8, 4) != 0)) {
        switch (random.uintLessThan(u8, 6)) {
            0 => {
                buf[len] = 0xfe;
                random.bytes(buf[len + 1 ..][0..3]);
                len += 4;
            },
            1 => {
                buf[len] = 0xff;
                random.bytes(buf[len + 1 ..][0..4]);
                len += 5;
            },
            2 => {
                buf[len] = random.uintLessThan(u8, 64);
                len += 1;
            },
            3 => {
                buf[len] = 0x40 | random.uintLessThan(u8, 64);
                len += 1;
            },
            4 => {
                buf[len] = 0x80 | random.uintLessThan(u8, 64);
                buf[len + 1] = random.int(u8);
                len += 2;
            },
            else => {
                const most: u8 = @intCast(@min(62, @max(1, left)));
                const run = if (exact) random.uintAtMost(u8, most - 1) else random.uintLessThan(u8, 62);
                buf[len] = 0xc0 | run;
                left -|= run;
                len += 1;
            },
        }
        left -|= 1;
    }
    if (random.uintLessThan(u8, 16) != 0) {
        @memcpy(buf[len..][0..8], "\x00\x00\x00\x00\x00\x00\x00\x01");
        len += 8;
    }
    return buf[0..len];
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk.
pub const seeds = [_][]const u8{
    "qoif\x00\x00\x00\x02\x00\x00\x00\x02\x04\x00" ++
        "\xfe\x10\x20\x30\x7b\xa8\x9a\xff\x01\x02\x03\x80" ++ @as([7]u8, @splat(0)) ++ "\x01",
    "qoif\x00\x00\x00\x03\x00\x00\x00\x01\x03\x01\xc0\x35\xc0" ++ @as([7]u8, @splat(0)) ++ "\x01",
};

test "qoi on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
