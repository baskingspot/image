//! The WebP lossless encoder's fuzz target: `harness.checkEncoder` at each
//! effort, and with metadata, which moves the file to VP8X; and
//! `encodeAlpha`, whose stream behind a VP8L header must decode to the
//! plane in green. `generate`
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
    switch (choice % (variants.len + 1)) {
        inline 0...variants.len - 1 => |i| {
            try harness.checkEncoderWith(As(variants[i]), sizes, input, choice / (variants.len + 1));
        },
        variants.len => try checkAlpha(input, choice / (variants.len + 1)),
        else => unreachable,
    }
}

const max_alpha = sizes.max_width * sizes.max_height;
var plane: [max_alpha]u8 = undefined;
var alpha_file: [max_alpha * 5 + 1024]u8 = undefined;
var alpha_work: [8 << 20]u8 = undefined;
var alpha_pixels: [max_alpha * 4]u8 = undefined;

/// `encodeAlpha` at an effort from `choice`: its stream, behind a VP8L
/// header, decodes to the plane in green, with red and blue 0 and alpha
/// opaque.
fn checkAlpha(input: []const u8, choice: u64) !void {
    if (input.len < 3) return;
    const width = 1 + @as(u32, input[0]) % sizes.max_width;
    const height = 1 + @as(u32, input[1]) % sizes.max_height;
    const n = width * height;
    const body = input[2..];
    for (plane[0..n], 0..) |*b, i| b.* = body[i % body.len];
    const file = alphaFile(&alpha_file, plane[0..n], width, height, @intCast(choice % 10), &alpha_work) catch
        return error.EncodeFailed;
    var r: std.Io.Reader = .fixed(file);
    var d = webp.Decoder.init(&r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.width != width or config.height != height) return error.RoundTripDiffers;
    if (config.work_len > alpha_work.len) return error.RoundTripDiffers;
    const got = PixelBuffer.init(alpha_pixels[0 .. n * 4], .bgra8, width, height) catch unreachable;
    _ = d.decodeFrame(got, alpha_work[0..config.work_len]) catch return error.RoundTripDiffers;
    for (plane[0..n], 0..) |a, i| {
        const px = alpha_pixels[i * 4 ..][0..4];
        if (px[0] != 0 or px[1] != a or px[2] != 0 or px[3] != 0xff) return error.RoundTripDiffers;
    }
}

/// `plane` as `encodeAlpha` writes it at `effort`, made a lossless WebP
/// file in `out`: the stream is a VP8L image's after its 40-bit header,
/// so a header in front makes it one, with the plane in green.
pub fn alphaFile(out: []u8, alpha: []const u8, width: u32, height: u32, effort: u4, work: []u8) ![]u8 {
    const work_len = webp.workLen(.{ .effort = effort }, width, height) orelse return error.ImageTooLarge;
    if (work_len > work.len) return error.WorkTooSmall;
    const head = 12 + 8 + 5;
    var w: std.Io.Writer = .fixed(out[head..]);
    try webp.encodeAlpha(&w, alpha, width, height, effort, work[0..work_len]);
    const chunk_len: u32 = @intCast(5 + w.end);
    const file_len = 12 + 8 + chunk_len + (chunk_len & 1);
    if (chunk_len & 1 != 0) try w.writeByte(0);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], file_len - 8, .little);
    @memcpy(out[8..16], "WEBPVP8L");
    std.mem.writeInt(u32, out[16..20], chunk_len, .little);
    out[20] = 0x2f;
    std.mem.writeInt(u32, out[21..25], (width - 1) | (height - 1) << 14, .little);
    return out[0..file_len];
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
    "\x2f\x01" ++ @as([200]u8, @splat(0)),
    "\x3f\x3f" ++ @as([512]u8, std.simd.repeat(512, "\x01\x02\x03\x04\x05\x06\x07\x08".*)),
};

test "webp_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
