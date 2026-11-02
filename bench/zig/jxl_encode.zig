//! JPEG XL's encode rows: raw 8-bit RGB or RGBA pixels (bench/corpus/
//! jxl_encode.sh) encoded losslessly, one row per libjxl effort from 1 to
//! 9, each at the effort of ours nearest it in size and speed: `fast` for
//! 1 to 3, `default` for 4 to 7, `best` for 8 and 9. Work memory grows to
//! the largest input's and is reused, as a caller that keeps it would.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "jxl-encode-e1", Encode(.fast).run },
    .{ "jxl-encode-e2", Encode(.fast).run },
    .{ "jxl-encode-e3", Encode(.fast).run },
    .{ "jxl-encode-e4", Encode(.default).run },
    .{ "jxl-encode-e5", Encode(.default).run },
    .{ "jxl-encode-e6", Encode(.default).run },
    .{ "jxl-encode-e7", Encode(.default).run },
    .{ "jxl-encode-e8", Encode(.best).run },
    .{ "jxl-encode-e9", Encode(.best).run },
};

var work: []u8 = &.{};

fn Encode(comptime effort: image.jxl.Effort) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            const format: image.PixelFormat = switch (input.bytesPerPixel(in)) {
                3 => .rgb8,
                4 => .rgba8,
                else => return null,
            };
            const src = input.pixels(in, format) orelse return null;
            const options: image.jxl.EncodeOptions = .{ .effort = effort };
            const len = image.jxl.workLen(options, src.width, src.height) orelse return null;
            if (len > work.len) {
                // Untouched pages cost no memory, so the mapping is not filled.
                const gpa = std.heap.page_allocator;
                if (work.len != 0) gpa.rawFree(work, .@"64", @returnAddress());
                work = &.{};
                const p = gpa.rawAlloc(len, .@"64", @returnAddress()) orelse return null;
                work = p[0..len];
            }
            var writer: std.Io.Writer = .fixed(out);
            image.jxl.encode(&writer, src, options, work[0..len]) catch return null;
            return writer.end;
        }
    };
}
