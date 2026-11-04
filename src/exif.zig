//! The one EXIF field every viewer needs: orientation. Decoders that meet
//! EXIF (PNG eXIf, JPEG APP1, WebP EXIF, JPEG XL Exif, TIFF itself) report
//! it in `Metadata.orientation` with this.

const std = @import("std");
const testing = std.testing;

const Orientation = @import("decode.zig").Orientation;

/// The orientation tag's value from EXIF data: a TIFF header and IFD0,
/// optionally after JPEG's `Exif\0\0` prefix. Null when the data is
/// malformed or IFD0 has no valid orientation. IFD0 must lie within `exif`;
/// a decoder streaming EXIF can pass the blob's first few KiB, since IFD0
/// almost always follows the header.
pub fn orientation(exif: []const u8) ?Orientation {
    const tiff = if (std.mem.startsWith(u8, exif, "Exif\x00\x00")) exif[6..] else exif;
    if (tiff.len < 8) return null;
    const endian: std.lang.Endian = if (std.mem.eql(u8, tiff[0..4], "II*\x00"))
        .little
    else if (std.mem.eql(u8, tiff[0..4], "MM\x00*"))
        .big
    else
        return null;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd > tiff.len or tiff.len - ifd < 2) return null;
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    var entries = tiff[ifd + 2 ..];
    for (0..count) |_| {
        if (entries.len < 12) return null;
        const tag = std.mem.readInt(u16, entries[0..2], endian);
        const kind = std.mem.readInt(u16, entries[2..4], endian);
        const n = std.mem.readInt(u32, entries[4..8], endian);
        // SHORT, one value, stored in the first two bytes of the field.
        if (tag == 0x0112) {
            if (kind != 3 or n != 1) return null;
            return Orientation.fromExif(std.mem.readInt(u16, entries[8..10], endian));
        }
        entries = entries[12..];
    }
    return null;
}

test orientation {
    // Little endian: one other entry, then orientation 6.
    const le = "II*\x00\x08\x00\x00\x00" ++ "\x02\x00" ++
        "\x0f\x01\x02\x00\x04\x00\x00\x00abc\x00" ++
        "\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00";
    try testing.expectEqual(Orientation.right_top, orientation(le).?);
    try testing.expectEqual(Orientation.right_top, orientation("Exif\x00\x00" ++ le).?);
    const be = "MM\x00*\x00\x00\x00\x08" ++ "\x00\x01" ++ "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x03\x00\x00";
    try testing.expectEqual(Orientation.bottom_right, orientation(be).?);
    // Malformed: truncated entries, bad offsets, out-of-range values,
    // wrong types, and every prefix of a good one.
    for (0..le.len) |n| try testing.expectEqual(null, orientation(le[0..n]));
    try testing.expectEqual(null, orientation("II*\x00\xff\xff\xff\xff"));
    const one = "MM\x00*\x00\x00\x00\x08\x00\x01\x01\x12";
    try testing.expectEqual(null, orientation(one ++ "\x00\x03\x00\x00\x00\x01\x00\x09\x00\x00"));
    try testing.expectEqual(null, orientation(one ++ "\x00\x04\x00\x00\x00\x01\x00\x00\x00\x03"));
    try testing.expectEqual(null, orientation("MM\x00*\x00\x00\x00\x08\xff\xff"));
}
