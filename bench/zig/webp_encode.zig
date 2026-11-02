//! WebP lossless encode rows: raw RGB or RGBA pixels
//! (bench/corpus/webp_encode.sh) to a file in memory, one row per effort
//! level, matching cwebp's `-z` levels. The work memory is kept between
//! calls and grown when an input needs more, as a caller that reuses it
//! would.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "webp-encode-z0", Encode(0).run },
    .{ "webp-encode-z1", Encode(1).run },
    .{ "webp-encode-z2", Encode(2).run },
    .{ "webp-encode-z3", Encode(3).run },
    .{ "webp-encode-z4", Encode(4).run },
    .{ "webp-encode-z5", Encode(5).run },
    .{ "webp-encode-z6", Encode(6).run },
    .{ "webp-encode-z7", Encode(7).run },
    .{ "webp-encode-z8", Encode(8).run },
    .{ "webp-encode-z9", Encode(9).run },
};

var work: []u8 = &.{};

fn Encode(comptime effort: u4) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            const format: image.PixelFormat = if (input.bytesPerPixel(in) == 4) .rgba8 else .rgb8;
            const src = input.pixels(in, format) orelse return null;
            const options: image.webp.EncodeOptions = .{ .effort = effort };
            const len = image.webp.workLen(options, src.width, src.height) orelse return null;
            if (work.len < len) {
                std.heap.page_allocator.free(work);
                work = std.heap.page_allocator.alloc(u8, len) catch return null;
            }
            var writer: std.Io.Writer = .fixed(out);
            image.webp.encode(&writer, src, options, work[0..len]) catch return null;
            return writer.end;
        }
    };
}
