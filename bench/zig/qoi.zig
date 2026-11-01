//! QOI's rows: decode a whole file from memory per call, into the file's
//! own format or BGRA.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "qoi-decode", native },
    .{ "qoi-decode-bgra", bgra },
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
