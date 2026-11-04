//! JPEG encoding (T.81): baseline sequential or progressive DCT with
//! Huffman coding, 8-bit samples, YCbCr at 4:4:4, 4:2:2, or 4:2:0 for
//! color sources and one component for gray ones, in a JFIF file
//! (T.871), with EXIF and an ICC profile written when given.
//!
//! For the same settings the file is libjpeg-turbo's byte for byte
//! (docs/slop/jpeg.md, "Encoding"): its quality scaling of T.81 K.1's
//! tables, its RGB to YCbCr and downsampling, the islow forward DCT
//! (fdct.zig), its padding of partial blocks and MCUs, its markers, and,
//! for progressive files, its default scan script and its choice of when
//! to end an EOB run. Sources convert to `rgb8` or `gray8` with
//! `image.convert`, which drops alpha (plan.md decision 7).
//!
//! A baseline file with the standard Huffman tables is written as the
//! source is read, an MCU row at a time. Optimized tables and progressive
//! scans need every coefficient more than once, so those keep the whole
//! image's quantized coefficients in the work memory, two bytes a sample,
//! as libjpeg-turbo does.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const shared = @import("../encode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const vfill = @import("../fill.zig").fill;
const huffman = @import("huffman.zig");
const Spec = huffman.Spec;
const natural = huffman.natural;
const henc = @import("huffman_encode.zig");
const Codes = henc.Codes;
const BitWriter = henc.BitWriter;
const fdct = @import("fdct.zig");
const simd = @import("simd.zig");

pub const Subsampling = enum {
    /// Chroma at full resolution.
    @"4:4:4",
    /// Chroma at half the width.
    @"4:2:2",
    /// Chroma at half the width and half the height.
    @"4:2:0",
};

pub const EncodeOptions = struct {
    /// libjpeg's quality, 1 to 100: T.81 K.1's tables scaled by 5000/q
    /// below 50 and by 200 - 2q from 50, each value kept within 1 to 255.
    /// 0 counts as 1, and above 100 as 100.
    quality: u8 = 75,
    /// The chroma resolution of a color source; gray sources have none.
    subsampling: Subsampling = .@"4:2:0",
    /// Progressive scans, by libjpeg's default script, with optimized
    /// Huffman tables for each.
    progressive: bool = false,
    /// Huffman tables made for the image (T.81 K.2) rather than the
    /// standard ones of K.3; always so for progressive files.
    optimize: bool = false,
    /// An EXIF block to write in APP1, from its TIFF header on (what
    /// follows "Exif\x00\x00"), at most 65,527 bytes.
    exif: ?[]const u8 = null,
    /// An ICC profile to write in APP2 segments of up to 65,519 bytes,
    /// at most 255 of them.
    icc: ?[]const u8 = null,
};

pub const EncodeError = shared.Error || error{
    /// `exif` or `icc` is longer than JPEG's segments can hold.
    MetadataTooLarge,
};

const max_side = 0xffff;
const max_exif = 0xffff - 2 - 6;
const icc_chunk = 0xffff - 2 - 14;
const max_icc = icc_chunk * 255;

/// T.81 Table K.1, in natural order.
const luma_table = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

/// T.81 Table K.2, in natural order.
const chroma_table = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

/// `base` scaled for `quality`, in zigzag order.
fn quantTable(base: *const [64]u8, quality: u8) [64]u16 {
    const q: u32 = std.math.clamp(quality, 1, 100);
    const scale = if (q < 50) 5000 / q else 200 - q * 2;
    var t: [64]u16 = undefined;
    for (&t, 0..) |*v, k| {
        const x = (@as(u32, base[natural[k]]) * scale + 50) / 100;
        v.* = @intCast(std.math.clamp(x, 1, 255));
    }
    return t;
}

/// The components, their sampling, and their blocks.
const Layout = struct {
    ncomp: u8,
    max_h: u8,
    max_v: u8,
    h: [3]u8,
    v: [3]u8,
    mcus_x: u32,
    mcus_y: u32,
    /// The blocks that hold image samples, across and down (A.2.2).
    blocks_w: [3]u32,
    blocks_h: [3]u32,
    /// The blocks the MCUs hold, across and down: the image's and the
    /// dummy blocks that complete the last MCUs of an interleaved scan.
    padded_w: [3]u32,
    padded_h: [3]u32,

    fn init(gray: bool, sub: Subsampling, width: u32, height: u32) Layout {
        var l: Layout = undefined;
        l.ncomp = if (gray) 1 else 3;
        const hy: u8, const vy: u8 = if (gray) .{ 1, 1 } else switch (sub) {
            .@"4:4:4" => .{ 1, 1 },
            .@"4:2:2" => .{ 2, 1 },
            .@"4:2:0" => .{ 2, 2 },
        };
        l.h = .{ hy, 1, 1 };
        l.v = .{ vy, 1, 1 };
        l.max_h = hy;
        l.max_v = vy;
        l.mcus_x = ceilDiv(width, @as(u32, hy) * 8);
        l.mcus_y = ceilDiv(height, @as(u32, vy) * 8);
        for (0..3) |c| {
            l.blocks_w[c] = ceilDiv(width * @as(u32, l.h[c]), @as(u32, hy) * 8);
            l.blocks_h[c] = ceilDiv(height * @as(u32, l.v[c]), @as(u32, vy) * 8);
            l.padded_w[c] = l.mcus_x * l.h[c];
            l.padded_h[c] = l.mcus_y * l.v[c];
        }
        return l;
    }

    fn subsampled(l: *const Layout) bool {
        return l.max_h > 1 or l.max_v > 1;
    }

    /// The width of a full-resolution sample row, padded to whole MCUs.
    fn fullWidth(l: *const Layout) usize {
        return @as(usize, l.mcus_x) * l.max_h * 8;
    }

    /// The bytes of the sample planes for one MCU row: each component at
    /// full resolution, and the chroma downsampled.
    fn planesLen(l: *const Layout) usize {
        const full = l.ncomp * l.fullWidth() * l.max_v * 8;
        const down: usize = if (l.subsampled()) 2 * @as(usize, l.mcus_x) * 8 * 8 else 0;
        return full + down;
    }

    /// The blocks of one MCU row, every component's.
    fn rowBlocks(l: *const Layout) usize {
        var n: usize = 0;
        for (0..l.ncomp) |c| n += @as(usize, l.padded_w[c]) * l.v[c];
        return n;
    }

    /// The bytes of the whole image's coefficients, or null past usize.
    fn coefLen(l: *const Layout) ?usize {
        var n: usize = 0;
        for (0..l.ncomp) |c| {
            const blocks = std.math.mul(usize, l.padded_w[c], l.padded_h[c]) catch return null;
            n = std.math.add(usize, n, std.math.mul(usize, blocks, 128) catch return null) catch return null;
        }
        return n;
    }
};

fn ceilDiv(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

fn stored(options: EncodeOptions) bool {
    return options.progressive or options.optimize;
}

/// The work memory `encode` needs for a `width` by `height` image: a row
/// of the source converted, the samples of one MCU row, and the
/// coefficients of one MCU row or, for optimized tables or progressive
/// scans, of the whole image, two bytes per sample of each component with
/// its blocks padded to whole MCUs. It assumes a color source, which
/// needs at least what a gray one does. Null if the image is too large
/// for JPEG or for `usize`.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
    const l: Layout = .init(false, options.subsampling, width, height);
    const n = @as(usize, width) * 3 + l.planesLen() + 63;
    const blocks = if (stored(options)) l.coefLen() orelse return null else l.rowBlocks() * 128;
    return std.math.add(usize, n, blocks) catch null;
}

/// Writes `src` as a JPEG file to `w`. `work` holds at least
/// `workLen(options, src.width, src.height)` bytes.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    try src.check();
    const need = workLen(options, src.width, src.height) orelse return error.ImageTooLarge;
    if (work.len < need) return error.WorkTooSmall;
    if (options.exif) |e| if (e.len > max_exif) return error.MetadataTooLarge;
    if (options.icc) |p| if (p.len > max_icc) return error.MetadataTooLarge;

    const gray = src.format.isGray();
    const l: Layout = .init(gray, options.subsampling, src.width, src.height);
    var e: Encoder = .{ .src = src, .l = l, .gray = gray };
    e.quant[0] = quantTable(&luma_table, options.quality);
    e.quant[1] = quantTable(&chroma_table, options.quality);
    e.div[0] = .init(&e.quant[0]);
    e.div[1] = .init(&e.quant[1]);

    var rest = work;
    const base = std.mem.alignForward(usize, @intFromPtr(rest.ptr), 64) - @intFromPtr(rest.ptr);
    rest = rest[base..];
    e.whole = stored(options);
    for (0..l.ncomp) |c| {
        const rows = if (e.whole) l.padded_h[c] else l.v[c];
        const n = @as(usize, l.padded_w[c]) * rows;
        e.coef[c] = @alignCast(std.mem.bytesAsSlice(Block, rest[0 .. n * 128]));
        rest = rest[n * 128 ..];
    }
    const fw = l.fullWidth();
    const full_len = fw * l.max_v * 8;
    for (0..l.ncomp) |c| {
        e.full[c] = rest[0..full_len];
        rest = rest[full_len..];
    }
    if (l.subsampled()) {
        const down_len = @as(usize, l.mcus_x) * 8 * 8;
        for (&e.down) |*d| {
            d.* = rest[0..down_len];
            rest = rest[down_len..];
        }
    }
    e.row = rest[0 .. @as(usize, src.width) * 3];

    try e.writeHeader(w, options);
    if (!stored(options)) {
        try e.sequentialStreaming(w);
    } else {
        for (0..l.mcus_y) |iy| {
            e.fill(@intCast(iy));
            e.transform(@intCast(iy));
        }
        if (options.progressive) try e.progressive(w) else try e.sequentialStored(w);
    }
    try w.writeAll(&.{ 0xff, 0xd9 });
}

/// One block's quantized coefficients, in natural order.
const Block = [64]i16;

const Encoder = struct {
    src: PixelBuffer,
    l: Layout,
    gray: bool,
    quant: [2][64]u16 = undefined,
    div: [2]fdct.Divisors = undefined,
    /// Each component's blocks, row by row of padded blocks: the whole
    /// image's when they are kept (`whole`), else one MCU row's.
    coef: [3][]Block = .{ &.{}, &.{}, &.{} },
    whole: bool = false,
    /// Each component's samples at full resolution for one MCU row.
    full: [3][]u8 = undefined,
    /// The chroma downsampled, when it is.
    down: [2][]u8 = undefined,
    /// A source row converted to `rgb8` or `gray8`.
    row: []u8 = undefined,

    fn table(c: usize) u1 {
        return @intFromBool(c != 0);
    }

    fn writeHeader(e: *const Encoder, w: *Io.Writer, options: EncodeOptions) Io.Writer.Error!void {
        const l = &e.l;
        // SOI and JFIF 1.01, no units, aspect ratio 1:1, no thumbnail.
        try w.writeAll(&.{ 0xff, 0xd8, 0xff, 0xe0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 });
        if (options.exif) |x| {
            try marker(w, 0xe1, 6 + x.len);
            try w.writeAll("Exif\x00\x00");
            try w.writeAll(x);
        }
        if (options.icc) |p| if (p.len > 0) {
            const count = ceilDiv(@intCast(p.len), icc_chunk);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const chunk = p[i * icc_chunk .. @min(p.len, (i + 1) * icc_chunk)];
                try marker(w, 0xe2, 14 + chunk.len);
                try w.writeAll("ICC_PROFILE\x00");
                try w.writeAll(&.{ @intCast(i + 1), @intCast(count) });
                try w.writeAll(chunk);
            }
        };
        for (0..@min(l.ncomp, 2)) |t| {
            try marker(w, 0xdb, 65);
            try w.writeByte(@intCast(t));
            for (e.quant[t]) |v| try w.writeByte(@intCast(v));
        }
        try marker(w, if (options.progressive) 0xc2 else 0xc0, 6 + 3 * @as(usize, l.ncomp));
        try w.writeByte(8);
        try w.writeInt(u16, @intCast(e.src.height), .big);
        try w.writeInt(u16, @intCast(e.src.width), .big);
        try w.writeByte(l.ncomp);
        for (0..l.ncomp) |c| {
            try w.writeAll(&.{ @intCast(c + 1), l.h[c] << 4 | l.v[c], table(c) });
        }
    }

    /// Fills the sample planes for MCU row `iy` (T.81 A.2.4's padding as
    /// libjpeg-turbo does it): a row past the image's last repeats it, a
    /// column past its last repeats it before downsampling, and a chroma
    /// row past the last made from the image's rows repeats that one.
    fn fill(e: *Encoder, iy: u32) void {
        const l = &e.l;
        const width: usize = e.src.width;
        const fw = l.fullWidth();
        const rows = @as(u32, l.max_v) * 8;
        const conv: Converter = .init(if (e.gray) .gray8 else .rgb8, e.src.format);
        const native = e.src.format == (if (e.gray) PixelFormat.gray8 else PixelFormat.rgb8);
        for (0..rows) |r| {
            const sy = @min(iy * rows + @as(u32, @intCast(r)), e.src.height - 1);
            var px: []const u8 = e.src.row(sy);
            prefetchRow(e.src, sy + prefetch_rows);
            if (!native) {
                const n = if (e.gray) width else width * 3;
                conv.run(e.row[0..n], px, width);
                px = e.row[0..n];
            }
            const off = r * fw;
            if (e.gray) {
                const y = e.full[0][off..][0..fw];
                @memcpy(y[0..width], px[0..width]);
                @memset(y[width..], px[width - 1]);
            } else {
                rgbToYcc(px, e.full[0][off..][0..fw], e.full[1][off..][0..fw], e.full[2][off..][0..fw], width);
            }
        }
        if (!l.subsampled()) return;
        const cw = @as(usize, l.mcus_x) * 8;
        // The chroma rows made from image rows: one per row group.
        const made = ceilDiv(e.src.height, l.max_v);
        for (e.down, 1..) |d, c| {
            const full = e.full[c];
            for (0..8) |r| {
                const k = iy * 8 + @as(u32, @intCast(r));
                const out = d[r * cw ..][0..cw];
                if (k >= made) {
                    const last = made - 1 - iy * 8;
                    @memcpy(out, d[last * cw ..][0..cw]);
                    continue;
                }
                if (l.max_v == 2) {
                    downsample(out, full[2 * r * fw ..][0..fw], full[(2 * r + 1) * fw ..][0..fw]);
                } else {
                    downsample(out, full[r * fw ..][0..fw], null);
                }
            }
        }
    }

    /// Component `c`'s samples for the current MCU row and their stride.
    fn plane(e: *const Encoder, c: usize) struct { []const u8, usize } {
        if (c == 0 or !e.l.subsampled()) return .{ e.full[c], e.l.fullWidth() };
        return .{ e.down[c - 1], @as(usize, e.l.mcus_x) * 8 };
    }

    /// Block `gbx` of block row `gby` of component `c`, or of row `by`
    /// of the current MCU row when only that is kept.
    fn block(e: *const Encoder, c: usize, gby: usize, by: usize, gbx: usize) *Block {
        const y = if (e.whole) gby else by;
        return &e.coef[c][y * e.l.padded_w[c] + gbx];
    }

    /// The quantized blocks of MCU row `iy` from its samples, two at a
    /// time across each row of blocks. A dummy block past the image's
    /// right edge has no AC coefficients and the DC of the block before
    /// it, as does one below the bottom edge, after its MCU's last block
    /// above it (libjpeg-turbo's choice; T.81 A.2.4 leaves them free).
    fn transform(e: *const Encoder, iy: u32) void {
        const l = &e.l;
        for (0..l.ncomp) |c| {
            const p, const stride = e.plane(c);
            const div = &e.div[table(c)];
            const w = l.blocks_w[c];
            for (0..l.v[c]) |by| {
                const gby = @as(usize, iy) * l.v[c] + by;
                const row = p[by * 8 * stride ..];
                if (gby >= l.blocks_h[c]) {
                    for (0..l.mcus_x) |mx| {
                        const above = mx * l.h[c] + l.h[c] - 1;
                        const dc = e.block(c, gby - 1, by - 1, above)[0];
                        for (0..l.h[c]) |bx| {
                            const b = e.block(c, gby, by, mx * l.h[c] + bx);
                            b.* = @splat(0);
                            b[0] = dc;
                        }
                    }
                    continue;
                }
                var gbx: usize = 0;
                while (gbx + 2 <= w) : (gbx += 2) {
                    const left = e.block(c, gby, by, gbx);
                    const right = e.block(c, gby, by, gbx + 1);
                    fdct.forwardPair(row[gbx * 8 ..], row[gbx * 8 + 8 ..], stride, div, left, right);
                }
                if (gbx < w) {
                    var spare: Block = undefined;
                    fdct.forwardPair(row[gbx * 8 ..], row[gbx * 8 ..], stride, div, e.block(c, gby, by, gbx), &spare);
                }
                for (w..l.padded_w[c]) |x| {
                    const b = e.block(c, gby, by, x);
                    const dc = e.block(c, gby, by, x - 1)[0];
                    b.* = @splat(0);
                    b[0] = dc;
                }
            }
        }
    }

    fn sequentialStreaming(e: *Encoder, w: *Io.Writer) Io.Writer.Error!void {
        const l = &e.l;
        var codes: [2][2]Codes = undefined;
        codes[0][0] = .init(&huffman.standard.dc_luma);
        codes[1][0] = .init(&huffman.standard.ac_luma);
        codes[0][1] = .init(&huffman.standard.dc_chroma);
        codes[1][1] = .init(&huffman.standard.ac_chroma);
        var specs: [2][2]*const Spec = .{
            .{ &huffman.standard.dc_luma, &huffman.standard.dc_chroma },
            .{ &huffman.standard.ac_luma, &huffman.standard.ac_chroma },
        };
        try e.writeTablesAndScan(w, &specs, &sequential_scans[if (l.ncomp == 1) 0 else 1]);
        var bw: BitWriter = .{ .w = w };
        var coder: Coder(false) = .{ .bw = &bw, .codes = &codes, .counts = undefined };
        var pred: [3]i32 = @splat(0);
        for (0..l.mcus_y) |iy| {
            e.fill(@intCast(iy));
            e.transform(@intCast(iy));
            for (0..l.mcus_x) |mx| {
                for (0..l.ncomp) |c| {
                    for (0..l.v[c]) |by| for (0..l.h[c]) |bx| {
                        try coder.sequential(e.block(c, by, by, mx * l.h[c] + bx), table(c), &pred[c]);
                    };
                }
            }
        }
        try bw.finish();
    }

    fn sequentialStored(e: *Encoder, w: *Io.Writer) Io.Writer.Error!void {
        try e.storedScan(w, &sequential_scans[if (e.l.ncomp == 1) 0 else 1]);
    }

    fn progressive(e: *Encoder, w: *Io.Writer) Io.Writer.Error!void {
        const script: []const Scan = if (e.l.ncomp == 1) &gray_script else &color_script;
        for (script) |*scan| try e.storedScan(w, scan);
    }

    /// One scan from the stored coefficients with optimal tables: the
    /// symbols counted, the tables the scan uses made, then the scan
    /// coded.
    fn storedScan(e: *Encoder, w: *Io.Writer, scan: *const Scan) Io.Writer.Error!void {
        var counts: [2][2][256]u64 = undefined;
        const used = scan.tables();
        for (0..2) |class| for (0..2) |t| {
            if (used[class][t]) vfill(u64, &counts[class][t], 0);
        };
        var gather: Coder(true) = .{ .bw = undefined, .codes = undefined, .counts = &counts };
        try e.runScan(true, &gather, scan);
        var spec_vals: [2][2]Spec = undefined;
        var specs: [2][2]*const Spec = undefined;
        var codes: [2][2]Codes = undefined;
        for (0..2) |class| for (0..2) |t| {
            if (!used[class][t]) continue;
            spec_vals[class][t] = henc.optimal(&counts[class][t]);
            specs[class][t] = &spec_vals[class][t];
            codes[class][t] = .init(&spec_vals[class][t]);
        };
        try e.writeTablesAndScan(w, &specs, scan);
        var bw: BitWriter = .{ .w = w };
        var coder: Coder(false) = .{ .bw = &bw, .codes = &codes, .counts = undefined };
        try e.runScan(false, &coder, scan);
        try bw.finish();
    }

    /// The DHT segments a scan needs, each table once in its own
    /// segment, then its SOS.
    fn writeTablesAndScan(
        e: *const Encoder,
        w: *Io.Writer,
        specs: *const [2][2]*const Spec,
        scan: *const Scan,
    ) Io.Writer.Error!void {
        _ = e;
        const used = scan.tables();
        for (0..2) |t| for (0..2) |class| {
            if (used[class][t]) {
                const s = specs[class][t];
                const n = s.count();
                try marker(w, 0xc4, 17 + n);
                try w.writeByte(@intCast(class << 4 | t));
                try w.writeAll(&s.counts);
                try w.writeAll(s.values[0..n]);
            }
        };
        try marker(w, 0xda, 4 + 2 * @as(usize, scan.n));
        try w.writeByte(scan.n);
        for (scan.comps[0..scan.n]) |c| {
            // A table the scan does not use is named as 0.
            const t: u8 = table(c);
            const td = if (scan.ss == 0 and scan.ah == 0) t else 0;
            const ta = if (scan.se != 0) t else 0;
            try w.writeAll(&.{ c + 1, td << 4 | ta });
        }
        try w.writeAll(&.{ scan.ss, scan.se, @as(u8, scan.ah) << 4 | scan.al });
    }

    /// Codes every block of `scan` from the stored coefficients.
    fn runScan(
        e: *const Encoder,
        comptime gather: bool,
        coder: *Coder(gather),
        scan: *const Scan,
    ) Io.Writer.Error!void {
        const l = &e.l;
        coder.reset();
        if (scan.n > 1) {
            // Interleaved: MCU by MCU, dummy blocks included.
            for (0..l.mcus_y) |iy| for (0..l.mcus_x) |mx| {
                for (scan.comps[0..scan.n]) |c| {
                    for (0..l.v[c]) |by| for (0..l.h[c]) |bx| {
                        const gby = iy * l.v[c] + by;
                        const gbx = mx * l.h[c] + bx;
                        try coder.block(scan, c, &e.coef[c][gby * l.padded_w[c] + gbx]);
                    };
                }
            };
        } else {
            const c = scan.comps[0];
            for (0..l.blocks_h[c]) |gby| for (0..l.blocks_w[c]) |gbx| {
                try coder.block(scan, c, &e.coef[c][gby * l.padded_w[c] + gbx]);
            };
        }
        try coder.finish(table(scan.comps[0]));
    }
};

fn marker(w: *Io.Writer, m: u8, len: usize) Io.Writer.Error!void {
    try w.writeAll(&.{ 0xff, m });
    try w.writeInt(u16, @intCast(len + 2), .big);
}

/// A scan: its components, spectral selection, and successive
/// approximation (T.81 G.1.1).
const Scan = struct {
    n: u8,
    comps: [3]u8,
    ss: u8,
    se: u8,
    ah: u4,
    al: u4,

    fn of(comps: []const u8, ss: u8, se: u8, ah: u4, al: u4) Scan {
        var s: Scan = .{ .n = @intCast(comps.len), .comps = @splat(0), .ss = ss, .se = se, .ah = ah, .al = al };
        @memcpy(s.comps[0..comps.len], comps);
        return s;
    }

    /// The Huffman tables the scan codes with, by class (DC, AC) and
    /// number: a DC refinement scan needs none.
    fn tables(scan: *const Scan) [2][2]bool {
        var used: [2][2]bool = @splat(@splat(false));
        for (scan.comps[0..scan.n]) |c| {
            used[0][Encoder.table(c)] = used[0][Encoder.table(c)] or (scan.ss == 0 and scan.ah == 0);
            used[1][Encoder.table(c)] = used[1][Encoder.table(c)] or scan.se != 0;
        }
        return used;
    }
};

const sequential_scans = [2]Scan{ .of(&.{0}, 0, 63, 0, 0), .of(&.{ 0, 1, 2 }, 0, 63, 0, 0) };

/// For each byte of a block's natural-order nonzero mask, the bits its
/// value sets at the zigzag positions of those coefficients.
const to_zigzag: [8][256]u64 = blk: {
    @setEvalBranchQuota(100000);
    var pos: [64]u6 = undefined;
    for (0..64) |z| pos[natural[z]] = z;
    var t: [8][256]u64 = undefined;
    for (0..8) |i| {
        for (0..256) |v| {
            var m: u64 = 0;
            for (0..8) |bit| {
                if (v >> bit & 1 == 1) m |= @as(u64, 1) << pos[8 * i + bit];
            }
            t[i][v] = m;
        }
    }
    break :blk t;
};

/// libjpeg's default progression for YCbCr (`jpeg_simple_progression`):
/// DC first at a halved precision, the luma's first five AC coefficients
/// at a quarter, the chroma at a half, then the rest refined.
const color_script = [_]Scan{
    .of(&.{ 0, 1, 2 }, 0, 0, 0, 1),
    .of(&.{0}, 1, 5, 0, 2),
    .of(&.{2}, 1, 63, 0, 1),
    .of(&.{1}, 1, 63, 0, 1),
    .of(&.{0}, 6, 63, 0, 2),
    .of(&.{0}, 1, 63, 2, 1),
    .of(&.{ 0, 1, 2 }, 0, 0, 1, 0),
    .of(&.{2}, 1, 63, 1, 0),
    .of(&.{1}, 1, 63, 1, 0),
    .of(&.{0}, 1, 63, 1, 0),
};

/// The same for one component.
const gray_script = [_]Scan{
    .of(&.{0}, 0, 0, 0, 1),
    .of(&.{0}, 1, 5, 0, 2),
    .of(&.{0}, 6, 63, 0, 2),
    .of(&.{0}, 1, 63, 2, 1),
    .of(&.{0}, 0, 0, 1, 0),
    .of(&.{0}, 1, 63, 1, 0),
};

/// Correction bits an AC refinement scan holds back while an EOB run
/// grows: an EOB run is ended before a block could take them past this
/// (libjpeg-turbo's limit, which the encoder matches).
const max_corr_bits = 1000;

/// The entropy coder of one scan, writing (`gather` false) or counting
/// symbols for optimized tables (`gather` true), with the progressive
/// procedures of T.81 G.1.2.
fn Coder(comptime gather: bool) type {
    return struct {
        bw: *BitWriter,
        codes: *const [2][2]Codes,
        counts: *[2][2][256]u64,
        pred: [3]i32 = @splat(0),
        eobrun: u32 = 0,
        /// Correction bits held back for the current EOB run.
        corr: [max_corr_bits]u8 = undefined,
        be: usize = 0,

        const Self = @This();
        /// Where a block's bits go: the writer's state, held locally.
        const Out = if (gather) struct {} else BitWriter.Fast;

        fn reset(s: *Self) void {
            s.pred = @splat(0);
            s.eobrun = 0;
            s.be = 0;
        }

        inline fn begin(s: *Self) Io.Writer.Error!Out {
            return if (gather) .{} else s.bw.begin();
        }

        inline fn end(s: *Self, o: *const Out) void {
            if (!gather) s.bw.end(o);
        }

        /// Where a table's symbols go: their counts, or their codes.
        const Table = if (gather) *[256]u64 else *const Codes;

        inline fn table(s: *Self, comptime class: u1, t: u1) Table {
            return if (gather) &s.counts[class][t] else &s.codes[class][t];
        }

        inline fn symbol(s: *Self, o: *Out, comptime class: u1, t: u1, sym: u8) void {
            put(o, s.table(class, t), sym, 0, 0);
        }

        /// Symbol `sym` of `tab`, then the `n` bits of a DC difference or
        /// AC value `v` it announces (F.1.2.1), together.
        inline fn put(o: *Out, tab: Table, sym: u8, v: i32, n: u6) void {
            if (gather) {
                tab[sym] += 1;
            } else {
                o.put(@as(u32, tab.code[sym]) << @intCast(n) | low(v, n), tab.size[sym] + @as(u32, n));
            }
        }

        inline fn bit(o: *Out, v: u1) void {
            if (!gather) o.put(v, 1);
        }

        fn magnitude(v: i32) u6 {
            return @intCast(32 - @clz(@abs(v)));
        }

        /// `put` to table `t` of `class`.
        inline fn code(s: *Self, o: *Out, comptime class: u1, t: u1, sym: u8, v: i32, n: u6) void {
            put(o, s.table(class, t), sym, v, n);
        }

        /// The `n` bits that stand for `v` after its category (F.1.2.1).
        inline fn low(v: i32, n: u6) u32 {
            return @as(u32, @bitCast(if (v < 0) v - 1 else v)) & ((@as(u32, 1) << @intCast(n)) - 1);
        }

        /// Which coefficients of `b` are not 0, bit `k` for the one at
        /// zigzag position `k`.
        fn nonzero(b: *const Block) u64 {
            var bits: u64 = 0;
            inline for (0..4) |i| {
                const v: @Vector(16, i16) = b[16 * i ..][0..16].*;
                bits |= @as(u64, flags16(v != @as(@Vector(16, i16), @splat(0)))) << (16 * i);
            }
            return zigzagMask(bits);
        }

        /// The flags of sixteen coefficients in natural order as bits.
        /// Sixteen lanes of 16 bits keep the compare in 256-bit registers:
        /// on the benchmark's Ice Lake host any 512-bit instruction lowers
        /// the clock (docs/slop/plan.md).
        inline fn flags16(flags: @Vector(16, bool)) u16 {
            // A bool vector's bit cast packs element 0 into the low bit.
            return @bitCast(flags);
        }

        /// Bits in natural order moved to their zigzag positions, a byte
        /// at a time by table.
        inline fn zigzagMask(bits: u64) u64 {
            var m: u64 = 0;
            inline for (0..8) |i| m |= to_zigzag[i][@as(u8, @truncate(bits >> (8 * i)))];
            return m;
        }

        const Magnitudes = struct {
            /// Each coefficient's magnitude after the point transform,
            /// which divides by 2^al rounding toward zero.
            abs: [64]u16,
            /// Which are not 0, and which are 1, in zigzag order.
            nonzero: u64,
            one: u64,
        };

        inline fn magnitudes(b: *const Block, al: u4) Magnitudes {
            var m: Magnitudes = undefined;
            var nz: u64 = 0;
            var one: u64 = 0;
            inline for (0..4) |i| {
                const v: @Vector(16, i16) = b[16 * i ..][0..16].*;
                const a = @abs(v) >> @splat(al);
                m.abs[16 * i ..][0..16].* = a;
                nz |= @as(u64, flags16(a != @as(@Vector(16, u16), @splat(0)))) << (16 * i);
                one |= @as(u64, flags16(a == @as(@Vector(16, u16), @splat(1)))) << (16 * i);
            }
            m.nonzero = zigzagMask(nz);
            m.one = zigzagMask(one);
            return m;
        }

        /// Bits `ss` to `se` set.
        inline fn band(scan: *const Scan) u64 {
            return (~@as(u64, 0) >> @intCast(63 - scan.se)) & (~@as(u64, 0) << @intCast(scan.ss));
        }

        fn sequential(s: *Self, b: *const Block, t: u1, pred: *i32) Io.Writer.Error!void {
            var o = try s.begin();
            defer s.end(&o);
            const dc = s.table(0, t);
            const ac = s.table(1, t);
            const diff = @as(i32, b[0]) - pred.*;
            pred.* = b[0];
            const n = magnitude(diff);
            put(&o, dc, n, diff, n);
            // The AC coefficients' zero runs, from the gaps between the
            // nonzero ones; clearing the lowest bit keeps the loop's
            // dependency on `mask` to one instruction.
            var mask = nonzero(b) & ~@as(u64, 1);
            var last: u32 = 0;
            while (mask != 0) {
                const k: u32 = @ctz(mask);
                mask &= mask - 1;
                var r = k - last - 1;
                last = k;
                while (r > 15) : (r -= 16) put(&o, ac, 0xf0, 0, 0);
                const c = b[natural[k]];
                const m = magnitude(c);
                put(&o, ac, @intCast(r << 4 | m), c, m);
            }
            if (last != 63) put(&o, ac, 0, 0, 0);
        }

        fn block(s: *Self, scan: *const Scan, c: u8, b: *const Block) Io.Writer.Error!void {
            const t = Encoder.table(c);
            if (scan.ss == 0 and scan.se == 63) return s.sequential(b, t, &s.pred[c]);
            var o = try s.begin();
            defer s.end(&o);
            if (scan.ss == 0) {
                if (scan.ah == 0) {
                    // DC first: the coefficient shifted arithmetically.
                    const v = @as(i32, b[0]) >> scan.al;
                    const diff = v - s.pred[c];
                    s.pred[c] = v;
                    const n = magnitude(diff);
                    s.code(&o, 0, t, n, diff, n);
                } else {
                    bit(&o, @intCast((@as(i32, b[0]) >> scan.al) & 1));
                }
            } else if (scan.ah == 0) {
                s.acFirst(&o, scan, t, b);
            } else {
                s.acRefine(&o, scan, t, b);
            }
        }

        fn acFirst(s: *Self, o: *Out, scan: *const Scan, t: u1, b: *const Block) void {
            const mags = magnitudes(b, scan.al);
            const abs = &mags.abs;
            var mask = mags.nonzero & band(scan);
            var last: u32 = @as(u32, scan.ss) -% 1;
            while (mask != 0) {
                const k: u32 = @ctz(mask);
                mask &= mask - 1;
                var r = k -% last - 1;
                last = k;
                if (s.eobrun > 0) s.endRun(o, t);
                while (r > 15) : (r -= 16) s.symbol(o, 1, t, 0xf0);
                const a: i32 = abs[natural[k]];
                const m = magnitude(a);
                s.code(o, 1, t, @intCast(r << 4 | m), if (b[natural[k]] < 0) -a else a, m);
            }
            if (last != scan.se) {
                s.eobrun += 1;
                if (s.eobrun == 0x7fff) s.endRun(o, t);
            }
        }

        fn acRefine(s: *Self, o: *Out, scan: *const Scan, t: u1, b: *const Block) void {
            const mags = magnitudes(b, scan.al);
            const abs = &mags.abs;
            const in_band = band(scan);
            var mask = mags.nonzero & in_band;
            const newly = mags.one & in_band;
            // The last coefficient that becomes nonzero in this scan.
            const eob: u32 = if (newly == 0) 0 else 63 - @clz(newly);
            // Zeros since the last newly nonzero coefficient: one already
            // nonzero takes a correction bit and leaves the run going.
            var r: u32 = 0;
            var last: u32 = @as(u32, scan.ss) -% 1;
            // This block's correction bits, after the run's.
            var br_start = s.be;
            var br: usize = 0;
            while (mask != 0) {
                const k: u32 = @ctz(mask);
                mask &= mask - 1;
                r += k -% last - 1;
                last = k;
                // ZRLs, unless the zeros can end in an EOB instead.
                while (r > 15 and k <= eob) {
                    s.endRun(o, t);
                    s.symbol(o, 1, t, 0xf0);
                    r -= 16;
                    s.held(o, br_start, br);
                    br_start = 0;
                    br = 0;
                }
                const a = abs[natural[k]];
                if (a > 1) {
                    s.corr[br_start + br] = @intCast(a & 1);
                    br += 1;
                    continue;
                }
                s.endRun(o, t);
                s.symbol(o, 1, t, @intCast(r << 4 | 1));
                bit(o, @intFromBool(b[natural[k]] > 0));
                s.held(o, br_start, br);
                br_start = 0;
                br = 0;
                r = 0;
            }
            r += scan.se -% last;
            if (r > 0 or br > 0) {
                s.eobrun += 1;
                s.be = br_start + br;
                if (s.eobrun == 0x7fff or s.be > max_corr_bits - 64 + 1) s.endRun(o, t);
            }
        }

        fn held(s: *Self, o: *Out, start: usize, n: usize) void {
            for (s.corr[start..][0..n]) |v| bit(o, @intCast(v));
        }

        /// Writes the pending EOB run and the correction bits it held.
        fn endRun(s: *Self, o: *Out, t: u1) void {
            if (s.eobrun == 0) return;
            const n: u6 = @intCast(31 - @clz(s.eobrun));
            s.code(o, 1, t, @as(u8, n) << 4, @intCast(s.eobrun), n);
            s.eobrun = 0;
            s.held(o, 0, s.be);
            s.be = 0;
        }

        /// Ends the scan: a run is pending only in an AC scan, which has
        /// one component and `t` its table.
        fn finish(s: *Self, t: u1) Io.Writer.Error!void {
            var o = try s.begin();
            defer s.end(&o);
            s.endRun(&o, t);
        }
    };
}

/// How many rows ahead of the row being converted `fill` asks for the
/// source. A source larger than the caches comes from memory, and the
/// conversion alone does not keep enough reads in flight: on a 16 MP photo
/// this was a third faster (results/jpeg-encode-perf-20261102.md), with
/// 2 to 8 rows all alike.
const prefetch_rows = 4;

/// Asks the cache for row `y` of `src`, if there is one.
fn prefetchRow(src: PixelBuffer, y: u32) void {
    if (y >= src.height) return;
    const r = src.row(y);
    var i: usize = 0;
    while (i < r.len) : (i += 64) @prefetch(r.ptr + i, .{ .locality = 3 });
}

/// RGB to JFIF's YCbCr (T.871 section 7) in 16-bit fixed point, Cb and
/// Cr rounded with half less one so they cannot pass 255, as
/// libjpeg-turbo computes it; the row is padded to `y.len` with its last
/// pixel's values.
fn rgbToYcc(rgb: []const u8, y: []u8, cb: []u8, cr: []u8, width: usize) void {
    const D = simd.D;
    const k = struct {
        fn v(c: i32) D {
            return @splat(c);
        }
    }.v;
    var x: usize = 0;
    // Eight pixels at a time, bytes 0-15 and 12-27 in the two 128-bit
    // halves, so every byte shuffle stays within a half (x86's pshufb).
    // The weights over 2^15 are split in two or applied by a shift to
    // fit the 16-bit multiply-add.
    while (x + 8 <= width and 3 * x + 32 <= rgb.len) : (x += 8) {
        const v: @Vector(32, u8) = @bitCast(halves(@bitCast(rgb[3 * x ..][0..32].*)));
        const z: @Vector(32, u8) = @splat(0);
        const rg: simd.Y = @bitCast(@shuffle(u8, v, z, spread(&.{ 0, 1 })));
        const bg: simd.Y = @bitCast(@shuffle(u8, v, z, spread(&.{ 2, 1 })));
        // R and B, the first of each pair of 16-bit lanes: the low half.
        const r = @as(D, @bitCast(rg)) & k(0xffff);
        const b = @as(D, @bitCast(bg)) & k(0xffff);
        const yv = (simd.madd(rg, 19595, 22086) + simd.madd(bg, 7471, 16384) + k(32768)) >> @splat(16);
        const cbv = (simd.madd(rg, -11059, -21709) + (b << @splat(15)) + k((128 << 16) + 32767)) >> @splat(16);
        const crv = (simd.madd(bg, -5329, -27439) + (r << @splat(15)) + k((128 << 16) + 32767)) >> @splat(16);
        y[x..][0..8].* = @as(@Vector(8, u8), @intCast(yv));
        cb[x..][0..8].* = @as(@Vector(8, u8), @intCast(cbv));
        cr[x..][0..8].* = @as(@Vector(8, u8), @intCast(crv));
    }
    for (x..width) |i| {
        const r: i32 = rgb[3 * i];
        const g: i32 = rgb[3 * i + 1];
        const b: i32 = rgb[3 * i + 2];
        y[i] = @intCast((19595 * r + 38470 * g + 7471 * b + 32768) >> 16);
        cb[i] = @intCast((-11059 * r - 21709 * g + 32768 * b + (128 << 16) + 32767) >> 16);
        cr[i] = @intCast((32768 * r - 27439 * g - 5329 * b + (128 << 16) + 32767) >> 16);
    }
    @memset(y[width..], y[width - 1]);
    @memset(cb[width..], cb[width - 1]);
    @memset(cr[width..], cr[width - 1]);
}

/// Bytes 0-15 and 12-27 of `w` in its two 128-bit halves. The permute is
/// spelled out on x86, where LLVM otherwise merges it with the byte
/// shuffles after it into three-uop two-table permutes.
inline fn halves(w: @Vector(8, u32)) @Vector(8, u32) {
    const index: @Vector(8, u32) = .{ 0, 1, 2, 3, 3, 4, 5, 6 };
    if (simd.has_avx2) return asm ("vpermd %[w], %[i], %[r]"
        : [r] "=x" (-> @Vector(8, u32)),
        : [w] "x" (w),
          [i] "x" (index),
    );
    return @shuffle(u32, w, undefined, @as(@Vector(8, i32), @bitCast(index)));
}

/// The shuffle mask that spreads four pixels of each 16-byte half into
/// 16-bit lanes, zero-extended: lane `i` of a half takes channel
/// `channels[i % 2]` of pixel `i / 2`. A bit cast to 16-bit lanes takes
/// the even byte as the low one.
fn spread(comptime channels: *const [2]u8) @Vector(32, i32) {
    var m: [32]i32 = undefined;
    for (&m, 0..) |*v, o| {
        const lane = o % 16 / 2;
        v.* = if (o % 2 != 0) -1 else @intCast(o / 16 * 16 + 3 * (lane / 2) + channels[lane % 2]);
    }
    return m;
}

/// Each pair of samples of `a` averaged with the same of `b` below it
/// (4:2:0) or alone (4:2:2, `b` null), rounding alternately down and up
/// as libjpeg-turbo does: a bias of 1 then 2 over four samples, 0 then 1
/// over two.
fn downsample(out: []u8, a: []const u8, b: ?[]const u8) void {
    var x: usize = 0;
    while (x + 16 <= out.len) : (x += 16) downsampleAt(16, out, a, b, x);
    while (x < out.len) : (x += 8) downsampleAt(8, out, a, b, x);
}

inline fn downsampleAt(comptime n: usize, out: []u8, a: []const u8, b: ?[]const u8, x: usize) void {
    const W = @Vector(n, u16);
    // Each u16 lane holds a pair of samples; adding its two bytes gives
    // the pair's sum whichever order the bytes are in.
    const va: W = @bitCast(a[2 * x ..][0 .. 2 * n].*);
    var sum = (va & @as(W, @splat(0xff))) + (va >> @splat(8));
    if (b) |bb| {
        const vb: W = @bitCast(bb[2 * x ..][0 .. 2 * n].*);
        sum += (vb & @as(W, @splat(0xff))) + (vb >> @splat(8));
        out[x..][0..n].* = @as(@Vector(n, u8), @intCast((sum + bias(n, 1, 2)) >> @splat(2)));
    } else {
        out[x..][0..n].* = @as(@Vector(n, u8), @intCast((sum + bias(n, 0, 1)) >> @splat(1)));
    }
}

fn bias(comptime n: usize, comptime even: u16, comptime odd: u16) @Vector(n, u16) {
    var m: [n]u16 = undefined;
    for (&m, 0..) |*v, i| v.* = if (i % 2 == 0) even else odd;
    return m;
}

test "RGB to YCbCr in vectors and the padding agree with the formula" {
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    var rgb: [3 * 70]u8 = undefined;
    var out: [3][80]u8 = undefined;
    for (0..50) |_| {
        r.bytes(&rgb);
        const width = 1 + r.uintLessThan(usize, 70);
        rgbToYcc(&rgb, &out[0], &out[1], &out[2], width);
        for (0..80) |x| {
            const i = @min(x, width - 1);
            const red: i32 = rgb[3 * i];
            const green: i32 = rgb[3 * i + 1];
            const blue: i32 = rgb[3 * i + 2];
            // T.871's equations, rounded to nearest (Cb and Cr a half less).
            const f = struct {
                fn v(c: i32) f64 {
                    return @floatFromInt(c);
                }
            }.v;
            const y = 0.299 * f(red) + 0.587 * f(green) + 0.114 * f(blue);
            try testing.expect(@abs(f(out[0][x]) - y) <= 0.5 + 1e-3);
            const y16 = 19595 * red + 38470 * green + 7471 * blue + 32768;
            const cb16 = -11059 * red - 21709 * green + 32768 * blue + (128 << 16) + 32767;
            const cr16 = 32768 * red - 27439 * green - 5329 * blue + (128 << 16) + 32767;
            try testing.expectEqual(@as(u8, @intCast(y16 >> 16)), out[0][x]);
            try testing.expectEqual(@as(u8, @intCast(cb16 >> 16)), out[1][x]);
            try testing.expectEqual(@as(u8, @intCast(cr16 >> 16)), out[2][x]);
        }
    }
}

test "downsampling alternates its rounding" {
    // 24 outputs: one 16-wide step and one 8-wide.
    var a: [48]u8 = undefined;
    var b: [48]u8 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @intCast(i * 7 % 256);
        y.* = @intCast(i * 13 % 256);
    }
    var out: [24]u8 = undefined;
    downsample(&out, &a, &b);
    for (out, 0..) |o, x| {
        const sum = @as(u32, a[2 * x]) + a[2 * x + 1] + b[2 * x] + b[2 * x + 1];
        try testing.expectEqual(@as(u8, @intCast((sum + 1 + x % 2) >> 2)), o);
    }
    downsample(&out, &a, null);
    for (out, 0..) |o, x| {
        try testing.expectEqual(@as(u8, @intCast((@as(u32, a[2 * x]) + a[2 * x + 1] + x % 2) >> 1)), o);
    }
}
