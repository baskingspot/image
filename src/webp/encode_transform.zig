//! The WebP lossless encoder's transforms (RFC 9649, section 3.5), applied
//! forward in place on an ARGB image: color indexing with pixel bundling,
//! subtract green, the predictor (a mode per tile, chosen by the residuals'
//! estimated bits), and the color transform (three multipliers per tile,
//! searched coarse to fine).

const std = @import("std");
const testing = std.testing;

/// Adds two pixels channel by channel, modulo 256.
pub inline fn add(a: u32, b: u32) u32 {
    const ag = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const rb = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}

/// Subtracts pixel `b` from `a` channel by channel, modulo 256.
pub inline fn sub(a: u32, b: u32) u32 {
    const ag = (a | 0x00ff00ff) -% (b & 0xff00ff00);
    const rb = (a | 0xff00ff00) -% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}

pub fn divRoundUp(n: u32, bits: u5) u32 {
    return @intCast((@as(u64, n) + (@as(u64, 1) << bits) - 1) >> bits);
}

// Estimated bits ---------------------------------------------------------

/// log2(n) for the counts the estimates use: exact to 4095, and past it
/// from the top 12 bits, within 0.0004.
pub fn log2(n: u32) f32 {
    if (n < log_table.len) return log_table[n];
    const e: u5 = @intCast(31 - @clz(n) - 11);
    return @as(f32, @floatFromInt(e)) + log_table[n >> e];
}

const log_table = blk: {
    @setEvalBranchQuota(100_000);
    var t: [4096]f32 = undefined;
    t[0] = 0;
    for (1..t.len) |i| t[i] = std.math.log2(@as(f32, @floatFromInt(i)));
    break :blk t;
};

/// Bits for the values counted in `tile`, coded with what `acc` has
/// counted so far plus them.
fn entropyCost(tile: *const [256]u16, acc: *const [256]u32, acc_total: u32, n: u32) f32 {
    var bits: f32 = 0;
    const whole = log2(acc_total + n);
    for (tile, acc) |c, a| {
        if (c == 0) continue;
        bits += @as(f32, @floatFromInt(c)) * (whole - log2(a + c));
    }
    return bits;
}

// Color indexing ---------------------------------------------------------

/// An open-addressed set of up to 256 colors and their indices.
pub const ColorTable = struct {
    keys: [1024]u32,
    vals: [1024]u16,

    const empty = 0xffff;

    fn slot(px: u32) usize {
        return (0x1e35a7bd *% px) >> 22;
    }

    /// The image's colors into `palette`, sorted, or null past 256.
    pub fn find(t: *ColorTable, px: []const u32, palette: *[256]u32) ?usize {
        @memset(&t.vals, empty);
        var n: usize = 0;
        var last: u32 = px[0] +% 1;
        for (px) |c| {
            if (c == last) continue;
            last = c;
            var s = slot(c);
            while (t.vals[s] != empty and t.keys[s] != c) s = (s + 1) & 1023;
            if (t.vals[s] != empty) continue;
            if (n == 256) return null;
            t.keys[s] = c;
            t.vals[s] = 0;
            palette[n] = c;
            n += 1;
        }
        std.sort.pdq(u32, palette[0..n], {}, std.sort.asc(u32));
        for (palette[0..n], 0..) |c, i| {
            var s = slot(c);
            while (t.keys[s] != c) s = (s + 1) & 1023;
            t.vals[s] = @intCast(i);
        }
        return n;
    }

    pub fn index(t: *const ColorTable, c: u32) u32 {
        var s = slot(c);
        while (t.keys[s] != c) s = (s + 1) & 1023;
        return t.vals[s];
    }
};

/// Bundling bits for a palette of `n` colors: 8, 4, 2, or 1 pixels a byte.
pub fn bundleBits(n: usize) u5 {
    return if (n <= 2) 3 else if (n <= 4) 2 else if (n <= 16) 1 else 0;
}

/// Replaces each pixel by its index in the table's palette, bundled, in
/// place: the image becomes `divRoundUp(w, bits)` pixels wide.
pub fn applyPalette(px: []u32, w: u32, h: u32, t: *const ColorTable, n: usize) void {
    const bits = bundleBits(n);
    const pw = divRoundUp(w, bits);
    const per = @as(u32, 1) << bits;
    const bpp: u5 = @intCast(@as(u32, 8) >> bits);
    var last: u32 = px[0] +% 1;
    var last_index: u32 = 0;
    for (0..h) |y| {
        const row = px[y * w ..][0..w];
        // Packed pixels never land after pixels of the row not yet read.
        const out = px[y * pw ..][0..pw];
        var x: u32 = 0;
        for (out) |*o| {
            var v: u32 = 0;
            var k: u32 = 0;
            while (k < per and x < w) : (k += 1) {
                const c = row[x];
                if (c != last) {
                    last = c;
                    last_index = t.index(c);
                }
                v |= last_index << @intCast(k * bpp);
                x += 1;
            }
            o.* = 0xff000000 | v << 8;
        }
    }
}

// Subtract green ---------------------------------------------------------

pub fn subtractGreen(px: []u32) void {
    for (px) |*p| {
        const g = (p.* >> 8) & 0xff;
        p.* = (p.* & 0xff00ff00) | (((p.* | 0xff00ff00) -% (g << 16 | g)) & 0x00ff00ff);
    }
}

// Predictor --------------------------------------------------------------

const Px = @Vector(4, u8);
const Wide = @Vector(4, i16);

inline fn lanes(c: u32) Px {
    return @bitCast(std.mem.nativeToLittle(u32, c));
}

inline fn pixel(v: Px) u32 {
    return std.mem.littleToNative(u32, @bitCast(v));
}

inline fn avg(a: Px, b: Px) Px {
    return (a & b) +% ((a ^ b) >> @splat(1));
}

inline fn sad(a: Px, b: Px) u16 {
    return @reduce(.Add, @as(@Vector(4, u16), @max(a, b) - @min(a, b)));
}

inline fn clamp(v: Wide) Px {
    return @intCast(@min(@max(v, @as(Wide, @splat(0))), @as(Wide, @splat(255))));
}

/// Predictor `mode` from the left, top-left, top, and top-right pixels.
inline fn predictMode(comptime mode: u4, l: Px, tl: Px, t: Px, tr: Px) Px {
    return switch (mode) {
        1 => l,
        2 => t,
        3 => tr,
        4 => tl,
        5 => avg(avg(l, tr), t),
        6 => avg(l, tl),
        7 => avg(l, t),
        8 => avg(tl, t),
        9 => avg(t, tr),
        10 => avg(avg(l, tl), avg(t, tr)),
        // Select: |estimate - L| is |T - TL|, and |estimate - T| is
        // |L - TL|; the nearer of left and top.
        11 => if (sad(t, tl) < sad(l, tl)) l else t,
        12 => clamp(@as(Wide, l) + @as(Wide, t) - @as(Wide, tl)),
        13 => blk: {
            const a: Wide = avg(l, t);
            break :blk clamp(a + @divTrunc(a - @as(Wide, tl), @as(Wide, @splat(2))));
        },
        else => .{ 0, 0, 0, 255 },
    };
}

pub const modes = 14;

pub const PredictCost = enum { sad, entropy };

/// What choosing predictor modes needs besides the image: the residuals
/// so far, a tile's residuals with each mode, and their counts.
pub const PredictScratch = struct {
    acc: [4][256]u32,
    res: [2][max_tile]Px,
    hist: [4][256]u16,
};

/// The most pixels in a predictor tile, of at most 5 bits.
const max_tile = 1 << 10;

/// Bits for a tile's residuals `res`, coded with the residuals so far
/// plus them, from the pixels themselves: each adds the bits of its own
/// value, which over a value's pixels gives its count times them.
fn residualCost(s: *PredictScratch, res: []const Px, acc_total: u32) f32 {
    for (res) |r| {
        inline for (0..4) |ch| s.hist[ch][r[ch]] += 1;
    }
    var bits: f32 = @as(f32, @floatFromInt(res.len * 4)) * log2(acc_total + @as(u32, @intCast(res.len)));
    for (res) |r| {
        inline for (0..4) |ch| bits -= log2(s.acc[ch][r[ch]] + s.hist[ch][r[ch]]);
    }
    for (res) |r| {
        inline for (0..4) |ch| s.hist[ch][r[ch]] = 0;
    }
    return bits;
}

/// The prediction for pixel (x, y) of a `w` wide image with `mode`, from
/// pixels not yet replaced by residuals.
inline fn predictAt(px: []const u32, w: usize, x: usize, y: usize, mode: u4) Px {
    const i = y * w + x;
    if (y == 0) return if (x == 0) .{ 0, 0, 0, 255 } else lanes(px[i - 1]);
    if (x == 0) return lanes(px[i - w]);
    // The rightmost pixel's top right is the row's first pixel.
    const tr = if (x + 1 == w) px[y * w] else px[i - w + 1];
    return switch (mode) {
        inline else => |m| predictMode(m, lanes(px[i - 1]), lanes(px[i - w - 1]), lanes(px[i - w]), lanes(tr)),
    };
}

/// Chooses a predictor mode for each `2^bits` square tile of `px`, a `w` by
/// `h` image, into `out` (the predictor image, mode in green), and
/// replaces the pixels by their residuals. `allowed` limits the modes
/// tried, as a bit set.
pub fn predict(
    px: []u32,
    w: u32,
    h: u32,
    bits: u5,
    cost: PredictCost,
    allowed: u14,
    keep: u4,
    refine: u8,
    out: []u32,
    s: *PredictScratch,
) void {
    std.debug.assert(bits <= 5);
    if (cost == .entropy) for (&s.hist) |*c| @memset(c, 0);
    const tw = divRoundUp(w, bits);
    const th = divRoundUp(h, bits);
    const W: usize = w;
    for (&s.acc) |*a| @memset(a, 0);
    var acc_total: u32 = 0;
    // The first pass chooses each tile's mode against the residuals of the
    // tiles before it; each refining pass again, against all the others'.
    const passes: usize = if (cost == .entropy) 1 + @as(usize, refine) else 1;
    for (0..passes) |pass| for (0..th) |ty| {
        for (0..tw) |tx| {
            const x0 = tx << bits;
            const y0 = ty << bits;
            const x1 = @min(W, x0 + (@as(usize, 1) << bits));
            const y1 = @min(h, y0 + (@as(usize, 1) << bits));
            // Each mode's absolute residuals, then the entropy of those
            // with the smallest.
            var sads: [modes]u32 = @splat(0);
            var n: u32 = 0;
            for (@max(y0, 1)..y1) |y| {
                for (@max(x0, 1)..x1) |x| {
                    const i = y * W + x;
                    const c = lanes(px[i]);
                    const l = lanes(px[i - 1]);
                    const tl = lanes(px[i - W - 1]);
                    const t = lanes(px[i - W]);
                    const tr = lanes(if (x + 1 == W) px[y * W] else px[i - W + 1]);
                    inline for (0..modes) |m| {
                        if (allowed & (1 << m) != 0) {
                            const r = c -% predictMode(m, l, tl, t, tr);
                            sads[m] += @reduce(.Add, @as(@Vector(4, u16), @min(r, @as(Px, @splat(0)) -% r)));
                        }
                    }
                    n += 1;
                }
            }
            var best: u4 = 11;
            const ti = ty * tw + tx;
            var current: ?u4 = null;
            if (pass > 0 and n > 0) {
                // This tile's residuals out of the counts.
                const m: u4 = @truncate(out[ti] >> 8);
                current = m;
                var k: usize = 0;
                for (@max(y0, 1)..y1) |y| {
                    for (@max(x0, 1)..x1) |x| {
                        const r = lanes(px[y * W + x]) -% predictAt(px, W, x, y, m);
                        inline for (0..4) |ch| s.acc[ch][r[ch]] -= 1;
                        k += 1;
                    }
                }
                acc_total -= n;
            }
            if (n > 0) {
                const left: ?usize = if (tx > 0) (out[ti - 1] >> 8) & 0xf else null;
                const up: ?usize = if (ty > 0) (out[ti - tw] >> 8) & 0xf else null;
                var tried = allowed;
                if (cost == .entropy and @popCount(allowed) > keep) {
                    tried = 0;
                    for (0..keep) |_| {
                        var low: u32 = std.math.maxInt(u32);
                        var pick: u4 = 0;
                        for (0..modes) |m| {
                            const bit = @as(u14, 1) << @intCast(m);
                            if (allowed & bit != 0 and tried & bit == 0 and sads[m] < low) {
                                low = sads[m];
                                pick = @intCast(m);
                            }
                        }
                        tried |= @as(u14, 1) << pick;
                    }
                    if (left) |m| tried |= @as(u14, 1) << @intCast(m);
                    if (up) |m| tried |= @as(u14, 1) << @intCast(m);
                    if (current) |m| tried |= @as(u14, 1) << m;
                    tried &= allowed;
                }
                var best_cost: f32 = std.math.inf(f32);
                // The best mode's residuals stay in one slot while the
                // next candidate's go in the other.
                var best_slot: usize = 0;
                var free: usize = 0;
                for (0..modes) |m| {
                    if (tried & (@as(u14, 1) << @intCast(m)) == 0) continue;
                    var c: f32 = undefined;
                    if (cost == .sad) {
                        c = @floatFromInt(sads[m]);
                    } else {
                        const res = &s.res[free];
                        var k: usize = 0;
                        for (@max(y0, 1)..y1) |y| {
                            for (@max(x0, 1)..x1) |x| {
                                res[k] = lanes(px[y * W + x]) -% predictAt(px, W, x, y, @intCast(m));
                                k += 1;
                            }
                        }
                        c = residualCost(s, res[0..n], acc_total);
                        if (left == m) c -= pred_bias;
                        if (up == m) c -= pred_bias;
                    }
                    if (c < best_cost) {
                        best_cost = c;
                        best = @intCast(m);
                        best_slot = free;
                        free = 1 - free;
                    }
                }
                if (cost == .entropy) {
                    for (s.res[best_slot][0..n]) |r| {
                        inline for (0..4) |ch| s.acc[ch][r[ch]] += 1;
                    }
                    acc_total += n;
                }
            }
            out[ty * tw + tx] = 0xff000000 | @as(u32, best) << 8;
        }
    };
    // Residuals, last pixel first, so every prediction reads pixels not
    // yet replaced, a tile's run of a row at a time.
    var y: usize = h;
    while (y > 0) {
        y -= 1;
        const row = px[y * W ..][0..W];
        if (y == 0) {
            var x: usize = W;
            while (x > 1) {
                x -= 1;
                row[x] = sub(row[x], row[x - 1]);
            }
            row[0] = sub(row[0], 0xff000000);
            break;
        }
        const up = px[(y - 1) * W ..][0..W];
        const modes_row = out[(y >> bits) * tw ..][0..tw];
        var tx: usize = tw;
        while (tx > 0) {
            tx -= 1;
            const x0 = @max(tx << bits, 1);
            const x1 = @min(W, (tx + 1) << bits);
            switch (@as(u4, @truncate(modes_row[tx] >> 8))) {
                inline else => |m| {
                    var x = x1;
                    while (x > x0) {
                        x -= 1;
                        // The rightmost pixel's top right is the row's
                        // first, which is replaced last.
                        const tr = if (x + 1 == W) row[0] else up[x + 1];
                        const pred = predictMode(m, lanes(row[x - 1]), lanes(up[x - 1]), lanes(up[x]), lanes(tr));
                        row[x] = pixel(lanes(row[x]) -% pred);
                    }
                },
            }
        }
        row[0] = sub(row[0], up[0]);
    }
}

// Color transform --------------------------------------------------------

/// The multiplier at bit `shift` of a color transform element.
fn field(e: ?u32, comptime shift: u5) ?i8 {
    return if (e) |v| @bitCast(@as(u8, @truncate(v >> shift))) else null;
}

inline fn delta(t: i8, c: i8) i32 {
    return (@as(i32, t) * @as(i32, c)) >> 5;
}

pub const ColorScratch = struct {
    acc: [3][256]u32,
    green: [1 << 12]i8,
    red: [1 << 12]i8,
    blue: [1 << 12]i8,
};

/// Bits for the tile's values of one channel, `base` minus each `c` times
/// `t` (shifted), against what `acc` has counted.
fn channelCost(
    base: []const i8,
    c: []const i8,
    t: i8,
    other: []const i8,
    t2: i8,
    acc: *const [256]u32,
    acc_total: u32,
) f32 {
    var hist: [256]u16 = @splat(0);
    for (base, c, other) |b, x, o| {
        const v: u8 = @truncate(@as(u32, @bitCast(@as(i32, b) - delta(t, x) - delta(t2, o))));
        hist[v] += 1;
    }
    return entropyCost(&hist, acc, acc_total, @intCast(base.len));
}

/// The multiplier minimizing `cost`: the best of 0, `starts`, and `near`
/// (the left and upper tiles' values), then steps of 8 down to 1 around it.
fn search(context: anytype, comptime cost: fn (@TypeOf(context), i8) f32, starts: []const i8, near: [2]?i8) i8 {
    var best: i8 = 0;
    var best_cost = cost(context, 0);
    var tried: [4]i8 = .{ 0, 0, 0, 0 };
    var n_tried: usize = 1;
    for (starts) |t| try1(context, cost, t, &best, &best_cost, &tried, &n_tried);
    for (near) |v| if (v) |t| try1(context, cost, t, &best, &best_cost, &tried, &n_tried);
    inline for (.{ 8, 4, 2, 1 }) |step| {
        const center: i32 = best;
        inline for (.{ -step, step }) |dv| {
            const v = center + dv;
            if (v >= -128 and v <= 127) {
                const c = cost(context, @intCast(v));
                if (c < best_cost) {
                    best_cost = c;
                    best = @intCast(v);
                }
            }
        }
    }
    return best;
}

inline fn try1(
    context: anytype,
    comptime cost: fn (@TypeOf(context), i8) f32,
    t: i8,
    best: *i8,
    best_cost: *f32,
    tried: *[4]i8,
    n_tried: *usize,
) void {
    for (tried[0..n_tried.*]) |d| if (d == t) return;
    if (n_tried.* < tried.len) {
        tried[n_tried.*] = t;
        n_tried.* += 1;
    }
    const c = cost(context, t);
    if (c < best_cost.*) {
        best_cost.* = c;
        best.* = t;
    }
}

/// `32 num / den` rounded and clamped to a multiplier, for the least
/// squares estimates.
fn ratio(num: i64, den: i64) i8 {
    if (den == 0) return 0;
    const v = @divFloor(64 * num + den, 2 * den);
    return @intCast(std.math.clamp(v, -128, 127));
}

/// Bits a predictor mode is favored by when the left or upper tile has
/// it, as the predictor image codes a repeated mode cheaply.
const pred_bias = 8;

/// Chooses each tile's color transform element for `px` into `out` (the
/// color transform image: red_to_blue in red, green_to_blue in green,
/// green_to_red in blue) and applies it. `bits` is at most 6.
pub fn crossColor(px: []u32, w: u32, h: u32, bits: u5, sample: u32, out: []u32, s: *ColorScratch) void {
    std.debug.assert(bits <= 6);
    const tw = divRoundUp(w, bits);
    const th = divRoundUp(h, bits);
    const W: usize = w;
    for (&s.acc) |*a| @memset(a, 0);
    var acc_total: u32 = 0;
    for (0..th) |ty| {
        for (0..tw) |tx| {
            const x0 = tx << bits;
            const y0 = ty << bits;
            const x1 = @min(W, x0 + (@as(usize, 1) << bits));
            const y1 = @min(h, y0 + (@as(usize, 1) << bits));
            // Every `sample`th pixel of the tile weighs the choices.
            var n: usize = 0;
            var k: usize = sample;
            var sgg: i64 = 0;
            var srr: i64 = 0;
            var sgr: i64 = 0;
            var srg: i64 = 0;
            var sbg: i64 = 0;
            var sbr: i64 = 0;
            for (y0..y1) |y| for (x0..x1) |x| {
                k -= 1;
                if (k != 0) continue;
                k = sample;
                const p = px[y * W + x];
                const g: i8 = @bitCast(@as(u8, @truncate(p >> 8)));
                const r: i8 = @bitCast(@as(u8, @truncate(p >> 16)));
                const b: i8 = @bitCast(@as(u8, @truncate(p)));
                s.green[n] = g;
                s.red[n] = r;
                s.blue[n] = b;
                sgg += @as(i64, g) * g;
                srr += @as(i64, r) * r;
                sgr += @as(i64, g) * r;
                srg += @as(i64, r) * g;
                sbg += @as(i64, b) * g;
                sbr += @as(i64, b) * r;
                n += 1;
            };
            const Ctx = struct {
                const Self = @This();
                green: []const i8,
                red: []const i8,
                blue: []const i8,
                acc: *const [3][256]u32,
                total: u32,
                g2b: i8 = 0,
                r2b: i8 = 0,
                fn redCost(c: Self, t: i8) f32 {
                    return channelCost(c.red, c.green, t, c.green, 0, &c.acc[0], c.total);
                }
                fn blueG(c: Self, t: i8) f32 {
                    return channelCost(c.blue, c.green, t, c.red, c.r2b, &c.acc[1], c.total);
                }
                fn blueR(c: Self, t: i8) f32 {
                    return channelCost(c.blue, c.green, c.g2b, c.red, t, &c.acc[1], c.total);
                }
            };
            // Least squares starts: red from green, and blue from green
            // and red together.
            const ls_r = ratio(sgr, sgg);
            const det = sgg * srr - sgr * srg;
            const ls_bg = if (det != 0) ratio(sbg * srr - sbr * sgr, det) else ratio(sbg, sgg);
            const ls_br = if (det != 0) ratio(sbr * sgg - sbg * srg, det) else 0;
            var ctx: Ctx = .{
                .green = s.green[0..n],
                .red = s.red[0..n],
                .blue = s.blue[0..n],
                .acc = &s.acc,
                .total = acc_total,
                .r2b = ls_br,
            };
            const ti = ty * tw + tx;
            const left: ?u32 = if (tx > 0) out[ti - 1] else null;
            const up: ?u32 = if (ty > 0) out[ti - tw] else null;
            const g2r = search(ctx, Ctx.redCost, &.{ls_r}, .{ field(left, 0), field(up, 0) });
            ctx.g2b = search(ctx, Ctx.blueG, &.{ls_bg}, .{ field(left, 8), field(up, 8) });
            const r2b = search(ctx, Ctx.blueR, &.{ls_br}, .{ field(left, 16), field(up, 16) });
            const g2b = ctx.g2b;
            out[ty * tw + tx] = 0xff000000 | @as(u32, @as(u8, @bitCast(r2b))) << 16 |
                @as(u32, @as(u8, @bitCast(g2b))) << 8 | @as(u8, @bitCast(g2r));
            for (y0..y1) |y| for (x0..x1) |x| {
                const p = &px[y * W + x];
                const g: i8 = @bitCast(@as(u8, @truncate(p.* >> 8)));
                const r: i8 = @bitCast(@as(u8, @truncate(p.* >> 16)));
                const nr: u8 = @truncate(@as(u32, @bitCast(@as(i32, r) - delta(g2r, g))));
                const b: i8 = @bitCast(@as(u8, @truncate(p.*)));
                const nb: u8 = @truncate(@as(u32, @bitCast(@as(i32, b) - delta(g2b, g) - delta(r2b, r))));
                p.* = (p.* & 0xff00ff00) | @as(u32, nr) << 16 | nb;
                s.acc[0][nr] += 1;
                s.acc[1][nb] += 1;
            };
            acc_total += @intCast(n * sample);
        }
    }
}

test "predictor residuals undo" {
    // The decoder's inverse, written out per pixel, gives back the image
    // for every mode.
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const w = 13;
    const h = 7;
    var img: [w * h]u32 = undefined;
    for (&img) |*p| p.* = random.int(u32) & 0xf0f0f0f0;
    var s: PredictScratch = undefined;
    for ([_]PredictCost{ .sad, .entropy }) |cost| {
        var px = img;
        var out: [16]u32 = undefined;
        predict(&px, w, h, 2, cost, std.math.maxInt(u14), 14, 1, &out, &s);
        const tw = divRoundUp(w, 2);
        for (0..h) |y| for (0..w) |x| {
            const mode: u4 = @truncate(out[(y >> 2) * tw + (x >> 2)] >> 8);
            px[y * w + x] = pixel(lanes(px[y * w + x]) +% predictAt(&px, w, x, y, mode));
        };
        try testing.expectEqualSlices(u32, &img, &px);
    }
}

test "palette bundling" {
    // Three colors, 4 per byte at 2 bits each, least significant first.
    var px = [_]u32{ 7, 9, 7, 8, 9, 9 } ++ [_]u32{ 8, 7, 7, 7, 7, 9 };
    var t: ColorTable = undefined;
    var palette: [256]u32 = undefined;
    const n = t.find(&px, &palette).?;
    try testing.expectEqual(3, n);
    try testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, palette[0..3]);
    applyPalette(&px, 6, 2, &t, n);
    try testing.expectEqual(0xff000000 | (0 | 2 << 2 | 0 << 4 | 1 << 6) << 8, px[0]);
    try testing.expectEqual(0xff000000 | (2 | 2 << 2) << 8, px[1]);
    try testing.expectEqual(0xff000000 | (1 | 0 << 2 | 0 << 4 | 0 << 6) << 8, px[2]);
}
