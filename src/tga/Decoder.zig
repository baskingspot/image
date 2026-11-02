//! A streaming TGA decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, and allocates nothing. A color-mapped image keeps its
//! color map in the caller's work memory (`Config.work_len`, 4 bytes an
//! entry); every other image needs none.
//!
//! Format: the Truevision TGA File Format Specification, version 2.0
//! (docs/slop/tga.md has the decisions below and why). Every image type the
//! specification defines: color-mapped (1, 9) with 8- or 16-bit indices and
//! 15-, 16-, 24-, or 32-bit entries, true-color (2, 10) at 15, 16, 24, and
//! 32 bits, gray (3, 11) at 8 bits and 16 (gray and alpha), run-length
//! encoded or not, in any of the four origins, and type 0, which has no
//! image (no frames). Where the specification leaves a choice:
//!
//! - 32-bit pixels and color-map entries always carry alpha, whatever the
//!   descriptor's attribute-bit count says, as every reader we compare with
//!   does; 16-bit pixels use their top bit as alpha only when the descriptor
//!   names one attribute bit; 15- and 16-bit color-map entries are opaque, as
//!   the specification says of their 16th bit. Five-bit channels widen by bit
//!   replication.
//! - A color map's first entry index offsets the indices: pixel value i is
//!   entry i - first. An index outside the map is opaque black, as in Wuffs.
//! - Run-length packets may run from one scan line into the next (the
//!   specification says they should not, and older writers do), but not past
//!   the last pixel (`RunPastEnd`).
//! - The descriptor's interleaving bits (7-6), the screen origin, and the
//!   color-map fields of an image without a color map are ignored; a color
//!   map in a true-color or gray file is skipped.
//!
//! The TGA 2.0 footer and extension area follow the pixels, so they cannot
//! shape `Config`: the `decodeFrame` call after the image reads the rest of
//! the input and `trailer` reports what it found. Reading forward only, the
//! decoder finds an extension area that starts right after the image data or
//! ends right before the footer, the two places writers put it.

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
    /// A run-length packet goes past the last pixel.
    RunPastEnd,
};

/// What follows the image: the TGA 2.0 footer and the extension area it
/// points to.
pub const Trailer = struct {
    /// Whether the input ends with the TGA 2.0 footer.
    footer: bool = false,
    /// The footer's offsets of the extension area and the developer
    /// directory, from the start of the file; 0 when there is none.
    extension_offset: u32 = 0,
    developer_offset: u32 = 0,
    /// The extension area's fields that describe the image, when the footer
    /// names one where this decoder can read it (see the top of this file).
    extension: ?Extension = null,
};

/// The extension area's fields that describe the image. Its text fields,
/// time stamps, postage stamp, and tables are skipped.
pub const Extension = struct {
    /// `gamma` from the gamma value, as PNG's gAMA would store it (the
    /// file's 2.2 is 45455), and `density` from the pixel aspect ratio,
    /// with no unit.
    metadata: decode.Metadata = .{},
    /// The key color, straight RGBA, unless it is zero (unset).
    background: ?[4]u8 = null,
    /// What the alpha channel holds, if the attributes type says.
    alpha: ?Alpha = null,

    pub const Alpha = enum(u8) {
        /// No alpha data.
        none = 0,
        /// Undefined data that can be ignored.
        ignore = 1,
        /// Undefined data that should be retained.
        retain = 2,
        /// Alpha, straight.
        straight = 3,
        /// Alpha, with the color premultiplied by it.
        premultiplied = 4,
    };
};

reader: *Io.Reader,
options: Options,
state: State = .start,
header: Header = undefined,
/// Bytes read from the input so far: the footer's offsets count from the
/// first byte.
pos: u64 = 0,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,
trailer_found: Trailer = .{},

const State = enum { start, config, frame, done };

const Kind = enum { none, mapped, truecolor, gray };

/// How a stored pixel becomes a native one.
const Expand = enum {
    /// It is one already.
    none,
    /// Five bits a channel, blue lowest: to `bgr8`.
    bgr555,
    /// The same with the top bit as alpha: to `bgra8`.
    bgra5551,
    /// An index into the color map.
    index8,
    index16,
};

const Header = struct {
    id_len: u8,
    map_type: u8,
    kind: Kind,
    rle: bool,
    map_first: u16,
    map_len: u16,
    map_bits: u8,
    width: u16,
    height: u16,
    descriptor: u8,
    native: PixelFormat,
    /// Bytes per stored pixel.
    stored: u3,
    expand: Expand,

    fn isOpaque(h: Header) bool {
        return !h.native.hasAlpha();
    }

    fn workLen(h: Header) usize {
        return if (h.kind == .mapped) @as(usize, h.map_len) * 4 else 0;
    }
};

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the 18-byte header. The native format is `bgr8` or `bgra8` for
/// color, `gray8` or `gray_alpha8` for gray. Calling it again returns the
/// same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.header = d.readHeader() catch |e| return d.fail(e);
        d.state = .config;
    }
    const h = d.header;
    return .{
        .width = h.width,
        .height = h.height,
        .native = h.native,
        .frame_count = if (h.kind == .none) 0 else 1,
        .work_len = h.workLen(),
        .is_opaque = h.isOpaque(),
    };
}

/// Decodes the image into `dst`, which must be the image's size, in any
/// format, using `work[0..Config.work_len]`. The call after the image (or
/// the first, for type 0) reads the rest of the input for the footer,
/// returns null, and leaves what it found in `trailer`.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    const h = d.header;
    try dst.check();
    if (dst.width != h.width or dst.height != h.height) return error.SizeMismatch;
    if (d.state == .frame or h.kind == .none) {
        if (h.kind == .none) d.skipToPixels(&.{}) catch |e| return d.fail(e);
        d.trailer_found = d.readTrailer() catch |e| return d.fail(e);
        d.state = .done;
        return null;
    }
    const palette = work[0..@min(work.len, h.workLen())];
    if (palette.len < h.workLen()) return error.WorkTooSmall;
    d.skipToPixels(palette) catch |e| return d.fail(e);
    d.pixels(dst, palette) catch |e| return d.fail(e);
    d.state = .frame;
    return .{ .width = h.width, .height = h.height, .is_opaque = h.isOpaque() };
}

/// The footer and extension area, once the `decodeFrame` call that returns
/// null has read them; null before.
pub fn trailer(d: *const Decoder) ?Trailer {
    return if (d.state == .done and d.err == null) d.trailer_found else null;
}

/// Sets in `config` what the extension area gives: the gamma and the pixel
/// aspect ratio in its metadata, and the key color as its background.
/// `image.Decoder.finalConfig` calls it once the frames end; the attributes
/// type is only in `trailer`.
pub fn applyTrailer(d: *const Decoder, config: *decode.Config) void {
    const e = (d.trailer() orelse return).extension orelse return;
    if (e.metadata.gamma) |g| config.metadata.gamma = g;
    if (e.metadata.density) |x| config.metadata.density = x;
    if (e.background) |b| config.background = b;
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

fn readHeader(d: *Decoder) Error!Header {
    const b = d.reader.takeArray(18) catch |e| return mapRead(e);
    d.pos = 18;
    const map_type = b[1];
    const image_type = b[2];
    const depth = b[16];
    const descriptor = b[17];
    if (map_type > 1) return error.BadHeader;
    const kind: Kind = switch (image_type & ~@as(u8, 8)) {
        0 => if (image_type == 0) .none else return error.BadHeader,
        1 => .mapped,
        2 => .truecolor,
        3 => .gray,
        else => return switch (image_type) {
            // Huffman and quadtree types from before version 2.0, and
            // developer types.
            32, 33, 128...255 => error.Unsupported,
            else => error.BadHeader,
        },
    };
    var h: Header = .{
        .id_len = b[0],
        .map_type = map_type,
        .kind = kind,
        .rle = image_type & 8 != 0,
        .map_first = std.mem.readInt(u16, b[3..5], .little),
        .map_len = std.mem.readInt(u16, b[5..7], .little),
        .map_bits = b[7],
        .width = std.mem.readInt(u16, b[12..14], .little),
        .height = std.mem.readInt(u16, b[14..16], .little),
        .descriptor = descriptor,
        .native = .bgr8,
        .stored = 0,
        .expand = .none,
    };
    switch (kind) {
        .none => {},
        .mapped => {
            if (map_type != 1) return error.BadHeader;
            h.native = switch (h.map_bits) {
                15, 16, 24 => .bgr8,
                32 => .bgra8,
                else => return error.Unsupported,
            };
            h.expand, h.stored = switch (depth) {
                8 => .{ .index8, 1 },
                16 => .{ .index16, 2 },
                else => return error.Unsupported,
            };
        },
        .truecolor => {
            const alpha_bit = descriptor & 0xf != 0;
            h.native, h.expand, h.stored = switch (depth) {
                15 => .{ .bgr8, .bgr555, 2 },
                16 => if (alpha_bit) .{ .bgra8, .bgra5551, 2 } else .{ .bgr8, .bgr555, 2 },
                24 => .{ .bgr8, .none, 3 },
                32 => .{ .bgra8, .none, 4 },
                else => return error.Unsupported,
            };
        },
        .gray => {
            h.native, h.stored = switch (depth) {
                8 => .{ .gray8, 1 },
                16 => .{ .gray_alpha8, 2 },
                else => return error.Unsupported,
            };
        },
    }
    try d.options.limits.checkSize(h.width, h.height);
    try d.options.limits.checkWork(h.workLen());
    return h;
}

/// Skips the image ID and reads the color map into `palette` as native
/// pixels of 4 bytes, or skips it when the image does not use it.
fn skipToPixels(d: *Decoder, palette: []u8) Error!void {
    const h = d.header;
    const r = d.reader;
    r.discardAll(h.id_len) catch |e| return mapRead(e);
    d.pos += h.id_len;
    if (h.map_type == 0) return;
    const entry_bytes = (@as(usize, h.map_bits) + 7) / 8;
    if (h.kind != .mapped) {
        const len = entry_bytes * h.map_len;
        r.discardAll(len) catch |e| return mapRead(e);
        d.pos += len;
        return;
    }
    for (0..h.map_len) |i| {
        const e = r.take(entry_bytes) catch |err| return mapRead(err);
        palette[i * 4 ..][0..4].* = switch (h.map_bits) {
            15, 16 => bgr555(std.mem.readInt(u16, e[0..2], .little)) ++ [1]u8{255},
            24 => .{ e[0], e[1], e[2], 255 },
            32 => e[0..4].*,
            else => unreachable,
        };
    }
    d.pos += entry_bytes * h.map_len;
}

inline fn widen5(c: u16) u8 {
    const v: u8 = @intCast(c & 31);
    return v << 3 | v >> 2;
}

inline fn bgr555(v: u16) [3]u8 {
    return .{ widen5(v), widen5(v >> 5), widen5(v >> 10) };
}

/// The run-length state that carries from one span of pixels to the next.
const Packets = struct {
    /// Pixels of the current packet not yet written.
    left: u8 = 0,
    raw: bool = false,
    /// A run packet's pixel.
    px: [4]u8 = undefined,
};

/// The most pixels decoded at once into a stack buffer for expansion or
/// conversion.
const chunk = 256;

fn pixels(d: *Decoder, dst: PixelBuffer, palette: []const u8) Error!void {
    const h = d.header;
    const w: usize = h.width;
    const top_down = h.descriptor & 0x20 != 0;
    const right_to_left = h.descriptor & 0x10 != 0;
    const nbpp = h.native.bytesPerPixel();
    const direct = dst.format == h.native;
    const conv: Converter = .init(dst.format, h.native);
    const dbpp = dst.format.bytesPerPixel();
    var s: Packets = .{};
    for (0..h.height) |i| {
        const y: u32 = @intCast(if (top_down) i else h.height - 1 - i);
        const row = dst.row(y);
        if (direct and h.expand == .none) {
            try d.stored(&s, row);
            if (right_to_left) reverse(row, nbpp);
            continue;
        }
        // An uncompressed row the reader can hold converts from its buffer.
        const len = w * h.stored;
        if (!h.rle and !right_to_left and len <= d.reader.buffer.len) {
            d.reader.fill(len) catch |e| return mapRead(e);
            const in = d.reader.buffered()[0..len];
            if (h.expand == .none) {
                conv.run(row, in, w);
            } else if (direct) {
                expand(h, row, in, palette);
            } else {
                var x: usize = 0;
                while (x < w) : (x += chunk) {
                    const n: usize = @min(chunk, w - x);
                    var native_buf: [chunk * 4]u8 = undefined;
                    expand(h, native_buf[0 .. n * nbpp], in[x * h.stored ..][0 .. n * h.stored], palette);
                    conv.run(row[x * dbpp ..], &native_buf, n);
                }
            }
            d.reader.toss(len);
            d.pos += len;
            continue;
        }
        var x: usize = 0;
        while (x < w) {
            const n: usize = @min(chunk, w - x);
            var stored_buf: [chunk * 4]u8 = undefined;
            var native_buf: [chunk * 4]u8 = undefined;
            const at = if (right_to_left) w - x - n else x;
            const in = stored_buf[0 .. n * h.stored];
            try d.stored(&s, in);
            var px: []u8 = in;
            if (h.expand != .none) {
                px = if (direct and !right_to_left) row[at * nbpp ..][0 .. n * nbpp] else native_buf[0 .. n * nbpp];
                expand(h, px, in, palette);
            }
            if (right_to_left) reverse(px, nbpp);
            if (direct) {
                if (px.ptr != row.ptr + at * nbpp) @memcpy(row[at * nbpp ..][0 .. n * nbpp], px);
            } else {
                conv.run(row[at * dbpp ..], px, n);
            }
            x += n;
        }
    }
    if (s.left != 0) return error.RunPastEnd;
}

/// Reverses the order of the pixels in `row`.
fn reverse(row: []u8, bpp: usize) void {
    const n = row.len / bpp;
    for (0..n / 2) |i| {
        const a = row[i * bpp ..][0..bpp];
        const b = row[(n - 1 - i) * bpp ..][0..bpp];
        for (a, b) |*p, *q| std.mem.swap(u8, p, q);
    }
}

fn expand(h: Header, out: []u8, in: []const u8, palette: []const u8) void {
    switch (h.expand) {
        .none => unreachable,
        .bgr555 => for (0..in.len / 2) |i| {
            out[i * 3 ..][0..3].* = bgr555(std.mem.readInt(u16, in[i * 2 ..][0..2], .little));
        },
        .bgra5551 => for (0..in.len / 2) |i| {
            const v = std.mem.readInt(u16, in[i * 2 ..][0..2], .little);
            const a: u8 = if (v & 0x8000 != 0) 255 else 0;
            out[i * 4 ..][0..4].* = bgr555(v) ++ [1]u8{a};
        },
        inline .index8, .index16 => |e| {
            const len: u32 = h.map_len;
            const first: u32 = h.map_first;
            const size = comptime if (e == .index8) 1 else 2;
            const n = in.len / size;
            switch (h.native) {
                inline .bgr8, .bgra8 => |f| {
                    const bpp = comptime f.bytesPerPixel();
                    const black = [4]u8{ 0, 0, 0, 255 };
                    for (0..n) |i| {
                        const v: u32 = if (size == 1) in[i] else std.mem.readInt(u16, in[i * 2 ..][0..2], .little);
                        // An index below the first entry wraps to above
                        // the last.
                        const k = v -% first;
                        const entry = if (k < len) palette[k * 4 ..][0..4] else &black;
                        out[i * bpp ..][0..bpp].* = entry[0..bpp].*;
                    }
                },
                else => unreachable,
            }
        },
    }
}

/// Reads `out.len` bytes of stored pixels, decoding run-length packets.
fn stored(d: *Decoder, s: *Packets, out: []u8) Error!void {
    const h = d.header;
    if (!h.rle) {
        d.reader.readSliceAll(out) catch |e| return mapRead(e);
        d.pos += out.len;
        return;
    }
    switch (h.stored) {
        inline 1...4 => |bpp| try d.packets(s, out, bpp),
        else => unreachable,
    }
}

inline fn fillRun(out: []u8, px: [4]u8, comptime bpp: usize) void {
    const p = px[0..bpp].*;
    for (0..out.len / bpp) |j| out[j * bpp ..][0..bpp].* = p;
}

fn packets(d: *Decoder, s: *Packets, out: []u8, comptime bpp: usize) Error!void {
    const r = d.reader;
    const n = out.len / bpp;
    var i: usize = 0;
    // The rest of a packet from the last span.
    if (s.left > 0) {
        const m: usize = @min(s.left, n);
        const part = out[0 .. m * bpp];
        if (s.raw) {
            r.readSliceAll(part) catch |e| return mapRead(e);
            d.pos += part.len;
        } else fillRun(part, s.px, bpp);
        s.left -= @intCast(m);
        i = m;
    }
    while (i < n) {
        // Every packet is at least a count and one pixel, so with that much
        // buffered the loop reads a packet's head without checking for more.
        r.fill(1 + bpp) catch |e| return mapRead(e);
        const buf = r.buffered();
        var p: usize = 0;
        while (i < n and buf.len - p >= 1 + bpp) {
            const head = buf[p];
            const count: usize = (head & 0x7f) + 1;
            const m: usize = @min(count, n - i);
            if (head & 0x80 != 0) {
                var px: [4]u8 = undefined;
                px[0..bpp].* = buf[p + 1 ..][0..bpp].*;
                fillRun(out[i * bpp ..][0 .. m * bpp], px, bpp);
                p += 1 + bpp;
                if (m < count) s.* = .{ .left = @intCast(count - m), .raw = false, .px = px };
            } else if (m * bpp <= buf.len - p - 1) {
                @memcpy(out[i * bpp ..][0 .. m * bpp], buf[p + 1 ..][0 .. m * bpp]);
                p += 1 + m * bpp;
                if (m < count) s.* = .{ .left = @intCast(count - m), .raw = true };
            } else {
                // The packet's pixels run past the buffered bytes: read
                // them through the reader.
                r.toss(p + 1);
                d.pos += p + 1;
                p = 0;
                r.readSliceAll(out[i * bpp ..][0 .. m * bpp]) catch |e| return mapRead(e);
                d.pos += m * bpp;
                i += m;
                if (m < count) s.* = .{ .left = @intCast(count - m), .raw = true };
                break;
            }
            i += m;
        }
        r.toss(p);
        d.pos += p;
    }
}

/// The footer is the last 26 bytes; the extension area's fields this
/// decoder reports are its last 25 of 495.
const footer_len = 26;
const extension_len = 495;
const fields_at = 470;
const fields_len = extension_len - fields_at;
const signature = "TRUEVISION-XFILE.\x00";

/// Reads to the end of the input, keeping what the footer and an extension
/// area in either readable place need: the first bytes after the image data
/// and the last bytes of the input.
fn readTrailer(d: *Decoder) Error!Trailer {
    const r = d.reader;
    const start = d.pos;
    // The extension area's size and fields, if it starts at `start`.
    var head: [2 + fields_len]u8 = undefined;
    // The last bytes of the input: an extension area's fields, then the
    // footer.
    var tail: [fields_len + footer_len]u8 = undefined;
    var tail_len: usize = 0;
    while (true) {
        if (r.bufferedLen() == 0) {
            r.fillMore() catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            continue;
        }
        const buf = r.buffered();
        const at = d.pos - start;
        copyOverlap(head[0..2], 0, buf, at);
        copyOverlap(head[2..], fields_at, buf, at);
        if (buf.len >= tail.len) {
            tail = buf[buf.len - tail.len ..][0..tail.len].*;
            tail_len = tail.len;
        } else {
            const keep = @min(tail_len, tail.len - buf.len);
            @memmove(tail[0..keep], tail[tail_len - keep .. tail_len]);
            @memcpy(tail[keep..][0..buf.len], buf);
            tail_len = keep + buf.len;
        }
        d.pos += buf.len;
        r.tossBuffered();
    }
    const end = d.pos;
    var t: Trailer = .{};
    if (end - start < footer_len) return t;
    const footer = tail[tail_len - footer_len ..][0..footer_len];
    if (!std.mem.eql(u8, footer[8..], signature)) return t;
    t.footer = true;
    t.extension_offset = std.mem.readInt(u32, footer[0..4], .little);
    t.developer_offset = std.mem.readInt(u32, footer[4..8], .little);
    const ext: u64 = t.extension_offset;
    if (ext == 0 or ext < start) return t;
    if (ext == start) {
        // Right after the image data, where its size can be checked.
        const fits = end - start >= extension_len + footer_len;
        if (fits and std.mem.readInt(u16, head[0..2], .little) == extension_len) {
            t.extension = parseExtension(head[2..]);
        }
    } else if (ext + extension_len + footer_len == end) {
        t.extension = parseExtension(tail[0..fields_len]);
    }
    return t;
}

/// Copies the part of `src`, which starts at offset `src_at`, that falls in
/// `dst`, which starts at offset `dst_at`.
fn copyOverlap(dst: []u8, dst_at: u64, src: []const u8, src_at: u64) void {
    const lo = @max(dst_at, src_at);
    const hi = @min(dst_at + dst.len, src_at + src.len);
    if (lo >= hi) return;
    const n: usize = @intCast(hi - lo);
    @memcpy(dst[@intCast(lo - dst_at)..][0..n], src[@intCast(lo - src_at)..][0..n]);
}

/// The fields from the key color to the attributes type.
fn parseExtension(f: *const [fields_len]u8) Extension {
    var e: Extension = .{};
    // A:R:G:B as a little-endian long.
    if (!std.mem.allEqual(u8, f[0..4], 0)) e.background = .{ f[2], f[1], f[0], f[3] };
    const aspect_num = std.mem.readInt(u16, f[4..6], .little);
    const aspect_den = std.mem.readInt(u16, f[6..8], .little);
    // The ratio is a pixel's width over its height, so the horizontal
    // density is the height.
    if (aspect_num != 0 and aspect_den != 0) e.metadata.density = .{ .x = aspect_den, .y = aspect_num, .unit = .none };
    const gamma_num: u64 = std.mem.readInt(u16, f[8..10], .little);
    const gamma_den: u64 = std.mem.readInt(u16, f[10..12], .little);
    // The display gamma the image is corrected for; PNG stores its inverse.
    if (gamma_num != 0 and gamma_den != 0) {
        e.metadata.gamma = std.math.cast(u32, (100_000 * gamma_den + gamma_num / 2) / gamma_num);
    }
    e.alpha = std.enums.fromInt(Extension.Alpha, f[24]);
    return e;
}

/// An 18-byte header with the color-map fields zero unless given.
fn testHeader(comptime f: struct {
    id_len: u8 = 0,
    map_type: u8 = 0,
    image_type: u8,
    map_first: u16 = 0,
    map_len: u16 = 0,
    map_bits: u8 = 0,
    width: u16,
    height: u16,
    depth: u8,
    descriptor: u8 = 0x20,
}) [18]u8 {
    var h: [18]u8 = @splat(0);
    h[0] = f.id_len;
    h[1] = f.map_type;
    h[2] = f.image_type;
    std.mem.writeInt(u16, h[3..5], f.map_first, .little);
    std.mem.writeInt(u16, h[5..7], f.map_len, .little);
    h[7] = f.map_bits;
    std.mem.writeInt(u16, h[12..14], f.width, .little);
    std.mem.writeInt(u16, h[14..16], f.height, .little);
    h[16] = f.depth;
    h[17] = f.descriptor;
    return h;
}

/// Decodes `file` as `format` into `out`, reading the trailer too.
/// `file` is bytes, or an array of them.
fn testDecode(file: anytype, format: PixelFormat, out: []u8) !struct { decode.Config, Trailer } {
    const bytes: []const u8 = if (@typeInfo(@TypeOf(file)) == .pointer) file else &file;
    var r: Io.Reader = .fixed(bytes);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    var work: [1024]u8 = undefined;
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    const frame = (try d.decodeFrame(dst, &work)).?;
    try testing.expectEqual(config.width, frame.width);
    try testing.expectEqual(null, try d.decodeFrame(dst, &work));
    try testing.expectEqual(0, r.bufferedLen());
    return .{ config, d.trailer().? };
}

test "origins" {
    // Six 24-bit pixels, 3 by 2, stored in file order; the decoded rows are
    // the same pixels placed by each origin.
    const px = "\x01\x01\x01\x02\x02\x02\x03\x03\x03\x04\x04\x04\x05\x05\x05\x06\x06\x06";
    const cases = [_]struct { u8, []const u8 }{
        .{ 0x20, "\x01\x02\x03\x04\x05\x06" }, // top-left
        .{ 0x00, "\x04\x05\x06\x01\x02\x03" }, // bottom-left
        .{ 0x30, "\x03\x02\x01\x06\x05\x04" }, // top-right
        .{ 0x10, "\x06\x05\x04\x03\x02\x01" }, // bottom-right
    };
    inline for (cases) |c| {
        const file = testHeader(.{ .image_type = 2, .width = 3, .height = 2, .depth = 24, .descriptor = c[0] }) ++ px;
        var out: [18]u8 = undefined;
        const config, _ = try testDecode(file, .bgr8, &out);
        try testing.expectEqual(PixelFormat.bgr8, config.native);
        try testing.expect(config.is_opaque);
        for (c[1], 0..) |v, i| try testing.expectEqualSlices(u8, &.{ v, v, v }, out[i * 3 ..][0..3]);
        // Through a converter, and through the run-length decoder: one raw
        // packet of all six pixels, crossing the scan lines.
        var rgba: [24]u8 = undefined;
        _ = try testDecode(file, .rgba8, &rgba);
        for (c[1], 0..) |v, i| try testing.expectEqualSlices(u8, &.{ v, v, v, 255 }, rgba[i * 4 ..][0..4]);
        const rle = testHeader(.{
            .image_type = 10,
            .width = 3,
            .height = 2,
            .depth = 24,
            .descriptor = c[0],
        }) ++ "\x05" ++ px;
        _ = try testDecode(rle, .bgr8, &out);
        for (c[1], 0..) |v, i| try testing.expectEqualSlices(u8, &.{ v, v, v }, out[i * 3 ..][0..3]);
    }
}

test "15- and 16-bit pixels" {
    // Red 31, green 3 (24 by bit replication; 25 if rounded, 24 if
    // truncated), blue 30 (247; 246 if truncated), with the top bit set and
    // clear.
    const a: u16 = 0x8000 | 31 << 10 | 3 << 5 | 30;
    const b: u16 = 1 << 10 | 2 << 5 | 1;
    var px: [4]u8 = undefined;
    std.mem.writeInt(u16, px[0..2], a, .little);
    std.mem.writeInt(u16, px[2..4], b, .little);
    var out: [8]u8 = undefined;
    const opaque_ = testHeader(.{ .image_type = 2, .width = 2, .height = 1, .depth = 16 }) ++ px;
    const config, _ = try testDecode(opaque_, .bgra8, &out);
    try testing.expectEqual(PixelFormat.bgr8, config.native);
    try testing.expectEqualSlices(u8, &.{ 247, 24, 255, 255, 8, 16, 8, 255 }, &out);
    const fifteen = testHeader(.{ .image_type = 2, .width = 2, .height = 1, .depth = 15, .descriptor = 0x21 }) ++ px;
    _ = try testDecode(fifteen, .bgra8, &out);
    try testing.expectEqualSlices(u8, &.{ 247, 24, 255, 255, 8, 16, 8, 255 }, &out);
    // One attribute bit: the top bit is alpha.
    const alpha = testHeader(.{
        .image_type = 10,
        .width = 2,
        .height = 1,
        .depth = 16,
        .descriptor = 0x21,
    }) ++ "\x01" ++ px;
    const config2, _ = try testDecode(alpha, .bgra8, &out);
    try testing.expectEqual(PixelFormat.bgra8, config2.native);
    try testing.expect(!config2.is_opaque);
    try testing.expectEqualSlices(u8, &.{ 247, 24, 255, 255, 8, 16, 8, 0 }, &out);
}

test "gray, and 32 bits always carry alpha" {
    var out: [8]u8 = undefined;
    const gray = testHeader(.{ .image_type = 11, .width = 4, .height = 1, .depth = 8 }) ++ "\x82\x07\x00\x09";
    const config, _ = try testDecode(gray, .gray8, out[0..4]);
    try testing.expectEqual(PixelFormat.gray8, config.native);
    try testing.expectEqualSlices(u8, &.{ 7, 7, 7, 9 }, out[0..4]);
    const ga = testHeader(.{ .image_type = 3, .width = 2, .height = 1, .depth = 16 }) ++ "\x10\x80\x20\xff";
    const config2, _ = try testDecode(ga, .gray_alpha8, out[0..4]);
    try testing.expectEqual(PixelFormat.gray_alpha8, config2.native);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x80, 0x20, 0xff }, out[0..4]);
    // No attribute bits named, but the fourth byte is alpha all the same.
    const bgra = testHeader(.{
        .image_type = 2,
        .width = 2,
        .height = 1,
        .depth = 32,
    }) ++ "\x01\x02\x03\x40\x04\x05\x06\x00";
    const config3, _ = try testDecode(bgra, .rgba8, &out);
    try testing.expectEqual(PixelFormat.bgra8, config3.native);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 0x40, 6, 5, 4, 0 }, &out);
}

test "color maps" {
    // Entries 2 and 3 of a map, 24-bit, read through 16-bit indices.
    const map = "\x01\x02\x03\x04\x05\x06";
    const head = testHeader(.{
        .map_type = 1,
        .image_type = 1,
        .map_first = 2,
        .map_len = 2,
        .map_bits = 24,
        .width = 3,
        .height = 1,
        .depth = 16,
    });
    var out: [12]u8 = undefined;
    const config, _ = try testDecode((head ++ map ++ "\x03\x00\x02\x00\x03\x00"), .bgr8, out[0..9]);
    try testing.expectEqual(PixelFormat.bgr8, config.native);
    try testing.expectEqual(8, config.work_len);
    try testing.expectEqualSlices(u8, "\x04\x05\x06\x01\x02\x03\x04\x05\x06", out[0..9]);
    // Indices below the first entry and past the last are black.
    _ = try testDecode((head ++ map ++ "\x01\x00\x04\x00\x03\x00"), .bgr8, out[0..9]);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x00\x00\x00\x04\x05\x06", out[0..9]);
    // 32-bit entries keep their alpha, and an index past them is opaque
    // black; 16-bit entries are opaque. An image ID comes first, and a
    // run repeats an index.
    const map32 = testHeader(.{
        .id_len = 2,
        .map_type = 1,
        .image_type = 9,
        .map_len = 2,
        .map_bits = 32,
        .width = 3,
        .height = 1,
        .depth = 8,
    });
    const file32 = map32 ++ "id" ++ "\x01\x02\x03\x40\x04\x05\x06\x80" ++ "\x81\x01\x00\x02";
    const config2, _ = try testDecode(file32, .bgra8, &out);
    try testing.expectEqual(PixelFormat.bgra8, config2.native);
    try testing.expect(!config2.is_opaque);
    try testing.expectEqualSlices(u8, "\x04\x05\x06\x80\x04\x05\x06\x80\x00\x00\x00\xff", &out);
    const map16 = testHeader(.{
        .map_type = 1,
        .image_type = 1,
        .map_len = 1,
        .map_bits = 16,
        .width = 1,
        .height = 1,
        .depth = 8,
        .descriptor = 0x21,
    });
    _ = try testDecode((map16 ++ "\x1f\x00" ++ "\x00"), .bgra8, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, out[0..4]);
    // A true-color image's map is skipped.
    const skip = testHeader(.{
        .map_type = 1,
        .image_type = 2,
        .map_len = 3,
        .map_bits = 15,
        .width = 1,
        .height = 1,
        .depth = 24,
    });
    _ = try testDecode((skip ++ "\xff" ** 6 ++ "\x07\x08\x09"), .bgr8, out[0..3]);
    try testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, out[0..3]);
    // Work memory one entry short.
    var r: Io.Reader = .fixed((head ++ map ++ "\x03\x00\x02\x00\x03\x00"));
    var d: Decoder = .init(&r, .{});
    var work: [7]u8 = undefined;
    try testing.expectError(error.WorkTooSmall, d.decodeFrame(try PixelBuffer.init(&out, .bgr8, 3, 1), &work));
}

test "malformed streams" {
    var out: [16]u8 = undefined;
    const head = testHeader(.{ .image_type = 11, .width = 2, .height = 2, .depth = 8, .descriptor = 0 });
    // Bad headers and unsupported ones.
    const bad = [_]struct { anyerror, [18]u8 }{
        .{ error.BadHeader, testHeader(.{ .map_type = 2, .image_type = 2, .width = 1, .height = 1, .depth = 24 }) },
        .{ error.BadHeader, testHeader(.{ .image_type = 1, .width = 1, .height = 1, .depth = 8 }) },
        .{ error.BadHeader, testHeader(.{ .image_type = 4, .width = 1, .height = 1, .depth = 8 }) },
        .{ error.BadHeader, testHeader(.{ .image_type = 8, .width = 1, .height = 1, .depth = 8 }) },
        .{ error.Unsupported, testHeader(.{ .image_type = 32, .width = 1, .height = 1, .depth = 8 }) },
        .{ error.Unsupported, testHeader(.{ .image_type = 2, .width = 1, .height = 1, .depth = 8 }) },
        .{ error.Unsupported, testHeader(.{ .image_type = 3, .width = 1, .height = 1, .depth = 24 }) },
        .{ error.Unsupported, testHeader(.{
            .map_type = 1,
            .image_type = 1,
            .map_len = 1,
            .map_bits = 8,
            .width = 1,
            .height = 1,
            .depth = 8,
        }) },
    };
    for (bad) |c| try testing.expectError(c[0], testDecode((c[1] ++ "\x00" ** 8), .gray8, &out));
    // Runs that cross scan lines are fine; past the last pixel they are not.
    _ = try testDecode((head ++ "\x83\x05"), .gray8, out[0..4]);
    try testing.expectError(error.RunPastEnd, testDecode((head ++ "\x84\x05"), .gray8, out[0..4]));
    try testing.expectError(error.RunPastEnd, testDecode((head ++ "\x04\x01\x02\x03\x04\x05"), .gray8, out[0..4]));
    // Every truncation.
    const good = head ++ "\x01\x01\x02\x81\x03";
    _ = try testDecode(good, .gray8, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 3, 3, 1, 2 }, out[0..4]);
    for (0..good.len) |n| try testing.expectError(error.Truncated, testDecode(good[0..n], .gray8, out[0..4]));
    // Limits apply before anything past the header.
    var r: Io.Reader = .fixed(good);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_pixels = 3 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
    try testing.expectError(error.ImageTooLarge, d.decodeFrame(try PixelBuffer.init(&out, .gray8, 2, 2), &.{}));
    try testing.expectEqual(18, r.seek);
    const mapped = testHeader(.{
        .map_type = 1,
        .image_type = 1,
        .map_len = 300,
        .map_bits = 24,
        .width = 1,
        .height = 1,
        .depth = 16,
    });
    r = .fixed(&mapped);
    d = .init(&r, .{ .limits = .{ .max_work = 1199 } });
    try testing.expectError(error.WorkTooLarge, d.decodeConfig());
    // The pixel buffer must be the image's size.
    r = .fixed(good);
    d = .init(&r, .{});
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .gray8, 1, 2), &.{}));
    // Type 0 has no frames.
    r = .fixed((testHeader(.{ .image_type = 0, .width = 4, .height = 4, .depth = 0 }) ++ "junk"));
    d = .init(&r, .{});
    try testing.expectEqual(0, (try d.decodeConfig()).frame_count);
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .gray8, 1, 1), &.{}));
    try testing.expectEqual(null, try d.decodeFrame(try PixelBuffer.init(&out, .gray8, 4, 4), &.{}));
    try testing.expectEqual(false, d.trailer().?.footer);
}

/// A 495-byte extension area with the given key color (B, G, R, A in file
/// order), aspect ratio, gamma, and attributes type.
fn testExtension(key: [4]u8, aspect: [2]u16, gamma: [2]u16, attributes: u8) [extension_len]u8 {
    var e: [extension_len]u8 = @splat(0);
    std.mem.writeInt(u16, e[0..2], extension_len, .little);
    e[fields_at..][0..4].* = key;
    std.mem.writeInt(u16, e[474..476], aspect[0], .little);
    std.mem.writeInt(u16, e[476..478], aspect[1], .little);
    std.mem.writeInt(u16, e[478..480], gamma[0], .little);
    std.mem.writeInt(u16, e[480..482], gamma[1], .little);
    e[494] = attributes;
    return e;
}

fn testFooter(extension: u32) [footer_len]u8 {
    var f: [footer_len]u8 = undefined;
    std.mem.writeInt(u32, f[0..4], extension, .little);
    std.mem.writeInt(u32, f[4..8], 0, .little);
    f[8..].* = signature.*;
    return f;
}

test "the footer and extension area" {
    const image = testHeader(.{ .image_type = 3, .width = 1, .height = 1, .depth = 8 }) ++ "\x42";
    const ext = testExtension(.{ 3, 2, 1, 0x80 }, .{ 2, 1 }, .{ 22, 10 }, 4);
    var out: [1]u8 = undefined;
    // None: the original format.
    _, var t = try testDecode(image, .gray8, &out);
    try testing.expect(!t.footer);
    // Right after the image data, then a postage stamp.
    const after = image ++ ext ++ "\x01\x01\x07" ++ testFooter(image.len);
    _, t = try testDecode(after, .gray8, &out);
    try testing.expect(t.footer);
    const e = t.extension.?;
    try testing.expectEqual([4]u8{ 1, 2, 3, 0x80 }, e.background.?);
    // Pixels twice as wide as tall: half the density across.
    try testing.expectEqual(decode.Density{ .x = 1, .y = 2, .unit = .none }, e.metadata.density.?);
    try testing.expectEqual(45455, e.metadata.gamma.?);
    try testing.expectEqual(Extension.Alpha.premultiplied, e.alpha.?);
    // Through image.Decoder, the extension area reaches the final config.
    var ar: Io.Reader = .fixed(after);
    var ad: ImageDecoder = try .init(.tga, &ar, .{});
    const config = try ad.decodeConfig();
    const dst = try PixelBuffer.init(&out, .gray8, 1, 1);
    while (try ad.decodeFrame(dst, &.{})) |_| {}
    const final = ad.finalConfig().?;
    try testing.expectEqual(e.background, final.background);
    try testing.expectEqual(e.metadata.gamma, final.metadata.gamma);
    try testing.expectEqual(e.metadata.density, final.metadata.density);
    try testing.expectEqual(null, config.background);
    // Right before the footer, after a scan-line table; and through a
    // reader that hands over 3 bytes at a time.
    const before = image ++ "\x00" ** 4 ++ ext ++ testFooter(image.len + 4);
    _, t = try testDecode(before, .gray8, &out);
    try testing.expectEqual(e, t.extension.?);
    var buffer: [decode.min_buffer_len]u8 = undefined;
    var trickle: Trickle = .{
        .data = before,
        .reader = .{ .vtable = &.{ .stream = Trickle.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
    };
    var d: Decoder = .init(&trickle.reader, .{});
    _ = try d.decodeFrame(try PixelBuffer.init(&out, .gray8, 1, 1), &.{});
    try testing.expectEqual(null, try d.decodeFrame(try PixelBuffer.init(&out, .gray8, 1, 1), &.{}));
    try testing.expectEqual(e, d.trailer().?.extension.?);
    // Elsewhere: the offset is reported, the area is not read.
    const elsewhere = image ++ "\x00" ** 4 ++ ext ++ "\x00" ++ testFooter(image.len + 4);
    _, t = try testDecode(elsewhere, .gray8, &out);
    try testing.expectEqual(image.len + 4, t.extension_offset);
    try testing.expectEqual(null, t.extension);
    // Unset fields.
    const unset = image ++ testExtension(@splat(0), .{ 1, 0 }, .{ 0, 1 }, 9) ++ testFooter(image.len);
    _, t = try testDecode(unset, .gray8, &out);
    try testing.expectEqual(Extension{}, t.extension.?);
}

const ImageDecoder = @import("../Decoder.zig");

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
