//! Scratch: encodeAlpha on raw planes (name ...-WxH.a8) at an effort; prints bytes and the best of R runs' ms.
const std = @import("std");
const image = @import("image");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const effort = try std.fmt.parseInt(u4, args[1], 10);
    const runs = try std.fmt.parseInt(u32, args[2], 10);
    var total: usize = 0;
    var total_ns: u64 = 0;
    for (args[3..]) |path| {
        const base = std.fs.path.basename(path);
        const stem = base[0 .. base.len - 3];
        const dash = std.mem.lastIndexOfScalar(u8, stem, '-').?;
        const x = std.mem.indexOfScalar(u8, stem[dash..], 'x').? + dash;
        const w = try std.fmt.parseInt(u32, stem[dash + 1 .. x], 10);
        const h = try std.fmt.parseInt(u32, stem[x + 1 ..], 10);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(data);
        const work = try gpa.alloc(u8, image.webp.workLen(.{ .effort = effort }, w, h).?);
        defer gpa.free(work);
        const out = try gpa.alloc(u8, data.len * 2 + 65536);
        defer gpa.free(out);
        var best: u64 = std.math.maxInt(u64);
        var len: usize = 0;
        for (0..runs) |_| {
            var writer: std.Io.Writer = .fixed(out);
            const t0 = std.Io.Clock.awake.now(io);
            try image.webp.encodeAlpha(&writer, data, w, h, effort, work);
            const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
            best = @min(best, ns);
            len = writer.end;
        }
        if (init.environ_map.get("OUT")) |dir| {
            const name = try std.fmt.allocPrint(gpa, "{s}/{s}.vp8l", .{ dir, stem });
            defer gpa.free(name);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = out[0..len] });
        }
        total += len;
        total_ns += best;
        if (init.environ_map.get("Q") == null) std.debug.print("{s}\t{d}\t{d:.2}ms\n", .{ stem, len, @as(f64, @floatFromInt(best)) / 1e6 });
    }
    std.debug.print("TOTAL\t{d}\t{d:.2}ms\n", .{ total, @as(f64, @floatFromInt(total_ns)) / 1e6 });
}
