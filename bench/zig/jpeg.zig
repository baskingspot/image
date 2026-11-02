//! JPEG's rows: decode a whole file from memory per call into RGB8 (RGB16
//! for 12-bit files), and encode raw RGB8 or gray pixels to a file in
//! memory at quality 85, with work memory from a static buffer, as a
//! caller that reuses it would. The buffer is large enough for a
//! progressive 50-megapixel photo's coefficients, decoding or encoding;
//! only the pages a call touches count toward peak RSS.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "jpeg-decode", rgb },
    .{ "jpeg-decode-progressive", rgb },
    .{ "jpeg-decode-444", rgb },
    .{ "jpeg-decode-arith", rgb },
    .{ "jpeg-decode-12bit", rgb16 },
    .{ "jpeg-decode-lossless", rgb },
    .{ "jpeg-decode-cmyk", rgb },
    .{ "jpeg-encode", encode420 },
    .{ "jpeg-encode-444", encode444 },
    .{ "jpeg-encode-optimized", encodeOptimized },
    .{ "jpeg-encode-progressive", encodeProgressive },
    .{ "jpeg-encode-gray", encodeGray },
};

var work: [512 << 20]u8 = undefined;

fn rgb(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .rgb8);
}

fn rgb16(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .rgb16);
}

fn decode(in: []const u8, out: []u8, format: image.PixelFormat) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.jpeg.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, format, c.width, c.height) catch return null;
    _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    return dst.stride * dst.height;
}

fn encode(in: []const u8, out: []u8, format: image.PixelFormat, options: image.jpeg.EncodeOptions) ?usize {
    const src = input.pixels(in, format) orelse return null;
    const n = image.jpeg.workLen(options, src.width, src.height) orelse return null;
    if (n > work.len) return null;
    var writer: std.Io.Writer = .fixed(out);
    image.jpeg.encode(&writer, src, options, work[0..n]) catch return null;
    return writer.end;
}

fn encode420(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgb8, .{ .quality = 85 });
}

/// At quality 95, where stb_image_write stops subsampling.
fn encode444(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgb8, .{ .quality = 95, .subsampling = .@"4:4:4" });
}

fn encodeOptimized(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgb8, .{ .quality = 85, .optimize = true });
}

fn encodeProgressive(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgb8, .{ .quality = 85, .progressive = true });
}

fn encodeGray(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .gray8, .{ .quality = 85 });
}
