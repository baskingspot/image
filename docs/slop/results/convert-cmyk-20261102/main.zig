const std = @import("std");
const conv = @import("conv");
const linux = std.os.linux;
const PF = @FieldType(conv.Converter, "dst");

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// The JPEG decoder's per-pixel loop today (src/jpeg/sample.zig `cmyk`).
fn scalar(out: []u8, in: []const u8, n: usize) void {
    for (0..n) |x| {
        const p = in[x * 4 ..][0..4];
        const k: u32 = p[3];
        inline for (0..3) |ch| out[x * 4 + ch] = @intCast((2 * @as(u32, p[ch]) * k + 255) / 510);
        out[x * 4 + 3] = 255;
    }
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const widths = [_]usize{ 16, 166, 1200, 8192 };
    const total: usize = 8 << 20; // pixels per timing
    const in = try a.alloc(u8, total * 4 + 4096);
    const out = try a.alloc(u8, total * 4 + 4096);
    for (in, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    for ([_]PF{ .rgba8, .rgb8 }) |d| {
        const c = conv.Converter.init(d, .cmyk8);
        for (widths) |w| {
            const rows = total / w;
            for (0..2) |mode| {
                if (mode == 1 and d != .rgba8) continue;
                var best: f64 = 1e30;
                for (0..9) |_| {
                    const t0 = now();
                    for (0..rows) |y| {
                        const o = out[2048 + y * w * d.bytesPerPixel() ..];
                        const i = in[y * w * 4 ..];
                        if (mode == 0) c.run(o, i, w) else scalar(o, i, w);
                    }
                    std.mem.doNotOptimizeAway(out.ptr);
                    best = @min(best, @as(f64, @floatFromInt(now() - t0)));
                }
                // Go benchmark lines: ns per megapixel, and MP/s.
                const mp = @as(f64, @floatFromInt(rows * w)) / 1e6;
                std.debug.print("Benchmark{s}/{t}/w{d}\t1\t{d:.0} ns/op\t{d:.1} MP/s\n", .{ if (mode == 0) "Convert" else "JpegLoop", d, w, best / mp, mp * 1e9 / best });
            }
        }
    }
}
