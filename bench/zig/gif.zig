//! GIF's rows: decode a whole file from memory per call into RGBA8, with
//! work memory from a static buffer, as a caller that reuses it would.
//! `gif-decode` writes the first frame; `gif-decode-anim` plays every frame
//! into the canvas as a player does, applying each frame's disposal before
//! the next, and leaves the last frame.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "gif-decode", first },
    .{ "gif-decode-anim", all },
};

var work: [1 << 17]u8 = undefined;
/// The region under a frame whose disposal is `previous`, kept between
/// calls as `work` is.
var saved: []u8 = &.{};

fn first(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.gif.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, .rgba8, c.width, c.height) catch return null;
    _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    return dst.stride * dst.height;
}

fn all(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.gif.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, .rgba8, c.width, c.height) catch return null;
    var next = d.decodeFrameConfig() catch return null;
    while (next) |f| {
        const region = dst.sub(f.x, f.y, f.width, f.height);
        const row_len = @as(usize, f.width) * 4;
        if (f.disposal == .previous) {
            const need = row_len * f.height;
            if (saved.len < need) {
                std.heap.page_allocator.free(saved);
                saved = std.heap.page_allocator.alloc(u8, need) catch return null;
            }
            for (0..f.height) |y| @memcpy(saved[y * row_len ..][0..row_len], region.row(@intCast(y)));
        }
        _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
        next = d.decodeFrameConfig() catch return null;
        if (next == null) break;
        if (f.width == 0) continue;
        for (0..f.height) |y| {
            const row = region.row(@intCast(y));
            switch (f.disposal) {
                .none => {},
                .background => @memset(row, 0),
                .previous => @memcpy(row, saved[y * row_len ..][0..row_len]),
            }
        }
    }
    return dst.stride * dst.height;
}
