//! JPEG XL's JPEG reconstruction against libjxl (test/oracle/jxl_jbrd.c),
//! the reference decoder's rebuild of the original JPEG (djxl's path to a
//! .jpg). The comparison carries pixels, so each side hands over the JPEG's
//! bytes as a gray8 image one row high and as wide as the file: two answers
//! agree when the files are the same bytes. A file over the comparison's
//! pixel limit in bytes is a rejection on both sides.

const std = @import("std");
const image = @import("image");

pub const name = "jxl_jbrd";
pub const fuzz = @import("fuzz").jxl_jbrd;
pub const oracles = [_][]const u8{"jxl_jbrd-libjxl"};
pub const formats = [_]image.PixelFormat{.gray8};

/// image.jxl.JpegReconstructor behind the decoder interface. The
/// comparison makes decoders it only asks for a configuration, so nothing
/// is kept between calls: `decodeConfig` rebuilds the JPEG for its length,
/// and `decodeFrame` rebuilds it into the pixel buffer.
pub const Decoder = struct {
    input: []const u8,
    max_len: u64,

    pub fn init(r: *std.Io.Reader, options: image.DecodeOptions) Decoder {
        return .{ .input = r.buffer[r.seek..r.end], .max_len = options.limits.max_pixels };
    }

    pub fn decodeConfig(d: *Decoder) !image.Config {
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try d.rebuild(&counter.writer);
        const len = counter.fullCount();
        if (len == 0 or len > d.max_len) return error.ImageTooLarge;
        return .{ .width = @intCast(len), .height = 1, .native = .gray8 };
    }

    pub fn decodeFrame(d: *Decoder, dst: image.PixelBuffer, _: []u8) !?image.Frame {
        if (dst.format != .gray8 or dst.height != 1) return error.Unsupported;
        var w: std.Io.Writer = .fixed(dst.pixels[0..dst.width]);
        try d.rebuild(&w);
        if (w.end != dst.width) return error.Truncated;
        return .{ .width = dst.width, .height = 1 };
    }

    fn rebuild(d: *const Decoder, w: *std.Io.Writer) !void {
        const gpa = std.heap.smp_allocator;
        var r: std.Io.Reader = .fixed(d.input);
        var x = image.jxl.JpegReconstructor.init(&r, .{ .seeker = .fixed(&r) });
        const work = try gpa.alloc(u8, try x.workLen());
        defer gpa.free(work);
        try x.run(w, work);
        try w.flush();
    }
};

pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = op;
    _ = format;
    _ = input;
    return true;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}
