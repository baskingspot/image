//! Times `Converter.run` on float pairs, in benchstat's format: one call of
//! n pixels, best of 5 batches, per pair and n; `image` is an image of 4
//! megapixels converted a row of 2048 at a time, past the cache. Built
//! against a directory holding `convert.zig` and `pixel.zig` (ab.sh).
const std = @import("std");
const conv = @import("conv");
const linux = std.os.linux;
const PF = @FieldType(conv.Converter, "dst");

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const big = 2048 * 2048;
var src: [big * 16]u8 align(64) = undefined;
var dst: [big * 16]u8 align(64) = undefined;

pub fn main() !void {
    // Floats mostly in 0 to 1, some outside; bytes as they fall for the
    // integer sources.
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    for (std.mem.bytesAsSlice(f32, &src)) |*v| v.* = r.float(f32) * 1.1 - 0.05;
    const Pair = struct { name: []const u8, d: PF, s: PF };
    const pairs = [_]Pair{
        .{ .name = "rgba_f32-rgba8", .d = .rgba8, .s = .rgba_f32 },
        .{ .name = "rgb_f32-rgb8", .d = .rgb8, .s = .rgb_f32 },
        .{ .name = "gray_f32-gray8", .d = .gray8, .s = .gray_f32 },
        .{ .name = "rgba_f32-rgba16", .d = .rgba16, .s = .rgba_f32 },
        .{ .name = "rgba8-rgba_f32", .d = .rgba_f32, .s = .rgba8 },
        .{ .name = "rgb8-rgb_f32", .d = .rgb_f32, .s = .rgb8 },
        .{ .name = "rgba16-rgba_f32", .d = .rgba_f32, .s = .rgba16 },
        // Controls: pairs the change does not touch.
        .{ .name = "rgba8-bgra8", .d = .bgra8, .s = .rgba8 },
        .{ .name = "rgba_f32-rgb_f32", .d = .rgb_f32, .s = .rgba_f32 },
    };
    const ns = [_]usize{ 16, 166, 1024, 8192 };
    for (pairs) |p| {
        const c = conv.Converter.init(p.d, p.s);
        for (ns) |n| {
            const iters: usize = @max(200, 20_000_000 / (n * 8 + 40));
            var best: f64 = 1e30;
            for (0..5) |_| {
                const t0 = now();
                for (0..iters) |_| {
                    c.run(&dst, &src, n);
                    std.mem.doNotOptimizeAway(&dst);
                }
                best = @min(best, @as(f64, @floatFromInt(now() - t0)) / @as(f64, @floatFromInt(iters)));
            }
            std.debug.print("Benchmark{s}/n={d} {d} {d:.2} ns/op {d:.1} MP/s\n", .{ p.name, n, iters, best, @as(f64, @floatFromInt(n)) * 1000.0 / best });
        }
        // A whole image, a row at a time, past the cache.
        const row = 2048;
        const ib = p.s.bytesPerPixel();
        const ob = p.d.bytesPerPixel();
        var best: f64 = 1e30;
        for (0..3) |_| {
            const t0 = now();
            for (0..big / row) |y| c.run(dst[y * row * ob ..], src[y * row * ib ..], row);
            std.mem.doNotOptimizeAway(&dst);
            best = @min(best, @as(f64, @floatFromInt(now() - t0)));
        }
        std.debug.print("Benchmark{s}/image-4MP 1 {d:.0} ns/op {d:.1} MP/s\n", .{ p.name, best, @as(f64, big) * 1000.0 / best });
    }
}
