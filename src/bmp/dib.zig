//! The device-independent bitmap (DIB) inside BMP files and ICO and CUR
//! entries: an info header, a color table, and rows of pixels. The BMP and
//! ICO decoders share this reader.
//!
//! Format: Microsoft's BITMAPCOREHEADER, BITMAPINFOHEADER, BITMAPV4HEADER,
//! and BITMAPV5HEADER, Adobe's 52- and 56-byte BITMAPV2INFOHEADER and
//! BITMAPV3INFOHEADER, and IBM's OS/2 2.x BITMAPINFOHEADER2 (16 or 64
//! bytes). Where the documents leave a case open, this reader decides it as
//! Wuffs does, so the bar library is also a strict oracle
//! (test/oracle/bmp.zig lists where the references differ):
//!
//! - Masks narrower than 8 bits widen by repeating their bits; wider ones
//!   keep their top 8. Masks must be contiguous and nonzero for red, green,
//!   and blue.
//! - 32-bit `BI_RGB` pixels are opaque: their high byte is unused. Alpha
//!   comes only from an alpha mask with `BI_BITFIELDS` in a 56-byte or
//!   larger header, or with `BI_ALPHABITFIELDS`.
//! - A color table index past the table's end is opaque black.
//! - RLE pixels the stream skips (with a delta or an early end of line or
//!   bitmap) are transparent black, so RLE images are BGRA. A run past the
//!   end of a row is cut off, as are RLE4 literals, and runs and RLE4
//!   literals after the last row are dropped; an RLE8 literal past the end
//!   of a row or after the last row, a delta past the right or top edge,
//!   and an end of line after the last row are errors. The stream must end
//!   with an end-of-bitmap code.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

pub const Error = decode.Error || error{
    /// RLE data that writes past the image or ends without an
    /// end-of-bitmap code.
    BadRle,
};

pub const Compression = enum { rgb, rle8, rle4, bitfields, jpeg, png };

/// A parsed info header, with the masks that follow a 40-byte one.
pub const Header = struct {
    width: u32,
    height: u32,
    /// Rows are stored top first (a negative height) rather than bottom
    /// first.
    top_down: bool = false,
    bits: u16,
    compression: Compression,
    /// Red, green, blue, and alpha masks of 16-, 24-, and 32-bit pixels.
    /// Alpha is 0 when the pixels have none.
    masks: [4]u32 = @splat(0),
    /// Bytes per color table entry: 3 after an OS/2 1.x core header, else 4.
    entry_len: u8 = 4,
    /// The bytes the info header and any masks after it take.
    len: u32,
    colors_used: u32 = 0,
    /// `biSizeImage`: the pixel data's length, which may be 0.
    image_size: u32 = 0,
    density: ?decode.Density = null,
    /// `bV4CSType`: 'sRGB', 'Win ', 'MBED', ... or 0.
    color_space: u32 = 0,
    /// An embedded ICC profile's offset from the info header's first byte
    /// and its length, or zeros.
    profile: [2]u32 = @splat(0),

    pub const srgb = 0x73524742;
    pub const windows = 0x57696e20;
    pub const embedded = 0x4d424544;

    /// Whether pixels can be transparent: an alpha mask, or RLE skips.
    pub fn hasAlpha(h: Header) bool {
        return h.masks[3] != 0 or h.compression == .rle8 or h.compression == .rle4;
    }

    /// The format that holds the pixels without loss and is cheapest to
    /// write: BGR, or BGRA when they can be transparent. Masks wider than 8
    /// bits are narrowed to 8.
    pub fn native(h: Header) PixelFormat {
        return if (h.hasAlpha()) .bgra8 else .bgr8;
    }

    /// Bytes per row in the file, padded to four, or null on overflow.
    pub fn rowLen(h: Header) ?usize {
        const bits = std.math.mul(u64, h.width, h.bits) catch return null;
        return std.math.cast(usize, (bits + 31) / 32 * 4);
    }

    /// The color table's entries, for a file that does not say where the
    /// pixels start: `colors_used`, or every index the bit depth allows.
    pub fn tableEntries(h: Header) u32 {
        if (h.colors_used != 0) return h.colors_used;
        return if (h.bits <= 8) @as(u32, 1) << @intCast(h.bits) else 0;
    }
};

/// The reader and how far into the input it is, so that a file's offsets
/// can be reached by skipping forward.
pub const Input = struct {
    r: *Io.Reader,
    /// Bytes consumed since the decoder started.
    pos: u64 = 0,

    pub fn takeArray(in: *Input, comptime n: usize) Error!*[n]u8 {
        const b = in.r.takeArray(n) catch |e| return mapRead(e);
        in.pos += n;
        return b;
    }

    /// The next `n` bytes, which must fit the reader's buffer (`maxTake`).
    pub fn take(in: *Input, n: usize) Error![]u8 {
        const b = in.r.take(n) catch |e| return mapRead(e);
        in.pos += n;
        return b;
    }

    pub fn read(in: *Input, dst: []u8) Error!void {
        in.r.readSliceAll(dst) catch |e| return mapRead(e);
        in.pos += dst.len;
    }

    pub fn skip(in: *Input, n: u64) Error!void {
        in.r.discardAll64(n) catch |e| return mapRead(e);
        in.pos += n;
    }

    /// Skips to offset `to`, which must not be behind.
    pub fn skipTo(in: *Input, to: u64) Error!void {
        std.debug.assert(to >= in.pos);
        return in.skip(to - in.pos);
    }

    /// The most bytes `take` can return at once, a multiple of `unit`.
    pub fn maxTake(in: *const Input, unit: usize) usize {
        return in.r.buffer.len / unit * unit;
    }
};

pub fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Where a DIB is: a BMP file, or an ICO or CUR entry.
pub const Container = enum { bmp, ico };

/// Reads an info header and any masks after it. `room` is how many bytes
/// the file has between the info header and the pixels: when a 40-byte
/// header with `BI_BITFIELDS` leaves room for a fourth mask after the
/// three it needs, the fourth is the alpha mask. An ICO or CUR entry's
/// header is a BITMAPINFOHEADER for uncompressed 1-, 4-, 8-, 24-, or
/// 32-bit pixels, with a positive height that counts the AND mask's rows
/// too; its planes field is not checked.
pub fn readHeader(in: *Input, container: Container, room: u64) Error!Header {
    const size = std.mem.readInt(u32, try in.takeArray(4), .little);
    switch (size) {
        12, 16, 52, 56, 64, 108, 124 => if (container == .ico) return error.BadHeader,
        40 => {},
        else => return error.BadHeader,
    }
    var b: [124]u8 = @splat(0);
    try in.read(b[4..size]);
    const os2 = size == 12 or size == 16 or size == 64;
    var h: Header = undefined;
    if (size == 12) {
        h = .{
            .width = le16(&b, 4),
            .height = le16(&b, 6),
            .bits = le16(&b, 10),
            .compression = .rgb,
            .entry_len = 3,
            .len = size,
        };
        if (le16(&b, 8) != 1) return error.BadHeader;
    } else {
        const width: i32 = @bitCast(le32(&b, 4));
        // OS/2 2.x documents an unsigned height. Wuffs reads it so in the
        // 16-byte header, and in the 64-byte one as Windows does, negative
        // for top-down rows.
        const raw = le32(&b, 8);
        const height: i64 = if (size == 16) raw else @as(i32, @bitCast(raw));
        if (width < 0 or height == std.math.minInt(i32)) return error.BadHeader;
        if (container == .bmp and le16(&b, 12) != 1) return error.BadHeader;
        if (container == .ico and (width == 0 or height < 2)) return error.BadHeader;
        h = .{
            .width = @intCast(width),
            .height = @intCast(@abs(height)),
            .top_down = height < 0,
            .bits = le16(&b, 14),
            .compression = .rgb,
            .len = size,
            .colors_used = le32(&b, 32),
            .image_size = le32(&b, 20),
        };
        const x: i32 = @bitCast(le32(&b, 24));
        const y: i32 = @bitCast(le32(&b, 28));
        if (x > 0 and y > 0) h.density = .{ .x = @intCast(x), .y = @intCast(y), .unit = .per_meter };
    }
    const compression = le32(&b, 16);
    if (os2) {
        switch (h.bits) {
            1, 4, 8, 24 => {},
            else => return error.Unsupported,
        }
        h.compression = switch (compression) {
            0 => .rgb,
            1 => .rle8,
            2 => .rle4,
            // Huffman 1D and RLE24.
            else => return error.Unsupported,
        };
    } else {
        h.compression = switch (compression) {
            0 => .rgb,
            1 => .rle8,
            2 => .rle4,
            3, 6 => .bitfields,
            4 => .jpeg,
            5 => .png,
            else => return error.Unsupported,
        };
    }
    switch (h.compression) {
        .rgb => switch (h.bits) {
            1, 2, 4, 8, 24 => {},
            16 => h.masks = .{ 0x7c00, 0x3e0, 0x1f, 0 },
            32 => h.masks = .{ 0xff0000, 0xff00, 0xff, 0 },
            64 => return error.Unsupported,
            else => return error.BadHeader,
        },
        .rle8 => if (h.bits != 8) return error.BadHeader,
        .rle4 => if (h.bits != 4) return error.BadHeader,
        .bitfields => {
            switch (h.bits) {
                16, 24, 32 => {},
                else => return error.BadHeader,
            }
            // Masks a 40- or 52-byte header lacks follow it. Only
            // BI_ALPHABITFIELDS, a 56-byte or larger header, or a 40-byte
            // one with room for it has alpha.
            const alpha = compression == 6 or size >= 56 or (size == 40 and room >= 16);
            const want: u32 = if (alpha) 16 else 12;
            if (size < 40 + want) {
                try in.read(b[size .. 40 + want]);
                h.len = 40 + want;
            }
            for (&h.masks, 0..) |*m, i| m.* = le32(&b, 40 + 4 * i);
            if (!alpha) h.masks[3] = 0;
            for (h.masks, 0..) |m, i| {
                if (m == 0 and i < 3) return error.BadHeader;
                if (m != 0 and @popCount(m) != 32 - @clz(m) - @ctz(m)) return error.BadHeader;
            }
            // 24-bit bitfields are BGR bytes, without alpha.
            if (h.bits == 24) {
                if (h.masks[0] != 0xff0000 or h.masks[1] != 0xff00 or h.masks[2] != 0xff) return error.BadHeader;
                h.masks[3] = 0;
            }
        },
        .jpeg, .png => {},
    }
    if (container == .ico) {
        if (h.compression != .rgb) return error.Unsupported;
        switch (h.bits) {
            1, 4, 8, 24, 32 => {},
            else => return error.Unsupported,
        }
        h.height /= 2;
        h.density = null;
        // An entry's 32-bit pixels have alpha in their fourth byte.
        if (h.bits == 32) h.masks[3] = 0xff000000;
    }
    if (size >= 108) h.color_space = le32(&b, 56);
    if (size >= 124 and h.color_space == Header.embedded) h.profile = .{ le32(&b, 112), le32(&b, 116) };
    return h;
}

/// Clears the pixels an ICO or CUR entry's AND mask marks, which follows
/// `h`'s pixels: they become transparent, keeping their color where `dst`
/// has straight alpha.
pub fn applyMask(in: *Input, h: Header, dst: PixelBuffer) Error!void {
    const f = dst.format;
    const bpp = f.bytesPerPixel();
    const sample = f.bytesPerSample();
    const alpha = if (f.channels().a) |a| a * sample else 0;
    const row_len = (@as(usize, h.width) + 31) / 32 * 4;
    for (0..h.height) |y| {
        const out = dst.row(rowIndex(h, y));
        var x: usize = 0;
        var left = row_len;
        while (left > 0) {
            const src = try in.take(@min(left, in.maxTake(1)));
            left -= src.len;
            if (!f.hasAlpha()) continue;
            for (src) |byte| {
                if (byte == 0 or x >= h.width) {
                    x += 8;
                    continue;
                }
                for (0..8) |k| {
                    if (x + k < h.width and byte & (@as(u8, 0x80) >> @intCast(k)) != 0) {
                        const px = out[(x + k) * bpp ..][0..bpp];
                        if (f.isPremultiplied()) @memset(px, 0) else @memset(px[alpha..][0..sample], 0);
                    }
                }
                x += 8;
            }
        }
    }
}

/// The color table, BGRA with opaque alpha, every entry past the file's
/// opaque black.
pub const Palette = [256][4]u8;

/// Reads `entries` color table entries of `h.entry_len` bytes, keeping the
/// first 256.
pub fn readPalette(in: *Input, h: Header, entries: u32, palette: *Palette) Error!void {
    const kept = @min(entries, 256);
    var i: usize = 0;
    while (i < kept) {
        const m = @min(kept - i, in.maxTake(h.entry_len) / h.entry_len);
        const src = try in.take(m * h.entry_len);
        if (h.entry_len == 4) {
            opaque4(std.mem.sliceAsBytes(palette[i..][0..m]), src);
        } else {
            for (palette[i..][0..m], 0..) |*c, k| c.* = .{ src[3 * k], src[3 * k + 1], src[3 * k + 2], 255 };
        }
        i += m;
    }
    @memset(palette[kept..], .{ 0, 0, 0, 255 });
    try in.skip(@as(u64, entries - kept) * h.entry_len);
}

/// Decodes `h`'s pixels, which start at the reader, into `dst`, which is
/// `h.width` by `h.height` and has passed `check`.
pub fn decodePixels(in: *Input, h: Header, palette: *const Palette, dst: PixelBuffer) Error!void {
    // An empty image has no pixel data to read, RLE's end code included.
    if (h.width == 0 or h.height == 0) return;
    switch (dst.format.bytesPerPixel()) {
        inline 1, 2, 3, 4, 6, 8, 12, 16 => |n| return pixelsAs(n, in, h, palette, dst),
        else => unreachable,
    }
}

/// The first `2^bits` palette entries, every index the pixels can hold,
/// converted to `format`, `n` bytes an entry.
fn lookupTable(comptime n: usize, palette: *const Palette, format: PixelFormat, bits: u16) [256][n]u8 {
    var lut: [256][n]u8 = undefined;
    const count = @as(usize, 1) << @intCast(bits);
    Converter.init(format, .bgra8).run(std.mem.asBytes(&lut), std.mem.asBytes(palette), count);
    return lut;
}

fn pixelsAs(comptime n: usize, in: *Input, h: Header, palette: *const Palette, dst: PixelBuffer) Error!void {
    switch (h.compression) {
        .rle8, .rle4 => {
            const lut = lookupTable(n, palette, dst.format, h.bits);
            return rle(n, in, h, &lut, dst);
        },
        .jpeg, .png => return error.Unsupported,
        .rgb, .bitfields => {},
    }
    const row_len = h.rowLen() orelse return error.ImageTooLarge;
    const data_len = (@as(usize, h.width) * h.bits + 7) / 8;
    const pad = row_len - data_len;
    switch (h.bits) {
        inline 1, 2, 4, 8 => |bits| {
            const lut = lookupTable(n, palette, dst.format, bits);
            for (0..h.height) |y| {
                const out = dst.row(rowIndex(h, y));
                var x: usize = 0;
                var left = data_len;
                while (left > 0) {
                    const src = try in.take(@min(left, in.maxTake(1)));
                    left -= src.len;
                    x = expand(bits, n, out, x, src, &lut);
                }
                try in.skip(pad);
            }
        },
        24 => try rows(in, h, dst, .bgr8, pad),
        else => {
            const standard = h.bits == 32 and h.masks[0] == 0xff0000 and h.masks[1] == 0xff00 and h.masks[2] == 0xff;
            if (standard and h.masks[3] == 0xff000000) return rows(in, h, dst, .bgra8, pad);
            if (standard and h.masks[3] == 0) return opaqueRows(in, h, dst, pad);
            return fields(in, h, dst, pad);
        },
    }
}

/// The buffer row that file row `y` goes to.
inline fn rowIndex(h: Header, y: usize) u32 {
    return @intCast(if (h.top_down) y else h.height - 1 - y);
}

/// Writes the pixels of the `bits`-bit indices in `src` from column `x`,
/// stopping at the row's end, and returns the next column.
inline fn expand(
    comptime bits: u4,
    comptime n: usize,
    out: []u8,
    x_in: usize,
    src: []const u8,
    lut: *const [256][n]u8,
) usize {
    var x = x_in;
    const width = out.len / n;
    if (bits == 8) {
        const m = @min(src.len, width - x);
        for (src[0..m], 0..) |i, k| out[(x + k) * n ..][0..n].* = lut[i];
        return x + m;
    }
    const per_byte = 8 / bits;
    const mask = (1 << bits) - 1;
    for (src) |byte| {
        inline for (0..per_byte) |k| {
            if (x < width) {
                const i = (byte >> (8 - bits * (k + 1))) & mask;
                out[x * n ..][0..n].* = lut[i];
                x += 1;
            }
        }
    }
    return x;
}

/// Rows stored as `format` pixels: read straight into `dst` when it holds
/// that format, and converted a piece at a time otherwise.
fn rows(in: *Input, h: Header, dst: PixelBuffer, comptime format: PixelFormat, pad: usize) Error!void {
    const bpp = format.bytesPerPixel();
    const out_bpp = dst.format.bytesPerPixel();
    const conv: Converter = .init(dst.format, format);
    for (0..h.height) |y| {
        const out = dst.row(rowIndex(h, y));
        if (dst.format == format) {
            try in.read(out);
        } else {
            var x: usize = 0;
            while (x < h.width) {
                const m = @min(h.width - x, in.maxTake(bpp) / bpp);
                conv.run(out[x * out_bpp ..], try in.take(m * bpp), m);
                x += m;
            }
        }
        try in.skip(pad);
    }
}

/// 32-bit BGRX rows, whose fourth byte is unused.
fn opaqueRows(in: *Input, h: Header, dst: PixelBuffer, pad: usize) Error!void {
    const out_bpp = dst.format.bytesPerPixel();
    // A format without alpha drops it, so only one with alpha needs it set.
    const conv: Converter = .init(dst.format, .bgra8);
    const set_alpha = dst.format.hasAlpha();
    var buf: [256 * 4]u8 = undefined;
    for (0..h.height) |y| {
        const out = dst.row(rowIndex(h, y));
        var x: usize = 0;
        while (x < h.width) {
            const m: usize = @min(h.width - x, in.maxTake(4) / 4, 256);
            const src = try in.take(m * 4);
            if (set_alpha) {
                const piece = if (dst.format == .bgra8) out[x * 4 ..][0 .. m * 4] else buf[0 .. m * 4];
                opaque4(piece, src);
                if (dst.format != .bgra8) conv.run(out[x * out_bpp ..], piece, m);
            } else {
                conv.run(out[x * out_bpp ..], src, m);
            }
            x += m;
        }
        try in.skip(pad);
    }
}

/// Copies 4-byte pixels with the fourth byte set to 255.
fn opaque4(out: []u8, src: []const u8) void {
    const V = @Vector(16, u8);
    const alpha: V = @bitCast(@as(@Vector(4, u32), @splat(std.mem.nativeToLittle(u32, 0xff000000))));
    var i: usize = 0;
    while (i + 16 <= src.len) : (i += 16) {
        const v: V = src[i..][0..16].*;
        out[i..][0..16].* = v | alpha;
    }
    while (i < src.len) : (i += 4) out[i..][0..4].* = .{ src[i], src[i + 1], src[i + 2], 255 };
}

/// How one mask's channel comes out of a pixel: shift, keep the top 8 or
/// fewer bits, and widen them through a table.
const Channel = struct {
    shift: u5,
    mask: u32,
    table: [256]u8,

    fn init(m: u32) Channel {
        var c: Channel = .{ .shift = 0, .mask = 0, .table = @splat(255) };
        if (m == 0) return c;
        const width: u6 = @intCast(@popCount(m));
        const kept: u4 = @intCast(@min(width, 8));
        c.shift = @intCast(@ctz(m) + (width - kept));
        c.mask = (@as(u32, 1) << kept) - 1;
        for (0..@as(usize, 1) << kept) |v| c.table[v] = widen(@intCast(v), kept);
        return c;
    }

    inline fn get(c: *const Channel, p: u32) u8 {
        return c.table[(p >> c.shift) & c.mask];
    }
};

/// `v`, `bits` wide, widened to 8 bits by repeating its bits.
fn widen(v: u8, bits: u4) u8 {
    var out: u32 = 0;
    var have: u32 = 0;
    while (have < 8) : (have += bits) out = out << bits | v;
    return @intCast(out >> @intCast(have - 8));
}

/// Pixels whose channels are masks: 16-bit, and 32-bit bitfields.
fn fields(in: *Input, h: Header, dst: PixelBuffer, pad: usize) Error!void {
    const bpp: usize = h.bits / 8;
    const out_bpp = dst.format.bytesPerPixel();
    var channels: [4]Channel = undefined;
    for (&channels, h.masks) |*c, m| c.* = .init(m);
    const conv: Converter = .init(dst.format, .bgra8);
    var buf: [256 * 4]u8 = undefined;
    for (0..h.height) |y| {
        const out = dst.row(rowIndex(h, y));
        var x: usize = 0;
        while (x < h.width) {
            const m: usize = @min(h.width - x, in.maxTake(bpp) / bpp, 256);
            const src = try in.take(m * bpp);
            const piece = if (dst.format == .bgra8) out[x * 4 ..][0 .. m * 4] else buf[0 .. m * 4];
            switch (bpp) {
                inline 2, 4 => |k| for (0..m) |i| {
                    const p: u32 = std.mem.readInt(@Int(.unsigned, k * 8), src[i * k ..][0..k], .little);
                    piece[i * 4 ..][0..4].* = .{
                        channels[2].get(p), channels[1].get(p), channels[0].get(p), channels[3].get(p),
                    };
                },
                else => unreachable,
            }
            if (dst.format != .bgra8) conv.run(out[x * out_bpp ..], piece, m);
            x += m;
        }
        try in.skip(pad);
    }
}

/// RLE8 and RLE4 (the module comment has the rules for streams that
/// misbehave). `lut` holds the palette in `dst`'s format.
fn rle(comptime n: usize, in: *Input, h: Header, lut: *const [256][n]u8, dst: PixelBuffer) Error!void {
    for (0..h.height) |y| @memset(dst.row(@intCast(y)), 0);
    const w: usize = h.width;
    const four = h.compression == .rle4;
    var x: usize = 0;
    var y: usize = 0;
    while (true) {
        const op = (try in.takeArray(2)).*;
        if (op[0] > 0) {
            // A run, cut off at the row's end and dropped past the last row.
            if (y < h.height) {
                const out = dst.row(rowIndex(h, y));
                const m = @min(op[0], w - x);
                if (four) {
                    const pair = [2]u8{ op[1] >> 4, op[1] & 15 };
                    for (0..m) |k| out[(x + k) * n ..][0..n].* = lut[pair[k & 1]];
                } else {
                    for (x..x + m) |i| out[i * n ..][0..n].* = lut[op[1]];
                }
                x += m;
            }
            continue;
        }
        switch (op[1]) {
            0 => {
                if (y >= h.height) return error.BadRle;
                y += 1;
                x = 0;
            },
            1 => return,
            2 => {
                const d = (try in.takeArray(2)).*;
                if (x + d[0] > w or (d[1] > 0 and y + d[1] >= h.height)) return error.BadRle;
                x += d[0];
                y += d[1];
            },
            else => |len| {
                // Literal indices, padded to an even number of bytes. RLE4
                // literals are cut off at the row's end and dropped past
                // the last row, as runs are.
                if (!four and (y >= h.height or x + len > w)) return error.BadRle;
                const bytes: usize = if (four) (@as(usize, len) + 1) / 2 else len;
                var left = bytes + (bytes & 1);
                if (y >= h.height) {
                    try in.skip(left);
                    continue;
                }
                const out = dst.row(rowIndex(h, y));
                var k: usize = 0;
                while (left > 0) {
                    const src = try in.take(@min(left, in.maxTake(1)));
                    left -= src.len;
                    for (src) |b| {
                        if (four) {
                            inline for (.{ b >> 4, b & 15 }) |i| {
                                if (k < len and x < w) {
                                    out[x * n ..][0..n].* = lut[i];
                                    x += 1;
                                }
                                k += 1;
                            }
                        } else if (k < len) {
                            out[x * n ..][0..n].* = lut[b];
                            x += 1;
                            k += 1;
                        }
                    }
                }
            },
        }
    }
}
