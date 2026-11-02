//! GIF against Wuffs, the bar, and giflib (test/oracle/gif.c), in RGBA8
//! and BGRA8. Every answer is the whole animation composited as a player
//! does it (gif.c says how), so every frame's pixels, regions, and errors
//! count, not only the first frame's: `Decoder` here composites this
//! package's frames the same way, saving a region before a frame whose
//! disposal is `previous` (`decodeFrameConfig`) and applying each disposal
//! before the next frame.
//!
//! The libraries disagree, and the expected splits are:
//!
//! - A first frame that reaches past the logical screen: Wuffs and this
//!   package grow the canvas to hold it (Chromium does the same); giflib
//!   reports the screen as written and gif.c clips to it.
//! - giflib rejects what Wuffs and this package accept: a file with no
//!   frames, a zero-width or zero-height frame, and a byte where a block
//!   should start, which Wuffs and this package read as the trailer.
//! - giflib accepts what Wuffs and this package reject: a graphic control
//!   extension whose block is not 4 bytes, a signature other than GIF87a
//!   or GIF89a, and, without `ignore_too_much_data` (inputs whose screen
//!   descriptor XORs to an even number), a frame whose LZW data holds more
//!   pixels than the frame, which giflib drops. With it, Wuffs's
//!   IGNORE_TOO_MUCH_PIXEL_DATA quirk and this package drop them too, and
//!   all three ignore a bad code once the frame is whole.
//! - Several graphic control extensions before a frame: Wuffs and this
//!   package take the last, giflib's `DGifSavedExtensionToGCB` the first.
//! - Disposal method 4, which the specification leaves undefined: Wuffs
//!   and this package restore to previous (as Chromium does), giflib's
//!   caller (gif.c) leaves the frame in place.
//! - A minimum code size of 0: Wuffs and this package decode it (clear
//!   code 1, end code 2, codes from 1 bit wide); giflib decodes some such
//!   files the same way and rejects others.
//! - A NETSCAPE2.0 or ANIMEXTS1.0 extension with no sub-blocks, its
//!   identifier followed by the block terminator: Wuffs reads that 0 as
//!   the size of the loop count's sub-block, and on any size but 3 skips
//!   that many bytes and then sub-blocks, so it reads past the terminator
//!   and takes the next byte for a sub-block's size. The specification
//!   makes 0 the terminator, as giflib and this package read it. `adapt`
//!   hands Wuffs the extension under another identifier, which it skips
//!   correctly; the extension holds no loop count, so the pixels cannot
//!   change. (Two fuzzed inputs, mutation copies after such an extension,
//!   had Wuffs and giflib both reject them for different reasons while
//!   this package read the copy's first byte as the end of the image.)
//!   Only an extension that starts where a block starts is renamed: the
//!   same bytes inside another block's data can hold a sub-block's length,
//!   and renaming them would change the file Wuffs reads (a fuzzed input
//!   had them inside an ICC profile).
//! - giflib applies no palette, so for a frame with no color table, or an
//!   index past its table, gif.c leaves the answer to Wuffs (opaque black,
//!   as this package writes).

const std = @import("std");
const image = @import("image");

pub const name = "gif";
pub const fuzz = @import("fuzz").gif;
pub const oracles = [_][]const u8{ "gif-wuffs", "gif-giflib" };
pub const formats = [_]image.PixelFormat{ .rgba8, .bgra8 };

pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    _ = op;
    _ = format;
    _ = input;
    return true;
}

/// Hands Wuffs every NETSCAPE2.0 or ANIMEXTS1.0 extension without
/// sub-blocks with its identifier renamed, so Wuffs skips it as an unknown
/// application extension (see above). It walks the blocks as the
/// specification lays them out, so only an extension where a block starts
/// is renamed, and stops at the first byte that starts no block or at the
/// end of the input.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (!std.mem.eql(u8, op, "gif-wuffs") or input.len < 13) return input;
    var out: ?[]u8 = null;
    var at: usize = 13 + colorTableLen(input[10]);
    while (at < input.len) {
        switch (input[at]) {
            0x21 => {
                const rest = input[at..];
                if (std.mem.startsWith(u8, rest, "\x21\xff\x0bNETSCAPE2.0\x00") or
                    std.mem.startsWith(u8, rest, "\x21\xff\x0bANIMEXTS1.0\x00"))
                {
                    if (out == null) out = try arena.dupe(u8, input);
                    @memset(out.?[at + 3 ..][0..11], '_');
                    at += 15;
                    continue;
                }
                at = skipSubBlocks(input, at + 2);
            },
            0x2c => {
                if (at + 10 > input.len) break;
                at = skipSubBlocks(input, at + 10 + colorTableLen(input[at + 9]) + 1);
            },
            else => break,
        }
    }
    return out orelse input;
}

/// The bytes of the color table that a screen or image descriptor's
/// packed field `flags` announces.
fn colorTableLen(flags: u8) usize {
    return if (flags & 0x80 != 0) @as(usize, 3) << @intCast((flags & 7) + 1) else 0;
}

/// Where the block after the sub-blocks starting at `at` starts, or past
/// the input's end when they run off it.
fn skipSubBlocks(input: []const u8, start: usize) usize {
    var at = start;
    while (at < input.len) {
        const n = input[at];
        at += 1 + @as(usize, n);
        if (n == 0) break;
    }
    return at;
}

/// The canvas before a frame whose disposal is `previous`; compare.zig's
/// pixel limit is 1 << 22, at 4 bytes a pixel. One per thread, since
/// compare.zig compares on every core.
threadlocal var saved: [(1 << 22) * 4]u8 = undefined;

/// This package's decoder, compositing every frame into the one canvas
/// compare.zig asks for. Like gif.c's Wuffs oracle, it sets
/// `ignore_too_much_data` when the screen descriptor's bytes XOR to an odd
/// number, so both settings are held against Wuffs.
pub const Decoder = struct {
    d: image.gif.Decoder,

    pub const Options = image.DecodeOptions;

    pub fn init(reader: *std.Io.Reader, options: Options) Decoder {
        const head = reader.peek(13) catch "";
        var x: u8 = 0;
        if (head.len == 13) for (head[6..13]) |b| {
            x ^= b;
        };
        return .{ .d = .init(reader, .{
            .limits = options.limits,
            .blob_sink = options.blob_sink,
            .ignore_too_much_data = x & 1 == 1,
        }) };
    }

    pub fn decodeConfig(c: *Decoder) image.gif.Decoder.Error!image.Config {
        return c.d.decodeConfig();
    }

    pub fn decodeFrame(c: *Decoder, dst: image.PixelBuffer, work: []u8) image.gif.Decoder.Error!?image.Frame {
        const bpp = dst.format.bytesPerPixel();
        // A file with no frames is a transparent canvas, as in Wuffs.
        for (0..dst.height) |y| @memset(dst.row(@intCast(y)), 0);
        var next = try c.d.decodeFrameConfig();
        while (next) |frame| {
            // An empty region has no rows to save or dispose.
            var f = frame;
            if (f.width == 0) f.height = 0;
            const region = dst.sub(f.x, f.y, f.width, f.height);
            if (f.disposal == .previous) {
                for (0..f.height) |y| {
                    const at = (f.y + y) * dst.stride + f.x * bpp;
                    @memcpy(saved[at..][0 .. f.width * bpp], region.row(@intCast(y)));
                }
            }
            _ = (try c.d.decodeFrame(dst, work)).?;
            next = try c.d.decodeFrameConfig();
            if (next == null) break;
            for (0..f.height) |y| {
                const row = region.row(@intCast(y));
                switch (f.disposal) {
                    .none => {},
                    .background => @memset(row, 0),
                    .previous => @memcpy(row, saved[(f.y + y) * dst.stride + f.x * bpp ..][0 .. f.width * bpp]),
                }
            }
        }
        return .{ .width = dst.width, .height = dst.height };
    }
};
