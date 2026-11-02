//! WebP's rows: decode a whole file from memory per call into RGBA8, with
//! work memory from a static buffer, as a caller that reuses it would.
//! Only the pages a file uses are touched. An animation plays every frame,
//! disposing of each to transparent black before the next, and leaves the
//! last, as libwebp's animation decoder does.

const std = @import("std");
const image = @import("image");

pub const ops = .{
    .{ "webp-decode-lossless", rgba },
    .{ "webp-decode-lossless-large", rgba },
    .{ "webp-decode-lossy", rgba },
    .{ "webp-decode-anim", anim },
};

var work: [256 << 20]u8 = undefined;
/// The region under an animation's frame disposed to the background, kept
/// between calls as `work` is.
var saved: []u8 = &.{};

fn rgba(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.webp.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, .rgba8, c.width, c.height) catch return null;
    _ = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    return dst.stride * dst.height;
}

fn anim(in: []const u8, out: []u8) ?usize {
    var r: std.Io.Reader = .fixed(in);
    var d: image.webp.Decoder = .init(&r, .{ .limits = .none });
    const c = d.decodeConfig() catch return null;
    if (c.work_len > work.len) return null;
    const dst = image.PixelBuffer.init(out, .rgba8, c.width, c.height) catch return null;
    var f = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse return null;
    while (true) {
        // The region under a frame disposed to the background is kept in
        // case the frame was the last.
        const region = dst.sub(f.x, f.y, f.width, f.height);
        const row_len = @as(usize, f.width) * 4;
        if (f.disposal == .background) {
            const need = row_len * f.height;
            if (saved.len < need) {
                std.heap.page_allocator.free(saved);
                saved = std.heap.page_allocator.alloc(u8, need) catch return null;
            }
            for (0..f.height) |y| {
                @memcpy(saved[y * row_len ..][0..row_len], region.row(@intCast(y)));
                @memset(region.row(@intCast(y)), 0);
            }
        }
        f = (d.decodeFrame(dst, work[0..c.work_len]) catch return null) orelse {
            if (f.disposal == .background) for (0..f.height) |y| {
                @memcpy(region.row(@intCast(y)), saved[y * row_len ..][0..row_len]);
            };
            return dst.stride * dst.height;
        };
    }
}
