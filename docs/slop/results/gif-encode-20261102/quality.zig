//! Decision 6's encoder side: encodes each raw RGBA8 input (`<name>-WxH.raw`)
//! with every quantizer, refine, and dither setting, best of three timed
//! calls, writing `<out>/<name>__<config>.gif` and a line of name, config,
//! pixels, bytes, and nanoseconds. Built against src/root.zig as module
//! `image` (with `compress`), ReleaseFast for this CPU; score.sh scores the
//! files.

const std = @import("std");
const image = @import("image");

const Cfg = struct { name: []const u8, o: image.gif.EncodeOptions };
const cfgs = [_]Cfg{
    .{ .name = "wu-r0-none", .o = .{ .quantizer = .wu, .refine = 0, .dither = .none } },
    .{ .name = "wu-r0-fs", .o = .{ .quantizer = .wu, .refine = 0, .dither = .floyd_steinberg } },
    .{ .name = "wu-r2-none", .o = .{ .quantizer = .wu, .refine = 2, .dither = .none } },
    .{ .name = "wu-r2-fs", .o = .{ .quantizer = .wu, .refine = 2, .dither = .floyd_steinberg } },
    .{ .name = "mc-r0-none", .o = .{ .quantizer = .median_cut, .refine = 0, .dither = .none } },
    .{ .name = "mc-r0-fs", .o = .{ .quantizer = .median_cut, .refine = 0, .dither = .floyd_steinberg } },
    .{ .name = "mc-r2-none", .o = .{ .quantizer = .median_cut, .refine = 2, .dither = .none } },
    .{ .name = "mc-r2-fs", .o = .{ .quantizer = .median_cut, .refine = 2, .dither = .floyd_steinberg } },
    .{ .name = "oct-r0-none", .o = .{ .quantizer = .octree, .refine = 0, .dither = .none } },
    .{ .name = "oct-r0-fs", .o = .{ .quantizer = .octree, .refine = 0, .dither = .floyd_steinberg } },
    .{ .name = "oct-r2-none", .o = .{ .quantizer = .octree, .refine = 2, .dither = .none } },
    .{ .name = "oct-r2-fs", .o = .{ .quantizer = .octree, .refine = 2, .dither = .floyd_steinberg } },
    .{ .name = "wu-r8-none", .o = .{ .quantizer = .wu, .refine = 8, .dither = .none } },
    .{ .name = "wu-r8-fs", .o = .{ .quantizer = .wu, .refine = 8, .dither = .floyd_steinberg } },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_dir = args[1];
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    for (args[2..]) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(data);
        const base = std.fs.path.basename(path);
        const stem = base[0 .. base.len - 4];
        const dash = std.mem.lastIndexOfScalar(u8, stem, '-').?;
        const x = std.mem.indexOfScalar(u8, stem[dash..], 'x').? + dash;
        const w = try std.fmt.parseInt(u32, stem[dash + 1 .. x], 10);
        const h = try std.fmt.parseInt(u32, stem[x + 1 ..], 10);
        const src = try image.PixelBuffer.init(data, .rgba8, w, h);
        const out = try gpa.alloc(u8, @as(usize, w) * h * 2 + 4096);
        defer gpa.free(out);
        for (cfgs) |c| {
            const work = try gpa.alloc(u8, image.gif.workLen(c.o, w, h).?);
            defer gpa.free(work);
            var best: u64 = std.math.maxInt(u64);
            var n: usize = 0;
            for (0..3) |_| {
                var wr: std.Io.Writer = .fixed(out);
                const t0 = std.Io.Timestamp.now(io, .awake);
                try image.gif.encode(&wr, src, c.o, work);
                const dt: u64 = @intCast(t0.untilNow(io, .awake).nanoseconds);
                best = @min(best, dt);
                n = wr.end;
            }
            const name = try std.fmt.allocPrint(gpa, "{s}/{s}__{s}.gif", .{ out_dir, stem[0..dash], c.name });
            defer gpa.free(name);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = out[0..n] });
            try stdout.interface.print("{s}\t{s}\t{d}\t{d}\t{d}\n", .{ stem[0..dash], c.name, @as(u64, w) * h, n, best });
            try stdout.interface.flush();
        }
    }
}
