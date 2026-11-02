//! The JPEG XL encoder's bit writer: LSB first, as ISO/IEC 18181-1 reads,
//! into a caller's buffer, with the specification's U32, U64, and enum
//! field codings. Writing past the buffer sets `overflow` and drops the
//! bits; the encoder sizes every buffer so that never happens, and checks.

const std = @import("std");
const testing = std.testing;

pub const BitWriter = struct {
    buf: []u8,
    /// Bytes written to `buf`.
    len: usize = 0,
    acc: u64 = 0,
    /// Bits in `acc`, under 8 between calls.
    nacc: u6 = 0,
    overflow: bool = false,

    pub fn init(buf: []u8) BitWriter {
        return .{ .buf = buf };
    }

    /// Writes the low `n` bits of `v`, `n` at most 56.
    pub inline fn bits(w: *BitWriter, v: u64, n: u6) void {
        std.debug.assert(n <= 56);
        std.debug.assert(n == 0 or v >> n == 0);
        w.acc |= v << w.nacc;
        w.nacc += n;
        while (w.nacc >= 8) {
            if (w.len < w.buf.len) {
                w.buf[w.len] = @truncate(w.acc);
                w.len += 1;
            } else w.overflow = true;
            w.acc >>= 8;
            w.nacc -= 8;
        }
    }

    pub fn boolean(w: *BitWriter, b: bool) void {
        w.bits(@intFromBool(b), 1);
    }

    /// The bits written so far.
    pub fn bitPos(w: *const BitWriter) u64 {
        return @as(u64, w.len) * 8 + w.nacc;
    }

    /// Pads with zeros to a byte boundary.
    pub fn padToByte(w: *BitWriter) void {
        if (w.nacc != 0) w.bits(0, 8 - w.nacc);
    }

    /// The bytes written, after `padToByte`.
    pub fn bytes(w: *const BitWriter) []const u8 {
        std.debug.assert(w.nacc == 0);
        return w.buf[0..w.len];
    }

    /// Appends whole bytes, at a byte boundary.
    pub fn append(w: *BitWriter, data: []const u8) void {
        std.debug.assert(w.nacc == 0);
        if (data.len > w.buf.len - w.len) {
            w.overflow = true;
            return;
        }
        @memcpy(w.buf[w.len..][0..data.len], data);
        w.len += data.len;
    }

    /// One of a U32 field's four distributions: a constant, or `n` bits plus
    /// an offset.
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

        fn fits(d: Dist, x: u32) bool {
            return switch (d) {
                .val => |c| c == x,
                .bits => |e| x >= e.offset and x - e.offset < @as(u64, 1) << e.n,
            };
        }
    };

    /// Writes `x` with the first of the four distributions that holds it;
    /// `x` must fit one.
    pub fn u32Dist(w: *BitWriter, x: u32, d: [4]Dist) void {
        for (d, 0..) |dist, sel| {
            if (!dist.fits(x)) continue;
            w.bits(sel, 2);
            switch (dist) {
                .val => {},
                .bits => |e| w.bits(x - e.offset, e.n),
            }
            return;
        }
        unreachable;
    }

    pub fn u64Field(w: *BitWriter, x: u64) void {
        if (x == 0) {
            w.bits(0, 2);
        } else if (x <= 16) {
            w.bits(1, 2);
            w.bits(x - 1, 4);
        } else if (x <= 272) {
            w.bits(2, 2);
            w.bits(x - 17, 8);
        } else {
            w.bits(3, 2);
            w.bits(x & 0xfff, 12);
            var rest = x >> 12;
            var shift: u6 = 12;
            while (rest != 0) {
                w.boolean(true);
                if (shift == 60) {
                    w.bits(rest & 0xf, 4);
                    return;
                }
                w.bits(rest & 0xff, 8);
                rest >>= 8;
                shift += 8;
            }
            w.boolean(false);
        }
    }

    /// An enum's value: `U32(0, 1, 2 + u(4), 18 + u(6))`.
    pub fn enumField(w: *BitWriter, x: u32) void {
        w.u32Dist(x, .{ .v(0), .v(1), .bo(4, 2), .bo(6, 18) });
    }
};

test "fields round trip through the decoder's reader" {
    const BitReader = @import("BitReader.zig");
    var buf: [64]u8 = undefined;
    var w: BitWriter = .init(&buf);
    w.bits(0x0aff, 16);
    w.u32Dist(5000, .{ .bo(9, 1), .bo(13, 1), .bo(18, 1), .bo(30, 1) });
    w.u64Field(0);
    w.u64Field(16);
    w.u64Field(272);
    w.u64Field(1 << 40);
    w.enumField(13);
    w.boolean(true);
    w.padToByte();
    var r: std.Io.Reader = .fixed(w.bytes());
    var br: BitReader = .init(&r, null);
    try testing.expectEqual(0x0aff, try br.bits(16));
    try testing.expectEqual(5000, try br.u32Dist(.{ .bo(9, 1), .bo(13, 1), .bo(18, 1), .bo(30, 1) }));
    try testing.expectEqual(0, try br.u64Field());
    try testing.expectEqual(16, try br.u64Field());
    try testing.expectEqual(272, try br.u64Field());
    try testing.expectEqual(1 << 40, try br.u64Field());
    try testing.expectEqual(13, try br.enumField());
    try testing.expect(try br.boolean());
    try testing.expect(!w.overflow);
}
