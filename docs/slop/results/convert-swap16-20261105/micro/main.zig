// Swap3 and Swap4 per call and over whole images, both sample types, the
// formats picked at run time as a decoder picks them.
const std = @import("std");
const conv = @import("conv");
const linux = std.os.linux;
const PF = @FieldType(conv.Converter, "dst");

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var src: [8192 * 8]u8 align(64) = undefined;
var dst: [8192 * 8]u8 align(64) = undefined;

pub fn main() !void {
    for (&src, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    const Pair = struct { name: []const u8, d: PF, s: PF, bpp: usize };
    var pairs = [_]Pair{
        .{ .name = "rgb16->bgr16", .d = .bgr16, .s = .rgb16, .bpp = 6 },
        .{ .name = "rgba16->bgra16", .d = .bgra16, .s = .rgba16, .bpp = 8 },
        .{ .name = "rgb8->bgr8", .d = .bgr8, .s = .rgb8, .bpp = 3 },
        .{ .name = "rgba8->bgra8", .d = .bgra8, .s = .rgba8, .bpp = 4 },
    };
    std.mem.doNotOptimizeAway(&pairs);
    const ns = [_]usize{ 16, 22, 166, 1000, 8192 };
    for (pairs) |p| {
        const c = conv.Converter.init(p.d, p.s);
        for (ns) |n| {
            const iters: usize = @max(1000, 40_000_000 / (n * p.bpp * 2 + 40));
            var best: f64 = 1e30;
            for (0..7) |_| {
                const t0 = now();
                for (0..iters) |_| {
                    c.run(&dst, &src, n);
                    std.mem.doNotOptimizeAway(&dst);
                }
                const t = @as(f64, @floatFromInt(now() - t0)) / @as(f64, @floatFromInt(iters));
                best = @min(best, t);
            }
            std.debug.print("call\t{s}\t{d}\t{d:.1} ns\t{d:.0} MP/s\n", .{ p.name, n, best, @as(f64, @floatFromInt(n)) * 1000.0 / best });
        }
    }
    // Whole images of rows, the output 2048 bytes past a page.
    const a = std.heap.page_allocator;
    const sizes = [_][2]usize{ .{ 1200, 1200 }, .{ 4096, 3072 } };
    for (pairs[0..2]) |p| {
        for (sizes) |wh| {
            const w = wh[0];
            const h = wh[1];
            const row = w * p.bpp;
            const in = try a.alloc(u8, row * h);
            defer a.free(in);
            const out = try a.alloc(u8, row * h + 4096);
            defer a.free(out);
            for (in, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
            @memset(out, 1);
            const c = conv.Converter.init(p.d, p.s);
            var best: f64 = 1e30;
            for (0..7) |_| {
                const t0 = now();
                for (0..h) |y| c.run(out[2048 + y * row ..], in[y * row ..], w);
                std.mem.doNotOptimizeAway(out.ptr);
                best = @min(best, @as(f64, @floatFromInt(now() - t0)));
            }
            std.debug.print("image\t{s}\t{d}x{d}\t{d:.2} ms\t{d:.0} MP/s\n", .{ p.name, w, h, best / 1e6, @as(f64, @floatFromInt(w * h)) * 1000.0 / best });
        }
    }
}
