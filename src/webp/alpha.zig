//! ALPH chunks (RFC 9649 section 2.7.1.2): a lossy image's alpha plane,
//! raw or as a lossless image stream of the frame's size whose green
//! channel holds it, then unfiltered by the predictor the header names.
//! As libwebp does, a header with reserved bits set, a method or
//! preprocessing value past those defined, or a raw plane shorter than the
//! frame is an error; the preprocessing bits are otherwise ignored.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const lossless = @import("lossless.zig");

pub const Error = lossless.Error || error{
    /// The ALPH header is malformed, or its raw plane is too short.
    BadAlpha,
};

/// Bytes of work memory `decode` needs beside the plane.
pub fn workLen(width: u32, height: u32, max_groups: u32) ?usize {
    return lossless.workLen(width, height, max_groups);
}

pub const Result = struct {
    /// Bytes of the chunk not read.
    unread: u64,
    /// Why the alpha plane could not be decoded, when the stream itself
    /// was fine: the caller may skip the rest and go on.
    err: ?Error = null,
};

const Unfilter = struct {
    plane: []u8,
    width: usize,
    filter: u2,

    /// Row `y` of filtered values, already in the plane, unfiltered in
    /// place against the row above.
    fn run(u: *const Unfilter, y: usize) void {
        const w = u.width;
        const cur = u.plane[y * w ..][0..w];
        if (u.filter == 0) return;
        if (y == 0 or u.filter == 1) {
            // Horizontal, and the top row of every filter: from the left,
            // and the first pixel from above (0 on the top row).
            var pred: u8 = if (y == 0) 0 else u.plane[(y - 1) * w];
            for (cur) |*p| {
                p.* +%= pred;
                pred = p.*;
            }
            return;
        }
        const prev = u.plane[(y - 1) * w ..][0..w];
        if (u.filter == 2) {
            for (cur, prev) |*p, a| p.* +%= a;
            return;
        }
        // Gradient: clip(left + above - above-left), the first pixel from
        // above.
        var left: u8 = prev[0];
        var top_left: u8 = prev[0];
        for (cur, prev) |*p, top| {
            const g = std.math.clamp(@as(i32, left) + top - top_left, 0, 255);
            p.* +%= @intCast(g);
            left = p.*;
            top_left = top;
        }
    }

    fn row(context: *anyopaque, y: u32, argb: []u32) void {
        const u: *const Unfilter = @ptrCast(@alignCast(context));
        const out = u.plane[@as(usize, y) * u.width ..][0..u.width];
        for (out, argb) |*a, p| a.* = @truncate(p >> 8);
        u.run(y);
    }
};

/// Decodes an ALPH chunk body of `len` bytes into `plane`, `width` by
/// `height`, using `work[0..workLen(...)]` for a lossless stream. Errors
/// from the reader are returned; errors in the alpha data come back in the
/// result with the bytes left unread.
pub fn decode(
    reader: *Io.Reader,
    len: u64,
    width: u32,
    height: u32,
    max_groups: u32,
    plane: []u8,
    work: []u8,
) Error!Result {
    if (len <= 1) return .{ .unread = len, .err = error.BadAlpha };
    const head = reader.takeByte() catch |e| return mapRead(e);
    const method: u2 = @truncate(head);
    const filter: u2 = @truncate(head >> 2);
    const pre: u2 = @truncate(head >> 4);
    if (head >> 6 != 0 or method > 1 or pre > 1) return .{ .unread = len - 1, .err = error.BadAlpha };
    const n = @as(usize, width) * height;
    const u: Unfilter = .{ .plane = plane[0..n], .width = width, .filter = filter };
    if (method == 0) {
        if (len - 1 < n) return .{ .unread = len - 1, .err = error.BadAlpha };
        for (0..height) |y| {
            reader.readSliceAll(plane[y * width ..][0..width]) catch |e| return mapRead(e);
            u.run(y);
        }
        return .{ .unread = len - 1 - n };
    }
    var br: lossless.BitReader = .init(reader, len - 1);
    lossless.decode(&br, width, height, max_groups, true, work, .{
        .context = @constCast(&u),
        .row = Unfilter.row,
    }) catch |e| {
        if (br.failed) |f| return f;
        // Zeros read past the end can look malformed: the end comes first.
        return .{ .unread = br.left, .err = if (br.count < br.pad) error.Truncated else e };
    };
    return .{ .unread = br.left };
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

test "unfilters invert the filters" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    const w = 7;
    const h = 5;
    var src: [w * h]u8 = undefined;
    r.bytes(&src);
    for (0..4) |f| {
        // Filter by the definitions: the predictor from the source.
        var plane: [w * h]u8 = undefined;
        for (0..h) |y| for (0..w) |x| {
            const a: i32 = if (x > 0) src[y * w + x - 1] else if (y > 0) src[(y - 1) * w] else 0;
            const b: i32 = if (y > 0) src[(y - 1) * w + x] else if (x > 0) src[x - 1] else 0;
            const c: i32 = if (x > 0 and y > 0) src[(y - 1) * w + x - 1] else b;
            const pred: i32 = switch (f) {
                0 => 0,
                1 => a,
                2 => b,
                else => if (x == 0 or y == 0) (if (x == 0) b else a) else std.math.clamp(a + b - c, 0, 255),
            };
            plane[y * w + x] = src[y * w + x] -% @as(u8, @intCast(pred));
        };
        const u: Unfilter = .{ .plane = &plane, .width = w, .filter = @intCast(f) };
        for (0..h) |y| u.run(y);
        try testing.expectEqualSlices(u8, &src, &plane);
    }
}
