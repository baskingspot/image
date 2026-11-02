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
//! The table is in the caller's work memory (`work_len`). A string longer
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
pub const work_len = table_len * (2 + 2 + 1 + 1) + table_len + 1;

pub const Decoder = struct {
    src: *Io.Reader,
    prefix: *[table_len]u16,
    length: *[table_len]u16,
    suffix: *[table_len]u8,
    first: *[table_len]u8,
    stash: *[table_len]u8,
    /// The unread part of the stash.
    stash_at: u16 = 0,
    stash_end: u16 = 0,
    bits: u64 = 0,
    nbits: u7 = 0,
    width: u4 = 9,
    next: u16 = first_free,
    prev: u16 = none,
    old: bool = false,
    started: bool = false,
    cleared: bool = false,

    /// A decoder of the stream `src`, with `work` of at least `work_len`
    /// bytes.
    pub fn init(src: *Io.Reader, work_in: []u8) Decoder {
        const work = work_in[@intFromPtr(work_in.ptr) & 1 ..];
        var d: Decoder = .{
            .src = src,
            .prefix = @ptrCast(@alignCast(work[0 .. 2 * table_len])),
            .length = @ptrCast(@alignCast(work[2 * table_len .. 4 * table_len])),
            .suffix = work[4 * table_len ..][0..table_len],
            .first = work[5 * table_len ..][0..table_len],
            .stash = work[6 * table_len ..][0..table_len],
        };
        for (0..256) |c| {
            d.length[c] = 1;
            d.suffix[c] = @intCast(c);
            d.first[c] = @intCast(c);
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
        while (i < dst.len) {
            const code = try d.nextCode();
            if (code == clear) {
                d.next = first_free;
                d.width = 9;
                d.prev = none;
                d.cleared = true;
                continue;
            }
            if (code == eoi) return error.NotEnoughData;
            if (!d.cleared) return error.BadLzw;
            if (d.prev == none) {
                if (code >= 256) return error.BadLzw;
                dst[i] = @intCast(code);
                i += 1;
                d.prev = code;
                continue;
            }
            if (code > d.next or code == d.next and d.next == table_len) return error.BadLzw;
            if (d.next < table_len) {
                // The new entry: the previous string and the first byte of
                // this one, which is the previous string's own first byte
                // when this code is the entry being made.
                const n = d.next;
                d.prefix[n] = d.prev;
                d.suffix[n] = if (code == n) d.first[d.prev] else d.first[code];
                d.first[n] = d.first[d.prev];
                d.length[n] = d.length[d.prev] + 1;
                d.next += 1;
                const grow: u16 = if (d.old) 0 else 1;
                if (d.next + grow >= @as(u16, 1) << d.width and d.width < 12) d.width += 1;
            }
            d.prev = code;
            const len = d.length[code];
            const room = dst.len - i;
            if (len <= room) {
                writeString(d, dst[i..][0..len], code);
                i += len;
            } else {
                writeString(d, d.stash[0..len], code);
                @memcpy(dst[i..], d.stash[0..room]);
                d.stash_at = @intCast(room);
                d.stash_end = len;
                i = dst.len;
            }
        }
    }

    fn writeString(d: *const Decoder, out: []u8, string: u16) void {
        var c = string;
        var k = out.len;
        while (k > 1) {
            k -= 1;
            out[k] = d.suffix[c];
            c = d.prefix[c];
        }
        out[0] = @intCast(c);
    }

    fn start(d: *Decoder) Error!void {
        d.started = true;
        const head = d.src.peek(2) catch |e| switch (e) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
        d.old = head[0] == 0 and head[1] & 1 != 0;
    }

    /// The next code, refilling the bit buffer a byte at a time.
    fn nextCode(d: *Decoder) Error!u16 {
        while (d.nbits < d.width) {
            const b = d.src.takeByte() catch |e| switch (e) {
                error.EndOfStream => return error.NotEnoughData,
                error.ReadFailed => return error.ReadFailed,
            };
            if (d.old) {
                d.bits |= @as(u64, b) << @intCast(d.nbits);
            } else {
                d.bits = d.bits << 8 | b;
            }
            d.nbits += 8;
        }
        const mask = (@as(u64, 1) << d.width) - 1;
        d.nbits -= d.width;
        if (d.old) {
            const c: u16 = @intCast(d.bits & mask);
            d.bits >>= d.width;
            return c;
        }
        return @intCast(d.bits >> @intCast(d.nbits) & mask);
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
    var d: Decoder = .init(&r, work);
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
    var d: Decoder = .init(&r, work);
    try testing.expectError(error.BadLzw, d.read(&out));
    // A literal, 3, with no Clear before it.
    r = .fixed(&.{ 0x01, 0x80, 0x00, 0x00 });
    d = .init(&r, work);
    try testing.expectError(error.BadLzw, d.read(out[0..1]));
    // Clear, 'a', EOI: one byte, then the end.
    const z = try testEncode(gpa, "a", false);
    defer gpa.free(z);
    r = .fixed(z);
    d = .init(&r, work);
    try testing.expectError(error.NotEnoughData, d.read(&out));
    r = .fixed(z[0..1]);
    d = .init(&r, work);
    try testing.expectError(error.NotEnoughData, d.read(&out));
}
