//! PNG's encoder rows: raw RGB or RGBA pixels (bench/corpus/tga.sh's
//! tga/rgba), encoded at the default effort and at `fast`, with work memory
//! from a static buffer, as a caller that reuses it would.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "png-encode", Encode(.{}).run },
    .{ "png-encode-fast", Encode(.{ .effort = .fast }).run },
};

/// Enough work memory for the corpus's widest image.
var work: [4 << 20]u8 = undefined;

fn Encode(comptime options: image.png.EncodeOptions) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            const format: image.PixelFormat = if (input.bytesPerPixel(in) == 4) .rgba8 else .rgb8;
            const src = input.pixels(in, format) orelse return null;
            const len = image.png.workLen(options, src.width, src.height) orelse return null;
            if (len > work.len) return null;
            var writer: std.Io.Writer = .fixed(out);
            image.png.encode(&writer, src, options, work[0..len]) catch return null;
            return writer.end;
        }
    };
}
