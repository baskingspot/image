//! JPEG reconstruction's rows: rebuild the JPEG a JPEG XL file was
//! transcoded from, from memory per call into the output buffer, as
//! libjxl's arm does, with work memory that grows to the largest input's
//! and is reused, as a caller that keeps it would.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "jxl-jbrd", rebuild },
    .{ "jxl-jbrd-progressive", rebuild },
};

var work: []u8 = &.{};

fn rebuild(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var x: image.jxl.JpegReconstructor = .init(&r, .{ .limits = .none, .seeker = .fixed(&r) });
    const len = x.workLen() catch return null;
    if (len > work.len) {
        // Untouched pages cost no memory, so the mapping is not filled.
        const gpa = std.heap.page_allocator;
        if (work.len != 0) gpa.rawFree(work, .@"64", @returnAddress());
        work = &.{};
        const p = gpa.rawAlloc(len, .@"64", @returnAddress()) orelse return null;
        work = p[0..len];
    }
    var w: std.Io.Writer = .fixed(out);
    x.run(&w, work[0..len]) catch return null;
    return w.end;
}
