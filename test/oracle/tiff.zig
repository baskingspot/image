//! TIFF against libtiff (test/oracle/tiff.c): its RGBA interface, in RGBA8
//! premultiplied, and its decompression with this package's sample rules,
//! in the native format. Both decode the first page, with a seeker over
//! the input; this decoder has `max_frames` 1, so its canvas is the first
//! page's and later IFDs do not fail `decodeConfig`. Later pages are the
//! fuzz harness's and the unit tests'.
//!
//! `comparable` leaves out both answers for a first page with:
//!
//! - a compression out of this decoder's scope, which libtiff reads and
//!   this decoder rejects as unsupported: old-style JPEG (6), LogLuv,
//!   JBIG, WebP, ZSTD, LZMA, and the rest.
//! - an entry of a type the specification does not define: libtiff refuses
//!   some fields of unknown type and reads past others, by rules of its own.
//! - a sample range field (Min, Max, SMin, SMaxSampleValue) without one
//!   numeric value per sample in the input: libtiff refuses the file, and
//!   this decoder does not read those fields.
//! - strip or tile offsets and byte counts of different lengths, or of a
//!   type other than SHORT, LONG, or LONG8: libtiff reads some with a
//!   warning, and this decoder refuses them as the specification has it.
//! - YCbCr with YCbCrCoefficients or ReferenceBlackWhite: libtiff ignores
//!   malformed ones that this decoder reads, and tiff-raw evaluates the
//!   equations only with the defaults. Chunky YCbCr JPEG data is the
//!   exception, which libjpeg converts with its own equations, ignoring
//!   both fields, as this decoder does.
//!
//! JPEG data is libjpeg-turbo's under libtiff, which conceals corrupt
//! data; tiff.c decodes each strip or tile strictly first, and rejects the
//! page if one fails, or skips it if one has more than one scan, which
//! this decoder does not read.
//!
//! The C side answers SKIPPED (the file says nothing about the decoder)
//! when libtiff replaces the byte counts with its own estimate, when a
//! Deflate chunk holds more than its rows or is corrupt only near their
//! end (libtiff with libdeflate then stops early and may leave bytes
//! unwritten), and, for the RGBA interface, when it declines the page or
//! fails one that tiff-raw reads.
//!
//! libtiff's RGBA interface is a second reference only where its
//! conversion is the decoder's; `comparable` also leaves its answer out
//! for:
//!
//! - photometric interpretations other than gray, palette, RGB, and
//!   chunky YCbCr JPEG data, which libjpeg converts for both. Its
//!   CMYK to RGB truncates, and `image.convert` rounds, as libjpeg-turbo
//!   does; tiff-raw compares CMYK natively, in `cmyk8` or `cmyk16`.
//! - what the interface does not read: sample widths other than 1, 2, 4,
//!   8, and 16 bits for gray and palette, and 8 bits for RGB, and signed
//!   and float samples.
//! - 16-bit RGB, which libtiff narrows to 8 bits with rounding;
//!   `image.convert` takes the high byte, as Wuffs does. tiff-raw compares
//!   those at 16 bits.
//! - YCbCr, which libtiff converts with its own fixed-point tables; this
//!   decoder evaluates the specification's equations in floating point,
//!   and the results differ by 1 in a few percent of samples. tiff-raw
//!   compares it with the decoder's equations.
//! - unassociated alpha, which libtiff premultiplies with its own rounding,
//!   and extra samples of unspecified meaning, which libtiff may take as
//!   alpha and this decoder ignores.
//! - gray with extra samples but for 8-bit black-is-zero gray with one
//!   alpha in strips: libtiff's interface drops the alpha of the others,
//!   does not invert premultiplied white-is-zero gray, and misplaces gray
//!   and alpha in a tile cut off by the image's right edge.
//! - tiles whose width or length is not a multiple of 16, which the
//!   specification requires and libtiff warns about: its interface misplaces
//!   the samples of a sub-byte tile row that ends inside a byte.
//! - a color map whose every entry is below 256, which libtiff takes as an
//!   8-bit map from old writers; this decoder reads every map as 16-bit, as
//!   the specification has it.
//!
//! No file is listed as failing: at 100000 fuzzed inputs every comparable
//! answer agrees.

const std = @import("std");
const image = @import("image");

pub const name = "tiff";
pub const Decoder = FirstPage;
pub const fuzz = @import("fuzz").tiff;
pub const oracles = [_][]const u8{ "tiff-rgba", "tiff-raw" };
/// RGBA8 premultiplied for the RGBA interface, and every native format.
pub const formats = [_]image.PixelFormat{
    .rgba8_premul, .gray8,  .gray16, .gray_alpha8, .gray_alpha16,  .gray_alpha8_premul, .gray_alpha16_premul,
    .rgb8,         .rgb16,  .rgba8,  .rgba16,      .rgba16_premul, .rgba_f32,           .rgba_f32_premul,
    .cmyk8,        .cmyk16,
};

pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = format;
    const p = firstPage(input) orelse return true;
    switch (p.compression) {
        1, 2, 3, 4, 5, 7, 8, 32946, 32773 => {},
        else => return false,
    }
    if (p.unknown_type or p.odd_sample_range) return false;
    if (p.offsets_count != p.counts_count or p.odd_array_type) return false;
    // libjpeg converts chunky YCbCr JPEG data with its own equations.
    const jpeg_ycc = p.compression == 7 and p.photometric == 6 and p.planar != 2;
    if (p.photometric == 6 and p.ycc_fields and !jpeg_ycc) return false;
    if (!std.mem.eql(u8, op, "tiff-rgba")) return true;
    switch (p.photometric) {
        0, 1, 2, 3 => {},
        6 => if (!jpeg_ycc) return false,
        else => return false,
    }
    if (p.format != 1) return false;
    switch (p.photometric) {
        2, 6 => if (p.bits != 8) return false,
        else => switch (p.bits) {
            1, 2, 4, 8, 16 => {},
            else => return false,
        },
    }
    const color: u16 = if (p.photometric == 2 or p.photometric == 6) 3 else 1;
    if (p.spp > color and p.extra != 1) return false;
    const gray_alpha_ok = p.bits == 8 and p.spp == 2 and p.photometric == 1 and p.tile_w == 0;
    if (p.spp > 1 and p.photometric <= 1 and !gray_alpha_ok) return false;
    if (p.tile_w % 16 != 0 or p.tile_h % 16 != 0) return false;
    if (p.photometric == 3 and p.small_map) return false;
    return true;
}

/// The decoder on the first page alone, with a seeker over the input.
const FirstPage = struct {
    inner: image.tiff.Decoder,

    pub const Options = image.DecodeOptions;
    pub const Error = image.tiff.Decoder.Error;

    pub fn init(r: *std.Io.Reader, options: Options) FirstPage {
        var limits = options.limits;
        limits.max_frames = 1;
        // Work memory up to libtiff's single allocation limit in tiff.c: a
        // page past it (one with tens of thousands of samples per pixel,
        // say) both refuse, and the harness does not hold hundreds of
        // megabytes per answer.
        limits.max_work = @min(limits.max_work, 1 << 28);
        return .{ .inner = .init(r, .{
            .limits = limits,
            .blob_sink = options.blob_sink,
            .seeker = .fixed(r),
        }) };
    }

    pub fn decodeConfig(d: *FirstPage) Error!image.Config {
        return d.inner.decodeConfig();
    }

    pub fn decodeFrame(d: *FirstPage, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        return d.inner.decodeFrame(dst, work);
    }
};

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}

const Page = struct {
    compression: u64 = 1,
    photometric: u64 = 99,
    bits: u64 = 1,
    spp: u64 = 1,
    extra: u64 = 0,
    format: u64 = 1,
    small_map: bool = false,
    tile_w: u64 = 0,
    tile_h: u64 = 0,
    /// An entry of a type the specification does not define.
    unknown_type: bool = false,
    /// A sample range field (Min, Max, SMin, SMaxSampleValue) without one
    /// numeric value per sample in the input.
    odd_sample_range: bool = false,
    offsets_count: u64 = 0,
    counts_count: u64 = 0,
    /// Offsets or byte counts of a type other than SHORT, LONG, and LONG8.
    odd_array_type: bool = false,
    /// YCbCrCoefficients or ReferenceBlackWhite, of any type.
    ycc_fields: bool = false,
    planar: u64 = 1,
};

/// The first IFD's fields `comparable` needs, or null if it cannot be read.
fn firstPage(in: []const u8) ?Page {
    if (in.len < 8) return null;
    const e: std.builtin.Endian = if (in[0] == 'I') .little else .big;
    const big = std.mem.readInt(u16, in[2..4], e) == 43;
    if (big and in.len < 16) return null;
    const off = if (big) std.mem.readInt(u64, in[8..16], e) else std.mem.readInt(u32, in[4..8], e);
    const head: u64 = if (big) 8 else 2;
    if (off > in.len or in.len - off < head) return null;
    const at: usize = @intCast(off);
    const n = if (big) std.mem.readInt(u64, in[at..][0..8], e) else std.mem.readInt(u16, in[at..][0..2], e);
    const size: u64 = if (big) 20 else 12;
    var p: Page = .{};
    var ranges: [4]?u64 = @splat(null);
    // libtiff keeps a tag's first entry and ignores the rest.
    var seen: std.StaticBitSet(1 << 16) = .initEmpty();
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const ent = off + head + i * size;
        if (ent + size > in.len) return null;
        const b = in[@intCast(ent)..][0..@intCast(size)];
        const tag = std.mem.readInt(u16, b[0..2], e);
        const t = std.mem.readInt(u16, b[2..4], e);
        const count = if (big) std.mem.readInt(u64, b[4..12], e) else std.mem.readInt(u32, b[4..8], e);
        if (seen.isSet(tag)) continue;
        seen.set(tag);
        const vb = if (big) b[12..20] else b[8..12];
        const tsize: u64 = switch (t) {
            1, 2, 6, 7 => 1,
            3, 8 => 2,
            4, 9, 11, 13 => 4,
            5, 10, 12, 16, 17, 18 => 8,
            else => {
                p.unknown_type = true;
                continue;
            },
        };
        switch (tag) {
            529, 532 => p.ycc_fields = true,
            273, 324, 279, 325 => {
                if (tag == 273 or tag == 324) p.offsets_count = count else p.counts_count = count;
                if (t != 3 and t != 4 and t != 16) p.odd_array_type = true;
            },
            280, 281, 340, 341 => {
                ranges[if (tag < 300) tag - 280 else tag - 338] = count;
                // libtiff reads Min and MaxSampleValue as SHORTs and the
                // SMin and SMax as DOUBLEs.
                switch (t) {
                    1, 3, 4, 6, 8, 9, 16, 17 => {},
                    5, 10, 11, 12 => if (tag < 300) {
                        p.odd_sample_range = true;
                    },
                    else => p.odd_sample_range = true,
                }
            },
            else => {},
        }
        const value = std.math.mul(u64, tsize, count) catch std.math.maxInt(u64);
        const data: []const u8 = if (value <= vb.len) vb else blk: {
            const o = if (big) std.mem.readInt(u64, vb[0..8], e) else std.mem.readInt(u32, vb[0..4], e);
            if (o > in.len or in.len - o < value) {
                if (tag == 280 or tag == 281 or tag == 340 or tag == 341) p.odd_sample_range = true;
                continue;
            }
            break :blk in[@intCast(o)..][0..@intCast(value)];
        };
        const first: u64 = if (count == 0) 0 else valueAt(t, data, 0, e);
        switch (tag) {
            258 => p.bits = first,
            259 => p.compression = first,
            // libtiff ignores a count other than 1, and a type other than
            // the integer ones.
            262 => switch (t) {
                1, 3, 4, 6, 8, 9, 16, 17 => if (count == 1) {
                    p.photometric = first;
                },
                else => {},
            },
            277 => p.spp = first,
            284 => p.planar = first,
            338 => p.extra = first,
            322 => p.tile_w = first,
            323 => p.tile_h = first,
            339 => p.format = if (first == 4) 1 else first,
            320 => {
                p.small_map = true;
                for (0..@intCast(count)) |k| {
                    if (valueAt(t, data, k, e) >= 256) p.small_map = false;
                }
            },
            else => {},
        }
    }
    checkRanges(&p, ranges);
    return p;
}

/// Value `k` of type `t` in `data`, unsigned.
fn valueAt(t: u16, data: []const u8, k: usize, e: std.builtin.Endian) u64 {
    return switch (t) {
        3, 8 => std.mem.readInt(u16, data[2 * k ..][0..2], e),
        4, 9 => std.mem.readInt(u32, data[4 * k ..][0..4], e),
        16, 17 => std.mem.readInt(u64, data[8 * k ..][0..8], e),
        else => data[k],
    };
}

/// The counts of the sample range fields, checked against
/// SamplesPerPixel once the whole IFD is read.
fn checkRanges(p: *Page, counts: [4]?u64) void {
    for (counts) |c| if (c != null and c != p.spp) {
        p.odd_sample_range = true;
    };
}
