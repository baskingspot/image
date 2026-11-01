//! `just oracle`: holds each decoder against its reference libraries on the
//! format's corpus files and on N fuzzed inputs (mutated corpus files and
//! generated ones, from the format's fuzz target), in each pixel format the
//! format's table names.
//!
//! For every input and pixel format, this package and every oracle either
//! accept it, with pixels, or reject it. Two answers agree when both reject,
//! or both accept with the same size and the same pixels, and two deciders
//! agree on an input when they agree in every pixel format both answered.
//! A mismatch is an input where ours agrees with no oracle, or differs from
//! an oracle that every other oracle agrees with. When the oracles disagree among themselves
//! and ours agrees with one, that is counted, by which oracles we differ
//! from, and not a mismatch: the reference libraries disagree on what the
//! specification leaves open. Each format file says which disagreements it
//! expects and why, and can leave an oracle's answer out (`comparable`) or
//! hand an oracle the input with a field it misreads rewritten to an
//! equivalent value (`adapt`), so one library's quirk does not hide another's
//! on the same input. The first inputs of each kind are saved under
//! zig-out/oracle/<format>/.
//!
//!   oracle-compare [N] [SEED]

const std = @import("std");
const image = @import("image");
const fuzz = @import("fuzz");
const Oracle = @import("Oracle.zig");
const PixelFormat = image.PixelFormat;

/// The formats with oracles, from formats.zig.
const formats = @import("formats.zig");

/// The pixel limit for both sides, so a hostile header cannot make either
/// allocate much.
const max_pixels = 1 << 22;
const batch_inputs = 1000;
/// The most pixel bytes one batch may produce, ours and every oracle's
/// answers together, so large images make batches shorter rather than
/// exhausting memory.
const batch_bytes = 512 << 20;
const saved_per_kind = 5;

var io: std.Io = undefined;
const gpa = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip();
    const n = if (it.next()) |a| try std.fmt.parseInt(usize, a, 10) else 100_000;
    const seed = if (it.next()) |a| try std.fmt.parseInt(u64, a, 10) else 1;
    const oracle: Oracle = .{ .io = io, .gpa = gpa, .path = "zig-out/bin/image-oracle" };
    var mismatches: usize = 0;
    inline for (@typeInfo(formats).@"struct".decls) |d| {
        mismatches += try compareFormat(@field(formats, d.name), oracle, n, seed);
    }
    if (mismatches != 0) std.process.exit(1);
}

const Answer = struct {
    accepted: bool,
    width: u32 = 0,
    height: u32 = 0,
    pixels: []const u8 = &.{},

    fn agrees(a: Answer, b: Answer) bool {
        if (a.accepted != b.accepted) return false;
        if (!a.accepted) return true;
        return a.width == b.width and a.height == b.height and std.mem.eql(u8, a.pixels, b.pixels);
    }
};

fn ours(comptime D: type, input: []const u8, format: PixelFormat, arena: std.mem.Allocator) !Answer {
    var r: std.Io.Reader = .fixed(input);
    var d = D.init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
    const config = d.decodeConfig() catch return .{ .accepted = false };
    const len = image.PixelBuffer.len(format, config.width, config.height).?;
    const pixels = try arena.alloc(u8, len);
    const work = try arena.alloc(u8, config.work_len);
    const dst = try image.PixelBuffer.init(pixels, format, config.width, config.height);
    _ = (d.decodeFrame(dst, work) catch return .{ .accepted = false }) orelse return .{ .accepted = false };
    return .{ .accepted = true, .width = config.width, .height = config.height, .pixels = pixels };
}

/// The most pixel bytes `input` can produce in a batch: its size, from our
/// decoder's header, times every format's pixel size, for ours and each
/// oracle.
fn answerBytes(comptime F: type, input: []const u8) usize {
    var r: std.Io.Reader = .fixed(input);
    var d = F.Decoder.init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
    const config = d.decodeConfig() catch return input.len;
    var per_pixel: usize = 0;
    for (F.formats) |format| per_pixel += format.bytesPerPixel();
    return input.len + @as(usize, config.width) * config.height * per_pixel * (F.oracles.len + 1);
}

fn compareFormat(comptime F: type, oracle: Oracle, n: usize, seed: u64) !usize {
    const T = F.fuzz;
    const corpus = try loadCorpus(T);
    const dir = "zig-out/oracle/" ++ F.name;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var stats: Stats = .{};
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var done: usize = 0;
    const total = corpus.len + n;
    while (done < total) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        // A batch of inputs: corpus files first, then fuzzed ones, until the
        // batch would hold `batch_bytes` of pixels.
        const room = @min(batch_inputs, total - done);
        const all_inputs = try arena.alloc([]const u8, room);
        var count: usize = 0;
        var bytes: usize = 0;
        for (all_inputs, done..) |*input, i| {
            if (count > 0 and bytes >= batch_bytes) break;
            count += 1;
            defer bytes += answerBytes(F, input.*);
            if (i < corpus.len) {
                input.* = corpus[i];
                continue;
            }
            const buf = try arena.alloc(u8, 1 << 16);
            var len: usize = 0;
            if (corpus.len > 0 and random.boolean()) {
                const base = corpus[random.uintLessThan(usize, corpus.len)];
                const big = try arena.alloc(u8, base.len + 4096);
                @memcpy(big[0..base.len], base);
                len = fuzz.harness.mutate(random, big, base.len);
                input.* = big[0..len];
            } else {
                const g = T.generate(random, buf);
                len = g.len;
                if (random.uintLessThan(u8, 4) == 0) len = fuzz.harness.mutate(random, buf, len);
                input.* = buf[0..len];
            }
        }
        const inputs = all_inputs[0..count];
        var requests: std.ArrayList(Oracle.Request) = .empty;
        for (inputs) |input| {
            for (F.formats) |format| {
                for (F.oracles) |op| {
                    try requests.append(arena, .{
                        .op = op,
                        .format = format,
                        .max_pixels = max_pixels,
                        .input = try F.adapt(op, input, arena),
                    });
                }
            }
        }
        const responses = try oracle.run(requests.items);
        defer oracle.free(responses);
        var k: usize = 0;
        for (inputs, done..) |input, i| {
            var mine: [F.formats.len]Answer = undefined;
            var theirs: [F.formats.len][F.oracles.len]?Answer = undefined;
            for (F.formats, &mine, &theirs) |format, *m, *row| {
                m.* = try ours(F.Decoder, input, format, arena);
                for (row, F.oracles) |*t, op| {
                    const resp = responses[k];
                    k += 1;
                    t.* = if (!F.comparable(op, format, input)) null else switch (resp.status) {
                        .ok => .{ .accepted = true, .width = resp.width, .height = resp.height, .pixels = resp.pixels },
                        .rejected, .too_large => .{ .accepted = false },
                        else => null,
                    };
                }
            }
            try stats.add(F, dir, input, i < corpus.len, &mine, &theirs);
        }
        done += count;
    }
    stats.print(F, corpus.len, n);
    return stats.mismatches;
}

const Stats = struct {
    comparisons: usize = 0,
    mismatches: usize = 0,
    agreed: usize = 0,
    /// Oracle disagreements, keyed by which oracles ours differed from and
    /// whether ours accepted.
    split: std.array_hash_map.String(usize) = .empty,

    /// One input's answers in every format. Ours agrees with an oracle when
    /// it agrees in every format both answered, and two oracles agree the
    /// same way.
    fn add(
        s: *Stats,
        comptime F: type,
        dir: []const u8,
        input: []const u8,
        from_corpus: bool,
        mine: []const Answer,
        theirs: []const [F.oracles.len]?Answer,
    ) !void {
        s.comparisons += 1;
        const n = F.oracles.len;
        var answered: [n]bool = @splat(false);
        var with_us: [n]bool = @splat(true);
        var pair: [n][n]bool = @splat(@splat(true));
        for (mine, theirs) |m, row| {
            for (row, 0..) |t, o| {
                const a = t orelse continue;
                answered[o] = true;
                if (!m.agrees(a)) with_us[o] = false;
                for (row, 0..) |t2, o2| {
                    const b = t2 orelse continue;
                    if (!a.agrees(b)) pair[o][o2] = false;
                }
            }
        }
        var any_answered = false;
        var any_with_us = false;
        var all_with_us = true;
        var mismatch = false;
        var differs: std.ArrayList(u8) = .empty;
        for (0..n) |o| {
            if (!answered[o]) continue;
            any_answered = true;
            if (with_us[o]) {
                any_with_us = true;
                continue;
            }
            all_with_us = false;
            try differs.appendSlice(gpa, F.oracles[o]);
            try differs.append(gpa, ' ');
            // Differing from an oracle every other oracle agrees with.
            var backed = true;
            for (0..n) |o2| {
                if (o2 != o and answered[o2] and !pair[o][o2]) backed = false;
            }
            if (backed) mismatch = true;
        }
        if (!any_answered) return;
        if (all_with_us) {
            s.agreed += 1;
            return;
        }
        if (!any_with_us) mismatch = true;
        const accepted = for (mine) |m| {
            if (m.accepted) break true;
        } else false;
        const kind: []const u8 = if (mismatch) "mismatch" else try std.fmt.allocPrint(gpa, "{s}{s}differ{s}", .{
            if (accepted) "ours accepts, " else "ours rejects, ",
            differs.items,
            if (from_corpus) " (corpus)" else "",
        });
        if (mismatch) s.mismatches += 1;
        const gop = try s.split.getOrPut(gpa, kind);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (gop.value_ptr.* <= saved_per_kind) {
            const id = std.hash.Wyhash.hash(0, input) % 1_000_000;
            // Saved as mismatch-ID or split-K-ID, K the kind's line in the
            // summary, from 1.
            const path = if (mismatch)
                try std.fmt.allocPrint(gpa, "{s}/mismatch-{d}.input", .{ dir, id })
            else
                try std.fmt.allocPrint(gpa, "{s}/split-{d}-{d}.input", .{ dir, s.split.getIndex(kind).?, id });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = input });
            if (mismatch) {
                std.debug.print("MISMATCH {s}: ours differs from {s}: {s}\n", .{ F.name, differs.items, path });
            }
        }
    }

    fn print(s: *Stats, comptime F: type, corpus: usize, n: usize) void {
        std.debug.print("{s}: {d} corpus files and {d} fuzzed inputs, {d} comparisons against", .{
            F.name, corpus, n, s.comparisons,
        });
        for (F.oracles) |op| std.debug.print(" {s}", .{op});
        std.debug.print("\n", .{});
        std.debug.print("  {d} agree with every oracle, {d} mismatches\n", .{ s.agreed, s.mismatches });
        for (s.split.keys(), s.split.values(), 0..) |kind, count, k| {
            if (std.mem.eql(u8, kind, "mismatch")) continue;
            std.debug.print("  split-{d}: oracles disagree, {s}: {d}\n", .{ k, kind, count });
        }
    }
};

fn loadCorpus(comptime T: type) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (T.corpus) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            for (T.extensions) |ext| {
                if (std.mem.endsWith(u8, entry.basename, ext)) break;
            } else continue;
            try list.append(gpa, try dir.readFileAlloc(io, entry.path, gpa, .limited(64 << 20)));
        }
    }
    return list.items;
}
