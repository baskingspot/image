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
//! - Wuffs rejects a malformed fcTL in a file without acTL; libspng and
//!   this package read such a file as a still image and skip the APNG
//!   chunks as unknown ones.
//! - libpng and libspng accept what Wuffs and this package reject: image
//!   data that decompresses to more than the image (libpng warns "Too much
//!   image data"), bytes after the zlib stream in the last IDAT, and a PLTE
//!   in a gray image. Both drop an ancillary chunk with a bad CRC, tRNS
//!   included, where Wuffs and this package do not check ancillary CRCs.
//! - libspng accepts a bad CRC on an IDAT chunk in some files where Wuffs,
//!   libpng, and this package reject it: PngSuite's xcsn0g01 ("incorrect
//!   IDAT checksum") is one, the corpus split.
//! - libpng rejects a chunk type with a byte that is not a letter; Wuffs,
//!   libspng, and this package skip it as an unknown ancillary chunk.
//! - libpng reads to IEND (`png_read_end`) and rejects a file cut after
//!   the image; Wuffs, libspng, and this package return the first frame,
//!   and this package fails only when the next call reads on.
//! - Wuffs does not check for image data after the last row of an
//!   interlaced image one row tall (it rejects it at any other height), and
//!   libpng and libspng never check; this package rejects it at every
//!   height, so no answer counts for such a file.
//! - The specification has decoders mask a gray or truecolor tRNS key to
//!   the bit depth, as libpng and this package do; libspng compares it
//!   unmasked and Wuffs rejects it. `adapt` hands both the key already
//!   masked (a good CRC rewritten to match).
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
    if (oneRowTooMuch(input)) return false;
    return true;
}

var row_pixels: [4 << 16]u8 = undefined;
var work: [1 << 20]u8 = undefined;

/// Whether `input` is an interlaced image one row tall that this package
/// rejects with `TooMuchData`.
fn oneRowTooMuch(input: []const u8) bool {
    if (input.len < 29 or input[28] != 1 or std.mem.readInt(u32, input[20..24], .big) != 1) return false;
    var r: std.Io.Reader = .fixed(input);
    var d: Decoder = .init(&r, .{});
    const c = d.decodeConfig() catch return false;
    if (c.work_len > work.len) return false;
    const dst = image.PixelBuffer.init(&row_pixels, .rgba8, c.width, c.height) catch return false;
    _ = d.decodeFrame(dst, work[0..c.work_len]) catch |e| return e == error.TooMuchData;
    return false;
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

/// For libspng and Wuffs, `input` with a gray or truecolor tRNS key before
/// IDAT masked to the bit depth (see above).
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (std.mem.eql(u8, op, "png-libpng") or input.len < 29) return input;
    const depth = input[24];
    const color = input[25];
    if (depth > 8 or @popCount(depth) != 1 or (color != 0 and color != 2)) return input;
    var at: usize = 8;
    while (input.len >= at + 12) {
        const len = std.mem.readInt(u32, input[at..][0..4], .big);
        const kind = input[at + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "IDAT")) return input;
        if (std.mem.eql(u8, kind, "tRNS")) {
            if (len > input.len - at - 12) return input;
            const crc_at = at + 8 + len;
            const Crc = std.hash.Crc32;
            const crc = std.mem.readInt(u32, input[crc_at..][0..4], .big) == Crc.hash(input[at + 4 .. crc_at]);
            const out = try arena.dupe(u8, input);
            const body = out[at + 8 ..][0..len];
            var i: usize = 0;
            while (i + 2 <= body.len) : (i += 2) {
                const key = std.mem.readInt(u16, body[i..][0..2], .big);
                std.mem.writeInt(u16, body[i..][0..2], key & ((@as(u16, 1) << @intCast(depth)) - 1), .big);
            }
            // A bad CRC stays bad: libspng drops the chunk then.
            if (crc) std.mem.writeInt(u32, out[crc_at..][0..4], Crc.hash(out[at + 4 .. crc_at]), .big);
            return out;
        }
        at += @as(usize, 12) + len;
    }
    return input;
}
