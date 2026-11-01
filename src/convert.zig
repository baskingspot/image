//! Conversion and swizzle between pixel formats.
//!
//! Every pair of `PixelFormat`s converts. Integer formats convert through
//! 16-bit RGBA, and any pair with a float side through `f32` RGBA. Integer
//! results are Wuffs's pixel swizzler's on every pair it has
//! (docs/slop/results/convert-rounding-20261101.md), with these
//! definitions:
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
//! - A format without alpha gets the color composited onto black: a
//!   straight source is premultiplied and a premultiplied one's alpha is
//!   dropped. A source without alpha is opaque.
//! - Gray from color is `(19595 R + 38470 G + 7471 B + 32768) >> 16` on
//!   16-bit samples (Rec. 601 luma), and `0.299 R + 0.587 G + 0.114 B` with
//!   those weights in float. Color from gray repeats the gray sample.
//!
//! The pairs decoders meet most, the byte swizzles, adding and dropping
//! alpha, premultiplying, gray to color, and 8 to 16 bits and back, have
//! SIMD paths that give the same bytes as the general path.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

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
    /// pixels of their format.
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
/// premultiplied (`premul`) when the destination is premultiplied or has no
/// alpha, and straight otherwise; the unpack premultiplies or
/// unpremultiplies to match, so a premultiplied source's samples above
/// their alpha come through a premultiplied pivot as they are.
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
        const premul = dst.isPremultiplied() or !dst.hasAlpha();
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

inline fn load(comptime f: PixelFormat, bytes: []const u8, pixel: usize, channel: u2) u32 {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    return switch (comptime f.sample()) {
        .u8 => bytes[at],
        .u16 => std.mem.readInt(u16, bytes[at..][0..2], builtin.cpu.arch.endian()),
        .f32 => unreachable,
    };
}

inline fn loadFloat(comptime f: PixelFormat, bytes: []const u8, pixel: usize, channel: u2) f32 {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    return switch (comptime f.sample()) {
        .u8 => @as(f32, @floatFromInt(bytes[at])) / 255,
        .u16 => @as(f32, @floatFromInt(std.mem.readInt(u16, bytes[at..][0..2], builtin.cpu.arch.endian()))) / 65535,
        .f32 => @bitCast(std.mem.readInt(u32, bytes[at..][0..4], builtin.cpu.arch.endian())),
    };
}

inline fn store(comptime f: PixelFormat, bytes: []u8, pixel: usize, channel: u2, v: u16) void {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    switch (comptime f.sample()) {
        .u8 => bytes[at] = @intCast(narrow(v)),
        .u16 => std.mem.writeInt(u16, bytes[at..][0..2], v, builtin.cpu.arch.endian()),
        .f32 => unreachable,
    }
}

inline fn storeFloat(comptime f: PixelFormat, bytes: []u8, pixel: usize, channel: u2, v: f32) void {
    const at = (pixel * f.channelCount() + channel) * f.bytesPerSample();
    switch (comptime f.sample()) {
        .u8 => bytes[at] = @intCast(quantize(v, 255)),
        .u16 => std.mem.writeInt(u16, bytes[at..][0..2], @intCast(quantize(v, 65535)), builtin.cpu.arch.endian()),
        .f32 => std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(v), builtin.cpu.arch.endian()),
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

inline fn unpack16Pixel(comptime f: PixelFormat, comptime premul: bool, bytes: []const u8, pixel: usize) [4]u16 {
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
    const c = comptime f.channels();
    if (c.y) |y| {
        storeFloat(f, bytes, pixel, y, 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]);
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
        if (src.channelCount() == 4 and dst.channelCount() == 3) {
            return switch (swapped) {
                inline else => |sw| switch (src.isPremultiplied()) {
                    inline else => |p| Drop4(sw, !p).run,
                },
            };
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
    return null;
}

fn copy(dst: []u8, src: []const u8, n: usize) void {
    _ = n;
    @memcpy(dst, src);
}

/// Blocks of `lanes` pixels, then the tail through the general path.
fn blocks(
    comptime dst: PixelFormat,
    comptime src: PixelFormat,
    comptime lanes: usize,
    out: []u8,
    in: []const u8,
    n: usize,
    comptime block: fn (*[lanes * dst.bytesPerPixel()]u8, *const [lanes * src.bytesPerPixel()]u8) void,
) void {
    const db = comptime dst.bytesPerPixel();
    const sb = comptime src.bytesPerPixel();
    const full = n / lanes * lanes;
    var i: usize = 0;
    while (i < full) : (i += lanes) {
        block(out[i * db ..][0 .. lanes * db], in[i * sb ..][0 .. lanes * sb]);
    }
    const stages = comptime Stages.init(dst, src);
    stages.run(out[full * db ..], in[full * sb ..], n - full);
}

/// RGBA and BGRA, either way: swap the first and third samples.
fn Swap4(comptime T: type) type {
    return struct {
        const lanes = 16;
        const f: PixelFormat = if (T == u8) .rgba8 else .rgba16;
        const g: PixelFormat = if (T == u8) .bgra8 else .bgra16;
        const W = if (T == u8) u32 else u64;
        const shift = @bitSizeOf(T) * 2;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(g, f, lanes, out, in, n, block);
        }
        fn block(o: *[lanes * f.bytesPerPixel()]u8, i: *const [lanes * f.bytesPerPixel()]u8) void {
            // As whole pixels: keep green and alpha, exchange the other two.
            // The masks name byte positions in memory, so build them from
            // bytes rather than as integers.
            const V = @Vector(lanes, W);
            const keep: W = @bitCast(@as([4]T, .{ 0, std.math.maxInt(T), 0, std.math.maxInt(T) }));
            const first: W = @bitCast(@as([4]T, .{ std.math.maxInt(T), 0, 0, 0 }));
            const v: V = @bitCast(i.*);
            const k: V = @splat(keep);
            const lo: V = @splat(first);
            const s: @Vector(lanes, std.math.Log2Int(W)) = @splat(shift);
            const third = if (builtin.cpu.arch.endian() == .little) (v >> s) & lo else (v << s) & lo;
            const firsts = if (builtin.cpu.arch.endian() == .little) (v & lo) << s else (v & lo) >> s;
            o.* = @bitCast((v & k) | third | firsts);
        }
    };
}

/// RGB and BGR, either way.
fn Swap3(comptime T: type) type {
    return struct {
        const lanes = 16;
        const f: PixelFormat = if (T == u8) .rgb8 else .rgb16;
        const g: PixelFormat = if (T == u8) .bgr8 else .bgr16;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(g, f, lanes, out, in, n, block);
        }
        fn block(o: *[lanes * f.bytesPerPixel()]u8, i: *const [lanes * f.bytesPerPixel()]u8) void {
            const mask = comptime m: {
                var m: [lanes * 3]i32 = undefined;
                for (0..lanes) |p| {
                    for (0..3) |ch| m[p * 3 + ch] = p * 3 + (2 - ch);
                }
                break :m m;
            };
            const v: @Vector(lanes * 3, T) = @bitCast(i.*);
            o.* = @bitCast(@shuffle(T, v, undefined, mask));
        }
    };
}

/// RGB or BGR to RGBA or BGRA, opaque.
fn Expand3(comptime swap: bool) type {
    return struct {
        const lanes = 16;
        const dst: PixelFormat = if (swap) .bgra8 else .rgba8;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(dst, .rgb8, lanes, out, in, n, block);
        }
        fn block(o: *[lanes * 4]u8, i: *const [lanes * 3]u8) void {
            // Four pixels at a time, each a 16-byte shuffle (pshufb, tbl)
            // of 16 input bytes; the last group loads the block's last 16
            // bytes so no load passes its end. Alpha is ORed in.
            const alpha: @Vector(16, u8) = comptime a: {
                var a: [16]u8 = @splat(0);
                for (0..4) |p| a[p * 4 + 3] = 255;
                break :a a;
            };
            inline for (0..4) |g| {
                const at = @min(g * 12, lanes * 3 - 16);
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

/// RGBA or BGRA to RGB or BGR: premultiplied alpha dropped, straight alpha
/// composited onto black (`composite`).
fn Drop4(comptime swap: bool, comptime composite: bool) type {
    return struct {
        const lanes = 16;
        const dst: PixelFormat = if (swap) .bgr8 else .rgb8;
        const src: PixelFormat = if (composite) .rgba8 else .rgba8_premul;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(dst, src, lanes, out, in, n, block);
        }
        fn block(o: *[lanes * 3]u8, i: *const [lanes * 4]u8) void {
            const order = comptime m: {
                var m: [lanes * 3]i32 = undefined;
                var a: [lanes * 4]i32 = undefined;
                for (0..lanes) |p| {
                    for (0..3) |ch| m[p * 3 + ch] = p * 4 + (if (swap) 2 - ch else ch);
                    for (0..4) |ch| a[p * 4 + ch] = p * 4 + 3;
                }
                break :m .{ m, a };
            };
            var v: @Vector(lanes * 4, u8) = i.*;
            // Whole pixels premultiply faster than the 48 color lanes.
            if (composite) v = premultiply(lanes * 4, v, @shuffle(u8, v, undefined, order[1]));
            o.* = @shuffle(u8, v, undefined, order[0]);
        }
    };
}

/// Straight RGBA to premultiplied RGBA or BGRA.
fn Premultiply(comptime swap: bool) type {
    return struct {
        const lanes = 16;
        const dst: PixelFormat = if (swap) .bgra8_premul else .rgba8_premul;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(dst, .rgba8, lanes, out, in, n, block);
        }
        fn block(o: *[lanes * 4]u8, i: *const [lanes * 4]u8) void {
            const order = comptime m: {
                var m: [lanes * 4]i32 = undefined;
                var a: [lanes * 4]i32 = undefined;
                for (0..lanes) |p| {
                    for (0..4) |ch| {
                        m[p * 4 + ch] = p * 4 + (if (swap and ch < 3) 2 - ch else ch);
                        a[p * 4 + ch] = if (ch == 3) -1 else p * 4 + 3;
                    }
                }
                break :m .{ m, a };
            };
            const v: @Vector(lanes * 4, u8) = i.*;
            const full: @Vector(1, u8) = .{255};
            // The alpha lanes multiply by 255, which leaves them unchanged.
            o.* = premultiply(lanes * 4, @shuffle(u8, v, undefined, order[0]), @shuffle(u8, v, full, order[1]));
        }
    };
}

/// The general path's 8-bit premultiply, `((c * 257) * (a * 257) / 65535) >> 8`,
/// which is `c * a * 257 / 65280` truncated. For every product `t` of two
/// bytes that is `(t + ((t + (t >> 8)) >> 7)) >> 8` in 16-bit lanes, as the
/// test against Wuffs's values checks over all of them.
inline fn premultiply(comptime n: usize, c: @Vector(n, u8), a: @Vector(n, u8)) @Vector(n, u8) {
    const V = @Vector(n, u16);
    const t = @as(V, c) * @as(V, a);
    // No sum passes 65534.
    return @intCast((t + ((t + (t >> @splat(8))) >> @splat(7))) >> @splat(8));
}

/// Gray to RGB, RGBA, or BGRA (the same bytes), opaque.
fn GrayTo(comptime count: usize) type {
    return struct {
        const lanes = 16;
        const dst: PixelFormat = if (count == 3) .rgb8 else .rgba8;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(dst, .gray8, lanes, out, in, n, block);
        }
        fn block(o: *[lanes * count]u8, i: *const [lanes]u8) void {
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

/// 16-bit samples to 8, same layout.
fn narrowAll(dst: []u8, src: []const u8, n: usize) void {
    _ = n;
    const lanes = 32;
    const count = dst.len;
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const v: @Vector(lanes, u16) = @bitCast(src[2 * i ..][0 .. 2 * lanes].*);
        const p: @Vector(lanes, u8) = @intCast(v >> @splat(8));
        dst[i..][0..lanes].* = p;
    }
    while (i < count) : (i += 1) {
        dst[i] = @intCast(narrow(std.mem.readInt(u16, src[2 * i ..][0..2], builtin.cpu.arch.endian())));
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
    while (i < count) : (i += 1) {
        std.mem.writeInt(u16, dst[2 * i ..][0..2], @as(u16, src[i]) * 257, builtin.cpu.arch.endian());
    }
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
        std.mem.writeInt(u32, bytes[i..][0..4], @bitCast(v), builtin.cpu.arch.endian());
    }
}

test "every SIMD path gives the general path's bytes" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var src: [201 * 16]u8 = undefined;
    var want: [201 * 16]u8 = undefined;
    var got: [201 * 16]u8 = undefined;
    var fast_pairs: usize = 0;
    for (std.enums.values(PixelFormat)) |d| {
        for (std.enums.values(PixelFormat)) |s| {
            const c: Converter = .init(d, s);
            if (!c.isFast()) continue;
            fast_pairs += 1;
            for ([_]usize{ 0, 1, 15, 16, 17, 31, 33, 64, 65, 130, 200 }) |n| {
                fill(random, src[0 .. n * s.bytesPerPixel()], s);
                Stages.init(d, s).run(want[0 .. n * d.bytesPerPixel()], src[0 .. n * s.bytesPerPixel()], n);
                @memset(&got, 0xAA);
                c.run(&got, &src, n);
                const len = n * d.bytesPerPixel();
                testing.expectEqualSlices(u8, want[0..len], got[0..len]) catch |err| {
                    std.debug.print("{t} from {t}, {d} pixels\n", .{ d, s, n });
                    return err;
                };
                // Nothing past the last pixel is written.
                try testing.expectEqual(0xAA, got[n * d.bytesPerPixel()]);
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
    var out3: [256 * 256][3]u8 = undefined;
    var out16: [256 * 256][4]u16 = undefined;
    for ([_]bool{ true, false }) |simd| {
        const run = struct {
            fn run(fast_path: bool, dst: []u8, d: PixelFormat, src: []const u8, s: PixelFormat) void {
                const n = src.len / s.bytesPerPixel();
                if (fast_path) convert(dst, d, src, s, n) else Stages.init(d, s).run(dst, src, n);
            }
        }.run;
        run(simd, std.mem.sliceAsBytes(&out), .rgba8_premul, bytes, .rgba8);
        run(simd, std.mem.sliceAsBytes(&out3), .rgb8, bytes, .rgba8);
        for (straight, out, out3) |in, p, q| {
            const a: u32 = in[3];
            for (0..3) |ch| {
                const want = in[ch] * a * 257 / (255 * 256);
                try testing.expectEqual(want, p[ch]);
                // Dropping straight alpha composites onto black.
                try testing.expectEqual(want, q[ch]);
            }
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
    // Dropping alpha composites onto black.
    convert(&out, .bgr8, &[4]u8{ 1, 2, 3, 255 }, .rgba8, 1);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, out[0..3]);
    convert(&out, .bgr8, &[4]u8{ 1, 2, 3, 0 }, .rgba8, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, out[0..3]);
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
