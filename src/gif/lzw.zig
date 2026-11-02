//! GIF's variant of LZW (GIF89a, appendix F): variable-length codes packed
//! least significant bit first, starting one bit wider than the minimum
//! code size and growing a bit each time the next code to assign reaches
//! the current width's limit, up to 12 bits. A clear code resets the table;
//! once it holds 4096 entries it stops growing and codes stay 12 bits wide
//! until the next clear (a "deferred clear"). TIFF's LZW differs (most
//! significant bit first, and an earlier change of width) and lives in
//! src/tiff/.
//!
//! Each table entry keeps its string's last chunk of up to 8 bytes and the
//! entry whose string is everything before that chunk, a multiple of 8
//! bytes long; literals are entries too, one byte long. Writing a string walks that chain from the end, 8 bytes per
//! step, so nothing reads back the output, and the output can be any
//! buffer with room to spare.

const std = @import("std");
const testing = std.testing;

/// The most entries a table holds, and so the longest string a code can
/// name.
pub const max_codes = 4096;

/// Room `decode` needs past the end of the bytes it writes: the longest
/// string, and the 8-byte chunk stores that may run past its end.
pub const out_slack = max_codes + 8;

/// The table, in the caller's work memory. Entry `c` is a string's last 1
/// to 8 bytes (`tail[c]`, the first of them lowest), and in `meta[c]` the
/// entry whose string is everything before them (the low 16 bits) and the
/// string's length (the high 16).
pub const Table = struct {
    tail: [max_codes]u64,
    meta: [max_codes]u32,
};

/// The entry for the string of `tail` and `meta`, code `code`, followed by
/// `byte`.
inline fn append(t: *Table, k: u16, tail: u64, meta: u32, code: u16, byte: u8) void {
    const len = meta >> 16;
    const rest: u6 = @intCast(((len - 1) & 7) + 1);
    if (rest < 8) {
        t.tail[k] = tail | @as(u64, byte) << (rest * 8);
        t.meta[k] = meta + 0x10000;
    } else {
        t.tail[k] = byte;
        t.meta[k] = (len + 1) << 16 | code;
    }
}

pub const Status = enum {
    /// `in` is used up: call again with more.
    need_input,
    /// `out` has less than `out_slack` bytes left past its write position.
    out_full,
    /// The end-of-information code.
    end,
    /// A code names an entry the table does not hold yet. `out_pos` is
    /// past the strings before it, so a caller can use them; the decoder
    /// must not be called again.
    bad_code,
};

pub const Result = struct {
    status: Status,
    /// Where the next byte of `in` and of `out` is.
    in_pos: usize,
    out_pos: usize,
};

pub const Decoder = struct {
    table: *Table,
    clear: u16,
    /// The next entry to assign, and the code width in bits.
    next: u16,
    width: u4,
    /// The code before this one and its entry, with `prev_meta` 0 after a
    /// clear.
    prev: u16 = 0,
    prev_tail: u64 = 0,
    prev_meta: u32 = 0,
    /// Bits read but not yet used, lowest first. Bits above `nbits` may be
    /// set: they are the input's next bits, read ahead, so reading those
    /// bytes again sets them to what they are already.
    acc: u64 = 0,
    nbits: u7 = 0,

    /// A decoder for literals of `min_bits` bits, 0 to 8. With 0, as Wuffs
    /// and giflib read it, the clear code is 1, the end code 2, and codes
    /// start 1 bit wide, already narrower than the next entry, 3: the
    /// width grows after the first code.
    pub fn init(table: *Table, min_bits: u4) Decoder {
        std.debug.assert(min_bits <= 8);
        const clear = @as(u16, 1) << min_bits;
        for (0..clear) |i| {
            table.tail[i] = i;
            table.meta[i] = 1 << 16;
        }
        return .{ .table = table, .clear = clear, .next = clear + 2, .width = min_bits + 1 };
    }

    /// Decodes codes from `in[in_pos..]`, writing their strings from
    /// `out[out_pos..]`, until the input runs out, the output is within
    /// `out_slack` bytes of its end, the end-of-information code, or a bad
    /// code.
    pub noinline fn decode(z: *Decoder, in: []const u8, in_pos: usize, out: []u8, out_pos: usize) Result {
        std.debug.assert(out.len >= out_slack);
        const t = z.table;
        const clear = z.clear;
        const limit = out.len - out_slack;
        var pos = in_pos;
        var o = out_pos;
        var acc = z.acc;
        var nbits: u32 = z.nbits;
        var width: u32 = z.width;
        var next = z.next;
        var prev = z.prev;
        var prev_tail = z.prev_tail;
        var prev_meta = z.prev_meta;
        const status: Status = while (o <= limit) {
            if (nbits < width) {
                if (in.len - pos >= 8) {
                    acc |= std.mem.readInt(u64, in[pos..][0..8], .little) << @intCast(nbits);
                    const n = (63 - nbits) >> 3;
                    pos += n;
                    nbits += n * 8;
                } else if (pos < in.len) {
                    acc |= @as(u64, in[pos]) << @intCast(nbits);
                    pos += 1;
                    nbits += 8;
                    continue;
                } else break .need_input;
            }
            const code: u16 = @intCast(acc & ((@as(u64, 1) << @intCast(width)) - 1));
            acc >>= @intCast(width);
            nbits -= width;
            if (code < next and code -% clear >= 2) {
                // A literal or an entry: the common case.
                const tail = t.tail[code];
                const meta = t.meta[code];
                const first = expand(t, tail, meta, out, o);
                if (prev_meta != 0 and next < max_codes) {
                    append(t, next, prev_tail, prev_meta, prev, first);
                    next += 1;
                }
                prev = code;
                prev_tail = tail;
                prev_meta = meta;
                o += meta >> 16;
            } else if (code == clear) {
                next = clear + 2;
                width = @ctz(clear) + 1;
                prev_meta = 0;
                continue;
            } else if (code == clear + 1) {
                break .end;
            } else if (code == next and prev_meta != 0) {
                // The string not yet in the table: the previous one and its
                // own first byte.
                append(t, next, prev_tail, prev_meta, prev, firstByte(t, prev_tail, prev_meta));
                prev = next;
                prev_tail = t.tail[next];
                prev_meta = t.meta[next];
                next += 1;
                _ = expand(t, prev_tail, prev_meta, out, o);
                o += prev_meta >> 16;
            } else break .bad_code;
            if (next >= @as(u32, 1) << @intCast(width) and width < 12) width += 1;
        } else .out_full;
        z.acc = acc;
        z.nbits = @intCast(nbits);
        z.width = @intCast(width);
        z.next = next;
        z.prev = prev;
        z.prev_tail = prev_tail;
        z.prev_meta = prev_meta;
        return .{ .status = status, .in_pos = pos, .out_pos = o };
    }
};

/// The first byte of the string of the entry `tail` and `meta`: the low
/// byte of its first chunk.
fn firstByte(t: *const Table, tail: u64, meta: u32) u8 {
    var len = meta >> 16;
    var c: u16 = @truncate(meta);
    var first = tail;
    while (len > 8) : (len -= 8) {
        first = t.tail[c];
        c = @truncate(t.meta[c]);
    }
    return @truncate(first);
}

/// Writes the string of the entry `tail` and `meta` at `out[o..]` and
/// returns its first byte. The first store may write up to 7 bytes past
/// the string's end.
inline fn expand(t: *const Table, tail_in: u64, meta: u32, out: []u8, o: usize) u8 {
    const len: usize = meta >> 16;
    var p = o + len - (((len - 1) & 7) + 1);
    var tail = tail_in;
    std.mem.writeInt(u64, out[p..][0..8], tail, .little);
    var c: u16 = @truncate(meta);
    while (p > o) {
        p -= 8;
        tail = t.tail[c];
        std.mem.writeInt(u64, out[p..][0..8], tail, .little);
        c = @truncate(t.meta[c]);
    }
    return @truncate(tail);
}

// Tests. `Encoder` is a plain LZW encoder in GIF's variant, with a
// dictionary of strings, so the decoder is checked against strings rather
// than against its own table.

pub const testing_encoder = struct {
    /// LZW codes for `data` with literals of `min_bits` bits. `clear_every`
    /// emits a clear code after that many codes once the table is full;
    /// null never clears again, so codes stay 12 bits (a deferred clear).
    pub fn encode(gpa: std.mem.Allocator, data: []const u8, min_bits: u4, clear_every: ?usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var dict: std.StringHashMapUnmanaged(u16) = .empty;
        defer dict.deinit(gpa);
        const clear = @as(u16, 1) << min_bits;
        var next: u16 = clear + 2;
        var width: u4 = min_bits + 1;
        var acc: u64 = 0;
        var nbits: u6 = 0;
        const Put = struct {
            fn put(o: *std.ArrayList(u8), g: std.mem.Allocator, a: *u64, n: *u6, code: u16, w: u4) !void {
                a.* |= @as(u64, code) << n.*;
                n.* += w;
                while (n.* >= 8) {
                    try o.append(g, @truncate(a.*));
                    a.* >>= 8;
                    n.* -= 8;
                }
            }
        };
        try Put.put(&out, gpa, &acc, &nbits, clear, width);
        var full_codes: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            // The longest prefix in the dictionary.
            var n: usize = 1;
            var code: u16 = data[i];
            while (i + n < data.len) {
                const c = dict.get(data[i .. i + n + 1]) orelse break;
                code = c;
                n += 1;
            }
            try Put.put(&out, gpa, &acc, &nbits, code, width);
            if (i + n < data.len) {
                if (next < max_codes) {
                    try dict.put(gpa, data[i .. i + n + 1], next);
                    next += 1;
                    // The decoder widens one code later than the encoder
                    // assigns, as it learns each entry a code late.
                    if (next >= (@as(u16, 1) << width) + 1 and width < 12) width += 1;
                } else if (clear_every) |every| {
                    full_codes += 1;
                    if (full_codes == every) {
                        try Put.put(&out, gpa, &acc, &nbits, clear, width);
                        dict.clearRetainingCapacity();
                        next = clear + 2;
                        width = min_bits + 1;
                        full_codes = 0;
                    }
                }
            }
            i += n;
        }
        // The decoder adds an entry for the last code too, a code late, and
        // reads the end code at the width that leaves it.
        if (next >= @as(u16, 1) << width and width < 12) width += 1;
        try Put.put(&out, gpa, &acc, &nbits, clear + 1, width);
        if (nbits > 0) try out.append(gpa, @truncate(acc));
        return out.toOwnedSlice(gpa);
    }
};

fn decodeAll(table: *Table, codes: []const u8, min_bits: u4, out: []u8, step: usize) ![]u8 {
    var z: Decoder = .init(table, min_bits);
    var o: usize = 0;
    var fed: usize = 0;
    var pos: usize = 0;
    while (true) {
        // Hand the input over `step` bytes at a time; the window keeps the
        // bytes not yet used.
        const end = @min(codes.len, fed + step);
        const r = z.decode(codes[0..end], pos, out, o);
        pos = r.in_pos;
        o = r.out_pos;
        switch (r.status) {
            .end => return out[0..o],
            .need_input => {
                if (end == codes.len) return error.NoEnd;
                fed = end;
            },
            .out_full => return error.OutFull,
            .bad_code => return error.BadLzw,
        }
    }
}

test "round trip: strings, a full table, and deferred clears" {
    const gpa = testing.allocator;
    const table = try gpa.create(Table);
    defer gpa.destroy(table);
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const data = try gpa.alloc(u8, 40000);
    defer gpa.free(data);
    const out = try gpa.alloc(u8, data.len + out_slack);
    defer gpa.free(out);
    for (0..9) |m| {
        const min_bits: u4 = @intCast(m);
        for (0..4) |kind| {
            const len = 1 + random.uintLessThan(usize, data.len);
            const mask: u8 = @intCast((@as(u16, 1) << min_bits) - 1);
            for (data[0..len], 0..) |*b, i| {
                const v: usize = switch (kind) {
                    // Runs, so strings grow long (past 8 bytes, many chunks).
                    0 => if (i % 3000 < 1500) 0 else 1,
                    1 => random.int(u8),
                    2 => i / 7 % 5,
                    else => (i * i / 31) % 13,
                };
                b.* = @as(u8, @truncate(v)) & mask;
            }
            for ([_]?usize{ null, 1, 100 }) |every| {
                const codes = try testing_encoder.encode(gpa, data[0..len], min_bits, every);
                defer gpa.free(codes);
                for ([_]usize{ 1, 3, 255, codes.len }) |step| {
                    const got = try decodeAll(table, codes, min_bits, out, step);
                    try testing.expectEqualSlices(u8, data[0..len], got);
                }
            }
        }
    }
}

test "the string not yet in the table, and bad codes" {
    const table = try testing.allocator.create(Table);
    defer testing.allocator.destroy(table);
    var out: [out_slack + 16]u8 = undefined;
    // Min 2: clear 4, end 5. Codes (3 bits): clear, 1, 6 (= "1" + "1"),
    // end: "111".
    const kwkwk = [_]u8{ 0x8c, 0x0b };
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1 }, try decodeAll(table, &kwkwk, 2, &out, 2));
    // Code 7 right after a literal is past the next entry (6).
    const bad = [_]u8{ 0xcc, 0x0b };
    try testing.expectError(error.BadLzw, decodeAll(table, &bad, 2, &out, 2));
    // Code 6 right after a clear has no previous string.
    const bad2 = [_]u8{ 0x74, 0x01 };
    try testing.expectError(error.BadLzw, decodeAll(table, &bad2, 2, &out, 2));
}
