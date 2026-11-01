//! The Netpbm encoder's fuzz target: `harness.checkEncoder` on the default
//! options, then every kind, a maxval, and a PFM byte order picked by the
//! choice, each read back by our decoder and compared with the source
//! quantized as the encoder documents.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");
const PixelFormat = image.PixelFormat;
const PixelBuffer = image.PixelBuffer;
const Kind = image.netpbm.Kind;

pub const name = "netpbm_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkEncoder(image.netpbm, input, choice);
    try checkKind(input, choice);
}

const max_side = 40;
var source: [max_side * max_side * 16]u8 = undefined;
var file: [1 << 20]u8 = undefined;
var got: [max_side * max_side * 16]u8 = undefined;
var want: [max_side * max_side * 16]u8 = undefined;
var wide_samples: [max_side * max_side * 16]u8 = undefined;

/// The 16-bit format with the channels of 8-bit `f`.
fn widen(f: PixelFormat) PixelFormat {
    return switch (f) {
        .gray8 => .gray16,
        .gray_alpha8 => .gray_alpha16,
        .rgb8 => .rgb16,
        else => .rgba16,
    };
}

/// Encodes an image made from `input` with options from `choice`, and
/// checks that our decoder reads back what the encoder's documentation
/// says the file holds.
fn checkKind(input: []const u8, choice: u64) !void {
    if (input.len < 3) return;
    const width: u32 = 1 + input[0] % max_side;
    const height: u32 = 1 + input[1] % max_side;
    const formats = std.enums.values(PixelFormat);
    const format = formats[choice % formats.len];
    const kinds = std.enums.values(Kind);
    const kind = kinds[(choice / formats.len) % kinds.len];
    const maxvals = [_]u16{ 0, 1, 2, 3, 100, 254, 255, 256, 1000, 65534, 65535 };
    const maxval = maxvals[(choice / formats.len / kinds.len) % maxvals.len];
    const endian: std.builtin.Endian = if (choice >> 40 & 1 == 0) .little else .big;
    const len = PixelBuffer.len(format, width, height).?;
    const body = input[2..];
    for (source[0..len], 0..) |*b, i| b.* = body[i % body.len];
    if (format.sample() == .f32) {
        const floats: []align(1) f32 = @ptrCast(source[0..len]);
        for (floats, 0..) |*f, i| f.* = @as(f32, @floatFromInt(body[i % body.len])) / 255;
    }
    const src = PixelBuffer.init(source[0..len], format, width, height) catch unreachable;

    var w: std.Io.Writer = .fixed(&file);
    const options: image.netpbm.EncodeOptions = .{ .kind = kind, .maxval = maxval, .pfm_endian = endian };
    image.netpbm.encode(&w, src, options, &.{}) catch return error.EncodeFailed;
    var r: std.Io.Reader = .fixed(w.buffered());
    var d = image.netpbm.Decoder.init(&r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.width != width or config.height != height) return error.RoundTripDiffers;
    const native = config.native;
    const native_len = PixelBuffer.len(native, width, height).?;
    const out = PixelBuffer.init(got[0..native_len], native, width, height) catch unreachable;
    _ = (d.decodeFrame(out, &.{}) catch return error.RoundTripDiffers) orelse return error.RoundTripDiffers;
    if (d.decodeFrame(out, &.{}) catch return error.RoundTripDiffers) |_| return error.RoundTripDiffers;

    // What the file should hold, from the source converted to the 8- or
    // 16-bit (or float) samples the encoder starts from.
    const m: u64 = if (maxval != 0) maxval else if (format.sample() == .u8) 255 else 65535;
    const wanted = PixelBuffer.init(want[0..native_len], native, width, height) catch unreachable;
    switch (kind) {
        .pbm, .plain_pbm => {
            if (native != .gray8) return error.RoundTripDiffers;
            image.convert.convertBuffer(wanted, src) catch unreachable;
            for (wanted.pixels) |*v| v.* = if (v.* < 128) 0 else 255;
        },
        .pfm => {
            if (native != .rgba_f32) return error.RoundTripDiffers;
            image.convert.convertBuffer(wanted, src) catch unreachable;
            const f: []align(1) f32 = @ptrCast(wanted.pixels);
            for (0..f.len / 4) |p| f[p * 4 + 3] = 1;
        },
        else => {
            // The encoder's samples: the source at 8 bits if it has 8, and
            // at 16 otherwise or for maxval above 255, quantized to
            // maxval; our decoder scales them back to 255 or 65535.
            const top: u64 = if (m > 255) 65535 else 255;
            if (native.sample() != (if (top == 255) PixelFormat.Sample.u8 else .u16)) return error.RoundTripDiffers;
            if (top == 255 and format.sample() != .u8) {
                const wide = widen(native);
                const wide_len = PixelBuffer.len(wide, width, height).?;
                const wide_buf = PixelBuffer.init(wide_samples[0..wide_len], wide, width, height) catch unreachable;
                image.convert.convertBuffer(wide_buf, src) catch unreachable;
                const n: []align(1) const u16 = @ptrCast(wide_buf.pixels);
                for (wanted.pixels, n) |*v, x| {
                    const q = (2 * @as(u64, x) * m + 65535) / 131070;
                    v.* = @intCast((2 * q * top + m) / (2 * m));
                }
            } else if (top == 255) {
                image.convert.convertBuffer(wanted, src) catch unreachable;
                for (wanted.pixels) |*v| {
                    const s = (2 * @as(u64, v.*) * m + top) / (2 * top);
                    v.* = @intCast((2 * s * top + m) / (2 * m));
                }
            } else {
                image.convert.convertBuffer(wanted, src) catch unreachable;
                const n: []align(1) u16 = @ptrCast(wanted.pixels);
                for (n) |*v| {
                    const s = (2 * @as(u64, v.*) * m + top) / (2 * top);
                    v.* = @intCast((2 * s * top + m) / (2 * m));
                }
            }
        },
    }
    if (!std.mem.eql(u8, out.pixels, wanted.pixels)) return error.RoundTripDiffers;
}

pub fn generate(random: std.Random, buf: []u8) []u8 {
    const n = 3 + random.uintLessThan(usize, @min(buf.len - 3, 400));
    random.bytes(buf[0..n]);
    return buf[0..n];
}

pub const seeds = [_][]const u8{
    "\x07\x05\x00\x10\x80\xff\x7f\x01",
    "\x27\x27" ++ "\x12\x34\x56\x78\x9a\xbc\xde\xf0" ** 4,
};

test "netpbm_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
