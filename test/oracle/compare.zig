//! `just oracle`: holds each decoder against its reference libraries on the
//! format's corpus files and on N fuzzed inputs (mutated corpus files and
//! generated ones, from the format's fuzz target), in each pixel format the
//! format's table names.
//!
//! For every input and pixel format, this package and every oracle either
//! accept it, with pixels, or reject it. Two answers agree when both reject,
//! or both accept with the same size and the same pixels (the same length
//! and XXH64, so the oracle need not send the pixels), and two deciders
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
//! A module with `encode` compares an encoder instead: from each input, in
//! each pixel format, its `Decoder` (ours) reads the source image, which our
//! encoder and each oracle's encode op turn into files, and two answers
//! agree when the files are the same bytes (test/oracle/qoi_encode.zig).
//!
//!   oracle-compare [N] [SEED] [FORMAT...]   (FORMATs: formats.zig's names; default all)

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
/// The most bytes one batch may hold, its inputs and an encoder's sources,
/// so large inputs make batches shorter rather than exhausting memory. Each
/// worker holds a batch, and its oracle a copy.
const batch_bytes = 64 << 20;
/// The most batches compared at once, one per core.
const max_workers = 8;
const saved_per_kind = 5;
/// Fuzzed inputs mutate a corpus file: one of at most this many pixels (or
/// whose header our decoder rejects), but one time in `big_base_odds` any
/// corpus file. Every corpus file is still compared whole; a mutation of a
/// large one mostly lands in pixel data and decodes megapixels for each
/// format and decider, which was most of the oracle pass's time, while
/// header mutations of small files reach large sizes too
/// (docs/slop/results/oracle-pass-20261102.md).
const max_base_pixels = 1 << 18;
const big_base_odds = 16;
/// Corpus files this large or larger are left out.
const max_corpus_len = 64 << 20;

var io: std.Io = undefined;
const gpa = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip();
    const n = if (it.next()) |a| try std.fmt.parseInt(usize, a, 10) else 100_000;
    const seed = if (it.next()) |a| try std.fmt.parseInt(u64, a, 10) else 1;
    var only: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| try only.append(gpa, a);
    const oracle: Oracle = .{ .io = io, .gpa = gpa, .path = "zig-out/bin/image-oracle" };
    var mismatches: usize = 0;
    var ran: usize = 0;
    inline for (@typeInfo(formats).@"struct".decls) |d| {
        const format = @field(formats, d.name);
        const wanted = for (only.items) |o| {
            if (std.mem.eql(u8, o, format.name)) break true;
        } else only.items.len == 0;
        if (wanted) {
            mismatches += try compareFormat(format, oracle, n, seed);
            ran += 1;
        }
    }
    if (ran == 0) {
        std.debug.print("oracle-compare: no format named {s}\n", .{only.items[0]});
        std.process.exit(2);
    }
    if (mismatches != 0) std.process.exit(1);
}

const Answer = struct {
    accepted: bool,
    width: u32 = 0,
    height: u32 = 0,
    /// The pixels' length and XXH64, or an encoder's file's.
    len: usize = 0,
    hash: u64 = 0,

    fn of(width: u32, height: u32, bytes: []const u8) Answer {
        const hash = std.hash.XxHash64.hash(0, bytes);
        return .{ .accepted = true, .width = width, .height = height, .len = bytes.len, .hash = hash };
    }

    fn agrees(a: Answer, b: Answer) bool {
        if (a.accepted != b.accepted) return false;
        if (!a.accepted) return true;
        return a.width == b.width and a.height == b.height and a.len == b.len and a.hash == b.hash;
    }
};

/// The image our decoder `D` reads from `input` as `format`, tightly
/// packed, its pixels from `pixel_gpa`; null when it rejects the input.
/// The work memory is the decoder's worst case, mostly untouched, so it is
/// allocated for this input alone and given back: kept in an arena, its
/// touched pages pile up across batches.
fn decode(comptime D: type, input: []const u8, format: PixelFormat, pixel_gpa: std.mem.Allocator) !?image.PixelBuffer {
    var r: std.Io.Reader = .fixed(input);
    var d = D.init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
    const config = d.decodeConfig() catch return null;
    const len = image.PixelBuffer.len(format, config.width, config.height).?;
    const pixels = try pixel_gpa.alloc(u8, len);
    errdefer pixel_gpa.free(pixels);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    const dst = try image.PixelBuffer.init(pixels, format, config.width, config.height);
    _ = (d.decodeFrame(dst, work) catch null) orelse {
        pixel_gpa.free(pixels);
        return null;
    };
    return dst;
}

/// Our decoder's answer. Its pixels are hashed and freed, so a batch holds
/// one image at a time.
fn ours(comptime D: type, input: []const u8, format: PixelFormat) !Answer {
    const dst = try decode(D, input, format, gpa) orelse return .{ .accepted = false };
    defer gpa.free(dst.pixels);
    return .of(dst.width, dst.height, dst.pixels);
}

/// The image our decoder `D` reads from `input` as `format`, tightly
/// packed, to hand an encoder, in `arena` for the batch; null when it reads
/// none, or an empty one.
fn source(comptime D: type, input: []const u8, format: PixelFormat, arena: std.mem.Allocator) !?image.PixelBuffer {
    const src = try decode(D, input, format, arena) orelse return null;
    return if (src.width == 0 or src.height == 0) null else src;
}

/// Our encoder's file for `src`: F.encode's, or a rejection when it fails.
fn oursEncode(comptime F: type, src: image.PixelBuffer, arena: std.mem.Allocator) !Answer {
    var w: std.Io.Writer.Allocating = .init(arena);
    F.encode(&w.writer, src, arena) catch return .{ .accepted = false };
    return .of(src.width, src.height, w.written());
}

/// Whether `op`'s answer for `input` in `format` counts: always, unless the
/// format module's `comparable` says not.
fn comparable(comptime F: type, op: []const u8, format: PixelFormat, input: []const u8) bool {
    return !@hasDecl(F, "comparable") or F.comparable(op, format, input);
}

/// The bytes `input` holds in a batch: itself, and for an encoder the
/// sources our decoder reads from it, their size from its header.
fn batchBytes(comptime F: type, input: []const u8) usize {
    if (!@hasDecl(F, "encode")) return input.len;
    var r: std.Io.Reader = .fixed(input);
    var d = F.Decoder.init(&r, .{ .limits = .{ .max_pixels = max_pixels } });
    const config = d.decodeConfig() catch return input.len;
    var per_pixel: usize = 0;
    for (F.formats) |format| per_pixel += format.bytesPerPixel();
    return input.len + @as(usize, config.width) * config.height * per_pixel;
}

fn compareFormat(comptime F: type, oracle: Oracle, n: usize, seed: u64) !usize {
    const start: std.Io.Timestamp = .now(io, .awake);
    const T = F.fuzz;
    // The corpus stays on disk: each file is read into the batch that
    // compares or mutates it, and only the small mutation bases are held.
    const corpus = try fuzz.harness.listCorpus(gpa, io, &T.corpus, &T.extensions, max_corpus_len);
    defer corpus.deinit(gpa);
    const dir = "zig-out/oracle/" ++ F.name;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var bases: std.ArrayList([]const u8) = .empty;
    defer {
        for (bases.items) |b| gpa.free(b);
        bases.deinit(gpa);
    }
    for (corpus.paths) |path| {
        const file = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_corpus_len));
        var rd: std.Io.Reader = .fixed(file);
        var d = F.Decoder.init(&rd, .{ .limits = .{ .max_pixels = max_pixels } });
        const ok = if (d.decodeConfig()) |c| @as(u64, c.width) * c.height <= max_base_pixels else |_| true;
        if (ok) try bases.append(gpa, file) else gpa.free(file);
    }
    var run: Run(F) = .{
        .oracle = oracle,
        .corpus = corpus.paths,
        .bases = bases.items,
        .total = corpus.paths.len + n,
        .prng = .init(seed),
    };
    // Batches run on every core; each worker takes the next batch, its
    // inputs made in order under the lock, so the inputs are the same
    // however many workers there are.
    var threads: [max_workers]std.Thread = undefined;
    const workers = std.math.clamp(std.Thread.getCpuCount() catch 1, 1, max_workers);
    for (threads[0..workers]) |*t| t.* = try std.Thread.spawn(.{}, Run(F).work, .{&run});
    for (threads[0..workers]) |t| t.join();
    if (run.err) |e| return e;
    run.stats.print(F, corpus, n, start.untilNow(io, .awake));
    return run.stats.mismatches;
}

fn Run(comptime F: type) type {
    return struct {
        const Self = @This();
        const T = F.fuzz;
        const dir = "zig-out/oracle/" ++ F.name;
        /// An encoder's comparison rather than a decoder's.
        const encodes = @hasDecl(F, "encode");

        oracle: Oracle,
        /// The corpus files' paths.
        corpus: []const []const u8,
        /// The corpus files to mutate, most of the time (`max_base_pixels`).
        bases: []const []const u8,
        total: usize,
        /// The rest is under `mutex`.
        mutex: std.Io.Mutex = .init,
        prng: std.Random.DefaultPrng,
        done: usize = 0,
        stats: Stats = .{},
        err: ?anyerror = null,

        fn work(r: *Self) void {
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            while (true) {
                _ = arena_state.reset(.retain_capacity);
                const more = r.batch(arena_state.allocator()) catch |e| {
                    r.mutex.lockUncancelable(io);
                    defer r.mutex.unlock(io);
                    if (r.err == null) r.err = e;
                    return;
                };
                if (!more) return;
            }
        }

        /// Takes the next batch and compares it, or returns false when
        /// there is none.
        fn batch(r: *Self, arena: std.mem.Allocator) !bool {
            r.mutex.lockUncancelable(io);
            const first = r.done;
            const inputs = r.take(arena) catch |e| {
                r.mutex.unlock(io);
                return e;
            };
            r.mutex.unlock(io);
            if (inputs.len == 0) return false;

            // An encoder's comparison encodes, from each input in each
            // format, the image our decoder reads from it: its source, or
            // null when there is none.
            const sources = try arena.alloc([F.formats.len]?image.PixelBuffer, if (encodes) inputs.len else 0);
            // A request whose input is the previous one's sends no copy
            // (Oracle.run), so a decoder's requests go op by op, each op's
            // adapted input made once: an input goes to the oracle once per
            // op that rewrites it, not once per pixel format.
            var requests: std.ArrayList(Oracle.Request) = .empty;
            for (inputs, 0..) |input, i| {
                if (!encodes) {
                    for (F.oracles) |op| {
                        const adapted = try F.adapt(op, input, arena);
                        for (F.formats) |format| try requests.append(arena, .{
                            .op = op,
                            .format = format,
                            .max_pixels = max_pixels,
                            .input = adapted,
                        });
                    }
                    continue;
                }
                for (F.formats, 0..) |format, f| {
                    sources[i][f] = try source(F.Decoder, input, format, arena);
                    const src = sources[i][f] orelse continue;
                    for (F.oracles) |op| try requests.append(arena, .{
                        .op = op,
                        .format = format,
                        .max_pixels = max_pixels,
                        .input = src.pixels,
                        .size = .{ src.width, src.height },
                    });
                }
            }
            const responses = try r.oracle.run(requests.items);
            defer r.oracle.free(responses);
            const mine = try arena.alloc([F.formats.len]Answer, inputs.len);
            const theirs = try arena.alloc([F.formats.len][F.oracles.len]?Answer, inputs.len);
            var k: usize = 0;
            for (inputs, mine, theirs, 0..) |input, *m_row, *t_rows, i| {
                const first_request = k;
                if (!encodes) k += F.oracles.len * F.formats.len;
                for (F.formats, m_row, t_rows, 0..) |format, *m, *row, f| {
                    if (encodes) {
                        const src = sources[i][f] orelse {
                            m.* = .{ .accepted = false };
                            row.* = @splat(null);
                            continue;
                        };
                        m.* = try oursEncode(F, src, arena);
                    } else m.* = try ours(F.Decoder, input, format);
                    for (row, F.oracles, 0..) |*t, op, o| {
                        const resp = if (encodes) responses[k] else responses[first_request + o * F.formats.len + f];
                        if (encodes) k += 1;
                        t.* = if (!comparable(F, op, format, input)) null else switch (resp.status) {
                            .ok => .{
                                .accepted = true,
                                .width = resp.width,
                                .height = resp.height,
                                .len = resp.len,
                                .hash = resp.hash,
                            },
                            .rejected, .too_large => .{ .accepted = false },
                            else => null,
                        };
                    }
                }
            }
            r.mutex.lockUncancelable(io);
            defer r.mutex.unlock(io);
            for (inputs, mine, theirs, first..) |input, *m, *t, i| {
                try r.stats.add(F, dir, input, i < r.corpus.len, m, t);
            }
            return true;
        }

        /// The next batch of inputs: corpus files first, then fuzzed ones,
        /// until the batch would hold `batch_bytes`. Under the
        /// lock.
        fn take(r: *Self, arena: std.mem.Allocator) ![]const []const u8 {
            const random = r.prng.random();
            const room = @min(batch_inputs, r.total - r.done);
            const inputs = try arena.alloc([]const u8, room);
            var count: usize = 0;
            var bytes: usize = 0;
            for (inputs, r.done..) |*input, i| {
                if (count > 0 and bytes >= batch_bytes) break;
                count += 1;
                defer bytes += batchBytes(F, input.*);
                if (i < r.corpus.len) {
                    input.* = try readFile(r.corpus[i], 0, arena);
                    continue;
                }
                const buf = try arena.alloc(u8, 1 << 16);
                var len: usize = 0;
                if (r.corpus.len > 0 and random.boolean()) {
                    const any = r.bases.len == 0 or random.uintLessThan(u8, big_base_odds) == 0;
                    const pool = if (any) r.corpus else r.bases;
                    const pick = pool[random.uintLessThan(usize, pool.len)];
                    // Room for `mutate` to grow it.
                    const extra = 4096;
                    var big: []u8 = undefined;
                    if (any) big = try readFile(pick, extra, arena) else {
                        big = try arena.alloc(u8, pick.len + extra);
                        @memcpy(big[0..pick.len], pick);
                    }
                    len = fuzz.harness.mutate(random, big, big.len - extra);
                    input.* = big[0..len];
                } else {
                    const g = T.generate(random, buf);
                    len = g.len;
                    if (random.uintLessThan(u8, 4) == 0) len = fuzz.harness.mutate(random, buf, len);
                    input.* = buf[0..len];
                }
            }
            r.done += count;
            return inputs[0..count];
        }
    };
}

/// The file at `path` in `arena`, followed by `extra` bytes of room.
fn readFile(path: []const u8, extra: usize, arena: std.mem.Allocator) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    if (len >= max_corpus_len) return error.CorpusChanged;
    const buf = try arena.alloc(u8, @intCast(len + extra));
    if (try file.readPositionalAll(io, buf[0..@intCast(len)], 0) != len) return error.CorpusChanged;
    return buf;
}

/// Orders a map's entries by their keys.
const ByKey = struct {
    keys: []const []const u8,
    pub fn lessThan(c: ByKey, a: usize, b: usize) bool {
        return std.mem.lessThan(u8, c.keys[a], c.keys[b]);
    }
};

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

    fn print(s: *Stats, comptime F: type, corpus: fuzz.harness.CorpusPaths, n: usize, took: std.Io.Duration) void {
        std.debug.print("{s}: {d} corpus files", .{ F.name, corpus.paths.len });
        if (corpus.too_large > 0) std.debug.print(" ({d} of 64 MiB or more left out)", .{corpus.too_large});
        std.debug.print(" and {d} fuzzed inputs, {d} comparisons against", .{ n, s.comparisons });
        for (F.oracles) |op| std.debug.print(" {s}", .{op});
        std.debug.print("\n", .{});
        const seconds = @as(f64, @floatFromInt(took.toMilliseconds())) / 1000;
        std.debug.print("  {d} agree with every oracle, {d} mismatches, in {d:.1} s\n", .{
            s.agreed, s.mismatches, seconds,
        });
        // In key order, not the order the workers' batches finished in.
        s.split.sort(ByKey{ .keys = s.split.keys() });
        for (s.split.keys(), s.split.values(), 0..) |kind, count, k| {
            if (std.mem.eql(u8, kind, "mismatch")) continue;
            std.debug.print("  split-{d}: oracles disagree, {s}: {d}\n", .{ k, kind, count });
        }
    }
};
