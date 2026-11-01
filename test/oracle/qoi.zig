//! QOI against Wuffs, the bar, and qoi.h, the reference decoder
//! (test/oracle/qoi.c).
//!
//! The libraries disagree on streams no encoder writes, and the expected
//! splits are:
//!
//! - qoi.h accepts what Wuffs and this package reject: a missing or wrong
//!   end marker, a stream that ends early (qoi.h repeats the last pixel), and
//!   a run past the last pixel (qoi.h stops at the last pixel). qoi.h
//!   rejects what the others accept: a zero width or height, and a
//!   colorspace byte other than 0 or 1. That byte "does not change the way
//!   data chunks are encoded", so `adapt` hands qoi.h 0 in its place.
//! - Wuffs leaves runs and index chunks out of the index; the specification
//!   puts "each pixel that is seen" in it, as qoi.h and this package do. A
//!   stream that reads an index entry only a run or index chunk wrote gets
//!   different pixels from Wuffs.
//! - Asked for RGBA from a three-channel file, qoi.h writes the alpha the
//!   chunks carry; Wuffs and this package treat the file as RGB and write
//!   opaque pixels. `comparable` leaves those answers of qoi.h out, since
//!   they would hide index splits on the same inputs.
//! - Asked for RGB from a four-channel file, Wuffs and this package
//!   composite over black (`image.convert`'s rule); qoi.h drops the alpha.
//!   `comparable` leaves those answers of qoi.h out too.
//!
//! The official edgecase.qoi is in the first split: Wuffs decodes it
//! differently from qoi.h.

const std = @import("std");
const image = @import("image");

pub const name = "qoi";
pub const Decoder = image.qoi.Decoder;
pub const fuzz = @import("fuzz").qoi;
pub const oracles = [_][]const u8{ "qoi-wuffs", "qoi-qoih" };
/// Each native format, and one that converts.
pub const formats = [_]image.PixelFormat{ .rgba8, .rgb8, .bgra8 };

/// Whether `op`'s answer in `format` counts: not qoi.h's alpha for a
/// three-channel file, nor its dropped alpha for a four-channel one.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    if (input.len <= 12 or !std.mem.eql(u8, op, "qoi-qoih")) return true;
    return switch (input[12]) {
        3 => !format.hasAlpha(),
        4 => format.hasAlpha(),
        else => true,
    };
}

/// The input `op` sees: for qoi.h, colorspace 0 in place of any value it
/// rejects.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (input.len < 14 or input[13] <= 1 or !std.mem.eql(u8, op, "qoi-qoih")) return input;
    const copy = try arena.dupe(u8, input);
    copy[13] = 0;
    return copy;
}
