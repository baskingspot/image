//! The PNG encoder's fuzz target: `harness.checkEncoder` through each
//! effort, filter, and with reduction off, and an APNG round trip of up to
//! four frames in mixed pixel formats, regions, disposals, and blends.
//! `generate` builds pixels from a few colors, often gray, opaque, or with
//! one transparent color, so that every palette depth, gray depth, and
//! tRNS key comes up.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

const png = image.png;
const PixelBuffer = image.PixelBuffer;
const PixelFormat = image.PixelFormat;

pub const name = "png_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

/// The option sets `checkEncoder` runs, one per input.
const variants = [_]png.EncodeOptions{
    .{},
    .{ .effort = .fast },
    .{ .effort = .best },
    .{ .reduce = false },
    .{ .filter = .none },
    .{ .filter = .sub },
    .{ .filter = .up },
    .{ .filter = .average },
    .{ .filter = .paeth },
};

pub fn check(input: []const u8, choice: u64) !void {
    switch (choice % variants.len) {
        inline 0...variants.len - 1 => |i| try harness.checkEncoder(As(variants[i]), input, choice / variants.len),
        else => unreachable,
    }
    try checkAnimation(input, choice);
}

/// image.png with `options` as the default.
fn As(comptime options: png.EncodeOptions) type {
    return struct {
        pub const EncodeOptions = struct {};
        pub const Decoder = png.Decoder;

        pub fn workLen(_: EncodeOptions, width: u32, height: u32) ?usize {
            return png.workLen(options, width, height);
        }

        pub fn encode(w: *std.Io.Writer, src: PixelBuffer, _: EncodeOptions, work: []u8) png.EncodeError!void {
            return png.encode(w, src, options, work);
        }
    };
}

const max_side = 32;
var frame_pixels: [4][max_side * max_side * 16]u8 = undefined;
var file: [1 << 20]u8 = undefined;
var canvas: [max_side * max_side * 8]u8 = undefined;
var want: [max_side * max_side * 8]u8 = undefined;
var work_mem: [4 << 20]u8 = undefined;

/// Encodes up to four frames made from `input` as an APNG and decodes it:
/// every frame must come back with its region, duration, disposal, and,
/// where it replaces its region, its pixels converted to the native format.
fn checkAnimation(input: []const u8, choice: u64) !void {
    if (input.len < 4) return;
    const width: u32 = 1 + input[0] % max_side;
    const height: u32 = 1 + input[1] % max_side;
    const count: usize = 1 + input[2] % 4;
    const body = input[3..];
    const formats = std.enums.values(PixelFormat);
    var frames: [4]png.AnimationFrame = undefined;
    var c = choice;
    var at: usize = 0;
    for (frames[0..count], 0..) |*f, i| {
        const format = formats[c % formats.len];
        c /= formats.len;
        var fw = width;
        var fh = height;
        var x: u32 = 0;
        var y: u32 = 0;
        if (i > 0) {
            fw = 1 + body[at % body.len] % width;
            fh = 1 + body[(at + 1) % body.len] % height;
            x = body[(at + 2) % body.len] % (width - fw + 1);
            y = body[(at + 3) % body.len] % (height - fh + 1);
            at += 4;
        }
        const len = PixelBuffer.len(format, fw, fh).?;
        const px = frame_pixels[i][0..len];
        for (px, 0..) |*b, k| b.* = body[(at + k) % body.len];
        at += 7;
        if (format.sample() == .f32) {
            const floats: []align(1) f32 = @ptrCast(px);
            for (floats, 0..) |*v, k| v.* = @as(f32, @floatFromInt(body[(at + k) % body.len])) / 255;
        }
        f.* = .{
            .pixels = PixelBuffer.init(px, format, fw, fh) catch unreachable,
            .x = x,
            .y = y,
            // Whole milliseconds, which fcTL holds exactly.
            .duration = @as(u64, body[at % body.len]) * image.flicks_per_second / 1000,
            .disposal = @enumFromInt(c % 3),
            .blend = @enumFromInt(c / 3 % 2),
        };
        c /= 6;
    }
    const options = variants[c % variants.len];
    const work_len = png.workLen(options, width, height) orelse return error.EncodeFailed;
    var w: std.Io.Writer = .fixed(&file);
    const all = frames[0..count];
    png.encodeAnimation(&w, width, height, all, options, work_mem[0..work_len]) catch return error.EncodeFailed;

    var r: std.Io.Reader = .fixed(w.buffered());
    var d = png.Decoder.init(&r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.frame_count != @as(u32, @intCast(count))) return error.RoundTripDiffers;
    if (config.width != width or config.height != height) return error.RoundTripDiffers;
    const native = config.native;
    const bpp = native.bytesPerPixel();
    const dst = PixelBuffer.init(canvas[0 .. width * height * bpp], native, width, height) catch unreachable;
    for (frames[0..count], 0..) |f, i| {
        const got = (d.decodeFrame(dst, work_mem[0..config.work_len]) catch return error.RoundTripDiffers) orelse
            return error.RoundTripDiffers;
        const p = f.pixels;
        if (got.x != f.x or got.y != f.y) return error.RoundTripDiffers;
        if (got.width != p.width or got.height != p.height) return error.RoundTripDiffers;
        if (got.duration != f.duration) return error.RoundTripDiffers;
        const disposal: image.Frame.Disposal = if (i == 0 and f.disposal == .previous) .background else f.disposal;
        if (got.disposal != disposal) return error.RoundTripDiffers;
        const expect = PixelBuffer.init(want[0 .. p.width * p.height * bpp], native, p.width, p.height) catch
            unreachable;
        image.convert.convertBuffer(expect, p) catch unreachable;
        // A blended frame changes its region exactly as replacing would when
        // it is opaque; the decoder's compositing is checked elsewhere.
        if (f.blend == .src_over and i > 0 and !isOpaque(expect)) continue;
        const region = dst.sub(f.x, f.y, p.width, p.height);
        for (0..p.height) |row| {
            if (!std.mem.eql(u8, region.row(@intCast(row)), expect.row(@intCast(row)))) return error.RoundTripDiffers;
        }
    }
    const after = d.decodeFrame(dst, work_mem[0..config.work_len]) catch return error.RoundTripDiffers;
    if (after != null) return error.RoundTripDiffers;
}

fn isOpaque(b: PixelBuffer) bool {
    const a = b.format.channels().a orelse return true;
    const size = b.format.bytesPerSample();
    for (0..b.height) |y| {
        const row = b.row(@intCast(y));
        var i: usize = a * size;
        while (i < row.len) : (i += b.format.bytesPerPixel()) {
            for (row[i..][0..size]) |x| if (x != 255) return false;
        }
    }
    return true;
}

/// Two size bytes (and a frame count for the animation), then pixels drawn
/// from a few colors of a few bytes each: gray, opaque, or with one
/// transparent color now and then.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    buf[0] = random.int(u8);
    buf[1] = random.int(u8);
    buf[2] = random.int(u8);
    if (random.uintLessThan(u8, 4) == 0) {
        const len = 4 + random.uintLessThan(usize, @min(buf.len, 2048) - 4);
        random.bytes(buf[3..len]);
        return buf[0..len];
    }
    // A pixel of 1 to 16 bytes, so it lines up with some pixel format.
    const sizes = [_]usize{ 1, 2, 3, 4, 6, 8, 16 };
    const size = sizes[random.uintLessThan(usize, sizes.len)];
    const colors = 1 + random.uintLessThan(usize, if (random.boolean()) 4 else 300);
    const gray = random.boolean();
    const opaque_tail = random.boolean();
    var palette: [300][16]u8 = undefined;
    for (palette[0..colors]) |*p| {
        random.bytes(p[0..size]);
        if (gray) @memset(p[1..size], p[0]);
        if (opaque_tail) @memset(p[size - @min(size, 2) .. size], 255);
    }
    // One transparent color.
    if (random.boolean()) @memset(palette[0][size - @min(size, 2) .. size], 0);
    const pixels = 1 + random.uintLessThan(usize, (@min(buf.len, 4096) - 3) / size);
    for (0..pixels) |i| {
        @memcpy(buf[3 + i * size ..][0..size], palette[random.uintLessThan(usize, colors)][0..size]);
    }
    return buf[0 .. 3 + pixels * size];
}

/// Seeds for the coverage-guided fuzzer.
pub const seeds = [_][]const u8{
    "\x05\x03\x02" ++ "\x01\x02\x03\x04" ** 8,
    "\x2f\x01\x01" ++ "\x80" ** 64 ++ "\x01\x02",
    "\x07\x07\x03" ++ "\x10\x10\x10\xff\x20\x20\x20\xff\x00\x00\x00\x00" ** 4,
};

test "png_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
