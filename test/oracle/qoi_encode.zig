//! The QOI encoder against qoi.h's encoder, byte for byte, through the
//! oracle's encode op (`qoi-qoih-encode` in test/oracle/qoi.c). The sources
//! are what our decoder reads from QOI's corpus and fuzzed QOI streams,
//! whose pixels exercise every chunk the encoder can choose, as RGBA and as
//! RGB, so every image is encoded with four channels and with three. Both
//! encoders write colorspace 0, sRGB.

const std = @import("std");
const image = @import("image");

pub const name = "qoi_encode";
pub const fuzz = @import("fuzz").qoi;
/// Reads the sources from the inputs.
pub const Decoder = image.qoi.Decoder;
pub const oracles = [_][]const u8{"qoi-qoih-encode"};
pub const formats = [_]image.PixelFormat{ .rgba8, .rgb8 };

pub fn encode(w: *std.Io.Writer, src: image.PixelBuffer, arena: std.mem.Allocator) !void {
    _ = arena;
    try image.qoi.encode(w, src, .{}, &.{});
}
