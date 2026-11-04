//! The Netpbm encoder: PBM, PGM, and PPM, plain and raw; PAM; and PFM.
//! It converts the source with `image.convert` to what the file stores,
//! writes one image, needs no work memory, and allocates nothing.
//!
//! By default it writes the format that holds the source's channels and
//! depth: PGM for gray, PPM for color, PAM (GRAYSCALE_ALPHA or RGB_ALPHA)
//! with alpha, with maxval 255 for 8-bit sources and 65535 for wider ones,
//! so a decoder reads back the source converted to its own native format.
//! Float sources default to a 16-bit PAM with alpha for the same reason;
//! ask for PFM, which has no alpha, with `.kind = .pfm`.
//!
//! - A maxval `m` stores `v * m / 255` of each 8-bit sample `v` and
//!   `v * m / 65535` of each 16-bit one, rounded to nearest, whatever the
//!   file's sample size (floats become 16-bit samples first); PAM with
//!   maxval 1 names its tuple type BLACKANDWHITE.
//! - PBM stores gray below 128 (of 255) as black.
//! - Plain files break lines before 70 characters, as the specifications
//!   ask, and end each row with a newline.
//! - PFM stores gray sources as `Pf` and others as `PF` (dropping alpha,
//!   as `image.convert` does), bottom row first, with scale 1 in the byte
//!   order `pfm_endian` names.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

const encoding = @import("../encode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

/// The Netpbm formats `encode` writes.
pub const Kind = enum {
    pbm,
    pgm,
    ppm,
    pam,
    pfm,
    plain_pbm,
    plain_pgm,
    plain_ppm,
};

pub const EncodeOptions = struct {
    /// The format to write; null picks PGM, PPM, or PAM from the source's
    /// channels.
    kind: ?Kind = null,
    /// The maxval of PGM, PPM, and PAM, 1 to 65535; 0 picks 255 for 8-bit
    /// sources and 65535 for wider ones. PBM and PFM have none.
    maxval: u16 = 0,
    /// PFM's byte order.
    pfm_endian: std.lang.Endian = .little,
};

pub const EncodeError = encoding.Error || error{
    /// Netpbm cannot store an image without rows or columns.
    EmptyImage,
};

/// The work memory `encode` needs: none.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    _ = options;
    _ = width;
    _ = height;
    return 0;
}

const Layout = enum { gray, gray_alpha, rgb, rgba };

fn layoutOf(f: PixelFormat) Layout {
    if (f.isGray()) return if (f.hasAlpha()) .gray_alpha else .gray;
    return if (f.hasAlpha()) .rgba else .rgb;
}

/// Writes `src` to `w` as one Netpbm image.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    _ = work;
    try src.check();
    if (src.width == 0 or src.height == 0) return error.EmptyImage;
    const kind = options.kind orelse switch (layoutOf(src.format)) {
        .gray => Kind.pgm,
        .rgb => if (src.format.sample() == .f32) Kind.pam else Kind.ppm,
        .gray_alpha, .rgba => Kind.pam,
    };
    const maxval: u16 = if (options.maxval != 0) options.maxval else if (src.format.sample() == .u8) 255 else 65535;
    switch (kind) {
        .pbm, .plain_pbm => {
            const plain = kind == .plain_pbm;
            try w.print("P{c}\n{d} {d}\n", .{ @as(u8, if (plain) '1' else '4'), src.width, src.height });
            return if (plain) plainBits(w, src) else bits(w, src);
        },
        .pgm, .ppm, .plain_pgm, .plain_ppm => {
            const color = kind == .ppm or kind == .plain_ppm;
            const plain = kind == .plain_pgm or kind == .plain_ppm;
            const magic: u8 = if (plain) (if (color) '3' else '2') else (if (color) '6' else '5');
            try w.print("P{c}\n{d} {d}\n{d}\n", .{ magic, src.width, src.height, maxval });
            const layout: Layout = if (color) .rgb else .gray;
            return if (plain) plainSamples(w, src, layout, maxval) else samples(w, src, layout, maxval);
        },
        .pam => {
            const layout = layoutOf(src.format);
            const depth: u8, const tuple: []const u8 = switch (layout) {
                .gray => .{ 1, if (maxval == 1) "BLACKANDWHITE" else "GRAYSCALE" },
                .gray_alpha => .{ 2, if (maxval == 1) "BLACKANDWHITE_ALPHA" else "GRAYSCALE_ALPHA" },
                .rgb => .{ 3, "RGB" },
                .rgba => .{ 4, "RGB_ALPHA" },
            };
            try w.print("P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH {d}\nMAXVAL {d}\nTUPLTYPE {s}\nENDHDR\n", .{
                src.width, src.height, depth, maxval, tuple,
            });
            return samples(w, src, layout, maxval);
        },
        .pfm => {
            const gray = src.format.isGray();
            const scale = if (options.pfm_endian == .little) "-1.0" else "1.0";
            try w.print("P{c}\n{d} {d}\n{s}\n", .{ @as(u8, if (gray) 'f' else 'F'), src.width, src.height, scale });
            return floats(w, src, if (gray) 1 else 3, options.pfm_endian);
        },
    }
}

const span_len = 4096;

/// The 8- or 16-bit format holding `layout`'s channels.
fn sampleFormat(layout: Layout, wide: bool) PixelFormat {
    return switch (layout) {
        .gray => if (wide) .gray16 else .gray8,
        .gray_alpha => if (wide) .gray_alpha16 else .gray_alpha8,
        .rgb => if (wide) .rgb16 else .rgb8,
        .rgba => if (wide) .rgba16 else .rgba8,
    };
}

/// A table of `round(v * m / 255)` for 8-bit samples, or null when `m` is
/// 255 or above it.
fn scaleTable(m: u16, table: *[256]u8) ?*const [256]u8 {
    if (m >= 255) return null;
    for (table, 0..) |*t, v| t.* = @intCast((2 * v * m + 255) / 510);
    return table;
}

/// Raw PGM, PPM, or PAM samples: big endian, scaled to maxval.
fn samples(w: *Io.Writer, src: PixelBuffer, layout: Layout, maxval: u16) EncodeError!void {
    const wide = maxval > 255;
    const fmt = sampleFormat(layout, workWide(src, maxval));
    const row_len = fmt.rowBytes(src.width).?;
    const as_stored = if (wide) maxval == 65535 and native_endian == .big else maxval == 255 and fmt.sample() == .u8;
    if (src.format == fmt and as_stored) {
        // The rows as they are, in one write when they are packed.
        if (src.stride == row_len) return w.writeAll(src.pixels[0 .. row_len * src.height]);
        for (0..src.height) |y| try w.writeAll(src.row(@intCast(y)));
        return;
    }
    var table_buf: [256]u8 = undefined;
    const table = scaleTable(maxval, &table_buf);
    const conv: Converter = .init(fmt, src.format);
    const bpp = fmt.bytesPerPixel();
    const sbpp = src.format.bytesPerPixel();
    var span: [span_len]u8 align(16) = undefined;
    const per = span_len / bpp;
    for (0..src.height) |y| {
        const row = src.row(@intCast(y));
        var x: usize = 0;
        while (x < src.width) {
            const n = @min(per, src.width - x);
            const out = span[0 .. n * bpp];
            conv.run(out, row[x * sbpp ..], n);
            if (fmt.sample() == .u8) {
                if (table) |t| for (out) |*b| {
                    b.* = t[b.*];
                };
                try w.writeAll(out);
            } else if (wide) {
                if (maxval != 65535) scale16(out, maxval);
                toBig16(out);
                try w.writeAll(out);
            } else {
                // 16-bit samples to a maxval of 255 or less, a byte each.
                scale16(out, maxval);
                for (0..out.len / 2) |j| out[j] = @intCast(std.mem.readInt(u16, out[2 * j ..][0..2], native_endian));
                try w.writeAll(out[0 .. out.len / 2]);
            }
            x += n;
        }
    }
}

const native_endian = builtin.target.cpu.arch.endian();

/// Whether to scale from 16-bit samples: for a 16-bit file, and for any
/// maxval from a source wider than 8 bits, so that the maxval's scaling is
/// one rounding of the source's own value.
fn workWide(src: PixelBuffer, maxval: u16) bool {
    return maxval > 255 or src.format.sample() != .u8;
}

/// 16-bit samples in the machine's order to `round(v * m / 65535)`.
fn scale16(s: []u8, m: u16) void {
    for (0..s.len / 2) |j| {
        const v: u64 = std.mem.readInt(u16, s[2 * j ..][0..2], native_endian);
        const scaled: u16 = @intCast((2 * v * m + 65535) / 131070);
        std.mem.writeInt(u16, s[2 * j ..][0..2], scaled, native_endian);
    }
}

/// 16-bit samples from the machine's order to big endian, in place.
fn toBig16(s: []u8) void {
    if (native_endian == .big) return;
    const lanes = 32;
    const mask = comptime m: {
        var m: [lanes]i32 = undefined;
        for (0..lanes) |i| m[i] = i ^ 1;
        break :m m;
    };
    var j: usize = 0;
    while (j + lanes <= s.len) : (j += lanes) {
        const v: @Vector(lanes, u8) = s[j..][0..lanes].*;
        s[j..][0..lanes].* = @shuffle(u8, v, undefined, mask);
    }
    while (j + 2 <= s.len) : (j += 2) std.mem.swap(u8, &s[j], &s[j + 1]);
}

/// Spans of a row as gray8, `per` pixels at a time.
const GraySpans = struct {
    conv: Converter,
    span: [span_len]u8 = undefined,

    fn init(src: PixelBuffer) GraySpans {
        return .{ .conv = .init(.gray8, src.format) };
    }

    fn get(g: *GraySpans, src: PixelBuffer, row: []const u8, x: usize, n: usize) []const u8 {
        if (src.format == .gray8) return row[x..][0..n];
        g.conv.run(&g.span, row[x * src.format.bytesPerPixel() ..], n);
        return g.span[0..n];
    }
};

/// Raw PBM: rows of packed bits, 1 for gray below 128.
fn bits(w: *Io.Writer, src: PixelBuffer) EncodeError!void {
    var gray: GraySpans = .init(src);
    var out: [span_len / 8]u8 = undefined;
    for (0..src.height) |y| {
        const row = src.row(@intCast(y));
        var x: usize = 0;
        while (x < src.width) {
            const n = @min(span_len, src.width - x);
            const g = gray.get(src, row, x, n);
            const len = (n + 7) / 8;
            @memset(out[0..len], 0);
            for (g, 0..) |v, i| out[i / 8] |= @as(u8, @intFromBool(v < 128)) << @intCast(7 - i % 8);
            try w.writeAll(out[0..len]);
            x += n;
        }
    }
}

/// The most characters on a plain line.
const line_max = 70;

/// Plain PBM: rows of 0 and 1, at most 70 to a line.
fn plainBits(w: *Io.Writer, src: PixelBuffer) EncodeError!void {
    var gray: GraySpans = .init(src);
    for (0..src.height) |y| {
        const row = src.row(@intCast(y));
        var x: usize = 0;
        while (x < src.width) {
            const n = @min(line_max, src.width - x);
            var line: [line_max + 1]u8 = undefined;
            for (gray.get(src, row, x, n), 0..) |v, i| line[i] = if (v < 128) '1' else '0';
            line[n] = '\n';
            try w.writeAll(line[0 .. n + 1]);
            x += n;
        }
    }
}

/// Plain PGM or PPM: decimal samples, lines broken before 70 characters.
fn plainSamples(w: *Io.Writer, src: PixelBuffer, layout: Layout, maxval: u16) EncodeError!void {
    const wide = workWide(src, maxval);
    const fmt = sampleFormat(layout, wide);
    var table_buf: [256]u8 = undefined;
    const table = scaleTable(maxval, &table_buf);
    const conv: Converter = .init(fmt, src.format);
    const bpp = fmt.bytesPerPixel();
    const sbpp = src.format.bytesPerPixel();
    var span: [span_len]u8 align(16) = undefined;
    const per = span_len / bpp;
    for (0..src.height) |y| {
        const row = src.row(@intCast(y));
        var line: [line_max + 1]u8 = undefined;
        var len: usize = 0;
        var x: usize = 0;
        while (x < src.width) {
            const n = @min(per, src.width - x);
            conv.run(&span, row[x * sbpp ..], n);
            const count = n * fmt.channelCount();
            for (0..count) |j| {
                var v: u32 = undefined;
                if (wide) {
                    v = std.mem.readInt(u16, span[2 * j ..][0..2], native_endian);
                    if (maxval != 65535) v = @intCast((2 * @as(u64, v) * maxval + 65535) / 131070);
                } else {
                    v = if (table) |t| t[span[j]] else span[j];
                }
                var digits: [5]u8 = undefined;
                const text = std.mem.print(&digits, "{d}", .{v}) catch unreachable;
                if (len > 0 and len + 1 + text.len > line_max) {
                    line[len] = '\n';
                    try w.writeAll(line[0 .. len + 1]);
                    len = 0;
                }
                if (len > 0) {
                    line[len] = ' ';
                    len += 1;
                }
                @memcpy(line[len..][0..text.len], text);
                len += text.len;
            }
            x += n;
        }
        line[len] = '\n';
        try w.writeAll(line[0 .. len + 1]);
    }
}

/// PFM: float samples, bottom row first, in `endian` order.
fn floats(w: *Io.Writer, src: PixelBuffer, channels: usize, endian: std.lang.Endian) EncodeError!void {
    const conv: Converter = .init(.rgba_f32, src.format);
    const sbpp = src.format.bytesPerPixel();
    var span: [span_len]u8 align(16) = undefined;
    var out: [span_len / 16 * 12]u8 = undefined;
    const per = span_len / 16;
    for (0..src.height) |i| {
        const row = src.row(@intCast(src.height - 1 - i));
        var x: usize = 0;
        while (x < src.width) {
            const n = @min(per, src.width - x);
            conv.run(&span, row[x * sbpp ..], n);
            for (0..n) |p| {
                for (0..channels) |c| {
                    const v = std.mem.readInt(u32, span[p * 16 + c * 4 ..][0..4], native_endian);
                    std.mem.writeInt(u32, out[(p * channels + c) * 4 ..][0..4], v, endian);
                }
            }
            try w.writeAll(out[0 .. n * channels * 4]);
            x += n;
        }
    }
}

const Decoder = @import("Decoder.zig");

/// Encodes `src` and decodes the file back as `format`.
fn roundTrip(src: PixelBuffer, options: EncodeOptions, file: []u8, format: PixelFormat, out: []u8) ![]const u8 {
    var w: Io.Writer = .fixed(file);
    try encode(&w, src, options, &.{});
    var r: Io.Reader = .fixed(w.buffered());
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(src.width, config.width);
    _ = (try d.decodeFrame(try PixelBuffer.init(out, format, config.width, config.height), &.{})).?;
    return w.buffered();
}

test "headers" {
    var file: [256]u8 = undefined;
    var out: [64]u8 = undefined;
    var px = [_]u8{ 0, 1, 2, 253, 254, 255 };
    const gray = try PixelBuffer.init(&px, .gray8, 3, 2);
    const rgb = try PixelBuffer.init(&px, .rgb8, 2, 1);
    const ga = try PixelBuffer.init(&px, .gray_alpha8, 3, 1);
    try testing.expectEqualStrings("P5\n3 2\n255\n" ++ px, try roundTrip(gray, .{}, &file, .gray8, &out));
    try testing.expectEqualStrings("P6\n2 1\n255\n" ++ px, try roundTrip(rgb, .{}, &file, .rgb8, &out));
    try testing.expectEqualStrings(
        "P7\nWIDTH 3\nHEIGHT 1\nDEPTH 2\nMAXVAL 255\nTUPLTYPE GRAYSCALE_ALPHA\nENDHDR\n" ++ px,
        try roundTrip(ga, .{}, &file, .gray_alpha8, &out),
    );
    try testing.expectEqualStrings("P4\n3 2\n\xe0\x00", try roundTrip(gray, .{ .kind = .pbm }, &file, .gray8, &out));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255 }, out[0..6]);
    const p1 = try roundTrip(gray, .{ .kind = .plain_pbm }, &file, .gray8, &out);
    try testing.expectEqualStrings("P1\n3 2\n111\n000\n", p1);
    const p2 = try roundTrip(gray, .{ .kind = .plain_pgm }, &file, .gray8, &out);
    try testing.expectEqualStrings("P2\n3 2\n255\n0 1 2\n253 254 255\n", p2);
    try testing.expectEqualSlices(u8, &px, out[0..6]);
    // maxval 3: round(v * 3 / 255) is 0, 0, 0, 3, 3, 3; read back as 0 or 255.
    const p3 = try roundTrip(rgb, .{ .kind = .plain_ppm, .maxval = 3 }, &file, .rgb8, &out);
    try testing.expectEqualStrings("P3\n2 1\n3\n0 0 0 3 3 3\n", p3);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255 }, out[0..6]);
    // 16-bit samples are big endian.
    const wide = [_]u16{ 0x0102, 0xfffe };
    const g16 = try PixelBuffer.init(@constCast(std.mem.sliceAsBytes(&wide)), .gray16, 2, 1);
    try testing.expectEqualStrings("P5\n2 1\n65535\n\x01\x02\xff\xfe", try roundTrip(g16, .{}, &file, .gray16, &out));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&wide), out[0..4]);
    // round(v * 1000 / 65535): 258 / 65.535 is 3.94 and 65534 is 999.98.
    const p5 = try roundTrip(g16, .{ .maxval = 1000 }, &file, .gray16, &out);
    try testing.expectEqualStrings("P5\n2 1\n1000\n\x00\x04\x03\xe8", p5);
    // An 8-bit maxval scales the 16-bit sample itself: 511 / 257 is 1.99,
    // where its high byte is 1.
    const mid = [_]u16{ 511, 0x8000 };
    const m16 = try PixelBuffer.init(@constCast(std.mem.sliceAsBytes(&mid)), .gray16, 2, 1);
    const p5_8 = try roundTrip(m16, .{ .maxval = 255 }, &file, .gray8, &out);
    try testing.expectEqualStrings("P5\n2 1\n255\n\x02\x80", p5_8);
    var w: Io.Writer = .fixed(&file);
    try testing.expectError(error.EmptyImage, encode(&w, try PixelBuffer.init(&px, .gray8, 0, 1), .{}, &.{}));
}

test "PFM" {
    var file: [256]u8 = undefined;
    var out: [64]u8 = undefined;
    const px = [_]f32{ 0.5, 0.25, 2, 0.75, 0, 1, -1, 1 };
    const src = try PixelBuffer.init(@constCast(std.mem.sliceAsBytes(&px)), .rgba_f32, 1, 2);
    const file_le = try roundTrip(src, .{ .kind = .pfm }, &file, .rgba_f32, &out);
    // The bottom row first, alpha dropped.
    try testing.expectEqualStrings("PF\n1 2\n-1.0\n", file_le[0..12]);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, -1))), std.mem.readInt(u32, file_le[20..24], .little));
    const want = [_]f32{ 0.5, 0.25, 2, 1, 0, 1, -1, 1 };
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), out[0..32]);
    const file_be = try roundTrip(src, .{ .kind = .pfm, .pfm_endian = .big }, &file, .rgba_f32, &out);
    try testing.expectEqualStrings("PF\n1 2\n1.0\n", file_be[0..11]);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), out[0..32]);
    // Gray sources are Pf; floats default to a 16-bit PAM, alpha kept.
    const g = [_]u8{ 0, 255 };
    const gray = try PixelBuffer.init(@constCast(&g), .gray8, 2, 1);
    const pf = try roundTrip(gray, .{ .kind = .pfm }, &file, .rgba_f32, &out);
    try testing.expect(std.mem.startsWith(u8, pf, "Pf\n2 1\n-1.0\n"));
    const pam = "P7\nWIDTH 1\nHEIGHT 2\nDEPTH 4\nMAXVAL 65535\nTUPLTYPE RGB_ALPHA\nENDHDR\n";
    try testing.expect(std.mem.startsWith(u8, try roundTrip(src, .{}, &file, .rgba16, &out), pam));
}
