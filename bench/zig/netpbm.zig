//! Netpbm's rows: decode a whole file from memory per call, into its own
//! format or another; and encode raw pixels from memory (an 8-byte header,
//! the width and height as little-endian u32s, then the pixels) into a
//! whole file per call.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "netpbm-decode-ppm", native },
    .{ "netpbm-decode-ppm-rgba", rgba },
    .{ "netpbm-decode-pgm", native },
    .{ "netpbm-decode-ppm16", native },
    .{ "netpbm-decode-ppm16-bgra", bgra16 },
    .{ "netpbm-decode-pam", native },
    .{ "netpbm-decode-pbm", native },
    .{ "netpbm-decode-plain", native },
    .{ "netpbm-decode-pfm", native },
    .{ "netpbm-encode-ppm", encodeRgb },
    .{ "netpbm-encode-pgm", encodeGray },
    .{ "netpbm-encode-pam", encodeRgba },
    .{ "netpbm-encode-ppm16", encodeRgb16 },
    .{ "netpbm-encode-plain", encodePlain },
};

fn decode(in: []const u8, out: []u8, format: ?image.PixelFormat) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.netpbm.Decoder = .init(&r, .{});
    const c = d.decodeConfig() catch return null;
    const dst = image.PixelBuffer.init(out, format orelse c.native, c.width, c.height) catch return null;
    _ = d.decodeFrame(dst, &.{}) catch return null;
    return dst.stride * dst.height;
}

fn native(in: []const u8, out: []u8) ?usize {
    return decode(in, out, null);
}

fn rgba(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .rgba8);
}

fn bgra16(in: []const u8, out: []u8) ?usize {
    return decode(in, out, .bgra16);
}

fn encode(in: []const u8, out: []u8, format: image.PixelFormat, options: image.netpbm.EncodeOptions) ?usize {
    if (in.len < 8) return null;
    const width = std.mem.readInt(u32, in[0..4], .little);
    const height = std.mem.readInt(u32, in[4..8], .little);
    const src = image.PixelBuffer.init(@constCast(in[8..]), format, width, height) catch return null;
    var w: std.Io.Writer = .fixed(out);
    image.netpbm.encode(&w, src, options, &.{}) catch return null;
    return w.end;
}

fn encodeRgb(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgb8, .{});
}

fn encodeGray(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .gray8, .{});
}

fn encodeRgba(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgba8, .{});
}

fn encodeRgb16(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgb16, .{});
}

fn encodePlain(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .rgb8, .{ .kind = .plain_ppm });
}
