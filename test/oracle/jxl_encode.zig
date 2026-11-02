//! The JPEG XL encoder's output against libjxl: every input is a file
//! `image.jxl.encode` wrote, at a random effort, from pixels the encoder's
//! fuzz target generates in a random pixel format, at sizes up to 24 by
//! 24 and one time in 32 a strip across two groups. libjxl must
//! decode it as this package does, in RGBA16 (premultiplied when the file's alpha
//! is), and the fuzz target (test/fuzz/jxl_encode.zig) checks that this
//! package decodes it to the source converted to the stored format, so
//! libjxl decodes it to that too. The harness mutates a quarter of the
//! inputs; those are the decoder's business (test/oracle/jxl.zig), so
//! `comparable` counts answers only for files as the encoder wrote them,
//! which `generate` records by their hashes. The rest is jxl.zig's.

const std = @import("std");
const image = @import("image");
const jxl = @import("jxl.zig");
const target = @import("fuzz").jxl_encode;

pub const name = "jxl_encode";
pub const Decoder = jxl.Decoder;
pub const oracles = jxl.oracles;
pub const formats = [_]image.PixelFormat{ .rgba16, .rgba16_premul };
pub const adapt = jxl.adapt;

/// Whether `op`'s answer counts: only for files as the encoder wrote
/// them, and then as for any JPEG XL file.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    return written(input) and jxl.comparable(op, format, input);
}

/// The hashes of the files `generate` wrote, in an open-addressed table
/// that stops taking them when three quarters full.
var hashes: [1 << 18]u64 = @splat(0);
var count: usize = 0;

fn hashOf(file: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6a786c, file) | 1;
}

fn record(file: []const u8) void {
    if (count >= hashes.len / 4 * 3) return;
    const h = hashOf(file);
    var i: usize = @intCast(h % hashes.len);
    while (true) : (i = (i + 1) % hashes.len) {
        const v = @atomicLoad(u64, &hashes[i], .acquire);
        if (v == h) return;
        if (v == 0) break;
    }
    @atomicStore(u64, &hashes[i], h, .release);
    count += 1;
}

fn written(file: []const u8) bool {
    const h = hashOf(file);
    var i: usize = @intCast(h % hashes.len);
    while (true) : (i = (i + 1) % hashes.len) {
        const v = @atomicLoad(u64, &hashes[i], .acquire);
        if (v == h) return true;
        if (v == 0) return false;
    }
}

var work: [64 << 20]u8 = undefined;
var pixels: [320 * 24 * 16]u8 = undefined;
var out: [4 << 20]u8 = undefined;

pub const fuzz = struct {
    pub const corpus: [0][]const u8 = .{};
    pub const extensions: [0][]const u8 = .{};

    /// An encoded file in `buf`, from pixels `target.generate` makes.
    /// Called under the comparison's lock, one at a time.
    pub fn generate(random: std.Random, buf: []u8) []u8 {
        var raw: [4096]u8 = undefined;
        const input = target.generate(random, &raw);
        // Encoding is serial, so sources are small: up to 24 by 24, and
        // one time in 32 a strip 257 to 320 long (two groups) and up to 24
        // across, mostly at the fast effort.
        var width: u32 = 1 + input[0] % 24;
        var height: u32 = 1 + input[1] % 24;
        const big = random.uintLessThan(u8, 32) == 0;
        if (big) {
            const long = 257 + @as(u32, input[0]) % 64;
            const across = 1 + @as(u32, input[1]) % 24;
            if (random.boolean()) {
                width = long;
                height = across;
            } else {
                width = across;
                height = long;
            }
        }
        const body = input[2..];
        const all = std.enums.values(image.PixelFormat);
        const format = all[random.uintLessThan(usize, all.len)];
        // The best effort only up to 16 by 16.
        const roll = random.uintLessThan(u8, 8);
        const effort: image.jxl.Effort = if (roll < 4 or (big and roll < 7))
            .fast
        else if (roll < 7 or width * height > 256) .default else .best;
        const options: image.jxl.EncodeOptions = .{ .effort = effort };
        while (true) {
            const len = image.PixelBuffer.len(format, width, height).?;
            const px = pixels[0..len];
            for (px, 0..) |*b, k| b.* = body[k % body.len];
            if (format.sample() == .f32) {
                const floats: []align(1) f32 = @ptrCast(px);
                for (floats, 0..) |*v, k| v.* = @as(f32, @floatFromInt(body[k % body.len])) / 255;
            }
            const src = image.PixelBuffer.init(px, format, width, height) catch unreachable;
            const work_len = image.jxl.workLen(options, width, height).?;
            var w: std.Io.Writer = .fixed(&out);
            image.jxl.encode(&w, src, options, work[0..work_len]) catch |e|
                std.debug.panic("jxl_encode oracle: encode failed: {t}", .{e});
            const file = w.buffered();
            // Smaller until the file fits the input buffer.
            if (file.len <= buf.len) {
                @memcpy(buf[0..file.len], file);
                record(buf[0..file.len]);
                return buf[0..file.len];
            }
            width = (width + 1) / 2;
            height = (height + 1) / 2;
        }
    }
};
