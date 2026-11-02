//! What happens to a decompressed row before it reaches the caller: byte
//! order, the predictors (TIFF 6.0 section 14, and Adobe's Technical Note
//! 3 for floating point), and the expansion of any sample layout to the
//! native pixel format.
//!
//! The native format holds 8-bit samples for 1 to 8 bits, 16-bit samples
//! for 9 to 32 bits, and f32 for floating point, as gray, gray and alpha,
//! RGB, or RGBA. Integer samples scale exactly: round(v * 255 / max) or
//! round(v * 65535 / max), where max is 2^bits - 1; 8 and 16 bits are
//! kept as they are, and 17 to 32 bits lose their low bits. Signed samples
//! are offset by half their range, so the most negative value is 0.
//! MinIsWhite gray is inverted. CMYK keeps its inks in `cmyk8` or
//! `cmyk16`, which store them inverted: the maximum minus each scaled ink
//! (float inks 1 - v, rounded and clamped to 16 bits), with any alpha
//! dropped; `image.convert` makes color of them. YCbCr becomes
//! RGB by the specification's equations (section 21), with
//! ReferenceBlackWhite and YCbCrCoefficients, rounded and clamped.
//! Floating point samples are kept as they are, not scaled or clamped, and
//! gray ones fill R, G, and B.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const PixelFormat = @import("../pixel.zig").PixelFormat;
const ifd = @import("ifd.zig");

pub const native_endian = builtin.cpu.arch.endian();

/// Reverses the bits of every byte, for FillOrder 2.
pub fn reverseBits(buf: []u8) void {
    for (buf) |*b| b.* = @bitReverse(b.*);
}

/// Reverses the byte order of each `bytes`-byte sample in `buf`.
pub fn swap(buf: []u8, bytes: u8) void {
    switch (bytes) {
        inline 2, 3, 4, 8 => |n| {
            var i: usize = 0;
            while (i + n <= buf.len) : (i += n) std.mem.reverse(u8, buf[i..][0..n]);
        },
        else => {},
    }
}

/// Undoes horizontal differencing (predictor 2) on one row of machine-order
/// samples, `stride` samples per pixel.
pub fn horizontal(buf: []u8, bytes: u8, stride: usize) void {
    // The usual layouts: 8-bit samples as prefix sums over vectors, and
    // 16-bit ones with a pixel's running sums in registers, so that no
    // sample waits on the store of the one a pixel before it.
    switch (stride) {
        inline 1...4 => |s| switch (bytes) {
            1 => return horizontalVector(s, buf),
            2 => return horizontalFixed(u16, s, buf),
            else => {},
        },
        else => {},
    }
    switch (bytes) {
        1 => {
            var i: usize = stride;
            while (i < buf.len) : (i += 1) buf[i] +%= buf[i - stride];
        },
        inline 2, 4, 8 => |n| {
            const T = @Int(.unsigned, 8 * n);
            const count = buf.len / n;
            var i: usize = stride;
            while (i < count) : (i += 1) {
                const prev = std.mem.readInt(T, buf[(i - stride) * n ..][0..n], native_endian);
                const cur = std.mem.readInt(T, buf[i * n ..][0..n], native_endian);
                std.mem.writeInt(T, buf[i * n ..][0..n], cur +% prev, native_endian);
            }
        },
        else => unreachable,
    }
}

fn horizontalVector(comptime s: usize, buf: []u8) void {
    const n = 16;
    const V = @Vector(n, u8);
    if (buf.len < s) return;
    // The previous block's outputs, whose last `s` lanes carry each
    // channel's sum into the next block.
    var last: [n]u8 = @splat(0);
    last[n - s ..].* = buf[0..s].*;
    var prev: V = last;
    var i: usize = s;
    while (i + n <= buf.len) : (i += n) {
        var x: V = buf[i..][0..n].*;
        comptime var k = s;
        inline while (k < n) : (k *= 2) x +%= @shuffle(u8, x, @as(V, @splat(0)), shiftMask(n, k));
        x +%= @shuffle(u8, prev, undefined, carryMask(n, s));
        buf[i..][0..n].* = x;
        prev = x;
    }
    while (i < buf.len) : (i += 1) buf[i] +%= buf[i - s];
}

/// Lane j takes lane j - k, or 0 from the second vector below k.
fn shiftMask(comptime n: usize, comptime k: usize) @Vector(n, i32) {
    var m: [n]i32 = undefined;
    for (&m, 0..) |*v, j| v.* = if (j >= k) @intCast(j - k) else ~@as(i32, 0);
    return m;
}

/// Lane j takes the last lane before the block of its channel: the
/// previous block's lane n - s + j mod s.
fn carryMask(comptime n: usize, comptime s: usize) @Vector(n, i32) {
    var m: [n]i32 = undefined;
    for (&m, 0..) |*v, j| v.* = @intCast(n - s + j % s);
    return m;
}

fn horizontalFixed(comptime T: type, comptime s: usize, buf: []u8) void {
    const n = @sizeOf(T);
    const px = s * n;
    if (buf.len < px) return;
    var acc: [s]T = undefined;
    inline for (0..s) |k| acc[k] = std.mem.readInt(T, buf[k * n ..][0..n], native_endian);
    var i: usize = px;
    while (i + px <= buf.len) : (i += px) {
        const p = buf[i..][0..px];
        inline for (0..s) |k| {
            acc[k] +%= std.mem.readInt(T, p[k * n ..][0..n], native_endian);
            std.mem.writeInt(T, p[k * n ..][0..n], acc[k], native_endian);
        }
    }
    // A partial pixel at the end, which a line of whole pixels never has.
    inline for (0..s) |k| {
        if (i + (k + 1) * n <= buf.len) {
            acc[k] +%= std.mem.readInt(T, buf[i + k * n ..][0..n], native_endian);
            std.mem.writeInt(T, buf[i + k * n ..][0..n], acc[k], native_endian);
        }
    }
}

/// Undoes the floating point predictor (predictor 3) on one row: byte
/// differencing with a stride of a pixel's samples, over the row's bytes
/// arranged most significant first. Leaves machine-order samples in `buf`,
/// using `temp`, as long.
pub fn floating(buf: []u8, temp: []u8, bytes: u8, stride: usize) void {
    var i: usize = stride;
    while (i < buf.len) : (i += 1) buf[i] +%= buf[i - stride];
    const count = buf.len / bytes;
    @memcpy(temp[0..buf.len], buf);
    for (0..count) |j| {
        for (0..bytes) |k| {
            // Byte k of each sample, most significant first.
            const at = if (native_endian == .big) k else bytes - 1 - k;
            buf[j * bytes + at] = temp[k * count + j];
        }
    }
}

/// The native format of a page with these fields.
pub fn nativeFormat(p: *const ifd.Page, palette_8bit: bool) PixelFormat {
    if (p.model() == .cmyk) return if (p.sample == .float or p.bits > 8) .cmyk16 else .cmyk8;
    const alpha = p.alpha();
    const premul = alpha == .premul;
    if (p.sample == .float) return if (premul) .rgba_f32_premul else .rgba_f32;
    const wide = p.bits > 8;
    return switch (p.model()) {
        .palette => if (palette_8bit) .rgb8 else .rgb16,
        // YCbCr is 8-bit but in JPEG data.
        .ycbcr => if (wide) .rgb16 else .rgb8,
        .gray => if (alpha == null)
            (if (wide) .gray16 else .gray8)
        else if (wide)
            (if (premul) .gray_alpha16_premul else .gray_alpha16)
        else
            (if (premul) .gray_alpha8_premul else .gray_alpha8),
        .cmyk => unreachable,
        .rgb => if (alpha == null)
            (if (wide) .rgb16 else .rgb8)
        else if (wide)
            (if (premul) .rgba16_premul else .rgba16)
        else
            (if (premul) .rgba8_premul else .rgba8),
    };
}

/// The smallest native format that holds both `a` and `b`, such that a
/// page decoded to it and then converted gets the same pixels as one
/// decoded straight to the caller's format: color if either has color,
/// alpha if either has it, and the wider samples. Null if there is none:
/// for float and integer samples, premultiplied and straight alpha, and a
/// format with alpha that would be widened, since `image.convert` keeps
/// an 8-bit source's precision when it premultiplies or unpremultiplies,
/// and for inks with color or with inks of the other width, since
/// `image.convert` makes color from `cmyk8` and `cmyk16` at their own
/// depths.
pub fn join(a: PixelFormat, b: PixelFormat) ?PixelFormat {
    if (a == b) return a;
    if (a.isCmyk() or b.isCmyk()) return null;
    if ((a.sample() == .f32) != (b.sample() == .f32)) return null;
    if (a.hasAlpha() and b.hasAlpha() and a.isPremultiplied() != b.isPremultiplied()) return null;
    const alpha = a.hasAlpha() or b.hasAlpha();
    const premul = a.isPremultiplied() or b.isPremultiplied();
    if (a.sample() == .f32) return if (premul) .rgba_f32_premul else .rgba_f32;
    const wide = a.sample() == .u16 or b.sample() == .u16;
    const formats: [2][3]PixelFormat = if (a.isGray() and b.isGray())
        .{ .{ .gray8, .gray_alpha8, .gray_alpha8_premul }, .{ .gray16, .gray_alpha16, .gray_alpha16_premul } }
    else
        .{ .{ .rgb8, .rgba8, .rgba8_premul }, .{ .rgb16, .rgba16, .rgba16_premul } };
    const j = formats[@intFromBool(wide)][if (!alpha) 0 else if (premul) 2 else 1];
    if (a.hasAlpha() and a.sample() != j.sample() or b.hasAlpha() and b.sample() != j.sample()) return null;
    return j;
}

/// How a row's samples become native pixels.
pub const Expand = struct {
    model: ifd.Model,
    planar: bool,
    spp: u16,
    /// The channels read: color, then alpha if any.
    used: u16,
    bits: u16,
    sample: ifd.SampleKind,
    /// Bytes per sample, or 0 for samples packed below a byte or across
    /// bytes (any width but 8, 16, 24, 32, 64).
    bytes: u8,
    min_is_white: bool,
    /// Whether the alpha sample is associated.
    premul: bool,
    native: PixelFormat,
    max: u64,
    /// 1 to 7 bits: a sample value to 8 bits.
    scale8: [128]u8,
    ycc: Ycc,

    pub fn init(p: *const ifd.Page, native: PixelFormat) Expand {
        const bits = p.bits;
        var e: Expand = .{
            .model = p.model(),
            .planar = p.planar == 2 and p.spp > 1,
            .spp = p.spp,
            .used = p.colorChannels() + @as(u16, if (p.alpha() != null and !native.isCmyk()) 1 else 0),
            .bits = bits,
            .sample = p.sample,
            .bytes = sampleBytes(bits),
            .min_is_white = p.photometric.? == 0,
            .premul = p.alpha() == .premul,
            .native = native,
            .max = if (bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1,
            .scale8 = undefined,
            .ycc = .init(p),
        };
        if (bits < 8) {
            for (0..@as(usize, 1) << @intCast(bits)) |v| e.scale8[v] = @intCast((v * 255 + e.max / 2) / e.max);
        }
        return e;
    }

    /// Writes `n` native pixels from pixels `x0` onward of the row whose
    /// planes are `planes` (one for chunky data).
    pub fn run(e: *const Expand, planes: []const []const u8, x0: usize, n: usize, out: []u8) void {
        switch (e.sample) {
            .float => switch (e.bytes) {
                inline 2, 3, 4, 8 => |b| e.runFloat(b, planes, x0, n, out),
                else => unreachable,
            },
            else => switch (e.bytes) {
                inline 0, 1, 2, 3, 4 => |b| e.runInt(b, planes, x0, n, out),
                else => unreachable,
            },
        }
    }

    fn at(e: *const Expand, planes: []const []const u8, x: usize, c: usize) struct { []const u8, usize } {
        return if (e.planar) .{ planes[c], x } else .{ planes[0], x * e.spp + c };
    }

    fn runInt(e: *const Expand, comptime bytes: u8, planes: []const []const u8, x0: usize, n: usize, out: []u8) void {
        const wide = e.native.sample() == .u16;
        var o: usize = 0;
        for (x0..x0 + n) |x| {
            var v: [5]u32 = undefined;
            for (0..e.used) |c| {
                const plane, const i = e.at(planes, x, c);
                var s: u64 = readUint(bytes, plane, i, e.bits);
                if (e.sample == .int) s ^= @as(u64, 1) << @intCast(e.bits - 1);
                if (c == 0 and e.min_is_white and e.model == .gray and !e.premul) s = e.max - s;
                v[c] = if (wide)
                    (if (e.bits == 16) @intCast(s) else @intCast((s * 65535 + e.max / 2) / e.max))
                else if (e.bits == 8)
                    @intCast(s)
                else
                    e.scale8[@intCast(s)];
            }
            // Premultiplied white-is-zero gray is alpha minus the sample.
            if (e.min_is_white and e.model == .gray and e.premul) v[0] = v[e.used - 1] -| v[0];
            const m: u32 = if (wide) 65535 else 255;
            var px: [4]u32 = undefined;
            var k: usize = 0;
            switch (e.model) {
                .gray => {
                    px[0] = v[0];
                    k = 1;
                },
                .rgb => {
                    px[0..3].* = v[0..3].*;
                    k = 3;
                },
                .cmyk => {
                    for (&px, v[0..4]) |*o_, ink| o_.* = m - ink;
                    k = 4;
                },
                .ycbcr => {
                    const rgb = e.ycc.rgb(@intCast(v[0]), @intCast(v[1]), @intCast(v[2]));
                    px[0..3].* = .{ rgb[0], rgb[1], rgb[2] };
                    k = 3;
                },
                .palette => unreachable,
            }
            if (e.used > e.model.channels()) {
                px[k] = v[e.used - 1];
                k += 1;
            }
            if (wide) {
                for (px[0..k]) |c| {
                    std.mem.writeInt(u16, out[o..][0..2], @intCast(c), native_endian);
                    o += 2;
                }
            } else {
                for (px[0..k]) |c| {
                    out[o] = @intCast(c);
                    o += 1;
                }
            }
        }
    }

    fn runFloat(e: *const Expand, comptime bytes: u8, planes: []const []const u8, x0: usize, n: usize, out: []u8) void {
        var o: usize = 0;
        for (x0..x0 + n) |x| {
            var v: [5]f32 = undefined;
            for (0..e.used) |c| {
                const plane, const i = e.at(planes, x, c);
                v[c] = readFloat(bytes, plane, i);
            }
            if (e.model == .cmyk) {
                // Inverted inks in cmyk16, rounded and clamped, NaN to
                // full ink, as `image.convert` quantizes floats.
                for (v[0..4]) |ink| {
                    const i = 1 - ink;
                    const q: u16 = if (!(i > 0)) 0 else if (i >= 1) 65535 else @intFromFloat(@round(i * 65535));
                    std.mem.writeInt(u16, out[o..][0..2], q, native_endian);
                    o += 2;
                }
                continue;
            }
            var px: [4]f32 = .{ 0, 0, 0, 1 };
            switch (e.model) {
                .gray => px[0..3].* = .{ v[0], v[0], v[0] },
                .rgb => px[0..3].* = v[0..3].*,
                .cmyk, .ycbcr, .palette => unreachable,
            }
            if (e.used > e.model.channels()) px[3] = v[e.used - 1];
            for (px) |c| {
                std.mem.writeInt(u32, out[o..][0..4], @bitCast(c), native_endian);
                o += 4;
            }
        }
    }
};

/// Bytes per sample for widths read whole, 0 for bit-packed widths.
pub fn sampleBytes(bits: u16) u8 {
    return switch (bits) {
        8, 16, 24, 32, 64 => @intCast(bits / 8),
        else => 0,
    };
}

/// Sample `i` of a row: whole bytes in machine order, or `bits` wide,
/// packed most significant bit first.
pub inline fn readUint(comptime bytes: u8, row: []const u8, i: usize, bits: u16) u64 {
    return switch (bytes) {
        1 => row[i],
        2 => std.mem.readInt(u16, row[2 * i ..][0..2], native_endian),
        3 => std.mem.readInt(u24, row[3 * i ..][0..3], native_endian),
        4 => std.mem.readInt(u32, row[4 * i ..][0..4], native_endian),
        0 => readBits(row, i * @as(usize, bits), bits),
        else => unreachable,
    };
}

/// `bits` (at most 32) bits from bit `pos` of `row`, most significant
/// first.
pub fn readBits(row: []const u8, pos: usize, bits: u16) u64 {
    var v: u64 = 0;
    const first = pos / 8;
    const end = (pos + bits + 7) / 8;
    for (row[first..end]) |b| v = v << 8 | b;
    const tail: u6 = @intCast(end * 8 - (pos + bits));
    return (v >> tail) & ((@as(u64, 1) << @intCast(bits)) - 1);
}

fn readFloat(comptime bytes: u8, row: []const u8, i: usize) f32 {
    return switch (bytes) {
        2 => float16(std.mem.readInt(u16, row[2 * i ..][0..2], native_endian)),
        3 => float24(std.mem.readInt(u24, row[3 * i ..][0..3], native_endian)),
        4 => @bitCast(std.mem.readInt(u32, row[4 * i ..][0..4], native_endian)),
        8 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, row[8 * i ..][0..8], native_endian)))),
        else => unreachable,
    };
}

/// A 16-bit float. A NaN becomes the quiet NaN of its sign, whatever its
/// payload, as for 24-bit floats: how a payload widens depends on the CPU.
fn float16(v: u16) f32 {
    if (v & 0x7c00 == 0x7c00 and v & 0x3ff != 0) return @bitCast(@as(u32, v >> 15) << 31 | 0x7fc00000);
    return @floatCast(@as(f16, @bitCast(v)));
}

/// Adobe's 24-bit float: a sign, a 7-bit exponent biased by 63, and a
/// 16-bit fraction.
fn float24(v: u24) f32 {
    const sign: u32 = @as(u32, v >> 23) << 31;
    const exp: u32 = (v >> 16) & 0x7f;
    const frac: u32 = v & 0xffff;
    if (exp == 0x7f) return @bitCast(sign | @as(u32, if (frac == 0) 0x7f800000 else 0x7fc00000));
    if (exp == 0) {
        // Subnormal: frac * 2^(1 - 63 - 16).
        const m: f32 = @floatFromInt(frac);
        const r = m * std.math.pow(f32, 2, -78);
        return if (sign != 0) -r else r;
    }
    return @bitCast(sign | (exp + 127 - 63) << 23 | frac << 7);
}

/// YCbCr to RGB (section 21) for 8-bit samples.
pub const Ycc = struct {
    y: [256]f32,
    cb: [256]f32,
    cr: [256]f32,
    lr: f32,
    lg: f32,
    lb: f32,

    pub fn init(p: *const ifd.Page) Ycc {
        var t: Ycc = undefined;
        const rb = p.ref_bw;
        t.lr = p.coefs[0];
        t.lg = p.coefs[1];
        t.lb = p.coefs[2];
        for (0..256) |i| {
            const v: f32 = @floatFromInt(i);
            t.y[i] = (v - rb[0]) * 255 / nonzero(rb[1] - rb[0]);
            t.cb[i] = (v - rb[2]) * 127 / nonzero(rb[3] - rb[2]);
            t.cr[i] = (v - rb[4]) * 127 / nonzero(rb[5] - rb[4]);
        }
        return t;
    }

    fn nonzero(v: f32) f32 {
        return if (v == 0) 1 else v;
    }

    pub fn rgb(t: *const Ycc, y: u8, cb: u8, cr: u8) [3]u8 {
        const yv = t.y[y];
        const r = t.cr[cr] * (2 - 2 * t.lr) + yv;
        const b = t.cb[cb] * (2 - 2 * t.lb) + yv;
        const g = if (t.lg == 0) yv else (yv - t.lb * b - t.lr * r) / t.lg;
        return .{ clamp8(r), clamp8(g), clamp8(b) };
    }

    fn clamp8(v: f32) u8 {
        if (!(v > 0)) return 0;
        if (v >= 255) return 255;
        return @intFromFloat(@round(v));
    }
};

test "predictors" {
    var row = [_]u8{ 1, 2, 3, 1, 1, 1, 255, 0, 0 };
    horizontal(&row, 1, 3);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 2, 3, 4, 1, 3, 4 }, &row);
    var wide: [6]u8 = undefined;
    for ([_]u16{ 1000, 65535, 2 }, 0..) |v, i| std.mem.writeInt(u16, wide[2 * i ..][0..2], v, native_endian);
    horizontal(&wide, 2, 1);
    try testing.expectEqual(999, std.mem.readInt(u16, wide[2..4], native_endian));
    try testing.expectEqual(1001, std.mem.readInt(u16, wide[4..6], native_endian));
    // Every stride and sample size against the definition, on rows that
    // end in a partial pixel and an odd byte.
    var prng: std.Random.DefaultPrng = .init(3);
    for ([_]u8{ 1, 2, 4 }) |bytes| for (1..6) |stride| for ([_]usize{ 0, 1, 7, 40, 41 }) |len| {
        var got: [41]u8 = undefined;
        prng.random().bytes(&got);
        var want = got;
        var i = stride;
        while (i < len / bytes) : (i += 1) {
            const at = i * bytes;
            const prev = std.mem.readVarInt(u32, want[at - stride * bytes ..][0..bytes], native_endian);
            const cur = std.mem.readVarInt(u32, want[at..][0..bytes], native_endian);
            switch (bytes) {
                inline 1, 2, 4 => |n| {
                    const T = @Int(.unsigned, 8 * n);
                    std.mem.writeInt(T, want[at..][0..n], @truncate(cur +% prev), native_endian);
                },
                else => unreachable,
            }
        }
        horizontal(got[0..len], bytes, stride);
        try testing.expectEqualSlices(u8, &want, &got);
    };
    // Two 32-bit floats, 1.0 (3f800000) and 2.0 (40000000), arranged by
    // byte significance and differenced with a stride of 1.
    var f = [_]u8{ 0x3f, 0x01, 0x40, 0x80, 0, 0, 0, 0 };
    var temp: [8]u8 = undefined;
    floating(&f, &temp, 4, 1);
    try testing.expectEqual(@as(f32, 1), @as(f32, @bitCast(std.mem.readInt(u32, f[0..4], native_endian))));
    try testing.expectEqual(@as(f32, 2), @as(f32, @bitCast(std.mem.readInt(u32, f[4..8], native_endian))));
}

test "joined native formats" {
    try testing.expectEqual(PixelFormat.rgba16, join(.gray_alpha16, .rgb8).?);
    try testing.expectEqual(PixelFormat.gray16, join(.gray8, .gray16).?);
    try testing.expectEqual(PixelFormat.rgba16_premul, join(.rgba16_premul, .gray8).?);
    try testing.expectEqual(PixelFormat.rgba8_premul, join(.rgba8_premul, .gray8).?);
    try testing.expectEqual(null, join(.rgba8_premul, .gray16));
    try testing.expectEqual(null, join(.gray8, .rgba_f32));
    try testing.expectEqual(null, join(.rgba8_premul, .gray_alpha8));
}

test "bit-packed samples" {
    const row = [_]u8{ 0b1011_0011, 0b1100_0101, 0b0101_0101 };
    try testing.expectEqual(0b1011, readBits(&row, 0, 4));
    try testing.expectEqual(0b0011_1100_0101, readBits(&row, 4, 12));
    try testing.expectEqual(0b1_0101, readBits(&row, 19, 5));
    try testing.expectEqual(1.0, float24(0x3f0000));
    try testing.expectEqual(-2.5, float24(0x804000 | 0x400000));
}
