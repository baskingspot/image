//! The TIFF encoder's fuzz target: `harness.checkEncoder` on images made
//! from the input with the default options and with another compression,
//! predictor, palette, and strip choice, and a multi-page file whose pages
//! must all read back.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const tiff = image.tiff;

pub const name = "tiff_encode";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

/// The option sets besides the defaults, one per check.
const variants = [_]tiff.EncodeOptions{
    .{ .compression = .none },
    .{ .compression = .packbits },
    .{ .compression = .lzw, .predictor = false },
    .{ .compression = .deflate },
    .{ .compression = .deflate, .predictor = false, .palette = false, .effort = .fast },
    .{ .compression = .lzw, .rows_per_strip = 1 },
    .{ .compression = .packbits, .rows_per_strip = 5, .palette = false },
    .{ .compression = .none, .rows_per_strip = 1000 },
};

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkEncoder(tiff, input, choice);
    inline for (variants, 0..) |options, i| {
        if (choice / 64 % variants.len == i) try harness.checkEncoder(Variant(options), input, choice);
    }
    try checkPages(input, choice);
}

/// The encoder with `options` in place of the defaults, under the names
/// `checkEncoder` looks for.
fn Variant(comptime options: tiff.EncodeOptions) type {
    return struct {
        pub const EncodeOptions = tiff.EncodeOptions;
        pub const Decoder = tiff.Decoder;
        pub fn workLen(_: EncodeOptions, width: u32, height: u32) ?usize {
            return tiff.workLen(options, width, height);
        }
        pub fn encode(w: *Io.Writer, src: image.PixelBuffer, _: EncodeOptions, work: []u8) tiff.EncodeError!void {
            return tiff.encode(w, src, options, work);
        }
    };
}

const max_side = 40;
const max_pages = 3;
var page_bytes: [max_pages][max_side * max_side * 16]u8 = undefined;
var file_buffer: [1 << 20]u8 = undefined;
var work_buffer: [2 << 20]u8 = undefined;
var canvas_buffer: [max_side * max_side * 16]u8 = undefined;
var want_buffer: [max_side * max_side * 16]u8 = undefined;
var got_buffer: [max_side * max_side * 16]u8 = undefined;

/// Pages of one format and different sizes, from the input's bytes, must
/// each read back from one file.
fn checkPages(input: []const u8, choice: u64) !void {
    if (input.len < 8) return;
    const formats = std.enums.values(image.PixelFormat);
    const format = formats[choice % formats.len];
    const count = 2 + input[0] % (max_pages - 1);
    var pages: [max_pages]image.PixelBuffer = undefined;
    const body = input[1 + 2 * count ..];
    if (body.len == 0) return;
    for (pages[0..count], 0..) |*p, i| {
        const w = 1 + @as(u32, input[1 + 2 * i]) % max_side;
        const h = 1 + @as(u32, input[2 + 2 * i]) % max_side;
        const len = image.PixelBuffer.len(format, w, h).?;
        for (page_bytes[i][0..len], 0..) |*b, k| b.* = body[(k + i) % body.len];
        if (format.sample() == .f32) {
            const f: []align(1) f32 = @ptrCast(page_bytes[i][0..len]);
            for (f, 0..) |*v, k| v.* = @as(f32, @floatFromInt(body[k % body.len])) / 255;
        }
        p.* = image.PixelBuffer.init(page_bytes[i][0..len], format, w, h) catch unreachable;
    }
    const options = variants[choice / 64 % variants.len];
    const work_len = tiff.workLen(options, max_side, max_side).?;
    var w: Io.Writer = .fixed(&file_buffer);
    tiff.encodePages(&w, pages[0..count], options, work_buffer[0..work_len]) catch return error.EncodeFailed;
    const file = w.buffered();

    var r: Io.Reader = .fixed(file);
    var d = tiff.Decoder.init(&r, .{ .limits = harness.limits, .seeker = .fixed(&r) });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.frame_count == null or config.frame_count.? != count) return error.RoundTripDiffers;
    const cw = config.width;
    const ch = config.height;
    const canvas_len = image.PixelBuffer.len(config.native, cw, ch).?;
    const canvas = image.PixelBuffer.init(canvas_buffer[0..canvas_len], config.native, cw, ch) catch unreachable;
    const dwork = work_buffer[work_len..][0..config.work_len];
    for (pages[0..count]) |src| {
        const decoded = d.decodeFrame(canvas, dwork) catch return error.RoundTripDiffers;
        const frame = decoded orelse return error.RoundTripDiffers;
        if (frame.width != src.width or frame.height != src.height) return error.RoundTripDiffers;
        // The page in the format it is stored in, from the canvas and from
        // the source.
        const stored = storedFormat(format);
        const len = image.PixelBuffer.len(stored, src.width, src.height).?;
        const got = image.PixelBuffer.init(got_buffer[0..len], stored, src.width, src.height) catch unreachable;
        const want = image.PixelBuffer.init(want_buffer[0..len], stored, src.width, src.height) catch unreachable;
        image.convert.convertBuffer(got, canvas.sub(0, 0, src.width, src.height)) catch unreachable;
        image.convert.convertBuffer(want, src) catch unreachable;
        if (!std.mem.eql(u8, got.pixels, want.pixels)) return error.RoundTripDiffers;
    }
    if ((d.decodeFrame(canvas, dwork) catch return error.RoundTripDiffers) != null) return error.RoundTripDiffers;
}

/// What the encoder stores a source of `f` as, decoded (src/tiff/encode.zig).
fn storedFormat(f: image.PixelFormat) image.PixelFormat {
    if (f.isCmyk()) return f;
    const wide = f.sample() != .u8;
    const i: usize = if (!f.hasAlpha()) 0 else if (f.isPremultiplied()) 2 else 1;
    const table: [2][3]image.PixelFormat = if (f.isGray())
        .{ .{ .gray8, .gray_alpha8, .gray_alpha8_premul }, .{ .gray16, .gray_alpha16, .gray_alpha16_premul } }
    else
        .{ .{ .rgb8, .rgba8, .rgba8_premul }, .{ .rgb16, .rgba16, .rgba16_premul } };
    return table[@intFromBool(wide)][i];
}

/// Size bytes, then pixel bytes with runs and few distinct values in them,
/// so palettes, repeat packets, and long LZW strings appear.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    const len = 8 + random.uintLessThan(usize, @min(buf.len, 8192) - 8);
    random.bytes(buf[0..8]);
    const alphabet: u8 = if (random.boolean()) 4 else 255;
    var i: usize = 8;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 40));
        const run = random.boolean();
        const v = random.uintLessThan(u8, alphabet);
        for (buf[i..][0..n]) |*b| b.* = if (run) v else random.uintLessThan(u8, alphabet);
        i += n;
    }
    return buf[0..len];
}

/// Seeds for the coverage-guided fuzzer.
pub const seeds = [_][]const u8{
    "\x05\x03\x02\x07" ++ "\x01\x02\x03\x04" ** 8,
    "\x2f\x01\x10\x11" ++ "\x80" ** 64 ++ "\x01\x02",
    "\x30\x30\x01\x02\x03\x04\x05\x06" ++ "\x00\x01\x02\x03" ** 40,
};

test "tiff_encode on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
