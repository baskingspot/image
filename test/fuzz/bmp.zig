//! The BMP fuzz target: the decoder properties in harness.zig, on mutated
//! corpus files and generated bitmaps of every header version, bit depth,
//! and compression.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "bmp";

/// Not bench/corpus-gen/bmp: its 50-megapixel files are over the oracle
/// harness's 64 MiB file limit, and ImageMagick wrote all of it, so it
/// adds no cases the suites lack.
pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor" };
pub const extensions = [_][]const u8{ ".bmp", ".dib" };

pub fn check(input: []const u8, choice: u64) !void {
    return harness.checkDecoder(image.bmp.Decoder, input, choice);
}

const Kind = enum { pal1, pal2, pal4, pal8, rle4, rle8, rgb16, rgb24, rgb32, bf16, bf24, bf32, jpeg };

/// A BMP file, usually valid and sometimes slightly off: a random header
/// version, pixel kind, size, color table, and pixels or RLE stream.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 4096);
    const sizes = [_]u32{ 40, 40, 40, 108, 124, 12, 16, 52, 56, 64 };
    const hsize = sizes[random.uintLessThan(usize, sizes.len)];
    const os2 = hsize == 12 or hsize == 16 or hsize == 64;
    const kinds: []const Kind = if (os2)
        &.{ .pal1, .pal4, .pal8, .rgb24, .rle4, .rle8 }
    else
        std.enums.values(Kind);
    var kind = kinds[random.uintLessThan(usize, kinds.len)];
    if ((hsize == 12 or hsize == 16) and (kind == .rle4 or kind == .rle8)) kind = .pal8;
    const bits: u16 = switch (kind) {
        .pal1 => 1,
        .pal2 => 2,
        .pal4, .rle4 => 4,
        .pal8, .rle8 => 8,
        .rgb16, .bf16 => 16,
        .rgb24, .bf24 => 24,
        .rgb32, .bf32 => 32,
        .jpeg => 0,
    };
    const compression: u32 = switch (kind) {
        .rle8 => 1,
        .rle4 => 2,
        .bf16, .bf24, .bf32 => if (hsize == 40 and random.uintLessThan(u8, 4) == 0) 6 else 3,
        .jpeg => if (random.boolean()) 4 else 5,
        else => 0,
    };
    var w: u32 = random.uintAtMost(u32, if (random.uintLessThan(u8, 8) == 0) 300 else 33);
    var h: u32 = random.uintAtMost(u32, 24);
    // Keep the pixels within the buffer, with room for the headers.
    while ((w * bits + 31) / 32 * 4 * h + 2 * w * h > buf.len - 1600) {
        w /= 2;
        h /= 2;
    }
    const top_down = hsize != 12 and random.uintLessThan(u8, 4) == 0;

    var len: usize = 14;
    // The info header.
    @memset(buf[14 .. 14 + hsize], 0);
    std.mem.writeInt(u32, buf[14..18], hsize, .little);
    if (hsize == 12) {
        std.mem.writeInt(u16, buf[18..20], @intCast(@min(w, 0xffff)), .little);
        std.mem.writeInt(u16, buf[20..22], @intCast(@min(h, 0xffff)), .little);
        std.mem.writeInt(u16, buf[22..24], 1, .little);
        std.mem.writeInt(u16, buf[24..26], bits, .little);
    } else {
        const sh: i32 = if (top_down) -@as(i32, @intCast(h)) else @intCast(h);
        std.mem.writeInt(u32, buf[18..22], w, .little);
        std.mem.writeInt(i32, buf[22..26], sh, .little);
        std.mem.writeInt(u16, buf[26..28], 1, .little);
        std.mem.writeInt(u16, buf[28..30], bits, .little);
        if (hsize >= 20) std.mem.writeInt(u32, buf[30..34], compression, .little);
        if (hsize >= 40) {
            std.mem.writeInt(u32, buf[38..42], random.uintLessThan(u32, 4000), .little);
            std.mem.writeInt(u32, buf[42..46], random.uintLessThan(u32, 4000), .little);
        }
    }
    len += hsize;
    // Masks: in the header from 52 bytes, after it otherwise.
    if (compression == 3 or compression == 6) {
        const masks = randomMasks(random, bits);
        const count: usize = if (compression == 6 or hsize >= 56) 4 else 3;
        const at: usize = if (hsize >= 52) 14 + 40 else blk: {
            len += 4 * count;
            break :blk 14 + hsize;
        };
        for (masks[0..count], 0..) |m, i| std.mem.writeInt(u32, buf[at + 4 * i ..][0..4], m, .little);
        if (hsize == 52 and count == 4) len += 4;
    }
    if (hsize >= 108) {
        const spaces = [_]u32{ 0, 0x73524742, 0x57696e20, 0x4d424544 };
        std.mem.writeInt(u32, buf[14 + 56 ..][0..4], spaces[random.uintLessThan(usize, spaces.len)], .little);
    }
    // The color table.
    const entry: usize = if (hsize == 12) 3 else 4;
    const full: usize = if (bits <= 8 and bits > 0) @as(usize, 1) << @intCast(bits) else 0;
    const entries: usize = switch (random.uintLessThan(u8, 8)) {
        0 => random.uintAtMost(usize, full + 2),
        1 => if (bits > 8) random.uintAtMost(usize, 4) else full,
        else => full,
    };
    if (hsize >= 40 and entries != full and random.boolean()) {
        std.mem.writeInt(u32, buf[14 + 32 ..][0..4], @intCast(entries), .little);
    }
    random.bytes(buf[len..][0 .. entries * entry]);
    len += entries * entry;
    if (random.uintLessThan(u8, 16) == 0) {
        const gap = random.uintAtMost(usize, 20);
        random.bytes(buf[len..][0..gap]);
        len += gap;
    }
    const offset = len;
    // The pixels.
    const row = (w * bits + 31) / 32 * 4;
    switch (kind) {
        .rle4, .rle8 => len = rleStream(random, buf, len, w, h, kind == .rle4),
        .jpeg => {
            const n = random.uintAtMost(usize, 64);
            random.bytes(buf[len..][0..n]);
            len += n;
        },
        else => {
            random.bytes(buf[len..][0 .. row * h]);
            len += row * h;
        },
    }
    if (hsize >= 40) std.mem.writeInt(u32, buf[34..38], @intCast(len - offset), .little);
    @memcpy(buf[0..2], "BM");
    std.mem.writeInt(u32, buf[2..6], @intCast(len), .little);
    std.mem.writeInt(u32, buf[6..10], 0, .little);
    std.mem.writeInt(u32, buf[10..14], @intCast(offset), .little);
    return buf[0..len];
}

/// Red, green, blue, and alpha masks for `bits`-bit pixels: the common
/// layouts, or random contiguous ones.
fn randomMasks(random: std.Random, bits: u16) [4]u32 {
    switch (random.uintLessThan(u8, 4)) {
        0 => return if (bits == 16) .{ 0xf800, 0x7e0, 0x1f, 0 } else .{ 0xff0000, 0xff00, 0xff, 0 },
        1 => return if (bits == 16) .{ 0xf00, 0xf0, 0xf, 0xf000 } else .{ 0xff0000, 0xff00, 0xff, 0xff000000 },
        else => {},
    }
    var masks: [4]u32 = undefined;
    for (&masks) |*m| {
        const width = random.uintAtMost(u6, @intCast(@min(bits, 12)));
        const shift = random.uintAtMost(u6, @intCast(bits - @min(bits, width)));
        m.* = if (width == 0) 0 else @truncate(((@as(u64, 1) << width) - 1) << shift);
    }
    return masks;
}

/// An RLE stream for a `w` by `h` image: runs, literals, deltas, and ends
/// of lines, usually ending with the end-of-bitmap code.
fn rleStream(random: std.Random, buf: []u8, start: usize, w: u32, h: u32, four: bool) usize {
    var len = start;
    var x: u32 = 0;
    var y: u32 = 0;
    const end = buf.len - 600;
    while (y < h and len < end) {
        switch (random.uintLessThan(u8, 10)) {
            0...3 => {
                const past = @intFromBool(random.uintLessThan(u8, 8) == 0);
                const n = 1 + random.uintAtMost(u32, @max(w -| x, 1) - 1 + past);
                buf[len] = @intCast(@min(n, 255));
                buf[len + 1] = random.int(u8);
                len += 2;
                x += n;
            },
            4...6 => {
                const n: u32 = 3 + random.uintAtMost(u32, @min(@max(w -| x, 3) - 3, 252));
                buf[len] = 0;
                buf[len + 1] = @intCast(n);
                len += 2;
                const bytes = if (four) (n + 1) / 2 else n;
                random.bytes(buf[len..][0..bytes]);
                len += bytes;
                if (bytes & 1 == 1) {
                    buf[len] = 0;
                    len += 1;
                }
                x += n;
            },
            7 => {
                const dx = random.uintAtMost(u8, 3);
                const dy = random.uintAtMost(u8, 1);
                buf[len..][0..4].* = .{ 0, 2, dx, dy };
                len += 4;
                x += dx;
                y += dy;
            },
            else => {
                buf[len..][0..2].* = .{ 0, 0 };
                len += 2;
                x = 0;
                y += 1;
            },
        }
        if (x >= w and random.boolean()) {
            buf[len..][0..2].* = .{ 0, 0 };
            len += 2;
            x = 0;
            y += 1;
        }
    }
    if (random.uintLessThan(u8, 16) != 0) {
        buf[len..][0..2].* = .{ 0, 1 };
        len += 2;
    }
    return len;
}

/// Hand-written seeds for the coverage-guided fuzzer: a 2 by 2 24-bit
/// image, an RLE8 one, and a 32-bit V4 bitfields one.
pub const seeds = [_][]const u8{
    "BM\x46\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00" ++
        "\x28\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x01\x00\x18\x00" ++
        @as([24]u8, @splat(0)) ++ "\x01\x02\x03\x04\x05\x06\x00\x00\x07\x08\x09\x0a\x0b\x0c\x00\x00",
    "BM\x48\x00\x00\x00\x00\x00\x00\x00\x3e\x00\x00\x00" ++
        "\x28\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00\x01\x00\x08\x00" ++
        "\x01\x00\x00\x00" ++ @as([20]u8, @splat(0)) ++ "\x10\x20\x30\x00\x40\x50\x60\x00" ++
        "\x02\x01\x00\x02\x01\x00\x00\x00\x00\x03\x00\x01\x01\x00\x00\x01",
    "BM\x7a\x00\x00\x00\x00\x00\x00\x00\x7a\x00\x00\x00" ++
        "\x6c\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x20\x00" ++
        "\x03\x00\x00\x00" ++ @as([20]u8, @splat(0)) ++
        "\x00\x00\xff\x00\x00\xff\x00\x00\xff\x00\x00\x00\x00\x00\x00\xff" ++ @as([52]u8, @splat(0)) ++
        "\x01\x02\x03\x80",
};

test "bmp on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
