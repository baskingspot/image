//! The WebP lossless encoder's fuzz target: `harness.checkEncoder` at each
//! effort, and with metadata, which moves the file to VP8X. `generate`
//! builds pixels from a few colors or from runs, repeats, and small steps,
//! so that color indexing, bundling, the predictor and color transforms,
//! backward references, and the color cache all come up. Decoding in
//! libwebp and Wuffs is checked by the oracle (test/oracle/webp_encode.zig).

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

const webp = image.webp;
const PixelBuffer = image.PixelBuffer;

pub const name = "webp_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

/// The option sets `checkEncoder` runs, one per input.
const variants = [_]webp.EncodeOptions{
    .{ .effort = 0 },
    .{ .effort = 1 },
    .{ .effort = 2 },
    .{ .effort = 3 },
    .{ .effort = 4 },
    .{ .effort = 5 },
    .{ .effort = 6 },
    .{ .effort = 7 },
    .{ .effort = 8 },
    .{ .effort = 9 },
    .{ .effort = 2, .icc = "icc", .exif = "MM\x00\x2a\x00\x00\x00\x08", .xmp = "<x/>" },
};

/// Up to 96 by 96, so that images have several predictor, color
/// transform, and entropy tiles.
const sizes: harness.EncoderCheck = .{ .max_width = 96, .max_height = 96 };

pub fn check(input: []const u8, choice: u64) !void {
    switch (choice % variants.len) {
        inline 0...variants.len - 1 => |i| {
            try harness.checkEncoderWith(As(variants[i]), sizes, input, choice / variants.len);
        },
        else => unreachable,
    }
}

/// image.webp with `options` as the default.
fn As(comptime options: webp.EncodeOptions) type {
    return struct {
        pub const EncodeOptions = struct {};
        pub const Decoder = webp.Decoder;

        pub fn workLen(_: EncodeOptions, width: u32, height: u32) ?usize {
            return webp.workLen(options, width, height);
        }

        pub fn encode(w: *std.Io.Writer, src: PixelBuffer, _: EncodeOptions, work: []u8) webp.EncodeError!void {
            return webp.encode(w, src, options, work);
        }
    };
}

/// A size and pixel bytes: either indices into a few random colors, for
/// color indexing, or bytes that repeat, step, copy from earlier, or jump.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 3 + random.uintLessThan(usize, @min(buf.len - 3, 16384));
    random.bytes(buf[0..3]);
    if (random.boolean()) {
        var palette: [16][4]u8 = undefined;
        random.bytes(std.mem.asBytes(&palette));
        const colors = 1 + random.uintLessThan(usize, palette.len);
        var i: usize = 3;
        while (i < len) : (i += 4) {
            const c = palette[random.uintLessThan(usize, colors)];
            const n = @min(len - i, 4);
            @memcpy(buf[i..][0..n], c[0..n]);
        }
        return buf[0..len];
    }
    var i: usize = 3;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 64));
        switch (random.uintLessThan(u8, 4)) {
            0 => @memset(buf[i..][0..n], buf[i - 1]),
            1 => for (buf[i..][0..n], 0..) |*b, k| {
                b.* = buf[i - 1] +% @as(u8, @truncate(k)) *% (random.uintLessThan(u8, 5) -% 2);
            },
            2 => {
                const back = 1 + random.uintLessThan(usize, i - 2);
                for (buf[i..][0..n], i..) |*b, k| b.* = buf[k - back];
            },
            else => random.bytes(buf[i..][0..n]),
        }
        i += n;
    }
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    "\x04\x03" ++ "\x10\x20\x30\xff\x11\x20\x31\xff\x1a\x28\x3b\xff\x01\x02\x03\x80",
    "\x2f\x01" ++ "\x00" ** 200,
    "\x3f\x3f" ++ "\x01\x02\x03\x04\x05\x06\x07\x08" ** 64,
};

test "webp_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
