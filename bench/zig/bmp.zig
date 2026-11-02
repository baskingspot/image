//! BMP's rows: decode a whole file from memory per call into RGBA or BGRA,
//! and encode raw pixels (bench/corpus/raw.sh) as 24-bit, 32-bit, or 8-bit
//! gray.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "bmp-decode", Decode(.rgba8).run },
    .{ "bmp-decode-rle", Decode(.rgba8).run },
    .{ "bmp-decode-bgra", Decode(.bgra8).run },
    .{ "bmp-encode-rgb", Encode(.rgb8).run },
    .{ "bmp-encode-rgba", Encode(.rgba8).run },
    .{ "bmp-encode-gray", Encode(.gray8).run },
};

fn Decode(comptime format: image.PixelFormat) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            var r: std.Io.Reader = .fixed(in);
            var d: image.bmp.Decoder = .init(&r, .{});
            const c = d.decodeConfig() catch return null;
            const dst = image.PixelBuffer.init(out, format, c.width, c.height) catch return null;
            _ = d.decodeFrame(dst, &.{}) catch return null;
            return dst.stride * dst.height;
        }
    };
}

fn Encode(comptime format: image.PixelFormat) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            const src = input.pixels(in, format) orelse return null;
            var w: std.Io.Writer = .fixed(out);
            image.bmp.encode(&w, src, .{}, &.{}) catch return null;
            return w.buffered().len;
        }
    };
}
