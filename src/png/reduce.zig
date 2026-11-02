//! What a PNG file stores for a set of source images (a still image, or
//! every frame of an APNG), and how a row of pixels becomes a row of the
//! file's samples.
//!
//! Rows are first converted with `image.convert` to the base format: the
//! sources' channels, straight, at their sample size (16 bits for float
//! sources). The survey then reads every base pixel once and keeps what
//! still holds of each lossless reduction, stopping as soon as nothing is
//! left to learn:
//!
//! - every alpha is the maximum: the alpha channel can go;
//! - every alpha is 0 or the maximum, the transparent pixels share one
//!   color, and no opaque pixel has it: a tRNS key can replace the alpha
//!   channel (checked by a second pass when the palette did not see every
//!   color);
//! - every pixel is gray (R = G = B): gray samples, except for float
//!   sources, whose gray `image.convert` computes in float;
//! - every 16-bit sample is a byte repeated (v = 257·k): 8-bit samples;
//! - every gray sample is on the 1-, 2-, or 4-bit grid: that depth;
//! - at most 256 colors: a palette, at the fewest bits that index it.
//!
//! The plan is the candidate with the fewest bits per pixel, a palette only
//! when its indices save more than twice the bytes PLTE and tRNS cost.
//! Colors under transparent pixels are kept: the file decodes to exactly
//! the base pixels.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

pub const ColorType = enum(u8) { gray = 0, rgb = 2, palette = 3, gray_alpha = 4, rgba = 6 };

/// What the file stores.
pub const Plan = struct {
    color: ColorType,
    /// Bits per sample (per index for a palette): 1, 2, 4, 8, or 16.
    depth: u8,
    /// The straight format every source row is converted to before packing.
    base: PixelFormat,
    /// The tRNS key of a gray or truecolor image, at the file's depth.
    key: ?[3]u16 = null,
    /// The palette, when `color` is `palette`.
    palette: *const Palette = undefined,

    pub fn channels(p: Plan) usize {
        return switch (p.color) {
            .gray, .palette => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    pub fn bitsPerPixel(p: Plan) usize {
        return p.channels() * p.depth;
    }

    /// The bytes of one row of `width` pixels, without the filter byte.
    pub fn rowBytes(p: Plan, width: u32) usize {
        return (@as(usize, width) * p.bitsPerPixel() + 7) / 8;
    }

    /// The filters' "bpp" (section 9.2): the bytes in a pixel, at least 1.
    pub fn filterBpp(p: Plan) usize {
        return @max(1, p.bitsPerPixel() / 8);
    }

    /// Whether `pack` is a copy of the base row (8-bit samples) or a byte
    /// swap of it (16-bit samples on a little-endian machine).
    pub fn sameLayout(p: Plan) bool {
        const want: ColorType = switch (p.base) {
            .gray8, .gray16 => .gray,
            .gray_alpha8, .gray_alpha16 => .gray_alpha,
            .rgb8, .rgb16 => .rgb,
            else => .rgba,
        };
        return p.color == want and p.depth == 8 * p.base.bytesPerSample();
    }

    /// Writes the file's samples for `width` base pixels in `base_row`
    /// into `out` (`rowBytes(width)` bytes).
    pub fn pack(p: Plan, out: []u8, base_row: []const u8, width: usize) void {
        switch (p.base) {
            inline .gray8, .gray_alpha8, .rgb8, .rgba8, .gray16, .gray_alpha16, .rgb16, .rgba16 => |b| {
                packAs(b, p, out, base_row, width);
            },
            else => unreachable,
        }
    }
};

/// The base format for sources of `src`'s kind.
pub fn baseOf(src: PixelFormat) PixelFormat {
    if (src.sample() == .f32) return .rgba16;
    const wide = src.sample() == .u16;
    if (src.isGray()) {
        if (src.hasAlpha()) return if (wide) .gray_alpha16 else .gray_alpha8;
        return if (wide) .gray16 else .gray8;
    }
    if (src.hasAlpha()) return if (wide) .rgba16 else .rgba8;
    return if (wide) .rgb16 else .rgb8;
}

/// The base format holding every one of `formats`' channels and depth.
pub fn baseOfAll(formats: anytype) PixelFormat {
    var color = false;
    var alpha = false;
    var wide = false;
    for (formats) |f| {
        const b = baseOf(f);
        color = color or !b.isGray();
        alpha = alpha or b.hasAlpha();
        wide = wide or b.sample() == .u16;
    }
    if (!color) {
        if (alpha) return if (wide) .gray_alpha16 else .gray_alpha8;
        return if (wide) .gray16 else .gray8;
    }
    if (alpha) return if (wide) .rgba16 else .rgba8;
    return if (wide) .rgb16 else .rgb8;
}

/// An image's distinct colors as straight RGBA8, found through an
/// open-addressed hash table, with the entries whose alpha is below 255
/// first once `sort` has run.
pub const Palette = struct {
    colors: [256][4]u8 = undefined,
    len: u16 = 0,
    /// The entries before this one are not opaque: tRNS's length.
    trns_len: u16 = 0,
    /// Color + (1 << 32) (0 for empty), and its index.
    keys: [512]u64 = @splat(0),
    slots: [512]u8 = undefined,

    fn slot(key: u64) u9 {
        return @truncate((@as(u32, @truncate(key)) *% 0x9e3779b1) >> 23);
    }

    /// Adds a color, returning false if the palette already holds `cap`
    /// others.
    fn add(t: *Palette, rgba: u32, cap: u16) bool {
        const key = @as(u64, rgba) | 1 << 32;
        var s = slot(key);
        while (t.keys[s] != 0) : (s +%= 1) if (t.keys[s] == key) return true;
        if (t.len == cap) return false;
        t.keys[s] = key;
        t.slots[s] = @intCast(t.len);
        t.colors[t.len] = @bitCast(rgba);
        t.len += 1;
        return true;
    }

    fn has(t: *const Palette, rgba: u32) bool {
        const key = @as(u64, rgba) | 1 << 32;
        var s = slot(key);
        while (t.keys[s] != 0) : (s +%= 1) if (t.keys[s] == key) return true;
        return false;
    }

    /// The index of a color the palette holds.
    pub fn find(t: *const Palette, rgba: u32) u8 {
        const key = @as(u64, rgba) | 1 << 32;
        var s = slot(key);
        while (t.keys[s] != key) s +%= 1;
        return t.slots[s];
    }

    /// Moves the colors that are not opaque to the front, keeping the order
    /// of first appearance within each group, and sets `trns_len`.
    fn sort(t: *Palette) void {
        var order: [256][4]u8 = undefined;
        var moved: [256]u8 = undefined;
        var n: u16 = 0;
        for (t.colors[0..t.len], 0..) |c, i| if (c[3] != 255) {
            order[n] = c;
            moved[i] = @intCast(n);
            n += 1;
        };
        t.trns_len = n;
        for (t.colors[0..t.len], 0..) |c, i| if (c[3] == 255) {
            order[n] = c;
            moved[i] = @intCast(n);
            n += 1;
        };
        t.colors = order;
        for (&t.keys, &t.slots) |k, *s| if (k != 0) {
            s.* = moved[s.*];
        };
    }
};

/// The survey's state: which reductions still hold.
pub const Survey = struct {
    base: PixelFormat,
    /// Every alpha is the maximum.
    opaque_: bool = true,
    /// Every alpha is 0 or the maximum.
    binary: bool = true,
    /// The transparent pixels so far share one color (`key`, base RGB).
    key_ok: bool = true,
    key: ?[3]u16 = null,
    /// Every pixel is gray.
    gray: bool,
    /// Every 16-bit sample is a byte repeated.
    narrow: bool,
    /// Every gray sample (8-bit, after narrowing) is on the 4-, 2-, and
    /// 1-bit grids.
    grid4: bool = true,
    grid2: bool = true,
    grid1: bool = true,
    /// At most `cap` colors so far, all in `palette`.
    palette_ok: bool = true,
    cap: u16,
    palette: *Palette,
    /// The pixels surveyed.
    pixel_count: u64 = 0,

    pub fn init(base: PixelFormat, float: bool, palette: *Palette) Survey {
        palette.* = .{};
        const wide = base.sample() == .u16;
        return .{
            .base = base,
            .gray = !float or base.isGray(),
            .narrow = wide,
            // A palette of gray without alpha wins only below 8 bits.
            .cap = if (base.isGray() and !base.hasAlpha()) 16 else 256,
            .palette = palette,
        };
    }

    /// Whether another pixel could change what the survey has found.
    fn learning(s: *const Survey) bool {
        if (s.base.hasAlpha() and (s.opaque_ or (s.binary and s.key_ok))) return true;
        if (s.gray and !s.base.isGray()) return true;
        if (s.narrow) return true;
        if (s.palette_ok) return true;
        return s.gray and (s.grid4 or s.grid2 or s.grid1);
    }

    /// Reads every pixel of `src`, converting its rows to the base format
    /// through `row` (at least a base row long).
    pub fn add(s: *Survey, src: PixelBuffer, row: []u8) void {
        switch (s.base) {
            inline .gray8, .gray_alpha8, .rgb8, .rgba8, .gray16, .gray_alpha16, .rgb16, .rgba16 => |b| {
                s.addAs(b, src, row);
            },
            else => unreachable,
        }
    }

    fn addAs(s: *Survey, comptime base: PixelFormat, src: PixelBuffer, row: []u8) void {
        s.pixel_count += @as(u64, src.width) * src.height;
        const conv: Converter = .init(base, src.format);
        const bpp = base.bytesPerPixel();
        const width: usize = src.width;
        for (0..src.height) |y| {
            if (!s.learning()) return;
            var r = src.row(@intCast(y));
            if (src.format != base) {
                conv.run(row, r, width);
                r = row[0 .. width * bpp];
            }
            // Only opacity left to learn: a vector check, and the pixel loop
            // only for a row with a pixel that is not opaque.
            if (base.hasAlpha() and s.opaque_ and !s.grayLive(base) and !s.narrow and !s.palette_ok) {
                if (allOpaque(base, r)) continue;
            }
            s.pixels(base, r, width);
        }
    }

    fn grayLive(s: *const Survey, comptime base: PixelFormat) bool {
        return s.gray and (!base.isGray() or s.grid4 or s.grid2 or s.grid1);
    }

    fn pixels(s: *Survey, comptime base: PixelFormat, r: []const u8, width: usize) void {
        const ch = comptime base.channels();
        const wide = comptime base.sample() == .u16;
        const max: u16 = if (wide) 65535 else 255;
        var last: ?u32 = null;
        for (0..width) |x| {
            var px: [4]u16 = undefined;
            inline for (0..comptime base.channelCount()) |i| {
                px[i] = if (wide)
                    std.mem.readInt(u16, r[(x * base.channelCount() + i) * 2 ..][0..2], native)
                else
                    r[x * base.channelCount() + i];
            }
            const red = px[ch.r orelse ch.y.?];
            const green = px[ch.g orelse ch.y.?];
            const blue = px[ch.b orelse ch.y.?];
            const alpha: u16 = if (ch.a) |a| px[a] else max;
            if (ch.a != null) {
                if (alpha != max) {
                    s.opaque_ = false;
                    if (alpha != 0) {
                        s.binary = false;
                    } else if (s.key_ok) {
                        const c: [3]u16 = .{ red, green, blue };
                        if (s.key) |k| {
                            if (!std.mem.eql(u16, &k, &c)) s.key_ok = false;
                        } else s.key = c;
                    }
                }
            }
            if (ch.y == null and s.gray and (red != green or green != blue)) s.gray = false;
            if (wide and s.narrow) {
                inline for (0..comptime base.channelCount()) |i| {
                    if (px[i] >> 8 != px[i] & 0xff) s.narrow = false;
                }
            }
            const r8: u8 = @truncate(if (wide) red >> 8 else red);
            if (s.gray and (s.grid4 or s.grid2 or s.grid1)) {
                if (r8 >> 4 != r8 & 15) s.grid4 = false;
                if (r8 % 85 != 0) s.grid2 = false;
                if (r8 != 0 and r8 != 255) s.grid1 = false;
            }
            if (s.palette_ok) {
                if (wide and !s.narrow) {
                    s.palette_ok = false;
                    continue;
                }
                const rgba: u32 = @bitCast([4]u8{
                    r8,
                    @truncate(if (wide) green >> 8 else green),
                    @truncate(if (wide) blue >> 8 else blue),
                    @truncate(if (wide) alpha >> 8 else alpha),
                });
                if (last != rgba) {
                    last = rgba;
                    if (!s.palette.add(rgba, s.cap)) s.palette_ok = false;
                }
            }
        }
    }

    /// The plan with the fewest bits per pixel. `key_checked` is null when
    /// a tRNS key would need the second pass (`keyClear`) that has not run,
    /// and otherwise its answer; `plan` returns `null` to ask for it.
    pub fn plan(s: *Survey, key_checked: ?bool) ?Plan {
        const base = s.base;
        const alpha = base.hasAlpha() and !s.opaque_;
        const narrow = base.sample() == .u8 or s.narrow;
        const sample: u8 = if (narrow) 8 else 16;
        var key_ok = alpha and s.binary and s.key_ok and s.key != null;
        if (key_ok and s.palette_ok) {
            // Every color is in the palette: the key is clear when no opaque
            // pixel has its color.
            const k = s.key.?;
            const shift: u4 = if (base.sample() == .u16) 8 else 0;
            const opaque_rgba: u32 = @bitCast([4]u8{
                @truncate(k[0] >> shift),
                @truncate(k[1] >> shift),
                @truncate(k[2] >> shift),
                255,
            });
            if (s.palette.has(opaque_rgba)) key_ok = false;
        } else if (key_ok) {
            if (key_checked) |ok| key_ok = ok else return null;
        }

        // The candidates, by bits per pixel.
        var best: Plan = undefined;
        var best_bits: usize = std.math.maxInt(usize);
        if (s.gray) {
            const depth: u8 = if (!narrow) 16 else if (s.grid1) 1 else if (s.grid2) 2 else if (s.grid4) 4 else 8;
            if (!alpha) {
                best = .{ .color = .gray, .depth = depth, .base = base };
            } else if (key_ok) {
                const key: [3]u16 = .{ scale(s.key.?[0], base, depth), 0, 0 };
                best = .{ .color = .gray, .depth = depth, .base = base, .key = key };
            } else {
                best = .{ .color = .gray_alpha, .depth = sample, .base = base };
            }
        } else if (!alpha) {
            best = .{ .color = .rgb, .depth = sample, .base = base };
        } else if (key_ok) {
            const k = s.key.?;
            const key: [3]u16 = .{ scale(k[0], base, sample), scale(k[1], base, sample), scale(k[2], base, sample) };
            best = .{ .color = .rgb, .depth = sample, .base = base, .key = key };
        } else {
            best = .{ .color = .rgba, .depth = sample, .base = base };
        }
        best_bits = best.bitsPerPixel();
        if (s.palette_ok and narrow) {
            const n = s.palette.len;
            const depth: u8 = if (n <= 2) 1 else if (n <= 4) 2 else if (n <= 16) 4 else 8;
            // PLTE and tRNS, with their chunks' 12 bytes each, must cost
            // less than half the bytes the indices save, since the samples
            // they replace would compress too.
            var trns: u64 = 0;
            for (s.palette.colors[0..n]) |c| trns += @intFromBool(c[3] != 255);
            const overhead = 3 * @as(u64, n) + 12 + if (trns > 0) trns + 12 else 0;
            const saved = (best_bits -| depth) * s.pixel_count / 8;
            if (depth < best_bits and 2 * overhead < saved) {
                s.palette.sort();
                best = .{ .color = .palette, .depth = depth, .base = base, .palette = s.palette };
            }
        }
        return best;
    }
};

/// A base sample at the file's depth: the high byte of a 16-bit sample for
/// an 8-bit file, and the high bits of an 8-bit sample below 8 bits.
fn scale(v: u16, base: PixelFormat, depth: u8) u16 {
    const from: u8 = if (base.sample() == .u16) 16 else 8;
    return v >> @intCast(from - depth);
}

const native = builtin.cpu.arch.endian();

/// Whether every alpha in a row of base pixels is the maximum.
fn allOpaque(comptime base: PixelFormat, r: []const u8) bool {
    const n = base.bytesPerPixel();
    const a_at = base.channels().a.? * base.bytesPerSample();
    if (base.sample() == .u8 and n == 4) {
        // Every fourth byte, 16 pixels at a time.
        const V = @Vector(64, u8);
        const mask: V = comptime blk: {
            var m: [64]u8 = undefined;
            for (&m, 0..) |*b, i| b.* = if (i % 4 == 3) 255 else 0;
            break :blk m;
        };
        var i: usize = 0;
        while (i + 64 <= r.len) : (i += 64) {
            const v: V = r[i..][0..64].*;
            if (!@reduce(.And, (v & mask) == mask)) return false;
        }
        while (i < r.len) : (i += 4) if (r[i + 3] != 255) return false;
        return true;
    }
    var i: usize = a_at;
    while (i < r.len) : (i += n) {
        for (r[i..][0..base.bytesPerSample()]) |b| if (b != 255) return false;
    }
    return true;
}

/// Whether no opaque pixel of `src` (converted to `base`) has the key
/// color, the check `Survey.plan` asks for when the palette did not see
/// every color.
pub fn keyClear(base: PixelFormat, key: [3]u16, src: PixelBuffer, row: []u8) bool {
    switch (base) {
        inline .gray_alpha8, .rgba8, .gray_alpha16, .rgba16 => |b| return keyClearAs(b, key, src, row),
        else => unreachable,
    }
}

fn keyClearAs(comptime base: PixelFormat, key: [3]u16, src: PixelBuffer, row: []u8) bool {
    const conv: Converter = .init(base, src.format);
    const ch = comptime base.channels();
    const wide = comptime base.sample() == .u16;
    const n = comptime base.channelCount();
    for (0..src.height) |y| {
        var r = src.row(@intCast(y));
        if (src.format != base) {
            conv.run(row, r, src.width);
            r = row[0 .. src.width * base.bytesPerPixel()];
        }
        for (0..src.width) |x| {
            var px: [4]u16 = undefined;
            inline for (0..n) |i| {
                px[i] = if (wide) std.mem.readInt(u16, r[(x * n + i) * 2 ..][0..2], native) else r[x * n + i];
            }
            if (px[ch.a.?] == 0) continue;
            const c: [3]u16 = .{ px[ch.r orelse ch.y.?], px[ch.g orelse ch.y.?], px[ch.b orelse ch.y.?] };
            if (std.mem.eql(u16, &c, &key)) return false;
        }
    }
    return true;
}

fn packAs(comptime base: PixelFormat, p: Plan, out: []u8, r: []const u8, width: usize) void {
    const wide = comptime base.sample() == .u16;
    const n = comptime base.channelCount();
    if (p.sameLayout()) {
        if (!wide or native == .big) {
            @memcpy(out[0..r.len], r);
        } else {
            const words = r.len / 2;
            for (0..words) |i| {
                out[2 * i] = r[2 * i + 1];
                out[2 * i + 1] = r[2 * i];
            }
        }
        return;
    }
    const ch = comptime base.channels();
    if (p.depth < 8) @memset(out[0..p.rowBytes(@intCast(width))], 0);
    var o: usize = 0;
    for (0..width) |x| {
        var px: [4]u16 = undefined;
        inline for (0..n) |i| {
            px[i] = if (wide) std.mem.readInt(u16, r[(x * n + i) * 2 ..][0..2], native) else r[x * n + i];
        }
        const red = px[ch.r orelse ch.y.?];
        const green = px[ch.g orelse ch.y.?];
        const blue = px[ch.b orelse ch.y.?];
        const alpha: u16 = if (ch.a) |a| px[a] else if (wide) 65535 else 255;
        switch (p.color) {
            .palette => {
                const sh: u4 = if (wide) 8 else 0;
                const rgba: u32 = @bitCast([4]u8{
                    @truncate(red >> sh),
                    @truncate(green >> sh),
                    @truncate(blue >> sh),
                    @truncate(alpha >> sh),
                });
                putBits(out, x, p.depth, p.palette.find(rgba));
            },
            .gray => {
                if (p.depth < 8) {
                    putBits(out, x, p.depth, @intCast(scale(red, base, p.depth)));
                } else {
                    o = put(out, o, red, base, p.depth);
                }
            },
            .gray_alpha => {
                o = put(out, o, red, base, p.depth);
                o = put(out, o, alpha, base, p.depth);
            },
            .rgb => {
                o = put(out, o, red, base, p.depth);
                o = put(out, o, green, base, p.depth);
                o = put(out, o, blue, base, p.depth);
            },
            .rgba => {
                o = put(out, o, red, base, p.depth);
                o = put(out, o, green, base, p.depth);
                o = put(out, o, blue, base, p.depth);
                o = put(out, o, alpha, base, p.depth);
            },
        }
    }
}

/// Writes a base sample at 8 or 16 bits, big endian, at `o`.
inline fn put(out: []u8, o: usize, v: u16, comptime base: PixelFormat, depth: u8) usize {
    if (depth == 16) {
        std.mem.writeInt(u16, out[o..][0..2], v, .big);
        return o + 2;
    }
    out[o] = @truncate(if (base.sample() == .u16) v >> 8 else v);
    return o + 1;
}

/// Sets sample `x` of a row of `depth`-bit samples, most significant
/// first, in a row cleared beforehand.
inline fn putBits(out: []u8, x: usize, depth: u8, v: u8) void {
    if (depth == 8) {
        out[x] = v;
        return;
    }
    const per = 8 / depth;
    const shift: u3 = @intCast(8 - depth * (x % per + 1));
    out[x / per] |= v << shift;
}

fn testPlan(format: PixelFormat, pixels: []const u8, width: u32) !Plan {
    const height: u32 = @intCast(pixels.len / format.bytesPerPixel() / width);
    const src = try PixelBuffer.init(@constCast(pixels), format, width, height);
    const base = baseOf(format);
    var palette: Palette = undefined;
    var s: Survey = .init(base, format.sample() == .f32, &palette);
    var row: [256]u8 = undefined;
    s.add(src, &row);
    var p = s.plan(null) orelse s.plan(keyClear(base, s.key.?, src, &row)).?;
    // The palette points at the local; copy it out for the caller.
    if (p.color == .palette) {
        test_palette = palette;
        p.palette = &test_palette;
    }
    return p;
}

var test_palette: Palette = undefined;

test "the plan is the fewest bits per pixel" {
    // Gray on the 1-bit grid.
    var p = try testPlan(.gray8, &.{ 0, 255, 255, 0 }, 2);
    try testing.expectEqual(ColorType.gray, p.color);
    try testing.expectEqual(1, p.depth);
    // RGB that is gray, on the 4-bit grid: gray, which a palette of its
    // 16 colors ties.
    var grid: [16 * 3]u8 = undefined;
    for (0..16) |i| grid[i * 3 ..][0..3].* = @splat(@intCast(i * 17));
    p = try testPlan(.rgb8, &grid, 16);
    try testing.expectEqual(ColorType.gray, p.color);
    try testing.expectEqual(4, p.depth);
    // Two of those colors: a 1-bit palette.
    p = try testPlan(.rgb8, &(grid[0..6].* ** 64), 2);
    try testing.expectEqual(ColorType.palette, p.color);
    try testing.expectEqual(1, p.depth);
    // Three colors: a 2-bit palette, once there are pixels enough to pay
    // for PLTE.
    p = try testPlan(.rgb8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 1, 2, 3 }, 4);
    try testing.expectEqual(ColorType.rgb, p.color);
    p = try testPlan(.rgb8, &(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 1, 2, 3 } ** 4), 4);
    try testing.expectEqual(ColorType.palette, p.color);
    try testing.expectEqual(2, p.depth);
    try testing.expectEqual(3, p.palette.len);
    // Opaque RGBA drops alpha; 16 bits that repeat bytes narrow to 8.
    var wide: [6 * 300]u8 = undefined;
    for (0..300) |i| {
        const v: u16 = @intCast(257 * (i % 256));
        const g: u16 = @intCast(257 * (i / 2 % 256));
        std.mem.writeInt(u16, wide[i * 6 ..][0..2], v, native);
        std.mem.writeInt(u16, wide[i * 6 + 2 ..][0..2], g, native);
        std.mem.writeInt(u16, wide[i * 6 + 4 ..][0..2], 0, native);
    }
    p = try testPlan(.rgb16, &wide, 10);
    try testing.expectEqual(ColorType.rgb, p.color);
    try testing.expectEqual(8, p.depth);
    // One transparent color nowhere opaque: a tRNS key, found by the second
    // pass once there are too many colors for a palette.
    var rgba: [4 * 300]u8 = undefined;
    for (0..300) |i| rgba[i * 4 ..][0..4].* = .{ @truncate(i), @intCast(i / 256), 7, 255 };
    rgba[4 * 5 ..][0..4].* = .{ 9, 9, 9, 0 };
    rgba[4 * 99 ..][0..4].* = .{ 9, 9, 9, 0 };
    p = try testPlan(.rgba8, &rgba, 10);
    try testing.expectEqual(ColorType.rgb, p.color);
    try testing.expectEqual([3]u16{ 9, 9, 9 }, p.key.?);
    // ... but not when an opaque pixel has that color.
    rgba[4 * 200 ..][0..4].* = .{ 9, 9, 9, 255 };
    p = try testPlan(.rgba8, &rgba, 10);
    try testing.expectEqual(ColorType.rgba, p.color);
    // Gray with alpha and few colors: a palette with the transparent entry
    // first.
    p = try testPlan(.gray_alpha8, &(.{ 5, 255, 6, 255, 7, 128, 5, 255 } ** 16), 4);
    try testing.expectEqual(ColorType.palette, p.color);
    try testing.expectEqual(1, p.palette.trns_len);
    try testing.expectEqual([4]u8{ 7, 7, 7, 128 }, p.palette.colors[0]);
}

test "pack writes the file's samples" {
    var out: [16]u8 = undefined;
    // Gray at 2 bits from RGB.
    const p: Plan = .{ .color = .gray, .depth = 2, .base = .rgb8 };
    p.pack(&out, &.{ 0, 0, 0, 85, 85, 85, 170, 170, 170, 255, 255, 255, 85, 85, 85 }, 5);
    try testing.expectEqualSlices(u8, &.{ 0b00011011, 0b01000000 }, out[0..2]);
    // 16-bit RGB written big endian, alpha dropped.
    var wide: [8]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(u16, wide[i * 2 ..][0..2], @intCast(0x0102 * (i + 1)), native);
    const q: Plan = .{ .color = .rgb, .depth = 16, .base = .rgba16 };
    q.pack(&out, &wide, 1);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 2, 4, 3, 6 }, out[0..6]);
}
