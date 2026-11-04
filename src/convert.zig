//! Conversion and swizzle between pixel formats.
//!
//! Every pair of `PixelFormat`s converts. Integer formats convert through
//! 16-bit RGBA, and any pair with a float side through `f32` RGBA. Integer
//! results are Wuffs's pixel swizzler's on every pair it has that keeps
//! alpha or has none to drop, with these definitions:
//!
//! - Widening an 8-bit sample multiplies by 257; narrowing a 16-bit one
//!   takes its high byte. A float sample is `c / max` one way and `c * max`
//!   rounded to nearest, clamped to 0..max, the other; NaN is 0.
//! - Premultiplying is `c * a / 65535` and unpremultiplying `c * 65535 / a`
//!   on 16-bit samples, both truncated; unpremultiplying clamps to 65535
//!   and gives 0 where `a` is 0. From an 8-bit source the result keeps 8
//!   bits (its high byte, widened again for a 16-bit destination), so 8-bit
//!   premultiplying is `c * a * 257 / 65280` truncated and unpremultiplying
//!   `c * 65535 / a / 256`. Float conversions multiply and divide without
//!   rounding or clamping.
//! - A format without alpha drops the (unpremultiplied) alpha; a source
//!   without alpha is opaque. Wuffs composites onto black there instead,
//!   the one place the integer results differ from its.
//! - Gray from color is `(19595 R + 38470 G + 7471 B + 32768) >> 16` on
//!   16-bit samples (Rec. 601 luma), and `0.299 R + 0.587 G + 0.114 B` with
//!   those weights in float, except that equal R, G, and B give that value
//!   exactly. Color from gray repeats the gray sample.
//! - Color from CMYK, whose samples are inverted inks, is libjpeg-turbo's
//!   naive conversion at the source's depth: `ink * black / max`, rounded,
//!   with `max` 255 or 65535 (`ink * black` in float). CMYK from color is
//!   its naive inverse on 16-bit samples: black is `m`, the largest of R,
//!   G, and B, and each ink `c * 65535 / m`, rounded (`c / m` in float),
//!   0 where `m` is 0, so black is all-zero bytes both ways. Alpha is dropped as for any format without it.
//!   Inks to inks pass through, not by way of color.
//!
//! The pairs decoders meet most, the byte swizzles, adding and dropping
//! alpha, premultiplying, gray to color, and 8-bit, 16-bit, and float
//! samples to one another in the same layout, have SIMD paths that give
//! the same bytes as the general path.
// Design notes and decisions: docs/slop/results/convert-rounding-20261101.md.

const std = @import("std");
const testing = std.testing;
const native_endian = @import("builtin").target.cpu.arch.endian();

const PixelFormat = @import("pixel.zig").PixelFormat;
const PixelBuffer = @import("pixel.zig").PixelBuffer;

/// A conversion from one format to another, chosen once and applied to many
/// rows. `init` picks a SIMD path for the pair when there is one.
pub const Converter = struct {
    dst: PixelFormat,
    src: PixelFormat,
    fast: ?Kernel,
    stages: Stages,

    const Kernel = *const fn (dst: []u8, src: []const u8, n: usize) void;

    pub fn init(dst: PixelFormat, src: PixelFormat) Converter {
        const kernel = fast(dst, src);
        // Only a pair without a kernel takes the general path, and choosing
        // its stages costs icons a few percent.
        return .{
            .dst = dst,
            .src = src,
            .fast = kernel,
            .stages = if (kernel == null) .init(dst, src) else undefined,
        };
    }

    /// Converts `n` pixels from `src` to `dst`. Asserts both hold `n`
    /// pixels of their format. They may be the same buffer when both
    /// formats have the same pixel size, and must not overlap otherwise.
    pub fn run(c: Converter, dst: []u8, src: []const u8, n: usize) void {
        const out = dst[0 .. n * c.dst.bytesPerPixel()];
        const in = src[0 .. n * c.src.bytesPerPixel()];
        if (c.fast) |kernel| kernel(out, in, n) else c.stages.run(out, in, n);
    }

    /// Whether `run` takes a SIMD path rather than the general one.
    pub fn isFast(c: Converter) bool {
        return c.fast != null;
    }
};

/// Converts `n` pixels of `src_format` in `src` to `dst_format` in `dst`.
pub fn convert(dst: []u8, dst_format: PixelFormat, src: []const u8, src_format: PixelFormat, n: usize) void {
    Converter.init(dst_format, src_format).run(dst, src, n);
}

/// Converts every pixel of `src` into `dst`, which must have the same
/// dimensions. Both buffers must pass `PixelBuffer.check`.
pub fn convertBuffer(dst: PixelBuffer, src: PixelBuffer) error{ SizeMismatch, BufferTooSmall }!void {
    if (dst.width != src.width or dst.height != src.height) return error.SizeMismatch;
    try dst.check();
    try src.check();
    const c: Converter = .init(dst.format, src.format);
    for (0..dst.height) |y| c.run(dst.row(@intCast(y)), src.row(@intCast(y)), dst.width);
}

// The general path: unpack to a pivot, pack from it, a chunk at a time.

const chunk = 64;

/// The general path for one pair: an unpack from the source and a pack to
/// the destination, through 16-bit or float RGBA. The pivot is
/// premultiplied (`premul`) when the destination is, and straight
/// otherwise; the unpack premultiplies or unpremultiplies to match, so
/// premultiplied to premultiplied passes samples above their alpha through
/// as they are.
const Stages = union(enum) {
    int: struct {
        unpack: *const fn (in: []const u8, pivot: *[chunk][4]u16, m: usize) void,
        pack: *const fn (out: []u8, pivot: *const [chunk][4]u16, m: usize) void,
    },
    float: struct {
        unpack: *const fn (in: []const u8, pivot: *[chunk][4]f32, m: usize) void,
        pack: *const fn (out: []u8, pivot: *const [chunk][4]f32, m: usize) void,
    },

    fn init(dst: PixelFormat, src: PixelFormat) Stages {
        if (dst.isCmyk() and src.isCmyk()) return .{
            .int = .{
                // Inks to inks, through 16 bits without going through color.
                .unpack = switch (src) {
                    inline .cmyk8, .cmyk16 => |f| Inks(f).unpack,
                    else => unreachable,
                },
                .pack = switch (dst) {
                    inline .cmyk8, .cmyk16 => |f| Inks(f).pack,
                    else => unreachable,
                },
            },
        };
        const premul = dst.isPremultiplied();
        if (dst.sample() == .f32 or src.sample() == .f32) {
            return switch (premul) {
                inline else => |p| .{ .float = .{
                    .unpack = switch (src) {
                        inline else => |f| Stage(f, p).unpackFloat,
                    },
                    .pack = switch (dst) {
                        inline else => |f| Stage(f, p).packFloat,
                    },
                } },
            };
        }
        return switch (premul) {
            inline else => |p| .{ .int = .{
                .unpack = switch (src) {
                    inline else => |f| Stage(f, p).unpack16,
                },
                .pack = switch (dst) {
                    inline else => |f| Stage(f, p).pack16,
                },
            } },
        };
    }

    fn run(stages: Stages, out: []u8, in: []const u8, n: usize) void {
        if (n == 0) return;
        const in_bpp = in.len / n;
        const out_bpp = out.len / n;
        var i: usize = 0;
        while (i < n) {
            const m = @min(chunk, n - i);
            const in_chunk = in[i * in_bpp ..][0 .. m * in_bpp];
            const out_chunk = out[i * out_bpp ..][0 .. m * out_bpp];
            switch (stages) {
                .int => |s| {
                    var pivot: [chunk][4]u16 = undefined;
                    s.unpack(in_chunk, &pivot, m);
                    s.pack(out_chunk, &pivot, m);
                },
                .float => |s| {
                    var pivot: [chunk][4]f32 = undefined;
                    s.unpack(in_chunk, &pivot, m);
                    s.pack(out_chunk, &pivot, m);
                },
            }
            i += m;
        }
    }
};

fn Stage(comptime f: PixelFormat, comptime premul: bool) type {
    return struct {
        fn unpack16(in: []const u8, pivot: *[chunk][4]u16, m: usize) void {
            for (pivot[0..m], 0..) |*p, j| p.* = unpack16Pixel(f, premul, in, j);
        }
        fn pack16(out: []u8, pivot: *const [chunk][4]u16, m: usize) void {
            for (pivot[0..m], 0..) |p, j| pack16Pixel(f, out, j, p);
        }
        fn unpackFloat(in: []const u8, pivot: *[chunk][4]f32, m: usize) void {
            for (pivot[0..m], 0..) |*p, j| p.* = unpackFloatPixel(f, premul, in, j);
        }
        fn packFloat(out: []u8, pivot: *const [chunk][4]f32, m: usize) void {
            for (pivot[0..m], 0..) |p, j| packFloatPixel(f, out, j, p);
        }
    };
}

fn Inks(comptime f: PixelFormat) type {
    return struct {
        fn unpack(in: []const u8, pivot: *[chunk][4]u16, m: usize) void {
            for (pivot[0..m], 0..) |*p, j| {
                for (p, 0..) |*s, ch| {
                    const v = load(f, in, j, @intCast(ch));
                    s.* = @intCast(if (comptime f.sample() == .u8) v * 257 else v);
                }
            }
        }
        fn pack(out: []u8, pivot: *const [chunk][4]u16, m: usize) void {
            for (pivot[0..m], 0..) |p, j| {
                for (p, 0..) |s, ch| store(f, out, j, @intCast(ch), s);
            }
        }
    };
}

inline fn load(comptime f: PixelFormat, bytes: []const u8, pixel: usize, channel: u2) u32 {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    return switch (comptime f.sample()) {
        .u8 => bytes[at],
        .u16 => std.mem.readInt(u16, bytes[at..][0..2], native_endian),
        .f32 => unreachable,
    };
}

inline fn loadFloat(comptime f: PixelFormat, bytes: []const u8, pixel: usize, channel: u2) f32 {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    return switch (comptime f.sample()) {
        .u8 => @as(f32, @floatFromInt(bytes[at])) / 255,
        .u16 => @as(f32, @floatFromInt(std.mem.readInt(u16, bytes[at..][0..2], native_endian))) / 65535,
        .f32 => @bitCast(std.mem.readInt(u32, bytes[at..][0..4], native_endian)),
    };
}

inline fn store(comptime f: PixelFormat, bytes: []u8, pixel: usize, channel: u2, v: u16) void {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    switch (comptime f.sample()) {
        .u8 => bytes[at] = @intCast(narrow(v)),
        .u16 => std.mem.writeInt(u16, bytes[at..][0..2], v, native_endian),
        .f32 => unreachable,
    }
}

inline fn storeFloat(comptime f: PixelFormat, bytes: []u8, pixel: usize, channel: u2, v: f32) void {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    switch (comptime f.sample()) {
        .u8 => bytes[at] = @intCast(quantize(v, 255)),
        .u16 => std.mem.writeInt(u16, bytes[at..][0..2], @intCast(quantize(v, 65535)), native_endian),
        .f32 => std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(v), native_endian),
    }
}

/// 16 bits to 8: the high byte.
inline fn narrow(c: u32) u32 {
    return c >> 8;
}

/// A float sample to an integer one: rounded, clamped, NaN to 0.
inline fn quantize(v: f32, comptime max: f32) u32 {
    if (!(v > 0)) return 0;
    if (v >= 1) return @intFromFloat(max);
    return @intFromFloat(@round(v * max));
}

/// Libjpeg-turbo's naive CMYK to RGB at the source's depth, widened to 16
/// bits, opaque.
inline fn cmykToRgb16(comptime f: PixelFormat, bytes: []const u8, pixel: usize) [4]u16 {
    const max: u64 = if (comptime f.sample() == .u8) 255 else 65535;
    const black: u64 = load(f, bytes, pixel, 3);
    var v: [4]u16 = undefined;
    for (0..3) |ch| {
        const x = load(f, bytes, pixel, @intCast(ch)) * black;
        const c: u16 = @intCast((2 * x + max) / (2 * max));
        v[ch] = if (max == 255) c * 257 else c;
    }
    v[3] = 65535;
    return v;
}

inline fn unpack16Pixel(comptime f: PixelFormat, comptime premul: bool, bytes: []const u8, pixel: usize) [4]u16 {
    if (comptime f.isCmyk()) return cmykToRgb16(f, bytes, pixel);
    const c = comptime f.channels();
    const wide = comptime f.sample() == .u8;
    var v: [4]u32 = undefined;
    if (c.y) |y| {
        v[0] = load(f, bytes, pixel, y);
        v[1] = v[0];
        v[2] = v[0];
    } else {
        v[0] = load(f, bytes, pixel, c.r.?);
        v[1] = load(f, bytes, pixel, c.g.?);
        v[2] = load(f, bytes, pixel, c.b.?);
    }
    v[3] = if (c.a) |a| load(f, bytes, pixel, a) else if (wide) 255 else 65535;
    if (wide) {
        for (&v) |*s| s.* *= 257;
    }
    const a = v[3];
    if (comptime f.isPremultiplied() and !premul) {
        for (v[0..3]) |*s| s.* = if (a == 0) 0 else @min(65535, s.* * 65535 / a);
    } else if (comptime f.hasAlpha() and !f.isPremultiplied() and premul) {
        for (v[0..3]) |*s| s.* = s.* * a / 65535;
    } else return .{ @intCast(v[0]), @intCast(v[1]), @intCast(v[2]), @intCast(a) };
    // An 8-bit source's alpha step keeps 8 bits.
    if (wide) {
        for (v[0..3]) |*s| s.* = narrow(s.*) * 257;
    }
    return .{ @intCast(v[0]), @intCast(v[1]), @intCast(v[2]), @intCast(a) };
}

inline fn pack16Pixel(comptime f: PixelFormat, bytes: []u8, pixel: usize, p: [4]u16) void {
    if (comptime f.isCmyk()) {
        const m: u32 = @max(p[0], p[1], p[2]);
        for (0..3) |ch| {
            const ink: u32 = if (m == 0) 0 else (@as(u32, p[ch]) * 65535 + m / 2) / m;
            store(f, bytes, pixel, @intCast(ch), @intCast(ink));
        }
        store(f, bytes, pixel, 3, @intCast(m));
        return;
    }
    const c = comptime f.channels();
    if (c.y) |y| {
        // Luma of premultiplied samples is the premultiplied luma.
        const l = (19595 * @as(u32, p[0]) + 38470 * @as(u32, p[1]) + 7471 * @as(u32, p[2]) + 32768) >> 16;
        store(f, bytes, pixel, y, @intCast(l));
    } else {
        store(f, bytes, pixel, c.r.?, p[0]);
        store(f, bytes, pixel, c.g.?, p[1]);
        store(f, bytes, pixel, c.b.?, p[2]);
    }
    if (c.a) |a| store(f, bytes, pixel, a, p[3]);
}

inline fn unpackFloatPixel(comptime f: PixelFormat, comptime premul: bool, bytes: []const u8, pixel: usize) [4]f32 {
    if (comptime f.isCmyk()) {
        const black = loadFloat(f, bytes, pixel, 3);
        var v: [4]f32 = undefined;
        for (0..3) |ch| v[ch] = loadFloat(f, bytes, pixel, @intCast(ch)) * black;
        v[3] = 1;
        return v;
    }
    const c = comptime f.channels();
    var v: [4]f32 = undefined;
    if (c.y) |y| {
        v[0] = loadFloat(f, bytes, pixel, y);
        v[1] = v[0];
        v[2] = v[0];
    } else {
        v[0] = loadFloat(f, bytes, pixel, c.r.?);
        v[1] = loadFloat(f, bytes, pixel, c.g.?);
        v[2] = loadFloat(f, bytes, pixel, c.b.?);
    }
    v[3] = if (c.a) |a| loadFloat(f, bytes, pixel, a) else 1;
    const a = v[3];
    if (comptime f.isPremultiplied() and !premul) {
        for (v[0..3]) |*s| {
            s.* = if (a == 0) 0 else s.* / a;
            // An integer sample is clamped as the 16-bit path clamps it.
            if (comptime f.sample() != .f32) s.* = @min(s.*, 1);
        }
    } else if (comptime f.hasAlpha() and !f.isPremultiplied() and premul) {
        for (v[0..3]) |*s| s.* *= a;
    }
    return v;
}

inline fn packFloatPixel(comptime f: PixelFormat, bytes: []u8, pixel: usize, p: [4]f32) void {
    if (comptime f.isCmyk()) {
        const m = @max(p[0], p[1], p[2]);
        // NaN and nothing above 0 are black.
        const lit = m > 0;
        for (0..3) |ch| storeFloat(f, bytes, pixel, @intCast(ch), if (lit) p[ch] / m else 0);
        storeFloat(f, bytes, pixel, 3, if (lit) m else 0);
        return;
    }
    const c = comptime f.channels();
    if (c.y) |y| {
        // Gray stays exactly itself: the weights' sum rounds away from 1.
        const gray = p[0] == p[1] and p[1] == p[2];
        storeFloat(f, bytes, pixel, y, if (gray) p[1] else 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]);
    } else {
        storeFloat(f, bytes, pixel, c.r.?, p[0]);
        storeFloat(f, bytes, pixel, c.g.?, p[1]);
        storeFloat(f, bytes, pixel, c.b.?, p[2]);
    }
    if (c.a) |a| storeFloat(f, bytes, pixel, a, p[3]);
}

// The SIMD paths. Each handles whole blocks with vectors and hands the tail
// to the general path, so both give the same bytes by construction of the
// tail and by test for the blocks.

fn fast(dst: PixelFormat, src: PixelFormat) ?Converter.Kernel {
    if (dst == src) return copy;
    if (dst.isCmyk() or src.isCmyk()) {
        // The channel maps do not describe CMYK, so it takes none of the
        // paths below but these.
        if (src == .cmyk8) return switch (dst) {
            .rgb8 => CmykTo(.rgb8).run,
            .bgr8 => CmykTo(.bgr8).run,
            .rgba8 => CmykTo(.rgba8).run,
            .bgra8 => CmykTo(.bgra8).run,
            .cmyk16 => widenAll,
            else => null,
        };
        if (src == .cmyk16 and dst == .cmyk8) return narrowAll;
        return null;
    }
    const d = dst.channels();
    const s = src.channels();
    const same_sample = dst.sample() == src.sample();
    const swapped = d.r != s.r;
    if (same_sample and dst.sample() != .f32 and dst.channelCount() == src.channelCount()) {
        // The same channels in another order.
        const same_alpha = dst.isPremultiplied() == src.isPremultiplied();
        if (same_alpha and dst.channelCount() == 4 and swapped) return switch (dst.sample()) {
            .u8 => Swap4(u8).run,
            .u16 => Swap4(u16).run,
            .f32 => unreachable,
        };
        if (dst.channelCount() == 3 and swapped) return switch (dst.sample()) {
            .u8 => Swap3(u8).run,
            .u16 => Swap3(u16).run,
            .f32 => unreachable,
        };
        if (dst.channelCount() == 4 and src.sample() == .u8 and !src.isPremultiplied() and dst.isPremultiplied()) {
            return if (swapped) Premultiply(true).run else Premultiply(false).run;
        }
    }
    if (same_sample and dst.sample() == .u8) {
        if (src.channelCount() == 3 and dst.channelCount() == 4) {
            return if (swapped) Expand3(true).run else Expand3(false).run;
        }
        if (src.channelCount() == 4 and dst.channelCount() == 3 and !src.isPremultiplied()) {
            return if (swapped) Drop4(true).run else Drop4(false).run;
        }
        if (src == .gray8 and !dst.isGray()) {
            return switch (dst.channelCount()) {
                3 => GrayTo(3).run,
                4 => GrayTo(4).run,
                else => unreachable,
            };
        }
    }
    // The same layout at another depth.
    const same_layout = dst.channelCount() == src.channelCount() and !swapped and d.y == s.y and
        dst.isPremultiplied() == src.isPremultiplied();
    if (same_layout and dst.sample() == .u8 and src.sample() == .u16) return narrowAll;
    if (same_layout and dst.sample() == .u16 and src.sample() == .u8) return widenAll;
    if (same_layout and src.sample() == .f32) return switch (dst.sample()) {
        .u8 => FloatAll(u8, false).run,
        .u16 => FloatAll(u16, false).run,
        .f32 => null,
    };
    if (same_layout and dst.sample() == .f32) return switch (src.sample()) {
        .u8 => FloatAll(u8, true).run,
        .u16 => FloatAll(u16, true).run,
        .f32 => null,
    };
    return null;
}

fn copy(dst: []u8, src: []const u8, n: usize) void {
    _ = n;
    if (dst.ptr != src.ptr) @memcpy(dst, src);
}

/// Whether two buffers share no byte.
fn disjoint(a: []const u8, b: []const u8) bool {
    return @intFromPtr(a.ptr) >= @intFromPtr(b.ptr) + b.len or @intFromPtr(b.ptr) >= @intFromPtr(a.ptr) + a.len;
}

/// Blocks of pixels, then the tail as one more block. `K.block(l, o, i)`
/// converts `l` pixels, for `l` of `K.wide` and `K.narrow`: wide blocks
/// once there are that many pixels (stores of whole cache lines where the
/// format allows), narrow ones below that. Every kernel works pixel by
/// pixel, so the tail's block may overlap the last one: it writes the same
/// bytes again. When the buffers overlap, or there is no whole block, the
/// narrow blocks run alone and the tail goes through a padded copy
/// instead, which reads no byte this call wrote.
fn blocks(
    comptime K: type,
    comptime dst: PixelFormat,
    comptime src: PixelFormat,
    out: []u8,
    in: []const u8,
    n: usize,
) void {
    const db = comptime dst.bytesPerPixel();
    const sb = comptime src.bytesPerPixel();
    if (n >= K.narrow and disjoint(out, in)) {
        if (K.wide != K.narrow and n >= K.wide + 64) {
            // Wide blocks from the first pixel whose output starts a cache
            // line, so their stores split none; narrow ones before it.
            const k = lineStart(db, @intFromPtr(out.ptr));
            if (k >= K.narrow) {
                overlapped(db, sb, K.narrow, out[0 .. k * db], in[0 .. k * sb], k, K.block);
            } else if (k != 0) {
                @call(.always_inline, K.block, .{ K.narrow, out[0 .. K.narrow * db], in[0 .. K.narrow * sb] });
            }
            overlapped(db, sb, K.wide, out[k * db ..], in[k * sb ..], n - k, K.block);
        } else if (K.wide != K.narrow and n >= K.wide) {
            overlapped(db, sb, K.wide, out, in, n, K.block);
        } else {
            overlapped(db, sb, K.narrow, out, in, n, K.block);
        }
        return;
    }
    const full = n / K.narrow * K.narrow;
    var i: usize = 0;
    while (i < full) : (i += K.narrow) {
        const o = out[i * db ..][0 .. K.narrow * db];
        @call(.always_inline, K.block, .{ K.narrow, o, in[i * sb ..][0 .. K.narrow * sb] });
    }
    const m = n - full;
    if (m != 0) {
        const o = out[full * db ..][0 .. m * db];
        @call(.never_inline, padded, .{ db, sb, K.narrow, o, in[full * sb ..][0 .. m * sb], K.block });
    }
}

/// The first pixel of `db` bytes from `addr` on whose bytes start a
/// 64-byte line, or 0 when no pixel's do.
fn lineStart(comptime db: usize, addr: usize) usize {
    const tz = comptime @ctz(db);
    const mask = (64 >> tz) - 1;
    // The inverse of `db`'s odd factor modulo 64 >> tz.
    const inv = comptime for (1..64) |x| {
        if ((x * (db >> tz)) & mask == 1) break x;
    } else unreachable;
    const need = (0 -% addr) & 63;
    if (need & ((1 << tz) - 1) != 0) return 0;
    return ((need >> tz) * inv) & mask;
}

/// `blocks`'s blocks of `l` pixels over disjoint buffers holding at least
/// `l`, the last ending at the last pixel.
inline fn overlapped(
    comptime db: usize,
    comptime sb: usize,
    comptime l: usize,
    out: []u8,
    in: []const u8,
    n: usize,
    comptime block: anytype,
) void {
    const full = n / l * l;
    var i: usize = 0;
    while (i < full) : (i += l) {
        @call(.always_inline, block, .{ l, out[i * db ..][0 .. l * db], in[i * sb ..][0 .. l * sb] });
    }
    if (full != n) {
        const o = out[(n - l) * db ..][0 .. l * db];
        @call(.always_inline, block, .{ l, o, in[(n - l) * sb ..][0 .. l * sb] });
    }
}

/// `blocks`'s tail of fewer than `l` pixels through a padded copy. Out of
/// line, so the common path keeps a small stack frame.
fn padded(
    comptime db: usize,
    comptime sb: usize,
    comptime l: usize,
    out: []u8,
    in: []const u8,
    comptime block: anytype,
) void {
    var pad_in: [l * sb]u8 = @splat(0);
    var pad_out: [l * db]u8 = undefined;
    @memcpy(pad_in[0..in.len], in);
    @call(.always_inline, block, .{ l, &pad_out, &pad_in });
    @memcpy(out, pad_out[0..out.len]);
}

/// RGBA and BGRA, either way: swap the first and third samples.
fn Swap4(comptime T: type) type {
    return struct {
        // 32-byte blocks: on this measure's AVX-512 host, 64-byte ones lost
        // 10% on images past the cache.
        const wide = 8 / @sizeOf(T);
        const narrow = 8 / @sizeOf(T);
        const f: PixelFormat = if (T == u8) .rgba8 else .rgba16;
        const g: PixelFormat = if (T == u8) .bgra8 else .bgra16;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(@This(), g, f, out, in, n);
        }
        fn block(comptime l: usize, o: *[l * f.bytesPerPixel()]u8, i: *const [l * f.bytesPerPixel()]u8) void {
            // A shuffle within each pixel (pshufb, tbl).
            const mask = comptime m: {
                var m: [l * 4]i32 = undefined;
                for (0..l) |p| {
                    for (0..4) |ch| m[p * 4 + ch] = p * 4 + (if (ch < 3) 2 - ch else ch);
                }
                break :m m;
            };
            const v: @Vector(l * 4, T) = @bitCast(i.*);
            o.* = @bitCast(@shuffle(T, v, undefined, mask));
        }
    };
}

/// RGB and BGR, either way.
fn Swap3(comptime T: type) type {
    return struct {
        // Wide blocks are 192 bytes: whole 64-byte stores, where 48-byte
        // blocks split every other store across cache lines.
        const wide = 64 / @sizeOf(T);
        const narrow = 16;
        const f: PixelFormat = if (T == u8) .rgb8 else .rgb16;
        const g: PixelFormat = if (T == u8) .bgr8 else .bgr16;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(@This(), g, f, out, in, n);
        }
        fn block(comptime l: usize, o: *[l * f.bytesPerPixel()]u8, i: *const [l * f.bytesPerPixel()]u8) void {
            const mask = comptime m: {
                @setEvalBranchQuota(100_000);
                var m: [l * 3]i32 = undefined;
                for (0..l) |p| {
                    for (0..3) |ch| m[p * 3 + ch] = p * 3 + (2 - ch);
                }
                break :m m;
            };
            const v: @Vector(l * 3, T) = @bitCast(i.*);
            o.* = @bitCast(@shuffle(T, v, undefined, mask));
        }
    };
}

/// RGB or BGR to RGBA or BGRA, opaque.
fn Expand3(comptime swap: bool) type {
    return struct {
        const wide = 16;
        const narrow = 16;
        const dst: PixelFormat = if (swap) .bgra8 else .rgba8;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(@This(), dst, .rgb8, out, in, n);
        }
        fn block(comptime l: usize, o: *[l * 4]u8, i: *const [l * 3]u8) void {
            // Four pixels at a time, each a 16-byte shuffle (pshufb, tbl)
            // of 16 input bytes; the last group loads the block's last 16
            // bytes so no load passes its end. Alpha is ORed in.
            const alpha: @Vector(16, u8) = comptime a: {
                var a: [16]u8 = @splat(0);
                for (0..4) |p| a[p * 4 + 3] = 255;
                break :a a;
            };
            inline for (0..l / 4) |g| {
                const at = @min(g * 12, l * 3 - 16);
                const shift = g * 12 - at;
                const m = comptime m: {
                    var m: [16]i32 = undefined;
                    for (0..4) |p| {
                        for (0..3) |ch| m[p * 4 + ch] = shift + p * 3 + (if (swap) 2 - ch else ch);
                        m[p * 4 + 3] = shift + p * 3;
                    }
                    break :m m;
                };
                const v: @Vector(16, u8) = i[at..][0..16].*;
                o[g * 16 ..][0..16].* = @shuffle(u8, v, undefined, m) | alpha;
            }
        }
    };
}

/// RGBA or BGRA to RGB or BGR, dropping straight alpha.
fn Drop4(comptime swap: bool) type {
    return struct {
        const wide = 16;
        const narrow = 16;
        const dst: PixelFormat = if (swap) .bgr8 else .rgb8;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(@This(), dst, .rgba8, out, in, n);
        }
        fn block(comptime l: usize, o: *[l * 3]u8, i: *const [l * 4]u8) void {
            const mask = comptime m: {
                var m: [l * 3]i32 = undefined;
                for (0..l) |p| {
                    for (0..3) |ch| m[p * 3 + ch] = p * 4 + (if (swap) 2 - ch else ch);
                }
                break :m m;
            };
            const v: @Vector(l * 4, u8) = i.*;
            o.* = @shuffle(u8, v, undefined, mask);
        }
    };
}

/// Straight RGBA to premultiplied RGBA or BGRA.
fn Premultiply(comptime swap: bool) type {
    return struct {
        const wide = 16;
        const narrow = 16;
        const dst: PixelFormat = if (swap) .bgra8_premul else .rgba8_premul;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(@This(), dst, .rgba8, out, in, n);
        }
        fn block(comptime l: usize, o: *[l * 4]u8, i: *const [l * 4]u8) void {
            const order = comptime m: {
                var m: [l * 4]i32 = undefined;
                var a: [l * 4]i32 = undefined;
                for (0..l) |p| {
                    for (0..4) |ch| {
                        m[p * 4 + ch] = p * 4 + (if (swap and ch < 3) 2 - ch else ch);
                        a[p * 4 + ch] = if (ch == 3) -1 else p * 4 + 3;
                    }
                }
                break :m .{ m, a };
            };
            const v: @Vector(l * 4, u8) = i.*;
            const full: @Vector(1, u8) = .{255};
            const c: @Vector(l * 4, u16) = @shuffle(u8, v, undefined, order[0]);
            // The alpha lanes multiply by 255, which leaves them unchanged.
            const a: @Vector(l * 4, u16) = @shuffle(u8, v, full, order[1]);
            // The general path's `((c * 257) * (a * 257) / 65535) >> 8` is
            // `c * a * 257 / 65280` truncated, and for every product `t` of
            // two bytes that is this, with no sum past 65534; the test
            // against Wuffs's values checks all of them.
            const t = c * a;
            const p: @Vector(l * 4, u8) = @intCast((t + ((t + (t >> @splat(8))) >> @splat(7))) >> @splat(8));
            o.* = p;
        }
    };
}

/// Gray to RGB, RGBA, or BGRA (the same bytes), opaque.
fn GrayTo(comptime count: usize) type {
    return struct {
        const wide = 16;
        const narrow = 16;
        const dst: PixelFormat = if (count == 3) .rgb8 else .rgba8;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(@This(), dst, .gray8, out, in, n);
        }
        fn block(comptime l: usize, o: *[l * count]u8, i: *const [l]u8) void {
            // Each 16 output bytes are a 16-byte shuffle (pshufb, tbl) of
            // the 16 gray bytes, with alpha ORed in.
            const v: @Vector(16, u8) = i.*;
            const alpha: @Vector(16, u8) = comptime a: {
                var a: [16]u8 = @splat(0);
                if (count == 4) for (0..4) |p| {
                    a[p * 4 + 3] = 255;
                };
                break :a a;
            };
            inline for (0..count) |g| {
                const m = comptime m: {
                    var m: [16]i32 = undefined;
                    for (0..16) |b| m[b] = (g * 16 + b) / count;
                    break :m m;
                };
                o[g * 16 ..][0..16].* = @shuffle(u8, v, undefined, m) | alpha;
            }
        }
    };
}

/// 8-bit CMYK to RGB, BGR, RGBA, or BGRA, opaque: the general path's
/// naive conversion, `(2x + 255) / 510` for `x` the product of the ink and
/// black samples, which is `(t + (t >> 8)) >> 8` for `t = x + 128` on
/// every product of two bytes (the test checks all of them).
fn CmykTo(comptime dst: PixelFormat) type {
    return struct {
        const wide = 16;
        const narrow = 16;
        const count = dst.channelCount();
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(@This(), dst, .cmyk8, out, in, n);
        }
        fn block(comptime l: usize, o: *[l * count]u8, i: *const [l * 4]u8) void {
            // A pixel to a 32-bit lane, C in the low byte: lane-wise
            // arithmetic, no shuffle but the one dropping alpha.
            const V = @Vector(l, u32);
            const px: V = @bitCast(i.*);
            const full: V = @splat(255);
            const black = px >> @splat(24);
            const c = comptime dst.channels();
            var rgba: V = if (count == 4) @splat(0xff00_0000) else @splat(0);
            inline for (.{ c.r.?, c.g.?, c.b.? }, 0..) |at, ch| {
                const ink = (px >> @splat(8 * ch)) & full;
                const t = ink * black + @as(V, @splat(128));
                rgba |= ((t + (t >> @splat(8))) >> @splat(8)) << @splat(8 * @as(u5, at));
            }
            const bytes: @Vector(l * 4, u8) = @bitCast(rgba);
            if (count == 4) {
                o.* = bytes;
            } else {
                const mask = comptime m: {
                    var m: [l * 3]i32 = undefined;
                    for (0..l) |p| {
                        for (0..3) |ch| m[p * 3 + ch] = p * 4 + ch;
                    }
                    break :m m;
                };
                o.* = @shuffle(u8, bytes, undefined, mask);
            }
        }
    };
}

/// 16-bit samples to 8, same layout.
fn narrowAll(dst: []u8, src: []const u8, n: usize) void {
    _ = n;
    const lanes = 32;
    const count = dst.len;
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const v: @Vector(lanes, u16) = std.mem.bytesToValue([lanes]u16, src[2 * i ..][0 .. 2 * lanes]);
        const p: @Vector(lanes, u8) = @intCast(v >> @splat(8));
        dst[i..][0..lanes].* = p;
    }
    if (i == count) return;
    // The tail as one more vector ending at the last sample, as in `blocks`.
    if (i != 0 and disjoint(dst, src)) {
        const v: @Vector(lanes, u16) = std.mem.bytesToValue([lanes]u16, src[2 * (count - lanes) ..][0 .. 2 * lanes]);
        dst[count - lanes ..][0..lanes].* = @as(@Vector(lanes, u8), @intCast(v >> @splat(8)));
        return;
    }
    while (i < count) : (i += 1) {
        dst[i] = @intCast(narrow(std.mem.readInt(u16, src[2 * i ..][0..2], native_endian)));
    }
}

/// 8-bit samples to 16, same layout.
fn widenAll(dst: []u8, src: []const u8, n: usize) void {
    _ = n;
    const lanes = 32;
    const count = src.len;
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const v: @Vector(lanes, u16) = src[i..][0..lanes].*;
        dst[2 * i ..][0 .. 2 * lanes].* = @bitCast(v * @as(@Vector(lanes, u16), @splat(257)));
    }
    if (i == count) return;
    if (i != 0 and disjoint(dst, src)) {
        const v: @Vector(lanes, u16) = src[count - lanes ..][0..lanes].*;
        dst[2 * (count - lanes) ..][0 .. 2 * lanes].* = @bitCast(v * @as(@Vector(lanes, u16), @splat(257)));
        return;
    }
    while (i < count) : (i += 1) {
        std.mem.writeInt(u16, dst[2 * i ..][0..2], @as(u16, src[i]) * 257, native_endian);
    }
}

/// Float samples to 8 or 16 bits (`to_float` false) or back, same layout:
/// `quantize` or `c / max` on every sample, as the general path does them.
fn FloatAll(comptime T: type, comptime to_float: bool) type {
    return struct {
        const lanes = 16;
        const max: @Vector(lanes, f32) = @splat(std.math.maxInt(T));
        const t = @sizeOf(T);

        fn run(dst: []u8, src: []const u8, n: usize) void {
            _ = n;
            const count = if (to_float) dst.len / 4 else src.len / 4;
            var i: usize = 0;
            while (i + lanes <= count) : (i += lanes) step(dst, src, i);
            if (i == count) return;
            // The tail as one more vector ending at the last sample, as in
            // `blocks`.
            if (i != 0 and disjoint(dst, src)) return step(dst, src, count - lanes);
            const e = native_endian;
            while (i < count) : (i += 1) {
                if (to_float) {
                    const v: f32 = @floatFromInt(std.mem.readInt(T, src[t * i ..][0..t], e));
                    std.mem.writeInt(u32, dst[4 * i ..][0..4], @bitCast(v / max[0]), e);
                } else {
                    const v: f32 = @bitCast(std.mem.readInt(u32, src[4 * i ..][0..4], e));
                    std.mem.writeInt(T, dst[t * i ..][0..t], @intCast(quantize(v, max[0])), e);
                }
            }
        }

        inline fn step(dst: []u8, src: []const u8, i: usize) void {
            if (to_float) {
                const v: @Vector(lanes, T) = std.mem.bytesToValue([lanes]T, src[t * i ..][0 .. t * lanes]);
                const f: @Vector(lanes, f32) = @floatFromInt(v);
                dst[4 * i ..][0 .. 4 * lanes].* = std.mem.toBytes(@as([lanes]f32, f / max));
            } else {
                // `quantize`: NaN and nothing above 0 to 0, 1 and up to max.
                const v: @Vector(lanes, f32) = std.mem.bytesToValue([lanes]f32, src[4 * i ..][0 .. 4 * lanes]);
                const zero: @Vector(lanes, f32) = @splat(0);
                const c = @min(@select(f32, v > zero, v, zero), @as(@Vector(lanes, f32), @splat(1)));
                const q: @Vector(lanes, T) = @intFromFloat(@round(c * max));
                dst[t * i ..][0 .. t * lanes].* = std.mem.toBytes(@as([lanes]T, q));
            }
        }
    };
}

fn fill(random: std.Random, bytes: []u8, f: PixelFormat) void {
    random.bytes(bytes);
    if (f.sample() != .f32) return;
    // Mostly in-range floats, with some out of range, infinite, and NaN.
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const v: f32 = switch (random.uintLessThan(u8, 16)) {
            0 => std.math.nan(f32),
            1 => std.math.inf(f32),
            2 => -0.5,
            3 => 1.5,
            else => random.float(f32),
        };
        std.mem.writeInt(u32, bytes[i..][0..4], @bitCast(v), native_endian);
    }
}

test "every SIMD path gives the general path's bytes" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var src: [201 * 16]u8 = undefined;
    var want: [201 * 16]u8 = undefined;
    var got_buf: [201 * 16 + 64]u8 = undefined;
    var fast_pairs: usize = 0;
    for (std.enums.values(PixelFormat)) |d| {
        for (std.enums.values(PixelFormat)) |s| {
            const c: Converter = .init(d, s);
            if (!c.isFast()) continue;
            fast_pairs += 1;
            for ([_]usize{ 0, 1, 15, 16, 17, 31, 33, 64, 65, 130, 200 }) |n| {
                fill(random, src[0 .. n * s.bytesPerPixel()], s);
                Stages.init(d, s).run(want[0 .. n * d.bytesPerPixel()], src[0 .. n * s.bytesPerPixel()], n);
                const len = n * d.bytesPerPixel();
                // At every offset from a cache line: some kernels align
                // their stores.
                for (0..64) |offset| {
                    const got = got_buf[offset..][0 .. 201 * 16];
                    @memset(got, 0xAA);
                    c.run(got, &src, n);
                    testing.expectEqualSlices(u8, want[0..len], got[0..len]) catch |err| {
                        std.debug.print("{t} from {t}, {d} pixels at offset {d}\n", .{ d, s, n, offset });
                        return err;
                    };
                    // Nothing past the last pixel is written.
                    try testing.expectEqual(0xAA, got[len]);
                }
                const got = got_buf[0 .. 201 * 16];
                // A pair of one size converts in place too.
                if (d.bytesPerPixel() == s.bytesPerPixel()) {
                    @memcpy(got[0..len], src[0..len]);
                    c.run(got, got, n);
                    try testing.expectEqualSlices(u8, want[0..len], got[0..len]);
                }
            }
        }
    }
    try testing.expect(fast_pairs >= 40);
}

test "8-bit premultiply, unpremultiply, and narrowing match Wuffs" {
    // Every (c, a) pair, through the SIMD paths and the general one. The
    // expected values are Wuffs's, in another form than the code's: its
    // 16-bit premultiply `c·257 · a·257 / 65535`, truncated, is
    // `c·a·257 / 255`, and its high byte is that over 256; its unpremultiply
    // `c·257 · 65535 / (a·257)` is `c·65535 / a`.
    // docs/slop/results/convert-rounding-20261101.md checks these against
    // Wuffs itself.
    var straight: [256 * 256][4]u8 = undefined;
    for (&straight, 0..) |*p, i| p.* = .{ @truncate(i), @truncate(~i), @truncate(i *% 91 +% 17), @intCast(i >> 8) };
    const bytes = std.mem.sliceAsBytes(&straight);
    var out: [256 * 256][4]u8 = undefined;
    var out16: [256 * 256][4]u16 = undefined;
    for ([_]bool{ true, false }) |simd| {
        const run = struct {
            fn run(fast_path: bool, dst: []u8, d: PixelFormat, src: []const u8, s: PixelFormat) void {
                const n = src.len / s.bytesPerPixel();
                if (fast_path) convert(dst, d, src, s, n) else Stages.init(d, s).run(dst, src, n);
            }
        }.run;
        run(simd, std.mem.sliceAsBytes(&out), .rgba8_premul, bytes, .rgba8);
        for (straight, out) |in, p| {
            const a: u32 = in[3];
            for (0..3) |ch| try testing.expectEqual(in[ch] * a * 257 / (255 * 256), p[ch]);
            try testing.expectEqual(a, p[3]);
        }
        // The same bytes read as premultiplied, valid or not.
        run(simd, std.mem.sliceAsBytes(&out), .rgba8, bytes, .rgba8_premul);
        run(simd, std.mem.sliceAsBytes(&out16), .rgba16, bytes, .rgba8_premul);
        for (straight, out, out16) |in, p, w| {
            const a: u32 = in[3];
            for (0..3) |ch| {
                const want: u32 = if (a == 0) 0 else @min(255, @as(u32, in[ch]) * 65535 / a / 256);
                try testing.expectEqual(want, p[ch]);
                // A 16-bit destination widens the 8-bit result.
                try testing.expectEqual(want * 257, w[ch]);
            }
            try testing.expectEqual(a, p[3]);
        }
    }
    // Every 16-bit sample, narrowed.
    var wide: [65536]u16 = undefined;
    for (&wide, 0..) |*w, i| w.* = @intCast(i);
    var narrowed: [65536]u8 = undefined;
    for ([_]bool{ true, false }) |simd| {
        if (simd) convert(&narrowed, .gray8, std.mem.sliceAsBytes(&wide), .gray16, wide.len) else {
            Stages.init(.gray8, .gray16).run(&narrowed, std.mem.sliceAsBytes(&wide), wide.len);
        }
        for (wide, narrowed) |w, n| try testing.expectEqual(w / 256, n);
    }
}

test "gray and color" {
    var out: [8]u8 = undefined;
    // Gray stays gray through color, at both depths.
    for (0..256) |c| {
        const rgb = [3]u8{ @intCast(c), @intCast(c), @intCast(c) };
        convert(&out, .gray8, &rgb, .rgb8, 1);
        try testing.expectEqual(c, out[0]);
    }
    convert(&out, .gray8, &[3]u8{ 255, 0, 0 }, .rgb8, 1);
    try testing.expectEqual(76, out[0]);
    convert(&out, .gray8, &[3]u8{ 0, 255, 0 }, .bgr8, 1);
    try testing.expectEqual(150, out[0]);
    convert(&out, .rgba8, &[2]u8{ 9, 200 }, .gray_alpha8, 1);
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 200 }, out[0..4]);
    convert(&out, .bgr8, &[4]u8{ 1, 2, 3, 0 }, .rgba8, 1);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, out[0..3]);
}

test "CMYK" {
    // Every (ink, black) pair to every 8-bit color layout, through the
    // SIMD paths and the general one, against libjpeg-turbo's naive
    // conversion of inverted inks, `(2 c k + 255) / 510`.
    var inks: [256 * 256][4]u8 = undefined;
    for (&inks, 0..) |*p, i| p.* = .{ @truncate(i), @truncate(~i), @truncate(i *% 91 +% 17), @intCast(i >> 8) };
    const bytes = std.mem.sliceAsBytes(&inks);
    var out: [256 * 256 * 4]u8 = undefined;
    var out16: [256 * 256][3]u16 = undefined;
    for ([_]PixelFormat{ .rgb8, .bgr8, .rgba8, .bgra8 }) |d| {
        for ([_]bool{ true, false }) |simd| {
            const len = inks.len * d.bytesPerPixel();
            if (simd) {
                convert(out[0..len], d, bytes, .cmyk8, inks.len);
            } else {
                Stages.init(d, .cmyk8).run(out[0..len], bytes, inks.len);
            }
            const c = d.channels();
            for (inks, 0..) |p, i| {
                const px = out[i * d.bytesPerPixel() ..][0..d.bytesPerPixel()];
                const k: u32 = p[3];
                inline for (.{ c.r.?, c.g.?, c.b.? }, 0..) |at, ch| {
                    try testing.expectEqual((2 * @as(u32, p[ch]) * k + 255) / 510, px[at]);
                }
                if (d.channelCount() == 4) try testing.expectEqual(255, px[3]);
            }
        }
    }
    // A 16-bit destination widens the 8-bit result.
    convert(std.mem.sliceAsBytes(&out16), .rgb16, bytes, .cmyk8, inks.len);
    for (inks, out16) |p, w| {
        try testing.expectEqual((2 * @as(u32, p[0]) * p[3] + 255) / 510 * 257, w[0]);
    }
    // 16-bit inks convert at 16 bits.
    var rgb16: [3]u16 = undefined;
    const ink16 = [4]u16{ 0, 65535, 32768, 32768 };
    convert(std.mem.asBytes(&rgb16), .rgb16, std.mem.asBytes(&ink16), .cmyk16, 1);
    try testing.expectEqualSlices(u16, &.{ 0, 32768, 16384 }, &rgb16);
    // Color to inks: black from the brightest channel, then each ink, and
    // back.
    var cmyk: [4]u8 = undefined;
    convert(&cmyk, .cmyk8, &[3]u8{ 255, 0, 0 }, .rgb8, 1);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &cmyk);
    convert(&cmyk, .cmyk8, &[4]u8{ 0, 0, 0, 9 }, .rgba8, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &cmyk);
    convert(&cmyk, .cmyk8, &[3]u8{ 128, 64, 0 }, .rgb8, 1);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 128 }, &cmyk);
    var rgb: [3]u8 = undefined;
    convert(&rgb, .rgb8, &cmyk, .cmyk8, 1);
    try testing.expectEqualSlices(u8, &.{ 128, 64, 0 }, &rgb);
    // Inks to inks keep the inks; float multiplies.
    var wide: [4]u16 = undefined;
    convert(std.mem.asBytes(&wide), .cmyk16, &[4]u8{ 1, 2, 3, 4 }, .cmyk8, 1);
    try testing.expectEqualSlices(u16, &.{ 257, 514, 771, 1028 }, &wide);
    var f: [4]f32 = undefined;
    convert(std.mem.asBytes(&f), .rgba_f32, &[4]u8{ 255, 204, 0, 204 }, .cmyk8, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.8), f[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.64), f[1], 1e-6);
    try testing.expectEqual(@as(f32, 0), f[2]);
    try testing.expectEqual(@as(f32, 1), f[3]);
}

test "float samples" {
    var out: [16]u8 = undefined;
    const in = [4]f32{ std.math.nan(f32), -1, 0.5, 2 };
    convert(&out, .rgba8, std.mem.asBytes(&in), .rgba_f32, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 128, 255 }, out[0..4]);
    convert(&out, .rgba_f32, &[4]u8{ 0, 51, 255, 255 }, .rgba8, 1);
    const f = std.mem.bytesAsValue([4]f32, out[0..16]).*;
    try testing.expectEqual(@as(f32, 0), f[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.2), f[1], 1e-7);
    try testing.expectEqual(@as(f32, 1), f[3]);
    // Premultiplied float keeps values outside 0 to 1.
    const hdr = [4]f32{ 4, 0, 0, 0.5 };
    convert(&out, .rgba_f32_premul, std.mem.asBytes(&hdr), .rgba_f32, 1);
    try testing.expectEqual(@as(f32, 2), std.mem.bytesAsValue([4]f32, out[0..16])[0]);
    // RGB and gray float: alpha dropped, Rec. 601 luma, and rounding to
    // bytes through both the SIMD path (16 samples) and the general one.
    var rgb: [3]f32 = undefined;
    convert(std.mem.asBytes(&rgb), .rgb_f32, &[4]u8{ 255, 51, 0, 7 }, .rgba8, 1);
    try testing.expectEqual([3]f32{ 1, 0.2, 0 }, rgb);
    var y: f32 = undefined;
    convert(std.mem.asBytes(&y), .gray_f32, std.mem.asBytes(&rgb), .rgb_f32, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.299 + 0.587 * 0.2), y, 1e-6);
    const nan = std.math.nan(f32);
    const grays = [16]f32{ 0.5, 1.5, -1, nan, 0.25, 1, 0, 0.75, 2.0 / 255.0, 0.1, 0.9, 0.3, 0.6, 0.002, 0.998, 0.4 };
    var bytes: [16]u8 = undefined;
    convert(&bytes, .gray8, std.mem.asBytes(&grays), .gray_f32, 16);
    const want = [16]u8{ 128, 255, 0, 0, 64, 255, 0, 191, 2, 26, 230, 77, 153, 1, 254, 102 };
    try testing.expectEqualSlices(u8, &want, &bytes);
    convert(&bytes, .rgb8, std.mem.asBytes(&grays), .gray_f32, 1);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128 }, bytes[0..3]);
    // A gray sample comes back exactly through color, even past 1.
    for ([_]f32{ 0.3, 1.7, -0.25, 0.1 }) |v| {
        var color: [4]f32 = undefined;
        convert(std.mem.asBytes(&color), .rgba_f32, std.mem.asBytes(&v), .gray_f32, 1);
        var back: f32 = undefined;
        convert(std.mem.asBytes(&back), .gray_f32, std.mem.asBytes(&color), .rgba_f32, 1);
        try testing.expectEqual(v, back);
    }
}

test "convertBuffer" {
    var a = [_]u8{ 1, 2, 3, 4, 5, 6, 0, 0, 7, 8, 9, 10, 11, 12, 0, 0 };
    var b: [16]u8 = undefined;
    const src = try PixelBuffer.initStride(&a, .rgb8, 2, 2, 8);
    const dst = try PixelBuffer.init(&b, .bgra8, 2, 2);
    try convertBuffer(dst, src);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 255 }, &b);
    try testing.expectError(error.SizeMismatch, convertBuffer(dst.sub(0, 0, 1, 2), src));
}
