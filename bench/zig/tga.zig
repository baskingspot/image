//! TGA's rows: decode a whole file from memory per call, into the file's
//! own channels in RGB order or BGRA; and encode raw RGB or RGBA pixels
//! uncompressed or run-length encoded.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "tga-decode", native },
    .{ "tga-decode-rle", native },
    .{ "tga-decode-bgra", bgra },
    .{ "tga-encode", encodeRaw },
    .{ "tga-encode-rle", encodeRle },
};

/// Work memory for a color map or an encoder's rows, enough for any TGA.
var work: [1 << 20]u8 = undefined;

fn decode(in: []const u8, out: []u8, format: ?image.PixelFormat) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.tga.Decoder = .init(&r, .{});
    const c = d.decodeConfig() catch return null;
    const f = format orelse switch (c.native) {
        .bgr8 => .rgb8,
        .bgra8 => .rgba8,
        else => c.native,
    };
    const dst = image.PixelBuffer.init(out, f, c.width, c.height) catch return null;
    _ = d.decodeFrame(dst, work[0..c.work_len]) catch return null;
    return dst.stride * dst.height;
}

fn native(in: []const u8, out: []u8) ?usize {
    return decode(in, out, null);
}

fn bgra(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .bgra8);
}

fn encode(in: []const u8, out: []u8, rle: bool) ?usize {
    const format: image.PixelFormat = if (input.bytesPerPixel(in) == 4) .rgba8 else .rgb8;
    const src = input.pixels(in, format) orelse return null;
    var writer: std.Io.Writer = .fixed(out);
    image.tga.encode(&writer, src, .{ .rle = rle }, &work) catch return null;
    return writer.end;
}

fn encodeRaw(in: []const u8, out: []u8) ?usize {
    return encode(in, out, false);
}

fn encodeRle(in: []const u8, out: []u8) ?usize {
    return encode(in, out, true);
}
