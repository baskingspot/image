//! The ICO encoder's fuzz target: the round trip in harness.zig, BMP
//! entries below 256 by 256 and PNG entries at it.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "ico_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

pub fn check(input: []const u8, choice: u64) !void {
    return harness.checkEncoder(image.ico, input, choice);
}

pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 3 + random.uintLessThan(usize, @min(buf.len - 3, 600));
    random.bytes(buf[0..len]);
    return buf[0..len];
}

/// The last two are 256 by 256, which `.auto` writes as a PNG entry: one
/// of four colors, which PNG stores as a palette, and one of noise.
pub const seeds = [_][]const u8{
    "\x05\x03abcdefgh",
    "\x00\x00\x01",
    "\x2f\x2f\x00\x80\xff",
    "\xff\xff\x00\x00\x00\x00\x10\x20\x30\xff\x50\x60\x70\xff\x90\xa0\xb0\xff",
    "\xff\xff\x13\x8a\x07\xe1\x5c\x92\x3f\xd4\x6b\x28\xf7\x41",
};

test "ico_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
