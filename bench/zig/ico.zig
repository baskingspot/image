//! ICO's row: decode a one-entry icon from memory per call into RGBA.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "ico-decode", decode },
};

fn decode(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.ico.Decoder = .init(&r, .{ .entry = 0 });
    const c = d.decodeConfig() catch return null;
    const dst = image.PixelBuffer.init(out, .rgba8, c.width, c.height) catch return null;
    _ = d.decodeFrame(dst, &.{}) catch return null;
    return dst.stride * dst.height;
}
