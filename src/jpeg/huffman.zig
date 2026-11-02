//! Huffman entropy decoding (ITU T.81 Annex C and sections F.2.2 and
//! G.2): the bit reader over the entropy-coded segments, decoding tables,
//! and the block decoders for sequential and progressive scans.
//!
//! The bit reader takes bytes from the caller's `std.Io.Reader` and
//! removes the stuffed zero after each 0xFF data byte. When the data ends,
//! at a marker or at the end of the input, it supplies zero bits, as the
//! specification's decoders do (F.2.2.5), but counts them: a scan that
//! reads past the end of its data is an error once the block is done,
//! which is where libjpeg-turbo warns that the data segment ended early.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const Error = error{
    ReadFailed,
    /// A code in the entropy-coded data is not in its Huffman table.
    BadHuffmanCode,
};

/// A table as DHT defines it: the number of codes of each length 1 to 16,
/// then the symbols in code order.
pub const Spec = struct {
    counts: [16]u8,
    values: [256]u8,

    pub fn count(s: *const Spec) usize {
        var n: usize = 0;
        for (s.counts) |c| n += c;
        return n;
    }
};

/// The lookahead width of `Table.fast`.
const fast_bits = 9;

/// A decoding table built from a `Spec`.
pub const Table = struct {
    /// For the next `fast_bits` bits of input: the code's length and
    /// symbol, `length << 8 | symbol`, or 0 when the code is longer.
    fast: [1 << fast_bits]u16,
    /// For AC tables, the next `fast_bits` bits decoded through the
    /// magnitude bits when both fit: `value << 16 | run << 8 | length`,
    /// the value the coefficient, sign-extended and never 0. When only
    /// the code fits: `symbol << 8 | length`. When neither does: 0.
    fast_ac: [1 << fast_bits]i32,
    /// `limit[l]`: one past the last code of length `l`, shifted to 16
    /// bits. The length of a code is the first `l` with the next 16 bits
    /// below `limit[l]`.
    limit: [18]u32,
    /// `offset[l]`: added to a code of length `l` to give its symbol's
    /// index in `values`.
    offset: [17]i32,
    values: [256]u8,

    /// Builds the table, checking the counts as libjpeg-turbo does: at
    /// most 256 codes, and no length so full that its last code is all
    /// ones (figure C.2's codes must fit their lengths). DC symbols are
    /// magnitude categories: at most 15, or 16 for lossless.
    pub fn init(t: *Table, spec: *const Spec, comptime kind: enum { dc, ac, lossless }) error{BadHuffmanTable}!void {
        const n = spec.count();
        if (n > 256) return error.BadHuffmanTable;
        var code: u32 = 0;
        var k: u32 = 0;
        var first_used = true;
        t.limit[0] = 0;
        for (spec.counts, 1..) |c, l| {
            t.offset[l] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            code += c;
            k += c;
            // The reference checks each length from the first used one.
            if (c != 0) first_used = false;
            if (!first_used and code >= @as(u32, 1) << @intCast(l)) return error.BadHuffmanTable;
            t.limit[l] = code << @intCast(16 - l);
            code <<= 1;
        }
        t.limit[17] = std.math.maxInt(u32);
        @memcpy(t.values[0..n], spec.values[0..n]);
        @memset(t.values[n..], 0);
        if (kind != .ac) {
            const max: u8 = if (kind == .lossless) 16 else 15;
            for (spec.values[0..n]) |v| if (v > max) return error.BadHuffmanTable;
        }
        // Lookahead entries for codes of at most `fast_bits` bits.
        @memset(&t.fast, 0);
        @memset(&t.fast_ac, 0);
        code = 0;
        k = 0;
        for (spec.counts[0..fast_bits], 1..) |c, l| {
            for (0..c) |_| {
                const sym = spec.values[k];
                const shift: u5 = @intCast(fast_bits - l);
                const lo = code << shift;
                for (lo..lo + (@as(u32, 1) << shift)) |i| {
                    t.fast[i] = @intCast(l << 8 | sym);
                    if (kind == .ac) {
                        const size: u32 = sym & 15;
                        const run: u32 = sym >> 4;
                        if (size != 0 and l + size <= fast_bits) {
                            const mask = (@as(u32, 1) << @intCast(size)) - 1;
                            const bits: u32 = @intCast((i >> @intCast(fast_bits - l - size)) & mask);
                            const v = extend(bits, @intCast(size));
                            t.fast_ac[i] = v << 16 | @as(i32, @intCast(run << 8 | (l + size)));
                        } else {
                            t.fast_ac[i] = @intCast(@as(u32, sym) << 8 | l);
                        }
                    }
                }
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
    }
};

/// The standard tables of T.81 section K.3, which libjpeg-turbo uses for a
/// sequential Huffman scan that names table 0 or 1 when no DHT defined it
/// (Motion JPEG frames leave them out).
pub const standard = struct {
    pub const dc_luma: Spec = spec(
        .{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
    );
    pub const dc_chroma: Spec = spec(
        .{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
        &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
    );
    pub const ac_luma: Spec = spec(.{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d }, &.{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    });
    pub const ac_chroma: Spec = spec(.{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 }, &.{
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    });

    fn spec(counts: [16]u8, values: []const u8) Spec {
        var s: Spec = .{ .counts = counts, .values = @splat(0) };
        @memcpy(s.values[0..values.len], values);
        return s;
    }
};

/// Figure F.12: a `size`-bit magnitude as a signed value.
pub inline fn extend(v: u32, size: u5) i32 {
    const x: i32 = @intCast(v);
    if (v < @as(u32, 1) << (size - 1)) return x - (@as(i32, 1) << size) + 1;
    return x;
}

/// Zigzag position to natural order, with 16 more entries mapping to the
/// last coefficient, where a corrupt run that passes position 63 lands in
/// libjpeg-turbo.
pub const natural: [80]u8 = blk: {
    var t: [80]u8 = @splat(63);
    const order = [64]u8{
        0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    };
    @memcpy(t[0..64], &order);
    break :blk t;
};

/// Where an entropy-coded segment ended.
pub const Stop = union(enum) {
    /// Not yet.
    none,
    /// At a marker, whose two bytes the reader has consumed.
    marker: u8,
    /// At the end of the input.
    end,
};

/// Reads bits, most significant first, from the entropy-coded data.
pub const BitReader = struct {
    reader: *Io.Reader,
    /// The bits not yet consumed, from the most significant end.
    acc: u64 = 0,
    /// How many of `acc`'s bits came from the data. Below zero once the
    /// decoder has consumed some of the zero bits after the data's end.
    n: i32 = 0,
    stop: Stop = .none,
    /// Bytes consumed from the reader.
    consumed: u64 = 0,

    /// Tops `acc` up to at least 57 bits of data, unless the data ends.
    pub fn refill(br: *BitReader) error{ReadFailed}!void {
        while (br.n <= 56) {
            if (br.stop != .none) return;
            const buf = br.reader.buffered();
            if (buf.len >= 8) {
                // Up to eight bytes at once when none of them is 0xFF.
                const w = std.mem.readInt(u64, buf[0..8], .big);
                const x = ~w;
                const ff = (x -% 0x0101010101010101) & ~x & 0x8080808080808080;
                // Bytes before the first 0xFF (or a false hit after it,
                // which only stops early), and as many as fit.
                const lead: u32 = @clz(ff) / 8;
                const room: u32 = @intCast(@divTrunc(64 - br.n, 8));
                const take = @min(lead, room);
                if (take > 0) {
                    const width: u7 = @intCast(take * 8);
                    const keep = if (width == 64) w else w & ~(@as(u64, std.math.maxInt(u64)) >> @intCast(width));
                    br.acc |= keep >> @intCast(br.n);
                    br.n += @intCast(width);
                    br.reader.toss(take);
                    br.consumed += take;
                    continue;
                }
            }
            try br.slowByte();
        }
    }

    fn slowByte(br: *BitReader) error{ReadFailed}!void {
        const b = br.reader.takeByte() catch |e| return br.ended(e);
        br.consumed += 1;
        if (b != 0xff) return br.push(b);
        // 0xFF: any further 0xFF fill bytes, then 0 for a data byte or a
        // marker's code.
        while (true) {
            const c = br.reader.takeByte() catch |e| return br.ended(e);
            br.consumed += 1;
            if (c == 0xff) continue;
            if (c == 0) return br.push(0xff);
            br.stop = .{ .marker = c };
            return;
        }
    }

    fn ended(br: *BitReader, e: Io.Reader.Error) error{ReadFailed}!void {
        switch (e) {
            error.EndOfStream => br.stop = .end,
            error.ReadFailed => return error.ReadFailed,
        }
    }

    inline fn push(br: *BitReader, b: u8) void {
        br.acc |= @as(u64, b) << @intCast(56 - br.n);
        br.n += 8;
    }

    /// Ensures at least 32 bits to decode from (data or padding).
    pub inline fn need(br: *BitReader) error{ReadFailed}!void {
        if (br.n < 32) {
            // Inline, the common case of `refill`: eight bytes buffered,
            // and no 0xFF among those that fit.
            const buf = br.reader.buffered();
            if (buf.len >= 8 and br.stop == .none) {
                const w = std.mem.readInt(u64, buf[0..8], .big);
                const x = ~w;
                const ff = (x -% 0x0101010101010101) & ~x & 0x8080808080808080;
                const room: u32 = @as(u32, @intCast(64 - br.n)) / 8;
                if (@clz(ff) / 8 >= room) {
                    const width: u7 = @intCast(room * 8);
                    const keep = if (width == 64) w else w & ~(@as(u64, std.math.maxInt(u64)) >> @intCast(width));
                    br.acc |= keep >> @intCast(br.n);
                    br.n += @intCast(width);
                    br.reader.toss(room);
                    br.consumed += room;
                    return;
                }
            }
            const f = try refilled(br.reader, br.acc, br.n, br.stop, br.consumed);
            br.acc = f.acc;
            br.n = f.n;
            br.stop = f.stop;
            br.consumed = f.consumed;
        }
    }

    const Fill = struct { acc: u64, n: i32, stop: Stop, consumed: u64 };

    /// `refill` on a copy of the state, passed and returned by value, so
    /// that the block decoders' copy of the reader never has its address
    /// taken and stays in registers.
    fn refilled(reader: *Io.Reader, acc: u64, n: i32, stop: Stop, consumed: u64) error{ReadFailed}!Fill {
        var b: BitReader = .{ .reader = reader, .acc = acc, .n = n, .stop = stop, .consumed = consumed };
        try b.refill();
        return .{ .acc = b.acc, .n = b.n, .stop = b.stop, .consumed = b.consumed };
    }

    pub inline fn peek(br: *const BitReader, comptime width: u5) u32 {
        return @intCast(br.acc >> (64 - @as(u7, width)));
    }

    pub inline fn drop(br: *BitReader, k: u32) void {
        br.acc <<= @intCast(k);
        br.n -= @intCast(k);
    }

    /// The next `k` bits, 1 to 16.
    pub inline fn bits(br: *BitReader, k: u32) u32 {
        const v: u32 = @intCast(br.acc >> @intCast(64 - k));
        br.drop(k);
        return v;
    }

    pub inline fn bit(br: *BitReader) u32 {
        return br.bits(1);
    }

    /// The next Huffman code's symbol. Needs 16 bits buffered.
    pub inline fn decode(br: *BitReader, t: *const Table) Error!u8 {
        const e = t.fast[br.peek(fast_bits)];
        if (e != 0) {
            br.drop(e >> 8);
            return @truncate(e);
        }
        const c = try slowCode(br.peek(16), t);
        br.drop(c >> 8);
        return @truncate(c);
    }

    /// The code at the front of the next 16 bits `p`, longer than the
    /// lookahead: `length << 8 | symbol`.
    fn slowCode(p: u32, t: *const Table) Error!u32 {
        var l: u32 = fast_bits + 1;
        while (l <= 16) : (l += 1) {
            if (p < t.limit[l]) break;
        } else return error.BadHuffmanCode;
        const i = @as(i32, @intCast(p >> @intCast(16 - l))) + t.offset[l];
        return l << 8 | t.values[@intCast(i)];
    }

    /// A magnitude category's `size` bits as a signed value (F.2.2.1).
    pub inline fn receive(br: *BitReader, size: u32) i32 {
        if (size == 0) return 0;
        return extend(br.bits(size), @intCast(size));
    }

    /// Discards the bits left in the current byte and every byte buffered,
    /// at the end of a scan or restart interval.
    pub fn reset(br: *BitReader) void {
        br.acc = 0;
        br.n = 0;
    }

    /// Whether the decoder read past the end of the data.
    pub fn overran(br: *const BitReader) bool {
        return br.n < 0;
    }
};

/// Decodes one block of a sequential scan (F.2.2) into `block`, with
/// `pred` the component's DC predictor. It writes the DC and the nonzero
/// AC coefficients, so `block` is zero beforehand but in a scan that
/// decodes a component again.
pub fn sequential(reader: *BitReader, dc: *const Table, ac: *const Table, pred: *i32, block: *[64]i16) Error!void {
    // A copy that never escapes, so it lives in registers.
    var copy = reader.*;
    defer reader.* = copy;
    const br = &copy;
    try br.need();
    const s = try br.decode(dc);
    // The predictor wraps as the reference's int does on corrupt data.
    pred.* +%= br.receive(s);
    block[0] = @truncate(pred.*);
    var k: u32 = 1;
    while (k < 64) {
        try br.need();
        const e = ac.fast_ac[br.peek(fast_bits)];
        if (e >> 16 != 0) {
            br.drop(@as(u32, @intCast(e & 0xff)));
            k += @as(u32, @intCast(e >> 8 & 0xff));
            block[natural[k]] = @truncate(e >> 16);
            k += 1;
            continue;
        }
        const rs: u8 = if (e != 0) blk: {
            br.drop(@as(u32, @intCast(e & 0xff)));
            break :blk @intCast(e >> 8);
        } else try br.decode(ac);
        const r: u32 = rs >> 4;
        const size: u32 = rs & 15;
        if (size != 0) {
            k += r;
            block[natural[k]] = @truncate(br.receive(size));
            k += 1;
        } else {
            if (r != 15) break;
            k += 16;
        }
    }
}

/// H.2.1: a lossless difference, modulo 2^16. Its category is at most 16,
/// and 16 is 32768 with no bits after it.
pub fn difference(reader: *BitReader, t: *const Table) Error!u16 {
    // A copy that never escapes, so it lives in registers.
    var copy = reader.*;
    defer reader.* = copy;
    const br = &copy;
    try br.need();
    const s = try br.decode(t);
    if (s == 16) return 32768;
    return @truncate(@as(u32, @bitCast(br.receive(s))));
}

/// Progressive scans' state that carries across blocks: the run of
/// end-of-band blocks.
pub const Progressive = struct {
    eobrun: u32 = 0,
};

/// G.1.2.1: the first DC scan of a block's successive approximation.
/// Fails when the predictor would overflow 32 bits, as the reference does.
pub fn dcFirst(
    reader: *BitReader,
    dc: *const Table,
    pred: *i32,
    al: u4,
    block: *[64]i16,
) (Error || error{BadCoefficient})!void {
    // A copy that never escapes, so it lives in registers.
    var copy = reader.*;
    defer reader.* = copy;
    const br = &copy;
    try br.need();
    const s = try br.decode(dc);
    const d = br.receive(s);
    pred.* = std.math.add(i32, pred.*, d) catch return error.BadCoefficient;
    block[0] = @truncate(@as(i64, pred.*) << al);
}

/// G.1.2.1: a DC refinement bit.
pub fn dcRefine(reader: *BitReader, al: u4, block: *[64]i16) error{ReadFailed}!void {
    // A copy that never escapes, so it lives in registers.
    var copy = reader.*;
    defer reader.* = copy;
    const br = &copy;
    try br.need();
    if (br.bit() != 0) block[0] |= @as(i16, 1) << al;
}

/// G.1.2.2: the first AC scan of a band.
pub fn acFirst(
    reader: *BitReader,
    ac: *const Table,
    st: *Progressive,
    ss: u32,
    se: u32,
    al: u4,
    block: *[64]i16,
) Error!void {
    // A copy that never escapes, so it lives in registers.
    var copy = reader.*;
    defer reader.* = copy;
    const br = &copy;
    if (st.eobrun > 0) {
        st.eobrun -= 1;
        return;
    }
    var k = ss;
    while (k <= se) : (k += 1) {
        try br.need();
        const rs = try br.decode(ac);
        const r: u32 = rs >> 4;
        const size: u32 = rs & 15;
        if (size != 0) {
            k += r;
            block[natural[k]] = @truncate(@as(i64, br.receive(size)) << al);
        } else if (r == 15) {
            k += 15;
        } else {
            st.eobrun = @as(u32, 1) << @intCast(r);
            if (r != 0) st.eobrun += br.bits(r);
            st.eobrun -= 1;
            break;
        }
    }
}

/// G.1.2.3: an AC refinement scan of a band. A new coefficient's size must
/// be 1 (`BadHuffmanCode` otherwise, where the reference warns).
pub fn acRefine(
    reader: *BitReader,
    ac: *const Table,
    st: *Progressive,
    ss: u32,
    se: u32,
    al: u4,
    block: *[64]i16,
) Error!void {
    // A copy that never escapes, so it lives in registers.
    var copy = reader.*;
    defer reader.* = copy;
    const br = &copy;
    const p1: i16 = @as(i16, 1) << al;
    const m1: i16 = @as(i16, -1) << al;
    var k = ss;
    if (st.eobrun == 0) {
        while (k <= se) : (k += 1) {
            try br.need();
            const rs = try br.decode(ac);
            var r: i32 = rs >> 4;
            const size: u32 = rs & 15;
            var s: i16 = 0;
            if (size != 0) {
                if (size != 1) return error.BadHuffmanCode;
                s = if (br.bit() != 0) p1 else m1;
            } else if (r != 15) {
                st.eobrun = @as(u32, 1) << @intCast(r);
                if (r != 0) st.eobrun += br.bits(@intCast(r));
                break;
            }
            // Skip `r` zero coefficients, refining the nonzero ones passed.
            while (true) {
                const c = &block[natural[k]];
                if (c.* != 0) {
                    try br.need();
                    if (br.bit() != 0 and c.* & p1 == 0) c.* +%= if (c.* >= 0) p1 else m1;
                } else {
                    r -= 1;
                    if (r < 0) break;
                }
                k += 1;
                if (k > se) break;
            }
            if (s != 0) block[natural[k]] = s;
        }
    }
    if (st.eobrun > 0) {
        // The rest of the band, after its last new coefficient.
        while (k <= se) : (k += 1) {
            const c = &block[natural[k]];
            if (c.* != 0) {
                try br.need();
                if (br.bit() != 0 and c.* & p1 == 0) c.* +%= if (c.* >= 0) p1 else m1;
            }
        }
        st.eobrun -= 1;
    }
}

test "table limits" {
    var t: Table = undefined;
    // Two one-bit codes: the second would be all ones.
    var s: Spec = .{ .counts = @splat(0), .values = @splat(0) };
    s.counts[0] = 2;
    try testing.expectError(error.BadHuffmanTable, t.init(&s, .ac));
    s.counts[0] = 1;
    s.counts[1] = 1;
    s.values[1] = 5;
    try t.init(&s, .dc);
    s.values[1] = 16;
    try testing.expectError(error.BadHuffmanTable, t.init(&s, .dc));
    try t.init(&s, .lossless);
    try t.init(&standard.ac_luma, .ac);
    try t.init(&standard.ac_chroma, .ac);
    try t.init(&standard.dc_luma, .dc);
    try t.init(&standard.dc_chroma, .dc);
}

test "bit reader: stuffing, fill bytes, and markers" {
    // A data byte 0xFF (as FF 00, and FF FF 00), then a marker.
    const data = "\x12\xff\x00\x34\xff\xff\x00\x56\xff\xd9";
    var r: Io.Reader = .fixed(data);
    var br: BitReader = .{ .reader = &r };
    try br.refill();
    try testing.expectEqual(Stop{ .marker = 0xd9 }, br.stop);
    try testing.expectEqual(40, br.n);
    try testing.expectEqual(0x12, br.bits(8));
    try testing.expectEqual(0xff, br.bits(8));
    try testing.expectEqual(0x34, br.bits(8));
    try testing.expectEqual(0xff, br.bits(8));
    try testing.expectEqual(0x56, br.bits(8));
    try testing.expect(!br.overran());
    try testing.expectEqual(0, br.bits(1));
    try testing.expect(br.overran());
    try testing.expectEqual(data.len, br.consumed);
}

test "bit reader: the fast path stops at 0xFF" {
    var data: [40]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i * 7 % 255);
    data[13] = 0xff;
    data[14] = 0x00;
    var r: Io.Reader = .fixed(&data);
    var br: BitReader = .{ .reader = &r };
    for (0..38) |i| {
        try br.need();
        try testing.expectEqual(data[if (i < 14) i else i + 1], br.bits(8));
    }
    try testing.expect(!br.overran());
}

test "huffman decoding" {
    var t: Table = undefined;
    try t.init(&standard.dc_luma, .dc);
    // Category 0 is 00, category 11 is 111111110.
    const data = [_]u8{ 0b00111111, 0b11000000 };
    var r: Io.Reader = .fixed(&data);
    var br: BitReader = .{ .reader = &r };
    try br.need();
    try testing.expectEqual(0, try br.decode(&t));
    try testing.expectEqual(11, try br.decode(&t));
}
