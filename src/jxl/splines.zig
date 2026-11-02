//! Splines (ISO/IEC 18181-1, the frame's splines): centripetal
//! Catmull-Rom curves through quantized control points, drawn as a trail
//! of Gaussian dots one pixel apart whose color and width follow a
//! 32-coefficient cosine series along the arc, added to X, Y, and B.

const std = @import("std");
const testing = std.testing;

const Arena = @import("Arena.zig");
const BitReader = @import("BitReader.zig");
const entropy = @import("entropy.zig");

pub const Error = entropy.Error || error{BadImage};

const ctx_quant_adjustment = 0;
const ctx_start = 1;
const ctx_num_splines = 2;
const ctx_num_points = 3;
const ctx_points = 4;
const ctx_dct = 5;
const num_contexts = 6;

const pos_limit = 1 << 23;
const delta_limit = 1 << 30;
const channel_weight = [4]f32{ 0.0042, 0.075, 0.07, 0.3333 };

const Spline = struct {
    start: [2]i64,
    /// The control points' second differences, at `points[first..][0..n]`.
    first: usize,
    n: usize,
    color: [3][32]i32,
    sigma: [32]i32,
};

pub const Splines = struct {
    list: []Spline,
    points: [][2]i64,
    quant_adjustment: i32,
};

/// The bytes the splines of a frame of `px` pixels may take in work
/// memory (docs/slop/jxl.md, work memory); more is `TooComplex`.
pub fn budgetBytes(px: u64) u64 {
    return (1 << 20) + px * 4;
}

fn unpack(v: u32) i64 {
    const m: i64 = v >> 1;
    return if (v & 1 == 1) -m - 1 else m;
}

/// Reads the splines of a frame of `px` pixels.
pub fn read(br: *BitReader, arena: *Arena, px: u64) Error!Splines {
    const code = try entropy.Code.read(br, arena, num_contexts);
    var r: entropy.Reader = try .init(&code, br, arena, 0, entropy.window_size);
    const max_points: u64 = @min(1 << 20, px / 2);
    const num = @as(u64, try r.read(br, ctx_num_splines)) + 1;
    if (num > max_points) return error.BadImage;
    const room = budgetBytes(px);
    if (num * @sizeOf(Spline) > room) return error.TooComplex;
    const list = try arena.alloc(Spline, num);
    var last: [2]i64 = .{ 0, 0 };
    for (list, 0..) |*s, i| {
        const dx = try r.read(br, ctx_start);
        const dy = try r.read(br, ctx_start);
        const p: [2]i64 = if (i == 0) .{ dx, dy } else .{ unpack(dx) + last[0], unpack(dy) + last[1] };
        if (@abs(p[0]) >= pos_limit or @abs(p[1]) >= pos_limit) return error.BadImage;
        s.start = p;
        last = p;
    }
    const qa = unpack(try r.read(br, ctx_quant_adjustment));
    if (@abs(qa) > 1 << 30) return error.BadImage;
    // The control points take what the budget leaves.
    const left = room - num * @sizeOf(Spline);
    const cap: usize = @intCast(@min(max_points, left / @sizeOf([2]i64)));
    const points = try arena.alloc([2]i64, cap);
    var total: u64 = num;
    var used: usize = 0;
    for (list) |*s| {
        const n = try r.read(br, ctx_num_points);
        if (n > max_points) return error.BadImage;
        total += n;
        if (total > max_points) return error.BadImage;
        if (used + n > cap) return error.TooComplex;
        s.first = used;
        s.n = n;
        for (points[used..][0..n]) |*p| {
            for (p) |*v| {
                v.* = unpack(try r.read(br, ctx_points));
                if (@abs(v.*) >= delta_limit) return error.BadImage;
            }
        }
        used += n;
        for (&s.color) |*d| try readDct(&r, br, d);
        try readDct(&r, br, &s.sigma);
    }
    if (!r.finalOk()) return error.BadEntropy;
    return .{ .list = list, .points = points[0..used], .quant_adjustment = @intCast(qa) };
}

fn readDct(r: *entropy.Reader, br: *BitReader, out: *[32]i32) Error!void {
    for (out) |*v| {
        const u = unpack(try r.read(br, ctx_dct));
        if (u == std.math.minInt(i32)) return error.BadImage;
        // Values past i32 cannot come from 32-bit symbols other than this one.
        v.* = @intCast(u);
    }
}

const Point = struct { x: f32, y: f32 };

/// A spline after dequantization: its control points and its cosine
/// series for the colors and sigma.
const Curve = struct {
    color: [3][32]f32,
    sigma: [32]f32,
};

fn invAdjusted(a: i32) f32 {
    const f: f32 = @floatFromInt(a);
    return if (a >= 0) 1 / (1 + 0.125 * f) else 1 - 0.125 * f;
}

fn idct(d: *const [32]f32, t: f32) f32 {
    var sum: f32 = 0;
    for (d, 0..) |v, i| {
        const arg = std.math.pi / 32.0 * @as(f32, @floatFromInt(i)) * (t + 0.5);
        sum = @mulAdd(f32, std.math.sqrt2, v * @cos(arg), sum);
    }
    return sum;
}

/// erf, to within 1.2e-7 (Numerical Recipes' erfc by Chebyshev fit).
fn erf(x: f32) f32 {
    const z: f64 = @abs(x);
    const t = 1 / (1 + 0.5 * z);
    const poly = -z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 +
        t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 +
            t * (-0.82215223 + t * 0.17087277))))))));
    const r = 1 - t * @exp(poly);
    return @floatCast(if (x >= 0) r else -r);
}

/// The control points of spline `s`, which `draw` walks.
const Walker = struct {
    pts: []const Point,

    /// The Catmull-Rom points between control points, sixteen per span,
    /// one at a time.
    const Iter = struct {
        pts: []const Point,
        span: usize = 0,
        i: usize = 0,
        done: bool = false,

        fn at(it: *const Iter, k: isize) Point {
            const n: isize = @intCast(it.pts.len);
            if (k < 0) return .{ .x = 2 * it.pts[0].x - it.pts[1].x, .y = 2 * it.pts[0].y - it.pts[1].y };
            if (k >= n) {
                const a = it.pts[it.pts.len - 1];
                const b = it.pts[it.pts.len - 2];
                return .{ .x = 2 * a.x - b.x, .y = 2 * a.y - b.y };
            }
            return it.pts[@intCast(k)];
        }

        fn next(it: *Iter) ?Point {
            if (it.done) return null;
            if (it.pts.len == 1) {
                it.done = true;
                return it.pts[0];
            }
            if (it.span + 1 >= it.pts.len) {
                it.done = true;
                return it.pts[it.pts.len - 1];
            }
            const s: isize = @intCast(it.span);
            const p = [4]Point{ it.at(s - 1), it.at(s), it.at(s + 1), it.at(s + 2) };
            const i = it.i;
            it.i += 1;
            if (it.i == 16) {
                it.i = 0;
                it.span += 1;
            }
            if (i == 0) return p[1];
            var d: [3]f32 = undefined;
            var t: [4]f32 = undefined;
            t[0] = 0;
            for (0..3) |k| {
                d[k] = @sqrt(std.math.hypot(p[k + 1].x - p[k].x, p[k + 1].y - p[k].y));
                t[k + 1] = t[k] + d[k];
            }
            const tt = d[0] + (@as(f32, @floatFromInt(i)) / 16) * d[1];
            var a: [3]Point = undefined;
            for (0..3) |k| {
                const f = (tt - t[k]) / d[k];
                a[k] = .{ .x = p[k].x + f * (p[k + 1].x - p[k].x), .y = p[k].y + f * (p[k + 1].y - p[k].y) };
            }
            var b: [2]Point = undefined;
            for (0..2) |k| {
                const f = (tt - t[k]) / (d[k] + d[k + 1]);
                b[k] = .{ .x = a[k].x + f * (a[k + 1].x - a[k].x), .y = a[k].y + f * (a[k + 1].y - a[k].y) };
            }
            const f = (tt - t[1]) / d[1];
            return .{ .x = b[0].x + f * (b[1].x - b[0].x), .y = b[0].y + f * (b[1].y - b[0].y) };
        }
    };

    /// Calls `f.dot(point, multiplier)` for points one pixel apart along
    /// the curve, the last with the arc length left before the end.
    fn each(w: Walker, f: anytype) void {
        var it: Iter = .{ .pts = w.pts };
        var current = it.next().?;
        f.dot(current, 1);
        var next = it.next();
        while (next != null) {
            var previous = current;
            var from_previous: f32 = 0;
            while (true) {
                const nx = next orelse {
                    f.dot(previous, from_previous);
                    return;
                };
                const dx = nx.x - previous.x;
                const dy = nx.y - previous.y;
                const to_next = @sqrt(dx * dx + dy * dy);
                if (from_previous + to_next >= 1) {
                    const k = (1 - from_previous) / to_next;
                    current = .{ .x = previous.x + k * dx, .y = previous.y + k * dy };
                    f.dot(current, 1);
                    break;
                }
                from_previous += to_next;
                previous = nx;
                next = it.next();
            }
        }
    }
};

const Counter = struct {
    n: usize = 0,
    last: f32 = 0,
    fn dot(c: *Counter, _: Point, m: f32) void {
        c.n += 1;
        c.last = m;
    }
};

const Drawer = struct {
    curve: *const Curve,
    inv_arc: f32,
    k: usize = 0,
    planes: [3][]f32,
    stride: usize,
    w: usize,
    h: usize,

    fn dot(d: *Drawer, p: Point, intensity: f32) void {
        const progress = @min(1, @as(f32, @floatFromInt(d.k)) * d.inv_arc);
        d.k += 1;
        var color: [3]f32 = undefined;
        for (&color, &d.curve.color) |*c, *dct| c.* = idct(dct, 31 * progress);
        const sigma = idct(&d.curve.sigma, 31 * progress);
        const finite = std.math.isFinite(sigma) and sigma != 0 and std.math.isFinite(1 / sigma);
        if (!(finite and std.math.isFinite(intensity))) return;
        var max_color: f32 = 0.01;
        for (color) |c| max_color = @max(max_color, @abs(c * intensity));
        const max_dist = @sqrt(-2 * sigma * sigma * (@log(@as(f32, 0.1)) * 3 - @log(max_color)));
        if (!std.math.isFinite(max_dist)) return;
        const y0: i64 = @max(0, llround(p.y - max_dist));
        const y1: i64 = @min(@as(i64, @intCast(d.h)), llround(p.y + max_dist) + 1);
        const x0: i64 = @max(0, llround(p.x - max_dist));
        const x1: i64 = @min(@as(i64, @intCast(d.w)), llround(p.x + max_dist) + 1);
        if (y1 <= y0 or x1 <= x0) return;
        const inv_sigma = 1 / sigma;
        const scale = 0.25 * sigma * intensity;
        var y = y0;
        while (y < y1) : (y += 1) {
            const dy = @as(f32, @floatFromInt(y)) - p.y;
            const row: usize = @as(usize, @intCast(y)) * d.stride;
            var x = x0;
            while (x < x1) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) - p.x;
                const dist = @sqrt(@mulAdd(f32, dx, dx, dy * dy));
                const one_d = erf(@mulAdd(f32, dist, 0.5, 0.353553391) * inv_sigma) -
                    erf(@mulAdd(f32, dist, 0.5, -0.353553391) * inv_sigma);
                const local = scale * (one_d * one_d);
                const at = row + @as(usize, @intCast(x));
                for (0..3) |c| d.planes[c][at] = @mulAdd(f32, color[c], local, d.planes[c][at]);
            }
        }
    }
};

fn llround(v: f32) i64 {
    const r = @round(v);
    if (!(r > -9e18 and r < 9e18)) return if (r > 0) std.math.maxInt(i32) else std.math.minInt(i32);
    return @intFromFloat(r);
}

/// Adds the splines to the X, Y, and B planes (`w` by `h`, rows of
/// `stride`), with chroma from luma factors `ytox` and `ytob`; the limits
/// on their area come from `px_up`, the frame's pixels after upsampling.
pub fn draw(
    arena: *Arena,
    sp: *const Splines,
    planes: [3][]f32,
    stride: usize,
    w: usize,
    h: usize,
    px_up: u64,
    ytox: f32,
    ytob: f32,
) Error!void {
    const area_limit: u64 = @min(1024 * px_up + (1 << 32), 1 << 42);
    const inv_quant = invAdjusted(sp.quant_adjustment);
    var total_area: u64 = 0;
    // First the checks the reference makes on every spline, then the
    // drawing, so that a bad spline draws nothing.
    for (0..2) |pass| {
        for (sp.list) |*s| {
            const m = arena.mark();
            defer arena.release(m);
            const pts = try arena.alloc(Point, s.n + 1);
            var cur = s.start;
            if (@abs(cur[0]) >= pos_limit or @abs(cur[1]) >= pos_limit) return error.BadImage;
            pts[0] = .{ .x = @floatFromInt(cur[0]), .y = @floatFromInt(cur[1]) };
            var delta: [2]i64 = .{ 0, 0 };
            var manhattan: u64 = 0;
            for (sp.points[s.first..][0..s.n], pts[1..]) |dd, *o| {
                delta[0] += dd[0];
                delta[1] += dd[1];
                manhattan += @abs(delta[0]) + @abs(delta[1]);
                if (manhattan > area_limit) return error.BadImage;
                if (@abs(delta[0]) >= pos_limit or @abs(delta[1]) >= pos_limit) return error.BadImage;
                cur[0] += delta[0];
                cur[1] += delta[1];
                if (@abs(cur[0]) >= pos_limit or @abs(cur[1]) >= pos_limit) return error.BadImage;
                o.* = .{ .x = @floatFromInt(cur[0]), .y = @floatFromInt(cur[1]) };
            }
            for (pts[1..], pts[0 .. pts.len - 1]) |a, b| if (a.x == b.x and a.y == b.y) return error.BadImage;
            var curve: Curve = undefined;
            for (0..3) |c| {
                for (0..32) |i| {
                    const f: f32 = if (i == 0) std.math.sqrt1_2 else 1;
                    curve.color[c][i] = @as(f32, @floatFromInt(s.color[c][i])) * f * channel_weight[c] * inv_quant;
                }
            }
            for (0..32) |i| {
                curve.color[0][i] += ytox * curve.color[1][i];
                curve.color[2][i] += ytob * curve.color[1][i];
            }
            if (pass == 0) {
                // The estimate of the area the spline covers.
                var col: [3]u64 = .{ 0, 0, 0 };
                for (0..3) |c| {
                    for (s.color[c]) |v| col[c] += @intFromFloat(@ceil(inv_quant * @abs(@as(f32, @floatFromInt(v)))));
                }
                col[0] +|= @as(u64, @intFromFloat(@min(1e18, @ceil(@abs(ytox))))) *| col[1];
                col[2] +|= @as(u64, @intFromFloat(@min(1e18, @ceil(@abs(ytob))))) *| col[1];
                const max_col = @max(col[0], col[1], col[2]);
                const logcolor: u64 = @max(1, std.math.log2_int_ceil(u64, 1 +| max_col));
                const per_color = @as(f32, @floatFromInt(area_limit)) / @as(f32, @floatFromInt(logcolor));
                const weight_limit = @ceil(@sqrt(per_color / @as(f32, @floatFromInt(@max(1, manhattan)))));
                var width: u64 = 0;
                for (s.sigma) |v| {
                    const wf = @ceil(inv_quant * @abs(@as(f32, @floatFromInt(v))));
                    const weight: u64 = @intFromFloat(@min(weight_limit, @max(1, wf)));
                    width +|= weight *| weight *| logcolor;
                }
                total_area +|= width *| manhattan;
                if (total_area > area_limit) return error.BadImage;
                continue;
            }
            for (0..32) |i| {
                const f: f32 = if (i == 0) std.math.sqrt1_2 else 1;
                curve.sigma[i] = @as(f32, @floatFromInt(s.sigma[i])) * f * channel_weight[3] * inv_quant;
            }
            const walker: Walker = .{ .pts = pts };
            var counter: Counter = .{};
            walker.each(&counter);
            const arc = @as(f32, @floatFromInt(counter.n -| 2)) + counter.last;
            if (counter.n < 2 or arc <= 0) continue;
            var drawer: Drawer = .{
                .curve = &curve,
                .inv_arc = 1 / arc,
                .planes = planes,
                .stride = stride,
                .w = w,
                .h = h,
            };
            walker.each(&drawer);
        }
        // The reference fails a file whose splines would take too long to
        // draw only when fuzzing; this decoder always does.
        if (pass == 0 and total_area > @min(8 * px_up + (1 << 25), 1 << 30)) return error.TooComplex;
    }
}

test "erf" {
    try testing.expectApproxEqAbs(0.0, erf(0), 1e-7);
    try testing.expectApproxEqAbs(0.8427007929, erf(1), 2e-7);
    try testing.expectApproxEqAbs(-0.9953222650, erf(-2), 2e-7);
}
