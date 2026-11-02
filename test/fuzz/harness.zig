//! The properties every decoder holds on any input, checked by
//! `checkDecoder`. A format's fuzz target (test/fuzz/<format>.zig) calls it
//! with its `Decoder`; `main.zig` and `zig_fuzz.zig` feed it inputs.
//!
//! On any input a decoder must:
//!
//! - not crash, trip a safety check, or hang (the driver catches those);
//! - report a config within the limits it was given, and fail with
//!   `ImageTooLarge` when the pixel limit is one below the image;
//! - give the same frames, pixels, and error through a reader that hands
//!   over a few bytes at a time as through one holding the whole input;
//! - write, in any pixel format, its native-format pixels converted by
//!   `image.convert` (for frames that replace their region; a blended
//!   frame's rounding depends on the format);
//! - refuse a pixel buffer one byte short and work memory one byte short
//!   with an error, writing nothing out of bounds;
//! - where it has `decodeFrameConfig`, return from `decodeFrame` the frame
//!   that announced, or null where it announced null, and fail with the
//!   error it announced (`announced`); and decode the same frames, pixels,
//!   and error whether or not it is called first.
//!
//! A decoder that can move back (its own `Options` has a `seeker`) is
//! checked twice: reading forward only, and with a seeker over each reader.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const PixelFormat = image.PixelFormat;
const PixelBuffer = image.PixelBuffer;

/// The limits fuzzed decoders run under, so a hostile header cannot make
/// the harness allocate much.
pub const limits: image.Limits = .{
    .max_width = 1 << 14,
    .max_height = 1 << 14,
    .max_pixels = 1 << 20,
    .max_frames = 64,
    .max_work = 1 << 26,
};

/// What a property violation returns. The driver records any error from a
/// target as a finding.
pub const Finding = error{
    LimitIgnored,
    ChunkedDiffers,
    FormatDiffers,
    UndersizeAccepted,
    TooManyFrames,
    EncodeFailed,
    RoundTripDiffers,
    ChunkedWriterDiffers,
    FrameConfigDiffers,
};

const max_bytes = limits.max_pixels * 16;
var buffers: [3][max_bytes]u8 = undefined;
var work_buffer: [limits.max_work]u8 = undefined;

const Result = struct {
    frames: [limits.max_frames]FrameResult = undefined,
    count: usize = 0,
    err: ?anyerror = null,

    fn eql(a: *const Result, b: *const Result) bool {
        if (a.count != b.count or errorCode(a.err) != errorCode(b.err)) return false;
        for (a.frames[0..a.count], b.frames[0..b.count]) |x, y| {
            if (!std.meta.eql(x, y)) return false;
        }
        return true;
    }
};

/// An optional error as an integer, 0 for none, so two can be compared
/// without `==` on `?anyerror`: Zig 0.16's x86_64 backend, Debug's default,
/// compares two of those by a non-null flag byte they do not have, reading
/// past each value, so equal errors can compare unequal.
fn errorCode(err: ?anyerror) u16 {
    return if (err) |e| @intFromError(e) else 0;
}

test "Result.eql" {
    const truncated: Result = .{ .err = error.Truncated };
    const truncated_too: Result = .{ .err = error.Truncated };
    const bad: Result = .{ .err = error.BadHeader };
    const none: Result = .{};
    const none_too: Result = .{};
    // The bytes the miscompiled comparison reads are stack slots two bytes
    // apart; a pattern that differs there makes it fail every time.
    dirtyStack();
    try std.testing.expect(truncated.eql(&truncated_too));
    dirtyStack();
    try std.testing.expect(none.eql(&none_too));
    try std.testing.expect(!truncated.eql(&bad));
    try std.testing.expect(!truncated.eql(&none));
    try std.testing.expect(!none.eql(&bad));
    var one: Result = .{ .count = 1 };
    one.frames[0] = .{ .frame = .{ .width = 1, .height = 1 }, .hash = 7 };
    var other = one;
    try std.testing.expect(one.eql(&other));
    other.frames[0].hash = 8;
    try std.testing.expect(!one.eql(&other));
    try std.testing.expect(!one.eql(&none));
}

/// Fills the stack below the caller with 00 00 ff ff repeated.
noinline fn dirtyStack() void {
    var junk: [8192]u8 = undefined;
    for (&junk, 0..) |*b, i| b.* = if (i & 2 == 0) 0 else 0xff;
    std.mem.doNotOptimizeAway(&junk);
}

const FrameResult = struct {
    frame: image.Frame,
    hash: u64,
};

/// `d.decodeFrame`, checked against `d.decodeFrameConfig` called first: a
/// frame `decodeFrame` returns must be the one announced, null only where
/// null was announced, and an announced error must be `decodeFrame`'s
/// error. An announced frame may still fail in its pixels. A decoder
/// without `decodeFrameConfig` is only decoded.
pub fn announced(comptime D: type, d: *D, dst: PixelBuffer, work: []u8) Finding!(anyerror!?image.Frame) {
    if (comptime !@hasDecl(D, "decodeFrameConfig")) return d.decodeFrame(dst, work);
    const next = d.decodeFrameConfig();
    const got = d.decodeFrame(dst, work);
    if (next) |n| {
        if (got) |g| {
            if (!std.meta.eql(n, g)) return error.FrameConfigDiffers;
        } else |_| {}
    } else |e| {
        if (got) |_| return error.FrameConfigDiffers else |e2| if (e2 != e) return error.FrameConfigDiffers;
    }
    return got;
}

/// Decodes every frame of `input` into `pixels` as `format`, reading
/// through `reader` (and `seeker`, where `D` takes one), and returns what happened. With `announce`, each frame
/// is checked against `decodeFrameConfig` first (`announced`).
/// `convert_to`, when set, hashes each frame's pixels converted to it.
fn decodeAll(
    comptime D: type,
    reader: *Io.Reader,
    seeker: ?image.Seeker,
    config: image.Config,
    format: PixelFormat,
    pixels: []u8,
    convert_to: ?PixelFormat,
    announce: bool,
) Finding!Result {
    var result: Result = .{};
    var d = open(D, reader, seeker, limits);
    _ = d.decodeConfig() catch |e| {
        result.err = e;
        return result;
    };
    const dst = PixelBuffer.init(pixels, format, config.width, config.height) catch unreachable;
    @memset(pixels[0 .. PixelBuffer.len(format, config.width, config.height) orelse unreachable], 0);
    while (true) {
        const work = work_buffer[0..config.work_len];
        const step: anyerror!?image.Frame = if (announce) try announced(D, &d, dst, work) else d.decodeFrame(dst, work);
        const frame = step catch |e| {
            result.err = e;
            return result;
        } orelse return result;
        if (result.count == limits.max_frames) {
            result.err = error.TooManyFrames;
            return result;
        }
        var hash: u64 = 0;
        if (convert_to) |to| {
            const out = PixelBuffer.init(&buffers[2], to, config.width, config.height) catch unreachable;
            image.convert.convertBuffer(out, dst) catch unreachable;
            const len = PixelBuffer.len(to, config.width, config.height) orelse unreachable;
            hash = std.hash.Wyhash.hash(0, out.pixels[0..len]);
        } else {
            const len = PixelBuffer.len(format, config.width, config.height) orelse unreachable;
            hash = std.hash.Wyhash.hash(0, pixels[0..len]);
        }
        result.frames[result.count] = .{ .frame = frame, .hash = hash };
        result.count += 1;
    }
}

/// A toy one-frame format for testing `announced`: "T", the width and
/// height as bytes, then gray pixels. `lie` makes `decodeFrameConfig`
/// announce a wider frame, or an error, for a width of 3, or change the
/// pixels `decodeFrame` writes.
fn FrameToy(comptime lie: enum { none, frame, err, pixels }) type {
    return struct {
        const Self = @This();
        pub const Options = image.DecodeOptions;
        r: *Io.Reader,
        limits: image.Limits,
        config: ?image.Config = null,
        done: bool = false,
        peeked: bool = false,

        pub fn init(r: *Io.Reader, options: Options) Self {
            return .{ .r = r, .limits = options.limits };
        }
        pub fn decodeConfig(d: *Self) !image.Config {
            if (d.config) |c| return c;
            const h = try d.r.takeArray(3);
            if (h[0] != 'T') return error.BadSignature;
            try d.limits.checkSize(h[1], h[2]);
            d.config = .{ .width = h[1], .height = h[2], .native = .gray8, .frame_count = 1 };
            return d.config.?;
        }
        pub fn decodeFrameConfig(d: *Self) !?image.Frame {
            const c = try d.decodeConfig();
            if (d.done) return null;
            if (lie == .err and c.width == 3) return error.Truncated;
            d.peeked = true;
            return .{ .width = c.width + @intFromBool(lie == .frame and c.width == 3), .height = c.height };
        }
        pub fn decodeFrame(d: *Self, dst: PixelBuffer, _: []u8) !?image.Frame {
            const c = try d.decodeConfig();
            if (d.done) return null;
            try dst.check();
            const conv: image.convert.Converter = .init(dst.format, .gray8);
            var row: [255]u8 = undefined;
            for (0..c.height) |y| {
                d.r.readSliceAll(row[0..c.width]) catch return error.Truncated;
                if (lie == .pixels and d.peeked) row[0] ^= 1;
                conv.run(dst.row(@intCast(y)), &row, c.width);
            }
            d.done = true;
            return .{ .width = c.width, .height = c.height };
        }
    };
}

test announced {
    const file = "T\x03\x02" ++ "abcdef";
    // Every prefix holds, including announced frames whose pixels are cut
    // short.
    for (0..file.len + 1) |n| try checkDecoder(FrameToy(.none), file[0..n], n);
    try std.testing.expectError(error.FrameConfigDiffers, checkDecoder(FrameToy(.frame), file, 0));
    try std.testing.expectError(error.FrameConfigDiffers, checkDecoder(FrameToy(.err), file, 0));
    // Announcing must not change what is decoded.
    try std.testing.expectError(error.FrameConfigDiffers, checkDecoder(FrameToy(.pixels), file, 0));
    // Other widths are announced truly.
    try checkDecoder(FrameToy(.frame), "T\x02\x01ab", 0);
}

/// A toy one-frame format for testing seeking: "S", the width, the height,
/// and the offset of the gray pixels, which may lie behind the header.
/// With `lie`, a decoder given a seeker announces a taller frame.
fn SeekToy(comptime lie: bool) type {
    return struct {
        const Self = @This();
        pub const Options = struct {
            limits: image.Limits = .{},
            seeker: ?image.Seeker = null,
        };
        r: *Io.Reader,
        options: Options,
        config: ?image.Config = null,
        offset: u8 = 0,
        done: bool = false,

        var seek_calls: usize = 0;

        pub fn init(r: *Io.Reader, options: Options) Self {
            return .{ .r = r, .options = options };
        }
        pub fn decodeConfig(d: *Self) !image.Config {
            if (d.config) |c| return c;
            const h = try d.r.takeArray(4);
            if (h[0] != 'S') return error.BadSignature;
            try d.options.limits.checkSize(h[1], h[2]);
            d.offset = h[3];
            d.config = .{ .width = h[1], .height = h[2], .native = .gray8, .frame_count = 1 };
            return d.config.?;
        }
        pub fn decodeFrameConfig(d: *Self) !?image.Frame {
            const c = try d.decodeConfig();
            if (d.done) return null;
            if (d.offset < 4 and d.options.seeker == null) return error.DataBehind;
            const taller = lie and d.options.seeker != null;
            return .{ .width = c.width, .height = c.height + @intFromBool(taller) };
        }
        pub fn decodeFrame(d: *Self, dst: PixelBuffer, _: []u8) !?image.Frame {
            const c = try d.decodeConfig();
            if (d.done) return null;
            try dst.check();
            if (d.offset < 4) {
                const s = d.options.seeker orelse return error.DataBehind;
                try s.seek(s.context, d.offset);
                seek_calls += 1;
            } else d.r.discardAll(d.offset - 4) catch return error.Truncated;
            const conv: image.convert.Converter = .init(dst.format, .gray8);
            var row: [255]u8 = undefined;
            for (0..c.height) |y| {
                d.r.readSliceAll(row[0..c.width]) catch return error.Truncated;
                conv.run(dst.row(@intCast(y)), &row, c.width);
            }
            d.done = true;
            return .{ .width = c.width, .height = c.height };
        }
    };
}

test "a decoder that can move back is checked with a seeker" {
    // The pixels start at byte 1, behind the header.
    const file = "S\x02\x02\x01" ++ "ab";
    for (0..file.len + 1) |n| try checkDecoder(SeekToy(false), file[0..n], n);
    try std.testing.expect(SeekToy(false).seek_calls > 0);
    try std.testing.expectError(error.FrameConfigDiffers, checkDecoder(SeekToy(true), file, 0));
}

/// A reader that hands over at most `step` bytes per read, into a buffer
/// of `image.min_buffer_len` bytes, and can seek. Initialize it in place
/// (`init`), since `reader` points into it, and read from `&t.reader`.
pub const Trickle = struct {
    data: []const u8,
    at: usize = 0,
    step: usize,
    buffer: [image.min_buffer_len]u8 = undefined,
    reader: Io.Reader,

    pub fn init(t: *Trickle, data: []const u8, step: usize) void {
        t.* = .{
            .data = data,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &t.buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("reader", r);
        const rest = t.data[t.at..];
        if (rest.len == 0) return error.EndOfStream;
        const n = try w.write(rest[0..limit.minInt(@min(t.step, rest.len))]);
        t.at += n;
        return n;
    }

    pub fn seeker(t: *Trickle) image.Seeker {
        return .{ .context = t, .seek = seek };
    }

    fn seek(context: *anyopaque, offset: u64) error{ReadFailed}!void {
        const t: *Trickle = @ptrCast(@alignCast(context));
        t.at = @intCast(@min(offset, t.data.len));
        t.reader.seek = 0;
        t.reader.end = 0;
    }
};

/// The options `D.init` takes.
fn InitOptions(comptime D: type) type {
    return @typeInfo(@TypeOf(D.init)).@"fn".params[1].type.?;
}

/// Whether `D` can move back: its own options have a `seeker`. Formats
/// that never do take `image.DecodeOptions`, whose seeker they ignore.
fn seeks(comptime D: type) bool {
    return InitOptions(D) != image.DecodeOptions and @hasField(InitOptions(D), "seeker");
}

/// `D.init` over `reader`, with `seeker` where `D` takes one.
fn open(comptime D: type, reader: *Io.Reader, seeker: ?image.Seeker, lim: image.Limits) D {
    var options: InitOptions(D) = .{ .limits = lim };
    if (comptime seeks(D)) options.seeker = seeker;
    return D.init(reader, options);
}

/// Checks every property on `input`, reading forward only and, where `D`
/// can move back, again with a seeker. `choice` picks the second pixel
/// format and the trickle reader's step, so one input can be checked many
/// ways.
pub fn checkDecoder(comptime D: type, input: []const u8, choice: u64) !void {
    try checkReading(D, input, choice, false);
    if (comptime seeks(D)) try checkReading(D, input, choice, true);
}

fn checkReading(comptime D: type, input: []const u8, choice: u64, comptime seeking: bool) !void {
    var fixed: Io.Reader = .fixed(input);
    const step = 1 + choice % 7;
    var trickle: Trickle = undefined;
    trickle.init(input, step);
    // `fixed` is reset in place, so its seeker stays valid.
    const fixed_seeker: ?image.Seeker = if (seeking) .fixed(&fixed) else null;
    const trickle_seeker: ?image.Seeker = if (seeking) trickle.seeker() else null;
    var d = open(D, &fixed, fixed_seeker, limits);

    const config = d.decodeConfig() catch |e| {
        // The same error through the trickle.
        var t = open(D, &trickle.reader, trickle_seeker, limits);
        const again = t.decodeConfig();
        if (again) |_| return error.ChunkedDiffers else |e2| if (e2 != e) return error.ChunkedDiffers;
        return;
    };
    limits.checkSize(config.width, config.height) catch return error.LimitIgnored;
    if (config.work_len > limits.max_work) return error.LimitIgnored;
    if (config.frame_count) |n| if (n > limits.max_frames) return error.LimitIgnored;

    // One below the pixel limit fails before any pixel.
    const pixel_count = @as(u64, config.width) * config.height;
    if (pixel_count > 0) {
        var r: Io.Reader = .fixed(input);
        var tight = open(D, &r, if (seeking) .fixed(&r) else null, .{ .max_pixels = pixel_count - 1 });
        if (tight.decodeConfig()) |_| return error.LimitIgnored else |e| {
            if (e != error.ImageTooLarge) return error.LimitIgnored;
        }
    }

    const native = config.native;
    fixed = .fixed(input);
    const want = try decodeAll(D, &fixed, fixed_seeker, config, native, &buffers[0], null, false);
    fixed = .fixed(input);
    const with = try decodeAll(D, &fixed, fixed_seeker, config, native, &buffers[1], null, true);
    if (!want.eql(&with)) return error.FrameConfigDiffers;
    const got = try decodeAll(D, &trickle.reader, trickle_seeker, config, native, &buffers[1], null, true);
    if (!want.eql(&got)) return error.ChunkedDiffers;

    // Another format: the native pixels converted, frame by frame.
    const formats = std.enums.values(PixelFormat);
    const other = formats[(choice / 7) % formats.len];
    fixed = .fixed(input);
    const converted = try decodeAll(D, &fixed, fixed_seeker, config, native, &buffers[0], other, false);
    fixed = .fixed(input);
    const direct = try decodeAll(D, &fixed, fixed_seeker, config, other, &buffers[1], other, false);
    var replaced = true;
    for (direct.frames[0..direct.count]) |f| replaced = replaced and f.frame.blend == .src;
    if (replaced and !converted.eql(&direct)) return error.FormatDiffers;

    // Buffers one byte short.
    if (pixel_count > 0) {
        fixed = .fixed(input);
        var short = open(D, &fixed, fixed_seeker, limits);
        const len = PixelBuffer.len(native, config.width, config.height).?;
        const dst: PixelBuffer = .{
            .pixels = buffers[0][0 .. len - 1],
            .format = native,
            .width = config.width,
            .height = config.height,
            .stride = len / config.height,
        };
        if (short.decodeFrame(dst, work_buffer[0..config.work_len])) |_| return error.UndersizeAccepted else |_| {}
    }
    if (config.work_len > 0 and want.count > 0) {
        fixed = .fixed(input);
        var short = open(D, &fixed, fixed_seeker, limits);
        const dst = PixelBuffer.init(&buffers[0], native, config.width, config.height) catch unreachable;
        const work = work_buffer[0 .. config.work_len - 1];
        if (short.decodeFrame(dst, work)) |_| return error.UndersizeAccepted else |_| {}
    }
}

pub const Corpus = struct {
    files: []const []const u8,
    /// Files left out for being `max_len` bytes or more.
    too_large: usize,
};

/// The paths `loadCorpus` would read, each its directory joined with the
/// file's path under it, without reading the files.
pub const CorpusPaths = struct {
    paths: []const []const u8,
    too_large: usize,

    pub fn deinit(c: CorpusPaths, gpa: std.mem.Allocator) void {
        for (c.paths) |p| gpa.free(p);
        gpa.free(c.paths);
    }
};

/// The files under `dirs` (relative to the working directory, and skipped
/// when missing) whose names end in one of `extensions`, leaving out any of
/// `max_len` bytes or more, such as bench/corpus-gen's 50-megapixel inputs.
/// Each directory's files come in path order, not the file system's, so a
/// seed picks the same inputs on every machine.
pub fn loadCorpus(
    gpa: std.mem.Allocator,
    io: Io,
    dirs: []const []const u8,
    extensions: []const []const u8,
    max_len: usize,
) !Corpus {
    const listed = try listCorpus(gpa, io, dirs, extensions, max_len);
    defer listed.deinit(gpa);
    const files = try gpa.alloc([]const u8, listed.paths.len);
    for (files, listed.paths) |*f, p| f.* = try Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_len));
    return .{ .files = files, .too_large = listed.too_large };
}

/// `loadCorpus`'s files, in its order, as paths: for a caller that reads
/// each file when it needs it rather than holding them all.
pub fn listCorpus(
    gpa: std.mem.Allocator,
    io: Io,
    dirs: []const []const u8,
    extensions: []const []const u8,
    max_len: usize,
) !CorpusPaths {
    var all: std.ArrayList([]const u8) = .empty;
    var too_large: usize = 0;
    for (dirs) |path| {
        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| gpa.free(p);
            paths.deinit(gpa);
        }
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            for (extensions) |ext| {
                if (std.mem.endsWith(u8, entry.basename, ext)) break;
            } else continue;
            try paths.append(gpa, try gpa.dupe(u8, entry.path));
        }
        std.mem.sortUnstable([]const u8, paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        for (paths.items) |p| {
            if ((try dir.statFile(io, p, .{})).size >= max_len) {
                too_large += 1;
                continue;
            }
            try all.append(gpa, try Io.Dir.path.join(gpa, &.{ path, p }));
        }
    }
    return .{ .paths = try all.toOwnedSlice(gpa), .too_large = too_large };
}

test loadCorpus {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "small.qoi", .data = "qoif" });
    try tmp.dir.writeFile(io, .{ .sub_path = "large.qoi", .data = "qoif" ** 4 });
    // Taken in path order, whatever order the directory lists them in.
    for ("qcbpa") |c| try tmp.dir.writeFile(io, .{ .sub_path = &[_]u8{ c, '.', 'q', 'o', 'i' }, .data = &.{c} });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.png", .data = "png" });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(path);
    const corpus = try loadCorpus(gpa, io, &.{ path, "no/such/directory" }, &.{".qoi"}, 16);
    defer {
        for (corpus.files) |f| gpa.free(f);
        gpa.free(corpus.files);
    }
    try std.testing.expectEqual(6, corpus.files.len);
    for (corpus.files[0..5], "abcpq") |f, c| try std.testing.expectEqualStrings(&.{c}, f);
    try std.testing.expectEqualStrings("qoif", corpus.files[5]);
    try std.testing.expectEqual(1, corpus.too_large);
}

/// Small edits to `buf[0..len]` in place, returning the new length: byte
/// changes, bit flips, truncation, insertion, and repeated runs.
pub fn mutate(random: std.Random, buf: []u8, len_in: usize) usize {
    var len = len_in;
    const edits = 1 + random.uintLessThan(u8, 8);
    for (0..edits) |_| {
        switch (random.uintLessThan(u8, 8)) {
            0, 1 => if (len > 0) {
                buf[random.uintLessThan(usize, len)] = random.int(u8);
            },
            2, 3 => if (len > 0) {
                buf[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3);
            },
            4 => if (len > 0) {
                len = random.uintLessThan(usize, len);
            },
            5 => if (len < buf.len) {
                const at = random.uintAtMost(usize, len);
                @memmove(buf[at + 1 .. len + 1], buf[at..len]);
                buf[at] = random.int(u8);
                len += 1;
            },
            6 => if (len > 0) {
                // An interesting value: a boundary of some integer width.
                const at = random.uintLessThan(usize, len);
                const values = [_]u8{ 0, 1, 0x7f, 0x80, 0xfe, 0xff };
                buf[at] = values[random.uintLessThan(usize, values.len)];
            },
            else => if (len > 0) {
                // Repeat a run of bytes after itself.
                const at = random.uintLessThan(usize, len);
                const n = @min(1 + random.uintLessThan(usize, 64), len - at, buf.len - len);
                @memmove(buf[at + n .. len + n], buf[at..len]);
                len += n;
            },
        }
    }
    return len;
}

/// The coverage-guided fuzz test for target `T`, over its seeds.
pub fn zigFuzz(comptime T: type) !void {
    const Run = struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [1 << 16]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            try T.check(input, smith.value(u64));
        }
    };
    const corpus = comptime blk: {
        var list: [T.seeds.len][]const u8 = undefined;
        for (&list, T.seeds) |*s, seed| s.* = smithInput(seed);
        break :blk list;
    };
    try std.testing.fuzz({}, Run.run, .{ .corpus = &corpus });
}

/// `seed` as `std.testing.Smith` reads the input and choice `zigFuzz`
/// takes: a little-endian u32 length, the bytes, and a u64 choice, 0. A
/// seed that already starts with its own length is taken as it is, for
/// targets written before `zigFuzz` encoded seeds.
fn smithInput(comptime seed: []const u8) []const u8 {
    if (seed.len >= 4 and std.mem.readInt(u32, seed[0..4], .little) == seed.len - 4) return seed;
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, seed.len, .little);
    const out = len ++ seed[0..seed.len].* ++ [_]u8{0} ** 8;
    return &out;
}

test smithInput {
    const Seen = struct {
        var input: [16]u8 = undefined;
        var len: usize = 0;
        var choice: u64 = 0;
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            len = smith.slice(&input);
            choice = smith.value(u64);
        }
    };
    var smith: std.testing.Smith = .{ .in = comptime smithInput("qoif\x00\x01") };
    try Seen.run({}, &smith);
    try std.testing.expectEqualStrings("qoif\x00\x01", Seen.input[0..Seen.len]);
    try std.testing.expectEqual(0, Seen.choice);
    // Already encoded: as it is.
    const abc = "\x03\x00\x00\x00abc";
    try std.testing.expectEqualStrings(abc, comptime smithInput(abc));
}

/// The most pixels `checkEncoder` makes an image of.
const max_encode_pixels = 1 << 16;
var encoded: [2][4 << 20]u8 = undefined;
var source: [max_encode_pixels * 16]u8 = undefined;

/// How `checkEncoderWith` makes images and what it expects back.
pub const EncoderCheck = struct {
    /// The largest image to make, per side; at most `max_encode_pixels`
    /// in all.
    max_width: u32 = 48,
    max_height: u32 = 48,
    /// What the file must decode to, for an encoder that quantizes (WBMP's
    /// threshold, a palette) or loses detail: called with `want`, the
    /// source converted to the file's native format by `image.convert`,
    /// to change in place, and the round trip it came from. A hook that
    /// accepts a decode within a bound copies `trip.got` into `want`. Null
    /// expects `want` unchanged, a lossless round trip.
    expect: ?*const fn (want: PixelBuffer, trip: RoundTrip) void = null,
};

/// What `EncoderCheck.expect` sees of a round trip, to read only.
pub const RoundTrip = struct {
    /// The source, in its own pixel format.
    src: PixelBuffer,
    /// What our decoder read from the file, in its native format.
    got: PixelBuffer,
    /// The encoded file.
    file: []const u8,
};

/// `checkEncoderWith` with the defaults: images up to 48 by 48, and a
/// lossless round trip.
pub fn checkEncoder(comptime F: type, input: []const u8, choice: u64) !void {
    return checkEncoderWith(F, .{}, input, choice);
}

/// Checks an encoder on an image made from `input`: its first two bytes
/// pick the size, `choice` the source pixel format, and the rest of the
/// input, repeated, is the pixels. `F` is the format's namespace, with
/// `encode`, `workLen`, `EncodeOptions`, and `Decoder` (src/encode.zig).
/// The encoder must:
///
/// - accept the image in any pixel format, given `workLen` bytes of work
///   memory, and refuse one byte less with `WorkTooSmall`;
/// - write the same bytes through a writer that drains every few bytes as
///   into one buffer;
/// - write a file our decoder reads back, in its native format, as the
///   source converted to that format by `image.convert` (and then by
///   `check.expect`, when set).
pub fn checkEncoderWith(comptime F: type, comptime check: EncoderCheck, input: []const u8, choice: u64) !void {
    comptime std.debug.assert(@as(u64, check.max_width) * check.max_height <= max_encode_pixels);
    if (input.len < 3) return;
    const width = encodeSide(input[0], check.max_width);
    const height = encodeSide(input[1], check.max_height);
    const formats = std.enums.values(PixelFormat);
    const format = formats[choice % formats.len];
    const len = PixelBuffer.len(format, width, height).?;
    const body = input[2..];
    for (source[0..len], 0..) |*b, i| b.* = body[i % body.len];
    // Float samples from arbitrary bytes are often NaN or infinite; keep
    // them in [0, 1] so conversion is defined.
    if (format.sample() == .f32) {
        const floats: []align(1) f32 = @ptrCast(source[0..len]);
        for (floats, 0..) |*f, i| f.* = @as(f32, @floatFromInt(body[i % body.len])) / 255;
    }
    const src = PixelBuffer.init(source[0..len], format, width, height) catch unreachable;

    const options: F.EncodeOptions = .{};
    const work_len = F.workLen(options, width, height) orelse return error.EncodeFailed;
    if (work_len > work_buffer.len) return error.EncodeFailed;
    var w: Io.Writer = .fixed(&encoded[0]);
    F.encode(&w, src, options, work_buffer[0..work_len]) catch return error.EncodeFailed;
    const file = w.buffered();
    if (work_len > 0) {
        var short: Io.Writer = .fixed(&encoded[1]);
        const work = work_buffer[0 .. work_len - 1];
        if (F.encode(&short, src, options, work)) |_| return error.UndersizeAccepted else |e| {
            if (e != error.WorkTooSmall) return error.UndersizeAccepted;
        }
    }

    var drip: Drip = undefined;
    drip.init(&encoded[1], 1 + choice / formats.len % 7);
    F.encode(&drip.writer, src, options, work_buffer[0..work_len]) catch return error.EncodeFailed;
    drip.writer.flush() catch return error.EncodeFailed;
    if (!std.mem.eql(u8, file, encoded[1][0..drip.len])) return error.ChunkedWriterDiffers;

    var r: Io.Reader = .fixed(file);
    var d = F.Decoder.init(&r, .{ .limits = limits });
    const config = d.decodeConfig() catch return error.RoundTripDiffers;
    if (config.width != width or config.height != height) return error.RoundTripDiffers;
    const native_len = PixelBuffer.len(config.native, width, height).?;
    const got = PixelBuffer.init(buffers[0][0..native_len], config.native, width, height) catch unreachable;
    _ = d.decodeFrame(got, work_buffer[0..config.work_len]) catch return error.RoundTripDiffers;
    const want = PixelBuffer.init(buffers[1][0..native_len], config.native, width, height) catch unreachable;
    image.convert.convertBuffer(want, src) catch unreachable;
    if (check.expect) |expect| expect(want, .{ .src = src, .got = got, .file = file });
    if (!std.mem.eql(u8, got.pixels, want.pixels)) return error.RoundTripDiffers;
}

/// A side from 1 to `max` from a byte: the byte itself, wrapped, up to 256,
/// and scaled above it.
fn encodeSide(byte: u8, max: u32) u32 {
    return 1 + if (max <= 256) byte % max else @as(u32, byte) * max / 256;
}

/// A writer with a buffer of `image.min_buffer_len` bytes that drains at
/// most `step` bytes per call into `out`; `len` is how much it has written.
pub const Drip = struct {
    out: []u8,
    len: usize,
    step: usize,
    buffer: [image.min_buffer_len]u8,
    writer: Io.Writer,

    pub fn init(d: *Drip, out: []u8, step: usize) void {
        d.* = .{
            .out = out,
            .len = 0,
            .step = step,
            .buffer = undefined,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &d.buffer },
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const d: *Drip = @fieldParentPtr("writer", w);
        // Buffered bytes first, a few at a time.
        if (w.end > 0) {
            const n = @min(d.step, w.end);
            if (d.len + n > d.out.len) return error.WriteFailed;
            @memcpy(d.out[d.len..][0..n], w.buffer[0..n]);
            d.len += n;
            @memmove(w.buffer[0 .. w.end - n], w.buffer[n..w.end]);
            w.end -= n;
            return 0;
        }
        // Then the first nonempty slice, a few bytes of it; the last slice
        // counts `splat` times.
        for (data, 0..) |bytes, i| {
            if (bytes.len == 0 or (i == data.len - 1 and splat == 0)) continue;
            const n = @min(d.step, bytes.len);
            if (d.len + n > d.out.len) return error.WriteFailed;
            @memcpy(d.out[d.len..][0..n], bytes[0..n]);
            d.len += n;
            return n;
        }
        return 0;
    }
};

/// A toy format for testing `checkEncoder`: "RAW", the width and height
/// as bytes, then RGB pixels, or RGBA when the source has alpha.
const Toy = struct {
    const EncodeOptions = struct {};
    fn workLen(_: EncodeOptions, width: u32, _: u32) ?usize {
        return width * 4;
    }
    fn encode(w: *Io.Writer, src: PixelBuffer, _: EncodeOptions, work: []u8) image.EncodeError!void {
        try src.check();
        if (work.len < src.width * 4) return error.WorkTooSmall;
        const out: PixelFormat = if (src.format.hasAlpha()) .rgba8 else .rgb8;
        try w.writeAll(&.{ 'R', 'A', 'W', @intCast(src.width), @intCast(src.height), @intFromBool(out == .rgba8) });
        const conv: image.convert.Converter = .init(out, src.format);
        for (0..src.height) |y| {
            const row = work[0 .. src.width * out.bytesPerPixel()];
            conv.run(row, src.row(@intCast(y)), src.width);
            try w.writeAll(row);
        }
    }
    const Decoder = struct {
        r: *Io.Reader,
        h: [6]u8 = undefined,
        done: bool = false,
        const Options = image.DecodeOptions;
        fn init(r: *Io.Reader, _: Options) Decoder {
            return .{ .r = r };
        }
        fn native(d: *const Decoder) PixelFormat {
            return if (d.h[5] == 1) .rgba8 else .rgb8;
        }
        fn decodeConfig(d: *Decoder) !image.Config {
            d.h = (try d.r.takeArray(6)).*;
            return .{ .width = d.h[3], .height = d.h[4], .native = d.native() };
        }
        fn decodeFrame(d: *Decoder, dst: PixelBuffer, _: []u8) !?image.Frame {
            for (0..dst.height) |y| try d.r.readSliceAll(dst.row(@intCast(y)));
            d.done = true;
            return .{ .width = dst.width, .height = dst.height };
        }
    };
};

test checkEncoder {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    var input: [200]u8 = undefined;
    for (0..200) |i| {
        prng.random().bytes(&input);
        try checkEncoder(Toy, input[0 .. 3 + i % 197], i);
    }
}

/// A toy two-level format for testing `checkEncoderWith`'s `expect`:
/// "BW", the width and height as little-endian u16s, then a byte per
/// pixel, 255 where the source's gray is at least 128 and 0 elsewhere.
const ToyThreshold = struct {
    const EncodeOptions = struct {};
    fn workLen(_: EncodeOptions, width: u32, _: u32) ?usize {
        return width;
    }
    fn encode(w: *Io.Writer, src: PixelBuffer, _: EncodeOptions, work: []u8) image.EncodeError!void {
        try src.check();
        if (work.len < src.width) return error.WorkTooSmall;
        try w.writeAll("BW");
        try w.writeInt(u16, @intCast(src.width), .little);
        try w.writeInt(u16, @intCast(src.height), .little);
        const conv: image.convert.Converter = .init(.gray8, src.format);
        for (0..src.height) |y| {
            const row = work[0..src.width];
            conv.run(row, src.row(@intCast(y)), src.width);
            threshold(row);
            try w.writeAll(row);
        }
    }
    fn threshold(gray: []u8) void {
        for (gray) |*v| v.* = if (v.* >= 128) 255 else 0;
    }
    fn expect(want: PixelBuffer, _: RoundTrip) void {
        threshold(want.pixels);
    }
    /// Accepts the decode, when it is the file's pixels.
    fn accept(want: PixelBuffer, trip: RoundTrip) void {
        if (std.mem.eql(u8, trip.file[6..], trip.got.pixels)) @memcpy(want.pixels, trip.got.pixels);
    }
    const Decoder = struct {
        r: *Io.Reader,
        const Options = image.DecodeOptions;
        fn init(r: *Io.Reader, _: Options) Decoder {
            return .{ .r = r };
        }
        fn decodeConfig(d: *Decoder) !image.Config {
            const h = try d.r.takeArray(6);
            const width = std.mem.readInt(u16, h[2..4], .little);
            const height = std.mem.readInt(u16, h[4..6], .little);
            return .{ .width = width, .height = height, .native = .gray8 };
        }
        fn decodeFrame(d: *Decoder, dst: PixelBuffer, _: []u8) !?image.Frame {
            for (0..dst.height) |y| try d.r.readSliceAll(dst.row(@intCast(y)));
            return .{ .width = dst.width, .height = dst.height };
        }
    };
};

test checkEncoderWith {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    var input: [400]u8 = undefined;
    var differed = false;
    for (0..200) |i| {
        prng.random().bytes(&input);
        const in = input[0 .. 3 + i % 397];
        // Sides past 256, and the threshold expected.
        const check: EncoderCheck = .{ .max_width = 300, .max_height = 200, .expect = ToyThreshold.expect };
        try checkEncoderWith(ToyThreshold, check, in, i);
        // A hook that accepts what was decoded from the file.
        const accepting: EncoderCheck = .{ .max_width = 300, .max_height = 200, .expect = ToyThreshold.accept };
        try checkEncoderWith(ToyThreshold, accepting, in, i);
        // Without `expect`, a thresholded file does not round-trip.
        checkEncoderWith(ToyThreshold, .{ .max_width = 300, .max_height = 200 }, in, i) catch |e| {
            if (e != error.RoundTripDiffers) return e;
            differed = true;
        };
    }
    try std.testing.expect(differed);
}
