//! The GIF fuzz target: the decoder properties in harness.zig, plus one of
//! GIF's own (`decodeFrameConfig` reports the frame `decodeFrame` then
//! returns), on mutated corpus files and generated files that reach every
//! block the decoder reads: color tables, graphic control, loop count,
//! comment, plain text and unknown extensions, interlaced frames inside
//! and outside the canvas, and LZW data that is exact, short, long, or
//! broken.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "gif";

pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/gif" };
pub const extensions = [_][]const u8{".gif"};

const Finding = error{FrameConfigDiffers};

var pixels: [harness.limits.max_pixels * 4]u8 = undefined;
var work: [1 << 17]u8 = undefined;

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkDecoder(image.gif.Decoder, input, choice);
    var r: std.Io.Reader = .fixed(input);
    var d: image.gif.Decoder = .init(&r, .{ .limits = harness.limits });
    const c = d.decodeConfig() catch return;
    const dst = image.PixelBuffer.init(&pixels, .rgba8, c.width, c.height) catch unreachable;
    while (true) {
        const peek = d.decodeFrameConfig() catch return;
        const frame = d.decodeFrame(dst, work[0..c.work_len]) catch return;
        if (!std.meta.eql(peek, frame)) return error.FrameConfigDiffers;
        if (frame == null) return;
    }
}

/// Writes into a buffer, dropping what does not fit: a file that runs out
/// of room comes out truncated.
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn put(o: *Out, bytes: []const u8) void {
        const n = @min(bytes.len, o.buf.len - o.len);
        @memcpy(o.buf[o.len..][0..n], bytes[0..n]);
        o.len += n;
    }

    fn byte(o: *Out, b: u8) void {
        o.put(&.{b});
    }

    fn u16le(o: *Out, v: u16) void {
        o.put(&.{ @truncate(v), @truncate(v >> 8) });
    }

    /// `data` as sub-blocks of random sizes, then the terminator.
    fn subBlocks(o: *Out, random: std.Random, data: []const u8) void {
        var at: usize = 0;
        while (at < data.len) {
            const n = @min(data.len - at, 1 + random.uintLessThan(usize, 255));
            o.byte(@intCast(n));
            o.put(data[at..][0..n]);
            at += n;
        }
        o.byte(0);
    }
};

/// LZW codes packed least significant bit first.
const Bits = struct {
    buf: []u8,
    len: usize = 0,
    acc: u32 = 0,
    count: u5 = 0,

    fn put(b: *Bits, code: u16, width: u4) void {
        b.acc |= @as(u32, code) << b.count;
        b.count += width;
        while (b.count >= 8) {
            if (b.len < b.buf.len) b.buf[b.len] = @truncate(b.acc);
            b.len += 1;
            b.acc >>= 8;
            b.count -= 8;
        }
    }

    fn flush(b: *Bits) []u8 {
        if (b.count > 0) b.put(0, @intCast(8 - @as(u5, b.count)));
        return b.buf[0..@min(b.len, b.buf.len)];
    }
};

var code_buf: [1 << 15]u8 = undefined;
var lens: [4096]u16 = undefined;

/// A valid LZW stream of random codes for `pixels` pixels, each code a
/// literal or an entry the decoder holds (sometimes the one it is about to
/// make), sometimes with clears, an early or late end, or a bad code.
fn lzwData(random: std.Random, min_bits: u4, pixel_count: u64) []u8 {
    var b: Bits = .{ .buf = &code_buf };
    const clear: u16 = @as(u16, 1) << min_bits;
    var next: u16 = clear + 2;
    var width: u4 = min_bits + 1;
    var prev: ?u16 = null;
    const clears = random.uintLessThan(u8, 4) == 0;
    var left: i64 = @intCast(pixel_count);
    // Sometimes a few pixels too few or too many.
    switch (random.uintLessThan(u8, 16)) {
        0 => left -= random.uintAtMost(u8, 3),
        1 => left += 1 + random.uintAtMost(u8, 3),
        else => {},
    }
    if (random.uintLessThan(u8, 8) != 0) b.put(clear, width);
    for (0..clear) |i| lens[i] = 1;
    var guard: usize = 0;
    while (left > 0 and b.len < code_buf.len - 4 and guard < 1 << 16) : (guard += 1) {
        if (clears and random.uintLessThan(u16, 300) == 0) {
            b.put(clear, width);
            next = clear + 2;
            width = min_bits + 1;
            prev = null;
            continue;
        }
        var code: u16 = random.uintLessThan(u16, clear);
        if (prev != null and next > clear + 2 and random.boolean()) {
            code = clear + 2 + random.uintLessThan(u16, next - clear - 2);
        }
        if (prev != null and next < 4096 and random.uintLessThan(u8, 8) == 0) code = next;
        if (random.uintLessThan(u16, 2000) == 0) {
            // Any code at all, often a bad one; the stream ends there.
            b.put(random.uintLessThan(u16, @as(u16, 1) << width), width);
            break;
        }
        var len: u16 = if (code < clear) 1 else if (code < next) lens[code] else lens[prev.?] + 1;
        if (len > left) {
            code = random.uintLessThan(u16, clear);
            len = 1;
        }
        b.put(code, width);
        if (prev) |p| if (next < 4096) {
            lens[next] = lens[p] + 1;
            next += 1;
        };
        if (next >= @as(u16, 1) << width and width < 12) width += 1;
        prev = code;
        left -= len;
    }
    if (random.uintLessThan(u8, 8) != 0) b.put(clear + 1, width);
    // Sometimes junk after the end.
    if (random.uintLessThan(u8, 16) == 0) b.put(random.int(u8), 8);
    return b.flush();
}

fn colorTable(o: *Out, random: std.Random, size_bits: u3) void {
    const n = @as(usize, 2) << size_bits;
    var c: [768]u8 = undefined;
    random.bytes(c[0 .. n * 3]);
    o.put(c[0 .. n * 3]);
}

/// A GIF of random blocks: usually a valid still or animated file,
/// sometimes broken.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    var o: Out = .{ .buf = buf };
    o.put(if (random.boolean()) "GIF89a" else "GIF87a");
    const sw = random.uintAtMost(u16, if (random.uintLessThan(u8, 8) == 0) 300 else 24);
    const sh = random.uintAtMost(u16, 24);
    o.u16le(sw);
    o.u16le(sh);
    const global = random.uintLessThan(u8, 8) != 0;
    const gbits = random.int(u3);
    o.byte(@as(u8, if (global) 0x80 else 0) | (random.int(u8) & 0x70) | gbits);
    o.byte(random.int(u8));
    o.byte(0);
    if (global) colorTable(&o, random, gbits);
    const frames = 1 + random.uintLessThan(u8, if (random.boolean()) 2 else 6);
    for (0..frames) |_| {
        // Extensions before the frame, in a random order.
        for (0..random.uintLessThan(u8, 4)) |_| switch (random.uintLessThan(u8, 8)) {
            0, 1, 2 => {
                const size: u8 = if (random.uintLessThan(u8, 32) == 0) random.uintLessThan(u8, 8) else 4;
                o.put(&.{ 0x21, 0xf9, size });
                var g: [8]u8 = undefined;
                random.bytes(&g);
                // Transparency often, disposal mostly 0 to 3.
                g[0] = random.uintLessThan(u8, 4) << 2 | @intFromBool(random.boolean());
                if (random.uintLessThan(u8, 16) == 0) g[0] = random.int(u8);
                if (random.boolean()) g[3] &= 3;
                o.put(g[0..size]);
                o.byte(0);
            },
            3 => {
                o.put("\x21\xff\x0bNETSCAPE2.0\x03\x01");
                o.u16le(random.uintLessThan(u16, 4));
                o.byte(0);
            },
            4 => {
                o.put("\x21\xfe");
                o.subBlocks(random, "a comment");
            },
            5 => {
                o.put("\x21\x01\x0c" ++ "\x00" ** 12);
                o.subBlocks(random, "text");
            },
            6 => {
                o.put("\x21\xff\x0bXMP DataXMP");
                o.subBlocks(random, "<x:xmpmeta/>");
            },
            else => {
                o.put(&.{ 0x21, random.int(u8) });
                o.subBlocks(random, "unknown");
            },
        };
        // The frame, usually inside the screen.
        const inside = random.uintLessThan(u8, 6) != 0;
        const fw: u16 = if (inside and sw > 0) 1 + random.uintLessThan(u16, sw) else random.uintAtMost(u16, 30);
        const fh: u16 = if (inside and sh > 0) 1 + random.uintLessThan(u16, sh) else random.uintAtMost(u16, 30);
        const fx: u16 = if (inside and sw >= fw) random.uintAtMost(u16, sw - fw) else random.uintAtMost(u16, 30);
        const fy: u16 = if (inside and sh >= fh) random.uintAtMost(u16, sh - fh) else random.uintAtMost(u16, 30);
        o.byte(0x2c);
        o.u16le(fx);
        o.u16le(fy);
        o.u16le(fw);
        o.u16le(fh);
        const local = !global or random.uintLessThan(u8, 4) == 0;
        const lbits = random.int(u3);
        const interlaced = random.uintLessThan(u8, 4) == 0;
        o.byte(@as(u8, if (local) 0x80 else 0) | @as(u8, if (interlaced) 0x40 else 0) | lbits);
        if (local) colorTable(&o, random, lbits);
        const table_bits: u4 = @as(u4, if (local) lbits else gbits) + 1;
        var min_bits: u4 = @max(2, table_bits);
        if (random.uintLessThan(u8, 8) == 0) min_bits = random.uintLessThan(u4, 9);
        o.byte(if (random.uintLessThan(u8, 64) == 0) random.int(u8) else min_bits);
        o.subBlocks(random, lzwData(random, min_bits, @as(u64, fw) * fh));
    }
    switch (random.uintLessThan(u8, 32)) {
        0 => {},
        1 => o.byte(random.int(u8)),
        else => o.byte(0x3b),
    }
    return buf[0..o.len];
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk: a 2x2 still, and a two-frame animation with transparency,
/// disposal, interlacing, and a loop count.
pub const seeds = [_][]const u8{
    "GIF89a\x02\x00\x02\x00\x80\x00\x00\x00\x00\xff\xff\x00\x00" ++
        "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x02\x03\x44\x02\x05\x00\x3b",
    "GIF89a\x02\x00\x02\x00\x81\x00\x00\x00\x00\x00\xff\x00\x00\x00\xff\x00\xff\xff\xff" ++
        "\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00" ++
        "\x21\xf9\x04\x09\x0a\x00\x01\x00" ++
        "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x40\x02\x03\x44\x02\x05\x00" ++
        "\x21\xf9\x04\x0d\x0a\x00\x02\x00" ++
        "\x2c\x01\x01\x00\x00\x01\x00\x01\x00\x00\x02\x02\x54\x01\x00\x3b",
};

test "fuzz gif" {
    try harness.zigFuzz(@This());
}
