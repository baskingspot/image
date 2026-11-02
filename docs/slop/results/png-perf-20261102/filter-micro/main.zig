const std = @import("std");
const filter = @import("filter.zig");
const linux = std.os.linux;
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
pub fn main() !void {
    const w = 8192;
    var bufs: [5][w * 8 + 4096]u8 = undefined;
    const off = [5]usize{ 0, 1344, 2688, 704, 2048 };
    var prng = std.Random.DefaultPrng.init(1);
    for (&bufs) |*b| prng.random().bytes(b);
    inline for (.{ 3, 4 }) |f| {
        inline for (.{ 1, 2, 3, 4, 6, 8 }) |bpp| {
            const len = w * bpp;
            const c0 = bufs[0][off[0]..][0..len];
            const s0 = bufs[1][off[1]..][0..len];
            const pv = bufs[2][off[2]..][0..len];
            const c1 = bufs[3][off[3]..][0..len];
            const s1 = bufs[4][off[4]..][0..len];
            var best1: u64 = std.math.maxInt(u64);
            var best2: u64 = std.math.maxInt(u64);
            for (0..15) |_| {
                var t0 = now();
                for (0..10) |_| {
                    try filter.unfilter(f, c0, s0, pv, bpp);
                    try filter.unfilter(f, c1, s1, c0, bpp);
                    std.mem.doNotOptimizeAway(c1.ptr);
                }
                best1 = @min(best1, (now() - t0) / 10);
                t0 = now();
                for (0..10) |_| {
                    filter.unfilter2(f, bpp, c0, s0, c1, s1, pv);
                    std.mem.doNotOptimizeAway(c1.ptr);
                }
                best2 = @min(best2, (now() - t0) / 10);
            }
            std.debug.print("filter {d} bpp {d}: one row at a time {d:.2} ns/px, two rows {d:.2} ns/px\n", .{ f, bpp, @as(f64, @floatFromInt(best1)) / (2 * w), @as(f64, @floatFromInt(best2)) / (2 * w) });
        }
    }
}
