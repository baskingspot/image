//! An encode row's input (bench/README.md, "Arm contract"): raw pixels,
//! tightly packed, at the size the harness reads from the input's name.

const image = @import("image");

extern var bench_width: u32;
extern var bench_height: u32;

/// The input's bytes per pixel: its length over its pixels.
pub fn bytesPerPixel(in: []const u8) usize {
    const n = @as(usize, bench_width) * bench_height;
    return if (n == 0) 0 else in.len / n;
}

/// The input as `format` pixels, or null when its length is not exactly
/// that. The encoders take a mutable view and only read it.
pub fn pixels(in: []const u8, format: image.PixelFormat) ?image.PixelBuffer {
    if (in.len != @as(usize, bench_width) * bench_height * format.bytesPerPixel()) return null;
    return image.PixelBuffer.init(@constCast(in), format, bench_width, bench_height) catch null;
}
