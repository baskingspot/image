//! A streaming ICO and CUR decoder: reads from a `std.Io.Reader`, writes
//! any `PixelFormat`, and allocates nothing.
//!
//! An ICO or CUR file is a directory of images, each a DIB (read by BMP's
//! reader, src/bmp/dib.zig) or a PNG stream. By default every entry is a
//! frame, in directory order, written to the top-left corner of a canvas
//! as large as the largest size the directory gives; `Options.entry` picks
//! one entry instead, and the canvas is its size. `entry` and `entryCount`
//! report the directory, with CUR hotspots.
//!
//! The input is read forward. The directory's offsets can point anywhere,
//! so an entry whose data starts before the reader's position needs
//! `Options.seeker`, an `image.Seeker`, to move back (`error.EntryBehind`
//! without one); an entry picked with `Options.entry` never does, since it
//! is the only data read after the directory. docs/slop/ico.md has the
//! reasons.
//!
//! An entry's own header gives its size, as Windows and ImageMagick read
//! it: a DIB's width and half its height (the AND mask's rows are counted
//! too), or a PNG's IHDR. A DIB entry of 32 bits takes its alpha from its
//! pixels and ignores the mask; one of fewer bits is opaque except where
//! the mask is set. PNG entries are decoded by `image.png` when the build
//! has it, picked with `Options.entry`; without it they fail with
//! `error.Unsupported`.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const dib = @import("../bmp/dib.zig");

/// One directory entry.
pub const Entry = struct {
    /// The size the directory gives, 1 to 256. The entry's own header
    /// decides the size it decodes to.
    width: u16,
    height: u16,
    /// Colors in the entry's color table: 0 for none or 256 or more.
    colors: u8,
    /// ICO: color planes. CUR: the hotspot's x.
    planes: u16,
    /// ICO: bits per pixel. CUR: the hotspot's y.
    bits: u16,
    /// The entry's data: its length and its offset in the file.
    size: u32,
    offset: u32,
};

/// The most entries a file may have.
pub const max_entries = 256;

/// The decoder, decoding PNG entries with `Png` (a `Decoder` with the
/// generic contract), or not at all when it is `void`.
pub fn Generic(comptime Png: type) type {
    return struct {
        const Self = @This();
        const has_png = Png != void;

        pub const Options = struct {
            limits: decode.Limits = .{},
            blob_sink: ?decode.BlobSink = null,
            /// Moves back to an entry whose data is behind the reader.
            seeker: ?decode.Seeker = null,
            /// Decode only this entry, as the only frame, on a canvas its
            /// size.
            entry: ?u16 = null,
        };

        pub const Error = dib.Error || (if (has_png) Png.Error else error{}) || error{
            /// An entry's data starts before the reader's position, and
            /// `Options.seeker` is null.
            EntryBehind,
            /// An entry's header gives a size larger than the canvas.
            EntryTooLarge,
            /// `Options.entry` is past the directory's end.
            NoEntry,
        };

        in: dib.Input,
        options: Options,
        state: State = .start,
        /// The error that stopped the decoder, returned again by later calls.
        err: ?Error = null,
        cursor: bool = false,
        count: u16 = 0,
        canvas: [2]u32 = .{ 0, 0 },
        /// The next entry `decodeFrame` decodes.
        next: u16 = 0,
        /// The picked entry's header, read by `decodeConfig`.
        picked: union(enum) { none, bmp: dib.Header, png: if (has_png) Png else void } = .none,
        png_config: if (has_png) decode.Config else void = undefined,
        directory: [max_entries][16]u8 = undefined,

        const State = enum { start, config, done };

        /// Starts a decoder on `reader`, whose buffer must hold at least
        /// `image.min_buffer_len` bytes. The decoder reads nothing until
        /// `decodeConfig` or `decodeFrame`.
        pub fn init(reader: *Io.Reader, options: Options) Self {
            return .{ .in = .{ .r = reader }, .options = options };
        }

        /// Reads the directory, and with `Options.entry`, that entry's
        /// header. The native format is `bgra8`, or a PNG entry's own.
        /// Calling it again returns the same config.
        pub fn decodeConfig(d: *Self) Error!decode.Config {
            if (d.err) |e| return e;
            if (d.state == .start) {
                d.readDirectory() catch |e| return d.fail(e);
                d.state = .config;
            }
            if (has_png and d.picked == .png) {
                var c = d.png_config;
                c.frame_count = 1;
                return c;
            }
            return .{
                .width = d.canvas[0],
                .height = d.canvas[1],
                .native = .bgra8,
                .frame_count = if (d.options.entry == null) d.count else 1,
            };
        }

        /// Decodes the next entry into the top-left corner of `dst`, which
        /// must be the canvas's size, in any format, and returns its region
        /// and its directory index. Returns null after the last.
        pub fn decodeFrame(d: *Self, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
            if (d.err) |e| return e;
            if (d.state == .done) return null;
            const config = try d.decodeConfig();
            try dst.check();
            if (dst.width != d.canvas[0] or dst.height != d.canvas[1]) return error.SizeMismatch;
            if (work.len < config.work_len) return error.WorkTooSmall;
            const f = d.nextFrame(dst, work) catch |e| return d.fail(e);
            if (d.options.entry != null or d.next == d.count) d.state = .done;
            return f;
        }

        /// The number of directory entries, after `decodeConfig`.
        pub fn entryCount(d: *const Self) u16 {
            return d.count;
        }

        /// Whether the file is a CUR, whose entries have hotspots.
        pub fn isCursor(d: *const Self) bool {
            return d.cursor;
        }

        /// Directory entry `i`, after `decodeConfig`.
        pub fn entry(d: *const Self, i: u16) Entry {
            const b = &d.directory[i];
            return .{
                .width = if (b[0] == 0) 256 else b[0],
                .height = if (b[1] == 0) 256 else b[1],
                .colors = b[2],
                .planes = std.mem.readInt(u16, b[4..6], .little),
                .bits = std.mem.readInt(u16, b[6..8], .little),
                .size = std.mem.readInt(u32, b[8..12], .little),
                .offset = std.mem.readInt(u32, b[12..16], .little),
            };
        }

        fn fail(d: *Self, e: Error) Error {
            d.err = e;
            return e;
        }

        fn readDirectory(d: *Self) Error!void {
            const h = try d.in.takeArray(6);
            const kind = std.mem.readInt(u16, h[2..4], .little);
            if (std.mem.readInt(u16, h[0..2], .little) != 0 or (kind != 1 and kind != 2)) return error.BadSignature;
            d.cursor = kind == 2;
            const count = std.mem.readInt(u16, h[4..6], .little);
            if (count == 0) return error.BadHeader;
            if (count > max_entries) return error.Unsupported;
            try d.options.limits.checkFrames(if (d.options.entry == null) count else 1);
            d.count = count;
            for (d.directory[0..count]) |*e| e.* = (try d.in.takeArray(16)).*;
            var canvas: [2]u32 = .{ 0, 0 };
            for (0..count) |i| {
                const e = d.entry(@intCast(i));
                canvas = .{ @max(canvas[0], e.width), @max(canvas[1], e.height) };
            }
            const i = d.options.entry orelse {
                try d.options.limits.checkSize(canvas[0], canvas[1]);
                d.canvas = canvas;
                return;
            };
            if (i >= count) return error.NoEntry;
            try d.goTo(d.entry(i).offset);
            if (try d.isPng()) {
                if (!has_png) return error.Unsupported;
                var o: Png.Options = .{};
                o.limits = d.options.limits;
                o.blob_sink = d.options.blob_sink;
                d.picked = .{ .png = .init(d.in.r, o) };
                d.png_config = try d.picked.png.decodeConfig();
                d.canvas = .{ d.png_config.width, d.png_config.height };
            } else {
                const b = try dib.readHeader(&d.in, .ico, 0);
                try d.options.limits.checkSize(b.width, b.height);
                d.picked = .{ .bmp = b };
                d.canvas = .{ b.width, b.height };
            }
        }

        fn isPng(d: *Self) Error!bool {
            const sig = d.in.r.peekArray(8) catch |e| return dib.mapRead(e);
            return std.mem.eql(u8, sig, "\x89PNG\r\n\x1a\n");
        }

        /// Moves to an entry's data at `offset`: forward by skipping, back
        /// with the seeker, but never into the directory.
        fn goTo(d: *Self, offset: u64) Error!void {
            if (offset < 6 + 16 * @as(u32, d.count)) return error.BadHeader;
            if (offset >= d.in.pos) return d.in.skipTo(offset);
            const s = d.options.seeker orelse return error.EntryBehind;
            try s.seek(s.context, offset);
            d.in.pos = offset;
        }

        fn nextFrame(d: *Self, dst: PixelBuffer, work: []u8) Error!decode.Frame {
            if (d.options.entry) |i| {
                switch (d.picked) {
                    .none => unreachable,
                    .bmp => |h| try decodeBmp(&d.in, h, dst),
                    .png => |*p| if (has_png) {
                        _ = (try p.decodeFrame(dst, work)) orelse return error.Truncated;
                        // A still image ends with IEND, which the next call
                        // reads and checks, as a PNG file's caller would.
                        // An animated one stops after its first frame.
                        if (d.png_config.frame_count == 1) _ = try p.decodeFrame(dst, work);
                    },
                }
                return .{ .index = i, .width = dst.width, .height = dst.height };
            }
            const i = d.next;
            try d.goTo(d.entry(i).offset);
            // PNG entries need `Options.entry`, which sizes their work
            // memory from their own header.
            if (try d.isPng()) return error.Unsupported;
            const h = try dib.readHeader(&d.in, .ico, 0);
            if (h.width > dst.width or h.height > dst.height) return error.EntryTooLarge;
            try decodeBmp(&d.in, h, dst.sub(0, 0, h.width, h.height));
            d.next += 1;
            return .{ .index = i, .width = h.width, .height = h.height };
        }
    };
}

/// A DIB entry's color table, pixels, and, below 32 bits, AND mask.
fn decodeBmp(in: *dib.Input, h: dib.Header, dst: PixelBuffer) dib.Error!void {
    var palette: dib.Palette = undefined;
    try dib.readPalette(in, h, h.tableEntries(), &palette);
    try dib.decodePixels(in, h, &palette, dst);
    if (h.bits < 32) try dib.applyMask(in, h, dst);
}

const TestDecoder = Generic(void);

inline fn le(comptime T: type, comptime v: T) [@sizeOf(T)]u8 {
    return @bitCast(std.mem.nativeToLittle(T, v));
}

/// A BITMAPINFOHEADER for an entry `w` by `h`, AND mask rows included.
inline fn testInfo(comptime w: i32, comptime h: i32, comptime bits: u16) []const u8 {
    return &(le(u32, 40) ++ le(i32, w) ++ le(i32, 2 * h) ++ le(u16, 1) ++ le(u16, bits) ++ [_]u8{0} ** 24);
}

/// 2 by 1, 1-bit: (10, 20, 30) masked out, then (40, 50, 60).
const entry_a = testInfo(2, 1, 1) ++ "\x1e\x14\x0a\x00\x3c\x32\x28\x00" ++ "\x40\x00\x00\x00" ++ "\x80\x00\x00\x00";
/// 1 by 1, 32-bit: (3, 2, 1, 128), its mask ignored.
const entry_b = testInfo(1, 1, 32) ++ "\x01\x02\x03\x80" ++ "\x80\x00\x00\x00";

/// A file with entries A and B, in that order in the directory, and their
/// data in that order or reversed.
inline fn testFile(comptime kind: u16, comptime reversed: bool) []const u8 {
    const end = 6 + 2 * 16;
    const a_at = if (reversed) end + entry_b.len else end;
    const b_at = if (reversed) end else end + entry_a.len;
    const head = le(u16, 0) ++ le(u16, kind) ++ le(u16, 2) ++
        "\x02\x01\x00\x00" ++ le(u16, 1) ++ le(u16, 1) ++ le(u32, entry_a.len) ++ le(u32, a_at) ++
        "\x01\x01\x00\x00" ++ le(u16, 5) ++ le(u16, 7) ++ le(u32, entry_b.len) ++ le(u32, b_at);
    return head ++ if (reversed) entry_b ++ entry_a else entry_a ++ entry_b;
}

const want_a = [_]u8{ 10, 20, 30, 0, 40, 50, 60, 255 };
const want_b = [_]u8{ 3, 2, 1, 128 };

/// Decodes every frame of `file` and checks them against A and B.
fn testAll(file: []const u8, seek: bool) !void {
    var r: Io.Reader = .fixed(file);
    var d: TestDecoder = .init(&r, .{ .seeker = if (seek) .fixed(&r) else null });
    const config = try d.decodeConfig();
    try testing.expectEqual(2, config.width);
    try testing.expectEqual(1, config.height);
    try testing.expectEqual(2, config.frame_count);
    var out: [8]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgba8, 2, 1);
    const a = (try d.decodeFrame(dst, &.{})).?;
    try testing.expectEqual(0, a.index);
    try testing.expectEqualSlices(u8, &want_a, &out);
    const b = (try d.decodeFrame(dst, &.{})).?;
    try testing.expectEqual(.{ 1, 1, 1 }, .{ b.index, b.width, b.height });
    try testing.expectEqualSlices(u8, &want_b, out[0..4]);
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
}

test "every entry, in directory order, with masks" {
    try testAll(testFile(1, false), false);
}

test "an entry behind the reader needs a seeker" {
    try testAll(testFile(1, true), true);
    var r: Io.Reader = .fixed(testFile(1, true));
    var d: TestDecoder = .init(&r, .{});
    _ = try d.decodeConfig();
    var out: [8]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgba8, 2, 1);
    _ = try d.decodeFrame(dst, &.{});
    try testing.expectError(error.EntryBehind, d.decodeFrame(dst, &.{}));
    try testing.expectError(error.EntryBehind, d.decodeFrame(dst, &.{}));
}

test "one entry, picked, never seeks" {
    for ([_]bool{ false, true }) |reversed| {
        const file = if (reversed) testFile(2, true) else testFile(2, false);
        var r: Io.Reader = .fixed(file);
        var d: TestDecoder = .init(&r, .{ .entry = 1 });
        const config = try d.decodeConfig();
        try testing.expectEqual(.{ 1, 1, 1 }, .{ config.width, config.height, config.frame_count });
        // A cursor's hotspot is in the planes and bits fields.
        try testing.expect(d.isCursor());
        try testing.expectEqual(.{ 5, 7 }, .{ d.entry(1).planes, d.entry(1).bits });
        var out: [4]u8 = undefined;
        _ = (try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 1, 1), &.{})).?;
        try testing.expectEqualSlices(u8, &want_b, &out);
    }
    var r: Io.Reader = .fixed(testFile(1, false));
    var d: TestDecoder = .init(&r, .{ .entry = 2 });
    try testing.expectError(error.NoEntry, d.decodeConfig());
}

fn testDecodeAll(file: []const u8) !void {
    var r: Io.Reader = .fixed(file);
    var d: TestDecoder = .init(&r, .{});
    _ = try d.decodeConfig();
    var out: [8]u8 = undefined;
    while (try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 1), &.{})) |_| {}
}

test "malformed files" {
    const file = comptime testFile(1, false);
    var out: [8]u8 = undefined;
    // Every truncation but of the last entry's mask, which a 32-bit entry
    // does not read.
    try testDecodeAll(file[0 .. file.len - 4]);
    for (0..file.len - 4) |n| try testing.expectError(error.Truncated, testDecodeAll(file[0..n]));
    // An offset into the directory.
    var bad = file[0..file.len].*;
    bad[18] = 6;
    var r: Io.Reader = .fixed(&bad);
    var d: TestDecoder = .init(&r, .{});
    _ = try d.decodeConfig();
    try testing.expectError(error.BadHeader, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 1), &.{}));
    // An entry larger than the directory says.
    bad = file[0..file.len].*;
    bad[6] = 1;
    r = .fixed(&bad);
    d = .init(&r, .{});
    _ = try d.decodeConfig();
    try testing.expectError(error.EntryTooLarge, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 1, 1), &.{}));
}

const PngDecoder = @import("../png/Decoder.zig");
const PngTestDecoder = Generic(PngDecoder);

/// A 2 by 1 RGBA PNG: (1, 2, 3, 4) and (5, 6, 7, 8).
const png_2x1 = "\x89PNG\r\n\x1a\n" ++
    "\x00\x00\x00\x0dIHDR\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f\x8a" ++
    "\x00\x00\x00\x14IDAT\x78\x01\x01\x09\x00\xf6\xff" ++
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x00\x81\x00\x25\x25\x2b\x1e\x22" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

/// An ICO whose one entry is `png`, its directory saying 16 by 16.
inline fn testPngFile(comptime png: []const u8) []const u8 {
    return le(u16, 0) ++ le(u16, 1) ++ le(u16, 1) ++ "\x10\x10\x00\x00" ++ le(u16, 1) ++ le(u16, 32) ++
        le(u32, png.len) ++ le(u32, 22) ++ png;
}

fn testDecodePng(comptime D: type, file: []const u8, options: D.Options, out: []u8) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: D = .init(&r, options);
    const config = try d.decodeConfig();
    const work = try testing.allocator.alloc(u8, config.work_len);
    defer testing.allocator.free(work);
    const dst = try PixelBuffer.init(out, .rgba8, config.width, config.height);
    _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    return config;
}

test "a picked PNG entry decodes through image.png, IEND included" {
    var out: [8]u8 = undefined;
    const config = try testDecodePng(PngTestDecoder, testPngFile(png_2x1), .{ .entry = 0 }, &out);
    // The PNG's own size, not the directory's.
    try testing.expectEqual(.{ 2, 1 }, .{ config.width, config.height });
    try testing.expectEqual(PixelFormat.rgba8, config.native);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &out);
    // IEND is checked as in a PNG file.
    const bad_iend = png_2x1[0 .. png_2x1.len - 1] ++ "\x83";
    try testing.expectError(error.BadCrc, testDecodePng(PngTestDecoder, testPngFile(bad_iend), .{ .entry = 0 }, &out));
    // Without image.png, or without `Options.entry`, a PNG entry is
    // unsupported.
    try testing.expectError(error.Unsupported, testDecodePng(TestDecoder, testPngFile(png_2x1), .{ .entry = 0 }, &out));
    var big: [16 * 16 * 4]u8 = undefined;
    try testing.expectError(error.Unsupported, testDecodePng(PngTestDecoder, testPngFile(png_2x1), .{}, &big));
}
