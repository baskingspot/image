//! TIFF encoding rows: every source as raw 8-bit RGBA or RGB
//! (bench/corpus/qoi_encode.sh) written as a TIFF file, uncompressed,
//! PackBits, LZW, or Deflate, Predictor 2 with LZW and Deflate, in strips
//! of about 8 KiB, as libtiff writes by default, and no palette. The
//! per-row Deflate row gives every image row its own strip, so that the
//! per-strip cost of starting a stream, which the others hide inside the
//! compression time, is what the row measures.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "tiff-encode-none", Encode(.none, null).run },
    .{ "tiff-encode-packbits", Encode(.packbits, null).run },
    .{ "tiff-encode-lzw", Encode(.lzw, null).run },
    .{ "tiff-encode-deflate", Encode(.deflate, null).run },
    .{ "tiff-encode-deflate-per-row", Encode(.deflate, 1).run },
};

/// The work memory, as a caller keeps it between calls; only the pages an
/// image needs are touched.
var work: [16 << 20]u8 = undefined;

fn Encode(comptime compression: image.tiff.Compression, comptime rows_per_strip: ?u32) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            const format: image.PixelFormat = switch (input.bytesPerPixel(in)) {
                3 => .rgb8,
                4 => .rgba8,
                else => return null,
            };
            const src = input.pixels(in, format) orelse return null;
            // No palette, as the other arms write none.
            const options: image.tiff.EncodeOptions = .{
                .compression = compression,
                .palette = false,
                .rows_per_strip = rows_per_strip,
            };
            const len = image.tiff.workLen(options, src.width, src.height) orelse return null;
            if (len > work.len) return null;
            var w: std.Io.Writer = .fixed(out);
            image.tiff.encode(&w, src, options, work[0..len]) catch return null;
            return w.buffered().len;
        }
    };
}
