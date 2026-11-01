//! Conversion and swizzle between pixel formats.
//!
//! Every pair of `PixelFormat`s converts. Integer formats convert through
//! straight 16-bit RGBA, and any pair with a float side through straight
//! `f32` RGBA, with these definitions:
//!
//! - Widening an 8-bit sample multiplies by 257; narrowing a 16-bit one
//!   rounds `c / 257` to nearest. A float sample is `c / max` one way and
//!   `c * max` rounded to nearest, clamped to 0..max, the other; NaN is 0.
//! - Premultiplying rounds `c * a / max` to nearest; unpremultiplying rounds
//!   `c * max / a`, clamped to max, and gives 0 where `a` is 0. Float
//!   conversions multiply and divide without rounding or clamping.
//! - Gray from color is `(19595 R + 38470 G + 7471 B + 32768) >> 16` on
//!   16-bit samples (Rec. 601 luma), and `0.299 R + 0.587 G + 0.114 B` with
//!   those weights in float. Color from gray repeats the gray sample.
//! - A format without alpha drops the (unpremultiplied) alpha; a source
//!   without alpha is opaque.
//!
//! These make the 8-bit results exact: narrowing the 16-bit premultiply or
//! unpremultiply of widened samples gives the same value as rounding the
//! 8-bit arithmetic directly. The pairs decoders meet most, the byte
//! swizzles, adding and dropping alpha, premultiplying, gray to color, and
//! 8 to 16 bits and back, have SIMD paths that give the same bytes as the
//! general path.

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
        return .{ .dst = dst, .src = src, .fast = fast(dst, src), .stages = .init(dst, src) };
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
/// the destination, through 16-bit or float RGBA. Premultiplied to
/// premultiplied stays premultiplied in the pivot (`keep`), so samples
/// above their alpha come through as they are.
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
        const keep = src.isPremultiplied() and dst.isPremultiplied();
        if (dst.sample() == .f32 or src.sample() == .f32) {
            return switch (keep) {
                inline else => |k| .{ .float = .{
                    .unpack = switch (src) {
                        inline else => |f| Stage(f, k).unpackFloat,
                    },
                    .pack = switch (dst) {
                        inline else => |f| Stage(f, k).packFloat,
                    },
                } },
            };
        }
        return switch (keep) {
            inline else => |k| .{ .int = .{
                .unpack = switch (src) {
                    inline else => |f| Stage(f, k).unpack16,
                },
                .pack = switch (dst) {
                    inline else => |f| Stage(f, k).pack16,
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

fn Stage(comptime f: PixelFormat, comptime keep: bool) type {
    return struct {
        fn unpack16(in: []const u8, pivot: *[chunk][4]u16, m: usize) void {
            for (pivot[0..m], 0..) |*p, j| p.* = unpack16Pixel(f, keep, in, j);
        }
        fn pack16(out: []u8, pivot: *const [chunk][4]u16, m: usize) void {
            for (pivot[0..m], 0..) |p, j| pack16Pixel(f, keep, out, j, p);
        }
        fn unpackFloat(in: []const u8, pivot: *[chunk][4]f32, m: usize) void {
            for (pivot[0..m], 0..) |*p, j| p.* = unpackFloatPixel(f, keep, in, j);
        }
        fn packFloat(out: []u8, pivot: *const [chunk][4]f32, m: usize) void {
            for (pivot[0..m], 0..) |p, j| packFloatPixel(f, keep, out, j, p);
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

/// `c / 257` rounded to nearest: 16 bits to 8.
inline fn narrow(c: u32) u32 {
    return (c + 128) / 257;
}

/// A float sample to an integer one: rounded, clamped, NaN to 0.
inline fn quantize(v: f32, comptime max: f32) u32 {
    if (!(v > 0)) return 0;
    if (v >= 1) return @intFromFloat(max);
    return @intFromFloat(@round(v * max));
}

inline fn unpack16Pixel(comptime f: PixelFormat, comptime keep: bool, bytes: []const u8, pixel: usize) [4]u16 {
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
    if (comptime f.isPremultiplied() and !keep) {
        const a = v[3];
        for (v[0..3]) |*s| s.* = if (a == 0) 0 else @min(65535, (s.* * 65535 + a / 2) / a);
    }
    return .{ @intCast(v[0]), @intCast(v[1]), @intCast(v[2]), @intCast(v[3]) };
}

inline fn pack16Pixel(comptime f: PixelFormat, comptime keep: bool, bytes: []u8, pixel: usize, p: [4]u16) void {
    const c = comptime f.channels();
    var v: [3]u32 = .{ p[0], p[1], p[2] };
    if (comptime f.isPremultiplied() and !keep) {
        for (&v) |*s| s.* = (s.* * p[3] + 32767) / 65535;
    }
    if (c.y) |y| {
        // Luma of premultiplied samples is the premultiplied luma.
        const l = (19595 * v[0] + 38470 * v[1] + 7471 * v[2] + 32768) >> 16;
        store(f, bytes, pixel, y, @intCast(l));
    } else {
        store(f, bytes, pixel, c.r.?, @intCast(v[0]));
        store(f, bytes, pixel, c.g.?, @intCast(v[1]));
        store(f, bytes, pixel, c.b.?, @intCast(v[2]));
    }
    if (c.a) |a| store(f, bytes, pixel, a, p[3]);
}

inline fn unpackFloatPixel(comptime f: PixelFormat, comptime keep: bool, bytes: []const u8, pixel: usize) [4]f32 {
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
    if (comptime f.isPremultiplied() and !keep) {
        const a = v[3];
        for (v[0..3]) |*s| {
            s.* = if (a == 0) 0 else s.* / a;
            // An integer sample is clamped as the 16-bit path clamps it.
            if (comptime f.sample() != .f32) s.* = @min(s.*, 1);
        }
    }
    return v;
}

inline fn packFloatPixel(comptime f: PixelFormat, comptime keep: bool, bytes: []u8, pixel: usize, p: [4]f32) void {
    const c = comptime f.channels();
    var v: [3]f32 = .{ p[0], p[1], p[2] };
    if (comptime f.isPremultiplied() and !keep) {
        for (&v) |*s| s.* *= p[3];
    }
    if (c.y) |y| {
        storeFloat(f, bytes, pixel, y, 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2]);
    } else {
        storeFloat(f, bytes, pixel, c.r.?, v[0]);
        storeFloat(f, bytes, pixel, c.g.?, v[1]);
        storeFloat(f, bytes, pixel, c.b.?, v[2]);
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
            const mask = comptime m: {
                var m: [lanes * 4]i32 = undefined;
                for (0..lanes) |p| {
                    for (0..3) |ch| m[p * 4 + ch] = p * 3 + (if (swap) 2 - ch else ch);
                    m[p * 4 + 3] = -1;
                }
                break :m m;
            };
            const v: @Vector(lanes * 3, u8) = i.*;
            const opaque_: @Vector(1, u8) = .{255};
            o.* = @shuffle(u8, v, opaque_, mask);
        }
    };
}

/// RGBA or BGRA to RGB or BGR, dropping straight alpha.
fn Drop4(comptime swap: bool) type {
    return struct {
        const lanes = 16;
        const dst: PixelFormat = if (swap) .bgr8 else .rgb8;
        fn run(out: []u8, in: []const u8, n: usize) void {
            blocks(dst, .rgba8, lanes, out, in, n, block);
        }
        fn block(o: *[lanes * 3]u8, i: *const [lanes * 4]u8) void {
            const mask = comptime m: {
                var m: [lanes * 3]i32 = undefined;
                for (0..lanes) |p| {
                    for (0..3) |ch| m[p * 3 + ch] = p * 4 + (if (swap) 2 - ch else ch);
                }
                break :m m;
            };
            const v: @Vector(lanes * 4, u8) = i.*;
            o.* = @shuffle(u8, v, undefined, mask);
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
            const c: @Vector(lanes * 4, u16) = @shuffle(u8, v, undefined, order[0]);
            // The alpha lanes multiply by 255, which leaves them unchanged.
            const a: @Vector(lanes * 4, u16) = @shuffle(u8, v, full, order[1]);
            // t / 255 rounded is (t + 128 + (t + 128) / 256) / 256.
            const t = c * a + @as(@Vector(lanes * 4, u16), @splat(128));
            const p: @Vector(lanes * 4, u8) = @intCast((t + (t >> @splat(8))) >> @splat(8));
            o.* = p;
        }
    };
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
            const mask = comptime m: {
                var m: [lanes * count]i32 = undefined;
                for (0..lanes) |p| {
                    for (0..count) |ch| m[p * count + ch] = if (ch == 3) -1 else p;
                }
                break :m m;
            };
            const v: @Vector(lanes, u8) = i.*;
            const opaque_: @Vector(1, u8) = .{255};
            o.* = @shuffle(u8, v, opaque_, mask);
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
        const w: @Vector(lanes, u32) = v;
        const half: @Vector(lanes, u32) = @splat(128);
        const p: @Vector(lanes, u8) = @intCast((w + half) / @as(@Vector(lanes, u32), @splat(257)));
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

test "8-bit premultiply and unpremultiply round exactly" {
    for (0..256) |a| {
        for (0..256) |c| {
            const straight = [4]u8{ @intCast(c), @intCast(255 - c), 0, @intCast(a) };
            var out: [4]u8 = undefined;
            // Through the 16-bit pivot, the general path.
            Stages.init(.rgba8_premul, .rgba8).run(&out, &straight, 1);
            try testing.expectEqual((2 * c * a + 255) / 510, out[0]);
            try testing.expectEqual((2 * (255 - c) * a + 255) / 510, out[1]);
            try testing.expectEqual(a, out[3]);
            Stages.init(.rgba8, .rgba8_premul).run(&out, &straight, 1);
            const unpremul: usize = if (a == 0) 0 else @min(255, (2 * c * 255 + a) / (2 * a));
            try testing.expectEqual(unpremul, out[0]);
        }
    }
}

test "16 to 8 bits rounds to nearest" {
    var c: u32 = 0;
    while (c <= 65535) : (c += 1) {
        const in = std.mem.toBytes(@as(u16, @intCast(c)));
        var out: [1]u8 = undefined;
        Stages.init(.gray8, .gray16).run(&out, &in, 1);
        try testing.expectEqual((2 * c + 257) / 514, out[0]);
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
