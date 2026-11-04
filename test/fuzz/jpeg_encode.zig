//! The JPEG encoder's fuzz target. JPEG loses detail, so in place of
//! `harness.checkEncoder`'s exact round trip the target checks the rest of
//! its properties itself: every source pixel format encodes, with any
//! settings `choice` picks, given `workLen` bytes of work memory and not
//! one byte fewer; a writer that drains a few bytes at a time sees the
//! same bytes; and our decoder reads the file back at the source's size.
//! At quality 100 with full-resolution chroma, where the only losses are
//! rounding, each sample must also come back near the source's, and on
//! average nearer still. Byte-for-byte agreement with libjpeg-turbo's
//! encoder is the oracle's to check (test/oracle/jpeg_encode.zig). Images
//! are up to 96 by 96 pixels, so they span MCUs and leave partial ones at
//! both edges, and the generator makes flat and smooth regions, whose
//! blocks end in long zero runs, as well as noise.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const PixelBuffer = image.PixelBuffer;
const PixelFormat = image.PixelFormat;

pub const name = "jpeg_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

const max_side = 96;
const max_pixels = max_side * max_side;

var source: [max_pixels * 16]u8 = undefined;
var files: [2][1 << 20]u8 = undefined;
var work: [1 << 20]u8 = undefined;
var decoded: [max_pixels * 3]u8 = undefined;
var want: [max_pixels * 3]u8 = undefined;
var exif: [300]u8 = @splat(0x45);
var icc: [70000]u8 = @splat(0x49);

pub fn check(input: []const u8, choice: u64) !void {
    if (input.len < 3) return;
    const width: u32 = 1 + input[0] % max_side;
    const height: u32 = 1 + input[1] % max_side;
    const all = std.enums.values(PixelFormat);
    const format = all[choice % all.len];
    var pick = choice / all.len;
    const len = PixelBuffer.len(format, width, height).?;
    const body = input[2..];
    for (source[0..len], 0..) |*b, i| b.* = body[i % body.len];
    // Float samples from arbitrary bytes are often NaN or infinite; keep
    // them in [0, 1] so conversion is defined.
    if (format.sample() == .f32) {
        const floats: []align(1) f32 = @ptrCast(source[0..len]);
        for (floats, 0..) |*f, i| f.* = @as(f32, @floatFromInt(body[i % body.len])) / 255;
    }
    const src = PixelBuffer.init(source[0..len], format, width, height) catch unreachable;

    var options: image.jpeg.EncodeOptions = .{};
    options.quality = if (pick % 4 == 0) 100 else @intCast(pick / 4 % 101);
    pick /= 404;
    options.subsampling = @fromBackingInt(@intCast(pick % 3));
    pick /= 3;
    options.progressive = pick % 2 == 1;
    options.optimize = pick / 2 % 2 == 1;
    pick /= 4;
    if (pick % 5 == 1) options.exif = exif[0 .. 1 + pick / 5 % exif.len];
    // Sometimes long enough for two segments.
    if (pick % 5 == 2) options.icc = icc[0 .. 1 + pick / 5 % icc.len];

    const work_len = image.jpeg.workLen(options, width, height) orelse return error.EncodeFailed;
    if (work_len > work.len) return error.EncodeFailed;
    var w: Io.Writer = .fixed(&files[0]);
    image.jpeg.encode(&w, src, options, work[0..work_len]) catch return error.EncodeFailed;
    const file = w.buffered();
    var short: Io.Writer = .fixed(&files[1]);
    if (image.jpeg.encode(&short, src, options, work[0 .. work_len - 1])) |_| return error.UndersizeAccepted else |e| {
        if (e != error.WorkTooSmall) return error.UndersizeAccepted;
    }
    var drip: harness.Drip = undefined;
    drip.init(&files[1], 1 + choice % 7);
    image.jpeg.encode(&drip.writer, src, options, work[0..work_len]) catch return error.EncodeFailed;
    drip.writer.flush() catch return error.EncodeFailed;
    if (!std.mem.eql(u8, file, files[1][0..drip.len])) return error.ChunkedWriterDiffers;

    var r: Io.Reader = .fixed(file);
    var d = image.jpeg.Decoder.init(&r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.width != width or config.height != height) return error.RoundTripDiffers;
    const native: PixelFormat = if (format.isGray()) .gray8 else .rgb8;
    if (config.native != native) return error.RoundTripDiffers;
    const n = PixelBuffer.len(native, width, height).?;
    const got = PixelBuffer.init(decoded[0..n], native, width, height) catch unreachable;
    if (config.work_len > work.len) return error.RoundTripDiffers;
    _ = d.decodeFrame(got, work[0..config.work_len]) catch return error.RoundTripDiffers;
    if (options.quality != 100 or options.subsampling != .@"4:4:4") return;
    const exact = PixelBuffer.init(want[0..n], native, width, height) catch unreachable;
    image.convert.convertBuffer(exact, src) catch unreachable;
    var total: u64 = 0;
    for (got.pixels, exact.pixels) |a, b| {
        const diff = @abs(@as(i32, a) - b);
        // A coefficient rounded by half a step moves a sample by at most
        // 7.4, a color difference more through the inverse transform's
        // gains, and the conversions round too.
        if (diff > 24) return error.RoundTripDiffers;
        total += diff;
    }
    if (total > 4 * n) return error.RoundTripDiffers;
}

/// A size, then pixels in runs: flat, ramps, repeats of earlier bytes,
/// and noise.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const len = 3 + random.uintLessThan(usize, @min(buf.len - 3, 8192));
    random.bytes(buf[0..3]);
    var i: usize = 3;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 64));
        switch (random.uintLessThan(u8, 4)) {
            0 => @memset(buf[i..][0..n], buf[i - 1]),
            1 => {
                const step = random.uintLessThan(u8, 5) -% 2;
                for (buf[i..][0..n], 0..) |*b, k| b.* = buf[i - 1] +% @as(u8, @truncate(k)) *% step;
            },
            2 => if (i >= 3 + n) @memcpy(buf[i..][0..n], buf[i - n ..][0..n]) else random.bytes(buf[i..][0..n]),
            else => random.bytes(buf[i..][0..n]),
        }
        i += n;
    }
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    "\x0f\x0f" ++ "\x10\x20\x30\x11\x22\x33\x80\x80\x80",
    "\x2f\x10" ++ @as([64]u8, @splat(0)) ++ @as([64]u8, @splat(0xff)),
    "\x00\x00\x7f",
};

test "jpeg_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
