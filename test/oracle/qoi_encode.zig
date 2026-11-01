//! The QOI encoder against qoi.h's encoder, byte for byte. The harness
//! compares decoders, so this side's `Decoder` "decodes" a QOI file into
//! the file our encoder writes for its pixels, as a one-row gray8 image
//! whose width is the file's length; the oracle (`qoi-qoih-encode` in
//! test/oracle/qoi.c) does the same with qoi.h's decoder and encoder. The
//! inputs are QOI's corpus and fuzzed QOI streams, whose pixels exercise
//! every chunk the encoder can choose.
//!
//! Only files our decoder accepts with a nonzero size count
//! (`comparable`): qoi.h's decoder accepts streams ours rejects
//! (test/oracle/qoi.zig) and rejects empty images, and those say nothing
//! about the encoder. A colorspace byte other than 0 or 1, which qoi.h
//! rejects, reaches it as 0 (`adapt`), and our encoder writes 0 for it too.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const qoi = @import("qoi.zig");

pub const name = "qoi_encode";
pub const fuzz = @import("fuzz").qoi;
pub const oracles = [_][]const u8{"qoi-qoih-encode"};
pub const formats = [_]image.PixelFormat{.gray8};

pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = .{ op, format };
    var r: Io.Reader = .fixed(input);
    var d: image.qoi.Decoder = .init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
    const config = d.decodeConfig() catch return false;
    if (config.width == 0 or config.height == 0) return false;
    const dst = image.PixelBuffer.init(&pixels, config.native, config.width, config.height) catch return false;
    _ = d.decodeFrame(dst, &.{}) catch return false;
    return true;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    return qoi.adapt("qoi-qoih", input, arena);
}

/// compare.zig's pixel limit.
const max_pixels = 1 << 22;
/// Per thread, since compare.zig runs batches on every core.
threadlocal var pixels: [max_pixels * 4]u8 = undefined;
threadlocal var file: [max_pixels * 5 + 22]u8 = undefined;

/// Decodes a QOI file with our decoder and encodes its pixels with our
/// encoder; the "image" is the encoded file.
pub const Decoder = struct {
    reader: *Io.Reader,
    options: Options,
    len: ?usize = null,

    pub const Options = image.DecodeOptions;

    pub fn init(reader: *Io.Reader, options: Options) Decoder {
        return .{ .reader = reader, .options = options };
    }

    pub fn decodeConfig(d: *Decoder) !image.Config {
        if (d.len == null) {
            var q: image.qoi.Decoder = .init(d.reader, d.options);
            const config = try q.decodeConfig();
            const src = try image.PixelBuffer.init(&pixels, config.native, config.width, config.height);
            _ = try q.decodeFrame(src, &.{});
            var w: Io.Writer = .fixed(&file);
            const transfer = config.metadata.transfer orelse .srgb;
            try image.qoi.encode(&w, src, .{ .transfer = transfer }, &.{});
            d.len = w.end;
        }
        return .{ .width = @intCast(d.len.?), .height = 1, .native = .gray8 };
    }

    pub fn decodeFrame(d: *Decoder, dst: image.PixelBuffer, work: []u8) !?image.Frame {
        _ = work;
        const config = try d.decodeConfig();
        @memcpy(dst.pixels[0..config.width], file[0..config.width]);
        return .{ .width = config.width, .height = 1 };
    }
};
