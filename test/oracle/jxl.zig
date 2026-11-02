//! JPEG XL against libjxl, the reference decoder (test/oracle/jxl.c), in
//! RGBA16, straight or premultiplied as the image stores its alpha, and
//! float RGBA. libjxl converts samples to floats and writes 16 bits
//! rounding to nearest even, which this package matches. (Its 8-bit
//! output is dithered; jxl.c narrows its 16-bit output by the high byte
//! when asked for RGBA8, but 8 bits would only repeat the 16-bit check.)
//!
//! Left out of the comparison:
//!
//! - What this decoder does not decode yet (`error.Unsupported`): VarDCT,
//!   XYB, YCbCr, upsampling, the restoration filters, patches, splines,
//!   noise, and LF frames. docs/slop/jxl.md lists the stages.
//! - Files with a header bundle that has extensions (which no encoder
//!   writes): libjxl keeps one bundle's extension state for the next, so
//!   when a frame's restoration filter has extensions and the frame header
//!   has none, it rejects the frame ("Read more extension bits than
//!   budgeted"), where the specification and jxl-oxide read on.
//! - 16-bit answers for images held as floats (float samples or more than
//!   16 bits), and float answers for the others: libjxl and this package
//!   round floats to 16 bits differently at exact ties, and widen 16-bit
//!   samples to floats from different precisions.
//!
//! The reference keeps the stored orientation and does not render spot
//! colors here, as this package does (test/oracle/jxl.c).

const std = @import("std");
const image = @import("image");

pub const name = "jxl";
pub const fuzz = @import("fuzz").jxl;
pub const oracles = [_][]const u8{"jxl-libjxl"};
pub const formats = [_]image.PixelFormat{ .rgba16, .rgba16_premul, .rgba_f32 };

/// image.jxl.Decoder, holding its work memory only while it decodes. The
/// comparison keeps every work buffer a batch of inputs asks for until the
/// batch ends, and this decoder's work memory is large, so this wrapper
/// reports none and allocates its own for each frame. It also notes, for
/// `comparable`, whether the input decoded to `Unsupported` and whether
/// its native format is float.
pub const Decoder = struct {
    inner: image.jxl.Decoder,
    input: []const u8,
    work_len: usize = 0,

    pub fn init(r: *std.Io.Reader, options: image.jxl.Decoder.Options) Decoder {
        return .{ .inner = .init(r, options), .input = r.buffer };
    }

    pub fn decodeConfig(d: *Decoder) !image.Config {
        defer if (d.inner.br.extensions != 0) {
            note(d.input).extensions = true;
        };
        var c = try d.inner.decodeConfig();
        d.work_len = c.work_len;
        c.work_len = 0;
        note(d.input).float = c.native.sample() == .f32;
        return c;
    }

    pub fn decodeFrame(d: *Decoder, dst: image.PixelBuffer, _: []u8) !?image.Frame {
        // rawAlloc, since alloc fills safe builds' memory with 0xaa, which
        // for a bound of hundreds of megabytes outweighs the decode.
        const gpa = std.heap.page_allocator;
        const raw = gpa.rawAlloc(d.work_len, .@"64", @returnAddress()) orelse return error.OutOfMemory;
        const work = raw[0..d.work_len];
        defer gpa.rawFree(work, .@"64", @returnAddress());
        defer if (d.inner.br.extensions != 0) {
            note(d.input).extensions = true;
        };
        return d.inner.decodeFrame(dst, work) catch |e| {
            if (e == error.Unsupported) note(d.input).unsupported = true;
            return e;
        };
    }
};

const Verdict = struct { extensions: bool = false, unsupported: bool = false, float: bool = false };

// Per thread, since the comparison runs batches on every core.
threadlocal var noted_input: []const u8 = &.{};
threadlocal var noted: Verdict = .{};

/// The verdict for `input`, the input this thread decoded last before it
/// asks whether answers count.
fn note(input: []const u8) *Verdict {
    if (input.ptr != noted_input.ptr or input.len != noted_input.len) {
        noted_input = input;
        noted = .{};
    }
    return &noted;
}

/// Whether `op`'s answer in `format` counts (see above).
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = op;
    const v = note(input).*;
    if (v.extensions or v.unsupported) return false;
    return (format.sample() == .f32) == v.float;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}
