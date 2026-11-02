//! JPEG's rows: decode a whole file from memory per call into RGB8, with
//! work memory from a static buffer, as a caller that reuses it would. The
//! buffer is large enough for a progressive 50-megapixel photo's
//! coefficients; only the pages a file touches count toward peak RSS.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "jpeg-decode", rgb },
    .{ "jpeg-decode-progressive", rgb },
    .{ "jpeg-decode-444", rgb },
};

var work: [512 << 20]u8 = undefined;

fn rgb(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.jpeg.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, .rgb8, c.width, c.height) catch return null;
    _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    return dst.stride * dst.height;
}
