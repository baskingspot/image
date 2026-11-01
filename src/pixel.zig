//! Pixel formats and the caller's pixel buffer.
//!
//! A decoder writes the `PixelFormat` the caller asks for and reports the
//! source's native one (`Config.native`), so a caller can ask for that and
//! skip conversion. Every format is interleaved. Samples wider than a byte
//! are in the machine's byte order, so a 16-bit buffer can be viewed as
//! `[]u16` and a float one as `[]f32` when it is aligned.

const std = @import("std");
const testing = std.testing;

/// How a pixel is laid out in memory: channel order, sample type, and
/// whether color is premultiplied by alpha.
pub const PixelFormat = enum(u8) {
    gray8,
    gray_alpha8,
    gray_alpha8_premul,
    rgb8,
    bgr8,
    rgba8,
    rgba8_premul,
    bgra8,
    bgra8_premul,
    gray16,
    gray_alpha16,
    gray_alpha16_premul,
    rgb16,
    bgr16,
    rgba16,
    rgba16_premul,
    bgra16,
    bgra16_premul,
    /// 32-bit float samples, nominally 0 to 1, for float and HDR sources.
    rgba_f32,
    rgba_f32_premul,

    /// The type of one sample.
    pub const Sample = enum { u8, u16, f32 };

    /// Where each channel sits in a pixel, in samples. `null` for a channel
    /// the format lacks; gray formats have only `y` (and `a`).
    pub const Channels = struct {
        r: ?u2 = null,
        g: ?u2 = null,
        b: ?u2 = null,
        y: ?u2 = null,
        a: ?u2 = null,
    };

    pub fn sample(f: PixelFormat) Sample {
        return switch (f) {
            .gray8, .gray_alpha8, .gray_alpha8_premul, .rgb8, .bgr8 => .u8,
            .rgba8, .rgba8_premul, .bgra8, .bgra8_premul => .u8,
            .rgba_f32, .rgba_f32_premul => .f32,
            else => .u16,
        };
    }

    /// The number of samples per pixel: 1 to 4.
    pub fn channelCount(f: PixelFormat) usize {
        return switch (f) {
            .gray8, .gray16 => 1,
            .gray_alpha8, .gray_alpha8_premul, .gray_alpha16, .gray_alpha16_premul => 2,
            .rgb8, .bgr8, .rgb16, .bgr16 => 3,
            else => 4,
        };
    }

    pub fn bytesPerSample(f: PixelFormat) usize {
        return switch (f.sample()) {
            .u8 => 1,
            .u16 => 2,
            .f32 => 4,
        };
    }

    pub fn bytesPerPixel(f: PixelFormat) usize {
        return f.channelCount() * f.bytesPerSample();
    }

    pub fn hasAlpha(f: PixelFormat) bool {
        return f.channels().a != null;
    }

    pub fn isPremultiplied(f: PixelFormat) bool {
        return switch (f) {
            .gray_alpha8_premul, .rgba8_premul, .bgra8_premul => true,
            .gray_alpha16_premul, .rgba16_premul, .bgra16_premul, .rgba_f32_premul => true,
            else => false,
        };
    }

    pub fn isGray(f: PixelFormat) bool {
        return f.channels().y != null;
    }

    pub fn channels(f: PixelFormat) Channels {
        return switch (f) {
            .gray8, .gray16 => .{ .y = 0 },
            .gray_alpha8, .gray_alpha8_premul, .gray_alpha16, .gray_alpha16_premul => .{ .y = 0, .a = 1 },
            .rgb8, .rgb16 => .{ .r = 0, .g = 1, .b = 2 },
            .bgr8, .bgr16 => .{ .b = 0, .g = 1, .r = 2 },
            .rgba8, .rgba8_premul, .rgba16, .rgba16_premul => .{ .r = 0, .g = 1, .b = 2, .a = 3 },
            .rgba_f32, .rgba_f32_premul => .{ .r = 0, .g = 1, .b = 2, .a = 3 },
            .bgra8, .bgra8_premul, .bgra16, .bgra16_premul => .{ .b = 0, .g = 1, .r = 2, .a = 3 },
        };
    }

    /// The bytes `width` pixels take, or null if that overflows `usize`.
    pub fn rowBytes(f: PixelFormat, width: u32) ?usize {
        return std.math.mul(usize, width, f.bytesPerPixel()) catch null;
    }
};

/// The caller's pixel memory: `height` rows of `width` pixels in `format`,
/// each row starting `stride` bytes after the one before. Decoders write
/// into it and never keep it.
pub const PixelBuffer = struct {
    pixels: []u8,
    format: PixelFormat,
    width: u32,
    height: u32,
    /// Bytes from the start of one row to the start of the next; at least
    /// `width * format.bytesPerPixel()`.
    stride: usize,

    pub const Error = error{
        /// The buffer is smaller than its dimensions and stride need, or
        /// the stride is narrower than a row.
        BufferTooSmall,
    };

    /// A buffer of tightly packed rows. Fails if `pixels` is too short.
    pub fn init(pixels: []u8, format: PixelFormat, width: u32, height: u32) Error!PixelBuffer {
        const packed_row = format.rowBytes(width) orelse return error.BufferTooSmall;
        return initStride(pixels, format, width, height, packed_row);
    }

    /// A buffer whose rows are `stride` bytes apart. Fails if the stride is
    /// narrower than a row or `pixels` is too short.
    pub fn initStride(pixels: []u8, format: PixelFormat, width: u32, height: u32, stride: usize) Error!PixelBuffer {
        const pb: PixelBuffer = .{
            .pixels = pixels,
            .format = format,
            .width = width,
            .height = height,
            .stride = stride,
        };
        try pb.check();
        return pb;
    }

    /// The number of bytes a tightly packed buffer of these dimensions
    /// takes, or null if it overflows `usize`.
    pub fn len(format: PixelFormat, width: u32, height: u32) ?usize {
        const packed_row = format.rowBytes(width) orelse return null;
        return std.math.mul(usize, packed_row, height) catch null;
    }

    /// Checks that every row fits in `pixels`. Decoders call this before
    /// writing, since the fields are public.
    pub fn check(pb: PixelBuffer) Error!void {
        const packed_row = pb.format.rowBytes(pb.width) orelse return error.BufferTooSmall;
        if (pb.stride < packed_row) return error.BufferTooSmall;
        if (pb.height == 0 or packed_row == 0) return;
        const before_last = std.math.mul(usize, pb.stride, pb.height - 1) catch return error.BufferTooSmall;
        const need = std.math.add(usize, before_last, packed_row) catch return error.BufferTooSmall;
        if (pb.pixels.len < need) return error.BufferTooSmall;
    }

    /// Row `y`, exactly `width` pixels long. Asserts `y < height` and a
    /// buffer that passed `check`.
    pub fn row(pb: PixelBuffer, y: u32) []u8 {
        std.debug.assert(y < pb.height);
        const start = pb.stride * y;
        return pb.pixels[start..][0 .. pb.width * pb.format.bytesPerPixel()];
    }

    /// The `width` by `height` region at (`x`, `y`), sharing this buffer's
    /// memory. Asserts the region fits.
    pub fn sub(pb: PixelBuffer, x: u32, y: u32, width: u32, height: u32) PixelBuffer {
        std.debug.assert(@as(u64, x) + width <= pb.width);
        std.debug.assert(@as(u64, y) + height <= pb.height);
        const start = pb.stride * y + @as(usize, x) * pb.format.bytesPerPixel();
        return .{
            .pixels = if (width == 0 or height == 0) pb.pixels[0..0] else pb.pixels[start..],
            .format = pb.format,
            .width = width,
            .height = height,
            .stride = pb.stride,
        };
    }
};

test "pixel format layout" {
    try testing.expectEqual(4, PixelFormat.rgba8.bytesPerPixel());
    try testing.expectEqual(3, PixelFormat.bgr8.bytesPerPixel());
    try testing.expectEqual(8, PixelFormat.bgra16_premul.bytesPerPixel());
    try testing.expectEqual(16, PixelFormat.rgba_f32.bytesPerPixel());
    try testing.expectEqual(2, PixelFormat.gray16.bytesPerPixel());
    try testing.expect(PixelFormat.gray_alpha8_premul.isPremultiplied());
    try testing.expect(!PixelFormat.rgba8.isPremultiplied());
    try testing.expect(!PixelFormat.rgb16.hasAlpha());
    try testing.expectEqual(@as(?u2, 2), PixelFormat.bgra8.channels().r);
    // Every format's channel map names distinct positions below its count.
    for (std.enums.values(PixelFormat)) |f| {
        const c = f.channels();
        var seen: u4 = 0;
        inline for (.{ "r", "g", "b", "y", "a" }) |name| {
            if (@field(c, name)) |i| {
                try testing.expect(i < f.channelCount());
                try testing.expect(seen & (@as(u4, 1) << i) == 0);
                seen |= @as(u4, 1) << i;
            }
        }
        try testing.expectEqual(f.channelCount(), @popCount(seen));
        try testing.expectEqual(f.isGray(), c.r == null);
    }
}

test "pixel buffer bounds" {
    var mem: [64]u8 = undefined;
    const pb = try PixelBuffer.init(&mem, .rgba8, 4, 4);
    try testing.expectEqual(16, pb.row(3).len);
    try testing.expectError(error.BufferTooSmall, PixelBuffer.init(&mem, .rgba8, 4, 5));
    try testing.expectError(error.BufferTooSmall, PixelBuffer.initStride(&mem, .rgba8, 4, 2, 12));
    // The last row needs only its own pixels, not a whole stride.
    const strided = try PixelBuffer.initStride(mem[0..56], .rgba8, 2, 4, 16);
    try testing.expectEqual(8, strided.row(3).len);
    try testing.expectError(error.BufferTooSmall, PixelBuffer.initStride(&mem, .rgba16, std.math.maxInt(u32), 1, 0));
    const s = pb.sub(1, 2, 2, 1);
    try testing.expectEqual(@intFromPtr(&mem) + 2 * 16 + 4, @intFromPtr(s.row(0).ptr));
    try testing.expectEqual(8, s.row(0).len);
    try testing.expectEqual(null, PixelBuffer.len(.rgba_f32, std.math.maxInt(u32), std.math.maxInt(u32)));
}
