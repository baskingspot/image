//! A streaming QOI decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, needs no work memory, and allocates nothing.
//!
//! Format: the QOI specification, version 1.0 (qoiformat.org). Every
//! decoded pixel goes into the index, runs and index chunks included, as
//! the specification says. The decoder is strict where the specification
//! is silent: the stream must end with its 8-byte end marker, and a run may
//! not go past the last pixel.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

const Decoder = @This();

pub const Options = decode.Options;

pub const Error = decode.Error || error{
    /// The stream does not end with the end marker, seven zeros and a one.
    BadFooter,
    /// A run goes past the last pixel.
    RunPastEnd,
};

reader: *Io.Reader,
options: Options,
state: State = .start,
header: Header = undefined,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,

const State = enum { start, config, done };

const Header = struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,
};

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops after the end marker.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the 14-byte header. The native format is `rgb8` for a
/// three-channel file and `rgba8` for a four-channel one. Calling it again
/// returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.header = readHeader(d.reader, d.options.limits) catch |e| return d.fail(e);
        d.state = .config;
    }
    const h = d.header;
    return .{
        .width = h.width,
        .height = h.height,
        .native = if (h.channels == 4) .rgba8 else .rgb8,
        .frame_count = 1,
        .is_opaque = h.channels == 3,
        .metadata = .{ .transfer = switch (h.colorspace) {
            0 => .srgb,
            1 => .linear,
            else => null,
        } },
    };
}

/// Decodes the image into `dst`, which must be the image's size, in any
/// format. Returns null once the image is decoded. `work` is unused: QOI
/// needs no work memory.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    _ = work;
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    const h = d.header;
    try dst.check();
    if (dst.width != h.width or dst.height != h.height) return error.SizeMismatch;
    d.pixels(dst) catch |e| return d.fail(e);
    d.state = .done;
    return .{ .width = h.width, .height = h.height, .is_opaque = h.channels == 3 };
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

fn readHeader(r: *Io.Reader, limits: decode.Limits) Error!Header {
    const b = r.takeArray(14) catch |e| return mapRead(e);
    if (!std.mem.eql(u8, b[0..4], "qoif")) return error.BadSignature;
    const h: Header = .{
        .width = std.mem.readInt(u32, b[4..8], .big),
        .height = std.mem.readInt(u32, b[8..12], .big),
        .channels = b[12],
        .colorspace = b[13],
    };
    if (h.channels != 3 and h.channels != 4) return error.BadHeader;
    try limits.checkSize(h.width, h.height);
    return h;
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

/// The decoding state that carries from one span of pixels to the next.
/// Pixels are `u32`s holding R, G, B, and A from the low byte up.
const Stream = struct {
    px: u32 = 0xff00_0000,
    index: [64]u32 = @splat(0),
    /// Pixels of the current run not yet written.
    run: u32 = 0,
};

/// How a span's pixels are stored: four bytes as decoded, four with alpha
/// forced opaque (a three-channel file), or three.
const Out = enum { rgba, rgbx, rgb };

fn pixels(d: *Decoder, dst: PixelBuffer) Error!void {
    const h = d.header;
    var s: Stream = .{};
    // Write rows straight into the buffer when it holds RGBA or RGB, and
    // through a converter from a span of RGBA otherwise.
    const direct: ?Out = switch (dst.format) {
        .rgba8 => if (h.channels == 4) .rgba else .rgbx,
        .rgb8 => .rgb,
        else => null,
    };
    // Every pixel goes into the index at its hash, but a run repeats the
    // pixel before it, which is there already, and so does an INDEX chunk
    // (`span`). Only a run that starts the image repeats a pixel never
    // stored.
    if (@as(u64, h.width) * h.height != 0) {
        if (d.reader.peekByte()) |b| {
            if (b >= 0xc0 and b < 0xfe) s.index[hash(s.px)] = s.px;
        } else |_| {}
    }
    try d.pixelsAs(dst, &s, direct);
    if (s.run != 0) return error.RunPastEnd;
    const footer = d.reader.takeArray(8) catch |e| return mapRead(e);
    if (!std.mem.eql(u8, footer, "\x00\x00\x00\x00\x00\x00\x00\x01")) return error.BadFooter;
}

fn pixelsAs(d: *Decoder, dst: PixelBuffer, s: *Stream, direct: ?Out) Error!void {
    const h = d.header;
    if (direct) |out| switch (out) {
        inline else => |o| {
            const row_len = @as(usize, h.width) * (if (o == .rgb) 3 else 4);
            if (dst.stride == row_len) {
                // Packed rows are one span: no setup per row, and runs
                // cross rows freely.
                try span(d.reader, s, dst.pixels[0 .. row_len * h.height], o);
            } else {
                for (0..h.height) |y| try span(d.reader, s, dst.row(@intCast(y)), o);
            }
        },
    } else {
        const native: PixelFormat = if (h.channels == 4) .rgba8 else .rgb8;
        const conv: Converter = .init(dst.format, native);
        var buf: [256 * 4]u8 = undefined;
        for (0..h.height) |y| {
            const row = dst.row(@intCast(y));
            var x: usize = 0;
            while (x < h.width) {
                const n: usize = @min(256, h.width - x);
                if (h.channels == 4) {
                    try span(d.reader, s, buf[0 .. n * 4], .rgba);
                } else {
                    try span(d.reader, s, buf[0 .. n * 3], .rgb);
                }
                conv.run(row[x * dst.format.bytesPerPixel() ..], &buf, n);
                x += n;
            }
        }
    }
}

/// The specification's index position, (3r + 5g + 7b + 11a) mod 64: the
/// four bytes spread 16 bits apart, and one multiply sums their weighted
/// values into bits 48 to 63.
inline fn hash(px: u32) u6 {
    const x: u64 = px;
    const spread = (x & 0x00ff_00ff) | (x & 0xff00_ff00) << 24;
    return @truncate((spread *% (3 << 48 | 7 << 32 | 5 << 16 | 11)) >> 48);
}

inline fn put(out: []u8, i: usize, px: u32, comptime o: Out) void {
    switch (o) {
        .rgba => std.mem.writeInt(u32, out[i * 4 ..][0..4], px, .little),
        .rgbx => std.mem.writeInt(u32, out[i * 4 ..][0..4], px | 0xff00_0000, .little),
        .rgb => std.mem.writeInt(u24, out[i * 3 ..][0..3], @truncate(px), .little),
    }
}

/// Writes `m` copies of `px` at pixel `i` of `out`, which holds `n`
/// pixels. While 8 pixels fit, they go out as one store each, which may
/// write past the run; the pixels after it overwrite those. Eight measured
/// faster than 16 or four 16s for any run
/// (docs/slop/results/qoi-perf-20261102.md).
inline fn fill(out: []u8, n: usize, i: usize, m: usize, px: u32, comptime o: Out) void {
    const bpp = if (o == .rgb) 3 else 4;
    const per = 8;
    var k: usize = 0;
    if (n - i >= per) {
        var p: [4]u8 = undefined;
        std.mem.writeInt(u32, &p, if (o == .rgbx) px | 0xff00_0000 else px, .little);
        const block: [per * bpp]u8 = if (o == .rgb)
            @shuffle(u8, @as(@Vector(4, u8), p), undefined, blk: {
                var mask: [per * 3]i32 = undefined;
                for (&mask, 0..) |*e, j| e.* = @intCast(j % 3);
                break :blk mask;
            })
        else
            @bitCast(@as(@Vector(per, u32), @splat(@bitCast(p))));
        while (true) {
            out[(i + k) * bpp ..][0 .. per * bpp].* = block;
            k += per;
            if (k >= m or n - i - k < per) break;
        }
    }
    while (k < m) : (k += 1) put(out, i + k, px, o);
}

/// What a chunk other than a run does, by its first byte: the bits of the
/// base pixel (the index entry for INDEX, else the last pixel) that stay,
/// with the next four bytes in the rest (RGB keeps alpha, RGBA nothing);
/// what is added to each byte (DIFF, and LUMA's green); whether the second
/// byte adds LUMA's red and blue; and the chunk's length.
const Op = struct { keep: u32, delta: u32, luma: u32, len: u32 };
const ops: [256]Op = blk: {
    var t: [256]Op = undefined;
    for (&t, 0..) |*e, b| {
        e.* = .{ .keep = 0xffff_ffff, .delta = 0, .luma = 0, .len = 1 };
        if (b == 0xfe) {
            e.* = .{ .keep = 0xff00_0000, .delta = 0, .luma = 0, .len = 4 };
        } else if (b == 0xff) {
            e.* = .{ .keep = 0, .delta = 0, .luma = 0, .len = 5 };
        } else if (b >> 6 == 1) {
            const dr: u32 = ((b >> 4) & 3) -% 2 & 0xff;
            const dg: u32 = ((b >> 2) & 3) -% 2 & 0xff;
            const db: u32 = (b & 3) -% 2 & 0xff;
            e.delta = dr | dg << 8 | db << 16;
        } else if (b >> 6 == 2) {
            const dg: u32 = ((b & 0x3f) -% 32) & 0xff;
            e.* = .{ .keep = 0xffff_ffff, .delta = dg * 0x01_0101, .luma = 0xffff_ffff, .len = 2 };
        }
    }
    break :blk t;
};
/// LUMA's second byte: red minus green in byte 0, blue minus green in 2.
const luma_rb: [256]u32 = blk: {
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, c| e.* = (((c >> 4) -% 8) & 0xff) | (((c & 15) -% 8) & 0xff) << 16;
    break :blk t;
};

/// Adds `y` to `x` byte by byte, each byte wrapping.
inline fn addBytes(x: u32, y: u32) u32 {
    const h: u32 = 0x8080_8080;
    return ((x & ~h) +% (y & ~h)) ^ ((x ^ y) & h);
}

/// Decodes `out.len / bytes-per-pixel` pixels into `out`.
///
/// DIFF, LUMA, and RGB chunks decode without branching on their kind,
/// through `ops`: the kind is close to random, and a mispredicted branch
/// per pixel costs more than the table lookups. That holds for icons too
/// unless one file is decoded again and again, so that the branch
/// predictor learns it (docs/slop/results/qoi-icons-20261102.md). INDEX
/// takes its own branch so that it skips the index store, whose address
/// hangs off the pixel just loaded and which later index loads must
/// follow; that measured up to 1.75× on index-heavy screenshots
/// (docs/slop/results/qoi-perf-20261102.md). RGBA takes its own branch
/// so that its pixel does not wait on the one before, as it would through
/// the table: up to 1.7× on icons with alpha, where RGBA chunks are common,
/// and opaque images have none (qoi-icons-20261102.md).
fn span(r: *Io.Reader, s: *Stream, out: []u8, comptime o: Out) Error!void {
    const bpp = if (o == .rgb) 3 else 4;
    const n = out.len / bpp;
    var i: usize = 0;
    var px = s.px;
    const index = &s.index;
    // The rest of a run from the last span.
    const carried = @min(s.run, n);
    while (i < carried) : (i += 1) put(out, i, px, o);
    s.run -= @intCast(carried);
    while (i < n) {
        // Every chunk is at most 5 bytes and gives at least one pixel, so
        // `c` chunks surely fit in what is buffered and in `out`, and the
        // inner loop checks only that count; a run, which gives more
        // pixels, cuts it to the pixels left. The end marker follows the
        // last chunk, so a valid stream always has 5 bytes here.
        r.fill(5) catch |e| return mapRead(e);
        const buf = r.buffered();
        var p: usize = 0;
        var c = @min(buf.len / 5, n - i);
        while (c != 0) {
            c -= 1;
            const b = buf[p];
            if (b < 64) {
                // INDEX: the entry already sits at its own hash, so the
                // store after every pixel would rewrite it; only an entry
                // never written (zero, whose hash is 0) moves.
                px = index[b];
                if (px == 0) index[0] = 0;
                put(out, i, px, o);
                i += 1;
                p += 1;
                continue;
            }
            if (b >= 0xc0 and b < 0xfe) {
                // A run of 1 to 62; 63 and 64 would be 0xfe and 0xff.
                const count: usize = (b & 0x3f) + 1;
                const m = @min(count, n - i);
                fill(out, n, i, m, px, o);
                i += m;
                c = @min(c, n - i);
                s.run = @intCast(count - m);
                p += 1;
                continue;
            }
            const next = std.mem.readInt(u32, buf[p + 1 ..][0..4], .little);
            if (b == 0xff) {
                px = next;
                p += 5;
                index[hash(px)] = px;
                put(out, i, px, o);
                i += 1;
                continue;
            }
            const op = ops[b];
            const from_index: u32 = 0 -% @as(u32, @intFromBool(b < 64));
            const base = (index[b & 63] & from_index) | (px & ~from_index);
            const delta = addBytes(op.delta, luma_rb[next & 0xff] & op.luma);
            px = addBytes((base & op.keep) | (next & ~op.keep), delta);
            p += op.len;
            index[hash(px)] = px;
            put(out, i, px, o);
            i += 1;
        }
        r.toss(p);
    }
    s.px = px;
}

fn testDecode(file: []const u8, format: PixelFormat, out: []u8) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    const frame = (try d.decodeFrame(dst, &.{})).?;
    try testing.expectEqual(config.width, frame.width);
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
    try testing.expectEqual(0, r.bufferedLen());
    return config;
}

const end = "\x00\x00\x00\x00\x00\x00\x00\x01";

inline fn testHeader(comptime w: u8, comptime h: u8, comptime channels: u8) []const u8 {
    return "qoif\x00\x00\x00" ++ [_]u8{w} ++ "\x00\x00\x00" ++ [_]u8{h} ++ [_]u8{ channels, 0 };
}

test "every chunk kind" {
    // RGB, DIFF, LUMA, RGBA, INDEX back to the first pixel, and a run.
    const file = testHeader(7, 1, 4) ++
        "\xfe\x10\x20\x30" ++ // (16, 32, 48, 255)
        "\x7b" ++ // diff +1, +0, +1: (17, 32, 49)
        "\xa8\x9a" ++ // luma dg +8, dr-dg +1, db-dg +2: (26, 40, 59)
        "\xff\x01\x02\x03\x80" ++ // (1, 2, 3, 128)
        [_]u8{hash(0xff30_2010)} ++
        "\xc1" ++ // run of 2
        end;
    var out: [7 * 4]u8 = undefined;
    const config = try testDecode(file, .rgba8, &out);
    try testing.expectEqual(PixelFormat.rgba8, config.native);
    try testing.expectEqualSlices(u8, &.{
        16, 32, 48, 255, 17, 32, 49, 255, 26, 40, 59, 255, 1, 2, 3, 128,
        16, 32, 48, 255, 16, 32, 48, 255, 16, 32, 48, 255,
    }, &out);
}

test "runs cross rows and conversion spans" {
    // 300 by 2 needs two spans per row through the converter.
    const runs = "\xfd" ** 9 ++ "\xd5"; // 9 * 62 + 22 = 580
    const head = "qoif\x00\x00\x01\x2c\x00\x00\x00\x02\x03\x00";
    const file = head ++ "\xfe\x05\x06\x07" ++ "\xc0" ++ runs ++ "\xc1" ++ end;
    // 1 + 1 + 580 + 2 = 584 is short of 600: a truncated stream.
    var out: [300 * 2 * 4]u8 = undefined;
    try testing.expectError(error.Truncated, testDecode(file, .bgra8, &out));
    const full = file[0 .. file.len - end.len - 1] ++ "\xd1" ++ end; // run of 18 instead of 2
    const config = try testDecode(full, .bgra8, &out);
    try testing.expectEqual(PixelFormat.rgb8, config.native);
    try testing.expect(config.is_opaque);
    for (0..600) |i| try testing.expectEqualSlices(u8, &.{ 7, 6, 5, 255 }, out[i * 4 ..][0..4]);
}

test "the index holds every decoded pixel" {
    // A first run puts the starting pixel (0, 0, 0, 255) in the index, so
    // index 53 then reads it back.
    const file = testHeader(2, 1, 4) ++ "\xc0" ++ [_]u8{hash(0xff00_0000)} ++ end;
    var out: [8]u8 = undefined;
    _ = try testDecode(file, .rgba8, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 0, 0, 0, 255 }, &out);
}

test "an INDEX chunk of an entry never written stores its zero pixel" {
    // (0, 0, 0, 64) hashes to 0; INDEX 5 reads an empty entry, (0, 0, 0,
    // 0), whose hash is also 0, so it replaces the first pixel there and
    // INDEX 0 reads it back.
    const file = testHeader(3, 1, 4) ++ "\xff\x00\x00\x00\x40" ++ "\x05" ++ "\x00" ++ end;
    var out: [12]u8 = undefined;
    _ = try testDecode(file, .rgba8, &out);
    try testing.expectEqualSlices(u8, &([_]u8{ 0, 0, 0, 64 } ++ [_]u8{0} ** 8), &out);
}

test "three channels: alpha is opaque whatever the chunks say" {
    const file = testHeader(1, 1, 3) ++ "\xff\x01\x02\x03\x04" ++ end;
    var out: [4]u8 = undefined;
    _ = try testDecode(file, .rgba8, &out);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &out);
    _ = try testDecode(file, .rgb8, out[0..3]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, out[0..3]);
}

test "malformed streams" {
    var out: [64]u8 = undefined;
    const good = testHeader(2, 1, 4) ++ "\xc1" ++ end;
    _ = try testDecode(good, .rgba8, &out);
    // Every truncation.
    for (0..good.len) |n| try testing.expectError(error.Truncated, testDecode(good[0..n], .rgba8, &out));
    try testing.expectError(error.BadSignature, testDecode("qoiF" ++ good[4..], .rgba8, &out));
    try testing.expectError(error.BadHeader, testDecode(testHeader(2, 1, 5) ++ good[14..], .rgba8, &out));
    try testing.expectError(error.BadFooter, testDecode(testHeader(2, 1, 4) ++ "\xc1" ++ "\x00" ** 8, .rgba8, &out));
    try testing.expectError(error.RunPastEnd, testDecode(testHeader(2, 1, 4) ++ "\xc2" ++ end, .rgba8, &out));
    // An empty image is only its header and end marker.
    _ = try testDecode(testHeader(0, 0, 4) ++ end, .rgba8, &out);
    // Limits apply before any pixel.
    var r: Io.Reader = .fixed(good);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_width = 1 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
    try testing.expectError(error.ImageTooLarge, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 1), &.{}));
    // The pixel buffer must be the image's size.
    r = .fixed(good);
    d = .init(&r, .{});
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 1, 1), &.{}));
    const short: PixelBuffer = .{ .pixels = out[0..7], .format = .rgba8, .width = 2, .height = 1, .stride = 8 };
    try testing.expectError(error.BufferTooSmall, d.decodeFrame(short, &.{}));
}

test "a reader with a small buffer" {
    // Pixels from every chunk kind, through a reader that serves a few
    // bytes at a time from a 64-byte buffer.
    var file: [14 + 5 * 40 + 8]u8 = undefined;
    @memcpy(file[0..14], testHeader(40, 1, 4));
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for (0..40) |i| {
        file[14 + 5 * i ..][0..5].* = .{ 0xff, random.int(u8), random.int(u8), random.int(u8), random.int(u8) };
    }
    @memcpy(file[file.len - 8 ..], end);
    var want: [160]u8 = undefined;
    _ = try testDecode(&file, .rgba8, &want);
    var buffer: [decode.min_buffer_len]u8 = undefined;
    var trickle: Trickle = .{
        .data = &file,
        .reader = .{ .vtable = &.{ .stream = Trickle.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
    };
    var d: Decoder = .init(&trickle.reader, .{});
    var got: [160]u8 = undefined;
    _ = try d.decodeFrame(try PixelBuffer.init(&got, .rgba8, 40, 1), &.{});
    try testing.expectEqualSlices(u8, &want, &got);
}

/// A reader that hands over at most 3 bytes per read.
const Trickle = struct {
    data: []const u8,
    reader: Io.Reader,
    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("reader", r);
        if (t.data.len == 0) return error.EndOfStream;
        const n = try w.write(t.data[0..limit.minInt(@min(3, t.data.len))]);
        t.data = t.data[n..];
        return n;
    }
};
