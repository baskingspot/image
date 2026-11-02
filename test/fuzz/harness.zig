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
//!   with an error, writing nothing out of bounds.

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

/// Decodes every frame of `input` into `pixels` as `format`, reading
/// through `reader`, and returns what happened. `hash_format`, when set,
/// hashes each frame's pixels converted to it.
fn decodeAll(
    comptime D: type,
    reader: *Io.Reader,
    config: image.Config,
    format: PixelFormat,
    pixels: []u8,
    convert_to: ?PixelFormat,
) Result {
    var result: Result = .{};
    var d = D.init(reader, .{ .limits = limits });
    _ = d.decodeConfig() catch |e| {
        result.err = e;
        return result;
    };
    const dst = PixelBuffer.init(pixels, format, config.width, config.height) catch unreachable;
    @memset(pixels[0 .. PixelBuffer.len(format, config.width, config.height) orelse unreachable], 0);
    while (true) {
        const frame = d.decodeFrame(dst, work_buffer[0..config.work_len]) catch |e| {
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

/// A reader that hands over at most `step` bytes per read, into a buffer
/// of `image.min_buffer_len` bytes.
const Trickle = struct {
    data: []const u8,
    step: usize,
    buffer: [image.min_buffer_len]u8 = undefined,
    reader: Io.Reader,

    fn init(t: *Trickle, data: []const u8, step: usize) void {
        t.* = .{
            .data = data,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &t.buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("reader", r);
        if (t.data.len == 0) return error.EndOfStream;
        const n = try w.write(t.data[0..limit.minInt(@min(t.step, t.data.len))]);
        t.data = t.data[n..];
        return n;
    }
};

/// Checks every property on `input`. `choice` picks the second pixel
/// format and the trickle reader's step, so one input can be checked many
/// ways.
pub fn checkDecoder(comptime D: type, input: []const u8, choice: u64) !void {
    var fixed: Io.Reader = .fixed(input);
    var d = D.init(&fixed, .{ .limits = limits });
    const step = 1 + choice % 7;
    var trickle: Trickle = undefined;
    trickle.init(input, step);

    const config = d.decodeConfig() catch |e| {
        // The same error through the trickle.
        var t = D.init(&trickle.reader, .{ .limits = limits });
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
        var tight = D.init(&r, .{ .limits = .{ .max_pixels = pixel_count - 1 } });
        if (tight.decodeConfig()) |_| return error.LimitIgnored else |e| {
            if (e != error.ImageTooLarge) return error.LimitIgnored;
        }
    }

    const native = config.native;
    fixed = .fixed(input);
    const want = decodeAll(D, &fixed, config, native, &buffers[0], null);
    const got = decodeAll(D, &trickle.reader, config, native, &buffers[1], null);
    if (!want.eql(&got)) return error.ChunkedDiffers;

    // Another format: the native pixels converted, frame by frame.
    const formats = std.enums.values(PixelFormat);
    const other = formats[(choice / 7) % formats.len];
    fixed = .fixed(input);
    const converted = decodeAll(D, &fixed, config, native, &buffers[0], other);
    fixed = .fixed(input);
    const direct = decodeAll(D, &fixed, config, other, &buffers[1], other);
    var replaced = true;
    for (direct.frames[0..direct.count]) |f| replaced = replaced and f.frame.blend == .src;
    if (replaced and !converted.eql(&direct)) return error.FormatDiffers;

    // Buffers one byte short.
    if (pixel_count > 0) {
        fixed = .fixed(input);
        var short = D.init(&fixed, .{ .limits = limits });
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
        var short = D.init(&fixed, .{ .limits = limits });
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

/// The files under `dirs` (relative to the working directory, and skipped
/// when missing) whose names end in one of `extensions`, leaving out any of
/// `max_len` bytes or more, such as bench/corpus-gen's 50-megapixel inputs.
pub fn loadCorpus(
    gpa: std.mem.Allocator,
    io: Io,
    dirs: []const []const u8,
    extensions: []const []const u8,
    max_len: usize,
) !Corpus {
    var files: std.ArrayList([]const u8) = .empty;
    var too_large: usize = 0;
    for (dirs) |path| {
        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            for (extensions) |ext| {
                if (std.mem.endsWith(u8, entry.basename, ext)) break;
            } else continue;
            if ((try dir.statFile(io, entry.path, .{})).size >= max_len) {
                too_large += 1;
                continue;
            }
            try files.append(gpa, try dir.readFileAlloc(io, entry.path, gpa, .limited(max_len)));
        }
    }
    return .{ .files = try files.toOwnedSlice(gpa), .too_large = too_large };
}

test loadCorpus {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "small.qoi", .data = "qoif" });
    try tmp.dir.writeFile(io, .{ .sub_path = "large.qoi", .data = "qoif" ** 4 });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.png", .data = "png" });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(path);
    const corpus = try loadCorpus(gpa, io, &.{ path, "no/such/directory" }, &.{".qoi"}, 16);
    defer {
        for (corpus.files) |f| gpa.free(f);
        gpa.free(corpus.files);
    }
    try std.testing.expectEqual(1, corpus.files.len);
    try std.testing.expectEqualStrings("qoif", corpus.files[0]);
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
    /// to change in place, and the source itself. Null expects `want`
    /// unchanged, a lossless round trip.
    expect: ?*const fn (want: PixelBuffer, src: PixelBuffer) void = null,
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
    if (check.expect) |expect| expect(want, src);
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
    fn expect(want: PixelBuffer, _: PixelBuffer) void {
        threshold(want.pixels);
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
        // Without `expect`, a thresholded file does not round-trip.
        checkEncoderWith(ToyThreshold, .{ .max_width = 300, .max_height = 200 }, in, i) catch |e| {
            if (e != error.RoundTripDiffers) return e;
            differed = true;
        };
    }
    try std.testing.expect(differed);
}
