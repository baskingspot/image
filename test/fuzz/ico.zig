//! The ICO and CUR fuzz target: the decoder properties in harness.zig, on
//! mutated corpus files and generated directories of DIB entries, both
//! decoding every entry and decoding the first on its own.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "ico";

pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/ico" };
pub const extensions = [_][]const u8{ ".ico", ".cur" };

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkDecoder(image.ico.Decoder, input, choice);
    try harness.checkDecoder(FirstEntry, input, choice);
}

/// The decoder with `Options.entry` 0, under the generic contract.
pub const FirstEntry = struct {
    inner: image.ico.Decoder,

    pub const Options = image.DecodeOptions;
    pub const Error = image.ico.Decoder.Error;

    pub fn init(reader: *std.Io.Reader, options: Options) FirstEntry {
        return .{ .inner = .init(reader, .{ .limits = options.limits, .blob_sink = options.blob_sink, .entry = 0 }) };
    }

    pub fn decodeConfig(d: *FirstEntry) Error!image.Config {
        return d.inner.decodeConfig();
    }

    pub fn decodeFrame(d: *FirstEntry, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        return d.inner.decodeFrame(dst, work);
    }
};

/// An ICO or CUR file of one to four DIB entries, usually valid: random
/// bit depths, sizes, color tables, and masks, the directory's sizes
/// sometimes off, the data sometimes out of order, and now and then a PNG
/// signature in place of a DIB.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 1 << 16);
    const count = 1 + random.uintLessThan(u16, 4);
    var len: usize = 6 + 16 * @as(usize, count);
    std.mem.writeInt(u16, buf[0..2], 0, .little);
    std.mem.writeInt(u16, buf[2..4], if (random.uintLessThan(u8, 4) == 0) 2 else 1, .little);
    std.mem.writeInt(u16, buf[4..6], count, .little);
    var starts: [4]usize = undefined;
    var sizes: [4]usize = undefined;
    for (0..count) |i| {
        const bits_choice = [_]u16{ 1, 4, 8, 24, 32, 32 };
        const bits = bits_choice[random.uintLessThan(usize, bits_choice.len)];
        const w = 1 + random.uintLessThan(u32, 40);
        const h = 1 + random.uintLessThan(u32, 40);
        starts[i] = len;
        if (random.uintLessThan(u8, 16) == 0) {
            @memcpy(buf[len..][0..8], "\x89PNG\r\n\x1a\n");
            random.bytes(buf[len + 8 ..][0..24]);
            len += 32;
        } else {
            const colors: u32 = if (bits <= 8) @as(u32, 1) << @intCast(bits) else 0;
            const short = colors > 0 and random.uintLessThan(u8, 4) == 0;
            const used: u32 = if (short) 1 + random.uintLessThan(u32, colors) else 0;
            const table = if (used != 0) used else colors;
            @memset(buf[len..][0..40], 0);
            std.mem.writeInt(u32, buf[len..][0..4], 40, .little);
            std.mem.writeInt(u32, buf[len + 4 ..][0..4], w, .little);
            std.mem.writeInt(u32, buf[len + 8 ..][0..4], 2 * h, .little);
            std.mem.writeInt(u16, buf[len + 12 ..][0..2], 1, .little);
            std.mem.writeInt(u16, buf[len + 14 ..][0..2], bits, .little);
            std.mem.writeInt(u32, buf[len + 32 ..][0..4], used, .little);
            len += 40;
            random.bytes(buf[len..][0 .. 4 * table]);
            len += 4 * table;
            const pixels = (w * bits + 31) / 32 * 4 * h;
            const mask = (w + 31) / 32 * 4 * h;
            random.bytes(buf[len..][0 .. pixels + mask]);
            len += pixels + mask;
            if (bits == 32 and random.boolean()) len -= mask;
        }
        sizes[i] = len - starts[i];
        const e = buf[6 + 16 * i ..][0..16];
        const off = random.uintLessThan(u8, 8) == 0;
        e[0] = @truncate(if (off) random.int(u8) else w);
        e[1] = @truncate(if (off) random.int(u8) else h);
        e[2] = 0;
        e[3] = 0;
        std.mem.writeInt(u16, e[4..6], 1, .little);
        std.mem.writeInt(u16, e[6..8], bits, .little);
    }
    // Usually in order, sometimes reversed.
    const reversed = random.uintLessThan(u8, 8) == 0;
    for (0..count) |i| {
        const j = if (reversed) count - 1 - i else i;
        const e = buf[6 + 16 * i ..][0..16];
        std.mem.writeInt(u32, e[8..12], @intCast(sizes[j]), .little);
        std.mem.writeInt(u32, e[12..16], @intCast(starts[j]), .little);
    }
    return buf[0..len];
}

/// Hand-written seeds for the coverage-guided fuzzer: a 2 by 1 32-bit icon
/// and a 1-bit cursor.
pub const seeds = [_][]const u8{
    "\x00\x00\x01\x00\x01\x00\x02\x01\x00\x00\x01\x00\x20\x00\x34\x00\x00\x00\x16\x00\x00\x00" ++
        "\x28\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x01\x00\x20\x00" ++ "\x00" ** 24 ++
        "\x01\x02\x03\x80\x04\x05\x06\xff" ++ "\x00\x00\x00\x00",
    "\x00\x00\x02\x00\x01\x00\x01\x01\x00\x00\x00\x00\x00\x00\x38\x00\x00\x00\x16\x00\x00\x00" ++
        "\x28\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\x00\x01\x00" ++ "\x00" ** 24 ++
        "\x00\x00\x00\x00\xff\xff\xff\x00" ++ "\x80\x00\x00\x00" ++ "\x00\x00\x00\x00",
};

test "ico on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
