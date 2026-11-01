//! Which pairs of pixel formats convert differently after the change of
//! docs/slop/results/convert-rounding-20261101.md: `image.convert` before
//! (module `before`, src/convert.zig at 98d1033) and after (`after`) on the
//! same inputs, every one of the 400 pairs. Inputs: every 8-bit (c, a) pair
//! for 8-bit formats with alpha, and 256K random pixels for every format
//! (floats mostly in 0 to 1). Prints each pair that differs, with how many
//! pixels do.
//!
//!   zig build-exe -OReleaseSafe --dep before --dep after -Mroot=changed-pairs.zig \
//!     -Mbefore=OLD/src/convert.zig -Mafter=src/convert.zig

const std = @import("std");
const before = @import("before");
const after = @import("after");
const After = @typeInfo(@TypeOf(after.convert)).@"fn".params[1].type.?;

const gpa = std.heap.smp_allocator;

pub fn main() !void {
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    var changed: usize = 0;
    for (std.enums.values(After)) |s| {
        const bpp = s.bytesPerPixel();
        const structured: usize = if (s.sample() == .u8 and s.hasAlpha()) 65536 else 0;
        const n = structured + (1 << 18);
        const in = try gpa.alloc(u8, n * bpp);
        defer gpa.free(in);
        random.bytes(in);
        for (0..structured) |i| {
            const p = in[i * bpp ..][0..bpp];
            for (p, 0..) |*b, ch| b.* = @truncate(i *% (ch + 1));
            p[s.channels().a.?] = @intCast(i >> 8);
        }
        if (s.sample() == .f32) {
            const f = std.mem.bytesAsSlice(f32, in);
            for (f) |*v| v.* = random.float(f32) * 1.5 - 0.25;
        }
        for (std.enums.values(After)) |d| {
            const len = n * d.bytesPerPixel();
            const old = try gpa.alloc(u8, len);
            defer gpa.free(old);
            const new = try gpa.alloc(u8, len);
            defer gpa.free(new);
            // The enum is the same before and after.
            before.convert(old, @enumFromInt(@intFromEnum(d)), in, @enumFromInt(@intFromEnum(s)), n);
            after.convert(new, d, in, s, n);
            const db = d.bytesPerPixel();
            var bad: usize = 0;
            for (0..n) |i| {
                if (!std.mem.eql(u8, old[i * db ..][0..db], new[i * db ..][0..db])) bad += 1;
            }
            if (bad == 0) continue;
            changed += 1;
            std.debug.print("{s} -> {s}: {d} of {d}\n", .{ @tagName(s), @tagName(d), bad, n });
        }
    }
    std.debug.print("{d} of 400 pairs changed\n", .{changed});
}
