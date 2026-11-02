//! WebP's rows: decode a whole file from memory per call into RGBA8, with
//! work memory from a static buffer, as a caller that reuses it would.
//! Only the pages a file uses are touched.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "webp-decode-lossless", rgba },
    .{ "webp-decode-lossless-large", rgba },
};

var work: [256 << 20]u8 = undefined;

fn rgba(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.webp.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, .rgba8, c.width, c.height) catch return null;
    _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    return dst.stride * dst.height;
}
