//! The resize rows: raw pixels resized with `image.resize`'s defaults (or
//! sRGB), to the size each row names, with work memory from a static
//! buffer, as a caller that reuses it would. The C arms compute the same
//! sizes (bench/c/stb-resize.c).

const image = @import("image");
const input = @import("input.zig");
const PixelFormat = image.PixelFormat;

pub const ops = .{
    .{ "resize-gray8-quarter", Resize(.gray8, .quarter, .linear).run },
    .{ "resize-gray8-double", Resize(.gray8, .double, .linear).run },
    .{ "resize-bgra8p-quarter", Resize(.bgra8_premul, .quarter, .linear).run },
    .{ "resize-bgra8p-double", Resize(.bgra8_premul, .double, .linear).run },
    .{ "resize-rgb8-thumb256", Resize(.rgb8, .thumb256, .linear).run },
    .{ "resize-rgb8-thumb1024", Resize(.rgb8, .thumb1024, .linear).run },
    .{ "resize-rgb8-double", Resize(.rgb8, .double, .linear).run },
    .{ "resize-rgba8-half", Resize(.rgba8, .half, .linear).run },
    .{ "resize-rgb8-srgb-thumb256", Resize(.rgb8, .thumb256, .srgb).run },
};

/// The destination's size for a source of `w` by `h`.
const Size = enum {
    quarter,
    half,
    double,
    thumb256,
    thumb1024,

    fn of(s: Size, w: u32, h: u32) [2]u32 {
        return switch (s) {
            .quarter => .{ @max(1, (w + 2) / 4), @max(1, (h + 2) / 4) },
            .half => .{ @max(1, (w + 1) / 2), @max(1, (h + 1) / 2) },
            .double => .{ 2 * w, 2 * h },
            .thumb256 => fit(w, h, 256),
            .thumb1024 => fit(w, h, 1024),
        };
    }

    /// Within `n` by `n`, the aspect ratio kept, rounded.
    fn fit(w: u32, h: u32, n: u64) [2]u32 {
        if (w >= h) return .{ @intCast(n), @intCast(@max(1, (2 * h * n + w) / (2 * w))) };
        return .{ @intCast(@max(1, (2 * w * n + h) / (2 * h))), @intCast(n) };
    }
};

var work: [16 << 20]u8 = undefined;

fn Resize(comptime format: PixelFormat, comptime size: Size, comptime colorspace: image.resize.Colorspace) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            const src = input.pixels(in, format) orelse return null;
            const d = size.of(src.width, src.height);
            const len = image.PixelBuffer.len(format, d[0], d[1]) orelse return null;
            if (len > out.len) return null;
            const dst = image.PixelBuffer.init(out[0..len], format, d[0], d[1]) catch return null;
            const options: image.resize.Options = .{ .colorspace = colorspace };
            const need = image.resize.workLen(format, d[0], d[1], format, src.width, src.height, options) orelse
                return null;
            if (need > work.len) return null;
            image.resize.resize(dst, src, work[0..need], options) catch return null;
            return len;
        }
    };
}
