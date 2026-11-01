//! Format detection from a file's first bytes.

const std = @import("std");
const testing = std.testing;

/// Every phase-1 format. Detection knows all of them, whether or not this
/// build has a decoder for one yet (`image.Decoder.supports`).
pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,
    tiff,
    jxl,
    bmp,
    ico,
    cur,
    tga,
    netpbm,
    wbmp,
    qoi,

    /// The package namespace that decodes this format: `cur` is `ico`'s.
    pub fn namespace(f: Format) []const u8 {
        return switch (f) {
            .cur => "ico",
            else => @tagName(f),
        };
    }
};

/// How many leading bytes `detect` reads at most. Fewer is fine for a short
/// file.
pub const prefix_len = 18;

/// The format of a file starting with `prefix`, or null if it matches none.
/// Formats with a signature match it exactly. BMP, ICO, and CUR also need
/// plausible header fields. TGA has no signature and WBMP a weak one, so
/// they are tried last, on header fields only, and can match files that are
/// neither; a decoder still rejects what it cannot parse.
pub fn detect(prefix: []const u8) ?Format {
    const p = prefix;
    if (std.mem.startsWith(u8, p, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, p, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, p, "GIF87a") or std.mem.startsWith(u8, p, "GIF89a")) return .gif;
    if (p.len >= 12 and std.mem.eql(u8, p[0..4], "RIFF") and std.mem.eql(u8, p[8..12], "WEBP")) return .webp;
    for ([_][]const u8{ "II*\x00", "MM\x00*", "II+\x00", "MM\x00+" }) |sig| {
        if (std.mem.startsWith(u8, p, sig)) return .tiff;
    }
    if (std.mem.startsWith(u8, p, "\xff\x0a")) return .jxl;
    if (std.mem.startsWith(u8, p, "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a")) return .jxl;
    if (std.mem.startsWith(u8, p, "qoif")) return .qoi;
    if (isBmp(p)) return .bmp;
    if (isIco(p)) |f| return f;
    if (isNetpbm(p)) return .netpbm;
    if (isTga(p)) return .tga;
    if (isWbmp(p)) return .wbmp;
    return null;
}

fn isBmp(p: []const u8) bool {
    if (p.len < 18 or !std.mem.eql(u8, p[0..2], "BM")) return false;
    // The DIB header's size names its version.
    return switch (std.mem.readInt(u32, p[14..18], .little)) {
        12, 16, 40, 52, 56, 64, 108, 124 => true,
        else => false,
    };
}

fn isIco(p: []const u8) ?Format {
    if (p.len < 10 or p[0] != 0 or p[1] != 0 or p[3] != 0) return null;
    const f: Format = switch (p[2]) {
        1 => .ico,
        2 => .cur,
        else => return null,
    };
    // At least one entry, and the first entry's reserved byte is zero.
    if (std.mem.readInt(u16, p[4..6], .little) == 0 or p[9] != 0) return null;
    return f;
}

fn isNetpbm(p: []const u8) bool {
    if (p.len < 3 or p[0] != 'P') return false;
    switch (p[1]) {
        '1'...'7', 'F', 'f' => {},
        else => return false,
    }
    return std.ascii.isWhitespace(p[2]);
}

fn isTga(p: []const u8) bool {
    if (p.len < 18) return false;
    const color_map = p[1];
    const kind = p[2];
    const map_bits = p[7];
    const depth = p[16];
    const descriptor = p[17];
    switch (kind) {
        1, 9 => if (color_map != 1) return false,
        2, 3, 10, 11 => if (color_map > 1) return false,
        else => return false,
    }
    if (color_map == 1) switch (map_bits) {
        15, 16, 24, 32 => {},
        else => return false,
    };
    switch (depth) {
        8, 15, 16, 24, 32 => {},
        else => return false,
    }
    const width = std.mem.readInt(u16, p[12..14], .little);
    const height = std.mem.readInt(u16, p[14..16], .little);
    // The interleaving bits are obsolete and zero in practice.
    return width != 0 and height != 0 and descriptor & 0xc0 == 0;
}

fn isWbmp(p: []const u8) bool {
    // Type 0, no extension headers, then two nonzero multi-byte integers.
    if (p.len < 4 or p[0] != 0 or p[1] != 0) return false;
    var i: usize = 2;
    for (0..2) |_| {
        var v: u32 = 0;
        var n: usize = 0;
        while (true) : (n += 1) {
            if (i >= p.len or n == 4) return false;
            const b = p[i];
            i += 1;
            v = v << 7 | (b & 0x7f);
            if (b & 0x80 == 0) break;
        }
        if (v == 0) return false;
    }
    return true;
}

test detect {
    try testing.expectEqual(Format.png, detect("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR").?);
    try testing.expectEqual(Format.jpeg, detect("\xff\xd8\xff\xe0").?);
    try testing.expectEqual(Format.gif, detect("GIF89a\x01\x00").?);
    try testing.expectEqual(Format.webp, detect("RIFF\x10\x00\x00\x00WEBPVP8L").?);
    try testing.expectEqual(Format.tiff, detect("MM\x00*\x00\x00\x00\x08").?);
    try testing.expectEqual(Format.tiff, detect("II+\x00\x08\x00\x00\x00").?);
    try testing.expectEqual(Format.jxl, detect("\xff\x0a\xfa").?);
    try testing.expectEqual(Format.jxl, detect("\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a").?);
    try testing.expectEqual(Format.qoi, detect("qoif\x00\x00\x00\x01").?);
    try testing.expectEqual(Format.bmp, detect("BM\x46\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00").?);
    try testing.expectEqual(null, detect("BM\x46\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x29\x00\x00\x00"));
    try testing.expectEqual(Format.ico, detect("\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x01\x00\x20\x00").?);
    try testing.expectEqual(Format.cur, detect("\x00\x00\x02\x00\x01\x00\x20\x20\x00\x00\x05\x00\x05\x00").?);
    try testing.expectEqual(null, detect("\x00\x00\x01\x00\x00\x00\x10\x10\x00\x00"));
    try testing.expectEqual(Format.netpbm, detect("P6\n3 2\n255\n").?);
    try testing.expectEqual(Format.netpbm, detect("Pf 1 1 -1.0\n").?);
    try testing.expectEqual(null, detect("P8 1 1"));
    try testing.expectEqual(null, detect("P6x"));
    // An uncompressed truecolor TGA, 2 by 3, 24 bits.
    const tga = "\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00";
    try testing.expectEqual(Format.tga, detect(tga ++ "\x18\x00").?);
    try testing.expectEqual(null, detect(tga ++ "\x11\x00"));
    try testing.expectEqual(Format.wbmp, detect("\x00\x00\x81\x00\x10").?);
    try testing.expectEqual(null, detect("\x00\x00\x00\x10"));
    try testing.expectEqual(null, detect(""));
    try testing.expectEqual(null, detect("\x89PN"));
    // Every prefix of a signature is too short to match.
    try testing.expectEqual(null, detect("qoi"));
    try testing.expectEqual(prefix_len, 18);
}
