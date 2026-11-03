//! JPEG XL against libjxl, the reference decoder (test/oracle/jxl.c), in
//! RGBA16, straight or premultiplied as the image stores its alpha, and
//! float RGBA. libjxl converts samples to floats and writes 16 bits
//! rounding to nearest even, which this package matches. (Its 8-bit
//! output is dithered; jxl.c narrows its 16-bit output by the high byte
//! when asked for RGBA8, but 8 bits would only repeat the 16-bit check.)
//!
//! Images whose frames are all drawn in integers (lossless Modular) must
//! match exactly. A frame drawn in floats (VarDCT, XYB, the restoration
//! filters, upsampling, patches, splines, noise) leaves the arithmetic
//! open within the conformance suite's error bounds, so `toleranceFor`
//! gives those images room, found from the frame headers before the
//! decode (`Decoder.skim`):
//!
//! - 4 steps of 16 bits a sample (plan.md decision 77). Floats that
//!   differ from libjxl's by a few 1e-5, in the sRGB curve's linear
//!   segment, whose slope 12.92 amplifies a few 1e-6 in linear light,
//!   round up to 4 steps of 65535 apart: 2.8 steps at most on the
//!   conformance files, and 3.4 on a fuzzed XYB frame far out of gamut
//!   (SHA-256 9377fe64..., 0.0216350 against 0.0215836). The conformance
//!   suite allows more (its tightest peak is 0.004 of full scale, 262
//!   steps); 4 holds this decoder to the reference's arithmetic, as close
//!   as the floats allow.
//! - With splines, the conformance suite's own bound, peak 0.004 and RMS
//!   1e-4 of full scale (262 and 6.55 steps): a spline's erf is an
//!   approximation the specification does not fix, and libjxl's and this
//!   decoder's differ by up to 52 steps on animation_spline (RMS 0.9).
//!
//! Left out of the comparison:
//!
//! - What this decoder does not decode (`error.Unsupported`).
//! - Containers whose `ftyp` box has a minor version above 1 or no
//!   compatible brand: libjxl refuses them, where the specification's
//!   reader (and this decoder) reads on.
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
const Oracle = @import("Oracle.zig");

pub const name = "jxl";
pub const fuzz = @import("fuzz").jxl;
pub const oracles = [_][]const u8{"jxl-libjxl"};
pub const formats = [_]image.PixelFormat{ .rgba16, .rgba16_premul, .rgba_f32 };

/// Exact for frames drawn in integers, else the room above.
pub fn toleranceFor(input: []const u8) ?Oracle.Tolerance {
    var r: std.Io.Reader = .fixed(input);
    var d: image.jxl.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    const gpa = std.heap.page_allocator;
    const raw = gpa.rawAlloc(c.work_len, .@"64", @returnAddress()) orelse return null;
    defer gpa.rawFree(raw[0..c.work_len], .@"64", @returnAddress());
    // The frames before an error still count, since they decode.
    var s: image.jxl.Decoder.Skim = .{};
    if (d.skim(raw[0..c.work_len], &s)) {} else |_| {}
    if (s.splines) return .{ .peak = 262, .rms = 6.55 };
    if (s.float) return .{ .peak = 4 };
    return null;
}

/// image.jxl.Decoder, with work memory it maps itself. The comparison
/// allocates an input's work memory with `alloc`, which in safe builds
/// writes 0xaa over all of it, and this decoder's bound is hundreds of
/// megabytes, mostly untouched; so this wrapper reports none and maps its
/// own for each frame with `rawAlloc`. It also notes, for
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

const Verdict = struct {
    extensions: bool = false,
    unsupported: bool = false,
    float: bool = false,
};

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
    if (v.extensions or v.unsupported or libjxlRefusesFtyp(input)) return false;
    return (format.sample() == .f32) == v.float;
}

/// Whether `input` is a container whose `ftyp` box libjxl refuses: a
/// minor version above 1, or no compatible brand.
fn libjxlRefusesFtyp(input: []const u8) bool {
    if (input.len < 28 or !std.mem.eql(u8, input[0..12], "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a")) return false;
    if (!std.mem.eql(u8, input[16..20], "ftyp")) return false;
    const size = std.mem.readInt(u32, input[12..16], .big);
    return size < 20 or std.mem.readInt(u32, input[24..28], .big) > 1;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}
