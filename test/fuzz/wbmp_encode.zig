//! The WBMP encoder's fuzz target: `harness.checkEncoderWith`'s
//! properties, with WBMP's one bit per pixel in place of an exact round
//! trip: our decoder must read back the source converted to gray and
//! thresholded at 128 to 0 or 255. Images are up to 300 pixels wide, so
//! rows cross the encoder's 64-pixel blocks and its spans. The encoder
//! also needs no work memory, and the decoder reads the whole file.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const PixelBuffer = image.PixelBuffer;

pub const name = "wbmp_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

const max_width = 300;
const max_height = 48;

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkEncoderWith(image.wbmp, .{
        .max_width = max_width,
        .max_height = max_height,
        .expect = threshold,
    }, input, choice);
    if (input.len < 3) return;
    const width: u32 = 1 + @as(u32, input[0]) * max_width / 256;
    const height: u32 = 1 + input[1] % max_height;
    if (image.wbmp.workLen(.{}, width, height) != 0) return error.EncodeFailed;
    var pixels: [max_width * max_height]u8 = @splat(0);
    var file: [max_width * max_height]u8 = undefined;
    var w: Io.Writer = .fixed(&file);
    const src = PixelBuffer.init(pixels[0 .. width * height], .gray8, width, height) catch unreachable;
    image.wbmp.encode(&w, src, .{}, &.{}) catch return error.EncodeFailed;
    var r: Io.Reader = .fixed(w.buffered());
    var d = image.wbmp.Decoder.init(&r, .{ .limits = harness.limits });
    _ = d.decodeConfig() catch return error.RoundTripDiffers;
    _ = d.decodeFrame(src, &.{}) catch return error.RoundTripDiffers;
    if (r.bufferedLen() != 0) return error.RoundTripDiffers;
}

/// Gray at 128 and above is white, the rest black.
fn threshold(want: PixelBuffer, _: PixelBuffer) void {
    for (want.pixels) |*v| v.* = if (v.* >= 128) 255 else 0;
}

/// Random sizes and pixels, mostly black and white with some gray.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 3 + random.uintLessThan(usize, @min(buf.len - 3, 4096));
    random.bytes(buf[0..2]);
    for (buf[2..len]) |*b| b.* = switch (random.uintLessThan(u8, 4)) {
        0 => 0,
        1 => 255,
        else => random.int(u8),
    };
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    "\x10\x02\x00\xff\x80\x7f",
    "\xff\x2f\x00\x00\x00\xff\xff\xff\x01\x02",
};

test "wbmp_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
