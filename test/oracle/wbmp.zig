//! WBMP against Wuffs, the bar, and ImageMagick (test/oracle/wbmp.c).

const std = @import("std");
const image = @import("image");

pub const name = "wbmp";
pub const Decoder = image.wbmp.Decoder;
pub const fuzz = @import("fuzz").wbmp;
pub const oracles = [_][]const u8{ "wbmp-wuffs", "wbmp-magick" };
/// The native format and two that convert.
pub const formats = [_]image.PixelFormat{ .gray8, .rgba8, .bgra8 };

pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = .{ op, format, input };
    return true;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = .{ op, arena };
    return input;
}
