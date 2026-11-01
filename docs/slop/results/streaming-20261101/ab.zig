//! Decision 1's A/B (docs/slop/results/streaming-20261101.md): the
//! shipped QOI decoder, which pulls from a `std.Io.Reader`, against a
//! Wuffs-style resumable push decoder written here only for this
//! measurement. Both decode the same chunks with the same row loop, so the
//! difference is the I/O model: a reader's buffer and vtable against a
//! slice the caller hands over, with the decoder's own carry buffer for a
//! chunk split across calls.
//!
//!   ab verify FILE...            every arm's pixels equal, also with random feeds
//!   ab bench ROUNDS MS FILE...   rows timed back to back, rotating order
//!
//! `bench` writes Go benchmark lines to ab-<arm>.txt in the working
//! directory, one per file per round, for benchstat. Round 0 sizes each
//! row's loop to MS milliseconds and is not written.

const std = @import("std");
const image = @import("image");
const Io = std.Io;

const chunk_len = 4096;

const Arm = enum {
    /// The shipped decoder over `Reader.fixed`: the whole file in memory.
    pull_fixed,
    /// The shipped decoder over a reader whose vtable hands over at most
    /// 4 KiB per call into its 4 KiB buffer, as a file reader does.
    pull_4k,
    /// The push decoder handed the whole file in one call.
    push_whole,
    /// The push decoder handed 4 KiB per call.
    push_4k,
};

var io: Io = undefined;
const gpa = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var args: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip();
    while (it.next()) |a| try args.append(gpa, a);
    const a = args.items;
    if (a.len >= 2 and std.mem.eql(u8, a[0], "verify")) return verify(a[1..]);
    if (a.len >= 4 and std.mem.eql(u8, a[0], "bench")) {
        return bench(try std.fmt.parseInt(u32, a[1], 10), try std.fmt.parseInt(u64, a[2], 10), a[3..]);
    }
    std.debug.print("usage: ab verify FILE... | ab bench ROUNDS MS FILE...\n", .{});
    std.process.exit(2);
}

const Input = struct {
    name: []const u8,
    data: []const u8,
    width: u32,
    height: u32,
    native: image.PixelFormat,
    out: []u8,
};

fn load(path: []const u8) !Input {
    const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
    var r: Io.Reader = .fixed(data);
    var d: image.qoi.Decoder = .init(&r, .{});
    const c = try d.decodeConfig();
    const len = image.PixelBuffer.len(c.native, c.width, c.height).?;
    const out = try gpa.alloc(u8, len);
    @memset(out, 0x55);
    return .{ .name = std.fs.path.basename(path), .data = data, .width = c.width, .height = c.height, .native = c.native, .out = out };
}

fn run(arm: Arm, in: *const Input) !void {
    switch (arm) {
        .pull_fixed => {
            var r: Io.Reader = .fixed(in.data);
            try pull(&r, in);
        },
        .pull_4k => {
            var buf: [chunk_len]u8 = undefined;
            var c: Chunked = .{ .data = in.data, .reader = .{ .vtable = &.{ .stream = Chunked.stream }, .buffer = &buf, .seek = 0, .end = 0 } };
            try pull(&c.reader, in);
        },
        .push_whole => try push(in, in.data.len),
        .push_4k => try push(in, chunk_len),
    }
}

fn pull(r: *Io.Reader, in: *const Input) !void {
    var d: image.qoi.Decoder = .init(r, .{});
    const c = try d.decodeConfig();
    const dst = try image.PixelBuffer.init(in.out, c.native, c.width, c.height);
    _ = try d.decodeFrame(dst, &.{});
}

fn push(in: *const Input, step: usize) !void {
    var p: Push = .{};
    var at: usize = 0;
    // The header, then the pixels, each fed `step` bytes at a time, as a
    // caller reading a socket would.
    while (true) {
        const end = @min(at + step, in.data.len);
        const n = try p.decodeConfig(in.data[at..end], end == in.data.len);
        at += n;
        if (p.phase != .header) break;
    }
    const stride = @as(usize, p.width) * p.bpp();
    while (true) {
        const end = @min(at + step, in.data.len);
        const status = try p.decodeFrame(in.out, stride, in.data[at..end], end == in.data.len);
        at = end;
        if (status == .done) break;
    }
}

/// A reader that hands over at most 4 KiB per call.
const Chunked = struct {
    data: []const u8,
    reader: Io.Reader,
    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const c: *Chunked = @fieldParentPtr("reader", r);
        if (c.data.len == 0) return error.EndOfStream;
        const n = try w.write(c.data[0..limit.minInt(@min(chunk_len, c.data.len))]);
        c.data = c.data[n..];
        return n;
    }
};

/// A resumable push QOI decoder in the style of Wuffs: each call takes the
/// bytes the caller has, consumes all of them (keeping a chunk split
/// across calls in `carry`), and says whether it needs more input. Same
/// format rules as the shipped decoder: every pixel indexed, strict end
/// marker, no run past the last pixel.
const Push = struct {
    phase: enum { header, pixels, footer, done } = .header,
    header: [14]u8 = undefined,
    have: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,
    channels: u8 = 0,
    px: [4]u8 = .{ 0, 0, 0, 255 },
    index: [64][4]u8 = @splat(.{ 0, 0, 0, 0 }),
    run: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    carry: [4]u8 = undefined,
    carry_len: u8 = 0,

    const Status = enum { need_input, done };
    const Error = error{ BadSignature, BadHeader, Truncated, BadFooter, RunPastEnd };
    const Out = enum { rgba, rgb };

    fn bpp(p: *const Push) usize {
        return p.channels;
    }

    /// Consumes header bytes from `src`; returns how many.
    fn decodeConfig(p: *Push, src: []const u8, eof: bool) Error!usize {
        if (p.phase != .header) return 0;
        const n = @min(14 - p.have, src.len);
        @memcpy(p.header[p.have..][0..n], src[0..n]);
        p.have += @intCast(n);
        if (p.have < 14) return if (eof) error.Truncated else n;
        const h = &p.header;
        if (!std.mem.eql(u8, h[0..4], "qoif")) return error.BadSignature;
        p.width = std.mem.readInt(u32, h[4..8], .big);
        p.height = std.mem.readInt(u32, h[8..12], .big);
        p.channels = h[12];
        if (p.channels != 3 and p.channels != 4) return error.BadHeader;
        p.phase = .pixels;
        p.have = 0;
        if (p.width == 0 or p.height == 0) p.phase = .footer;
        return n;
    }

    /// Decodes from all of `src` into `dst`, rows `stride` bytes apart.
    fn decodeFrame(p: *Push, dst: []u8, stride: usize, src: []const u8, eof: bool) Error!Status {
        var rest = src;
        if (p.phase == .pixels) {
            // A chunk split across calls: the carried bytes and up to 5
            // more, decoded through a small buffer until the carry is gone.
            while (p.carry_len > 0) {
                var tmp: [9]u8 = undefined;
                const k = @min(5, rest.len);
                @memcpy(tmp[0..p.carry_len], p.carry[0..p.carry_len]);
                @memcpy(tmp[p.carry_len..][0..k], rest[0..k]);
                const len = p.carry_len + k;
                const c = p.feed(dst, stride, tmp[0..len]);
                if (c >= p.carry_len) {
                    rest = rest[c - p.carry_len ..];
                    p.carry_len = 0;
                } else if (c > 0) {
                    std.mem.copyForwards(u8, p.carry[0 .. p.carry_len - c], p.carry[c..p.carry_len]);
                    p.carry_len -= @intCast(c);
                } else if (p.phase == .pixels) {
                    // Not one chunk in all there is: keep it all.
                    if (len > p.carry.len) unreachable;
                    @memcpy(p.carry[0..len], tmp[0..len]);
                    p.carry_len = @intCast(len);
                    return if (eof) error.Truncated else .need_input;
                }
                if (p.phase != .pixels) break;
            }
            if (p.phase == .pixels) {
                const c = p.feed(dst, stride, rest);
                rest = rest[c..];
                if (p.phase == .pixels) {
                    if (rest.len > p.carry.len) unreachable;
                    @memcpy(p.carry[0..rest.len], rest);
                    p.carry_len = @intCast(rest.len);
                    return if (eof) error.Truncated else .need_input;
                }
            }
        }
        if (p.phase == .footer) {
            if (p.run != 0) return error.RunPastEnd;
            // Carried bytes left when the pixels ended are footer bytes.
            try p.footer(p.carry[0..p.carry_len]);
            p.carry_len = 0;
            try p.footer(rest);
            if (p.phase == .footer) return if (eof) error.Truncated else .need_input;
        }
        return .done;
    }

    fn footer(p: *Push, bytes: []const u8) Error!void {
        const end = "\x00\x00\x00\x00\x00\x00\x00\x01";
        const n = @min(8 - p.have, bytes.len);
        if (!std.mem.eql(u8, bytes[0..n], end[p.have..][0..n])) return error.BadFooter;
        p.have += @intCast(n);
        if (p.have == 8) p.phase = .done;
    }

    /// Decodes whole chunks from `buf` until the image is done or the next
    /// chunk is not all there; returns the bytes consumed.
    fn feed(p: *Push, dst: []u8, stride: usize, buf: []const u8) usize {
        return switch (p.channels) {
            4 => p.feedAs(dst, stride, buf, .rgba),
            else => p.feedAs(dst, stride, buf, .rgb),
        };
    }

    inline fn put(out: []u8, i: usize, px: [4]u8, comptime o: Out) void {
        switch (o) {
            .rgba => out[i * 4 ..][0..4].* = px,
            .rgb => out[i * 3 ..][0..3].* = px[0..3].*,
        }
    }

    fn chunkLen(b: u8) usize {
        return if (b == 0xff) 5 else if (b == 0xfe) 4 else if (b >> 6 == 2) 2 else 1;
    }

    fn feedAs(p: *Push, dst: []u8, stride: usize, buf: []const u8, comptime o: Out) usize {
        const b_pp = if (o == .rgb) 3 else 4;
        var q: usize = 0;
        var px = p.px;
        const index = &p.index;
        const n: usize = p.width;
        defer p.px = px;
        while (p.y < p.height) {
            const out = dst[p.y * stride ..][0 .. n * b_pp];
            var i: usize = p.x;
            const carried = @min(p.run, n - i);
            for (i..i + carried) |j| put(out, j, px, o);
            i += carried;
            p.run -= @intCast(carried);
            while (i < n) {
                // Every chunk is at most 5 bytes; with fewer left, check
                // this one's length.
                if (buf.len - q < 5 and (buf.len == q or buf.len - q < chunkLen(buf[q]))) {
                    p.x = @intCast(i);
                    return q;
                }
                const b = buf[q];
                if (b == 0xfe) {
                    px[0..3].* = buf[q + 1 ..][0..3].*;
                    q += 4;
                } else if (b == 0xff) {
                    px = buf[q + 1 ..][0..4].*;
                    q += 5;
                } else switch (@as(u2, @intCast(b >> 6))) {
                    0 => {
                        px = index[b];
                        q += 1;
                    },
                    1 => {
                        px[0] +%= (b >> 4 & 3) -% 2;
                        px[1] +%= (b >> 2 & 3) -% 2;
                        px[2] +%= (b & 3) -% 2;
                        q += 1;
                    },
                    2 => {
                        const dg = (b & 0x3f) -% 32;
                        const c = buf[q + 1];
                        px[0] +%= dg +% (c >> 4) -% 8;
                        px[1] +%= dg;
                        px[2] +%= dg +% (c & 0xf) -% 8;
                        q += 2;
                    },
                    3 => {
                        const count: usize = (b & 0x3f) + 1;
                        const m = @min(count, n - i);
                        index[hash(px)] = px;
                        for (i..i + m) |j| put(out, j, px, o);
                        i += m;
                        p.run = @intCast(count - m);
                        q += 1;
                        continue;
                    },
                }
                index[hash(px)] = px;
                put(out, i, px, o);
                i += 1;
            }
            p.x = 0;
            p.y += 1;
        }
        p.phase = .footer;
        return q;
    }

    inline fn hash(px: [4]u8) u6 {
        return @truncate(@as(u32, px[0]) * 3 + @as(u32, px[1]) * 5 + @as(u32, px[2]) * 7 + @as(u32, px[3]) * 11);
    }
};

fn verify(paths: []const []const u8) !void {
    var prng: std.Random.DefaultPrng = .init(1);
    for (paths) |path| {
        const in = try load(path);
        try run(.pull_fixed, &in);
        const want = try gpa.dupe(u8, in.out);
        for (std.enums.values(Arm)) |arm| {
            @memset(in.out, 0x55);
            try run(arm, &in);
            if (!std.mem.eql(u8, want, in.out)) return fail(arm, path);
        }
        // The push decoder fed random amounts, down to one byte.
        for (0..20) |_| {
            @memset(in.out, 0x55);
            try push(&in, 1 + prng.random().uintLessThan(usize, 16));
            if (!std.mem.eql(u8, want, in.out)) return fail(.push_4k, path);
        }
        // Every truncation the push decoder can see at a 7-byte step fails.
        var cut: usize = 0;
        while (cut < in.data.len) : (cut += @max(1, in.data.len / 50)) {
            const short: Input = .{ .name = in.name, .data = in.data[0..cut], .width = in.width, .height = in.height, .native = in.native, .out = in.out };
            if (push(&short, 7)) return fail(.push_4k, path) else |_| {}
        }
    }
    std.debug.print("verify: {d} files, every arm equal\n", .{paths.len});
}

fn fail(arm: Arm, path: []const u8) error{Mismatch} {
    std.debug.print("{s}: {s} differs\n", .{ path, @tagName(arm) });
    return error.Mismatch;
}

fn now() u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

fn bench(rounds: u32, ms: u64, paths: []const []const u8) !void {
    const arms = std.enums.values(Arm);
    var inputs: std.ArrayList(Input) = .empty;
    for (paths) |path| try inputs.append(gpa, try load(path));
    const iters = try gpa.alloc(u64, inputs.items.len * arms.len);
    var files: [arms.len]Io.File = undefined;
    var writers: [arms.len]Io.File.Writer = undefined;
    var bufs: [arms.len][4096]u8 = undefined;
    for (arms, 0..) |arm, k| {
        var name: [64]u8 = undefined;
        files[k] = try Io.Dir.cwd().createFile(io, try std.fmt.bufPrint(&name, "ab-{s}.txt", .{@tagName(arm)}), .{});
        writers[k] = files[k].writer(io, &bufs[k]);
    }
    for (0..rounds + 1) |round| {
        for (inputs.items, 0..) |*in, j| {
            for (0..arms.len) |i| {
                const k = (round + j + i) % arms.len;
                const slot = &iters[j * arms.len + k];
                var n: u64 = if (round == 0) 1 else slot.*;
                while (true) {
                    const t = now();
                    for (0..n) |_| try run(arms[k], in);
                    const ns = now() - t;
                    if (round == 0) {
                        // Grow as Go's testing.B does until a sample fills ms.
                        if (ns < ms * std.time.ns_per_ms and n < 1 << 30) {
                            n = @max(n + 1, @min(n * 100, n * ms * std.time.ns_per_ms / @max(ns, 1) * 6 / 5));
                            continue;
                        }
                        slot.* = n;
                    } else {
                        const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
                        const mp = @as(f64, @floatFromInt(@as(u64, in.width) * in.height)) / per * 1000;
                        try writers[k].interface.print("BenchmarkDecode/{s}\t{d}\t{d:.1} ns/op\t{d:.2} MP/s\n", .{ in.name, n, per, mp });
                    }
                    break;
                }
            }
        }
        std.debug.print("round {d} of {d} done\n", .{ round, rounds });
    }
    for (&writers, &files) |*w, f| {
        try w.interface.flush();
        f.close(io);
    }
    std.debug.print("state: pull decoder {d} bytes + reader {d} (+ its buffer: 0 fixed, {d} chunked); push decoder {d} bytes\n", .{ @sizeOf(image.qoi.Decoder), @sizeOf(Io.Reader), chunk_len, @sizeOf(Push) });
}
