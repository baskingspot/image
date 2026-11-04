//! The JPEG XL encoder's fuzz target: `harness.checkEncoder`'s properties
//! (any pixel format, exact work memory, the same bytes through a
//! draining writer, and a lossless round trip through our decoder) at
//! each effort, on images up to 48 by 48, and at the default effort on
//! images up to 320 by 200, which span two groups when wider than 256.
//! The oracle (test/oracle/jxl_encode.zig) checks that libjxl decodes the
//! files to the same pixels.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "jxl_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkEncoder(image.jxl, input, choice);
    try harness.checkEncoder(WithEffort(.fast), input, choice);
    try harness.checkEncoder(WithEffort(.best), input, choice);
    try harness.checkEncoderWith(image.jxl, .{ .max_width = 320, .max_height = 200 }, input, choice);
}

/// The encoder at `effort`, under the names `checkEncoder` looks for.
fn WithEffort(comptime effort: image.jxl.Effort) type {
    return struct {
        pub const EncodeOptions = image.jxl.EncodeOptions;
        pub const Decoder = image.jxl.Decoder;
        pub fn workLen(_: EncodeOptions, width: u32, height: u32) ?usize {
            return image.jxl.workLen(.{ .effort = effort }, width, height);
        }
        pub fn encode(
            w: *std.Io.Writer,
            src: image.PixelBuffer,
            _: EncodeOptions,
            work: []u8,
        ) image.jxl.EncodeError!void {
            return image.jxl.encode(w, src, .{ .effort = effort }, work);
        }
    };
}

/// Two size bytes, then pixel bytes in runs, ramps, repeats, and noise,
/// so that palettes, flat areas, gradients, and noisy ones all appear.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    const len = 3 + random.uintLessThan(usize, @min(buf.len, 4096) - 3);
    random.bytes(buf[0..3]);
    // A few colors for some images, so that a palette pays.
    var colors: [8]u8 = undefined;
    random.bytes(&colors);
    const few = random.boolean();
    var i: usize = 3;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 32));
        switch (random.uintLessThan(u8, 5)) {
            0 => @memset(buf[i..][0..n], buf[i - 1]),
            1 => for (buf[i..][0..n], 0..) |*b, k| {
                b.* = buf[i - 1] +% @as(u8, @truncate(k));
            },
            2 => if (i >= 3 + n) @memcpy(buf[i..][0..n], buf[i - n ..][0..n]) else random.bytes(buf[i..][0..n]),
            3 => for (buf[i..][0..n]) |*b| {
                b.* = colors[random.uintLessThan(usize, if (few) 3 else colors.len)];
            },
            else => random.bytes(buf[i..][0..n]),
        }
        i += n;
    }
    return buf[0..len];
}

/// Seeds for the coverage-guided fuzzer.
pub const seeds = [_][]const u8{
    "\x05\x03" ++ @as([32]u8, std.simd.repeat(32, "\x01\x02\x03\x04".*)),
    "\x2f\x11" ++ @as([64]u8, @splat(0x80)) ++ "\x01\x02",
    "\xf0\x40" ++ @as([160]u8, std.simd.repeat(160, "\x00\x10\x20\x30\x40\x50\x60\x70\x80\x90".*)),
};

test "jxl_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
