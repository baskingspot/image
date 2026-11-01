//! BMP against Wuffs, the bar, stb_image, and ImageMagick
//! (test/oracle/bmp.c).
//!
//! src/bmp/dib.zig decides every case the format leaves open as Wuffs
//! does, so this package agrees with Wuffs on every bmpsuite file and every
//! fuzzed input; the expected splits are stb_image's and Magick's:
//!
//! - stb_image rejects RLE of any kind, OS/2 2.x headers, the 52- and
//!   56-byte headers (q/rgb32h52, q/rgba32h56), `BI_ALPHABITFIELDS`, masks
//!   that are not whole bytes at 24 and 32 bits, a pixel offset that leaves
//!   room for more than the color table, and 24-bit files with a color
//!   table of more than 256 entries. It accepts files that end early,
//!   filling the rest, and rejects images over its own size limit that the
//!   others decode (b/badwidth, g/pal8topdown).
//! - Magick widens 5- and 6-bit channels by its own scaling rather than
//!   repeating their bits, so every 16-bit file with narrow masks gets
//!   different pixels (g/rgb16*, q/rgba16-*). It rejects a file shorter
//!   than its file header's size (b/badfilesize), an index past the color
//!   table (b/pal8badindex; Wuffs and this package paint it opaque black),
//!   a bad color table size (b/badpalettesize, q/pal8oversizepal), and
//!   several OS/2 variants (q/pal8os2*). It accepts what Wuffs rejects: RLE that runs past the
//!   image (b/badrle*), a bad header size, 16-bit masks wider than 8 bits
//!   (b/rgb16-880), and 64-bit pixels (q/rgba64); and it decodes embedded
//!   JPEG and PNG streams (q/rgb24jpeg, q/rgb24png), which this package
//!   reports as `error.EmbeddedJpeg` and `error.EmbeddedPng`.
//! - bmpsuite's q/ files are the cases its author calls questionable, and
//!   most splits on corpus files are there.
//!
//! None needs `comparable` or `adapt`: this package sides with Wuffs in
//! each split, which the harness counts rather than fails.

const std = @import("std");
const image = @import("image");

pub const name = "bmp";
pub const Decoder = image.bmp.Decoder;
pub const fuzz = @import("fuzz").bmp;
pub const oracles = [_][]const u8{ "bmp-wuffs", "bmp-stb", "bmp-magick" };
pub const formats = [_]image.PixelFormat{ .rgba8, .bgra8 };

/// Every answer counts.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = op;
    _ = format;
    _ = input;
    return true;
}

/// Every oracle sees the input as it is.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}
