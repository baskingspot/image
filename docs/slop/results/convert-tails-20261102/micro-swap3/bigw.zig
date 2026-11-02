const std = @import("std");
const conv = @import("conv");
const linux = std.os.linux;
const PF = @FieldType(conv.Converter, "dst");

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    try big();
}

fn big() !void {
    const PairB = struct { name: []const u8, d: PF, s: PF };
    const pairs = [_]PairB{
        .{ .name = "bgr8->rgb8", .d = .rgb8, .s = .bgr8 },
    };
    const w: usize = @import("cfg").w;
    const h: usize = @import("cfg").h;
    const a = std.heap.page_allocator;
    const in = try a.alloc(u8, w * h * 4);
    const out = try a.alloc(u8, w * h * 4 + 4096);
    for (in, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    @memset(out, 1);
    for (pairs) |p| {
        const c = conv.Converter.init(p.d, p.s);
        const sb = p.s.bytesPerPixel();
        const db = p.d.bytesPerPixel();
        var best: f64 = 1e30;
        for (0..7) |_| {
            const t0 = now();
            for (0..h) |y| c.run(out[2048 + y * w * db ..], in[y * w * sb ..], w);
            std.mem.doNotOptimizeAway(out.ptr);
            best = @min(best, @as(f64, @floatFromInt(now() - t0)));
        }
        std.debug.print("big {s}\t{d:.2} ms\t{d:.0} MP/s\n", .{ p.name, best / 1e6, @as(f64, w * h) * 1000.0 / best });
    }
}
