//! The TIFF encoder against libtiff, the bar, in two comparisons.
//!
//! `tiff_encode`: libtiff writes each source with the same settings
//! (`tiff-libtiff-encode` in test/oracle/tiff_encode.c), and its file must
//! be ours byte for byte once its IFD, values, and strips are moved to
//! where our encoder puts them. The move is needed because libtiff writes
//! the IFD after the strips, going back to fill in the header's offset,
//! and our encoder writes to a stream that cannot go back, so its IFD comes
//! first (src/tiff/encode.zig). Every byte of every entry, value, and strip
//! is compared. The sources are what our decoder reads from TIFF's corpus
//! and fuzzed TIFF files, in each format the encoder stores unconverted;
//! the settings follow from the size, `(width * 31 + height * 17) % 4`
//! picking no compression, PackBits, LZW, or LZW with Predictor 2, with a
//! palette where the encoder would choose one. Deflate is not compared
//! here: libtiff's zlib and `compress` make different streams of the same
//! data, both valid.
//!
//! `tiff_encode_readback`: libtiff reads files our encoder writes, from
//! random sources with random options (every compression, Deflate too,
//! predictor, palette, strip size, density, and a second page), and must
//! read the pixels our decoder reads, through `tiff-raw` and `tiff-rgba`
//! with test/oracle/tiff.zig's rules; the fuzz target checks that our
//! decoder reads back the source.

const std = @import("std");
const image = @import("image");
const tiff_oracle = @import("tiff.zig");
const encoder_oracle = @This();

pub const name = "tiff_encode";
pub const fuzz = @import("fuzz").tiff;
/// Reads the sources from the inputs.
pub const Decoder = tiff_oracle.Decoder;
pub const oracles = [_][]const u8{"tiff-libtiff-encode"};
pub const formats = [_]image.PixelFormat{
    .gray8, .gray_alpha8, .gray_alpha8_premul, .rgb8,                .rgba8, .rgba8_premul, .gray16,
    .rgb16, .rgba16,      .rgba16_premul,      .gray_alpha16_premul, .cmyk8, .cmyk16,
};

/// The settings both encoders use for an image of this size.
fn settings(width: u32, height: u32) image.tiff.EncodeOptions {
    const k = (width *% 31 +% height *% 17) % 4;
    const compression: image.tiff.Compression = switch (k) {
        0 => .none,
        1 => .packbits,
        else => .lzw,
    };
    return .{ .compression = compression, .predictor = k == 3 };
}

pub fn encode(w: *std.Io.Writer, src: image.PixelBuffer, arena: std.mem.Allocator) !void {
    const options = settings(src.width, src.height);
    const len = image.tiff.workLen(options, src.width, src.height) orelse return error.ImageTooLarge;
    try image.tiff.encode(w, src, options, try arena.alloc(u8, len));
}

/// libtiff reading our encoder's files.
pub const readback = struct {
    pub const name = "tiff_encode_readback";
    pub const fuzz = Written;
    pub const Decoder = encoder_oracle.Decoder;
    pub const oracles = tiff_oracle.oracles;
    pub const formats = tiff_oracle.formats;
    pub const comparable = tiff_oracle.comparable;
    pub const adapt = tiff_oracle.adapt;
};

/// Inputs for `readback`: files our encoder writes. `generate` runs under
/// the comparison's lock, one input at a time, so its buffers are shared.
const Written = struct {
    pub const corpus: [0][]const u8 = .{};
    pub const extensions: [0][]const u8 = .{};

    /// A page's pixels at most, and its rows: two pages, their strip
    /// arrays at a row a strip, and twice the pixels for incompressible
    /// LZW fit in the 64 KiB an input may take.
    const max_raw = 8 << 10;
    const max_height = 1024;
    var pixels: [2][max_raw]u8 = undefined;
    var work: [2 << 20]u8 = undefined;

    pub fn generate(random: std.Random, buf: []u8) []u8 {
        const all = std.enums.values(image.PixelFormat);
        const options: image.tiff.EncodeOptions = .{
            .compression = random.enumValue(image.tiff.Compression),
            .predictor = random.boolean(),
            .palette = random.uintLessThan(u8, 4) != 0,
            .effort = random.enumValue(image.tiff.Effort),
            .rows_per_strip = if (random.boolean()) null else 1 + random.uintLessThan(u32, 40),
            .density = if (random.boolean()) null else .{
                .x = 1 + random.uintLessThan(u32, 10000),
                .y = 1 + random.uintLessThan(u32, 10000),
                .unit = random.enumValue(image.Density.Unit),
            },
        };
        var pages: [2]image.PixelBuffer = undefined;
        const count = 1 + random.uintLessThan(usize, 2);
        for (pages[0..count], 0..) |*p, i| {
            const format = all[random.uintLessThan(usize, all.len)];
            const bpp = format.bytesPerPixel();
            const w = 1 + random.uintLessThan(u32, 64);
            const h = 1 + random.uintLessThan(u32, @intCast(@min(max_height, @max(1, max_raw / (w * bpp)))));
            const px = pixels[i][0 .. w * h * bpp];
            const colors = 1 + random.uintLessThan(usize, 6);
            var palette: [6][16]u8 = undefined;
            for (&palette) |*c| random.bytes(c);
            const noise = random.boolean();
            var k: usize = 0;
            while (k < w * h) : (k += 1) {
                if (noise) random.bytes(px[k * bpp ..][0..bpp]) else @memcpy(
                    px[k * bpp ..][0..bpp],
                    palette[random.uintLessThan(usize, colors)][0..bpp],
                );
            }
            if (format.sample() == .f32) {
                const f: []align(1) f32 = @ptrCast(px);
                for (f) |*v| v.* = @as(f32, @floatFromInt(random.int(u8))) / 255;
            }
            p.* = image.PixelBuffer.init(px, format, w, h) catch unreachable;
        }
        const len = image.tiff.workLen(options, 64, max_height).?;
        var out: std.Io.Writer = .fixed(buf);
        image.tiff.encodePages(&out, pages[0..count], options, work[0..len]) catch return buf[0..0];
        return out.buffered();
    }
};
