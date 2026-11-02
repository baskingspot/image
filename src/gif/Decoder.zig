//! A streaming GIF decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, and allocates nothing. It needs `Config.work_len` bytes
//! of work memory (about 68 KiB): the LZW table, a buffer of decoded
//! palette indices, a buffer of compressed data, and the palette in the
//! destination's format. Nothing scales with the image.
//!
//! Format: GIF87a and GIF89a (W3C, 1987 and 1990), with the NETSCAPE2.0 (or
//! ANIMEXTS1.0) application extension's loop count. Global and local color
//! tables, interlacing, and the graphic control extension's transparent
//! index, delay, and disposal. Comments, plain text, and other application
//! extensions are skipped.
//!
//! Frames follow the APNG model (docs/slop/gif.md): `decodeFrame` writes
//! each frame into its region of the caller's canvas, which must hold the
//! previous frame with its disposal applied. The first frame clears the
//! canvas outside its region to transparent black and writes its
//! transparent pixels as transparent black (`Frame.blend` is `src`); a
//! later frame with a transparent index leaves the canvas under those
//! pixels alone (`src_over`). Disposal is the caller's: `Frame.disposal`
//! says what to do with the region before the next frame, and
//! `decodeFrameConfig` reports the next frame before it is drawn, so a
//! caller can save the region that restore-to-previous needs.
//!
//! Where the specification leaves room, this decoder does what Wuffs does
//! by default: the canvas grows to hold the first frame, later frames are
//! clipped to it, a frame's LZW data must hold exactly its pixels, an
//! index past the color table (or with no color table) is opaque black,
//! the last of several graphic control extensions wins, and a byte that
//! starts no block ends the image as the trailer does. A file cut short
//! is `Truncated`, even after its last frame, where the trailer should be.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const lzw = @import("lzw.zig");

const Decoder = @This();

pub const Options = decode.Options;

pub const Error = decode.Error || error{
    /// A graphic control extension is not one block of 4 bytes.
    BadBlock,
    /// The minimum code size is past 8, or a code names an LZW table
    /// entry not yet defined.
    BadLzw,
    /// The LZW data ends before the frame's last pixel.
    NotEnoughData,
    /// The LZW data holds more pixels than the frame.
    TooMuchData,
};

reader: *Io.Reader,
options: Options,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,
state: State = .start,
/// The canvas: the logical screen, grown to hold the first frame.
width: u32 = 0,
height: u32 = 0,
/// Straight RGBA, opaque.
global: [256][4]u8 = undefined,
global_len: u16 = 0,
background: ?[4]u8 = null,
/// The NETSCAPE2.0 loop count, as a number of plays.
loop_count: ?u32 = null,
/// The graphic control extension for the next frame.
control: Control = .{},
/// The frame whose descriptor and color table are read, pixels next.
pending: ?Pending = null,
local: [256][4]u8 = undefined,
/// Frames decoded.
frames: u32 = 0,

const State = enum {
    start,
    /// Config read; between frames.
    frames,
    /// The trailer is read.
    done,
};

const Control = struct {
    disposal: u3 = 0,
    transparent: ?u8 = null,
    /// Hundredths of a second.
    delay: u16 = 0,
};

const Pending = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    interlaced: bool,
    /// Entries in `local`, or 0 to use the global color table.
    local_len: u16,
    control: Control,
};

const signature87 = "GIF87a";
const signature89 = "GIF89a";
const flicks_per_centisecond = decode.flicks_per_second / 100;

// The work memory, after aligning its start to 8 bytes for the table.
const table_len = @sizeOf(lzw.Table);
/// Decoded indices, converted to pixels each time it fills.
const index_len = 8192 + lzw.out_slack;
/// Compressed data, gathered from the data sub-blocks.
const data_len = 4096;
/// The palette in the destination's format, up to 16 bytes a pixel.
const palette_len = 256 * 16;
const work_len = 7 + table_len + index_len + data_len + palette_len;

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops after the trailer.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the header, the global color table, and the blocks up to the
/// first frame's color table. The native format is RGBA8: an animation's
/// canvas can be transparent wherever a frame does not cover it.
/// `frame_count` is null (GIF does not say), and `loop_count` is the
/// NETSCAPE2.0 count as a number of plays (the count plus one, or 0 for
/// forever) when one comes before the first frame, and 1 otherwise, as
/// browsers play such a file once. Calling it again returns the same
/// config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHead() catch |e| return d.fail(e);
    }
    return .{
        .width = d.width,
        .height = d.height,
        .native = .rgba8,
        .loop_count = d.loop_count orelse 1,
        .work_len = work_len,
        .background = d.background,
    };
}

/// Reads up to the next frame's pixels and returns the frame that
/// `decodeFrame` will decode next, without drawing it, or null after the
/// last frame. A caller saves the region here for a frame whose disposal
/// is `previous`.
pub fn decodeFrameConfig(d: *Decoder) Error!?decode.Frame {
    if (d.err) |e| return e;
    _ = try d.decodeConfig();
    const p = (d.nextPending() catch |e| return d.fail(e)) orelse return null;
    return d.frameOf(p);
}

/// Decodes the next frame into its region of `dst`, which must be the
/// canvas's size, in any format, using `work[0..work_len]`. Returns null
/// after the last frame, once the trailer is read.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    _ = try d.decodeConfig();
    try dst.check();
    if (dst.width != d.width or dst.height != d.height) return error.SizeMismatch;
    if (work.len < work_len) return error.WorkTooSmall;
    return d.nextFrame(dst, work) catch |e| return d.fail(e);
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn take(d: *Decoder, comptime n: usize) Error!*[n]u8 {
    return d.reader.takeArray(n) catch |e| mapRead(e);
}

fn takeByte(d: *Decoder) Error!u8 {
    return d.reader.takeByte() catch |e| mapRead(e);
}

fn readSlice(d: *Decoder, buf: []u8) Error!void {
    return d.reader.readSliceAll(buf) catch |e| mapRead(e);
}

fn readHead(d: *Decoder) Error!void {
    const h = try d.take(13);
    if (!std.mem.eql(u8, h[0..6], signature87) and !std.mem.eql(u8, h[0..6], signature89)) {
        return error.BadSignature;
    }
    const screen_w = std.mem.readInt(u16, h[6..8], .little);
    const screen_h = std.mem.readInt(u16, h[8..10], .little);
    const flags = h[10];
    const bg = h[11];
    if (flags & 0x80 != 0) {
        d.global_len = @as(u16, 2) << @intCast(flags & 7);
        try d.readColors(&d.global, d.global_len);
        if (bg < d.global_len) d.background = d.global[bg];
    }
    d.width = screen_w;
    d.height = screen_h;
    d.state = .frames;
    if (try d.readBlocks()) {
        const p = d.pending.?;
        d.width = @max(d.width, @as(u32, p.x) + p.width);
        d.height = @max(d.height, @as(u32, p.y) + p.height);
    }
    try d.options.limits.checkSize(d.width, d.height);
    try d.options.limits.checkWork(work_len);
}

/// Reads `n` RGB entries into `table` as opaque RGBA.
fn readColors(d: *Decoder, table: *[256][4]u8, n: u16) Error!void {
    // A byte to spare, so each entry is one 4-byte load.
    var raw: [256 * 3 + 1]u8 = undefined;
    try d.readSlice(raw[0 .. @as(usize, n) * 3]);
    for (table[0..n], 0..) |*c, i| {
        const v = std.mem.readInt(u32, raw[i * 3 ..][0..4], .little) | 0xff00_0000;
        c.* = @bitCast(std.mem.nativeToLittle(u32, v));
    }
}

/// Skips data sub-blocks through the block terminator.
fn skipSubBlocks(d: *Decoder) Error!void {
    while (true) {
        const n = try d.takeByte();
        if (n == 0) return;
        d.reader.discardAll(n) catch |e| return mapRead(e);
    }
}

/// The pending frame, reading blocks up to the next one if there is none;
/// null at the end of the image.
fn nextPending(d: *Decoder) Error!?Pending {
    if (d.pending) |p| return p;
    if (d.state == .done) return null;
    if (!try d.readBlocks()) return null;
    return d.pending.?;
}

/// Reads blocks up to and including the next image descriptor and color
/// table, which become `pending`, and returns true; or up to the end of
/// the image, and returns false.
fn readBlocks(d: *Decoder) Error!bool {
    while (true) {
        switch (try d.takeByte()) {
            0x2c => {
                try d.options.limits.checkFrames(@as(u64, d.frames) + 1);
                const b = try d.take(9);
                const flags = b[8];
                var p: Pending = .{
                    .x = std.mem.readInt(u16, b[0..2], .little),
                    .y = std.mem.readInt(u16, b[2..4], .little),
                    .width = std.mem.readInt(u16, b[4..6], .little),
                    .height = std.mem.readInt(u16, b[6..8], .little),
                    .interlaced = flags & 0x40 != 0,
                    .local_len = 0,
                    .control = d.control,
                };
                d.control = .{};
                if (flags & 0x80 != 0) {
                    p.local_len = @as(u16, 2) << @intCast(flags & 7);
                    try d.readColors(&d.local, p.local_len);
                }
                d.pending = p;
                return true;
            },
            0x21 => try d.readExtension(),
            // The trailer, and, as in Wuffs, any byte that starts no block.
            else => {
                d.state = .done;
                return false;
            },
        }
    }
}

fn readExtension(d: *Decoder) Error!void {
    switch (try d.takeByte()) {
        0xf9 => {
            if (try d.takeByte() != 4) return error.BadBlock;
            const b = try d.take(5);
            if (b[4] != 0) return error.BadBlock;
            d.control = .{
                .disposal = @intCast(b[0] >> 2 & 7),
                .transparent = if (b[0] & 1 != 0) b[3] else null,
                .delay = std.mem.readInt(u16, b[1..3], .little),
            };
            return;
        },
        0xff => {
            const n = try d.takeByte();
            if (n == 0) return;
            var id: [255]u8 = undefined;
            try d.readSlice(id[0..n]);
            if (n == 11 and (std.mem.eql(u8, id[0..11], "NETSCAPE2.0") or std.mem.eql(u8, id[0..11], "ANIMEXTS1.0"))) {
                while (true) {
                    const m = try d.takeByte();
                    if (m == 0) return;
                    var sub: [255]u8 = undefined;
                    try d.readSlice(sub[0..m]);
                    if (m >= 3 and sub[0] == 1 and d.frames == 0 and d.pending == null) {
                        const count = std.mem.readInt(u16, sub[1..3], .little);
                        d.loop_count = if (count == 0) 0 else @as(u32, count) + 1;
                    }
                }
            }
        },
        else => {},
    }
    try d.skipSubBlocks();
}

/// The frame `p` will be once drawn: its region clipped to the canvas.
fn frameOf(d: *const Decoder, p: Pending) decode.Frame {
    const x = @min(p.x, d.width);
    const y = @min(p.y, d.height);
    const first = d.frames == 0;
    return .{
        .index = d.frames,
        .x = x,
        .y = y,
        .width = @min(p.width, d.width - x),
        .height = @min(p.height, d.height - y),
        .duration = @as(u64, p.control.delay) * flicks_per_centisecond,
        .disposal = switch (p.control.disposal) {
            2 => .background,
            // Some encoders wrote 4 for restore to previous; Wuffs and
            // Chromium read it so. Before the first frame there is only the
            // cleared canvas.
            3, 4 => if (first) .background else .previous,
            else => .none,
        },
        .blend = if (!first and p.control.transparent != null) .src_over else .src,
        .is_opaque = p.control.transparent == null,
    };
}

fn nextFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    const p = try d.nextPending() orelse return null;
    try d.options.limits.checkSize(p.width, p.height);
    const frame = d.frameOf(p);
    const w = work[std.mem.alignPointerOffset(work.ptr, 8).?..];
    const table: *lzw.Table = @ptrCast(@alignCast(w[0..table_len]));
    const indices = w[table_len..][0..index_len];
    const data = w[table_len + index_len ..][0..data_len];
    const palette = w[table_len + index_len + data_len ..][0..palette_len];

    const min = try d.takeByte();
    if (min > 8) return error.BadLzw;
    // The color table in the destination's format, for each index the
    // codes can name: opaque black past the table's end, and the
    // transparent index transparent black (only the first frame writes
    // it).
    const n = @as(usize, 1) << @intCast(min);
    const colors = if (p.local_len != 0) d.local[0..@min(n, p.local_len)] else d.global[0..@min(n, d.global_len)];
    const bpp = dst.format.bytesPerPixel();
    var rgba_buf: [256][4]u8 = undefined;
    const rgba: *[256][4]u8 = if (dst.format == .rgba8) @ptrCast(palette[0 .. 256 * 4]) else &rgba_buf;
    @memcpy(rgba[0..colors.len], colors);
    @memset(rgba[colors.len..n], .{ 0, 0, 0, 255 });
    if (p.control.transparent) |t| rgba[t] = @splat(0);
    if (dst.format != .rgba8) Converter.init(dst.format, .rgba8).run(palette, std.mem.sliceAsBytes(rgba), n);

    if (d.frames == 0) clearOutside(dst, frame);
    var out: Out = .init(dst, palette[0 .. 256 * bpp], p, frame.blend == .src_over);
    try d.pixels(&out, table, @intCast(min), indices, data);
    d.pending = null;
    d.frames += 1;
    return frame;
}

/// Clears the canvas outside `f`'s region to transparent black.
fn clearOutside(dst: PixelBuffer, f: decode.Frame) void {
    if (f.width == dst.width and f.height == dst.height) return;
    const bpp = dst.format.bytesPerPixel();
    var zero: [16]u8 = undefined;
    Converter.init(dst.format, .rgba8).run(&zero, &.{ 0, 0, 0, 0 }, 1);
    for (0..dst.height) |yy| {
        const y: u32 = @intCast(yy);
        const row = dst.row(y);
        const inside = y >= f.y and y < f.y + f.height;
        const spans = [2][2]usize{
            if (inside) .{ 0, f.x } else .{ 0, dst.width },
            if (inside) .{ f.x + f.width, dst.width } else .{ 0, 0 },
        };
        for (spans) |s| {
            for (s[0]..s[1]) |x| @memcpy(row[x * bpp ..][0..bpp], zero[0..bpp]);
        }
    }
}

/// Decodes a frame's LZW data, after its minimum code size `min` through
/// its block terminator, into `out`.
fn pixels(d: *Decoder, out: *Out, table: *lzw.Table, min: u4, indices: []u8, data: []u8) Error!void {
    var z: lzw.Decoder = .init(table, min);
    var len: usize = 0;
    var pos: usize = 0;
    var ended = false;
    while (true) {
        if (pos == len and !ended) {
            // Gather sub-blocks; `pos == len`, so nothing is kept.
            len = 0;
            pos = 0;
            while (data.len - len >= 255) {
                const n = try d.takeByte();
                if (n == 0) {
                    ended = true;
                    break;
                }
                try d.readSlice(data[len..][0..n]);
                len += n;
            }
        }
        const r = try z.decode(data[0..len], pos, indices, 0);
        pos = r.in_pos;
        try out.emit(indices[0..r.out_pos]);
        switch (r.status) {
            .out_full => {},
            .need_input => if (ended) break,
            .end => break,
        }
    }
    if (out.rows_left != 0) return error.NotEnoughData;
    // Data after the end code is skipped, as in Wuffs and giflib.
    if (!ended) try d.skipSubBlocks();
}

/// Where a frame's indices go: its rows of the canvas, in order or
/// interlaced, clipped to the canvas.
const Out = struct {
    dst: PixelBuffer,
    /// 256 entries in the destination's format.
    palette: []const u8,
    over: bool,
    /// The transparent index, or 256, which no index equals.
    transparent: u16,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    /// Columns of the frame inside the canvas.
    visible: u32,
    interlaced: bool,
    pass: u2 = 0,
    /// The frame row being written, the column in it, and the rows left.
    row: u32 = 0,
    col: u32 = 0,
    rows_left: u32,

    fn init(dst: PixelBuffer, palette: []const u8, p: Pending, over: bool) Out {
        return .{
            .dst = dst,
            .palette = palette,
            .over = over,
            .transparent = p.control.transparent orelse 256,
            .x = p.x,
            .y = p.y,
            .width = p.width,
            .height = p.height,
            .visible = if (p.x >= dst.width) 0 else @min(p.width, dst.width - p.x),
            .interlaced = p.interlaced,
            .rows_left = if (p.width == 0) 0 else p.height,
            .row = 0,
        };
    }

    const pass_start = [4]u32{ 0, 4, 2, 1 };
    const pass_step = [4]u32{ 8, 8, 4, 2 };

    fn emit(o: *Out, indices: []const u8) Error!void {
        var i: usize = 0;
        while (i < indices.len) {
            if (o.rows_left == 0) return error.TooMuchData;
            const n: u32 = @intCast(@min(o.width - o.col, indices.len - i));
            const y = @as(u64, o.y) + o.row;
            if (y < o.dst.height and o.col < o.visible) {
                const m = @min(n, o.visible - o.col);
                const bpp = o.dst.format.bytesPerPixel();
                const row = o.dst.row(@intCast(y))[(o.x + o.col) * bpp ..][0 .. m * bpp];
                o.put(row, indices[i..][0..m]);
            }
            o.col += n;
            i += n;
            if (o.col == o.width) {
                o.col = 0;
                o.rows_left -= 1;
                if (!o.interlaced) {
                    o.row += 1;
                } else {
                    o.row += pass_step[o.pass];
                    while (o.rows_left != 0 and o.row >= o.height) {
                        o.pass += 1;
                        o.row = pass_start[o.pass];
                    }
                }
            }
        }
    }

    fn put(o: *const Out, row: []u8, indices: []const u8) void {
        switch (o.dst.format.bytesPerPixel()) {
            inline 1, 2, 3, 4, 6, 8, 16 => |bpp| {
                if (o.over)
                    putN(bpp, true, row, o.palette, indices, o.transparent)
                else
                    putN(bpp, false, row, o.palette, indices, o.transparent);
            },
            else => unreachable,
        }
    }
};

fn putN(
    comptime bpp: usize,
    comptime over: bool,
    row: []u8,
    palette: []const u8,
    indices: []const u8,
    transparent: u16,
) void {
    for (indices, 0..) |v, k| {
        if (over and v == transparent) continue;
        row[k * bpp ..][0..bpp].* = palette[@as(usize, v) * bpp ..][0..bpp].*;
    }
}

// Tests. `TestGif` writes GIF files; frames' LZW data comes from
// lzw.zig's dictionary encoder, and the expected pixels from the indices
// that went in.

const TestGif = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(t: *TestGif) void {
        t.bytes.deinit(testing.allocator);
        t.* = undefined;
    }

    fn put(t: *TestGif, b: []const u8) !void {
        try t.bytes.appendSlice(testing.allocator, b);
    }

    fn int(t: *TestGif, v: u16) !void {
        try t.put(&.{ @truncate(v), @truncate(v >> 8) });
    }

    /// The header and a global color table of `colors` (none if empty),
    /// whose length is a power of two from 2 to 256.
    fn head(t: *TestGif, w: u16, h: u16, colors: []const [3]u8) !void {
        try t.put(signature89);
        try t.int(w);
        try t.int(h);
        try t.put(&.{ if (colors.len == 0) 0 else 0x80 | tableBits(colors.len), 0, 0 });
        for (colors) |c| try t.put(&c);
    }

    fn tableBits(n: usize) u8 {
        return @intCast(std.math.log2_int(usize, n) - 1);
    }

    fn control(t: *TestGif, disposal: u3, transparent: ?u8, delay: u16) !void {
        try t.put(&.{ 0x21, 0xf9, 4, @as(u8, disposal) << 2 | @intFromBool(transparent != null) });
        try t.int(delay);
        try t.put(&.{ transparent orelse 0, 0 });
    }

    fn loop(t: *TestGif, count: u16) !void {
        try t.put("\x21\xff\x0bNETSCAPE2.0\x03\x01");
        try t.int(count);
        try t.put("\x00");
    }

    const FrameOptions = struct {
        local: []const [3]u8 = &.{},
        interlaced: bool = false,
        min_bits: u4 = 8,
        /// Pixels dropped from, or added to, the end of the data.
        drop: usize = 0,
        extra: usize = 0,
    };

    /// A frame of `indices`, `w` by `h` pixels, row by row.
    fn frame(t: *TestGif, x: u16, y: u16, w: u16, h: u16, indices: []const u8, o: FrameOptions) !void {
        const a = testing.allocator;
        try t.put(&.{0x2c});
        for ([_]u16{ x, y, w, h }) |v| try t.int(v);
        var flags: u8 = if (o.interlaced) 0x40 else 0;
        if (o.local.len != 0) flags |= 0x80 | tableBits(o.local.len);
        try t.put(&.{flags});
        for (o.local) |c| try t.put(&c);
        // The rows in the order the file stores them.
        var rows: std.ArrayList(u8) = .empty;
        defer rows.deinit(a);
        if (o.interlaced) {
            for ([_][2]u16{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } }) |pass| {
                var row = pass[0];
                while (row < h) : (row += pass[1]) try rows.appendSlice(a, indices[@as(usize, row) * w ..][0..w]);
            }
        } else try rows.appendSlice(a, indices);
        for (0..o.extra) |i| try rows.append(a, @intCast(i & 1));
        const data = rows.items[0 .. rows.items.len - o.drop];
        const codes = try lzw.testing_encoder.encode(a, data, o.min_bits, if (data.len % 2 == 0) 50 else null);
        defer a.free(codes);
        try t.put(&.{o.min_bits});
        var at: usize = 0;
        while (at < codes.len) {
            const n = @min(codes.len - at, 1 + (at * 7 + 100) % 255);
            try t.put(&.{@intCast(n)});
            try t.put(codes[at..][0..n]);
            at += n;
        }
        try t.put(&.{0});
    }
};

fn randomColors(random: std.Random, buf: [][3]u8) [][3]u8 {
    for (buf) |*c| random.bytes(c);
    return buf;
}

test "a still image, in order and interlaced, through any reader" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var colors_buf: [256][3]u8 = undefined;
    const colors = randomColors(random, &colors_buf);
    const w = 37;
    const h = 29;
    var indices: [w * h]u8 = undefined;
    // Smooth runs and noise, so strings are long and short.
    for (&indices, 0..) |*v, i| v.* = if (i % 200 < 120) @intCast(i / 50 % 256) else random.int(u8);
    const work = try a.alloc(u8, work_len);
    defer a.free(work);
    for ([_]bool{ false, true }) |interlaced| {
        var t: TestGif = .{};
        defer t.deinit();
        try t.head(w, h, colors);
        try t.frame(0, 0, w, h, &indices, .{ .interlaced = interlaced });
        try t.put("\x3b");
        for ([_]usize{ 1, 7, t.bytes.items.len }) |step| {
            var trickle: Trickle = undefined;
            trickle.init(t.bytes.items, step);
            var d: Decoder = .init(&trickle.reader, .{});
            const config = try d.decodeConfig();
            try testing.expectEqual(decode.Config{
                .width = w,
                .height = h,
                .native = .rgba8,
                // No loop extension: the file plays once.
                .loop_count = 1,
                .work_len = work_len,
                .background = .{ colors[0][0], colors[0][1], colors[0][2], 255 },
            }, config);
            var out: [w * h * 4]u8 = undefined;
            const dst = try PixelBuffer.init(&out, .rgba8, w, h);
            const f = (try d.decodeFrame(dst, work)).?;
            try testing.expectEqual(decode.Frame{ .width = w, .height = h, .is_opaque = true }, f);
            for (indices, 0..) |v, i| try testing.expectEqualSlices(u8, &(colors[v] ++ .{255}), out[i * 4 ..][0..4]);
            try testing.expectEqual(null, try d.decodeFrame(dst, work));
            try testing.expectEqual(null, try d.decodeFrame(dst, work));
        }
    }
}

/// A reader that hands over at most `step` bytes at a time.
const Trickle = struct {
    data: []const u8,
    step: usize,
    buffer: [decode.min_buffer_len]u8 = undefined,
    reader: Io.Reader,

    fn init(t: *Trickle, data: []const u8, step: usize) void {
        t.* = .{
            .data = data,
            .step = step,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = &t.buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @alignCast(@fieldParentPtr("reader", r));
        if (t.data.len == 0) return error.EndOfStream;
        const n = try w.write(t.data[0..limit.minInt(@min(t.step, t.data.len))]);
        t.data = t.data[n..];
        return n;
    }
};

test "an animation: regions, transparency, disposal, timing, and the loop count" {
    const a = testing.allocator;
    // A 4 by 3 canvas. Frame 0 is 2 by 2 at (1, 0) with index 3
    // transparent; frame 1 is 3 by 1 at (0, 2) with index 1 transparent,
    // from its own color table; frame 2 reaches past the canvas.
    const colors = [4][3]u8{ .{ 10, 11, 12 }, .{ 20, 21, 22 }, .{ 30, 31, 32 }, .{ 40, 41, 42 } };
    const local = [2][3]u8{ .{ 50, 51, 52 }, .{ 60, 61, 62 } };
    var t: TestGif = .{};
    defer t.deinit();
    try t.head(4, 3, &colors);
    try t.loop(2);
    try t.control(3, 3, 10);
    try t.frame(1, 0, 2, 2, &.{ 0, 3, 2, 1 }, .{ .min_bits = 2 });
    try t.control(4, 1, 250);
    try t.frame(0, 2, 3, 1, &.{ 0, 1, 0 }, .{ .local = &local, .min_bits = 2 });
    // Three graphic control extensions: the last counts.
    try t.control(2, null, 1);
    try t.control(0, 0, 2);
    try t.control(1, 2, 7);
    try t.frame(3, 1, 2, 2, &.{ 2, 0, 1, 1 }, .{ .min_bits = 2, .interlaced = true });
    try t.put("\x3b");

    const work = try a.alloc(u8, work_len);
    defer a.free(work);
    var r: Io.Reader = .fixed(t.bytes.items);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(3, config.loop_count);
    var out: [4 * 3 * 4]u8 = undefined;
    @memset(&out, 0xee);
    const dst = try PixelBuffer.init(&out, .rgba8, 4, 3);
    const centi = decode.flicks_per_second / 100;

    // Restore to previous on the first frame is reported as background.
    const f0 = (try d.decodeFrameConfig()).?;
    try testing.expectEqual(decode.Frame{
        .x = 1,
        .width = 2,
        .height = 2,
        .duration = 10 * centi,
        .disposal = .background,
    }, f0);
    try testing.expectEqual(f0, (try d.decodeFrame(dst, work)).?);
    const o: [4]u8 = @splat(0);
    const c = struct {
        fn of(rgb: [3]u8) [4]u8 {
            return rgb ++ .{255};
        }
    }.of;
    const want = o ++ c(colors[0]) ++ o ++ o ++ o ++ c(colors[2]) ++ c(colors[1]) ++ o ++ o ++ o ++ o ++ o;
    try testing.expectEqualSlices(u8, &want, &out);

    // Disposal 4 is restore to previous; the transparent pixel leaves the
    // canvas alone.
    out[2 * 16 + 4 ..][0..4].* = .{ 1, 2, 3, 4 };
    const f1 = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(decode.Frame{
        .index = 1,
        .y = 2,
        .width = 3,
        .height = 1,
        .duration = 250 * centi,
        .disposal = .previous,
        .blend = .src_over,
    }, f1);
    try testing.expectEqualSlices(u8, &(c(local[0]) ++ .{ 1, 2, 3, 4 } ++ c(local[0])), out[2 * 16 ..][0..12]);

    const f2 = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(decode.Frame{
        .index = 2,
        .x = 3,
        .y = 1,
        .width = 1,
        .height = 2,
        .duration = 7 * centi,
        .blend = .src_over,
    }, f2);
    // Clipped to the column at x = 3: index 2 is transparent, then 1.
    try testing.expectEqualSlices(u8, &o, out[1 * 16 + 12 ..][0..4]);
    try testing.expectEqualSlices(u8, &c(colors[1]), out[2 * 16 + 12 ..][0..4]);
    try testing.expectEqual(null, try d.decodeFrameConfig());
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
}

test "the canvas grows to hold the first frame" {
    const a = testing.allocator;
    var t: TestGif = .{};
    defer t.deinit();
    try t.head(2, 1, &.{ .{ 1, 2, 3 }, .{ 4, 5, 6 } });
    try t.frame(1, 1, 2, 2, &.{ 0, 1, 1, 0 }, .{ .min_bits = 2 });
    try t.put("\x3b");
    var r: Io.Reader = .fixed(t.bytes.items);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(.{ 3, 3 }, .{ config.width, config.height });
    var r2: Io.Reader = .fixed(t.bytes.items);
    var tight: Decoder = .init(&r2, .{ .limits = .{ .max_width = 2 } });
    try testing.expectError(error.ImageTooLarge, tight.decodeConfig());
    const work = try a.alloc(u8, work_len);
    defer a.free(work);
    // Gray: the frame converted, and transparent black outside it.
    var out: [9]u8 = undefined;
    _ = (try d.decodeFrame(try PixelBuffer.init(&out, .gray8, 3, 3), work)).?;
    var gray: [2]u8 = undefined;
    Converter.init(.gray8, .rgba8).run(&gray, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, gray[0], gray[1], 0, gray[1], gray[0] }, &out);
}

test "indices past the color table, and no color table, are opaque black" {
    const a = testing.allocator;
    const work = try a.alloc(u8, work_len);
    defer a.free(work);
    for ([_]bool{ false, true }) |table| {
        var t: TestGif = .{};
        defer t.deinit();
        try t.head(2, 1, if (table) &.{ .{ 9, 9, 9 }, .{ 8, 8, 8 } } else &.{});
        try t.frame(0, 0, 2, 1, &.{ 1, 3 }, .{ .min_bits = 2 });
        try t.put("\x3b");
        var r: Io.Reader = .fixed(t.bytes.items);
        var d: Decoder = .init(&r, .{});
        _ = try d.decodeConfig();
        var out: [8]u8 = undefined;
        _ = (try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 1), work)).?;
        const first: [4]u8 = if (table) .{ 8, 8, 8, 255 } else .{ 0, 0, 0, 255 };
        try testing.expectEqualSlices(u8, &(first ++ .{ 0, 0, 0, 255 }), &out);
    }
}

test "a minimum code size of 0, as Wuffs and giflib read it" {
    const a = testing.allocator;
    const work = try a.alloc(u8, work_len);
    defer a.free(work);
    // Codes 1 (clear) and 0 at 1 bit, 0 at 2 bits, 0 and 0 at 3 bits, then
    // 2 (end): four pixels of index 0. Wuffs and giflib both decode this.
    var t: TestGif = .{};
    defer t.deinit();
    try t.head(2, 2, &.{ .{ 0, 0, 255 }, .{ 9, 9, 9 } });
    try t.put("\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x00\x02\x01\x28\x00\x3b");
    var r: Io.Reader = .fixed(t.bytes.items);
    var d: Decoder = .init(&r, .{});
    _ = try d.decodeConfig();
    var out: [16]u8 = undefined;
    _ = (try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 2), work)).?;
    try testing.expectEqualSlices(u8, &(.{ 0, 0, 255, 255 } ** 4), &out);
    try testing.expectEqual(null, try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 2), work));
}

test "errors, and they stick" {
    const a = testing.allocator;
    const work = try a.alloc(u8, work_len);
    defer a.free(work);
    const colors = [2][3]u8{ .{ 1, 1, 1 }, .{ 2, 2, 2 } };
    const px = [4]u8{ 0, 1, 1, 0 };
    const Case = struct {
        want: Error,
        o: TestGif.FrameOptions = .{ .min_bits = 2 },
        trailer: bool = true,
        head: []const u8 = "",
        ext: []const u8 = "",
    };
    const cases = [_]Case{
        .{ .want = error.NotEnoughData, .o = .{ .min_bits = 2, .drop = 1 } },
        .{ .want = error.TooMuchData, .o = .{ .min_bits = 2, .extra = 1 } },
        .{ .want = error.Truncated, .trailer = false },
        .{ .want = error.BadSignature, .head = "GIF88a" },
        .{ .want = error.BadBlock, .ext = "\x21\xf9\x03\x00\x00\x00\x00" },
        .{ .want = error.BadBlock, .ext = "\x21\xf9\x04\x00\x00\x00\x00\x01\x00" },
    };
    for (cases) |case| {
        var t: TestGif = .{};
        defer t.deinit();
        try t.head(2, 2, &colors);
        if (case.head.len != 0) @memcpy(t.bytes.items[0..6], case.head);
        try t.put(case.ext);
        try t.frame(0, 0, 2, 2, &px, case.o);
        if (case.trailer) try t.put("\x3b");
        var r: Io.Reader = .fixed(t.bytes.items);
        var d: Decoder = .init(&r, .{});
        var out: [16]u8 = undefined;
        const dst = try PixelBuffer.init(&out, .rgba8, 2, 2);
        const got = blk: {
            _ = d.decodeConfig() catch |e| break :blk e;
            while (d.decodeFrame(dst, work) catch |e| break :blk e) |_| {}
            return error.TestExpectedError;
        };
        try testing.expectEqual(case.want, got);
        try testing.expectError(case.want, d.decodeFrame(dst, work));
        try testing.expectError(case.want, d.decodeConfig());
    }
    // Bad LZW: a minimum code size past 8, and a code past the table.
    const bad = [_][]const u8{ "\x09\x02\x00\x00\x00", "\x02\x01\x3c\x00" };
    for (bad) |data| {
        var t: TestGif = .{};
        defer t.deinit();
        try t.head(2, 2, &colors);
        try t.put("\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00");
        try t.put(data);
        try t.put("\x3b");
        var r: Io.Reader = .fixed(t.bytes.items);
        var d: Decoder = .init(&r, .{});
        _ = try d.decodeConfig();
        var out: [16]u8 = undefined;
        try testing.expectError(error.BadLzw, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 2, 2), work));
    }
}

test "limits: frames, frame size, and buffers" {
    const a = testing.allocator;
    const work = try a.alloc(u8, work_len);
    defer a.free(work);
    var t: TestGif = .{};
    defer t.deinit();
    try t.head(2, 2, &.{ .{ 1, 1, 1 }, .{ 2, 2, 2 } });
    for (0..3) |_| try t.frame(0, 0, 2, 2, &.{ 0, 1, 1, 0 }, .{ .min_bits = 2 });
    // A frame far past the canvas, larger than the pixel limit.
    try t.frame(100, 100, 3, 2, &.{ 0, 1, 1, 0, 1, 1 }, .{ .min_bits = 2 });
    try t.put("\x3b");
    var out: [16]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgba8, 2, 2);

    var r: Io.Reader = .fixed(t.bytes.items);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_frames = 2 } });
    _ = try d.decodeConfig();
    try testing.expectError(error.WorkTooSmall, d.decodeFrame(dst, work[1..]));
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 1, 4), work));
    try testing.expectError(error.BufferTooSmall, d.decodeFrame(.{
        .pixels = out[1..],
        .format = .rgba8,
        .width = 2,
        .height = 2,
        .stride = 8,
    }, work));
    _ = (try d.decodeFrame(dst, work)).?;
    _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectError(error.TooManyFrames, d.decodeFrame(dst, work));

    r = .fixed(t.bytes.items);
    d = .init(&r, .{ .limits = .{ .max_pixels = 5 } });
    for (0..3) |_| _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectError(error.ImageTooLarge, d.decodeFrame(dst, work));
    r = .fixed(t.bytes.items);
    d = .init(&r, .{});
    for (0..4) |_| _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
}

test {
    _ = lzw;
}
