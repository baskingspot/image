//! A streaming Netpbm decoder: PBM, PGM, and PPM, plain and raw; PAM; and
//! PFM. It reads from a `std.Io.Reader`, writes any `PixelFormat`, needs no
//! work memory, and allocates nothing.
//!
//! Formats: the Netpbm specifications (netpbm.sourceforge.net/doc: pbm,
//! pgm, ppm, pam, and pfm). The native pixel format is 8-bit for a maxval
//! up to 255 and 16-bit above it, gray, gray and alpha, RGB, or RGBA as the
//! file stores; PBM is `gray8`, and PFM is `rgba_f32`. A sample `v` with
//! maxval `m` is the fraction `v / m` of full scale, so it becomes
//! `v * 255 / m` (or `v * 65535 / m`) rounded to nearest; maxval 255 and
//! 65535 keep the samples as they are.
//!
//! How strict the decoder is, where the specifications leave room:
//!
//! - Header numbers are ASCII decimal, separated by at least one
//!   whitespace character (space, tab, CR, LF, VT, FF). A comment runs from
//!   `#` to the next CR or LF, which stays and counts as whitespace, so
//!   `255#c\n` ends a header. Exactly one whitespace character ends a PBM,
//!   PGM, PPM, or PFM header. A zero width, height, depth, or maxval, a
//!   maxval over 65535, or anything else out of place is `BadHeader`; a
//!   width or height over 2^32 - 1 is `ImageTooLarge`.
//! - PAM: `P7` and a newline, then lines of one keyword and its value;
//!   blank lines and lines starting with `#` (after blanks) are ignored,
//!   and blanks (whitespace but LF, so a CR too) may end a line.
//!   WIDTH, HEIGHT, DEPTH, MAXVAL, and ENDHDR must each appear once, and an
//!   unknown keyword or an extra token on a line is `BadHeader`. The tuple
//!   types BLACKANDWHITE and GRAYSCALE (read the same way, as gray scaled
//!   by maxval), RGB, and their `_ALPHA` forms are read from the first one
//!   to four planes, and further planes are skipped, as the PAM
//!   specification recommends; a depth too small for the type is
//!   `BadHeader`. Without a tuple type, depth 1 to 4 reads as gray, gray
//!   and alpha, RGB, and RGBA; any other tuple type, or no tuple type with a
//!   larger depth, is `Unsupported`.
//! - PFM: `PF` (color) or `Pf` (gray), the width, the height, and the scale,
//!   a nonzero decimal number whose sign gives the byte order (negative is
//!   little endian); the scale's magnitude names units and is not applied.
//!   Rows are stored bottom to top and written top to bottom.
//! - A sample above maxval is `SampleOutOfRange`.
//! - Plain rasters (P1, P2, P3) are read leniently, as their specifications
//!   ask: any whitespace between samples, and comments, as libnetpbm accepts
//!   them. A sample must end with whitespace, a comment, or the end of the
//!   input, and anything after the last sample must start with whitespace or
//!   a comment; otherwise it is `BadRaster`. The decoder reads nothing past
//!   the last sample.
//! - Frames: a raw PBM, PGM, PPM, or PAM file is a sequence of images, each
//!   a frame. Whitespace between images and after the last is skipped (as
//!   libnetpbm skips it between plain images); then the input must end or
//!   hold another image with the same magic number, size, and native format
//!   (`FrameMismatch` otherwise). `Config.frame_count` is null for these,
//!   since only the end of the input tells. Plain files and PFM hold one
//!   image, and the decoder stops after it.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

const Decoder = @This();

pub const Options = decode.Options;

pub const Error = decode.Error || error{
    /// A sample is greater than the header's maxval.
    SampleOutOfRange,
    /// A plain raster holds something other than samples, whitespace, and
    /// comments, or a sample runs into the next character.
    BadRaster,
    /// An image after the first has another magic number, size, or native
    /// pixel format.
    FrameMismatch,
};

reader: *Io.Reader,
options: Options,
state: State = .start,
/// The first image's header, which sets the canvas.
first: Header = undefined,
/// The header of the image being decoded.
header: Header = undefined,
frames: u32 = 0,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,

const State = enum {
    start,
    /// A header is read and its raster is next.
    config,
    /// An image is decoded and another may follow.
    more,
    done,
};

const Magic = enum(u8) {
    plain_pbm = '1',
    plain_pgm = '2',
    plain_ppm = '3',
    pbm = '4',
    pgm = '5',
    ppm = '6',
    pam = '7',
    pfm = 'F',
    pfm_gray = 'f',

    fn isPlain(m: Magic) bool {
        return switch (m) {
            .plain_pbm, .plain_pgm, .plain_ppm => true,
            else => false,
        };
    }

    fn isFloat(m: Magic) bool {
        return m == .pfm or m == .pfm_gray;
    }

    fn isBits(m: Magic) bool {
        return m == .pbm or m == .plain_pbm;
    }

    /// Whether more images may follow this one.
    fn isSequence(m: Magic) bool {
        return !m.isPlain() and !m.isFloat();
    }
};

const Layout = enum(u3) {
    gray = 1,
    gray_alpha = 2,
    rgb = 3,
    rgba = 4,

    fn count(l: Layout) u3 {
        return @intFromEnum(l);
    }
};

const Header = struct {
    magic: Magic,
    width: u32,
    height: u32,
    /// 1 for PBM; unused for PFM.
    maxval: u16 = 1,
    /// Samples per stored pixel: PAM's depth, else the layout's count.
    depth: u32,
    /// The channels the native format holds, from the first stored samples.
    layout: Layout,
    /// PFM's byte order.
    little: bool = false,

    fn native(h: Header) PixelFormat {
        if (h.magic.isFloat()) return .rgba_f32;
        const wide = h.maxval > 255;
        return switch (h.layout) {
            .gray => if (wide) .gray16 else .gray8,
            .gray_alpha => if (wide) .gray_alpha16 else .gray_alpha8,
            .rgb => if (wide) .rgb16 else .rgb8,
            .rgba => if (wide) .rgba16 else .rgba8,
        };
    }
};

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the first image's header. Calling it again returns the same
/// config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.first = d.readFirst() catch |e| return d.fail(e);
        d.header = d.first;
        d.state = .config;
    }
    const h = d.first;
    const native = h.native();
    return .{
        .width = h.width,
        .height = h.height,
        .native = native,
        .frame_count = if (h.magic.isSequence()) null else 1,
        .is_opaque = !native.hasAlpha(),
    };
}

fn readFirst(d: *Decoder) Error!Header {
    const h = try readHeader(d.reader);
    try d.options.limits.checkSize(h.width, h.height);
    if (!h.magic.isSequence()) try d.options.limits.checkFrames(1);
    return h;
}

/// Decodes the next image into `dst`, which must be the canvas's size, in
/// any format. Returns null once there are no more. `work` is unused:
/// Netpbm needs no work memory.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    _ = work;
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    try dst.check();
    if (dst.width != d.first.width or dst.height != d.first.height) return error.SizeMismatch;
    if (d.state == .more) {
        const more = d.next() catch |e| return d.fail(e);
        if (!more) {
            d.state = .done;
            return null;
        }
        d.state = .config;
    }
    raster(d.reader, d.header, dst) catch |e| return d.fail(e);
    const index = d.frames;
    d.frames += 1;
    d.state = if (d.header.magic.isSequence()) .more else .done;
    return .{
        .index = index,
        .width = d.first.width,
        .height = d.first.height,
        .is_opaque = !d.first.native().hasAlpha(),
    };
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

/// Skips whitespace after an image and reads the next image's header, or
/// returns false at the end of the input.
fn next(d: *Decoder) Error!bool {
    const r = d.reader;
    while (true) {
        const c = r.peekByte() catch |e| switch (e) {
            error.EndOfStream => return false,
            error.ReadFailed => return error.ReadFailed,
        };
        if (!isSpace(c)) break;
        r.toss(1);
    }
    try d.options.limits.checkFrames(@as(u64, d.frames) + 1);
    const h = try readHeader(r);
    const f = d.first;
    if (h.magic != f.magic or h.width != f.width or h.height != f.height or h.native() != f.native()) {
        return error.FrameMismatch;
    }
    d.header = h;
    return true;
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn peek(r: *Io.Reader) Error!u8 {
    return r.peekByte() catch |e| mapRead(e);
}

fn take(r: *Io.Reader) Error!u8 {
    return r.takeByte() catch |e| mapRead(e);
}

/// C's isspace: space, tab, LF, VT, FF, and CR.
fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r' => true,
        else => false,
    };
}

/// Whitespace within a PAM header line: all but LF.
fn isBlank(c: u8) bool {
    return c != '\n' and isSpace(c);
}

// The headers.

fn readHeader(r: *Io.Reader) Error!Header {
    if (try take(r) != 'P') return error.BadSignature;
    const magic: Magic = switch (try take(r)) {
        '1'...'7', 'F', 'f' => |c| @enumFromInt(c),
        else => return error.BadSignature,
    };
    return switch (magic) {
        .pam => readPam(r),
        .pfm, .pfm_gray => readPfm(r, magic),
        else => readPnm(r, magic),
    };
}

/// Skips a comment, from its `#` to the next CR or LF (left in place) or
/// the end of the input.
fn skipComment(r: *Io.Reader) Error!void {
    r.toss(1);
    return skipUntil(r, "\r\n");
}

/// Skips to the next of `ends`, leaving it in place, or to the end of the
/// input.
fn skipUntil(r: *Io.Reader, ends: []const u8) Error!void {
    while (true) {
        const buf = r.buffered();
        if (std.mem.findAny(u8, buf, ends)) |i| return r.toss(i);
        r.toss(buf.len);
        r.fillMore() catch |e| switch (e) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

/// Skips the bytes `skip` holds for and returns how many; the input must
/// go on past them, so `r.buffered()` is not empty after it. These loops
/// scan the reader's buffer rather than peeking a byte at a time, which
/// costs an error union per byte.
fn skipWhile(r: *Io.Reader, comptime skip: fn (u8) bool) Error!usize {
    var n: usize = 0;
    while (true) {
        const buf = r.buffered();
        const i = for (buf, 0..) |c, i| {
            if (!skip(c)) break i;
        } else buf.len;
        r.toss(i);
        n += i;
        if (i < buf.len) return n;
        r.fillMore() catch |e| return mapRead(e);
    }
}

/// Skips the whitespace and comments between header numbers, of which at
/// least one whitespace character.
fn skipSeparator(r: *Io.Reader) Error!void {
    var spaced = false;
    while (true) {
        if (try skipWhile(r, isSpace) > 0) spaced = true;
        if (r.buffered()[0] != '#') break;
        try skipComment(r);
    }
    if (!spaced) return error.BadHeader;
}

/// Saturates well above every field's range, so overflow is visible.
const number_cap = 1 << 40;

/// An unsigned decimal number, capped at `number_cap`. The digits must be
/// followed by something.
fn number(r: *Io.Reader) Error!u64 {
    var v: u64 = 0;
    var digits: usize = 0;
    while (true) {
        const buf = r.buffered();
        const i = for (buf, 0..) |c, i| {
            if (c < '0' or c > '9') break i;
            v = @min(v * 10 + (c - '0'), number_cap);
        } else buf.len;
        r.toss(i);
        digits += i;
        if (i < buf.len) break;
        r.fillMore() catch |e| return mapRead(e);
    }
    if (digits == 0) return error.BadHeader;
    return v;
}

fn dimension(v: u64) Error!u32 {
    if (v == 0) return error.BadHeader;
    return std.math.cast(u32, v) orelse error.ImageTooLarge;
}

fn maxvalue(v: u64) Error!u16 {
    if (v == 0) return error.BadHeader;
    return std.math.cast(u16, v) orelse error.BadHeader;
}

fn readPnm(r: *Io.Reader, magic: Magic) Error!Header {
    try skipSeparator(r);
    const width = try number(r);
    try skipSeparator(r);
    const height = try number(r);
    var maxval: u64 = 1;
    if (!magic.isBits()) {
        try skipSeparator(r);
        maxval = try number(r);
    }
    // A comment may come before the one whitespace character that ends
    // the header; it ends at a CR or LF, which is that character.
    if (try peek(r) == '#') try skipComment(r);
    if (!isSpace(try take(r))) return error.BadHeader;
    const layout: Layout = switch (magic) {
        .plain_ppm, .ppm => .rgb,
        else => .gray,
    };
    return .{
        .magic = magic,
        .width = try dimension(width),
        .height = try dimension(height),
        .maxval = try maxvalue(maxval),
        .depth = layout.count(),
        .layout = layout,
    };
}

fn readPfm(r: *Io.Reader, magic: Magic) Error!Header {
    try skipSpaces(r);
    const width = try number(r);
    try skipSpaces(r);
    const height = try number(r);
    try skipSpaces(r);
    // The scale: a decimal number, ended by one whitespace character.
    var text: [64]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const c = try take(r);
        if (isSpace(c)) break;
        switch (c) {
            '0'...'9', '+', '-', '.', 'e', 'E' => {},
            else => return error.BadHeader,
        }
        if (len == text.len) return error.BadHeader;
        text[len] = c;
        len += 1;
    }
    const scale = std.fmt.parseFloat(f64, text[0..len]) catch return error.BadHeader;
    if (scale == 0 or std.math.isNan(scale)) return error.BadHeader;
    const layout: Layout = if (magic == .pfm) .rgb else .gray;
    return .{
        .magic = magic,
        .width = try dimension(width),
        .height = try dimension(height),
        .depth = layout.count(),
        .layout = layout,
        .little = text[0] == '-',
    };
}

/// At least one whitespace character, and no comments: PFM's separators.
fn skipSpaces(r: *Io.Reader) Error!void {
    if (try skipWhile(r, isSpace) == 0) return error.BadHeader;
}

fn skipBlanks(r: *Io.Reader) Error!void {
    _ = try skipWhile(r, isBlank);
}

/// A PAM keyword: the bytes up to the next whitespace, at most `out.len`.
fn keyword(r: *Io.Reader, out: []u8) Error![]u8 {
    var len: usize = 0;
    while (true) {
        const buf = r.buffered();
        const i = for (buf, 0..) |c, i| {
            if (isSpace(c)) break i;
        } else buf.len;
        if (i > out.len - len) return error.BadHeader;
        @memcpy(out[len..][0..i], buf[0..i]);
        len += i;
        r.toss(i);
        if (i < buf.len) return out[0..len];
        r.fillMore() catch |e| return mapRead(e);
    }
}

/// The rest of a PAM header line: blanks, then its newline.
fn endLine(r: *Io.Reader) Error!void {
    try skipBlanks(r);
    if (try take(r) != '\n') return error.BadHeader;
}

const TupleType = struct {
    name: []const u8,
    layout: Layout,
};

const tuple_types = [_]TupleType{
    .{ .name = "BLACKANDWHITE", .layout = .gray },
    .{ .name = "GRAYSCALE", .layout = .gray },
    .{ .name = "RGB", .layout = .rgb },
    .{ .name = "BLACKANDWHITE_ALPHA", .layout = .gray_alpha },
    .{ .name = "GRAYSCALE_ALPHA", .layout = .gray_alpha },
    .{ .name = "RGB_ALPHA", .layout = .rgba },
};

fn readPam(r: *Io.Reader) Error!Header {
    if (try take(r) != '\n') return error.BadHeader;
    var fields: [4]?u64 = @splat(null); // WIDTH, HEIGHT, DEPTH, MAXVAL
    // The tuple type, as far as the longest known one; a longer one is
    // unknown whatever it says.
    var tuple: [24]u8 = undefined;
    var tuple_len: usize = 0;
    while (true) {
        try skipBlanks(r);
        switch (r.buffered()[0]) {
            '\n' => {
                r.toss(1);
                continue;
            },
            '#' => {
                // A comment line, to its newline.
                try skipUntil(r, "\n");
                _ = try take(r);
                continue;
            },
            else => {},
        }
        var key_buf: [8]u8 = undefined;
        const key = try keyword(r, &key_buf);
        if (std.mem.eql(u8, key, "ENDHDR")) {
            try endLine(r);
            break;
        }
        if (std.mem.eql(u8, key, "TUPLTYPE")) {
            try skipBlanks(r);
            var any = false;
            var blanks: usize = 0;
            line: while (true) {
                const buf = r.buffered();
                for (buf, 0..) |c, i| {
                    if (c == '\n') {
                        r.toss(i + 1);
                        break :line;
                    }
                    if (isBlank(c)) {
                        blanks += 1;
                        continue;
                    }
                    // Values join with one blank; blanks inside a value
                    // are kept (as blanks) and blanks at its end dropped.
                    if (!any and tuple_len > 0) blanks = 1;
                    if (!any) any = true;
                    for (0..blanks) |_| append(&tuple, &tuple_len, ' ');
                    blanks = 0;
                    append(&tuple, &tuple_len, c);
                }
                r.toss(buf.len);
                r.fillMore() catch |e| return mapRead(e);
            }
            if (!any) return error.BadHeader;
            continue;
        }
        const names = [_][]const u8{ "WIDTH", "HEIGHT", "DEPTH", "MAXVAL" };
        const i = for (names, 0..) |name, i| {
            if (std.mem.eql(u8, key, name)) break i;
        } else return error.BadHeader;
        if (fields[i] != null) return error.BadHeader;
        try skipBlanks(r);
        fields[i] = try number(r);
        try endLine(r);
    }
    for (fields) |f| if (f == null) return error.BadHeader;
    const width = try dimension(fields[0].?);
    const height = try dimension(fields[1].?);
    const depth = try dimension(fields[2].?);
    const maxval = try maxvalue(fields[3].?);
    const layout: Layout = if (tuple_len == 0) switch (depth) {
        1...4 => @enumFromInt(depth),
        else => return error.Unsupported,
    } else for (tuple_types) |t| {
        if (std.mem.eql(u8, tuple[0..tuple_len], t.name)) {
            if (depth < t.layout.count()) return error.BadHeader;
            break t.layout;
        }
    } else return error.Unsupported;
    return .{ .magic = .pam, .width = width, .height = height, .maxval = maxval, .depth = depth, .layout = layout };
}

/// Appends to a tuple type, marking it unknown (full past the longest
/// known name) when it is too long.
fn append(tuple: *[24]u8, len: *usize, c: u8) void {
    if (len.* == tuple.len) return;
    tuple[len.*] = c;
    len.* += 1;
}

// The rasters.

/// How stored samples become native ones.
const Unpack = enum {
    /// 8-bit samples with maxval 255, as they are.
    copy8,
    /// 16-bit samples with maxval 65535, big endian to the machine's order.
    swap16,
    /// 8-bit samples with a smaller maxval, scaled through a table.
    scale8,
    /// 16-bit samples with another maxval, scaled to 65535.
    scale16,
    /// PBM's packed bits, 1 for black.
    bits,
    /// PFM's floats, in either byte order, to RGBA.
    float,
};

/// What a raster needs to unpack spans of pixels.
const Raster = struct {
    unpack: Unpack,
    plain: bool,
    /// Stored samples kept per pixel, and their size in bytes.
    channels: u3,
    sample_bytes: u3,
    /// Stored bytes per pixel, kept and skipped.
    stored: u64,
    maxval: u16,
    little: bool,
    /// Scaled values of 8-bit samples up to maxval, for `scale8` and plain
    /// samples with maxval below 256.
    table: [256]u8,

    fn init(h: Header) Raster {
        const sample_bytes: u3 = if (h.magic.isFloat()) 4 else if (h.maxval > 255) 2 else 1;
        var ras: Raster = .{
            .unpack = if (h.magic.isBits())
                .bits
            else if (h.magic.isFloat())
                .float
            else switch (h.maxval) {
                255 => .copy8,
                65535 => .swap16,
                else => if (h.maxval > 255) .scale16 else .scale8,
            },
            .plain = h.magic.isPlain(),
            .channels = h.layout.count(),
            .sample_bytes = sample_bytes,
            .stored = @as(u64, h.depth) * sample_bytes,
            .maxval = h.maxval,
            .little = h.little,
            .table = undefined,
        };
        if (h.maxval < 256 and !h.magic.isBits() and (ras.unpack == .scale8 or ras.plain)) {
            const m: u32 = h.maxval;
            for (ras.table[0 .. m + 1], 0..) |*t, v| t.* = @intCast((v * 510 + m) / (2 * m));
        }
        return ras;
    }

    /// Bytes of the native pixels a span unpacks into.
    fn nativeBytes(ras: *const Raster) usize {
        if (ras.unpack == .float) return 16;
        if (ras.unpack == .bits) return 1;
        return @as(usize, ras.channels) * ras.sample_bytes;
    }
};

const span_len = 4096;

fn raster(r: *Io.Reader, h: Header, dst: PixelBuffer) Error!void {
    const native = h.native();
    const nbpp = native.bytesPerPixel();
    const dbpp = dst.format.bytesPerPixel();
    const direct = dst.format == native;
    const conv: Converter = .init(dst.format, native);
    // Rows stored as native rows go straight into the buffer, or convert
    // straight from the reader's buffer; a buffer without padding between
    // rows is one long row.
    const whole = !h.magic.isPlain() and !h.magic.isBits() and !h.magic.isFloat() and
        h.depth == h.layout.count() and (h.maxval == 255 or h.maxval == 65535);
    if (whole and (direct or h.maxval == 255)) {
        const packed_rows = dst.stride == @as(usize, h.width) * dbpp;
        const rows: usize = if (packed_rows) 1 else h.height;
        const cols: usize = if (packed_rows) @as(usize, h.width) * h.height else h.width;
        for (0..rows) |y| {
            const row = dst.pixels[y * dst.stride ..][0 .. cols * dbpp];
            if (direct) {
                r.readSliceAll(row) catch |e| return mapRead(e);
                if (h.maxval == 65535) swap16(row, row);
                continue;
            }
            var x: usize = 0;
            while (x < cols) {
                r.fill(nbpp) catch |e| return mapRead(e);
                const buf = r.buffered();
                const k = @min(buf.len / nbpp, cols - x);
                conv.run(row[x * dbpp ..], buf, k);
                r.toss(k * nbpp);
                x += k;
            }
        }
        return;
    }
    // Spans of native pixels, written straight into rows of the native
    // format and through a converter into any other.
    var ras: Raster = .init(h);
    var span: [span_len]u8 align(16) = undefined;
    const per = span_len / nbpp;
    for (0..h.height) |i| {
        const y = if (h.magic.isFloat()) h.height - 1 - i else i;
        const row = dst.row(@intCast(y));
        var x: usize = 0;
        while (x < h.width) {
            const n = @min(per, h.width - x);
            const out = if (direct) row[x * nbpp ..][0 .. n * nbpp] else span[0 .. n * nbpp];
            if (ras.plain) try readPlain(r, &ras, out, n) else try readSpan(r, &ras, out, n);
            if (!direct) conv.run(row[x * dbpp ..], out, n);
            x += n;
        }
    }
    if (ras.plain) {
        // What follows the raster must start with whitespace or a comment.
        const c = r.peekByte() catch |e| switch (e) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
        if (!isSpace(c) and c != '#') return error.BadRaster;
    }
}

/// Reads `n` raw pixels into `out` as native ones: `n` is a multiple of 8
/// or the rest of a row, so PBM spans start at byte boundaries.
fn readSpan(r: *Io.Reader, ras: *const Raster, out: []u8, n: usize) Error!void {
    if (ras.unpack == .bits) return readBits(r, out, n);
    const keep = @as(usize, ras.channels) * ras.sample_bytes;
    const obpp = ras.nativeBytes();
    if (ras.stored != keep) {
        // A PAM with planes past the ones kept: a pixel at a time.
        for (0..n) |i| {
            const s = r.take(keep) catch |e| return mapRead(e);
            try unpack(ras, out[i * obpp ..][0..obpp], s, 1);
            r.discardAll64(ras.stored - keep) catch |e| return mapRead(e);
        }
        return;
    }
    // Whole pixels from the reader's buffer, as many as it holds.
    var i: usize = 0;
    while (i < n) {
        r.fill(keep) catch |e| return mapRead(e);
        const buf = r.buffered();
        const k = @min(buf.len / keep, n - i);
        try unpack(ras, out[i * obpp ..][0 .. k * obpp], buf[0 .. k * keep], k);
        r.toss(k * keep);
        i += k;
    }
}

/// Unpacks `k` stored pixels `s` into native pixels `out`.
fn unpack(ras: *const Raster, out: []u8, s: []const u8, k: usize) Error!void {
    switch (ras.unpack) {
        .copy8 => @memcpy(out, s),
        .swap16 => swap16(out, s),
        .scale8 => {
            var top: u8 = 0;
            for (out, s) |*o, v| {
                top = @max(top, v);
                o.* = ras.table[v];
            }
            if (top > ras.maxval) return error.SampleOutOfRange;
        },
        .scale16 => {
            const m: u64 = ras.maxval;
            for (0..out.len / 2) |j| {
                const v: u64 = std.mem.readInt(u16, s[2 * j ..][0..2], .big);
                if (v > m) return error.SampleOutOfRange;
                const scaled: u16 = @intCast((v * 131070 + m) / (2 * m));
                std.mem.writeInt(u16, out[2 * j ..][0..2], scaled, native_endian);
            }
        },
        .float => {
            const order: std.builtin.Endian = if (ras.little) .little else .big;
            const c = ras.channels;
            for (0..k) |p| {
                var px: [4]u32 = .{ 0, 0, 0, @bitCast(@as(f32, 1)) };
                for (0..3) |ch| {
                    const at = (p * c + @min(ch, c - 1)) * 4;
                    px[ch] = std.mem.readInt(u32, s[at..][0..4], order);
                }
                for (px, 0..) |v, ch| std.mem.writeInt(u32, out[p * 16 + ch * 4 ..][0..4], v, native_endian);
            }
        },
        .bits => unreachable,
    }
}

const native_endian = builtin.cpu.arch.endian();

/// 16-bit samples from big endian to the machine's order; `out` may be
/// `s`.
fn swap16(out: []u8, s: []const u8) void {
    if (native_endian == .big) {
        if (out.ptr != s.ptr) @memcpy(out, s);
        return;
    }
    const lanes = 32;
    const mask = comptime m: {
        var m: [lanes]i32 = undefined;
        for (0..lanes) |i| m[i] = i ^ 1;
        break :m m;
    };
    var j: usize = 0;
    while (j + lanes <= s.len) : (j += lanes) {
        const v: @Vector(lanes, u8) = s[j..][0..lanes].*;
        out[j..][0..lanes].* = @shuffle(u8, v, undefined, mask);
    }
    while (j + 2 <= s.len) : (j += 2) {
        const hi = s[j];
        out[j] = s[j + 1];
        out[j + 1] = hi;
    }
}

/// PBM's packed rows: each byte is 8 pixels, 1 black and 0 white, the
/// first in the high bit.
fn readBits(r: *Io.Reader, out: []u8, n: usize) Error!void {
    var i: usize = 0;
    while (i < n) {
        r.fill(1) catch |e| return mapRead(e);
        const buf = r.buffered();
        const k = @min(buf.len, (n - i + 7) / 8);
        // Whole bytes of 8 pixels, then the span's last bits.
        const whole = @min(k, (n - i) / 8);
        for (buf[0..whole]) |b| {
            out[i..][0..8].* = expandBits(b);
            i += 8;
        }
        if (whole < k) {
            const px = expandBits(buf[whole]);
            @memcpy(out[i..n], px[0 .. n - i]);
            i = n;
        }
        r.toss(k);
    }
}

fn expandBits(b: u8) [8]u8 {
    const select: @Vector(8, u8) = .{ 128, 64, 32, 16, 8, 4, 2, 1 };
    const v: @Vector(8, u8) = @splat(b);
    const black: @Vector(8, u8) = @splat(0);
    const white: @Vector(8, u8) = @splat(255);
    return @select(u8, (v & select) == black, white, black);
}

/// Reads `n` plain pixels into `out` as native ones.
fn readPlain(r: *Io.Reader, ras: *const Raster, out: []u8, n: usize) Error!void {
    if (ras.unpack == .bits) {
        for (out[0..n]) |*o| o.* = if (try plainBit(r)) 0 else 255;
        return;
    }
    const count = n * ras.channels;
    var j: usize = 0;
    while (j < count) {
        // Samples of up to 5 digits, 8 bytes at a time, while the buffer
        // holds them; then one sample the slow way, which takes comments,
        // longer numbers, and samples the buffer splits.
        const buf = r.buffered();
        var i: usize = 0;
        while (j < count and i + 8 <= buf.len) {
            const c = buf[i];
            if (isSpace(c)) {
                i += 1;
                continue;
            }
            const len = digitRun(buf[i..][0..8]);
            if (len == 0 or len > 5) break;
            const after = buf[i + len];
            if (!isSpace(after) and after != '#') return error.BadRaster;
            try putSample(ras, out, j, digitValue(buf[i..][0..8], len));
            j += 1;
            i += len;
        }
        r.toss(i);
        if (j < count) {
            try putSample(ras, out, j, try plainSample(r));
            j += 1;
        }
    }
}

/// How many of the 8 bytes `b` starts with are ASCII digits. A byte that
/// is not one may borrow or carry into the bytes after it, so only the
/// count up to the first such byte is exact, which is all it returns.
fn digitRun(b: *const [8]u8) u4 {
    const x = std.mem.readInt(u64, b, .little);
    const ones: u64 = 0x0101010101010101;
    const not_digit = ((x -% ones * '0') | (x +% ones * (0x7f - '9'))) & (ones * 0x80);
    return @intCast(@ctz(not_digit) / 8);
}

/// The value of the `len` (1 to 8) digits `b` starts with.
fn digitValue(b: *const [8]u8, len: u4) u32 {
    const ones: u64 = 0x0101010101010101;
    // Digits as bytes, the first in the low byte; leading zeros fill the
    // low bytes so the number ends at the top one.
    var v = (std.mem.readInt(u64, b, .little) -% ones * '0') << @intCast(8 * (8 - @as(u7, len)));
    v = ((v * 10) + (v >> 8)) & 0x00ff00ff00ff00ff;
    v = ((v * 100) + (v >> 16)) & 0x0000ffff0000ffff;
    v = (v * 10000) + (v >> 32);
    return @truncate(v);
}

/// Stores plain sample `v` as native sample `j` of `out`.
fn putSample(ras: *const Raster, out: []u8, j: usize, v: u32) Error!void {
    if (v > ras.maxval) return error.SampleOutOfRange;
    if (ras.maxval < 256) {
        out[j] = ras.table[v];
        return;
    }
    const m: u64 = ras.maxval;
    const scaled: u16 = @intCast((@as(u64, v) * 131070 + m) / (2 * m));
    std.mem.writeInt(u16, out[2 * j ..][0..2], scaled, native_endian);
}

/// Skips whitespace and comments before a plain sample, and returns its
/// first character.
fn skipPlain(r: *Io.Reader) Error!u8 {
    while (true) {
        _ = try skipWhile(r, isSpace);
        const c = r.buffered()[0];
        if (c != '#') return c;
        try skipComment(r);
    }
}

/// A plain PBM pixel: whether it is black.
fn plainBit(r: *Io.Reader) Error!bool {
    const c = try skipPlain(r);
    if (c != '0' and c != '1') return error.BadRaster;
    r.toss(1);
    return c == '1';
}

/// A plain sample, capped above every maxval.
fn plainSample(r: *Io.Reader) Error!u32 {
    const first = try skipPlain(r);
    if (first < '0' or first > '9') return error.BadRaster;
    var v: u32 = 0;
    while (true) {
        const buf = r.buffered();
        const i = for (buf, 0..) |c, i| {
            if (c < '0' or c > '9') break i;
            v = @min(v * 10 + (c - '0'), 1 << 17);
        } else buf.len;
        r.toss(i);
        if (i < buf.len) {
            if (!isSpace(buf[i]) and buf[i] != '#') return error.BadRaster;
            return v;
        }
        r.fillMore() catch |e| switch (e) {
            error.EndOfStream => return v,
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

fn testDecode(file: []const u8, format: PixelFormat, out: []u8) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    const frame = (try d.decodeFrame(dst, &.{})).?;
    try testing.expectEqual(config.width, frame.width);
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
    return config;
}

fn expectPixels(file: []const u8, format: PixelFormat, want: []const u8) !void {
    var out: [256]u8 = undefined;
    _ = try testDecode(file, format, out[0..want.len]);
    try testing.expectEqualSlices(u8, want, out[0..want.len]);
}

test "raw and plain PBM, PGM, and PPM" {
    // PBM: 1 is black; the last byte of each row is padded.
    try expectPixels("P4\n3 2\n\xa0\x40", .gray8, &.{ 0, 255, 0, 255, 0, 255 });
    try expectPixels("P1\n3 2\n101\n0 1 0", .gray8, &.{ 0, 255, 0, 255, 0, 255 });
    try expectPixels("P1 3 2 1010 10", .gray8, &.{ 0, 255, 0, 255, 0, 255 });
    try expectPixels("P5 2 1 255\n\x00\xfe", .gray8, &.{ 0, 254 });
    try expectPixels("P2 2 1 255\n0 254", .gray8, &.{ 0, 254 });
    try expectPixels("P6 1 1 255\n\x01\x02\x03", .rgb8, &.{ 1, 2, 3 });
    try expectPixels("P3 1 1 255\n1 2 3\n", .bgr8, &.{ 3, 2, 1 });
    // 16-bit samples are big endian in the file and native in memory.
    try expectPixels("P5 1 1 65535\n\x12\x34", .gray16, std.mem.asBytes(&@as(u16, 0x1234)));
    try expectPixels("P2 1 1 65535\n4660\n", .gray16, std.mem.asBytes(&@as(u16, 0x1234)));
    // Through a converter: 16 to 8 bits rounds c / 257.
    try expectPixels("P6 1 1 65535\n\x00\x80\x01\x00\xff\xff", .rgba8, &.{ 0, 1, 255, 255 });
}

test "maxval scales to nearest" {
    // round(v * 255 / 3): 0, 85, 170, 255.
    try expectPixels("P5 4 1 3\n\x00\x01\x02\x03", .gray8, &.{ 0, 85, 170, 255 });
    // round(v * 255 / 2): 0, 127.5 up to 128, 255.
    try expectPixels("P2 3 1 2\n0 1 2", .gray8, &.{ 0, 128, 255 });
    // maxval 1: a PGM bitmap, 0 black and 1 white, unlike PBM.
    try expectPixels("P5 2 1 1\n\x00\x01", .gray8, &.{ 0, 255 });
    // 16-bit: round(v * 65535 / 1000): 500 is 32767.5, up to 32768.
    var want: [3]u16 = .{ 0, 32768, 65535 };
    try expectPixels("P5 3 1 1000\n\x00\x00\x01\xf4\x03\xe8", .gray16, std.mem.sliceAsBytes(&want));
    // 256 needs 2 bytes: round(1 * 65535 / 256) = 256.
    want[0] = 256;
    try expectPixels("P5 1 1 256\n\x00\x01", .gray16, std.mem.sliceAsBytes(want[0..1]));
    // A sample above maxval.
    var out: [8]u8 = undefined;
    try testing.expectError(error.SampleOutOfRange, testDecode("P5 2 1 3\n\x00\x04", .gray8, &out));
    try testing.expectError(error.SampleOutOfRange, testDecode("P2 2 1 3\n0 4", .gray8, &out));
    try testing.expectError(error.SampleOutOfRange, testDecode("P5 1 1 1000\n\x03\xe9", .gray16, &out));
    try testing.expectError(error.SampleOutOfRange, testDecode("P2 1 1 7 99999999999999", .gray8, &out));
}

test "header whitespace and comments" {
    try expectPixels("P5\t2\x0b1\x0c255\r\x00\x01", .gray8, &.{ 0, 1 });
    try expectPixels("P5#c\n2 #c c\r1#\n255\n\x00\x01", .gray8, &.{ 0, 1 });
    // A comment's CR or LF can end the header.
    try expectPixels("P5 2 1 255#c\n\x00\x01", .gray8, &.{ 0, 1 });
    // The one whitespace character is all the header takes.
    try expectPixels("P5 2 1 255\n\n\x01", .gray8, &.{ 10, 1 });
    try expectPixels("P5 2 1 0255\n\x00\x01", .gray8, &.{ 0, 1 });
    var out: [8]u8 = undefined;
    for ([_][]const u8{
        "P52 1 255\n\x00\x00", // no whitespace after the magic number
        "P5 2x 1 255\n\x00\x00",
        "P5 2 1 255x\x00\x00",
        "P5 -2 1 255\n\x00\x00",
        "P5 0 1 255\n",
        "P5 2 1 0\n\x00\x00",
        "P5 2 1 65536\n\x00\x00",
    }) |file| try testing.expectError(error.BadHeader, testDecode(file, .gray8, &out));
    try testing.expectError(error.BadSignature, testDecode("P8 1 1 255\n\x00", .gray8, &out));
    try testing.expectError(error.BadSignature, testDecode("Q5 1 1 255\n\x00", .gray8, &out));
    try testing.expectError(error.ImageTooLarge, testDecode("P5 4294967296 1 255\n", .gray8, &out));
    // Every truncation of a valid file.
    const good = "P5 #c\n2 1 255\n\x00\x01";
    for (0..good.len) |n| try testing.expectError(error.Truncated, testDecode(good[0..n], .gray8, &out));
}

test "plain rasters" {
    try expectPixels("P2 2 1 9\n#c\n 9#c\n\n0 ", .gray8, &.{ 255, 0 });
    try expectPixels("P1 2 1\n1#c\n0 junk", .gray8, &.{ 0, 255 });
    try expectPixels("P2 1 1 9 00009", .gray8, &.{255});
    var out: [8]u8 = undefined;
    try testing.expectError(error.BadRaster, testDecode("P2 2 1 9\n1x 2", .gray8, &out));
    try testing.expectError(error.BadRaster, testDecode("P2 2 1 9\n1 2x", .gray8, &out));
    try testing.expectError(error.BadRaster, testDecode("P1 2 1\n102", .gray8, &out));
    try testing.expectError(error.BadRaster, testDecode("P1 2 1\n1 1x", .gray8, &out));
    try testing.expectError(error.BadRaster, testDecode("P3 1 1 9\n1 -2 3", .gray8, &out));
    try testing.expectError(error.Truncated, testDecode("P3 1 1 9\n1 2 ", .gray8, &out));
}

test "PAM" {
    const rgba = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n";
    var out: [64]u8 = undefined;
    const config = try testDecode(rgba ++ "\x01\x02\x03\x04\x05\x06\x07\x08", .rgba8, &out);
    try testing.expectEqual(PixelFormat.rgba8, config.native);
    try testing.expect(!config.is_opaque);
    try testing.expectEqual(null, config.frame_count);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, out[0..8]);
    // Comments, blank lines, blanks, any order, and a split tuple type.
    const gray =
        "P7\n# c\n\n  \tMAXVAL 3 \r\nHEIGHT 1\n   # c\nWIDTH 2\nDEPTH 2\n" ++
        "TUPLTYPE \t GRAYSCALE_ALPHA  \nENDHDR  \n";
    try expectPixels(gray ++ "\x00\x03\x03\x01", .gray_alpha8, &.{ 0, 255, 255, 85 });
    // Planes past the type's are skipped.
    const deep = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 5\nMAXVAL 65535\nTUPLTYPE RGB\nENDHDR\n";
    const px = "\x00\x01\x00\x02\x00\x03\xff\xff\xff\xff" ++ "\x00\x04\x00\x05\x00\x06\xff\xff\xff\xff";
    var want: [6]u16 = .{ 1, 2, 3, 4, 5, 6 };
    try expectPixels(deep ++ px, .rgb16, std.mem.sliceAsBytes(&want));
    // Without a tuple type, the depth says.
    try expectPixels("P7\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nENDHDR\n\x01\x02\x03", .rgb8, &.{ 1, 2, 3 });
    // BLACKANDWHITE: 0 is black, 1 white.
    const bw = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 1\nMAXVAL 1\nTUPLTYPE BLACKANDWHITE\nENDHDR\n";
    try expectPixels(bw ++ "\x00\x01", .gray8, &.{ 0, 255 });
    // A CR is a blank, so the ENDHDR line ends at its newline.
    const crlf = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 1\nMAXVAL 1\nENDHDR\r\n";
    try expectPixels(crlf ++ "\x00\x01", .gray8, &.{ 0, 255 });
    for ([_][]const u8{
        "P7 WIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nENDHDR\n\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nENDHDR\n\x00",
        "P7\nWIDTH 1\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nENDHDR\n\x00",
        "P7\nWIDTH 1 2\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nENDHDR\n\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nCOLORS 3\nENDHDR\n\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nTUPLTYPE \nENDHDR\n\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 2\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nENDHDR x\n\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 0\nMAXVAL 255\nENDHDR\n",
    }) |file| try testing.expectError(error.BadHeader, testDecode(file, .gray8, &out));
    for ([_][]const u8{
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 5\nMAXVAL 255\nENDHDR\n\x00\x00\x00\x00\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE CMYK\nENDHDR\n\x00\x00\x00\x00",
        "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB\nTUPLTYPE _ALPHA\nENDHDR\n\x00\x00\x00\x00",
    }) |file| try testing.expectError(error.Unsupported, testDecode(file, .gray8, &out));
}

test "PFM" {
    // Little endian, bottom row first.
    const le = "PF\n1 2\n-1.0\n" ++ std.mem.toBytes([3]f32{ 0.5, 0.25, 2 }) ++ std.mem.toBytes([3]f32{ 0, 1, -1 });
    var want = [8]f32{ 0, 1, -1, 1, 0.5, 0.25, 2, 1 };
    var out: [32]u8 = undefined;
    if (native_endian == .little) {
        const config = try testDecode(le, .rgba_f32, &out);
        try testing.expectEqual(PixelFormat.rgba_f32, config.native);
        try testing.expectEqual(1, config.frame_count);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), &out);
    }
    // Big endian gray, any positive scale.
    const be = "Pf 2 1 3.5e2\n\x3f\x00\x00\x00\xc0\x00\x00\x00";
    want = .{ 0.5, 0.5, 0.5, 1, -2, -2, -2, 1 };
    _ = try testDecode(be, .rgba_f32, &out);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), &out);
    _ = try testDecode(be, .rgba8, out[0..8]);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255, 0, 0, 0, 255 }, out[0..8]);
    // One whitespace character ends the scale; a second is the raster's
    // first byte.
    _ = try testDecode("Pf 1 1 1. \n\x00\x00\x00", .rgba8, out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, out[0..4]);
    _ = try testDecode("Pf 1 1 1. \n\x00\x00\x00", .rgba_f32, out[0..16]);
    try testing.expectEqual(@as(u32, 0x0a000000), std.mem.readInt(u32, out[0..4], native_endian));
    try testing.expectError(error.BadHeader, testDecode("PF 1 1 0.0\n", .rgba8, &out));
    try testing.expectError(error.BadHeader, testDecode("PF 1 1 -0\n", .rgba8, &out));
    try testing.expectError(error.BadHeader, testDecode("PF 1 1 nan\n", .rgba8, &out));
    try testing.expectError(error.BadHeader, testDecode("PF #c\n1 1 1\n", .rgba8, &out));
    try testing.expectError(error.Truncated, testDecode("PF 1 1 1\n\x00\x00\x00\x00", .rgba8, &out));
}

test "image sequences" {
    const one = "P5 2 1 255\n\x01\x02";
    const two = one ++ "\n\nP5 2 1 7\n\x07\x00";
    var r: Io.Reader = .fixed(two ++ " \n");
    var d: Decoder = .init(&r, .{});
    var out: [2]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .gray8, 2, 1);
    try testing.expectEqual(0, (try d.decodeFrame(dst, &.{})).?.index);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, &out);
    try testing.expectEqual(1, (try d.decodeFrame(dst, &.{})).?.index);
    try testing.expectEqualSlices(u8, &.{ 255, 0 }, &out);
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));

    for ([_]struct { []const u8, Error }{
        .{ one ++ "P5 1 2 255\n\x00\x00", error.FrameMismatch },
        .{ one ++ "P2 2 1 255\n0 0", error.FrameMismatch },
        .{ one ++ "P5 2 1 256\n\x00\x00\x00\x00", error.FrameMismatch },
        .{ one ++ "junk", error.BadSignature },
        .{ one ++ "P5 2 1 255\n\x00", error.Truncated },
    }) |case| {
        r = .fixed(case[0]);
        d = .init(&r, .{});
        _ = try d.decodeFrame(dst, &.{});
        try testing.expectError(case[1], d.decodeFrame(dst, &.{}));
        try testing.expectError(case[1], d.decodeFrame(dst, &.{}));
    }
    // The frame limit applies as frames appear.
    r = .fixed(two);
    d = .init(&r, .{ .limits = .{ .max_frames = 1 } });
    _ = try d.decodeFrame(dst, &.{});
    try testing.expectError(error.TooManyFrames, d.decodeFrame(dst, &.{}));
    // Plain files hold one image, and nothing after it is read.
    r = .fixed("P2 2 1 255 1 2 P2 2 1 255 1 2");
    d = .init(&r, .{});
    try testing.expectEqual(1, (try d.decodeConfig()).frame_count);
    _ = try d.decodeFrame(dst, &.{});
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
}

test "limits and buffers" {
    const file = "P6 3 2 255\n" ++ "\x00" ** 18;
    var out: [64]u8 = undefined;
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_pixels = 5 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
    try testing.expectError(error.ImageTooLarge, d.decodeFrame(try PixelBuffer.init(&out, .rgb8, 3, 2), &.{}));
    r = .fixed(file);
    d = .init(&r, .{});
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .rgb8, 2, 2), &.{}));
    const short: PixelBuffer = .{ .pixels = out[0..17], .format = .rgb8, .width = 3, .height = 2, .stride = 9 };
    try testing.expectError(error.BufferTooSmall, d.decodeFrame(short, &.{}));
    _ = (try d.decodeFrame(try PixelBuffer.init(&out, .rgb8, 3, 2), &.{})).?;
}

test "a reader with a small buffer" {
    // Every unpacking path through a reader that serves 3 bytes at a time.
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var raster_bytes: [40 * 3 * 16]u8 = undefined;
    random.bytes(&raster_bytes);
    var file_buf: [2048]u8 = undefined;
    for ([_][]const u8{
        "P4 40 3\n",       "P5 40 3 255\n",                                                       "P5 40 3 200\n",
        "P6 40 3 65535\n", "P6 40 3 40000\n",                                                     "Pf 40 3 -1\n",
        "PF 13 3 1\n",     "P7\nWIDTH 20\nHEIGHT 3\nDEPTH 5\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n",
    }) |head| {
        @memcpy(file_buf[0..head.len], head);
        @memcpy(file_buf[head.len..][0..raster_bytes.len], &raster_bytes);
        // Samples within maxval, so scaling paths succeed.
        if (std.mem.find(u8, head, " 200") != null) {
            for (file_buf[head.len..][0..120]) |*b| b.* %= 201;
        }
        if (std.mem.find(u8, head, " 40000") != null) {
            for (0..360) |i| file_buf[head.len + 2 * i] %= 0x9c;
        }
        const file = file_buf[0 .. head.len + raster_bytes.len];
        var r: Io.Reader = .fixed(file);
        var d: Decoder = .init(&r, .{});
        const config = try d.decodeConfig();
        var want: [40 * 3 * 16]u8 = undefined;
        var got: [40 * 3 * 16]u8 = undefined;
        const len = PixelBuffer.len(.rgba16, config.width, config.height).?;
        _ = try d.decodeFrame(try PixelBuffer.init(want[0..len], .rgba16, config.width, config.height), &.{});
        var buffer: [decode.min_buffer_len]u8 = undefined;
        var trickle: Trickle = .{
            .data = file,
            .reader = .{ .vtable = &.{ .stream = Trickle.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
        };
        d = .init(&trickle.reader, .{});
        _ = try d.decodeFrame(try PixelBuffer.init(got[0..len], .rgba16, config.width, config.height), &.{});
        try testing.expectEqualSlices(u8, want[0..len], got[0..len]);
    }
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
