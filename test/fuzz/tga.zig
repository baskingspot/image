//! The TGA fuzz target: the decoder properties in harness.zig, plus the
//! same trailer through a fixed and a trickling reader, on mutated corpus
//! files, generated files of every image type, and the encoder's output.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const tga = image.tga;

pub const name = "tga";

/// Seed directories, relative to the repository root (corpus/README.md),
/// and the extensions of the files in them to take. Not bench/corpus-gen/tga,
/// whose 50-megapixel files are past what test/oracle/compare.zig loads.
pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor" };
pub const extensions = [_][]const u8{".tga"};

var work: [harness.limits.max_pixels * 4]u8 = undefined;
var pixels: [harness.limits.max_pixels * 4]u8 = undefined;

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkDecoder(tga.Decoder, input, choice);
    // The trailer, which the harness does not see, is the same however the
    // input arrives.
    var fixed: Io.Reader = .fixed(input);
    const want = trailerOf(&fixed);
    var trickle: Trickle = undefined;
    trickle.init(input, 1 + choice % 5);
    const got = trailerOf(&trickle.reader);
    if (!std.meta.eql(want, got)) return error.ChunkedDiffers;
}

fn trailerOf(r: *Io.Reader) ?tga.Decoder.Trailer {
    var d: tga.Decoder = .init(r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return null;
    const dst = image.PixelBuffer.init(&pixels, config.native, config.width, config.height) catch return null;
    while (d.decodeFrame(dst, work[0..config.work_len]) catch return null) |_| {}
    return d.trailer();
}

/// A reader that hands over at most `step` bytes per read.
const Trickle = struct {
    data: []const u8,
    step: usize,
    buffer: [image.min_buffer_len]u8 = undefined,
    reader: Io.Reader,

    fn init(t: *Trickle, data: []const u8, step: usize) void {
        t.* = .{
            .data = data,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &t.buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("reader", r);
        if (t.data.len == 0) return error.EndOfStream;
        const n = try w.write(t.data[0..limit.minInt(@min(t.step, t.data.len))]);
        t.data = t.data[n..];
        return n;
    }
};

/// Appends to a buffer while there is room; what does not fit is dropped,
/// which makes a truncated file.
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(o: *Out, b: u8) void {
        if (o.len < o.buf.len) {
            o.buf[o.len] = b;
            o.len += 1;
        }
    }

    fn int(o: *Out, comptime T: type, v: T) void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        for (b) |x| o.byte(x);
    }

    fn random(o: *Out, r: std.Random, n: usize) void {
        for (0..n) |_| o.byte(r.int(u8));
    }
};

/// A TGA file: usually a valid header of a random image type, depth,
/// origin, and color map, pixels that cover the image (raw, or run-length
/// packets that sometimes cross scan lines), and sometimes a footer and
/// extension area; sometimes slightly wrong; and sometimes a file from the
/// encoder.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 4096);
    if (random.uintLessThan(u8, 8) == 0) return encoded(random, buf);
    var o: Out = .{ .buf = buf };
    const odd = random.uintLessThan(u8, 16) == 0;
    const types = [_]u8{ 1, 2, 3, 9, 10, 11, 0 };
    const image_type = if (odd) random.int(u8) else types[random.uintLessThan(usize, types.len)];
    const mapped = image_type & ~@as(u8, 8) == 1;
    const map_type: u8 = if (odd and random.boolean())
        random.int(u8)
    else if (mapped or random.uintLessThan(u8, 8) == 0) 1 else 0;
    const map_bits_choice = [_]u8{ 15, 16, 24, 32 };
    const map_bits = if (odd and random.boolean()) random.int(u8) else map_bits_choice[random.uintLessThan(usize, 4)];
    const map_len: u16 = if (map_type == 0)
        0
    else if (random.uintLessThan(u8, 8) == 0)
        random.uintAtMost(u16, 600)
    else
        1 + random.uintLessThan(u16, 256);
    const map_first: u16 = if (random.uintLessThan(u8, 4) == 0) random.uintAtMost(u16, 300) else 0;
    const depth: u8 = if (odd) random.int(u8) else switch (image_type & ~@as(u8, 8)) {
        1 => if (random.uintLessThan(u8, 4) == 0) 16 else 8,
        2 => ([_]u8{ 15, 16, 24, 32 })[random.uintLessThan(usize, 4)],
        3 => if (random.uintLessThan(u8, 4) == 0) 16 else 8,
        else => 0,
    };
    const alpha_bits = ([_]u8{ 0, 1, 8, 15 })[random.uintLessThan(usize, 4)];
    const descriptor: u8 = if (odd) random.int(u8) else @as(u8, random.uintLessThan(u8, 4)) << 4 | alpha_bits;
    const w: u16 = random.uintAtMost(u16, if (random.uintLessThan(u8, 8) == 0) 300 else 24);
    const h: u16 = random.uintAtMost(u16, 24);
    const id_len: u8 = if (random.uintLessThan(u8, 4) == 0) random.uintAtMost(u8, 40) else 0;

    o.byte(id_len);
    o.byte(map_type);
    o.byte(image_type);
    o.int(u16, map_first);
    o.int(u16, map_len);
    o.byte(map_bits);
    o.int(u16, random.int(u16));
    o.int(u16, random.int(u16));
    o.int(u16, w);
    o.int(u16, h);
    o.byte(depth);
    o.byte(descriptor);
    o.random(random, id_len);
    if (map_type == 1) o.random(random, map_len * ((@as(usize, map_bits) + 7) / 8));

    const bpp: usize = @max(1, (@as(usize, depth) + 7) / 8);
    const count = @as(usize, w) * h;
    // A pixel: an index into the map for a color-mapped image, mostly in
    // range; random bytes otherwise.
    const Pixel = struct {
        fn put(out: *Out, r: std.Random, is_mapped: bool, size: usize, first: u16, len: u16) void {
            if (is_mapped and len > 0 and r.uintLessThan(u8, 32) != 0) {
                const index = first +| r.uintLessThan(u16, len);
                if (size == 1) out.byte(@truncate(index)) else out.int(u16, index);
                for (2..@max(2, size)) |_| out.byte(0);
            } else out.random(r, size);
        }
    };
    if (image_type & 8 == 0) {
        for (0..count) |_| Pixel.put(&o, random, mapped, bpp, map_first, map_len);
    } else {
        var left = count;
        const exact = random.uintLessThan(u8, 8) != 0;
        const per_line = random.boolean();
        var x: usize = 0;
        while (o.len + 1 + bpp <= buf.len and (left > 0 or !exact and random.uintLessThan(u8, 4) != 0)) {
            // Packets end at a scan line's end when `per_line`.
            const line_left = if (per_line and w > 0) w - x else left;
            const most: usize = @max(1, @min(128, if (exact) @min(left, line_left) else 128));
            const n = 1 + random.uintLessThan(usize, most);
            if (random.boolean()) {
                o.byte(@intCast(0x80 | (n - 1)));
                Pixel.put(&o, random, mapped, bpp, map_first, map_len);
            } else {
                o.byte(@intCast(n - 1));
                for (0..n) |_| Pixel.put(&o, random, mapped, bpp, map_first, map_len);
            }
            left -|= n;
            if (w > 0) x = (x + n) % w;
        }
    }
    if (random.uintLessThan(u8, 4) == 0) trailer(random, &o);
    return buf[0..o.len];
}

/// A footer, often with an extension area right after the image data or
/// right before the footer, and sometimes bytes between.
fn trailer(random: std.Random, o: *Out) void {
    const start: u32 = @intCast(o.len);
    var ext_at: u32 = 0;
    const gap = if (random.boolean()) random.uintAtMost(usize, 40) else 0;
    const before = random.boolean();
    if (!before) o.random(random, gap);
    if (random.uintLessThan(u8, 4) != 0) {
        ext_at = @intCast(o.len);
        o.int(u16, if (random.uintLessThan(u8, 8) == 0) random.int(u16) else 495);
        for (0..468) |_| o.byte(0);
        o.random(random, 25);
    }
    if (before) o.random(random, gap);
    if (random.uintLessThan(u8, 8) == 0) ext_at = random.uintAtMost(u32, start + 600);
    o.int(u32, ext_at);
    o.int(u32, random.int(u32));
    for ("TRUEVISION-XFILE.\x00") |c| o.byte(if (random.uintLessThan(u8, 64) == 0) random.int(u8) else c);
}

var source: [64 * 64 * 16]u8 = undefined;
var encode_work: [64 * 4 * 3]u8 = undefined;

/// A random image in a random pixel format, encoded.
fn encoded(random: std.Random, buf: []u8) []u8 {
    const formats = std.enums.values(image.PixelFormat);
    const format = formats[random.uintLessThan(usize, formats.len)];
    const w = random.uintAtMost(u32, 64);
    const h = random.uintAtMost(u32, 64);
    const len = image.PixelBuffer.len(format, w, h).?;
    // Runs of repeated bytes, so run packets appear.
    var i: usize = 0;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 32));
        if (random.boolean()) @memset(source[i..][0..n], random.int(u8)) else random.bytes(source[i..][0..n]);
        i += n;
    }
    if (format.sample() == .f32) {
        const floats: []align(1) f32 = @ptrCast(source[0..len]);
        for (floats) |*f| f.* = @as(f32, @floatFromInt(random.int(u8))) / 255;
    }
    const src = image.PixelBuffer.init(source[0..len], format, w, h) catch unreachable;
    const options: tga.EncodeOptions = .{ .rle = random.boolean() };
    var writer: Io.Writer = .fixed(buf);
    tga.encode(&writer, src, options, &encode_work) catch return buf[0..0];
    return writer.buffered();
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk. `std.testing.Smith` reads an input as a 4-byte length and the
/// bytes (then the choice, 0 when absent), so each seed carries its length.
pub const seeds = [_][]const u8{
    // 2 by 2, 24-bit, bottom-left.
    seed("\x00\x00\x02" ++ "\x00" ** 9 ++ "\x02\x00\x02\x00\x18\x00" ++ "\x01\x02\x03" ** 4),
    // Run-length, color-mapped, two 32-bit entries, crossing scan lines.
    seed("\x00\x01\x09\x00\x00\x02\x00\x20" ++ "\x00" ** 4 ++ "\x02\x00\x02\x00\x08\x28" ++
        "\x01\x02\x03\x80\x04\x05\x06\xff" ++ "\x82\x01\x00\x00"),
    // 16-bit gray and alpha, top-right, with a footer.
    seed("\x00\x00\x03" ++ "\x00" ** 9 ++ "\x01\x00\x01\x00\x10\x38" ++ "\x40\x80" ++
        "\x00" ** 8 ++ "TRUEVISION-XFILE.\x00"),
};

/// `bytes` as a seed: its length, then itself.
pub fn seed(comptime bytes: []const u8) []const u8 {
    comptime {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, bytes.len, .little);
        const with_len = len ++ bytes[0..bytes.len].*;
        return &with_len;
    }
}

test "tga on the coverage-guided fuzzer" {
    // In Debug builds, Zig 0.16 can compare two null `?anyerror` fields read
    // through pointers as different, which makes harness.zig's
    // `Result.eql` report equal results as differing (FormatDiffers on
    // these seeds). Skipped there until the harness compares copies;
    // ReleaseSafe runs it.
    if (builtin.mode == .Debug) return error.SkipZigTest;
    try harness.zigFuzz(@This());
}
