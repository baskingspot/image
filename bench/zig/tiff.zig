//! TIFF's rows: decode a whole file from memory per call into RGBA8, with
//! a seeker over the same memory (most writers put the IFD after the
//! strips) and work memory from a static buffer, as a caller that reuses it
//! would.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "tiff-decode-none", rgba },
    .{ "tiff-decode-lzw", rgba },
    .{ "tiff-decode-deflate", rgba },
    .{ "tiff-decode-packbits", rgba },
    .{ "tiff-decode-jpeg", rgba },
    .{ "tiff-decode-g4", rgba },
};

var work: [1 << 20]u8 = undefined;

fn rgba(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.tiff.Decoder = .init(&r, .{ .limits = .none, .seeker = .fixed(&r) });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, .rgba8, c.width, c.height) catch return null;
    _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    return dst.stride * dst.height;
}
