//! ICO and CUR against ImageMagick (test/oracle/ico.c), the only reference
//! library that reads them, on the first entry: Magick's first image.
//!
//! Magick and this package compare entry 0 alone, and Magick reads some
//! fields its own way, so:
//!
//! - Magick reads every entry and rejects the whole file when any is bad;
//!   this package, asked for one entry, reads only that entry. `adapt`
//!   hands Magick the file with its count set to 1, which leaves entry 0's
//!   directory record and data where they were.
//! - Magick takes an entry as PNG when its bytes 1 to 3 are "PNG",
//!   whatever byte 0 is; this package needs the whole eight-byte signature.
//!   Until `image.png` lands this package rejects PNG entries, so
//!   `comparable` leaves out Magick's answer for any entry Magick reads as
//!   PNG, and afterwards for one whose signature is not exact.
//! - Magick reads 40 header bytes whatever biSize says, and the color table
//!   right after them, and ignores biCompression; this package takes the
//!   uncompressed BITMAPINFOHEADER the format names and rejects any other
//!   size or compression. Magick takes the directory's size for a biWidth
//!   or biHeight of 0; this package takes an entry's size from its own
//!   header alone and rejects a zero. `comparable` leaves out Magick's answer for
//!   these.
//! - Magick rejects an entry whose directory size runs past the end of the
//!   file; this package reads forward without knowing the file's size and
//!   takes an entry's extent from its own header. `adapt` cuts the size to
//!   the end of the file.
//! - Magick reads entry data that starts inside the directory, which this
//!   package rejects. `comparable` leaves out Magick's answer for it.
//! - A color table has biClrUsed entries. Below 2^bits it can leave
//!   indices past the table, which Magick reports as corrupt (the oracle
//!   rejects on any exception) and this package paints opaque black, the
//!   rule Wuffs uses for BMP, since ICO's DIBs go through BMP's reader.
//!   Above 256 Magick reads 256 entries and takes the rest as pixels, or
//!   rejects the entry at 24 and 32 bits; this package keeps 256 and skips
//!   the rest. `comparable` leaves out both.
//! - A 32-bit entry's alpha replaces its AND mask, so this package does not
//!   read the mask; Magick reads it and rejects one cut short. `adapt`
//!   pads a 32-bit entry 0 cut short within its mask with zeros.

const std = @import("std");
const image = @import("image");

pub const name = "ico";
pub const Decoder = @import("fuzz").ico.FirstEntry;
pub const fuzz = @import("fuzz").ico;
pub const oracles = [_][]const u8{"ico-magick"};
pub const formats = [_]image.PixelFormat{ .rgba8, .bgra8 };

/// Whether Magick's answer counts: not for the entries the file comment
/// lists.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = op;
    _ = format;
    const data = entry0(input) orelse return true;
    const count = std.mem.readInt(u16, input[4..6], .little);
    if (input.len - data.len < 6 + 16 * @as(u32, count)) return false;
    if (data.len < 4) return true;
    if (std.mem.eql(u8, data[1..4], "PNG")) return @hasDecl(image, "png") and data[0] == 0x89;
    if (std.mem.readInt(u32, data[0..4], .little) != 40) return false;
    if (data.len < 20) return true;
    if (std.mem.readInt(u32, data[4..8], .little) == 0) return false;
    if (std.mem.readInt(u32, data[8..12], .little) == 0) return false;
    if (std.mem.readInt(u32, data[16..20], .little) != 0) return false;
    if (data.len < 36) return true;
    const bits = std.mem.readInt(u16, data[14..16], .little);
    const used = std.mem.readInt(u32, data[32..36], .little);
    return used <= 256 and !(bits <= 8 and used != 0 and used < @as(u32, 1) << @intCast(bits));
}

/// The input Magick sees: the file with entry 0 alone, its directory size
/// cut to the end of the file, and a 32-bit entry 0's mask padded out.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    if (entry0(input) == null) return input;
    const copy = try arena.alloc(u8, @max(maskEnd(input) orelse 0, input.len));
    @memcpy(copy[0..input.len], input);
    @memset(copy[input.len..], 0);
    std.mem.writeInt(u16, copy[4..6], @min(1, std.mem.readInt(u16, copy[4..6], .little)), .little);
    const left: u32 = @intCast(copy.len - std.mem.readInt(u32, copy[18..22], .little));
    std.mem.writeInt(u32, copy[14..18], @min(left, std.mem.readInt(u32, copy[14..18], .little)), .little);
    return copy;
}

/// Entry 0's data, when its offset is inside the file.
fn entry0(input: []const u8) ?[]const u8 {
    if (input.len < 22) return null;
    const offset = std.mem.readInt(u32, input[18..22], .little);
    if (offset > input.len) return null;
    return input[offset..];
}

/// Where a 32-bit entry 0's mask ends, when its pixels are whole and its
/// mask is cut short.
fn maskEnd(input: []const u8) ?usize {
    const data = entry0(input) orelse return null;
    if (data.len < 40 or std.mem.readInt(u32, data[0..4], .little) != 40) return null;
    if (std.mem.readInt(u16, data[14..16], .little) != 32) return null;
    const width = std.mem.readInt(i32, data[4..8], .little);
    const height = @divTrunc(std.mem.readInt(i32, data[8..12], .little), 2);
    const used = std.mem.readInt(u32, data[32..36], .little);
    if (width <= 0 or height <= 0 or used > 1 << 16) return null;
    const w: u64 = @intCast(width);
    const h: u64 = @intCast(height);
    if (w * h > 1 << 22) return null;
    const pixels_end = 40 + 4 * @as(u64, used) + 4 * w * h;
    const mask_end = pixels_end + (w + 31) / 32 * 4 * h;
    if (data.len < pixels_end or data.len >= mask_end) return null;
    return input.len - data.len + @as(usize, @intCast(mask_end));
}
