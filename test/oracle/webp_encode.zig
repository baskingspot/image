//! The WebP lossless encoder's output against libwebp and Wuffs: every
//! input is a file `image.webp.encode` wrote from pixels the encoder's fuzz
//! target generates, in a random pixel format, at an effort (and with
//! metadata or not) that its size picks. The oracles must decode it as this
//! package does, and the fuzz target (test/fuzz/webp_encode.zig) checks
//! that this package decodes it to the source converted to `bgra8`, so the
//! oracles decode it to that too. The harness mutates a quarter of the
//! inputs; those are the decoder's business (test/oracle/webp.zig, whose
//! expected splits apply), so `comparable` leaves out every answer for a
//! file that is not as the encoder wrote it: one that this package's
//! decoder rejects, or whose pixels encode, with the options its size
//! picks, to other bytes. The encoder's output depends only on the pixels
//! as `bgra8` and the options, so that test is exact.
//!
//! Wuffs (v0.4.0-alpha.12) decodes no VP8L image inside VP8X: libwebp's
//! own lossless files with metadata added by webpmux fail with "bad
//! ALPH+VP8L combination" when the VP8X alpha flag is set, as RFC 9649
//! says it must be for an image with alpha, and with "bad color cache"
//! when it is clear, while the same VP8L chunk alone decodes. So Wuffs's
//! answers for files with metadata are left out; libwebp's count.

const std = @import("std");
const image = @import("image");
const webp = @import("webp.zig");
const target = @import("fuzz").webp_encode;

pub const name = "webp_encode";
pub const Decoder = webp.Decoder;
pub const oracles = webp.oracles;
pub const formats = webp.formats;
pub const adapt = webp.adapt;

/// Whether `op`'s answer counts: only for files as the encoder wrote them,
/// and then as for any WebP.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    if (std.mem.eql(u8, op, "webp-wuffs") and extended(input)) return false;
    return intact(input) and webp.comparable(op, format, input);
}

/// Whether `input`'s first chunk is VP8X.
fn extended(input: []const u8) bool {
    return input.len >= 16 and std.mem.eql(u8, input[12..16], "VP8X");
}

const variants = [_]image.webp.EncodeOptions{
    .{ .effort = 0 },
    .{ .effort = 1 },
    .{ .effort = 2 },
    .{ .effort = 3 },
    .{ .effort = 4 },
    .{ .effort = 5 },
    .{ .effort = 6 },
    .{ .effort = 7 },
    .{ .effort = 8 },
    .{ .effort = 9 },
    .{ .effort = 2, .icc = "icc", .exif = "MM\x00\x2a\x00\x00\x00\x08", .xmp = "<x/>" },
};

/// The options a `width` by `height` image is encoded with.
fn variant(width: u32, height: u32) image.webp.EncodeOptions {
    return variants[(width * 31 + height) % variants.len];
}

const side = 64;
var work: [8 << 20]u8 = undefined;
var pixels: [side * side * 16]u8 = undefined;

/// The last input `intact` judged, per thread, since `comparable` is asked
/// once per oracle and pixel format.
threadlocal var last: struct { hash: u64 = 0, len: usize = 0, intact: bool = false } = .{};
threadlocal var check_pixels: [side * side * 4]u8 = undefined;
threadlocal var check_file: [1 << 16]u8 = undefined;
threadlocal var check_work: [8 << 20]u8 = undefined;

/// Whether `input` is a file the encoder writes: our decoder reads it as
/// at most `side` by `side` pixels that encode to it again.
fn intact(input: []const u8) bool {
    const hash = std.hash.XxHash64.hash(0, input);
    if (last.hash == hash and last.len == input.len) return last.intact;
    const ok = reencodes(input);
    last = .{ .hash = hash, .len = input.len, .intact = ok };
    return ok;
}

fn reencodes(input: []const u8) bool {
    var r: std.Io.Reader = .fixed(input);
    var d: image.webp.Decoder = .init(&r, .{});
    const config = d.decodeConfig() catch return false;
    if (config.width > side or config.height > side or config.work_len > check_work.len) return false;
    const len = @as(usize, config.width) * config.height * 4;
    const px = image.PixelBuffer.init(check_pixels[0..len], .bgra8, config.width, config.height) catch return false;
    _ = d.decodeFrame(px, check_work[0..config.work_len]) catch return false;
    const options = variant(config.width, config.height);
    const work_len = image.webp.workLen(options, config.width, config.height) orelse return false;
    if (work_len > check_work.len) return false;
    var w: std.Io.Writer = .fixed(&check_file);
    image.webp.encode(&w, px, options, check_work[0..work_len]) catch return false;
    return std.mem.eql(u8, w.buffered(), input);
}

pub const fuzz = struct {
    pub const corpus: [0][]const u8 = .{};
    pub const extensions: [0][]const u8 = .{};

    /// An encoded file in `buf`, from pixels `target.generate` makes.
    pub fn generate(random: std.Random, buf: []u8) []u8 {
        var raw: [4096]u8 = undefined;
        const input = target.generate(random, &raw);
        const width: u32 = 1 + input[0] % side;
        const height: u32 = 1 + input[1] % side;
        const body = input[2..];
        const all = std.enums.values(image.PixelFormat);
        const format = all[random.uintLessThan(usize, all.len)];
        const len = image.PixelBuffer.len(format, width, height).?;
        const px = pixels[0..len];
        for (px, 0..) |*b, k| b.* = body[k % body.len];
        if (format.sample() == .f32) {
            const floats: []align(1) f32 = @ptrCast(px);
            for (floats, 0..) |*v, k| v.* = @as(f32, @floatFromInt(body[k % body.len])) / 255;
        }
        const src = image.PixelBuffer.init(px, format, width, height) catch unreachable;
        const options = variant(width, height);
        const work_len = image.webp.workLen(options, width, height).?;
        var w: std.Io.Writer = .fixed(buf);
        image.webp.encode(&w, src, options, work[0..work_len]) catch |e|
            std.debug.panic("webp_encode oracle: encode failed: {t}", .{e});
        return w.buffered();
    }
};
