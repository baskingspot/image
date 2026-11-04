//! The WBMP fuzz target: the decoder properties in harness.zig, on mutated
//! corpus files and generated headers and rows.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "wbmp";

pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/wbmp" };
pub const extensions = [_][]const u8{".wbmp"};

pub fn check(input: []const u8, choice: u64) !void {
    return harness.checkDecoder(image.wbmp.Decoder, input, choice);
}

/// A multi-byte integer, sometimes with up to ten extra leading 0x80
/// octets.
fn putInt(random: std.Random, buf: []u8, v: u32) usize {
    var n: usize = 1;
    while (n < 5 and v >> @intCast(7 * n) != 0) n += 1;
    const pad = if (random.uintLessThan(u8, 16) == 0) random.uintAtMost(usize, 10) else 0;
    @memset(buf[0..pad], 0x80);
    for (0..n) |i| {
        const shift: u5 = @intCast(7 * (n - 1 - i));
        buf[pad + i] = @as(u8, @truncate(v >> shift)) & 0x7f | if (i + 1 < n) @as(u8, 0x80) else 0;
    }
    return pad + n;
}

/// A WBMP file: usually a type 0 header and exactly the rows it needs,
/// sometimes another type, extension headers, or too few or many octets.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    // Now and then a width at the 2^24 limit with no rows.
    const edge = random.uintLessThan(u8, 64) == 0;
    const small_w = random.uintAtMost(u32, if (random.uintLessThan(u8, 8) == 0) 600 else 40);
    const w = if (edge) (1 << 24) - 1 + random.uintAtMost(u32, 1) else small_w;
    const h = if (edge) 0 else random.uintAtMost(u32, 24);
    var len: usize = 0;
    buf[0] = if (random.uintLessThan(u8, 32) == 0) random.int(u8) else 0;
    buf[1] = if (random.uintLessThan(u8, 32) == 0) random.int(u8) else 0;
    len = 2;
    len += putInt(random, buf[len..], w);
    len += putInt(random, buf[len..], h);
    var rows = @as(usize, (w + 7) / 8) * h;
    switch (random.uintLessThan(u8, 16)) {
        0 => rows -|= 1 + random.uintLessThan(usize, 8),
        1 => rows += 1 + random.uintLessThan(usize, 8),
        else => {},
    }
    rows = @min(rows, buf.len - len);
    // Mostly runs of black or white, as real images have.
    var i: usize = 0;
    while (i < rows) {
        const n = @min(rows - i, 1 + random.uintLessThan(usize, 16));
        const b: u8 = switch (random.uintLessThan(u8, 3)) {
            0 => 0,
            1 => 0xff,
            else => random.int(u8),
        };
        @memset(buf[len + i ..][0..n], b);
        i += n;
    }
    return buf[0 .. len + rows];
}

pub const seeds = [_][]const u8{
    "\x00\x00\x0a\x02\xa5\xff\x0f\x40",
    "\x00\x00\x82\x2c\x01" ++ @as([38]u8, @splat(0x5a)),
};

test "wbmp on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
