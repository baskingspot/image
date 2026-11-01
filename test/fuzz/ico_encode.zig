//! The ICO encoder's fuzz target: the round trip in harness.zig.

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

pub const seeds = [_][]const u8{ "\x05\x03abcdefgh", "\x00\x00\x01", "\x2f\x2f\x00\x80\xff" };

test "ico_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
