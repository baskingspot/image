//! WebP against libwebp, the bar, and Wuffs (test/oracle/webp.c), in
//! RGBA8, BGRA8 (the native format of a lossless image), and RGB8.
//!
//! Animations are not decoded yet: inputs whose VP8X chunk announces one
//! (`notYet`) are left out for every oracle.
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

const std = @import("std");
const image = @import("image");

pub const name = "webp";
pub const fuzz = @import("fuzz").webp;
pub const oracles = [_][]const u8{ "webp-libwebp", "webp-wuffs" };
pub const formats = [_]image.PixelFormat{ .rgba8, .bgra8, .rgb8 };

/// Whether `op`'s answer in `format` counts (see above).
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    if (notYet(input)) return false;
    if (std.mem.eql(u8, op, "webp-wuffs") and format == .rgb8) return false;
    return true;
}

/// Whether `input`'s VP8X chunk sets the animation flag: what this
/// package does not decode yet.
fn notYet(input: []const u8) bool {
    if (input.len < 21 or !std.mem.eql(u8, input[0..4], "RIFF")) return false;
    return std.mem.eql(u8, input[12..16], "VP8X") and input[20] & 0x02 != 0;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}

/// Work memory, one buffer per thread, reused for every input. compare.zig
/// takes each input's `work_len` from an arena that holds a whole batch and
/// keeps its capacity: blocks of a VP8L image's worst case (its prefix
/// tables alone can span 26 MiB, of which a stream touches little) spread
/// each batch's pixels over gigabytes, and the pages they touch pile up
/// batch after batch until the oracle runs out of memory. So `Decoder`
/// asks compare.zig for no work memory and decodes in this buffer.
threadlocal var own_work: []u8 = &.{};
const own_work_len = 64 << 20;

/// This package's decoder, decoding in `own_work`.
pub const Decoder = struct {
    d: image.webp.Decoder,
    /// `own_work`, when the decoder's work fits it.
    work: ?[]u8 = null,

    pub const Options = image.webp.Decoder.Options;

    pub fn init(reader: *std.Io.Reader, options: Options) Decoder {
        return .{ .d = .init(reader, options) };
    }

    pub fn decodeConfig(c: *Decoder) image.webp.Decoder.Error!image.Config {
        var config = try c.d.decodeConfig();
        if (config.work_len <= own_work_len) {
            if (own_work.len == 0) own_work = std.heap.page_allocator.alloc(u8, own_work_len) catch return config;
            c.work = own_work[0..config.work_len];
            config.work_len = 0;
        }
        return config;
    }

    pub fn decodeFrame(c: *Decoder, dst: image.PixelBuffer, arena_work: []u8) image.webp.Decoder.Error!?image.Frame {
        return c.d.decodeFrame(dst, c.work orelse arena_work);
    }
};
