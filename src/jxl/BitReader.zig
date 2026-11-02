//! Bits from the codestream, least significant first (ISO/IEC 18181-1,
//! the bitstream conventions), with the field encodings every header uses:
//! `U32`, `U64`, `F16`, `Bool`, enums, and `ZeroPadToByte`.
//!
//! A frame's sections have byte sizes from its table of contents. Inside
//! a section (`beginSection` to `endSection`) reads past its end yield zero
//! bits, as if the section were padded, and `endSection` fails if any were
//! consumed, then skips what the section did not read. Outside a section
//! the input ending is `Truncated`.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const container = @import("container.zig");
const Source = container.Source;

const BitReader = @This();

pub const Error = container.Error || error{
    /// A field breaks the specification: an F16 that is infinite or NaN,
    /// an enum value out of range, nonzero padding, or a section read past
    /// its end.
    BadHeader,
};

src: Source,
/// Unconsumed bits, the next one lowest; bits above `nbits` are zero.
buf: u64 = 0,
nbits: u32 = 0,
/// Bits consumed so far, and bytes loaded from the source.
pos: u64 = 0,
loaded: u64 = 0,
/// The byte where the current section ends, or `no_end`.
end: u64 = no_end,
/// How many header bundles so far had extensions, which the oracle's
/// comparison leaves out (test/oracle/jxl.zig).
extensions: u32 = 0,

const no_end = std.math.maxInt(u64);

pub fn init(r: *Io.Reader, sink: anytype) BitReader {
    return .{ .src = .init(r, sink) };
}

/// Loads bytes until at least 57 bits are buffered, the section ends (then
/// zero bits follow), or the input ends.
fn refill(br: *BitReader) Error!void {
    while (br.nbits <= 56) {
        if (br.loaded >= br.end) {
            br.nbits = 64;
            return;
        }
        const avail = try br.src.more();
        if (avail.len == 0) return;
        const room: usize = (64 - br.nbits) / 8;
        const n: usize = @intCast(@min(@min(avail.len, room), br.end - br.loaded));
        var v: u64 = 0;
        if (avail.len >= 8) {
            v = std.mem.readInt(u64, avail[0..8], .little);
            if (n < 8) v &= (@as(u64, 1) << @intCast(n * 8)) - 1;
        } else {
            for (avail[0..n], 0..) |b, i| v |= @as(u64, b) << @intCast(i * 8);
        }
        br.buf |= v << @intCast(br.nbits);
        br.nbits += @intCast(n * 8);
        br.loaded += n;
        br.src.toss(n);
    }
}

/// The next `n` bits (at most 32) without consuming them.
pub inline fn peek(br: *BitReader, n: u6) Error!u32 {
    if (br.nbits < n) {
        try br.refill();
        if (br.nbits < n) return error.Truncated;
    }
    return @truncate(br.buf & ((@as(u64, 1) << n) - 1));
}

pub inline fn consume(br: *BitReader, n: u6) void {
    std.debug.assert(n <= br.nbits);
    br.buf >>= n;
    br.nbits -= n;
    br.pos += n;
}

/// Consumes `n` bits, which may be all 64 of a full buffer.
fn consumeUpTo64(br: *BitReader, n: u32) void {
    std.debug.assert(n <= br.nbits);
    br.buf = if (n == 64) 0 else br.buf >> @intCast(n);
    br.nbits -= n;
    br.pos += n;
}

/// Reads `n` bits, at most 32.
pub inline fn bits(br: *BitReader, n: u6) Error!u32 {
    std.debug.assert(n <= 32);
    if (n == 0) return 0;
    const v = try br.peek(n);
    br.consume(n);
    return v;
}

pub fn boolean(br: *BitReader) Error!bool {
    return try br.bits(1) == 1;
}

/// One of a `U32` field's four distributions: a constant, or `n` bits
/// plus an offset.
pub const Dist = union(enum) {
    val: u32,
    bits: struct { n: u6, offset: u32 = 0 },

    pub fn v(x: u32) Dist {
        return .{ .val = x };
    }
    pub fn b(n: u6) Dist {
        return .{ .bits = .{ .n = n } };
    }
    pub fn bo(n: u6, offset: u32) Dist {
        return .{ .bits = .{ .n = n, .offset = offset } };
    }
};

pub fn u32Dist(br: *BitReader, d: [4]Dist) Error!u32 {
    const sel = try br.bits(2);
    return switch (d[sel]) {
        .val => |x| x,
        .bits => |x| try br.bits(x.n) +% x.offset,
    };
}

pub fn u64Field(br: *BitReader) Error!u64 {
    switch (try br.bits(2)) {
        0 => return 0,
        1 => return 1 + @as(u64, try br.bits(4)),
        2 => return 17 + @as(u64, try br.bits(8)),
        else => {
            var v: u64 = try br.bits(12);
            var shift: u6 = 12;
            while (try br.boolean()) {
                if (shift == 60) {
                    v |= @as(u64, try br.bits(4)) << 60;
                    break;
                }
                v |= @as(u64, try br.bits(8)) << shift;
                shift += 8;
            }
            return v;
        },
    }
}

/// A binary16 float; infinity and NaN are `BadHeader`.
pub fn f16Field(br: *BitReader) Error!f32 {
    const h = try br.bits(16);
    const mantissa = h & 0x3ff;
    const exp = (h >> 10) & 0x1f;
    const sign: f32 = if (h >> 15 == 1) -1 else 1;
    if (exp == 31) return error.BadHeader;
    if (exp == 0) return sign * @as(f32, @floatFromInt(mantissa)) / (1 << 24);
    const m = 1 + @as(f32, @floatFromInt(mantissa)) / 1024;
    return sign * m * std.math.pow(f32, 2, @as(f32, @floatFromInt(@as(i32, @intCast(exp)) - 15)));
}

/// An enum's value: `U32(0, 1, 2 + u(4), 18 + u(6))`, below 64.
pub fn enumField(br: *BitReader) Error!u32 {
    const v = try br.u32Dist(.{ .v(0), .v(1), .bo(4, 2), .bo(6, 18) });
    if (v >= 64) return error.BadHeader;
    return v;
}

/// Skips to the next byte boundary; the skipped bits must be zero.
pub fn zeroPadToByte(br: *BitReader) Error!void {
    const n: u6 = @intCast((8 - br.pos % 8) % 8);
    if (try br.bits(n) != 0) return error.BadHeader;
}

/// Skips `n` bits.
pub fn skipBits(br: *BitReader, n_in: u64) Error!void {
    var n = n_in;
    const in_buf: u32 = @intCast(@min(n, br.nbits));
    br.consumeUpTo64(in_buf);
    n -= in_buf;
    if (n == 0) return;
    // Whole bytes straight from the source, within the section.
    const bytes = n / 8;
    if (br.end != no_end and br.loaded + bytes > br.end) {
        // Past the section's end: the rest is zero padding.
        br.pos += n;
        const real = br.end - br.loaded;
        try br.src.discard(real);
        br.loaded = br.end;
        return;
    }
    try br.src.discard(bytes);
    br.loaded += bytes;
    br.pos += bytes * 8;
    _ = try br.bits(@intCast(n % 8));
}

/// Starts a section of `len` bytes at the current position, which is
/// byte-aligned.
pub fn beginSection(br: *BitReader, len: u64) Error!void {
    std.debug.assert(br.pos % 8 == 0);
    br.end = std.math.add(u64, br.pos / 8, len) catch return error.BadHeader;
}

/// Ends the current section: fails if it was read past its end, and skips
/// what was left unread.
pub fn endSection(br: *BitReader) Error!void {
    const end_bit = br.end * 8;
    if (br.pos > end_bit) return error.BadHeader;
    const skip = end_bit - br.pos;
    if (skip <= br.nbits) {
        br.consumeUpTo64(@intCast(skip));
    } else {
        br.consumeUpTo64(br.nbits);
        try br.src.discard(br.end - br.loaded);
        br.loaded = br.end;
        br.pos = end_bit;
    }
    // Zero padding past the section end is not input.
    const real = br.loaded * 8 - br.pos;
    if (real < br.nbits) {
        br.nbits = @intCast(real);
        br.buf &= if (real == 0) 0 else (@as(u64, 1) << @intCast(real)) - 1;
    }
    br.end = no_end;
}

/// The bits consumed in the current section.
pub fn sectionPos(br: *const BitReader) u64 {
    return br.pos;
}

test "fields" {
    // 0b10_1101_01: selector 1 then four bits 1101 + 1.
    var r: Io.Reader = .fixed(&.{ 0xff, 0x0a, 0b1011_0101, 0x00, 0xff, 0xff });
    var br: BitReader = .init(&r, null);
    _ = try br.bits(16);
    try testing.expectEqual(@as(u64, 1 + 0b1101), try br.u64Field());
    try testing.expectEqual(@as(u32, 0b10), try br.bits(2));
    try br.zeroPadToByte();
    try testing.expectEqual(@as(u32, 0), try br.bits(8));
    try testing.expectEqual(@as(u32, 0xffff), try br.bits(16));
    try testing.expectError(error.Truncated, br.bits(1));
}

test "ending a section past a full buffer" {
    var bytes: [34]u8 = @splat(0x5a);
    bytes[0..2].* = .{ 0xff, 0x0a };
    var r: Io.Reader = .fixed(&bytes);
    var br: BitReader = .init(&r, null);
    _ = try br.bits(16);
    try br.beginSection(20);
    _ = try br.bits(32);
    _ = try br.peek(32); // refills all 64 bits
    try br.endSection();
    try testing.expectEqual(@as(u64, 176), br.sectionPos());
    try testing.expectEqual(@as(u32, 0x5a), try br.bits(8));
}

test "f16" {
    var r: Io.Reader = .fixed(&.{ 0xff, 0x0a, 0x00, 0x3c, 0x00, 0xc0, 0x01, 0x00, 0x00, 0x7c });
    var br: BitReader = .init(&r, null);
    _ = try br.bits(16);
    try testing.expectEqual(@as(f32, 1), try br.f16Field());
    try testing.expectEqual(@as(f32, -2), try br.f16Field());
    try testing.expectEqual(1.0 / @as(f32, 1 << 24), try br.f16Field());
    try testing.expectError(error.BadHeader, br.f16Field());
}

test "sections" {
    var r: Io.Reader = .fixed(&.{ 0xff, 0x0a, 0x01, 0x02, 0x03, 0x04, 0x05 });
    var br: BitReader = .init(&r, null);
    try testing.expectEqual(@as(u32, 0x0aff), try br.bits(16));
    try br.beginSection(2);
    try testing.expectEqual(@as(u32, 1), try br.bits(8));
    try br.endSection();
    try br.beginSection(1);
    try testing.expectEqual(@as(u32, 3), try br.bits(8));
    // Past the end: an error at the end.
    _ = try br.bits(8);
    try testing.expectError(error.BadHeader, br.endSection());
    br.end = no_end;
}

test "section skip" {
    var r: Io.Reader = .fixed(&.{ 0xff, 0x0a, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b });
    var br: BitReader = .init(&r, null);
    _ = try br.bits(16);
    try br.beginSection(10);
    try testing.expectEqual(@as(u32, 1), try br.bits(8));
    try br.endSection();
    try testing.expectEqual(@as(u32, 0x0b), try br.bits(8));
}
