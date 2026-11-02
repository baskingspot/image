//! QOI's rows: decode a whole file from memory per call, into the file's
//! own format or BGRA, and encode raw RGB or RGBA (bench/corpus/qoi_encode.sh)
//! to a file in memory.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "qoi-decode", native },
    .{ "qoi-decode-bgra", bgra },
    .{ "qoi-encode", encode },
};

fn decode(in: []const u8, out: []u8, format: ?image.PixelFormat) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.qoi.Decoder = .init(&r, .{});
    const c = d.decodeConfig() catch return null;
    const dst = image.PixelBuffer.init(out, format orelse c.native, c.width, c.height) catch return null;
    _ = d.decodeFrame(dst, &.{}) catch return null;
    return dst.stride * dst.height;
}

fn native(in: []const u8, out: []u8) ?usize {
    return decode(in, out, null);
}

fn bgra(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .bgra8);
}

fn encode(in: []const u8, out: []u8) ?usize {
    const format: image.PixelFormat = if (input.bytesPerPixel(in) == 4) .rgba8 else .rgb8;
    const src = input.pixels(in, format) orelse return null;
    var writer: std.Io.Writer = .fixed(out);
    image.qoi.encode(&writer, src, .{}, &.{}) catch return null;
    return writer.end;
}
