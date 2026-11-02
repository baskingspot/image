//! JPEG against libjpeg-turbo, the bar, and Wuffs (test/oracle/jpeg.c), in
//! RGB, for grayscale images gray, and for CMYK and YCCK images their inks
//! (`cmyk8`, `cmyk16`), each 8- and 16-bit. libjpeg-turbo's decoding choices
//! are its defaults, which this package matches bit for bit (owner
//! decision 2), so any pixel it writes differently is a mismatch.
//!
//! libjpeg-turbo runs strict, every warning an error but three that leave
//! the pixels alone (jpeg.c), and with two settings changed:
//!
//! - No SIMD. Its SIMD IDCT dequantizes in 16 bits and saturates its
//!   results, where its C IDCT computes in 64 bits and wraps them; they
//!   agree on every file an encoder writes, and this package follows the C
//!   code on the corrupt rest.
//! - No block smoothing. For a progressive image whose scans leave any of
//!   the first nine AC coefficients unrefined, libjpeg-turbo estimates
//!   them from the neighboring blocks' DC (T.81 K.8's suggestion, with its
//!   own 5×5 filter); this package does not, so it writes what the scans
//!   coded. A complete progression, as every encoder writes, is unaffected.
//!
//! The references disagree, and the expected splits are:
//!
//! - Wuffs's pixels differ from libjpeg-turbo's on some images (its own
//!   upsampling at the image edges and for other sampling layouts), and it
//!   accepts or rejects some damaged files differently.
//!
//! Wuffs decodes only 8-bit Huffman-coded DCT images, and its 16-bit
//! output only widens them, so `comparable` leaves out its answer for the
//! other processes and for 16-bit formats.

const std = @import("std");
const image = @import("image");

pub const name = "jpeg";
pub const fuzz = @import("fuzz").jpeg;
pub const oracles = [_][]const u8{ "jpeg-turbo", "jpeg-wuffs" };
pub const formats = [_]image.PixelFormat{ .rgb8, .gray8, .rgb16, .gray16, .cmyk8, .cmyk16 };

/// This package's decoder with its default options, but asked for a CMYK
/// format, with `cmyk = .raw`: the inks as stored, which libjpeg-turbo
/// writes as JCS_CMYK. (The default reads a CMYK image as RGB, so its
/// `cmyk8` would be the naive conversion inverted.) Raw only for CMYK
/// formats, as a 12-bit image's raw `cmyk16` narrows to RGB at 16 bits,
/// not at the image's precision as the default and libjpeg-turbo do.
///
/// compare.zig reads each input from a fixed reader, which buffers all of
/// it, so the raw decoder reads the same bytes afresh.
pub const Decoder = struct {
    d: image.jpeg.Decoder,
    input: []const u8,
    options: Options,

    pub const Options = image.jpeg.Decoder.Options;
    pub const Error = image.jpeg.Decoder.Error;

    pub fn init(reader: *std.Io.Reader, options: Options) Decoder {
        return .{ .d = .init(reader, options), .input = reader.buffered(), .options = options };
    }

    /// The default decoder's configuration, with work memory for both:
    /// raw needs less at 8 bits, where it writes the inks without a row to
    /// convert them from, and more past them, where its native row has
    /// four channels to the default's three.
    pub fn decodeConfig(c: *Decoder) Error!image.Config {
        var config = try c.d.decodeConfig();
        var r: std.Io.Reader = .fixed(c.input);
        var d = c.rawDecoder(&r);
        config.work_len = @max(config.work_len, (try d.decodeConfig()).work_len);
        return config;
    }

    pub fn decodeFrame(c: *Decoder, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        if (!dst.format.isCmyk()) return c.d.decodeFrame(dst, work);
        var r: std.Io.Reader = .fixed(c.input);
        var d = c.rawDecoder(&r);
        _ = try d.decodeConfig();
        return d.decodeFrame(dst, work);
    }

    fn rawDecoder(c: *const Decoder, r: *std.Io.Reader) image.jpeg.Decoder {
        var options = c.options;
        options.cmyk = .raw;
        return .init(r, options);
    }
};

/// Whether `op`'s answer counts: Wuffs's only for 8-bit Huffman-coded DCT
/// images in 8-bit formats.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    if (!std.mem.eql(u8, op, "jpeg-wuffs")) return true;
    if (format != .rgb8 and format != .gray8) return false;
    const sof = firstSof(input) orelse return true;
    return switch (sof.marker) {
        0xc0, 0xc1, 0xc2 => sof.precision == 8,
        else => false,
    };
}

const Sof = struct { marker: u8, precision: u8 };

/// The first SOF marker and its precision, walking the segments from SOI.
fn firstSof(input: []const u8) ?Sof {
    if (input.len < 4 or input[0] != 0xff or input[1] != 0xd8) return null;
    var at: usize = 2;
    while (at + 4 < input.len) {
        if (input[at] != 0xff) {
            at += 1;
            continue;
        }
        const m = input[at + 1];
        if (m == 0xff or m == 0 or m == 0x01 or (m >= 0xd0 and m <= 0xd8)) {
            at += if (m == 0xff) 1 else 2;
            continue;
        }
        if (m == 0xda or m == 0xd9) return null;
        if (m >= 0xc0 and m <= 0xcf and m != 0xc4 and m != 0xc8 and m != 0xcc) {
            return .{ .marker = m, .precision = input[at + 4] };
        }
        at += @as(usize, 2) + std.mem.readInt(u16, input[at + 2 ..][0..2], .big);
    }
    return null;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}
