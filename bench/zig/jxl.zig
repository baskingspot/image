//! JPEG XL's rows: decode the first frame of a file from memory per call
//! into RGBA16, as libjxl's and jxl-oxide's arms do, with work memory
//! that grows to the largest input's and is reused, as a caller that
//! keeps it would.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "jxl-decode", rgba16 },
    .{ "jxl-decode-lossless", rgba16 },
};

var work: []u8 = &.{};

fn rgba16(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.jxl.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) {
        // Untouched pages cost no memory, so the mapping is not filled.
        const gpa = std.heap.page_allocator;
        if (work.len != 0) gpa.rawFree(work, .@"64", @returnAddress());
        work = &.{};
        const p = gpa.rawAlloc(c.work_len, .@"64", @returnAddress()) orelse return null;
        work = p[0..c.work_len];
    }
    const dst = image.PixelBuffer.init(out, .rgba16, c.width, c.height) catch return null;
    _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    return dst.stride * dst.height;
}
