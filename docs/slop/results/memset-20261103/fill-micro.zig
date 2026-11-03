const std = @import("std");
const fill = @import("fill.zig").fill;
pub fn main() !void {
    const sizes = [_]usize{ 16, 64, 256, 1024, 1608, 4096, 65536, 1 << 20, 8 << 20 };
    const buf = try std.heap.page_allocator.alloc(u8, 8 << 20);
    @memset(buf, 1);
    for (sizes) |n| {
        var best = [2]u64{ std.math.maxInt(u64), std.math.maxInt(u64) };
        const reps = @max(1, (64 << 20) / n);
        for (0..5) |_| for (0..2) |k| {
            const t0 = now();
            for (0..reps) |r| {
                const d = buf[0..n];
                if (k == 0) @memset(d, @truncate(r)) else fill(u8, d, @truncate(r));
                std.mem.doNotOptimizeAway(d.ptr);
            }
            best[k] = @min(best[k], now() - t0);
        };
        const ns0 = @as(f64, @floatFromInt(best[0])) / @as(f64, @floatFromInt(reps));
        const ns1 = @as(f64, @floatFromInt(best[1])) / @as(f64, @floatFromInt(reps));
        std.debug.print("{d:>8} B  @memset {d:>10.1} ns ({d:>6.2} B/ns)  fill {d:>10.1} ns ({d:>6.2} B/ns)\n", .{ n, ns0, @as(f64, @floatFromInt(n)) / ns0, ns1, @as(f64, @floatFromInt(n)) / ns1 });
    }
}

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
