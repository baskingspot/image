//! The lossy WebP encoder's rows: raw RGB8 pixels (RGBA8 for the alpha
//! row) to a file in memory at quality 75, at each effort, with work
//! memory from a static buffer, as a caller that reuses it would. Only the
//! pages a call touches count toward peak RSS.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "webp-encode-lossy", default },
    .{ "webp-encode-lossy-fast", fast },
    .{ "webp-encode-lossy-best", best },
    .{ "webp-encode-lossy-rgba", rgba },
};

var work: [512 << 20]u8 = undefined;

fn encode(in: []const u8, out: []u8, effort: image.webp.lossy.Effort) ?usize {
    const format: image.PixelFormat = if (input.bytesPerPixel(in) == 4) .rgba8 else .rgb8;
    const src = input.pixels(in, format) orelse return null;
    // Work memory for compressing alpha only when there can be alpha, as a
    // caller that knows its pixels would ask.
    const options: image.webp.lossy.EncodeOptions = .{
        .quality = 75,
        .effort = effort,
        .alpha_compression = format == .rgba8,
    };
    const n = image.webp.lossy.workLen(options, src.width, src.height) orelse return null;
    if (n > work.len) return null;
    var writer: std.Io.Writer = .fixed(out);
    image.webp.lossy.encode(&writer, src, options, work[0..n]) catch return null;
    return writer.end;
}

fn default(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .default);
}

fn fast(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .fast);
}

fn best(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .best);
}

/// RGBA input, whose alpha goes to an ALPH chunk where it is not opaque.
fn rgba(in: []const u8, out: []u8) ?usize {
    return encode(in, out, .default);
}
