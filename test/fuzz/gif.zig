//! The GIF fuzz target: the decoder properties in harness.zig, with
//! `ignore_too_much_data` off or on, plus GIF's own: the two settings agree
//! wherever the strict decode found neither too much data nor a bad code,
//! and the blob sink agrees with the metadata reported.
//! It runs on mutated corpus files and generated files that reach every
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

var pixels: [harness.limits.max_pixels * 4]u8 = undefined;
var work: [1 << 17]u8 = undefined;

pub fn check(input: []const u8, choice: u64) !void {
    if (choice >> 63 == 1) {
        try harness.checkDecoder(Lax, input, choice);
    } else {
        try harness.checkDecoder(image.gif.Decoder, input, choice);
    }
    try compareLax(input);
}

/// `image.gif.Decoder` with `ignore_too_much_data` set.
const Lax = struct {
    d: image.gif.Decoder,

    pub const Options = image.gif.Decoder.Options;
    pub const Error = image.gif.Decoder.Error;

    pub fn init(reader: *std.Io.Reader, options: Options) Lax {
        var o = options;
        o.ignore_too_much_data = true;
        return .{ .d = .init(reader, o) };
    }

    pub fn decodeConfig(l: *Lax) Error!image.Config {
        return l.d.decodeConfig();
    }

    pub fn decodeFrame(l: *Lax, dst: image.PixelBuffer, w: []u8) Error!?image.Frame {
        return l.d.decodeFrame(dst, w);
    }

    pub fn decodeFrameConfig(l: *Lax) Error!?image.Frame {
        return l.d.decodeFrameConfig();
    }
};

const Run = struct {
    err: ?image.gif.Decoder.Error = null,
    count: usize = 0,
    frames: [harness.limits.max_frames]image.Frame = undefined,
    hashes: [harness.limits.max_frames]u64 = undefined,

    fn same(a: *const Run, b: *const Run, n: usize) bool {
        for (0..n) |i| {
            if (!std.meta.eql(a.frames[i], b.frames[i]) or a.hashes[i] != b.hashes[i]) return false;
        }
        return true;
    }
};

/// Checks the pieces a decoder passes its blob sink against `BlobSink`'s
/// rules: each blob arrives in order from byte 0, its length known by its
/// last piece, and nothing follows that piece. A second blob of a kind
/// is a fault too, since GIF reports only the first, and GIF has no Exif.
/// Indexed by `Blob.Kind`.
const Sink = struct {
    blobs: [3]?image.Blob = @splat(null),
    at: [3]u64 = @splat(0),
    ended: [3]bool = @splat(false),
    bad: bool = false,

    fn write(context: *anyopaque, blob: image.Blob, at: u64, bytes: []const u8) void {
        const s: *Sink = @ptrCast(@alignCast(context));
        const k = @intFromEnum(blob.kind);
        if (blob.kind == .exif or s.ended[k] or at != s.at[k]) return s.fail();
        if (s.blobs[k]) |b| if (b.offset != blob.offset) return s.fail();
        if (blob.len) |n| if (at + bytes.len > n) return s.fail();
        s.blobs[k] = blob;
        s.at[k] += bytes.len;
        s.ended[k] = blob.endsAt(at, bytes.len);
    }

    fn fail(s: *Sink) void {
        s.bad = true;
    }

    /// The metadata a decode reports agrees with what the sink was sent:
    /// a blob there is one the sink saw end, with the same offset and
    /// length, and each blob the sink saw end is there.
    fn agrees(s: *const Sink, metadata: image.Metadata) bool {
        if (s.bad) return false;
        for ([3]?image.Blob{ metadata.icc, metadata.exif, metadata.xmp }, 0..) |m, k| {
            if (m) |b| {
                if (!s.ended[k] or b.len != s.at[k] or b.offset != s.blobs[k].?.offset) return false;
            } else if (s.ended[k]) return false;
        }
        return true;
    }
};

/// Decodes every frame of `input`, checking that the blobs the sink gets
/// agree with the metadata reported.
fn run(input: []const u8, lax: bool) !Run {
    var result: Run = .{};
    var r: std.Io.Reader = .fixed(input);
    var sink: Sink = .{};
    var d: image.gif.Decoder = .init(&r, .{
        .limits = harness.limits,
        .ignore_too_much_data = lax,
        .blob_sink = .{ .context = &sink, .write = Sink.write },
    });
    var c = d.decodeConfig() catch |e| {
        result.err = e;
        return result;
    };
    const dst = image.PixelBuffer.init(&pixels, .rgba8, c.width, c.height) catch unreachable;
    const len = @as(usize, c.width) * c.height * 4;
    @memset(pixels[0..len], 0);
    while (result.count < result.frames.len) : (result.count += 1) {
        const frame = d.decodeFrame(dst, work[0..c.work_len]) catch |e| {
            result.err = e;
            break;
        };
        result.frames[result.count] = frame orelse break;
        result.hashes[result.count] = std.hash.Wyhash.hash(0, pixels[0..len]);
    }
    d.applyTrailer(&c);
    if (!sink.agrees(c.metadata)) return error.BlobsDisagree;
    return result;
}

/// With too much data accepted, a decode matches the strict one up to the
/// frame where the strict one found too much data or a bad code, and
/// entirely when it found neither.
fn compareLax(input: []const u8) !void {
    const strict = try run(input, false);
    const lax = try run(input, true);
    if (strict.err) |e| if (e == error.TooMuchData or e == error.BadLzw) {
        if (lax.count < strict.count or !strict.same(&lax, strict.count)) return error.LaxDiffers;
        return;
    };
    if (errorCode(lax.err) != errorCode(strict.err) or lax.count != strict.count or !strict.same(&lax, strict.count)) {
        return error.LaxDiffers;
    }
}

/// An optional error as an integer, 0 for none: `!=` on two `?Error` can
/// find two nulls unequal on Zig 0.16's x86_64 backend (harness.zig's
/// `errorCode` has the details).
fn errorCode(err: ?image.gif.Decoder.Error) u16 {
    return if (err) |e| @intFromError(e) else 0;
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

/// An ICC profile in random sub-blocks, or an XMP packet with its
/// trailer, sometimes cut short of it.
fn metadataExtension(o: *Out, random: std.Random) void {
    var data: [600]u8 = undefined;
    const n = random.uintAtMost(usize, data.len);
    random.bytes(data[0..n]);
    if (random.boolean()) {
        o.put("\x21\xff\x0bICCRGBG1012");
        return o.subBlocks(random, data[0..n]);
    }
    o.put("\x21\xff\x0bXMP DataXMP");
    // Text bytes, which as sub-block lengths land in the trailer.
    for (data[0..n]) |*b| b.* = 0x20 + b.* % 0x5f;
    o.put(data[0..n]);
    var trailer: [258]u8 = undefined;
    trailer[0] = 1;
    for (trailer[1..257], 0..) |*b, i| b.* = @intCast(255 - i);
    trailer[257] = 0;
    o.put(if (random.uintLessThan(u8, 8) == 0) trailer[random.uintLessThan(usize, 257)..] else &trailer);
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
        for (0..random.uintLessThan(u8, 4)) |_| switch (random.uintLessThan(u8, 9)) {
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
            3 => if (random.uintLessThan(u8, 8) == 0) {
                // No sub-blocks: Wuffs misreads this (test/oracle/gif.zig).
                o.put("\x21\xff\x0bNETSCAPE2.0\x00");
            } else {
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
            6, 7 => metadataExtension(&o, random),
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
    // Metadata after the frames, for `applyTrailer`.
    if (random.uintLessThan(u8, 4) == 0) metadataExtension(&o, random);
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
