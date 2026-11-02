//! YUV 4:2:0 to RGB for lossy WebP, as libwebp converts by default, so that
//! its output is the oracle: "fancy" upsampling, which weighs the four
//! nearest chroma samples 9:3:3:1, and BT.601 limited-range conversion in
//! 14-bit fixed point.
//!
//! The upsampler rounds in two steps: with `a` the nearest chroma sample,
//! `b` its horizontal neighbor, `c` its vertical neighbor, and `d` the
//! diagonal one, a pixel's chroma is ((a + 3b + 3c + d + 8) >> 3 + a) >> 1,
//! which can differ by one from (9a + 3b + 3c + d + 8) >> 4. The first
//! and, for an even width, last pixels have no horizontal neighbor on one
//! side and take (3a + c + 2) >> 2. These were matched to libwebp's output.
//!
//! The conversion: R = (19077 y + 26149 v) / 256 - 14234, G = (19077 y -
//! 6419 u - 13320 v) / 256 + 8708, B = (19077 y + 33050 u) / 256 - 17685,
//! each product divided by 256 rounding down on its own, then clamped and
//! divided by 64. The multipliers are 255/219 and the BT.601 chroma
//! weights times 255/224, in units of 2^-14; the offsets fold in the 16 and
//! 128 biases and 32 for rounding.

const std = @import("std");
const testing = std.testing;

fn mulHi(v: i32, k: i32) i32 {
    return (v * k) >> 8;
}

fn clip8(v: i32) u8 {
    if (v & ~@as(i32, (256 << 6) - 1) == 0) return @intCast(v >> 6);
    return if (v < 0) 0 else 255;
}

pub fn toRgb(y: u8, u: u8, v: u8) [3]u8 {
    const yy = mulHi(y, 19077);
    return .{
        clip8(yy + mulHi(v, 26149) - 14234),
        clip8(yy - mulHi(u, 6419) - mulHi(v, 13320) + 8708),
        clip8(yy + mulHi(u, 33050) - 17685),
    };
}

/// Where the channels go in an output pixel.
pub const Layout = enum {
    rgb,
    bgr,
    rgba,
    bgra,

    pub fn bpp(l: Layout) usize {
        return switch (l) {
            .rgb, .bgr => 3,
            .rgba, .bgra => 4,
        };
    }
};

const lanes = 16;
const U8s = @Vector(lanes, u8);
const U16s = @Vector(lanes, u16);
const I32s = @Vector(lanes, i32);

/// One output row in `layout`, from a luma row and the chroma rows nearest
/// it (`near`) and next nearest (`far`), each `[u, v]`; with four bytes a
/// pixel, alpha comes from `alpha` or is 255. `scratch` holds two rows of
/// upsampled chroma.
pub fn row(
    comptime layout: Layout,
    out: []u8,
    luma: []const u8,
    near: [2][]const u8,
    far: [2][]const u8,
    alpha: ?[]const u8,
    width: usize,
    scratch: []u8,
) void {
    const u = scratch[0..width];
    const v = scratch[width..][0..width];
    upsample(u, near[0], far[0], width);
    upsample(v, near[1], far[1], width);
    const bpp = comptime layout.bpp();
    var x: usize = 0;
    while (x + lanes <= width) : (x += lanes) {
        const rgb = toRgbVec(luma[x..][0..lanes].*, u[x..][0..lanes].*, v[x..][0..lanes].*);
        const a: U8s = if (alpha) |al| al[x..][0..lanes].* else @splat(255);
        out[x * bpp ..][0 .. lanes * bpp].* = interleave(layout, rgb, a);
    }
    while (x < width) : (x += 1) {
        const c = toRgb(luma[x], u[x], v[x]);
        const px = out[x * bpp ..][0..bpp];
        switch (layout) {
            .rgb, .rgba => px[0..3].* = c,
            .bgr, .bgra => px[0..3].* = .{ c[2], c[1], c[0] },
        }
        if (bpp == 4) px[3] = if (alpha) |al| al[x] else 255;
    }
}

/// Each pixel's chroma, from the chroma rows nearest and next nearest.
fn upsample(out: []u8, near: []const u8, far: []const u8, width: usize) void {
    out[0] = edge(near[0], far[0]);
    const pairs = (width - 1) / 2;
    var x: usize = 1;
    while (x + lanes <= pairs + 1) : (x += lanes) {
        const tl: U16s = near[x - 1 ..][0..lanes].*;
        const t: U16s = near[x..][0..lanes].*;
        const l: U16s = far[x - 1 ..][0..lanes].*;
        const c: U16s = far[x..][0..lanes].*;
        const avg = tl + t + l + c + @as(U16s, @splat(8));
        const d0 = (avg + (t + l) * @as(U16s, @splat(2))) >> @splat(3);
        const d1 = (avg + (tl + c) * @as(U16s, @splat(2))) >> @splat(3);
        const o0: U8s = @intCast((d0 + tl) >> @splat(1));
        const o1: U8s = @intCast((d1 + t) >> @splat(1));
        const mask = comptime blk: {
            var m: [2 * lanes]i32 = undefined;
            for (0..lanes) |i| {
                m[2 * i] = @intCast(i);
                m[2 * i + 1] = ~@as(i32, @intCast(i));
            }
            break :blk m;
        };
        out[2 * x - 1 ..][0 .. 2 * lanes].* = @shuffle(u8, o0, o1, mask);
    }
    while (x <= pairs) : (x += 1) {
        const p = pair(near[x - 1], near[x], far[x - 1], far[x]);
        out[2 * x - 1] = p[0];
        out[2 * x] = p[1];
    }
    if (width & 1 == 0 and width > 1) out[width - 1] = edge(near[width / 2 - 1], far[width / 2 - 1]);
}

fn toRgbVec(y8: U8s, u8s: U8s, v8: U8s) [3]U8s {
    const y: I32s = y8;
    const u: I32s = u8s;
    const v: I32s = v8;
    const yy = (y * @as(I32s, @splat(19077))) >> @splat(8);
    const r = yy + ((v * @as(I32s, @splat(26149))) >> @splat(8)) - @as(I32s, @splat(14234));
    const g = yy - ((u * @as(I32s, @splat(6419))) >> @splat(8)) - ((v * @as(I32s, @splat(13320))) >> @splat(8)) +
        @as(I32s, @splat(8708));
    const b = yy + ((u * @as(I32s, @splat(33050))) >> @splat(8)) - @as(I32s, @splat(17685));
    return .{ clipVec(r), clipVec(g), clipVec(b) };
}

fn clipVec(v: I32s) U8s {
    const s = v >> @splat(6);
    return @intCast(@min(@max(s, @as(I32s, @splat(0))), @as(I32s, @splat(255))));
}

fn interleave(comptime layout: Layout, rgb: [3]U8s, a: U8s) [lanes * layout.bpp()]u8 {
    const first = if (layout == .bgr or layout == .bgra) rgb[2] else rgb[0];
    const third = if (layout == .bgr or layout == .bgra) rgb[0] else rgb[2];
    const bpp = comptime layout.bpp();
    var out: [lanes * bpp]u8 = undefined;
    if (bpp == 4) {
        const pairs = comptime blk: {
            var m: [2 * lanes]i32 = undefined;
            for (0..lanes) |i| {
                m[2 * i] = @intCast(i);
                m[2 * i + 1] = ~@as(i32, @intCast(i));
            }
            break :blk m;
        };
        const rg: @Vector(2 * lanes, u8) = @shuffle(u8, first, rgb[1], pairs);
        const ba: @Vector(2 * lanes, u8) = @shuffle(u8, third, a, pairs);
        const rg16: @Vector(lanes, u16) = @bitCast(rg);
        const ba16: @Vector(lanes, u16) = @bitCast(ba);
        const quads: @Vector(2 * lanes, u16) = @shuffle(u16, rg16, ba16, pairs);
        out = @bitCast(quads);
    } else {
        const f: [lanes]u8 = first;
        const g: [lanes]u8 = rgb[1];
        const t: [lanes]u8 = third;
        for (0..lanes) |i| out[3 * i ..][0..3].* = .{ f[i], g[i], t[i] };
    }
    return out;
}

fn edge(a: u8, c: u8) u8 {
    return @intCast((3 * @as(u32, a) + c + 2) >> 2);
}

/// The chroma of the two pixels between chroma columns x - 1 and x: `tl`
/// and `t` on the near row, `l` and `c` on the far row.
fn pair(tl: u8, t: u8, l: u8, c: u8) [2]u8 {
    const avg = @as(u32, tl) + t + l + c + 8;
    const d0 = (avg + 2 * (@as(u32, t) + l)) >> 3;
    const d1 = (avg + 2 * (@as(u32, tl) + c)) >> 3;
    return .{ @intCast((d0 + tl) >> 1), @intCast((d1 + t) >> 1) };
}

test "the vector paths match the scalar ones" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    inline for (.{ Layout.rgb, Layout.bgra }) |layout| for ([_]usize{ 1, 2, 3, 16, 33, 34, 70 }) |w| {
        var luma: [70]u8 = undefined;
        var ch: [4][35]u8 = undefined;
        var al: [70]u8 = undefined;
        r.bytes(&luma);
        r.bytes(&al);
        for (&ch) |*c| r.bytes(c);
        var out: [70 * 4]u8 = undefined;
        var scratch: [140]u8 = undefined;
        row(layout, &out, &luma, .{ &ch[0], &ch[1] }, .{ &ch[2], &ch[3] }, &al, w, &scratch);
        const bpp = layout.bpp();
        for (0..w) |x| {
            // The definitions: pair() for pixels with neighbors, edge() else.
            const k = (x + 1) / 2;
            var uv: [2]u8 = undefined;
            for (0..2) |c| {
                const n = &ch[c];
                const f = &ch[c + 2];
                uv[c] = if (x == 0 or (x == w - 1 and w % 2 == 0))
                    edge(n[if (x == 0) 0 else w / 2 - 1], f[if (x == 0) 0 else w / 2 - 1])
                else
                    pair(n[k - 1], n[k], f[k - 1], f[k])[(x + 1) % 2];
            }
            const want = toRgb(luma[x], uv[0], uv[1]);
            const px = out[x * bpp ..][0..bpp];
            if (layout == .rgb) {
                try testing.expectEqualSlices(u8, &want, px[0..3]);
            } else {
                try testing.expectEqualSlices(u8, &.{ want[2], want[1], want[0], al[x] }, px);
            }
        }
    };
}

test "conversion corners" {
    try testing.expectEqual([3]u8{ 0, 0, 0 }, toRgb(16, 128, 128));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, toRgb(235, 128, 128));
    // Clamped below and above.
    try testing.expectEqual([3]u8{ 0, 136, 0 }, toRgb(0, 0, 0));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, toRgb(255, 128, 128));
}
