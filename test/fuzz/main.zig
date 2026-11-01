//! The fuzz driver behind `just fuzz`: each target in targets.zig runs for
//! its share of the time on mutated corpus files, generated inputs, and
//! random bytes, checked by the target's `check` (harness.zig).
//!
//! Inputs run in a forked child that copies each input to memory shared
//! with the parent before running it, so a crash, a safety panic, a hang,
//! or a property violation is caught with the input that caused it. The
//! child runs under an address-space limit, so unbounded memory is a crash
//! too. A finding is written to `<out>/<target>/` as the input, a
//! minimized input, and a description, and the driver exits 1.
//!
//! `--seconds N` is the whole run, split across the targets; `--seconds-each
//! N` gives every target N seconds, however many there are.
//!
//!   fuzz run [TARGET...] [--seconds N | --seconds-each N] [--seed N] [--out DIR]
//!   fuzz repro TARGET FILE [CHOICE]
//!   fuzz gen TARGET SEED            (a generated input, on stdout)

const std = @import("std");
const targets = @import("targets.zig");
const linux = std.os.linux;

const max_input = 1 << 20;
/// A child whose heartbeat stops this long is hung.
const hang_ms = 10_000;
/// The child's address-space limit.
const memory_limit = 4 << 30;
/// A target stops after this many findings: they are usually one bug.
const max_findings = 10;

const usage =
    \\usage: fuzz run [TARGET...] [--seconds N | --seconds-each N] [--seed N] [--out DIR]
    \\       fuzz repro TARGET FILE [CHOICE]
    \\       fuzz gen TARGET SEED
    \\
;

const Shared = struct {
    heartbeat: u64,
    inputs: u64,
    choice: u64,
    len: u32,
    data: [max_input]u8,
    /// The property a child found violated, as an error name.
    finding: [64]u8,
};

const Kind = enum { crash, hang, property };

var io: std.Io = undefined;
const gpa = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var args: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip();
    var seconds: u64 = 60;
    var each: ?u64 = null;
    var seed: ?u64 = null;
    var out: []const u8 = "zig-out/fuzz";
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--seconds")) {
            seconds = try std.fmt.parseInt(u64, it.next() orelse return fail(), 10);
        } else if (std.mem.eql(u8, a, "--seconds-each")) {
            each = try std.fmt.parseInt(u64, it.next() orelse return fail(), 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            seed = try std.fmt.parseInt(u64, it.next() orelse return fail(), 10);
        } else if (std.mem.eql(u8, a, "--out")) {
            out = try gpa.dupe(u8, it.next() orelse return fail());
        } else try args.append(gpa, try gpa.dupe(u8, a));
    }
    if (args.items.len == 0) return fail();
    const cmd = args.items[0];
    const rest = args.items[1..];
    if (std.mem.eql(u8, cmd, "run")) {
        var names = rest;
        if (names.len == 0) {
            var all: std.ArrayList([]const u8) = .empty;
            inline for (targets.all) |T| try all.append(gpa, T.name);
            names = all.items;
        }
        const first_seed = seed orelse @as(u64, @intCast(nowMs())) *% 0x9e3779b97f4a7c15;
        var findings: u32 = 0;
        const share = each orelse @max(1, seconds / names.len);
        for (names) |n| findings += try dispatchRun(n, share, first_seed, out);
        if (findings != 0) std.process.exit(1);
        return;
    }
    if (std.mem.eql(u8, cmd, "repro")) {
        if (rest.len < 2) return fail();
        const data = try std.Io.Dir.cwd().readFileAlloc(io, rest[1], gpa, .limited(max_input));
        const choice = if (rest.len > 2) try std.fmt.parseInt(u64, rest[2], 10) else 0;
        inline for (targets.all) |T| {
            if (std.mem.eql(u8, rest[0], T.name)) {
                T.check(data, choice) catch |e| {
                    std.debug.print("{s}: {t}\n", .{ T.name, e });
                    std.process.exit(1);
                };
                std.debug.print("{s}: ok\n", .{T.name});
                return;
            }
        }
        return fail();
    }
    if (std.mem.eql(u8, cmd, "gen")) {
        if (rest.len < 2) return fail();
        var prng: std.Random.DefaultPrng = .init(try std.fmt.parseInt(u64, rest[1], 10));
        const buf = try gpa.alloc(u8, max_input);
        inline for (targets.all) |T| {
            if (std.mem.eql(u8, rest[0], T.name)) {
                try std.Io.File.stdout().writeStreamingAll(io, T.generate(prng.random(), buf[0 .. 1 << 16]));
                return;
            }
        }
        return fail();
    }
    return fail();
}

fn fail() error{Usage} {
    std.debug.print("{s}", .{usage});
    return error.Usage;
}

fn dispatchRun(target_name: []const u8, seconds: u64, seed: u64, out: []const u8) !u32 {
    inline for (targets.all) |T| {
        if (std.mem.eql(u8, target_name, T.name)) return Runner(T).run(seconds, seed, out);
    }
    std.debug.print("fuzz: no target {s}\n", .{target_name});
    return error.Usage;
}

fn Runner(comptime T: type) type {
    return struct {
        var shared: *Shared = undefined;
        var corpus: []const []const u8 = &.{};
        var minimized: std.StringHashMapUnmanaged(void) = .empty;

        fn run(seconds: u64, seed: u64, out: []const u8) !u32 {
            shared = try mapShared();
            shared.heartbeat = 0;
            shared.inputs = 0;
            corpus = try loadCorpus();
            const dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ out, T.name });
            try std.Io.Dir.cwd().createDirPath(io, dir);
            const log_path = try std.fmt.allocPrintSentinel(gpa, "{s}/child.log", .{dir}, 0);
            const start = nowMs();
            const deadline = start + @as(i64, @intCast(seconds)) * 1000;
            std.debug.print("fuzz {s}: seed {d}, {d}s, {d} corpus files\n", .{ T.name, seed, seconds, corpus.len });
            var findings: u32 = 0;
            var restarts: u32 = 0;
            var done: u64 = 0;
            while (nowMs() < deadline) {
                // Each child starts from its own seed, so a restart after a
                // finding goes on to new inputs.
                const pid = try spawn(log_path, null, seed +% restarts, deadline);
                const status = wait(pid);
                done += shared.inputs;
                const kind = kindOf(status) orelse break;
                restarts += 1;
                findings += 1;
                const input = try gpa.dupe(u8, shared.data[0..shared.len]);
                try record(dir, log_path, kind, input, shared.choice);
                if (findings == max_findings) {
                    std.debug.print("fuzz {s}: stopping after {d} findings\n", .{ T.name, findings });
                    break;
                }
            }
            const seconds_taken = @divTrunc(nowMs() - start, 1000);
            std.debug.print("fuzz {s}: {d} inputs in {d}s, {d} findings\n", .{ T.name, done, seconds_taken, findings });
            return findings;
        }

        fn loadCorpus() ![]const []const u8 {
            var list: std.ArrayList([]const u8) = .empty;
            for (T.seeds) |s| try list.append(gpa, s);
            const loaded = try targets.harness.loadCorpus(gpa, io, &T.corpus, &T.extensions, max_input);
            try list.appendSlice(gpa, loaded.files);
            return list.items;
        }

        /// Forks a child that runs inputs until `deadline`, or only
        /// `single` when it is set, with stderr to `log_path`.
        fn spawn(log_path: [:0]const u8, single: ?[]const u8, seed: u64, deadline: i64) !linux.pid_t {
            const rc = linux.fork();
            if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
            if (rc != 0) return @intCast(rc);
            const fd = linux.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
            if (linux.errno(fd) == .SUCCESS) _ = linux.dup2(@intCast(fd), 2);
            const limit: linux.rlimit = .{ .cur = memory_limit, .max = memory_limit };
            _ = linux.setrlimit(.AS, &limit);
            if (single) |input| {
                @atomicStore(u64, &shared.heartbeat, shared.heartbeat + 1, .seq_cst);
                runOne(input, shared.choice);
                linux.exit_group(0);
            }
            childLoop(seed, deadline);
        }

        fn runOne(input: []const u8, choice: u64) void {
            T.check(input, choice) catch |e| {
                const msg = std.fmt.bufPrint(&shared.finding, "{t}", .{e}) catch "?";
                shared.finding[msg.len] = 0;
                std.debug.print("property: {t}\n", .{e});
                linux.exit_group(3);
            };
        }

        fn childLoop(seed: u64, deadline: i64) noreturn {
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            var gen: [1 << 16]u8 = undefined;
            var n: u64 = 0;
            while (true) : (n += 1) {
                if (n % 64 == 0 and nowMs() >= deadline) linux.exit_group(0);
                const buf = &shared.data;
                var len: usize = 0;
                switch (random.uintLessThan(u8, 10)) {
                    0...3 => if (corpus.len > 0) {
                        const base = corpus[random.uintLessThan(usize, corpus.len)];
                        len = @min(base.len, buf.len);
                        @memcpy(buf[0..len], base[0..len]);
                        len = targets.harness.mutate(random, buf, len);
                    },
                    4...6 => {
                        const g = T.generate(random, &gen);
                        len = g.len;
                        @memcpy(buf[0..len], g);
                    },
                    7, 8 => {
                        const g = T.generate(random, &gen);
                        len = g.len;
                        @memcpy(buf[0..len], g);
                        len = targets.harness.mutate(random, buf, len);
                    },
                    else => {
                        len = random.uintAtMost(usize, 256);
                        random.bytes(buf[0..len]);
                    },
                }
                shared.len = @intCast(len);
                shared.choice = random.int(u64);
                @atomicStore(u64, &shared.heartbeat, n + 1, .seq_cst);
                runOne(buf[0..len], shared.choice);
                shared.inputs = n + 1;
            }
        }

        const Status = union(enum) { exited: u32, signaled: u32, hung };

        fn wait(pid: linux.pid_t) Status {
            var last = @atomicLoad(u64, &shared.heartbeat, .seq_cst);
            var since = nowMs();
            while (true) {
                var status: u32 = 0;
                const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
                if (rc == pid) {
                    if (linux.W.IFEXITED(status)) return .{ .exited = linux.W.EXITSTATUS(status) };
                    return .{ .signaled = @intFromEnum(linux.W.TERMSIG(status)) };
                }
                const beat = @atomicLoad(u64, &shared.heartbeat, .seq_cst);
                if (beat != last) {
                    last = beat;
                    since = nowMs();
                } else if (nowMs() - since > hang_ms) {
                    _ = linux.kill(pid, .KILL);
                    _ = linux.waitpid(pid, &status, 0);
                    return .hung;
                }
                sleepMs(2);
            }
        }

        fn kindOf(status: Status) ?Kind {
            return switch (status) {
                .exited => |c| if (c == 0) null else if (c == 3) .property else .crash,
                .signaled => .crash,
                .hung => .hang,
            };
        }

        /// Writes the input, its description, and a minimized input.
        fn record(dir: []const u8, log_path: [:0]const u8, kind: Kind, input: []const u8, choice: u64) !void {
            const log = readLog(log_path);
            const sig = try gpa.dupe(u8, signature(log));
            const hash = std.hash.Wyhash.hash(0, input) % 1_000_000;
            const base = try std.fmt.allocPrint(gpa, "{s}/{t}-{d}", .{ dir, kind, hash });
            std.debug.print("FINDING: {t} ({s}), {d} bytes, choice {d}: {s}.input\n", .{
                kind, sig, input.len, choice, base,
            });
            try writeFile(try std.fmt.allocPrint(gpa, "{s}.input", .{base}), input);
            try writeFile(try std.fmt.allocPrint(gpa, "{s}.txt", .{base}), try std.fmt.allocPrint(
                gpa,
                "target: {s}\nkind: {t}\nchoice: {d}\nsignature: {s}\n" ++
                    "repro: zig-out/bin/fuzz repro {s} {s}.input {d}\n\n{s}",
                .{ T.name, kind, choice, sig, T.name, base, choice, log },
            ));
            // One minimized input per kind and signature is enough.
            const key = try std.fmt.allocPrint(gpa, "{t}|{s}", .{ kind, sig });
            if (minimized.contains(key)) return;
            try minimized.put(gpa, key, {});
            const min = try minimize(dir, kind, sig, input, choice);
            try writeFile(try std.fmt.allocPrint(gpa, "{s}.min", .{base}), min);
            std.debug.print("  minimized to {d} bytes: {s}.min\n", .{ min.len, base });
        }

        /// Removes runs of bytes, halving the run length down to one, while
        /// the input still fails the same way. Each try runs in a fresh
        /// child.
        fn minimize(dir: []const u8, kind: Kind, sig: []const u8, input: []const u8, choice: u64) ![]const u8 {
            const log_path = try std.fmt.allocPrintSentinel(gpa, "{s}/minimize.log", .{dir}, 0);
            var best = input;
            const stop = nowMs() + 60_000;
            var chunk: usize = @max(1, best.len / 2);
            while (nowMs() < stop) {
                var at: usize = 0;
                while (at < best.len and nowMs() < stop) {
                    const end = @min(best.len, at + chunk);
                    const candidate = try std.mem.concat(gpa, u8, &.{ best[0..at], best[end..] });
                    if (try still(log_path, candidate, choice, kind, sig)) best = candidate else at = end;
                }
                if (chunk == 1) break;
                chunk /= 2;
            }
            return best;
        }

        fn still(log_path: [:0]const u8, input: []const u8, choice: u64, kind: Kind, sig: []const u8) !bool {
            shared.choice = choice;
            shared.len = @intCast(input.len);
            const pid = try spawn(log_path, input, 0, 0);
            const got = kindOf(wait(pid)) orelse return false;
            return got == kind and (kind == .hang or std.mem.eql(u8, signature(readLog(log_path)), sig));
        }
    };
}

fn mapShared() !*Shared {
    const size = std.mem.alignForward(usize, @sizeOf(Shared), std.heap.page_size_min);
    const rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return error.MmapFailed;
    return @ptrFromInt(rc);
}

/// The panic message or the property, from a child's log: what a minimized
/// input must still produce.
fn signature(log: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "panic: ")) |i| return line[i..];
        if (std.mem.startsWith(u8, line, "property: ")) return line;
        if (std.mem.startsWith(u8, line, "Segmentation fault")) return line;
    }
    return "";
}

fn readLog(path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16)) catch "";
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u32) void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}
