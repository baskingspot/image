//! GIF's LZW compressor (GIF89a, appendix F): palette indices in, codes
//! out, packed least significant bit first into data sub-blocks of up to
//! 255 bytes. The stream starts with a clear code, and when the table holds
//! 4096 entries the next new string is a clear code instead, so the table
//! never stops learning. Each code is as wide as the decoder will read it:
//! the decoder learns each entry a code late, so its width is tracked here
//! from the codes it has read (`dec_next`), not from the encoder's table.
//!
//! The table is a hash of (prefix code, index) pairs in the caller's
//! memory: a slot holds `key << 12 | code`, with 0 for empty, since no
//! string's code is below the end code.

const std = @import("std");
const vfill = @import("../fill.zig").fill;
const testing = std.testing;
const Io = std.Io;

pub const max_codes = 4096;

/// The table slots for an image of `pixels` pixels: a power of two at
/// least twice the codes it can need, at most four times the most codes a
/// table holds, so a lookup rarely probes far. A frame of n pixels adds
/// fewer than n entries.
pub fn tableLen(pixels: u64) usize {
    const want: usize = @as(usize, @intCast(@min(pixels, max_codes))) * 2;
    return std.math.ceilPowerOfTwo(usize, @max(want, 64)) catch unreachable;
}

pub const Encoder = struct {
    out: *Io.Writer,
    table: []u32,
    /// The shift that takes a hash's top bits as a slot.
    shift: u5,
    min_bits: u4,
    clear: u16,
    /// The next code the encoder assigns, and the next the decoder will,
    /// one code behind.
    enc_next: u16,
    dec_next: u16,
    /// Codes written since the last clear code.
    since_clear: u16 = 0,
    /// The code of the string matched so far, or -1 before the first index.
    prefix: i32 = -1,
    acc: u64 = 0,
    nbits: u7 = 0,
    block: [255]u8 = undefined,
    block_len: u8 = 0,

    /// Starts a frame's data: writes its minimum code size, `min_bits`
    /// (2 to 8), and a clear code. `table` has a power of two of slots,
    /// at least `tableLen` of the frame's pixels.
    pub fn init(out: *Io.Writer, table: []u32, min_bits: u4) Io.Writer.Error!Encoder {
        std.debug.assert(min_bits >= 2);
        std.debug.assert(min_bits <= 8);
        std.debug.assert(std.math.isPowerOfTwo(table.len));
        std.debug.assert(table.len >= 64);
        const clear = @as(u16, 1) << min_bits;
        var e: Encoder = .{
            .out = out,
            .table = table,
            .shift = @intCast(32 - std.math.log2_int(usize, table.len)),
            .min_bits = min_bits,
            .clear = clear,
            .enc_next = clear + 2,
            .dec_next = clear + 2,
        };
        vfill(u32, table, 0);
        try out.writeByte(min_bits);
        try e.emit(clear);
        return e;
    }

    /// Compresses `indices`, each below `1 << min_bits`.
    pub fn write(e: *Encoder, indices: []const u8) Io.Writer.Error!void {
        var i: usize = 0;
        if (e.prefix < 0) {
            if (indices.len == 0) return;
            e.prefix = indices[0];
            i = 1;
        }
        var prefix: u32 = @intCast(e.prefix);
        const table = e.table;
        const mask = table.len - 1;
        while (i < indices.len) : (i += 1) {
            const k = indices[i];
            const key = prefix << 8 | k;
            var slot: usize = (key *% 0x9E3779B1) >> e.shift;
            const found = probe: while (true) {
                const v = table[slot];
                if (v == 0) break :probe false;
                if (v >> 12 == key) {
                    prefix = v & 0xfff;
                    break :probe true;
                }
                slot = (slot + 1) & mask;
            };
            if (found) continue;
            try e.emit(@intCast(prefix));
            if (e.enc_next < max_codes) {
                table[slot] = key << 12 | e.enc_next;
                e.enc_next += 1;
            } else {
                // The table is full: a clear code instead of an entry.
                try e.emit(e.clear);
            }
            prefix = k;
        }
        e.prefix = @intCast(prefix);
    }

    /// Ends the data: the last string's code, the end code, the bits left
    /// over, and the block terminator.
    pub fn finish(e: *Encoder) Io.Writer.Error!void {
        if (e.prefix >= 0) try e.emit(@intCast(e.prefix));
        try e.emit(e.clear + 1);
        while (e.nbits > 0) {
            try e.putByte(@truncate(e.acc));
            e.acc >>= 8;
            e.nbits -|= 8;
        }
        try e.flushBlock();
        try e.out.writeByte(0);
    }

    fn reset(e: *Encoder) void {
        vfill(u32, e.table, 0);
        e.enc_next = e.clear + 2;
        e.dec_next = e.clear + 2;
        e.since_clear = 0;
    }

    /// Writes `code` as wide as the decoder reads it now, then moves the
    /// decoder's next code on as it will once it has read this one: it
    /// adds an entry for every code but the first after a clear.
    fn emit(e: *Encoder, code: u16) Io.Writer.Error!void {
        const width: u7 = if (e.dec_next >= max_codes)
            12
        else
            @max(@as(u7, e.min_bits) + 1, std.math.log2_int(u16, e.dec_next) + 1);
        e.acc |= @as(u64, code) << @intCast(e.nbits);
        e.nbits += width;
        while (e.nbits >= 8) {
            try e.putByte(@truncate(e.acc));
            e.acc >>= 8;
            e.nbits -= 8;
        }
        if (e.since_clear >= 1 and e.dec_next < max_codes) e.dec_next += 1;
        e.since_clear +|= 1;
        if (code == e.clear) e.reset();
    }

    fn putByte(e: *Encoder, b: u8) Io.Writer.Error!void {
        e.block[e.block_len] = b;
        e.block_len += 1;
        if (e.block_len == 255) try e.flushBlock();
    }

    fn flushBlock(e: *Encoder) Io.Writer.Error!void {
        if (e.block_len == 0) return;
        try e.out.writeByte(e.block_len);
        try e.out.writeAll(e.block[0..e.block_len]);
        e.block_len = 0;
    }
};

const lzw = @import("lzw.zig");

/// Compresses `data` and decodes it again with this package's decoder,
/// from the sub-blocks' data.
fn roundTrip(data: []const u8, min_bits: u4) !void {
    const gpa = testing.allocator;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const table = try gpa.alloc(u32, tableLen(data.len));
    defer gpa.free(table);
    var e: Encoder = try .init(&aw.writer, table, min_bits);
    // In pieces of several sizes, so state carries across calls.
    var i: usize = 0;
    var step: usize = 1;
    while (i < data.len) : (step = step * 3 % 97 + 1) {
        const n = @min(step, data.len - i);
        try e.write(data[i..][0..n]);
        i += n;
    }
    try e.finish();
    const file = aw.written();
    try testing.expectEqual(min_bits, file[0]);
    // Gather the sub-blocks' data.
    var codes: std.ArrayList(u8) = .empty;
    defer codes.deinit(gpa);
    var p: usize = 1;
    while (file[p] != 0) {
        try codes.appendSlice(gpa, file[p + 1 ..][0..file[p]]);
        p += 1 + @as(usize, file[p]);
    }
    try testing.expectEqual(file.len, p + 1);
    const t = try gpa.create(lzw.Table);
    defer gpa.destroy(t);
    const out = try gpa.alloc(u8, data.len + lzw.out_slack);
    defer gpa.free(out);
    var z: lzw.Decoder = .init(t, min_bits);
    const r = z.decode(codes.items, 0, out, 0);
    try testing.expectEqual(lzw.Status.end, r.status);
    try testing.expectEqualSlices(u8, data, out[0..r.out_pos]);
}

test "LZW round trips: empty, runs, noise that fills the table, every width" {
    const gpa = testing.allocator;
    try roundTrip("", 2);
    try roundTrip(&.{0}, 2);
    try roundTrip(&.{ 1, 1, 1, 1, 1, 1, 1 }, 2);
    const big = try gpa.alloc(u8, 200_000);
    defer gpa.free(big);
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    for (2..9) |bits| {
        const b: u4 = @intCast(bits);
        // Noise fills the table many times over; long runs reach strings
        // of every length; a mix crosses each width at many places.
        for (big) |*v| v.* = @intCast(random.uintLessThan(u16, @as(u16, 1) << b));
        try roundTrip(big, b);
        @memset(big, 1);
        try roundTrip(big, b);
        for (big, 0..) |*v, i| {
            v.* = if (i % 1000 < 500) @truncate(i % (@as(usize, 1) << b)) else random.uintLessThan(u8, 2);
        }
        try roundTrip(big, b);
        // Every length up to well past a width change.
        for (0..600) |n| try roundTrip(big[0..n], b);
    }
}
