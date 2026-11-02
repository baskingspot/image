//! PNG against Wuffs, the bar, libpng, and libspng (test/oracle/png.c), in
//! RGBA8 and BGRA16, the 16-bit order Wuffs writes for PNG. All four narrow
//! 16-bit samples to 8 by the high byte (libpng with `png_set_strip_16`).
//!
//! The libraries disagree, and the expected splits are:
//!
//! - An APNG whose default image is not part of the animation (acTL before
//!   IDAT, no fcTL before it): Wuffs and this package decode the
//!   animation's first frame, libpng and libspng the default image, so
//!   their answers are left out. Wuffs rejects such a file when it is
//!   interlaced, so then no answer counts.
//! - Wuffs rejects an interlaced APNG (acTL before IDAT), every one tried,
//!   even a one-frame APNG whose frame is its whole default image, which
//!   it decodes once acTL and fcTL are removed; libpng, libspng, and this
//!   package decode its first frame. Its answer still counts, since it is
//!   the only oracle that checks the APNG chunks of such a file when this
//!   package rejects them.
//! - An fcTL before IDAT whose region is smaller than the canvas: Wuffs
//!   draws only that region of the default image, filled from its
//!   top-left corner, and leaves the rest transparent; libpng, libspng,
//!   and this package decode the whole default image (plan.md decision
//!   59). Wuffs rejects such a region outside the canvas, as this package
//!   does, and libpng and libspng accept it.
//! - Wuffs rejects a malformed fcTL in a file without acTL; libspng and
//!   this package read such a file as a still image and skip the APNG
//!   chunks as unknown ones.
//! - libpng and libspng accept what Wuffs and this package reject: image
//!   data that decompresses to more than the image (libpng warns "Too much
//!   image data"), bytes after the zlib stream in the last IDAT, and a PLTE
//!   in a gray image. Both drop an ancillary chunk with a bad CRC, where
//!   Wuffs and this package do not check ancillary CRCs. Of those chunks
//!   only tRNS changes the pixels, so `adapt` hands every oracle the tRNS
//!   with its CRC made good: libpng and libspng then apply it as Wuffs and
//!   this package do, and their answers still count where Wuffs gives none
//!   (an interlaced APNG, below).
//! - libspng accepts a bad CRC on an IDAT chunk in some files where Wuffs,
//!   libpng, and this package reject it: PngSuite's xcsn0g01 ("incorrect
//!   IDAT checksum") is one, the corpus split.
//! - libpng rejects a chunk type with a byte that is not a letter; Wuffs,
//!   libspng, and this package skip it as an unknown ancillary chunk.
//! - libpng reads to IEND (`png_read_end`) and rejects a file cut after
//!   the image; Wuffs, libspng, and this package return the first frame,
//!   and this package fails only when the next call reads on.
//! - Wuffs reads an interlaced image one row tall only to its last row, so
//!   it accepts image data after it, unchecked, where it rejects it at any
//!   other height. This package does the same (the owner's decision), and
//!   libpng and libspng accept such data at every height, so all four
//!   agree on such a file.
//! - The specification has decoders mask a gray or truecolor tRNS key to
//!   the bit depth, as libpng and this package do; libspng compares it
//!   unmasked and Wuffs rejects it. `adapt` hands every oracle the key
//!   already masked.
//! - Wuffs writes the pixels a gray or truecolor tRNS makes transparent as
//!   transparent black; libpng, libspng, and this package keep their
//!   color. The Wuffs oracle restores the color from a second decode
//!   without tRNS (png.c), so the rest of its decode still counts.

const std = @import("std");
const image = @import("image");

pub const name = "png";
pub const Decoder = image.png.Decoder;
pub const fuzz = @import("fuzz").png;
pub const oracles = [_][]const u8{ "png-wuffs", "png-libpng", "png-spng" };
pub const formats = [_]image.PixelFormat{ .rgba8, .bgra16 };

/// Whether `op`'s answer in `format` counts (see above).
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = format;
    const wuffs = std.mem.eql(u8, op, "png-wuffs");
    if (beforeIdat(input, "acTL") and !beforeIdat(input, "fcTL")) {
        if (!wuffs) return false;
        if (input.len > 28 and input[28] == 1) return false;
    }
    return true;
}

/// Whether `input` has a chunk of type `kind` before its first IDAT.
fn beforeIdat(input: []const u8, kind: *const [4]u8) bool {
    var at: usize = 8;
    while (input.len >= at + 8) {
        const len = std.mem.readInt(u32, input[at..][0..4], .big);
        const this = input[at + 4 ..][0..4];
        if (std.mem.eql(u8, this, "IDAT")) return false;
        if (std.mem.eql(u8, this, kind)) return true;
        at += @as(usize, 12) + len;
    }
    return false;
}

/// `input` with its tRNS before IDAT as this package reads it (see above):
/// a gray or truecolor key masked to the bit depth, and its CRC made good.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    if (input.len < 29) return input;
    const depth = input[24];
    const color = input[25];
    const masked = depth <= 8 and @popCount(depth) == 1 and (color == 0 or color == 2);
    var at: usize = 8;
    while (input.len >= at + 12) {
        const len = std.mem.readInt(u32, input[at..][0..4], .big);
        const kind = input[at + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "IDAT")) return input;
        if (std.mem.eql(u8, kind, "tRNS")) {
            if (len > input.len - at - 12) return input;
            const crc_at = at + 8 + len;
            const out = try arena.dupe(u8, input);
            const body = out[at + 8 ..][0..len];
            var i: usize = 0;
            while (masked and i + 2 <= body.len) : (i += 2) {
                const key = std.mem.readInt(u16, body[i..][0..2], .big);
                std.mem.writeInt(u16, body[i..][0..2], key & ((@as(u16, 1) << @intCast(depth)) - 1), .big);
            }
            const crc = std.hash.Crc32.hash(out[at + 4 .. crc_at]);
            std.mem.writeInt(u32, out[crc_at..][0..4], crc, .big);
            return out;
        }
        at += @as(usize, 12) + len;
    }
    return input;
}

/// `png_hdr`: the HDR chunks (cICP, mDCV, cLLI) this package reports in
/// `Config.metadata` against what libpng (1.6.45 and later) reads before
/// the image data, laid out as a one-row gray8 image of `hdr_len` bytes
/// (test/oracle/png.c). The inputs are the PNG fuzz target's, whose
/// generated files carry the HDR chunks, and half the time a file this
/// package's encoder wrote with random HDR options. Only the metadata is
/// compared: an input counts only when this package reads its header, and
/// libpng's answer only when libpng does (it skips otherwise); the `png`
/// module compares the files themselves. The expected splits:
///
/// - libpng drops a cICP whose matrix is not 0 and an mDCV or cLLI with a
///   value past 2^31 - 1, but counts it as seen, so it drops a valid one
///   after it as a duplicate; this package ignores the broken chunk and
///   reads the next. It also ignores a cICP whose range flag is past 1,
///   which libpng keeps. `adapt` hands libpng every such chunk renamed to
///   an unknown one, which both skip.
/// - libpng drops a color chunk after PLTE; this package reads the HDR
///   chunks up to the image data, as it reads gAMA, cHRM, sRGB, and iCCP.
///   `comparable` leaves out inputs with an HDR chunk after a PLTE.
/// - libpng drops an ancillary chunk with a bad CRC; this package does not
///   check them. `adapt` makes the HDR chunks' CRCs good.
pub const hdr = struct {
    pub const name = "png_hdr";
    pub const Decoder = HdrDecoder;
    pub const oracles = [_][]const u8{"png-libpng-hdr"};
    pub const formats = [_]image.PixelFormat{.gray8};

    /// Whether libpng's answer counts: this package reads the input's
    /// header, and no HDR chunk follows a PLTE.
    pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
        _ = op;
        _ = format;
        var r: std.Io.Reader = .fixed(input);
        var d: HdrDecoder = .init(&r, .{ .limits = .{ .max_pixels = 1 << 22 } });
        _ = d.decodeConfig() catch return false;
        var plte = false;
        var at: usize = 8;
        while (input.len >= at + 8) {
            const len = std.mem.readInt(u32, input[at..][0..4], .big);
            const kind = input[at + 4 ..][0..4];
            if (std.mem.eql(u8, kind, "IDAT")) return true;
            if (std.mem.eql(u8, kind, "PLTE")) plte = true;
            if (plte and hdrChunk(kind)) return false;
            at += @as(usize, 12) + len;
        }
        return true;
    }

    /// `input` with each HDR chunk before IDAT given a good CRC, and each
    /// that this package ignores for its values renamed (see above).
    pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
        _ = op;
        var out: ?[]u8 = null;
        var at: usize = 8;
        while (input.len >= at + 12) {
            const len = std.mem.readInt(u32, input[at..][0..4], .big);
            if (len > input.len - at - 12) break;
            const kind = input[at + 4 ..][0..4];
            if (std.mem.eql(u8, kind, "IDAT")) break;
            if (hdrChunk(kind)) {
                const o = out orelse try arena.dupe(u8, input);
                out = o;
                const body = o[at + 8 ..][0..len];
                const broken = if (std.mem.eql(u8, kind, "cICP"))
                    len == 4 and (body[2] != 0 or body[3] > 1)
                else if (std.mem.eql(u8, kind, "mDCV"))
                    len == 24 and (body[16] >= 0x80 or body[20] >= 0x80)
                else
                    len == 8 and (body[0] >= 0x80 or body[4] >= 0x80);
                if (broken) o[at + 7] = 'x';
                const crc = std.hash.Crc32.hash(o[at + 4 ..][0 .. 4 + len]);
                std.mem.writeInt(u32, o[at + 8 + len ..][0..4], crc, .big);
            }
            at += @as(usize, 12) + len;
        }
        return out orelse input;
    }

    /// The PNG fuzz target's corpus and files, and files this package's
    /// encoder writes. `generate` runs under the comparison's lock, one
    /// input at a time, so its buffers are shared.
    pub const fuzz = struct {
        pub const corpus = png_fuzz.corpus;
        pub const extensions = png_fuzz.extensions;
        var pixels: [16 * 16 * 4]u8 = undefined;
        var work: [1 << 20]u8 = undefined;

        pub fn generate(random: std.Random, buf: []u8) []u8 {
            if (random.boolean()) return png_fuzz.generate(random, buf);
            const w = 1 + random.uintLessThan(u32, 16);
            const h = 1 + random.uintLessThan(u32, 16);
            random.bytes(pixels[0 .. w * h * 4]);
            const src = image.PixelBuffer.init(pixels[0 .. w * h * 4], .rgba8, w, h) catch unreachable;
            var options: image.png.EncodeOptions = .{ .effort = .fast };
            if (random.boolean()) options.cicp = .{
                .primaries = random.int(u8),
                .transfer = random.int(u8),
                .matrix = 0,
                .full_range = random.boolean(),
            };
            if (random.boolean()) {
                var p: [8]f32 = undefined;
                for (&p) |*x| x.* = random.float(f32) * 1.3;
                options.mastering_display = .{
                    .primaries = p,
                    .min_luminance = random.float(f32) * 10,
                    .max_luminance = random.float(f32) * 200_000,
                };
            }
            if (random.boolean()) options.content_light_level = .{
                .max_cll = random.float(f32) * 200_000,
                .max_fall = random.float(f32) * 200_000,
            };
            var out: std.Io.Writer = .fixed(buf);
            const work_len = image.png.workLen(options, w, h).?;
            image.png.encode(&out, src, options, work[0..work_len]) catch |e|
                std.debug.panic("png_hdr oracle: encode failed: {t}", .{e});
            return out.buffered();
        }
    };
};

const png_fuzz = @import("fuzz").png;

fn hdrChunk(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "cICP") or std.mem.eql(u8, kind, "mDCV") or std.mem.eql(u8, kind, "cLLI");
}

/// The bytes of `hdr`'s record (see png.c).
const hdr_len = 53;

/// The PNG `Decoder` whose one frame is `Config.metadata`'s HDR fields
/// as `hdr`'s record, one gray8 row.
const HdrDecoder = struct {
    d: Decoder,

    pub const Options = Decoder.Options;
    pub const Error = Decoder.Error;

    pub fn init(reader: *std.Io.Reader, options: Options) HdrDecoder {
        return .{ .d = .init(reader, options) };
    }

    pub fn decodeConfig(h: *HdrDecoder) Error!image.Config {
        const c = try h.d.decodeConfig();
        return .{ .width = hdr_len, .height = 1, .native = .gray8, .metadata = c.metadata };
    }

    pub fn decodeFrame(h: *HdrDecoder, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        _ = work;
        const m = (try h.decodeConfig()).metadata;
        var rec: [hdr_len]u8 = @splat(0);
        var f: [12]f32 = @splat(0);
        if (m.cicp) |c| {
            rec[0] |= 1;
            rec[1..5].* = .{ c.primaries, c.transfer, c.matrix, @intFromBool(c.full_range) };
        }
        if (m.mastering_display) |md| {
            rec[0] |= 2;
            f[0..8].* = md.primaries;
            f[8] = md.min_luminance;
            f[9] = md.max_luminance;
        }
        if (m.content_light_level) |l| {
            rec[0] |= 4;
            f[10] = l.max_cll;
            f[11] = l.max_fall;
        }
        @memcpy(rec[5..], std.mem.asBytes(&f));
        @memcpy(dst.pixels[0..hdr_len], &rec);
        return .{ .width = hdr_len, .height = 1 };
    }
};
