//! The JPEG encoder against libjpeg-turbo's, byte for byte, through the
//! oracle's encode op (`jpeg-turbo-encode` in test/oracle/jpeg.c). The
//! sources are what our decoder reads from JPEG's corpus and fuzzed JPEG
//! streams, as RGB, as RGBA (whose alpha both encoders drop), and as gray.
//! Each source's size picks the settings, the same on both sides
//! (`settingsFor` here, `settings_for` in jpeg.c): quality, subsampling,
//! baseline or progressive, standard or optimized Huffman tables, and
//! sometimes an EXIF block and an ICC profile, which then takes two APP2
//! segments. libjpeg-turbo's SIMD is off for the whole oracle (jpeg.c);
//! its encoder's SIMD kernels give the same bytes, as the benchmark's
//! checksums show.

const std = @import("std");
const image = @import("image");

pub const name = "jpeg_encode";
pub const fuzz = @import("fuzz").jpeg;
/// Reads the sources from the inputs.
pub const Decoder = image.jpeg.Decoder;
pub const oracles = [_][]const u8{"jpeg-turbo-encode"};
pub const formats = [_]image.PixelFormat{ .rgb8, .rgba8, .gray8 };

const Settings = struct {
    options: image.jpeg.EncodeOptions,
    key: u32,
    exif_len: u32 = 0,
    icc_len: u32 = 0,
};

fn settingsFor(width: u32, height: u32) Settings {
    var k = (width *% 0x9E3779B1) ^ (height *% 0x85EBCA77);
    k ^= k >> 15;
    k *%= 0x2C1B3C6D;
    k ^= k >> 12;
    var s: Settings = .{ .key = k, .options = .{
        .quality = @intCast(1 + k % 100),
        .subsampling = @fromBackingInt(@intCast((k >> 8) % 3)),
        .progressive = (k >> 10) & 1 == 1,
        .optimize = (k >> 11) & 1 == 1,
    } };
    const meta = (k >> 12) & 7;
    if (meta == 5 or meta == 7) s.exif_len = 1 + (k >> 16) % 2000;
    if (meta == 6) s.icc_len = 1 + (k >> 16) % 3000;
    if (meta == 7) s.icc_len = 65520 + (k >> 16) % 70000;
    return s;
}

pub fn encode(w: *std.Io.Writer, src: image.PixelBuffer, arena: std.mem.Allocator) !void {
    var s = settingsFor(src.width, src.height);
    if (s.exif_len > 0) {
        const exif = try arena.alloc(u8, s.exif_len);
        for (exif, 0..) |*b, i| b.* = @truncate(@as(u32, @intCast(i)) *% 131 +% s.key);
        s.options.exif = exif;
    }
    if (s.icc_len > 0) {
        const icc = try arena.alloc(u8, s.icc_len);
        for (icc, 0..) |*b, i| b.* = @truncate(@as(u32, @intCast(i)) *% 71 +% (s.key >> 8));
        s.options.icc = icc;
    }
    // The work memory, coefficients for a whole image when kept, is
    // given back at once rather than piling up in the batch's arena.
    const gpa = std.heap.smp_allocator;
    const work = try gpa.alloc(u8, image.jpeg.workLen(s.options, src.width, src.height).?);
    defer gpa.free(work);
    try image.jpeg.encode(w, src, s.options, work);
}
