//! Scratch: encode raw files (name ...-WxH.raw, RGB or RGBA) at an effort; R=n keeps the best of n encodes, Q=1 prints totals only, and a build patched by phases.py prints Mcycles per phase.
const std = @import("std");
const image = @import("image");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const effort = try std.fmt.parseInt(u4, args[1], 10);
    var total: usize = 0;
    const reps = if (init.environ_map.get("R")) |r| std.fmt.parseInt(u32, r, 10) catch 1 else 1;
    defer {
        if (@hasDecl(image.webp, "enc_internal")) {
            const T = image.webp.enc_internal.tsc;
            var all: u64 = 0;
            for (T) |t| all += t;
            std.debug.print("parse {d} +cache {d} ", .{ T[8] / 1000000, T[9] / 1000000 });
            std.debug.print("Mcycles: fill {d} rank {d} transforms {d} find {d} greedy+cache {d} optimal {d} groups {d} emit {d}\n", .{ T[7] / 1000000, T[0] / 1000000, T[6] / 1000000, T[1] / 1000000, T[2] / 1000000, T[3] / 1000000, T[4] / 1000000, T[5] / 1000000 });
        }
        std.debug.print("TOTAL {d}\n", .{total});
    }
    const outdir = args[2];
    for (args[3..]) |path| {
        const base = std.fs.path.basename(path);
        const stem = base[0 .. base.len - 4];
        const dash = std.mem.lastIndexOfScalar(u8, stem, '-').?;
        const x = std.mem.indexOfScalar(u8, stem[dash..], 'x').? + dash;
        const w = try std.fmt.parseInt(u32, stem[dash + 1 .. x], 10);
        const h = try std.fmt.parseInt(u32, stem[x + 1 ..], 10);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(data);
        const fmt: image.PixelFormat = if (data.len == @as(usize, w) * h * 4) .rgba8 else .rgb8;
        const src = try image.PixelBuffer.init(data, fmt, w, h);
        const opts: image.webp.EncodeOptions = .{ .effort = effort };
        const work = try gpa.alloc(u8, image.webp.workLen(opts, w, h).?);
        defer gpa.free(work);
        const out = try gpa.alloc(u8, data.len * 2 + 65536);
        defer gpa.free(out);
        var writer: std.Io.Writer = .fixed(out);
        var ns: i96 = std.math.maxInt(i64);
        for (0..reps) |_| {
            writer = .fixed(out);
            const t0 = std.Io.Clock.awake.now(io);
            try image.webp.encode(&writer, src, opts, work);
            ns = @min(ns, t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        }
        const name = try std.fmt.allocPrint(gpa, "{s}/{s}.webp", .{ outdir, stem });
        defer gpa.free(name);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = writer.buffered() });
        total += writer.end;
        if (init.environ_map.get("Q") == null) std.debug.print("{s}\t{d}\t{d:.2}ms\n", .{ stem, writer.end, @as(f64, @floatFromInt(ns)) / 1e6 });
    }
}
