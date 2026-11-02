//! The TGA encoder's fuzz target: `harness.checkEncoder` on images made
//! from the input, run-length encoded and not.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "tga_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkEncoder(image.tga, input, choice);
    try harness.checkEncoder(Uncompressed, input, choice);
}

/// The same encoder with run-length encoding off, under the names
/// `checkEncoder` looks for.
const Uncompressed = struct {
    pub const EncodeOptions = image.tga.EncodeOptions;
    pub const Decoder = image.tga.Decoder;
    pub fn workLen(_: EncodeOptions, width: u32, height: u32) ?usize {
        return image.tga.workLen(.{ .rle = false }, width, height);
    }
    pub fn encode(w: *std.Io.Writer, src: image.PixelBuffer, _: EncodeOptions, work: []u8) image.tga.EncodeError!void {
        return image.tga.encode(w, src, .{ .rle = false }, work);
    }
};

/// Two size bytes, then pixel bytes with runs in them, so both packet
/// kinds appear.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    const len = 3 + random.uintLessThan(usize, @min(buf.len, 4096) - 3);
    var i: usize = 0;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 16));
        if (random.boolean()) @memset(buf[i..][0..n], random.int(u8)) else random.bytes(buf[i..][0..n]);
        i += n;
    }
    return buf[0..len];
}

/// Seeds for the coverage-guided fuzzer.
pub const seeds = [_][]const u8{
    "\x05\x03" ++ "\x01\x02\x03\x04" ** 8,
    "\x2f\x01" ++ "\x80" ** 64 ++ "\x01\x02",
};

test "tga_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
