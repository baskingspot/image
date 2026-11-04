//! The QOI encoder's fuzz target: `harness.checkEncoder`'s properties on
//! images made from random bytes, which are mostly noise, and from
//! generated ones with runs, repeats, and small steps, which reach every
//! chunk kind. Byte-for-byte agreement with qoi.h's encoder is checked by
//! the oracle (test/oracle/qoi_encode.zig) and by the benchmark's
//! checksums.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "qoi_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

pub fn check(input: []const u8, choice: u64) !void {
    return harness.checkEncoder(image.qoi, input, choice);
}

/// A size and pixel bytes that repeat, step by small amounts, or jump, so
/// the encoder meets runs, index hits, DIFF, LUMA, RGB, and RGBA chunks.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 3 + random.uintLessThan(usize, @min(buf.len - 3, 4096));
    random.bytes(buf[0..3]);
    var i: usize = 3;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 24));
        switch (random.uintLessThan(u8, 4)) {
            0 => @memset(buf[i..][0..n], buf[i - 1]),
            1 => for (buf[i..][0..n], 0..) |*b, k| {
                b.* = buf[i - 1] +% @as(u8, @truncate(k)) *% (random.uintLessThan(u8, 5) -% 2);
            },
            2 => if (i >= 3 + n) @memcpy(buf[i..][0..n], buf[i - n ..][0..n]) else random.bytes(buf[i..][0..n]),
            else => random.bytes(buf[i..][0..n]),
        }
        i += n;
    }
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    "\x04\x03" ++ "\x10\x20\x30\xff\x11\x20\x31\xff\x1a\x28\x3b\xff\x01\x02\x03\x80",
    "\x2f\x01" ++ @as([200]u8, @splat(0)),
};

test "qoi_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
