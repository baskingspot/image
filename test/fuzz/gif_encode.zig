//! The GIF encoder's fuzz target.
//!
//! Stills go through `harness.checkEncoderWith`, under several options, on
//! images up to 64 by 64 from any pixel format. Our decoder must read back
//! the source as GIF stores it, alpha below 128 transparent black and the
//! rest opaque: exactly when it has at most 256 colors (counting
//! transparency as one), and otherwise within a bound (`bounded`).
//!
//! Animations of two to four frames made from the input, some regions
//! and disposals and some frames unchanged, must decode, composited as a
//! player does, to the frames composited the same way: exactly when every
//! frame has at most 256 colors, and otherwise with the same transparent
//! pixels and colors within the frames' range. They must also come out the
//! same through a writer that drains a few bytes at a time.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const PixelBuffer = image.PixelBuffer;
const gif = image.gif;

pub const name = "gif_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

const max_side = 64;

pub fn check(input: []const u8, choice: u64) !void {
    switch (choice >> 61) {
        0, 1 => try still(.{}, input, choice),
        2 => try still(.{ .dither = .none }, input, choice),
        3 => try still(.{ .dither = .none, .quantizer = .median_cut, .interlace = true }, input, choice),
        4 => try still(.{ .dither = .none, .quantizer = .octree, .refine = 2 }, input, choice),
        5 => try still(.{ .quantizer = .median_cut, .refine = 1, .interlace = true }, input, choice),
        else => try animation(input, choice),
    }
}

fn still(comptime options: gif.EncodeOptions, input: []const u8, choice: u64) !void {
    try harness.checkEncoderWith(With(options), .{
        .max_width = max_side,
        .max_height = max_side,
        .expect = Bound(options.dither != .none).expect,
    }, input, choice);
}

/// The encoder with `options` whatever it is passed, under the names
/// `checkEncoderWith` looks for.
fn With(comptime options: gif.EncodeOptions) type {
    return struct {
        pub const EncodeOptions = gif.EncodeOptions;
        pub const Decoder = gif.Decoder;
        pub fn workLen(_: EncodeOptions, width: u32, height: u32) ?usize {
            return gif.workLen(options, width, height);
        }
        pub fn encode(w: *Io.Writer, src: PixelBuffer, _: EncodeOptions, work: []u8) gif.EncodeError!void {
            return gif.encode(w, src, options, work);
        }
    };
}

/// A file's global color table, every entry of which is one of the
/// image's colors; empty when it has none.
fn globalTable(file: []const u8) []const [3]u8 {
    if (file.len < 13 or file[10] & 0x80 == 0) return &.{};
    const n = @as(usize, 2) << @intCast(file[10] & 7);
    if (file.len < 13 + n * 3) return &.{};
    return @ptrCast(file[13..][0 .. n * 3]);
}

/// RGBA8 as GIF stores it.
fn binarize(rgba: []u8) void {
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        if (rgba[i + 3] < 128) @memset(rgba[i..][0..4], 0) else rgba[i + 3] = 255;
    }
}

/// How many colors `rgba` (binarized) has, counting transparency as one,
/// up to 257.
fn colorCount(rgba: []const u8) usize {
    var seen: [257]u32 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    outer: while (i < rgba.len) : (i += 4) {
        const k = std.mem.readInt(u32, rgba[i..][0..4], .little);
        for (seen[0..n]) |s| if (s == k) continue :outer;
        if (n == 257) return n;
        seen[n] = k;
        n += 1;
    }
    return n;
}

/// What a quantized image may decode to, given the source `want`
/// (binarized RGBA8) and the decode `got`: the same transparent pixels,
/// every color within the source's range in each channel, with 1024
/// opaque pixels or more a mean within 8 of the source's in each channel,
/// and each pixel's color no farther from its source than any entry of the
/// color table, plus twice the distance a 6-bit cell's center can be from
/// its colors (quantize.zig's `Lookup`). With dithering, a pixel maps from
/// its color plus the error its neighbors pass on, at most 16 a channel
/// (quantize.zig's `max_error`), and 1 for rounding, so the slack grows by
/// twice that distance.
fn bounded(want: []const u8, got: []const u8, table: []const [3]u8, dither: bool) bool {
    var lo: [3]u8 = @splat(255);
    var hi: [3]u8 = @splat(0);
    var i: usize = 0;
    while (i < want.len) : (i += 4) {
        if ((want[i + 3] == 0) != (got[i + 3] == 0)) return false;
        if (want[i + 3] == 0) {
            if (!std.mem.eql(u8, got[i..][0..4], &.{ 0, 0, 0, 0 })) return false;
            continue;
        }
        if (got[i + 3] != 255) return false;
        for (0..3) |c| {
            lo[c] = @min(lo[c], want[i + c]);
            hi[c] = @max(hi[c], want[i + c]);
        }
    }
    i = 0;
    while (i < got.len) : (i += 4) {
        if (got[i + 3] == 0) continue;
        for (0..3) |c| if (got[i + c] < lo[c] or got[i + c] > hi[c]) return false;
    }
    var sum: [2][3]i64 = @splat(@splat(0));
    var opaque_pixels: i64 = 0;
    i = 0;
    while (i < want.len) : (i += 4) {
        if (want[i + 3] == 0) continue;
        opaque_pixels += 1;
        for (0..3) |c| {
            sum[0][c] += want[i + c];
            sum[1][c] += got[i + c];
        }
    }
    if (opaque_pixels >= 1024) for (0..3) |c| {
        if (@abs(sum[0][c] - sum[1][c]) > 8 * opaque_pixels) return false;
    };
    if (table.len == 0) return false;
    const diffused: f64 = if (dither) 2 * @sqrt(3.0 * 17 * 17) else 0;
    const slack = 2 * @sqrt(3.0 * 1.5 * 1.5) + diffused + 1e-9;
    i = 0;
    while (i < want.len) : (i += 4) {
        if (want[i + 3] == 0) continue;
        const d = distance(want[i..][0..3], got[i..][0..3]);
        for (table) |*p| if (d > distance(want[i..][0..3], p) + slack) return false;
    }
    return true;
}

fn distance(a: *const [3]u8, b: *const [3]u8) f64 {
    var s: f64 = 0;
    for (0..3) |c| {
        const e = @as(f64, @floatFromInt(a[c])) - @as(f64, @floatFromInt(b[c]));
        s += e * e;
    }
    return @sqrt(s);
}

fn Bound(comptime dither: bool) type {
    return struct {
        /// `want` is the source as RGBA8: binarized, it is the answer when
        /// it has at most 256 colors; otherwise the decode is accepted, by
        /// becoming the answer, when it is within the bound.
        fn expect(want: PixelBuffer, trip: harness.RoundTrip) void {
            binarize(want.pixels);
            if (colorCount(want.pixels) <= 256) return;
            if (bounded(want.pixels, trip.got.pixels, globalTable(trip.file), dither)) {
                @memcpy(want.pixels, trip.got.pixels);
            }
        }
    };
}

// Animations.

const anim_side = 32;
const max_frames = 4;
var frame_pixels: [max_frames][anim_side * anim_side * 4]u8 = undefined;
var files: [2][1 << 20]u8 = undefined;
var anim_work: [8 << 20]u8 = undefined;
var expected: [max_frames][anim_side * anim_side * 4]u8 = undefined;
var canvas: [anim_side * anim_side * 4]u8 = undefined;
var saved: [anim_side * anim_side * 4]u8 = undefined;

fn animation(input: []const u8, choice: u64) !void {
    if (input.len < 4) return;
    const width: u32 = 1 + input[0] % anim_side;
    const height: u32 = 1 + input[1] % anim_side;
    const count: usize = 2 + input[2] % (max_frames - 1);
    const body = input[3..];
    var frames: [max_frames]gif.AnimationFrame = undefined;
    var bits = choice;
    var exact = true;
    for (0..count) |k| {
        // Frame k: a region of the canvas, from the input, some pixels
        // changed from the frame before, or none.
        const f = &frames[k];
        const same_region = k > 0 and bits & 1 == 0;
        bits >>= 1;
        var fw = width;
        var fh = height;
        var fx: u32 = 0;
        var fy: u32 = 0;
        if (same_region) {
            fw = frames[k - 1].pixels.width;
            fh = frames[k - 1].pixels.height;
            fx = frames[k - 1].x;
            fy = frames[k - 1].y;
        } else if (k > 0 and bits & 1 == 1) {
            fw = 1 + @as(u32, @truncate(bits >> 1)) % width;
            fh = 1 + @as(u32, @truncate(bits >> 7)) % height;
            fx = @as(u32, @truncate(bits >> 13)) % (width - fw + 1);
            fy = @as(u32, @truncate(bits >> 19)) % (height - fh + 1);
        }
        bits = std.math.rotr(u64, bits, 25);
        const px = frame_pixels[k][0 .. fw * fh * 4];
        if (same_region and bits & 3 != 0) {
            @memcpy(px, frame_pixels[k - 1][0 .. fw * fh * 4]);
            // A few pixels change, or none.
            if (bits & 3 != 1) for (0..1 + (bits >> 2) % 7) |j| {
                const at = (@as(usize, body[(j + k) % body.len]) * 31 + j * 17 + k) % (fw * fh);
                for (0..4) |c| px[at * 4 + c] = body[(at + 1 + c) % body.len];
            };
        } else {
            for (px, 0..) |*b, i| b.* = body[(i + k * 7) % body.len];
        }
        bits = std.math.rotr(u64, bits, 5);
        binarize(px);
        if (colorCount(px) > 256) exact = false;
        f.* = .{
            .pixels = PixelBuffer.init(px, .rgba8, fw, fh) catch unreachable,
            .x = fx,
            .y = fy,
            .duration = (bits & 0xff) * 7_056_000,
            .disposal = switch (bits >> 8 & 7) {
                0 => .background,
                1 => .previous,
                else => .none,
            },
        };
        bits = std.math.rotr(u64, bits, 11);
    }
    // The frames composited as GIF shows them.
    const row = width * 4;
    @memset(canvas[0 .. row * height], 0);
    for (frames[0..count], 0..) |f, k| {
        if (f.disposal == .previous) @memcpy(saved[0 .. row * height], canvas[0 .. row * height]);
        for (0..f.pixels.height) |y| for (0..f.pixels.width) |x| {
            const p = f.pixels.row(@intCast(y))[x * 4 ..][0..4];
            if (p[3] == 0) continue;
            canvas[(f.y + y) * row + (f.x + x) * 4 ..][0..4].* = p.*;
        };
        @memcpy(expected[k][0 .. row * height], canvas[0 .. row * height]);
        switch (f.disposal) {
            .none => {},
            .background => for (0..f.pixels.height) |y| {
                @memset(canvas[(f.y + y) * row + f.x * 4 ..][0 .. f.pixels.width * 4], 0);
            },
            .previous => @memcpy(canvas[0 .. row * height], saved[0 .. row * height]),
        }
    }

    const options: gif.EncodeOptions = .{
        .dither = if (choice & 1 == 0) .floyd_steinberg else .none,
        .crop = choice & 2 == 0,
        .interlace = choice & 4 != 0,
        .loop_count = @truncate(choice >> 3 & 3),
    };
    const need = gif.workLen(options, width, height) orelse return error.EncodeFailed;
    var w: Io.Writer = .fixed(&files[0]);
    const all = frames[0..count];
    gif.encodeAnimation(&w, width, height, all, options, anim_work[0..need]) catch return error.EncodeFailed;
    const file = w.buffered();
    var drip: harness.Drip = undefined;
    drip.init(&files[1], 1 + choice % 5);
    gif.encodeAnimation(&drip.writer, width, height, all, options, anim_work[0..need]) catch return error.EncodeFailed;
    drip.writer.flush() catch return error.EncodeFailed;
    if (!std.mem.eql(u8, file, files[1][0..drip.len])) return error.ChunkedWriterDiffers;

    // Decode, compositing as a player does.
    var r: Io.Reader = .fixed(file);
    var d: gif.Decoder = .init(&r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.width != width or config.height != height) return error.RoundTripDiffers;
    if (config.loop_count != options.loop_count) return error.RoundTripDiffers;
    var dwork: [1 << 17]u8 = undefined;
    if (config.work_len > dwork.len) return error.RoundTripDiffers;
    const got = canvas[0 .. row * height];
    const dst = PixelBuffer.init(got, .rgba8, width, height) catch unreachable;
    @memset(got, 0);
    for (0..count) |k| {
        const peek = (d.decodeFrameConfig() catch return error.RoundTripDiffers) orelse return error.RoundTripDiffers;
        if (peek.disposal == .previous) @memcpy(saved[0 .. row * height], got);
        const decoded = d.decodeFrame(dst, dwork[0..config.work_len]) catch return error.RoundTripDiffers;
        const f = decoded orelse return error.RoundTripDiffers;
        // Restoring before the first frame clears its region, as the
        // decoder reports it.
        var disposal = frames[k].disposal;
        if (k == 0 and disposal == .previous) disposal = .background;
        if (f.duration != frames[k].duration or f.disposal != disposal) return error.RoundTripDiffers;
        const want = expected[k][0 .. row * height];
        if (exact) {
            if (!std.mem.eql(u8, got, want)) return error.RoundTripDiffers;
        } else if (!inRange(want, got, frames[0..count])) {
            return error.RoundTripDiffers;
        }
        switch (f.disposal) {
            .none => {},
            .background => for (0..f.height) |y| @memset(got[(f.y + y) * row + f.x * 4 ..][0 .. f.width * 4], 0),
            .previous => @memcpy(got, saved[0 .. row * height]),
        }
    }
    if ((d.decodeFrameConfig() catch return error.RoundTripDiffers) != null) return error.RoundTripDiffers;
}

/// The same transparent pixels as `want`, and every color within the
/// range of the frames' opaque colors in each channel: a quantized frame
/// can leave another frame's colors on the canvas.
fn inRange(want: []const u8, got: []const u8, frames: []const gif.AnimationFrame) bool {
    var lo: [3]u8 = @splat(255);
    var hi: [3]u8 = @splat(0);
    for (frames) |f| {
        var i: usize = 0;
        const px = f.pixels.pixels[0 .. @as(usize, f.pixels.width) * f.pixels.height * 4];
        while (i < px.len) : (i += 4) {
            if (px[i + 3] == 0) continue;
            for (0..3) |c| {
                lo[c] = @min(lo[c], px[i + c]);
                hi[c] = @max(hi[c], px[i + c]);
            }
        }
    }
    var i: usize = 0;
    while (i < want.len) : (i += 4) {
        if ((want[i + 3] == 0) != (got[i + 3] == 0)) return false;
        if (got[i + 3] == 0) {
            if (!std.mem.eql(u8, got[i..][0..4], &.{ 0, 0, 0, 0 })) return false;
            continue;
        }
        if (got[i + 3] != 255) return false;
        for (0..3) |c| if (got[i + c] < lo[c] or got[i + c] > hi[c]) return false;
    }
    return true;
}

/// Sizes and pixels from a few colors, or many, with runs.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 4 + random.uintLessThan(usize, @min(buf.len - 4, 8192));
    random.bytes(buf[0..3]);
    const colors = switch (random.uintLessThan(u8, 3)) {
        0 => 1 + random.uintLessThan(usize, 8),
        1 => 1 + random.uintLessThan(usize, 300),
        else => 0,
    };
    var palette: [300][4]u8 = undefined;
    for (palette[0..colors]) |*c| random.bytes(c);
    var i: usize = 3;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 32));
        if (colors == 0) {
            random.bytes(buf[i..][0..n]);
        } else {
            const c = palette[random.uintLessThan(usize, colors)];
            for (buf[i..][0..n], i..) |*b, j| b.* = c[j % 4];
        }
        i += n;
    }
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    "\x07\x05\x02" ++ "\x10\x20\x30\xff\x10\x20\x30\x00\xff\x00\x00\xff",
    "\x2f\x2f\x03" ++ "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11",
};

test "gif_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
