const std = @import("std");
const conv = @import("conv");
const linux = std.os.linux;
const PF = @FieldType(conv.Converter, "dst");

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var src: [8192 * 16]u8 align(64) = undefined;
var dst: [8192 * 16]u8 align(64) = undefined;

pub fn main() !void {
    for (&src, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    const Pair = struct { name: []const u8, d: PF, s: PF };
    const pairs = [_]Pair{
        .{ .name = "bgr8->rgba8", .d = .rgba8, .s = .bgr8 },
        .{ .name = "bgr8->rgb8", .d = .rgb8, .s = .bgr8 },
        .{ .name = "bgra8->rgba8", .d = .rgba8, .s = .bgra8 },
        .{ .name = "rgb8->bgra8", .d = .bgra8, .s = .rgb8 },
        .{ .name = "gray8->rgba8", .d = .rgba8, .s = .gray8 },
        .{ .name = "rgba8->rgb8", .d = .rgb8, .s = .rgba8 },
        .{ .name = "rgba16->rgba8", .d = .rgba8, .s = .rgba16 },
        .{ .name = "rgba8->premul", .d = .rgba8_premul, .s = .rgba8 },
        .{ .name = "rgba16->bgra16", .d = .bgra16, .s = .rgba16 },
    };
    const ns = [_]usize{ 16, 22, 64, 166, 256, 1000, 8192 };
    for (pairs) |p| {
        const c = conv.Converter.init(p.d, p.s);
        for (ns) |n| {
            const iters: usize = @max(1000, 40_000_000 / (n * 4 + 40));
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
            std.debug.print("{s}\t{d}\t{d:.1} ns\t{d:.0} MP/s\n", .{ p.name, n, best, @as(f64, @floatFromInt(n)) * 1000.0 / best });
        }
    }
}
