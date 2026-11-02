//! The GIF encoder against giflib and Wuffs. Each input, a corpus file or
//! a fuzzed GIF stream as the gif oracle has them, is decoded by our
//! decoder, its frames composited as a player does, and the canvases are
//! encoded by our encoder: as a still for one frame, otherwise as an
//! animation of whole-canvas frames with their delays, which the encoder
//! crops to what changes. A GIF frame's transparent pixels show what is
//! beneath, so a frame whose next canvas is transparent where it is opaque
//! gets disposal background, and every other frame disposal none. The file goes to every decoder: gif-wuffs and
//! gif-giflib (test/oracle/gif.c, through `adapt`) and ours, and all three
//! must read the same final canvas. Where every canvas has at most 256
//! colors, ours must also read back each canvas exactly, or it rejects the
//! input, a mismatch, since the oracles accept the file. An input our
//! decoder rejects becomes an empty file, which every decoder rejects.
//!
//! An animation's canvases are kept up to `max_canvas_bytes`; past that
//! only the final canvas is encoded, as a still.

const std = @import("std");
const image = @import("image");
const gif_oracle = @import("gif.zig");

pub const name = "gif_encode";
pub const fuzz = @import("fuzz").gif;
pub const oracles = [_][]const u8{ "gif-wuffs", "gif-giflib" };
pub const formats = [_]image.PixelFormat{ .rgba8, .bgra8 };

const gpa = std.heap.smp_allocator;
const max_canvas_bytes = 16 << 20;
const max_pixels = 1 << 22;

/// Every oracle decodes our encoder's file for the input.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    const file = reencode(input, arena, false) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return "",
    };
    return file orelse "";
}

const Error = error{ OutOfMemory, RoundTripDiffers };

/// Our encoder's file for what our decoder reads from `input`, or null
/// when it reads nothing. With `verify`, the file must read back exactly
/// when every canvas has at most 256 colors.
fn reencode(input: []const u8, alloc: std.mem.Allocator, verify: bool) Error!?[]u8 {
    var canvases: std.ArrayList([]u8) = .empty;
    defer {
        for (canvases.items) |c| gpa.free(c);
        canvases.deinit(gpa);
    }
    var durations: std.ArrayList(u64) = .empty;
    defer durations.deinit(gpa);
    const config = (try decodeCanvases(input, &canvases, &durations)) orelse return null;
    const width = config.width;
    const height = config.height;
    if (width == 0 or height == 0) return null;

    var frames: std.ArrayList(image.gif.AnimationFrame) = .empty;
    defer frames.deinit(gpa);
    for (canvases.items, durations.items, 0..) |c, d, i| {
        const next = if (i + 1 < canvases.items.len) canvases.items[i + 1] else c;
        try frames.append(gpa, .{
            .pixels = image.PixelBuffer.init(c, .rgba8, width, height) catch unreachable,
            .duration = d,
            .disposal = if (clears(c, next)) .background else .none,
        });
    }
    const options: image.gif.EncodeOptions = .{};
    const work = try gpa.alloc(u8, image.gif.workLen(options, width, height).?);
    defer gpa.free(work);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const encoded = if (frames.items.len == 1)
        image.gif.encode(&aw.writer, frames.items[0].pixels, options, work)
    else
        image.gif.encodeAnimation(&aw.writer, width, height, frames.items, options, work);
    encoded catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        // A canvas grown past GIF's largest side by a frame reaching
        // past the screen: there is no file to write.
        else => return null,
    };
    const file = try aw.toOwnedSlice();
    if (verify) {
        var exact = true;
        for (canvases.items) |c| exact = exact and colorCount(c) <= 256;
        if (exact) try readsBack(file, frames.items);
    }
    return file;
}

/// Decodes `input`, keeping the canvas after each frame (before its
/// disposal), as the gif oracle composites them; null when our decoder
/// rejects the input or reads no frame.
fn decodeCanvases(
    input: []const u8,
    canvases: *std.ArrayList([]u8),
    durations: *std.ArrayList(u64),
) Error!?image.Config {
    var r: std.Io.Reader = .fixed(input);
    var d: gif_oracle.Decoder = .init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
    const config = d.d.decodeConfig() catch return null;
    const len = @as(usize, config.width) * config.height * 4;
    const canvas = try gpa.alloc(u8, len);
    defer gpa.free(canvas);
    const saved = try gpa.alloc(u8, len);
    defer gpa.free(saved);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    @memset(canvas, 0);
    const dst = image.PixelBuffer.init(canvas, .rgba8, config.width, config.height) catch unreachable;
    var kept: usize = 0;
    var overflow = false;
    while (true) {
        const next = d.d.decodeFrameConfig() catch return null;
        const f = next orelse break;
        if (f.disposal == .previous) @memcpy(saved, canvas);
        _ = (d.d.decodeFrame(dst, work) catch return null) orelse return null;
        // Past the limit, only the last canvas.
        overflow = overflow or kept + len > max_canvas_bytes;
        if (overflow) {
            for (canvases.items) |c| gpa.free(c);
            canvases.clearRetainingCapacity();
            durations.clearRetainingCapacity();
        }
        try canvases.append(gpa, try gpa.dupe(u8, canvas));
        try durations.append(gpa, f.duration);
        kept += len;
        var region = f;
        if (region.width == 0) region.height = 0;
        const rect = dst.sub(region.x, region.y, region.width, region.height);
        switch (f.disposal) {
            .none => {},
            .background => for (0..region.height) |y| @memset(rect.row(@intCast(y)), 0),
            .previous => @memcpy(canvas, saved),
        }
    }
    if (canvases.items.len == 0) return null;
    // A still's delay means nothing.
    if (canvases.items.len == 1) durations.items[0] = 0;
    return config;
}

/// How many colors `rgba` has, up to 257.
fn colorCount(rgba: []const u8) usize {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        seen.put(gpa, std.mem.readInt(u32, rgba[i..][0..4], .little), {}) catch return 257;
        if (seen.count() > 256) return 257;
    }
    return seen.count();
}

/// Whether canvas `next` is transparent where `canvas` is opaque. A GIF
/// frame's transparent pixels show what is beneath, so the frame showing
/// `canvas` must clear it (disposal background) for `next` to show.
fn clears(canvas: []const u8, next: []const u8) bool {
    var i: usize = 3;
    while (i < canvas.len) : (i += 4) {
        if (canvas[i] != 0 and next[i] == 0) return true;
    }
    return false;
}

/// Our decoder reads `frames`, whole canvases, back from `file`, each with
/// its disposal.
fn readsBack(file: []const u8, frames: []const image.gif.AnimationFrame) Error!void {
    var r: std.Io.Reader = .fixed(file);
    var d: image.gif.Decoder = .init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    const len = @as(usize, config.width) * config.height * 4;
    const canvas = try gpa.alloc(u8, len);
    defer gpa.free(canvas);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    @memset(canvas, 0);
    const dst = image.PixelBuffer.init(canvas, .rgba8, config.width, config.height) catch unreachable;
    for (frames) |want| {
        const f = (d.decodeFrame(dst, work) catch return error.RoundTripDiffers) orelse return error.RoundTripDiffers;
        if (f.disposal != want.disposal) return error.RoundTripDiffers;
        if (!std.mem.eql(u8, canvas, want.pixels.pixels)) return error.RoundTripDiffers;
        if (f.disposal == .background) {
            const rect = dst.sub(f.x, f.y, f.width, f.height);
            for (0..f.height) |y| @memset(rect.row(@intCast(y)), 0);
        }
    }
    if ((d.decodeFrame(dst, work) catch return error.RoundTripDiffers) != null) return error.RoundTripDiffers;
}

/// Ours: our encoder's file for the input, read by our decoder as the gif
/// oracle reads every file, the whole animation composited. The input's
/// screen is the file's, so `decodeConfig` reads only the input; the
/// encoding happens in `decodeFrame`, which reads the file with work
/// memory of its own.
pub const Decoder = struct {
    input: []const u8,
    d: gif_oracle.Decoder,

    pub const Options = image.DecodeOptions;

    pub fn init(reader: *std.Io.Reader, options: Options) Decoder {
        return .{ .input = reader.buffered(), .d = .init(reader, options) };
    }

    pub fn decodeConfig(c: *Decoder) !image.Config {
        return c.d.decodeConfig();
    }

    pub fn decodeFrame(c: *Decoder, dst: image.PixelBuffer, work: []u8) !?image.Frame {
        _ = work;
        const file = try reencode(c.input, gpa, true) orelse return error.BadHeader;
        defer gpa.free(file);
        var r: std.Io.Reader = .fixed(file);
        var d: gif_oracle.Decoder = .init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
        const config = try d.decodeConfig();
        if (config.width != dst.width or config.height != dst.height) return error.RoundTripDiffers;
        const inner_work = try gpa.alloc(u8, config.work_len);
        defer gpa.free(inner_work);
        return d.decodeFrame(dst, inner_work);
    }
};
