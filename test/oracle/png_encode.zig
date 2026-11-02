//! The PNG encoder's output against Wuffs, libpng, and libspng: every input
//! is a file `image.png.encode` (or `encodeAnimation`, whose first frame
//! is the default image all three decode) wrote from pixels the encoder's
//! fuzz target generates, in a random pixel format, with random options.
//! The oracles must decode it as this package does, and the fuzz target
//! (test/fuzz/png_encode.zig) checks that this package decodes it to the
//! source converted to the file's format, so the oracles decode it to that
//! too. The harness mutates a quarter of the inputs; those are the
//! decoder's business (test/oracle/png.zig), so `comparable` leaves out
//! every answer for a file that is not as the encoder wrote it: one whose
//! chunks do not parse, with their CRCs, through IEND at its end. One such
//! file, an APNG whose acTL frame count was mutated past
//! `Limits.max_frames` (with a bad CRC), this package rejects as
//! `TooManyFrames` while all three oracles decode its first frame.

const std = @import("std");
const image = @import("image");
const png = @import("png.zig");
const target = @import("fuzz").png_encode;

pub const name = "png_encode";
pub const Decoder = image.png.Decoder;
pub const oracles = png.oracles;
pub const formats = png.formats;
pub const adapt = png.adapt;

/// Whether `op`'s answer counts: only for files as the encoder wrote them,
/// and then as for any PNG.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    return intact(input) and png.comparable(op, format, input);
}

/// Whether `input` is a signature and whole chunks with good CRCs, the
/// last of them IEND.
fn intact(input: []const u8) bool {
    if (input.len < 8 or !std.mem.eql(u8, input[0..8], "\x89PNG\r\n\x1a\n")) return false;
    var at: usize = 8;
    while (input.len - at >= 12) {
        const len = std.mem.readInt(u32, input[at..][0..4], .big);
        if (len > input.len - at - 12) return false;
        const crc = std.mem.readInt(u32, input[at + 8 + len ..][0..4], .big);
        if (crc != std.hash.Crc32.hash(input[at + 4 ..][0 .. 4 + len])) return false;
        if (std.mem.eql(u8, input[at + 4 ..][0..4], "IEND")) return at + 12 == input.len;
        at += 12 + len;
    }
    return false;
}

const variants = [_]image.png.EncodeOptions{
    .{},
    .{ .effort = .fast },
    .{ .effort = .best },
    .{ .reduce = false },
    .{ .filter = .paeth },
};

var work: [4 << 20]u8 = undefined;
var pixels: [2][64 * 64 * 16]u8 = undefined;

pub const fuzz = struct {
    pub const corpus: [0][]const u8 = .{};
    pub const extensions: [0][]const u8 = .{};

    /// An encoded file in `buf`, from pixels `target.generate` makes.
    pub fn generate(random: std.Random, buf: []u8) []u8 {
        var raw: [4096]u8 = undefined;
        const input = target.generate(random, &raw);
        const count: usize = if (random.uintLessThan(u8, 4) == 0) 2 else 1;
        // Small enough that the file fits `buf` even stored.
        const side: u32 = if (count == 1) 64 else 40;
        const width: u32 = 1 + input[0] % side;
        const height: u32 = 1 + input[1] % side;
        const body = input[2..];
        const all = std.enums.values(image.PixelFormat);
        var frames: [2]image.png.AnimationFrame = undefined;
        for (frames[0..count], 0..) |*f, i| {
            const format = all[random.uintLessThan(usize, all.len)];
            const fw = if (i == 0) width else 1 + random.uintLessThan(u32, width);
            const fh = if (i == 0) height else 1 + random.uintLessThan(u32, height);
            const len = image.PixelBuffer.len(format, fw, fh).?;
            const px = pixels[i][0..len];
            for (px, 0..) |*b, k| b.* = body[k % body.len];
            if (format.sample() == .f32) {
                const floats: []align(1) f32 = @ptrCast(px);
                for (floats, 0..) |*v, k| v.* = @as(f32, @floatFromInt(body[k % body.len])) / 255;
            }
            f.* = .{ .pixels = image.PixelBuffer.init(px, format, fw, fh) catch unreachable };
        }
        const options = variants[random.uintLessThan(usize, variants.len)];
        const work_len = image.png.workLen(options, width, height).?;
        var w: std.Io.Writer = .fixed(buf);
        const result = if (count == 1)
            image.png.encode(&w, frames[0].pixels, options, work[0..work_len])
        else
            image.png.encodeAnimation(&w, width, height, frames[0..count], options, work[0..work_len]);
        result catch |e| std.debug.panic("png_encode oracle: encode failed: {t}", .{e});
        return w.buffered();
    }
};
