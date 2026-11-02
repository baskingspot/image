//! TIFF against libtiff (test/oracle/tiff.c): its RGBA interface, in RGBA8
//! premultiplied, and its decompression with this package's sample rules,
//! in the native format. Both decode the first page, with a seeker over
//! the input. This decoder reads a copy of the input whose first IFD has no
//! next IFD, so it decodes the first page alone too: with the whole chain,
//! its canvas is as large as the largest page, and an error in a later
//! page's IFD is an error in `decodeConfig`. Later pages are the fuzz
//! harness's and the unit tests'.
//!
//! `comparable` leaves out both answers for a first page with:
//!
//! - a compression out of this decoder's scope, which libtiff reads and
//!   this decoder rejects as unsupported: old-style JPEG (6), LogLuv,
//!   JBIG, WebP, ZSTD, LZMA, and the rest. JPEG (7) waits for `image.jpeg`.
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
//!   equations only with the defaults.
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
//! - photometric interpretations other than gray, palette, and RGB. Its
//!   CMYK to RGB truncates, and `image.convert` rounds, as libjpeg-turbo
//!   does; tiff-raw compares CMYK through `image.convert`'s rule. The oracle
//!   protocol has no `cmyk8` or `cmyk16` (test/oracle/oracle.h), so tiff-raw
//!   answers CMYK as `rgb8` or `rgb16`, the color the decoder's native inks
//!   convert to.
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
    .rgba8_premul, .gray8, .gray16, .gray_alpha8, .gray_alpha16,  .gray_alpha8_premul, .gray_alpha16_premul,
    .rgb8,         .rgb16, .rgba8,  .rgba16,      .rgba16_premul, .rgba_f32,           .rgba_f32_premul,
};

pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = format;
    const p = firstPage(input) orelse return true;
    switch (p.compression) {
        1, 2, 3, 4, 5, 8, 32946, 32773 => {},
        else => return false,
    }
    if (p.unknown_type or p.odd_sample_range) return false;
    if (p.offsets_count != p.counts_count or p.odd_array_type) return false;
    if (p.photometric == 6 and p.ycc_fields) return false;
    if (!std.mem.eql(u8, op, "tiff-rgba")) return true;
    switch (p.photometric) {
        0, 1, 2, 3 => {},
        else => return false,
    }
    if (p.format != 1) return false;
    switch (p.photometric) {
        2 => if (p.bits != 8) return false,
        else => switch (p.bits) {
            1, 2, 4, 8, 16 => {},
            else => return false,
        },
    }
    const color: u16 = if (p.photometric == 2) 3 else 1;
    if (p.spp > color and p.extra != 1) return false;
    const gray_alpha_ok = p.bits == 8 and p.spp == 2 and p.photometric == 1 and p.tile_w == 0;
    if (p.spp > 1 and p.photometric <= 1 and !gray_alpha_ok) return false;
    if (p.tile_w % 16 != 0 or p.tile_h % 16 != 0) return false;
    if (p.photometric == 3 and p.small_map) return false;
    return true;
}

/// The decoder over a copy of the input that ends the IFD chain after the
/// first IFD, with a seeker over the copy. The copy and its reader are
/// per thread, since batches run on every core.
const FirstPage = struct {
    inner: image.tiff.Decoder,

    pub const Options = image.DecodeOptions;
    pub const Error = image.tiff.Decoder.Error;

    threadlocal var copy: std.ArrayList(u8) = .empty;
    threadlocal var reader: std.Io.Reader = undefined;

    pub fn init(r: *std.Io.Reader, options: Options) FirstPage {
        const in = r.buffered();
        copy.clearRetainingCapacity();
        copy.appendSlice(std.heap.page_allocator, in) catch @panic("out of memory");
        endChain(copy.items);
        reader = .fixed(copy.items);
        return .{ .inner = .init(&reader, .{
            .limits = options.limits,
            .blob_sink = options.blob_sink,
            .seeker = .fixed(&reader),
        }) };
    }

    pub fn decodeConfig(d: *FirstPage) Error!image.Config {
        return d.inner.decodeConfig();
    }

    pub fn decodeFrame(d: *FirstPage, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        return d.inner.decodeFrame(dst, work);
    }
};

/// Zeroes the first IFD's next-IFD offset, where it is inside `in`.
fn endChain(in: []u8) void {
    if (in.len < 8) return;
    const e: std.builtin.Endian = if (in[0] == 'I') .little else .big;
    const big = std.mem.readInt(u16, in[2..4], e) == 43;
    if (big and in.len < 16) return;
    const off = if (big) std.mem.readInt(u64, in[8..16], e) else std.mem.readInt(u32, in[4..8], e);
    const head: u64 = if (big) 8 else 2;
    if (off > in.len or in.len - off < head) return;
    const at: usize = @intCast(off);
    const n = if (big) std.mem.readInt(u64, in[at..][0..8], e) else std.mem.readInt(u16, in[at..][0..2], e);
    const next = std.math.add(u64, off + head, std.math.mul(u64, n, if (big) 20 else 12) catch return) catch return;
    const len: u64 = if (big) 8 else 4;
    if (next > in.len or in.len - next < len) return;
    @memset(in[@intCast(next)..][0..@intCast(len)], 0);
}

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
    var ranges: [4]u64 = @splat(0);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const ent = off + head + i * size;
        if (ent + size > in.len) return null;
        const b = in[@intCast(ent)..][0..@intCast(size)];
        const tag = std.mem.readInt(u16, b[0..2], e);
        const t = std.mem.readInt(u16, b[2..4], e);
        const count = if (big) std.mem.readInt(u64, b[4..12], e) else std.mem.readInt(u32, b[4..8], e);
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
                switch (t) {
                    1, 3, 4, 5, 6, 8, 9, 10, 11, 12, 16, 17 => {},
                    else => p.odd_sample_range = true,
                }
            },
            else => {},
        }
        const value = std.math.mul(u64, tsize, count) catch return null;
        const data: []const u8 = if (value <= vb.len) vb else blk: {
            const o = if (big) std.mem.readInt(u64, vb[0..8], e) else std.mem.readInt(u32, vb[0..4], e);
            if (o > in.len or in.len - o < value) {
                if (tag == 280 or tag == 281 or tag == 340 or tag == 341) p.odd_sample_range = true;
                continue;
            }
            break :blk in[@intCast(o)..][0..@intCast(value)];
        };
        const first: u64 = if (count == 0) 0 else switch (t) {
            3 => std.mem.readInt(u16, data[0..2], e),
            4 => std.mem.readInt(u32, data[0..4], e),
            16 => std.mem.readInt(u64, data[0..8], e),
            else => data[0],
        };
        switch (tag) {
            258 => p.bits = first,
            259 => p.compression = first,
            262 => p.photometric = first,
            277 => p.spp = first,
            338 => p.extra = first,
            322 => p.tile_w = first,
            323 => p.tile_h = first,
            339 => p.format = if (first == 4) 1 else first,
            320 => if (t == 3) {
                p.small_map = true;
                for (0..@intCast(count)) |k| {
                    if (std.mem.readInt(u16, data[2 * k ..][0..2], e) >= 256) p.small_map = false;
                }
            },
            else => {},
        }
    }
    checkRanges(&p, ranges);
    return p;
}

/// The counts of the sample range fields, checked against
/// SamplesPerPixel once the whole IFD is read.
fn checkRanges(p: *Page, counts: [4]u64) void {
    for (counts) |c| if (c != 0 and c != p.spp) {
        p.odd_sample_range = true;
    };
}
