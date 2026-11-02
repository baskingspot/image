//! WebP against libwebp, the bar, and Wuffs (test/oracle/webp.c), in
//! RGBA8, BGRA8 (the native format of a lossless image), and RGB8.
//!
//! An animation's answer is its last canvas, every frame composited as
//! libwebp's animation decoder composites them: `Decoder` here disposes of
//! each frame to transparent black before the next, so every frame's
//! pixels, regions, and errors count. libwebp's demuxer checks every chunk
//! of the file before it decodes a frame, and this package checks each as
//! it streams past, so a file that breaks the rules after a frame is
//! rejected by both, at different points.
//!
//! The libraries disagree, and the expected splits are:
//!
//! - Wuffs composites onto black when asked for RGB8 from an image with
//!   alpha; libwebp and this package drop the alpha (`image.convert`'s
//!   rule), so Wuffs's RGB8 answers are left out.
//! - Wuffs gives a simple prefix code's two symbols their codes in the
//!   order they are written; the specification builds a canonical code from
//!   the lengths, so the smaller symbol gets code 0, as libwebp and this
//!   package do. libwebp's encoder writes them in increasing order, so only
//!   generated streams split.
//! - libwebp hands a VP8L decoder every byte after the chunk header, not
//!   just the chunk's, so a stream that runs past its chunk's declared size
//!   into the bytes after it decodes; Wuffs and this package stop at the
//!   chunk's end (`Truncated`).
//! - Wuffs rejects an ALPH chunk beside a VP8L one, and an ICCP chunk the
//!   VP8X flags do not announce; libwebp and this package skip the first,
//!   as the specification says to, and read the chunks that are there.
//!   Wuffs accepts some streams cut short that libwebp and this package
//!   reject.
//! - Lossy: libwebp, Wuffs, and this package let a still image's
//!   partitions run past the VP8 chunk to the end of the input, but this
//!   package keeps the partitions before the last only up to the RIFF
//!   payload's end (its work memory is sized by the payload), so one that
//!   runs past it is `Truncated` here (docs/slop/webp.md).
//! - Lossy with alpha: Wuffs's colors under an alpha of 0 differ from
//!   libwebp's in places; this package matches libwebp's. A lossless
//!   alpha stream whose last symbol reads past its end decodes in libwebp
//!   from its bit window wrapped around (docs/slop/webp.md); this package
//!   rejects it, as Wuffs does.
//! - Animation: Wuffs does not decode animations, and no answer in RGB8
//!   counts: a canvas without alpha cannot hold the transparent pixels
//!   later frames blend over, so this package's RGB8 canvas differs from
//!   libwebp's RGBA canvas with the alpha dropped. An ALPH chunk is decoded
//!   before the VP8 chunk after it is read, at the size the ANMF chunk
//!   gives, so this package rejects a frame with alpha whose bitstream is
//!   another size, which libwebp decodes at the bitstream's size.

const std = @import("std");
const image = @import("image");

pub const name = "webp";
pub const fuzz = @import("fuzz").webp;
pub const oracles = [_][]const u8{ "webp-libwebp", "webp-wuffs" };
pub const formats = [_]image.PixelFormat{ .rgba8, .bgra8, .rgb8 };

/// Whether `op`'s answer in `format` counts (see above).
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    if (format == .rgb8 and animated(input)) return false;
    if (std.mem.eql(u8, op, "webp-wuffs") and format == .rgb8) return false;
    return true;
}

/// Whether `input` is an animation: its VP8X chunk sets the flag, as
/// webp.c checks.
fn animated(input: []const u8) bool {
    return input.len >= 21 and std.mem.eql(u8, input[0..4], "RIFF") and
        std.mem.eql(u8, input[12..16], "VP8X") and input[20] & 0x02 != 0;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}

/// The region under a frame disposed to the background, kept in case it was
/// the last; compare.zig's pixel limit is 1 << 22, at up to 4 bytes a
/// pixel. One per thread, since compare.zig compares on every core.
threadlocal var saved: [(1 << 22) * 4]u8 = undefined;

/// This package's decoder, compositing every frame of an animation into the
/// one canvas compare.zig asks for, as libwebp's animation decoder leaves
/// it after the last frame.
pub const Decoder = struct {
    d: image.webp.Decoder,

    pub const Options = image.webp.Decoder.Options;

    pub fn init(reader: *std.Io.Reader, options: Options) Decoder {
        return .{ .d = .init(reader, options) };
    }

    pub fn decodeConfig(c: *Decoder) image.webp.Decoder.Error!image.Config {
        return c.d.decodeConfig();
    }

    pub fn decodeFrame(c: *Decoder, dst: image.PixelBuffer, work: []u8) image.webp.Decoder.Error!?image.Frame {
        var last = (try c.d.decodeFrame(dst, work)) orelse return null;
        const bpp = dst.format.bytesPerPixel();
        while (true) {
            const region = dst.sub(last.x, last.y, last.width, last.height);
            const row_len = @as(usize, last.width) * bpp;
            if (last.disposal == .background) for (0..last.height) |y| {
                const row = region.row(@intCast(y));
                @memcpy(saved[y * row_len ..][0..row_len], row);
                @memset(row, 0);
            };
            const next = (try c.d.decodeFrame(dst, work)) orelse {
                if (last.disposal == .background) for (0..last.height) |y| {
                    @memcpy(region.row(@intCast(y)), saved[y * row_len ..][0..row_len]);
                };
                return last;
            };
            last = next;
        }
    }
};
