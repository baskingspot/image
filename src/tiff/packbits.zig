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

    pub fn init(src: *Io.Reader) Decoder {
        return .{ .src = src };
    }

    pub fn read(d: *Decoder, dst: []u8) Error!void {
        var i: usize = 0;
        while (i < dst.len) {
            if (d.left == 0) {
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

    fn take(d: *Decoder) Error!u8 {
        return d.src.takeByte() catch |e| map(e);
    }
};

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
