// Swap3 per call and over whole images, the formats picked at run time
// as a decoder picks them.
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
    const Pair = struct { name: []const u8, d: PF, s: PF };
    var pairs = [_]Pair{
        .{ .name = "rgb8->bgr8", .d = .bgr8, .s = .rgb8 },
        .{ .name = "rgb16->bgr16", .d = .bgr16, .s = .rgb16 },
    };
    std.mem.doNotOptimizeAway(&pairs);
    const ns = [_]usize{ 16, 22, 166, 1000, 8192 };
    for (pairs) |p| {
        const c = conv.Converter.init(p.d, p.s);
        for (ns) |n| {
            const iters: usize = @max(1000, 40_000_000 / (n * 6 + 40));
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
    const sizes = [_][2]usize{ .{ 1200, 1200 }, .{ 8192, 6144 } };
    for (sizes) |wh| {
        const w = wh[0];
        const h = wh[1];
        const in = try a.alloc(u8, w * h * 3);
        defer a.free(in);
        const out = try a.alloc(u8, w * h * 3 + 4096);
        defer a.free(out);
        for (in, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
        @memset(out, 1);
        const c = conv.Converter.init(pairs[0].d, pairs[0].s);
        var best: f64 = 1e30;
        for (0..7) |_| {
            const t0 = now();
            for (0..h) |y| c.run(out[2048 + y * w * 3 ..], in[y * w * 3 ..], w);
            std.mem.doNotOptimizeAway(out.ptr);
            best = @min(best, @as(f64, @floatFromInt(now() - t0)));
        }
        std.debug.print("image\trgb8->bgr8\t{d}x{d}\t{d:.2} ms\t{d:.0} MP/s\n", .{ w, h, best / 1e6, @as(f64, @floatFromInt(w * h)) * 1000.0 / best });
    }
}
