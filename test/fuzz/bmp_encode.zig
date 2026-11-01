//! The BMP encoder's fuzz target: the round trip in harness.zig, through
//! each of the encoder's formats. `indexed8` falls back to `bgr24` for
//! images of more than 256 colors, so it still round-trips.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "bmp_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

const formats = std.enums.values(image.bmp.EncodeOptions.Format);

pub fn check(input: []const u8, choice: u64) !void {
    switch (formats[choice % formats.len]) {
        inline else => |f| return harness.checkEncoder(As(f), input, choice / formats.len),
    }
}

/// image.bmp with `format` as the default.
fn As(comptime format: image.bmp.EncodeOptions.Format) type {
    return struct {
        pub const EncodeOptions = struct {};
        pub const Decoder = image.bmp.Decoder;

        pub fn workLen(_: EncodeOptions, width: u32, height: u32) ?usize {
            return image.bmp.workLen(.{ .format = format }, width, height);
        }

        pub fn encode(
            w: *std.Io.Writer,
            src: image.PixelBuffer,
            _: EncodeOptions,
            work: []u8,
        ) image.bmp.EncodeError!void {
            image.bmp.encode(w, src, .{ .format = format }, work) catch |e| switch (e) {
                // Nothing was written: the table is collected first.
                error.TooManyColors => return image.bmp.encode(w, src, .{ .format = .bgr24 }, work),
                else => return e,
            };
        }
    };
}

pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 3 + random.uintLessThan(usize, @min(buf.len - 3, 600));
    random.bytes(buf[0..len]);
    // Few distinct bytes now and then, so that indexed8 has few colors.
    if (random.boolean()) for (buf[2..len]) |*b| {
        b.* &= 0xc0;
    };
    return buf[0..len];
}

pub const seeds = [_][]const u8{ "\x05\x03abcdefgh", "\x00\x00\x01", "\x2f\x2f\x00\x80\xff" };

test "bmp_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
