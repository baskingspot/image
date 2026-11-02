//! WBMP's rows: decode a whole file from memory per call, to gray or RGBA,
//! and encode raw gray (bench/corpus/wbmp_encode.sh) to a file in memory.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "wbmp-decode", gray },
    .{ "wbmp-decode-rgba", rgba },
    .{ "wbmp-encode", encode },
};

fn decode(in: []const u8, out: []u8, format: image.PixelFormat) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.wbmp.Decoder = .init(&r, .{});
    const c = d.decodeConfig() catch return null;
    const dst = image.PixelBuffer.init(out, format, c.width, c.height) catch return null;
    _ = d.decodeFrame(dst, &.{}) catch return null;
    return dst.stride * dst.height;
}

fn gray(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .gray8);
}

fn rgba(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .rgba8);
}

fn encode(in: []const u8, out: []u8) ?usize {
    const src = input.pixels(in, .gray8) orelse return null;
    var writer: std.Io.Writer = .fixed(out);
    image.wbmp.encode(&writer, src, .{}, &.{}) catch return null;
    return writer.end;
}
