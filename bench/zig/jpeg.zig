//! JPEG's rows: decode a whole file from memory per call into RGB8 (RGB16
//! for 12-bit files), with work memory from a static buffer, as a caller
//! that reuses it would. The
//! buffer is large enough for a progressive 50-megapixel photo's
//! coefficients; only the pages a file touches count toward peak RSS.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "jpeg-decode", rgb },
    .{ "jpeg-decode-progressive", rgb },
    .{ "jpeg-decode-444", rgb },
    .{ "jpeg-decode-arith", rgb },
    .{ "jpeg-decode-12bit", rgb16 },
    .{ "jpeg-decode-lossless", rgb },
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
