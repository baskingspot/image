//! GIF's rows: decode a whole file from memory per call into RGBA8, with
//! work memory from a static buffer, as a caller that reuses it would.
//! `gif-decode` writes the first frame; `gif-decode-anim` plays every frame
//! into the canvas as a player does, applying each frame's disposal before
//! the next, and leaves the last frame.
//!
//! The encode rows (bench/corpus/gif_encode.sh) write raw RGBA8 to a file
//! in memory with the default options: `gif-encode` and `gif-encode-few`
//! a still, `gif-encode-anim` an animation of whole-canvas frames, 10
//! hundredths of a second each, which the encoder crops. A frame whose next
//! canvas is transparent where it is opaque is disposed to background, as
//! GIF needs for the next to show; the rest are left in place.

const std = @import("std");
const image = @import("image");
const input = @import("input.zig");

pub const ops = .{
    .{ "gif-decode", first },
    .{ "gif-decode-anim", all },
    .{ "gif-encode", encode },
    .{ "gif-encode-few", encode },
    .{ "gif-encode-anim", encodeAnim },
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

/// The encoder's work memory and an animation's frames, kept between
/// calls as `work` is.
var enc_work: []u8 = &.{};
var frames: [64]image.gif.AnimationFrame = undefined;

fn encodeWork(width: u32, height: u32) ?[]u8 {
    const need = image.gif.workLen(.{}, width, height) orelse return null;
    if (enc_work.len < need) {
        std.heap.page_allocator.free(enc_work);
        enc_work = std.heap.page_allocator.alloc(u8, need) catch return null;
    }
    return enc_work[0..need];
}

fn encode(in: []const u8, out: []u8) ?usize {
    const src = input.pixels(in, .rgba8) orelse return null;
    const w = encodeWork(src.width, src.height) orelse return null;
    var writer: std.Io.Writer = .fixed(out);
    image.gif.encode(&writer, src, .{}, w) catch return null;
    return writer.end;
}

fn encodeAnim(in: []const u8, out: []u8) ?usize {
    const n = input.bytesPerPixel(in) / 4;
    if (n == 0 or n > frames.len) return null;
    const canvas = in.len / n;
    const first_frame = input.pixels(in[0..canvas], .rgba8) orelse return null;
    const width = first_frame.width;
    const height = first_frame.height;
    for (frames[0..n], 0..) |*f, i| {
        const pixels = in[i * canvas ..][0..canvas];
        const next = if (i + 1 < n) in[(i + 1) * canvas ..][0..canvas] else pixels;
        f.* = .{
            .pixels = image.PixelBuffer.init(@constCast(pixels), .rgba8, width, height) catch return null,
            .duration = image.flicks_per_second / 10,
            .disposal = if (clears(pixels, next)) .background else .none,
        };
    }
    const w = encodeWork(width, height) orelse return null;
    var writer: std.Io.Writer = .fixed(out);
    image.gif.encodeAnimation(&writer, width, height, frames[0..n], .{}, w) catch return null;
    return writer.end;
}

/// Whether canvas `next` is transparent where `canvas` is opaque.
fn clears(canvas: []const u8, next: []const u8) bool {
    var i: usize = 3;
    while (i < canvas.len) : (i += 4) {
        if (canvas[i] >= 128 and next[i] < 128) return true;
    }
    return false;
}
