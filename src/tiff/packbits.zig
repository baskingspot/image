//! PackBits (TIFF 6.0, section 9), decoded a row at a time. A header byte
//! n of 0 to 127 copies the next n + 1 bytes, -127 to -1 repeats the next
//! byte 1 - n times, and -128 does nothing. A run may cross the end of a
//! row, as libtiff allows.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const Error = error{
    /// The strip's data ended before the rows did.
    NotEnoughData,
    ReadFailed,
};

pub const Decoder = struct {
    src: *Io.Reader,
    /// Bytes left in the current run, and for a repeat run its byte.
    left: u8 = 0,
    repeat: bool = false,
    byte: u8 = 0,
    /// Whether a fill has found the end of the data.
    ended: bool = false,

    pub fn init(src: *Io.Reader) Decoder {
        return .{ .src = src };
    }

    pub fn read(d: *Decoder, dst: []u8) Error!void {
        var i: usize = 0;
        while (i < dst.len) {
            if (d.left == 0) {
                i = d.runs(dst, i);
                if (i == dst.len) return;
                const h: i8 = @bitCast(try d.take());
                if (h >= 0) {
                    d.left = @intCast(@as(i16, h) + 1);
                    d.repeat = false;
                } else if (h != -128) {
                    d.left = @intCast(1 - @as(i16, h));
                    d.repeat = true;
                    d.byte = try d.take();
                }
                continue;
            }
            const n = @min(d.left, dst.len - i);
            if (d.repeat) {
                @memset(dst[i..][0..n], d.byte);
                i += n;
                d.left -= @intCast(n);
            } else {
                const got = d.src.peekGreedy(1) catch |e| return map(e);
                const m = @min(n, got.len);
                @memcpy(dst[i..][0..m], got[0..m]);
                d.src.toss(m);
                i += m;
                d.left -= @intCast(m);
            }
        }
    }

    /// The longest run's header and bytes.
    const max_run = 129;

    /// Decodes whole runs straight from the reader's buffer into `dst`
    /// from `i`, while the buffer holds the next run and `dst` has room for
    /// it, and returns where it stopped. With room for any run, a run is
    /// moved as a fixed 32 or 128 bytes, writing past its end bytes that
    /// the runs after it overwrite; near the end of `dst`, exactly.
    fn runs(d: *Decoder, dst: []u8, start: usize) usize {
        var i = start;
        // A short or failed fill leaves the runs to `read`, which reports
        // the end or the failure where a run needs the bytes; once the data
        // has ended, there is nothing to fill.
        if (d.src.bufferedLen() < max_run and !d.ended) d.src.fill(max_run) catch |e| switch (e) {
            error.EndOfStream => d.ended = true,
            error.ReadFailed => {},
        };
        const buf = d.src.buffered();
        var p: usize = 0;
        while (i < dst.len and p < buf.len) {
            const h = buf[p];
            const room = dst.len - i;
            if (h < 128) {
                const n: usize = @as(usize, h) + 1;
                if (room >= 128 and p + max_run <= buf.len) {
                    if (n <= 32) {
                        dst[i..][0..32].* = buf[p + 1 ..][0..32].*;
                    } else dst[i..][0..128].* = buf[p + 1 ..][0..128].*;
                } else if (n <= room and p + 1 + n <= buf.len) {
                    copyExact(dst[i..][0..n], buf[p + 1 ..][0..n]);
                } else break;
                i += n;
                p += 1 + n;
            } else if (h == 128) {
                p += 1;
            } else {
                const n: usize = 257 - @as(usize, h);
                if (n > room or p + 1 >= buf.len) break;
                const b = buf[p + 1];
                if (room >= 128) {
                    if (n <= 32) {
                        dst[i..][0..32].* = @splat(b);
                    } else dst[i..][0..128].* = @splat(b);
                } else setExact(dst[i..][0..n], b);
                i += n;
                p += 2;
            }
        }
        d.src.toss(p);
        return i;
    }

    fn take(d: *Decoder) Error!u8 {
        return d.src.takeByte() catch |e| map(e);
    }
};

/// Copies 1 to 128 bytes with fixed-size moves, which overlap, rather
/// than a call.
fn copyExact(dst: []u8, src: []const u8) void {
    const n = dst.len;
    if (n >= 16) {
        var k: usize = 0;
        while (k + 16 < n) : (k += 16) dst[k..][0..16].* = src[k..][0..16].*;
        dst[n - 16 ..][0..16].* = src[n - 16 ..][0..16].*;
    } else if (n >= 8) {
        dst[0..8].* = src[0..8].*;
        dst[n - 8 ..][0..8].* = src[n - 8 ..][0..8].*;
    } else if (n >= 4) {
        dst[0..4].* = src[0..4].*;
        dst[n - 4 ..][0..4].* = src[n - 4 ..][0..4].*;
    } else {
        dst[0] = src[0];
        dst[n - 1] = src[n - 1];
        dst[n / 2] = src[n / 2];
    }
}

/// Sets 1 to 128 bytes to `b` in the same way.
fn setExact(dst: []u8, b: u8) void {
    const n = dst.len;
    if (n >= 16) {
        const v: [16]u8 = @splat(b);
        var k: usize = 0;
        while (k + 16 < n) : (k += 16) dst[k..][0..16].* = v;
        dst[n - 16 ..][0..16].* = v;
    } else if (n >= 8) {
        dst[0..8].* = @splat(b);
        dst[n - 8 ..][0..8].* = @splat(b);
    } else if (n >= 4) {
        dst[0..4].* = @splat(b);
        dst[n - 4 ..][0..4].* = @splat(b);
    } else {
        dst[0] = b;
        dst[n - 1] = b;
        dst[n / 2] = b;
    }
}

fn map(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.NotEnoughData,
        error.ReadFailed => error.ReadFailed,
    };
}

test "runs and literals, across rows" {
    // The specification's example.
    const packed_bytes = "\xfe\xaa\x02\x80\x00\x2a\xfd\xaa\x03\x80\x00\x2a\x22\xf7\xaa";
    const want = "\xaa\xaa\xaa\x80\x00\x2a\xaa\xaa\xaa\xaa\x80\x00\x2a\x22\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa";
    for ([_]usize{ 1, 5, want.len }) |step| {
        var r: Io.Reader = .fixed(packed_bytes);
        var d: Decoder = .init(&r);
        var out: [want.len]u8 = undefined;
        var at: usize = 0;
        while (at < out.len) : (at += step) try d.read(out[at..@min(out.len, at + step)]);
        try testing.expectEqualSlices(u8, want, &out);
        var one: [1]u8 = undefined;
        try testing.expectError(error.NotEnoughData, d.read(&one));
    }
    // -128 is skipped.
    var r: Io.Reader = .fixed("\x80\x00\x07");
    var d: Decoder = .init(&r);
    var out: [1]u8 = undefined;
    try d.read(&out);
    try testing.expectEqual(7, out[0]);
}

test "long data, read in pieces of every size" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(5);
    const random = prng.random();
    var packed_bytes: std.ArrayList(u8) = .empty;
    defer packed_bytes.deinit(gpa);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    // Literals and repeats of every length, and no-ops.
    while (want.items.len < 20000) {
        const h = random.int(u8);
        try packed_bytes.append(gpa, h);
        if (h < 128) {
            for (0..@as(usize, h) + 1) |_| {
                const b = random.int(u8);
                try packed_bytes.append(gpa, b);
                try want.append(gpa, b);
            }
        } else if (h > 128) {
            const b = random.int(u8);
            try packed_bytes.append(gpa, b);
            try want.appendNTimes(gpa, b, 257 - @as(usize, h));
        }
    }
    const out = try gpa.alloc(u8, want.items.len);
    defer gpa.free(out);
    for ([_]usize{ 1, 3, 100, 127, 128, 129, 300, 4096, out.len }) |step| {
        var r: Io.Reader = .fixed(packed_bytes.items);
        var d: Decoder = .init(&r);
        @memset(out, 0xee);
        var at: usize = 0;
        while (at < out.len) : (at += step) try d.read(out[at..@min(out.len, at + step)]);
        try testing.expectEqualSlices(u8, want.items, out);
    }
}
