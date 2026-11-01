//! The check of docs/slop/results/convert-rounding-20261101.md:
//! `image.convert` against Wuffs's pixel swizzler (wuffs-probe.c) on every
//! pair of pixel formats both have, and against Go's image/color
//! (go-probe/) on the pairs Go has.
//!
//!   wuffs-probe            every pair Wuffs has, with every 8-bit (c, a)
//!                          pair, every RGB triple, every 16-bit gray, and
//!                          16-bit RGBA with every alpha and random colors
//!   wuffs-probe go BASE... Go's outputs, BASE.in and BASE.out, against ours
//!
//! A pair's line counts the pixels that differ. A premultiplied source pixel
//! with a color above its alpha is not valid and is counted apart: Wuffs's
//! unpremultiply overflows on it and ours clamps. probe.sh builds and runs
//! both.

const std = @import("std");
const convert = @import("convert");
const PixelFormat = @typeInfo(@TypeOf(convert.convert)).@"fn".params[1].type.?;

extern fn probe_wuffs_swizzle(dst: u8, src: u8, out: [*]u8, out_len: usize, in: [*]const u8, in_len: usize) usize;

const gpa = std.heap.smp_allocator;

fn inputs(f: PixelFormat, random: std.Random) ![]u8 {
    const bpp = f.bytesPerPixel();
    var list: std.ArrayList(u8) = .empty;
    const c = f.channels();
    const n_ch = f.channelCount();
    if (f.sample() == .u8) {
        if (n_ch == 1) {
            for (0..256) |v| try list.append(gpa, @intCast(v));
        } else if (c.a == null) {
            // Every RGB triple.
            for (0..1 << 24) |v| {
                try list.append(gpa, @truncate(v));
                try list.append(gpa, @truncate(v >> 8));
                try list.append(gpa, @truncate(v >> 16));
            }
        } else {
            // Every (c, a) pair, with the color channels c, 255 - c, and a third.
            for (0..256) |a| for (0..256) |v| {
                var px: [4]u8 = undefined;
                const vals = [3]u8{ @intCast(v), @intCast(255 - v), @truncate(v * 91 + 17) };
                var k: usize = 0;
                for (0..n_ch) |ch| {
                    if (ch == c.a.?) px[ch] = @intCast(a) else {
                        px[ch] = vals[k];
                        k += 1;
                    }
                }
                try list.appendSlice(gpa, px[0..n_ch]);
            };
            // And random pixels.
            const old = list.items.len;
            try list.resize(gpa, old + bpp * (1 << 20));
            random.bytes(list.items[old..]);
        }
    } else {
        std.debug.assert(f.sample() == .u16);
        if (n_ch == 1) {
            for (0..65536) |v| try list.appendSlice(gpa, &std.mem.toBytes(@as(u16, @intCast(v))));
        } else if (c.a == null) {
            try list.resize(gpa, bpp * (1 << 20));
            random.bytes(list.items);
        } else {
            const ai = c.a.?;
            const special = [_]u16{ 0, 1, 2, 127, 128, 255, 256, 257, 258, 32767, 32768, 65278, 65279, 65280, 65534, 65535 };
            var px: [4]u16 = undefined;
            // Every alpha with 16 random colors.
            for (0..65536) |a| for (0..16) |_| {
                for (0..4) |ch| px[ch] = random.int(u16);
                px[ai] = @intCast(a);
                try list.appendSlice(gpa, std.mem.sliceAsBytes(px[0..n_ch]));
            };
            // Every color with special alphas, and every alpha with special colors.
            for (0..65536) |v| for (special) |s| {
                for (0..4) |ch| px[ch] = @intCast(v);
                px[ai] = s;
                try list.appendSlice(gpa, std.mem.sliceAsBytes(px[0..n_ch]));
                for (0..4) |ch| px[ch] = s;
                px[ai] = @intCast(v);
                try list.appendSlice(gpa, std.mem.sliceAsBytes(px[0..n_ch]));
            };
            const old = list.items.len;
            try list.resize(gpa, old + bpp * (1 << 20));
            random.bytes(list.items[old..]);
        }
    }
    return list.toOwnedSlice(gpa);
}

/// Whether no color sample of a premultiplied pixel exceeds its alpha.
fn validPremul(f: PixelFormat, px: []const u8) bool {
    const c = f.channels();
    const a = c.a.?;
    var v: [4]u16 = undefined;
    for (0..f.channelCount()) |ch| v[ch] = if (f.sample() == .u8) px[ch] else std.mem.readInt(u16, px[2 * ch ..][0..2], .little);
    for (0..f.channelCount()) |ch| if (v[ch] > v[a]) return false;
    return true;
}

/// `probe go BASE...`: compares Go's outputs (goprobe) with ours.
fn compareGo(io: std.Io, bases: []const []const u8) !void {
    for (bases) |base| {
        const name = std.fs.path.basename(base);
        const dash = std.mem.indexOfScalar(u8, name, '-').?;
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
        const s = std.meta.stringToEnum(PixelFormat, name[0..dash]).?;
        const d = std.meta.stringToEnum(PixelFormat, name[dash + 1 .. dot]).?;
        const in = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(gpa, "{s}.in", .{base}), gpa, .limited(1 << 30));
        const want = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(gpa, "{s}.out", .{base}), gpa, .limited(1 << 30));
        const n = in.len / s.bytesPerPixel();
        const got = try gpa.alloc(u8, want.len);
        convert.convert(got, d, in, s, n);
        const sb = s.bytesPerPixel();
        const db = d.bytesPerPixel();
        var bad: usize = 0;
        var invalid: usize = 0;
        var invalid_bad: usize = 0;
        for (0..n) |i| {
            const same = std.mem.eql(u8, want[i * db ..][0..db], got[i * db ..][0..db]);
            if (s.isPremultiplied() and !validPremul(s, in[i * sb ..][0..sb])) {
                invalid += 1;
                if (!same) invalid_bad += 1;
                continue;
            }
            if (same) continue;
            if (bad < 4) std.debug.print("  {s}: in {any} go {any} ours {any}\n", .{ name, in[i * sb ..][0..sb], want[i * db ..][0..db], got[i * db ..][0..db] });
            bad += 1;
        }
        std.debug.print("go {s}: {d} pixels, {d} differ; {d} invalid premultiplied, {d} of them differ\n", .{ name, n, bad, invalid, invalid_bad });
    }
}

pub fn main(init: std.process.Init) !void {
    var args: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(gpa);
    while (it.next()) |a| try args.append(gpa, a);
    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "go")) return compareGo(init.io, args.items[2..]);
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    var total: usize = 0;
    var differ: usize = 0;
    for (std.enums.values(PixelFormat)) |s| {
        if (s.sample() == .f32) continue;
        const in = try inputs(s, random);
        defer gpa.free(in);
        const n = in.len / s.bytesPerPixel();
        for (std.enums.values(PixelFormat)) |d| {
            const len = n * d.bytesPerPixel();
            const want = try gpa.alloc(u8, len);
            defer gpa.free(want);
            const got = try gpa.alloc(u8, len);
            defer gpa.free(got);
            if (probe_wuffs_swizzle(@intFromEnum(d), @intFromEnum(s), want.ptr, len, in.ptr, in.len) != n) continue;
            total += 1;
            convert.convert(got, d, in, s, n);
            const sb = s.bytesPerPixel();
            const db = d.bytesPerPixel();
            var bad: usize = 0;
            var invalid: usize = 0;
            var invalid_bad: usize = 0;
            for (0..n) |i| {
                const same = std.mem.eql(u8, want[i * db ..][0..db], got[i * db ..][0..db]);
                if (s.isPremultiplied() and !validPremul(s, in[i * sb ..][0..sb])) {
                    invalid += 1;
                    if (!same) invalid_bad += 1;
                    continue;
                }
                if (std.mem.eql(u8, want[i * db ..][0..db], got[i * db ..][0..db])) continue;
                if (bad < 4) std.debug.print("  {t} -> {t}: in {any} wuffs {any} ours {any}\n", .{ s, d, in[i * sb ..][0..sb], want[i * db ..][0..db], got[i * db ..][0..db] });
                bad += 1;
            }
            if (bad > 0) differ += 1;
            std.debug.print("{s} -> {s}: {d} pixels, {d} differ; {d} invalid premultiplied, {d} of them differ\n", .{ @tagName(s), @tagName(d), n, bad, invalid, invalid_bad });
        }
    }
    std.debug.print("{d} pairs, {d} differ\n", .{ total, differ });
}
