//! The lossy WebP encoder against libwebp's decoder: from each input, the
//! fuzz target's `source` reads an image (a corpus file our decoders read,
//! or a size and pixel bytes) and `options` a quality, effort, and
//! metadata; our encoder writes the file, and libwebp (`webp-libwebp`,
//! test/oracle/webp.c) and our decoder must decode it to the same pixels
//! in RGBA8 and RGB8. Lossy files cannot be compared byte for byte with
//! another encoder's, so this is a decoder comparison whose inputs pass
//! through our encoder first: `Decoder` here encodes and then decodes, and
//! `adapt` hands libwebp the same file. An input with no image is handed
//! over as it is, which both reject. The files' fidelity to their sources
//! is the fuzz target's check (test/fuzz/webp_lossy_encode.zig).

const std = @import("std");
const image = @import("image");
const target = @import("fuzz").webp_lossy_encode;

pub const name = "webp_lossy_encode";
pub const fuzz = target;
pub const oracles = [_][]const u8{"webp-libwebp"};
pub const formats = [_]image.PixelFormat{ .rgba8, .rgb8 };

const max_file = 8 << 20;

/// Per thread, since compare.zig compares on every core.
threadlocal var src_buf: [target.max_source_pixels * 16]u8 = undefined;
threadlocal var source_work: [1 << 26]u8 = undefined;
threadlocal var encode_work: [32 << 20]u8 = undefined;
threadlocal var file_buf: [max_file]u8 = undefined;

/// The options for `input`'s image: the fuzz target's for a choice made
/// from the input's hash, so every input picks its own.
fn options(input: []const u8) image.webp.lossy.EncodeOptions {
    return target.optionsFor(input, std.hash.Wyhash.hash(1, input));
}

/// Our encoding of `input`'s image into `out`, or null when it has none.
fn encodeInput(input: []const u8, out: []u8) ?[]const u8 {
    const choice = std.hash.Wyhash.hash(2, input);
    const src = target.source(input, &src_buf, &source_work, choice) orelse return null;
    const o = options(input);
    const len = image.webp.lossy.workLen(o, src.width, src.height) orelse return null;
    if (len > encode_work.len) return null;
    var w: std.Io.Writer = .fixed(out);
    image.webp.lossy.encode(&w, src, o, encode_work[0..len]) catch return null;
    return w.buffered();
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    const file = encodeInput(input, &file_buf) orelse return input;
    return arena.dupe(u8, file);
}

/// Encodes the input's image with our encoder, then decodes the file
/// with our decoder.
pub const Decoder = struct {
    reader: *std.Io.Reader,
    options: Options,
    file: std.Io.Reader = undefined,
    inner: image.webp.Decoder = undefined,

    pub const Options = image.webp.Decoder.Options;

    pub fn init(reader: *std.Io.Reader, o: Options) Decoder {
        return .{ .reader = reader, .options = o };
    }

    pub fn decodeConfig(d: *Decoder) image.webp.Decoder.Error!image.Config {
        const input = d.reader.buffered();
        const file = encodeInput(input, &file_buf) orelse input;
        d.file = .fixed(file);
        d.inner = .init(&d.file, d.options);
        return d.inner.decodeConfig();
    }

    pub fn decodeFrame(d: *Decoder, dst: image.PixelBuffer, work: []u8) image.webp.Decoder.Error!?image.Frame {
        return d.inner.decodeFrame(dst, work);
    }
};
