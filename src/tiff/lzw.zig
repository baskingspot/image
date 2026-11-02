//! TIFF's LZW (TIFF 6.0, section 13), decoding a strip or tile a row at a
//! time into the caller's buffers.
//!
//! Codes are 9 to 12 bits, most significant bit first; 256 clears the
//! table and 257 ends the data. The code width grows one code early: to 10
//! bits once the next free entry is 511, as the specification's encoder
//! does. Files from before TIFF 5.0's revision ("old-style") pack codes
//! least significant bit first and grow the width when the next entry is
//! 512; they start with a Clear code whose low byte is 0 and whose ninth
//! bit is in the second byte's low bit, which a new-style stream (first
//! byte 0x80) cannot, so the first two bytes tell them apart.
//!
//! The table is in the caller's work memory (`work_len`). Each entry holds
//! its string's last block of up to 8 bytes and the entry for the rest, so
//! a string is written out 8 bytes a step. A string longer
//! than what is left of the caller's buffer is written to a stash in the
//! same memory and copied out over later calls.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const Error = error{
    /// Data that does not start with Clear (libtiff rejects it too), a
    /// code past the table's next entry, or a first code after Clear that
    /// is not a literal.
    BadLzw,
    /// The data ended (with EOI or the strip's last byte) before the rows.
    NotEnoughData,
    /// The input reader failed; the caller knows why.
    ReadFailed,
};

const clear = 256;
const eoi = 257;
const first_free = 258;
const table_len = 4096;
const none: u16 = 0xffff;

/// Work memory for the table and the stash, with a byte to align the
/// 16-bit arrays.
pub const work_len = table_len * (2 + 2 + block) + table_len + 1;

/// A table entry's string is held as its last block of up to this many
/// bytes and the entry holding the rest, so writing a string out takes a
/// step per block, not per byte.
const block = 8;

pub const Decoder = struct {
    src: *Io.Reader,
    /// The entry whose string is this one's without its last block.
    prefix: *[table_len]u16,
    length: *[table_len]u16,
    /// The last block: the bytes from the last multiple of `block` before
    /// the string's end.
    tail: *[table_len][block]u8,
    stash: *[table_len]u8,
    /// The unread part of the stash.
    stash_at: u16 = 0,
    stash_end: u16 = 0,
    bits: u64 = 0,
    nbits: u7 = 0,
    width: u4 = 9,
    next: u16 = first_free,
    prev: u16 = none,
    /// The first byte of the previous code's string.
    prev_first: u8 = 0,
    old: bool = false,
    /// The style the caller has decided, or null to tell from the data.
    style: ?bool,
    started: bool = false,
    cleared: bool = false,

    /// A decoder of the stream `src`, with `work` of at least `work_len`
    /// bytes.
    pub fn init(src: *Io.Reader, work_in: []u8, style: ?bool) Decoder {
        const work = work_in[@intFromPtr(work_in.ptr) & 1 ..];
        var d: Decoder = .{
            .src = src,
            .style = style,
            .prefix = @ptrCast(@alignCast(work[0 .. 2 * table_len])),
            .length = @ptrCast(@alignCast(work[2 * table_len .. 4 * table_len])),
            .tail = @ptrCast(work[4 * table_len ..][0 .. block * table_len]),
            .stash = work[(4 + block) * table_len ..][0..table_len],
        };
        for (0..256) |c| {
            d.length[c] = 1;
            d.tail[c][0] = @intCast(c);
        }
        return d;
    }

    /// Fills `dst` with the next decoded bytes.
    pub fn read(d: *Decoder, dst: []u8) Error!void {
        var i: usize = 0;
        if (d.stash_at < d.stash_end) {
            const n = @min(dst.len, d.stash_end - d.stash_at);
            @memcpy(dst[0..n], d.stash[d.stash_at..][0..n]);
            d.stash_at += @intCast(n);
            i = n;
        }
        if (!d.started) try d.start();
        // The state lives in locals here, since stores to `dst` could
        // otherwise alias it.
        const prefix = d.prefix;
        const length = d.length;
        const tail = d.tail;
        const old = d.old;
        var bits = d.bits;
        var nbits = d.nbits;
        var width = d.width;
        var next = d.next;
        var prev = d.prev;
        var prev_first = d.prev_first;
        var cleared = d.cleared;
        defer {
            d.cleared = cleared;
            d.bits = bits;
            d.nbits = nbits;
            d.width = width;
            d.next = next;
            d.prev = prev;
            d.prev_first = prev_first;
        }
        while (i < dst.len) {
            if (nbits < width) {
                const avail = d.src.buffered();
                if (avail.len >= 8) {
                    // Whole bytes, as many as fit beside the bits left.
                    const k: u6 = @intCast((63 - nbits) / 8);
                    if (old) {
                        const w = std.mem.readInt(u64, avail[0..8], .little);
                        bits |= (w & ((@as(u64, 1) << 8 * k) - 1)) << @intCast(nbits);
                    } else {
                        const w = std.mem.readInt(u64, avail[0..8], .big);
                        bits = bits << 8 * k | w >> @intCast(64 - @as(u7, 8) * k);
                    }
                    d.src.toss(k);
                    nbits += 8 * @as(u7, k);
                } else while (nbits < width) {
                    const b = d.src.takeByte() catch |e| switch (e) {
                        error.EndOfStream => return error.NotEnoughData,
                        error.ReadFailed => return error.ReadFailed,
                    };
                    if (old) {
                        bits |= @as(u64, b) << @intCast(nbits);
                    } else {
                        bits = bits << 8 | b;
                    }
                    nbits += 8;
                }
            }
            const mask = (@as(u64, 1) << width) - 1;
            nbits -= width;
            var code: u16 = undefined;
            if (old) {
                code = @intCast(bits & mask);
                bits >>= width;
            } else code = @intCast(bits >> @intCast(nbits) & mask);
            if (code < 256 and prev != none) {
                // A literal, the common case.
                if (next < table_len) {
                    add(prefix, length, tail, next, prev, @intCast(code));
                    next += 1;
                    if (next + @intFromBool(!old) >= @as(u16, 1) << width and width < 12) width += 1;
                }
                dst[i] = @intCast(code);
                i += 1;
                prev = code;
                prev_first = @intCast(code);
                continue;
            }
            if (code == clear) {
                next = first_free;
                width = 9;
                prev = none;
                cleared = true;
                continue;
            }
            if (code == eoi) return error.NotEnoughData;
            if (!cleared) return error.BadLzw;
            if (prev == none) {
                if (code >= 256) return error.BadLzw;
                dst[i] = @intCast(code);
                i += 1;
                prev = code;
                prev_first = @intCast(code);
                continue;
            }
            if (code > next or code == next and next == table_len) return error.BadLzw;
            // The new entry is the previous string and the first byte of
            // this one; when this code is that entry, its first byte is the
            // previous string's.
            const n = next;
            const len = if (code == n) length[prev] + 1 else length[code];
            if (n < table_len) {
                add(prefix, length, tail, n, prev, prev_first);
                next += 1;
                if (next + @intFromBool(!old) >= @as(u16, 1) << width and width < 12) width += 1;
            }
            prev = code;
            // The string's blocks are written whole, last first, as far as
            // `dst` (or the stash) has room; bytes past the string's end are
            // overwritten by the strings after it.
            const room = dst.len - i;
            const out = if (len <= room) dst[i..] else d.stash;
            var c = code;
            var at: usize = (len - 1) / block * block;
            if (at + block <= out.len) {
                out[at..][0..block].* = tail[c];
            } else for (out[at..len], tail[c][0 .. len - at]) |*o, t| {
                o.* = t;
            }
            while (at > 0) {
                c = prefix[c];
                at -= block;
                out[at..][0..block].* = tail[c];
            }
            prev_first = out[0];
            if (n < table_len) tail[n][(length[n] - 1) % block] = prev_first;
            if (len <= room) {
                i += len;
            } else {
                @memcpy(dst[i..], d.stash[0..room]);
                d.stash_at = @intCast(room);
                d.stash_end = len;
                i = dst.len;
            }
        }
    }

    /// Makes entry `n` the string of `prev` and then `byte`.
    inline fn add(
        prefix: *[table_len]u16,
        length: *[table_len]u16,
        tail: *[table_len][block]u8,
        n: u16,
        prev: u16,
        byte: u8,
    ) void {
        const len = length[prev];
        length[n] = len + 1;
        if (len % block != 0) {
            prefix[n] = prefix[prev];
            tail[n] = tail[prev];
            tail[n][len % block] = byte;
        } else {
            prefix[n] = prev;
            tail[n][0] = byte;
        }
    }

    fn start(d: *Decoder) Error!void {
        d.started = true;
        if (d.style) |old| {
            d.old = old;
            return;
        }
        const head = d.src.peek(2) catch |e| switch (e) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
        d.old = head[0] == 0 and head[1] & 1 != 0;
    }
};

/// A TIFF LZW encoder for tests: new-style unless `old`.
pub fn testEncode(gpa: std.mem.Allocator, data: []const u8, old: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var bits: u64 = 0;
    var nbits: u7 = 0;
    var width: u4 = 9;
    const W = struct {
        fn put(o: *std.ArrayList(u8), a: std.mem.Allocator, b: *u64, n: *u7, w: u4, c: u16, is_old: bool) !void {
            if (is_old) {
                b.* |= @as(u64, c) << @intCast(n.*);
                n.* += w;
                while (n.* >= 8) {
                    try o.append(a, @truncate(b.*));
                    b.* >>= 8;
                    n.* -= 8;
                }
            } else {
                b.* = b.* << w | c;
                n.* += w;
                while (n.* >= 8) {
                    n.* -= 8;
                    try o.append(a, @truncate(b.* >> @intCast(n.*)));
                }
            }
        }
    };
    var dict: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer dict.deinit(gpa);
    var next: u16 = first_free;
    try W.put(&out, gpa, &bits, &nbits, width, clear, old);
    var cur: ?u16 = null;
    // The encoder grows the width a code after the decoder, which is one
    // entry behind it.
    const late: u16 = if (old) 1 else 0;
    for (data) |b| {
        if (cur) |c| {
            const key = @as(u32, c) << 8 | b;
            if (dict.get(key)) |e| {
                cur = e;
                continue;
            }
            try W.put(&out, gpa, &bits, &nbits, width, c, old);
            try dict.put(gpa, key, next);
            next += 1;
            if (next >= (@as(u16, 1) << width) + late and width < 12) width += 1;
            if (next == table_len - 2) {
                try W.put(&out, gpa, &bits, &nbits, width, clear, old);
                dict.clearRetainingCapacity();
                next = first_free;
                width = 9;
            }
        }
        cur = b;
    }
    if (cur) |c| {
        try W.put(&out, gpa, &bits, &nbits, width, c, old);
        next += 1;
        if (next >= (@as(u16, 1) << width) + late and width < 12) width += 1;
    }
    try W.put(&out, gpa, &bits, &nbits, width, eoi, old);
    if (nbits > 0) {
        if (old) try out.append(gpa, @truncate(bits)) else try out.append(gpa, @truncate(bits << @intCast(8 - nbits)));
    }
    return out.toOwnedSlice(gpa);
}

fn testRoundTrip(data: []const u8, old: bool, step: usize) !void {
    const gpa = testing.allocator;
    const z = try testEncode(gpa, data, old);
    defer gpa.free(z);
    var r: Io.Reader = .fixed(z);
    const work = try gpa.alloc(u8, work_len);
    defer gpa.free(work);
    var d: Decoder = .init(&r, work, null);
    const out = try gpa.alloc(u8, data.len);
    defer gpa.free(out);
    var at: usize = 0;
    while (at < out.len) {
        const n = @min(step, out.len - at);
        try d.read(out[at..][0..n]);
        at += n;
    }
    try testing.expectEqualSlices(u8, data, out);
    var one: [1]u8 = undefined;
    try testing.expectError(error.NotEnoughData, d.read(&one));
}

test "round trips through every code width, new and old style" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    const data = try gpa.alloc(u8, 60000);
    defer gpa.free(data);
    // Runs and noise, so strings get long and the table fills and clears.
    var i: usize = 0;
    while (i < data.len) {
        const n = @min(data.len - i, 1 + random.uintLessThan(usize, 300));
        if (random.boolean()) @memset(data[i..][0..n], random.uintLessThan(u8, 4)) else for (data[i..][0..n]) |*b| {
            b.* = random.uintLessThan(u8, 8);
        }
        i += n;
    }
    for ([_]bool{ false, true }) |old| {
        for ([_]usize{ 1, 7, 157, 60000 }) |step| try testRoundTrip(data, old, step);
    }
    try testRoundTrip("a", false, 1);
}

test "malformed streams" {
    const gpa = testing.allocator;
    const work = try gpa.alloc(u8, work_len);
    defer gpa.free(work);
    var out: [4]u8 = undefined;
    // Clear, then 259, past the table.
    var r: Io.Reader = .fixed(&.{ 0x80, 0x40, 0xc0, 0x00 });
    var d: Decoder = .init(&r, work, null);
    try testing.expectError(error.BadLzw, d.read(&out));
    // A literal, 3, with no Clear before it.
    r = .fixed(&.{ 0x01, 0x80, 0x00, 0x00 });
    d = .init(&r, work, null);
    try testing.expectError(error.BadLzw, d.read(out[0..1]));
    // Clear, 'a', EOI: one byte, then the end.
    const z = try testEncode(gpa, "a", false);
    defer gpa.free(z);
    r = .fixed(z);
    d = .init(&r, work, null);
    try testing.expectError(error.NotEnoughData, d.read(&out));
    r = .fixed(z[0..1]);
    d = .init(&r, work, null);
    try testing.expectError(error.NotEnoughData, d.read(&out));
}
