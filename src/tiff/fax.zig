//! CCITT bilevel coding, as TIFF uses it (TIFF 6.0 sections 10 and 11):
//! Modified Huffman runs with each row byte-aligned and no EOLs
//! (compression 2), ITU-T T.4 one- and two-dimensional coding with EOLs
//! (compression 3, Group 3), and T.6 two-dimensional coding (compression
//! 4, Group 4). Rows decode one at a time to packed bits, most significant
//! first, white 0 and black 1; the photometric interpretation is the
//! caller's.
//!
//! In Group 3, the bits before each row's EOL are skipped, fill or not, as
//! libtiff skips them; data without EOLs is `error.NoEol`, for the caller
//! to decode again with `no_eol`, as libtiff does. Two or more EOLs in a row
//! (the return to control) end the data. Uncompressed mode is unsupported.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const Error = error{
    /// A code that is not in the tables, or a row whose runs or changes go
    /// past its width or backward.
    BadFax,
    /// The strip's data ended, or reached the return to control, before the
    /// rows did.
    NotEnoughData,
    /// The data switches to uncompressed mode.
    Unsupported,
    /// Group 3 data ends before a row's EOL. libtiff then decodes the strip
    /// again from its start without EOLs; the caller does too, with
    /// `no_eol`.
    NoEol,
    ReadFailed,
};

pub const Kind = enum { mh, g3, g4 };

// T.4 tables 2 and 3: (code, run). Runs below 64 terminate a run; 64 and
// above are makeup codes. The extended makeup codes are both colors'.
const white_codes = [_]struct { []const u8, u16 }{
    .{ "00110101", 0 },     .{ "000111", 1 },       .{ "0111", 2 },         .{ "1000", 3 },
    .{ "1011", 4 },         .{ "1100", 5 },         .{ "1110", 6 },         .{ "1111", 7 },
    .{ "10011", 8 },        .{ "10100", 9 },        .{ "00111", 10 },       .{ "01000", 11 },
    .{ "001000", 12 },      .{ "000011", 13 },      .{ "110100", 14 },      .{ "110101", 15 },
    .{ "101010", 16 },      .{ "101011", 17 },      .{ "0100111", 18 },     .{ "0001100", 19 },
    .{ "0001000", 20 },     .{ "0010111", 21 },     .{ "0000011", 22 },     .{ "0000100", 23 },
    .{ "0101000", 24 },     .{ "0101011", 25 },     .{ "0010011", 26 },     .{ "0100100", 27 },
    .{ "0011000", 28 },     .{ "00000010", 29 },    .{ "00000011", 30 },    .{ "00011010", 31 },
    .{ "00011011", 32 },    .{ "00010010", 33 },    .{ "00010011", 34 },    .{ "00010100", 35 },
    .{ "00010101", 36 },    .{ "00010110", 37 },    .{ "00010111", 38 },    .{ "00101000", 39 },
    .{ "00101001", 40 },    .{ "00101010", 41 },    .{ "00101011", 42 },    .{ "00101100", 43 },
    .{ "00101101", 44 },    .{ "00000100", 45 },    .{ "00000101", 46 },    .{ "00001010", 47 },
    .{ "00001011", 48 },    .{ "01010010", 49 },    .{ "01010011", 50 },    .{ "01010100", 51 },
    .{ "01010101", 52 },    .{ "00100100", 53 },    .{ "00100101", 54 },    .{ "01011000", 55 },
    .{ "01011001", 56 },    .{ "01011010", 57 },    .{ "01011011", 58 },    .{ "01001010", 59 },
    .{ "01001011", 60 },    .{ "00110010", 61 },    .{ "00110011", 62 },    .{ "00110100", 63 },
    .{ "11011", 64 },       .{ "10010", 128 },      .{ "010111", 192 },     .{ "0110111", 256 },
    .{ "00110110", 320 },   .{ "00110111", 384 },   .{ "01100100", 448 },   .{ "01100101", 512 },
    .{ "01101000", 576 },   .{ "01100111", 640 },   .{ "011001100", 704 },  .{ "011001101", 768 },
    .{ "011010010", 832 },  .{ "011010011", 896 },  .{ "011010100", 960 },  .{ "011010101", 1024 },
    .{ "011010110", 1088 }, .{ "011010111", 1152 }, .{ "011011000", 1216 }, .{ "011011001", 1280 },
    .{ "011011010", 1344 }, .{ "011011011", 1408 }, .{ "010011000", 1472 }, .{ "010011001", 1536 },
    .{ "010011010", 1600 }, .{ "011000", 1664 },    .{ "010011011", 1728 },
};

const black_codes = [_]struct { []const u8, u16 }{
    .{ "0000110111", 0 },       .{ "010", 1 },              .{ "11", 2 },               .{ "10", 3 },
    .{ "011", 4 },              .{ "0011", 5 },             .{ "0010", 6 },             .{ "00011", 7 },
    .{ "000101", 8 },           .{ "000100", 9 },           .{ "0000100", 10 },         .{ "0000101", 11 },
    .{ "0000111", 12 },         .{ "00000100", 13 },        .{ "00000111", 14 },        .{ "000011000", 15 },
    .{ "0000010111", 16 },      .{ "0000011000", 17 },      .{ "0000001000", 18 },      .{ "00001100111", 19 },
    .{ "00001101000", 20 },     .{ "00001101100", 21 },     .{ "00000110111", 22 },     .{ "00000101000", 23 },
    .{ "00000010111", 24 },     .{ "00000011000", 25 },     .{ "000011001010", 26 },    .{ "000011001011", 27 },
    .{ "000011001100", 28 },    .{ "000011001101", 29 },    .{ "000001101000", 30 },    .{ "000001101001", 31 },
    .{ "000001101010", 32 },    .{ "000001101011", 33 },    .{ "000011010010", 34 },    .{ "000011010011", 35 },
    .{ "000011010100", 36 },    .{ "000011010101", 37 },    .{ "000011010110", 38 },    .{ "000011010111", 39 },
    .{ "000001101100", 40 },    .{ "000001101101", 41 },    .{ "000011011010", 42 },    .{ "000011011011", 43 },
    .{ "000001010100", 44 },    .{ "000001010101", 45 },    .{ "000001010110", 46 },    .{ "000001010111", 47 },
    .{ "000001100100", 48 },    .{ "000001100101", 49 },    .{ "000001010010", 50 },    .{ "000001010011", 51 },
    .{ "000000100100", 52 },    .{ "000000110111", 53 },    .{ "000000111000", 54 },    .{ "000000100111", 55 },
    .{ "000000101000", 56 },    .{ "000001011000", 57 },    .{ "000001011001", 58 },    .{ "000000101011", 59 },
    .{ "000000101100", 60 },    .{ "000001011010", 61 },    .{ "000001100110", 62 },    .{ "000001100111", 63 },
    .{ "0000001111", 64 },      .{ "000011001000", 128 },   .{ "000011001001", 192 },   .{ "000001011011", 256 },
    .{ "000000110011", 320 },   .{ "000000110100", 384 },   .{ "000000110101", 448 },   .{ "0000001101100", 512 },
    .{ "0000001101101", 576 },  .{ "0000001001010", 640 },  .{ "0000001001011", 704 },  .{ "0000001001100", 768 },
    .{ "0000001001101", 832 },  .{ "0000001110010", 896 },  .{ "0000001110011", 960 },  .{ "0000001110100", 1024 },
    .{ "0000001110101", 1088 }, .{ "0000001110110", 1152 }, .{ "0000001110111", 1216 }, .{ "0000001010010", 1280 },
    .{ "0000001010011", 1344 }, .{ "0000001010100", 1408 }, .{ "0000001010101", 1472 }, .{ "0000001011010", 1536 },
    .{ "0000001011011", 1600 }, .{ "0000001100100", 1664 }, .{ "0000001100101", 1728 },
};

const extended_codes = [_]struct { []const u8, u16 }{
    .{ "00000001000", 1792 },  .{ "00000001100", 1856 },  .{ "00000001101", 1920 },  .{ "000000010010", 1984 },
    .{ "000000010011", 2048 }, .{ "000000010100", 2112 }, .{ "000000010101", 2176 }, .{ "000000010110", 2240 },
    .{ "000000010111", 2304 }, .{ "000000011100", 2368 }, .{ "000000011101", 2432 }, .{ "000000011110", 2496 },
    .{ "000000011111", 2560 },
};

/// A table of `1 << bits` entries indexed by the next `bits` bits: each
/// the code's length in the low 4 bits and its run above, 0 for no code.
fn runTable(comptime bits: u4, comptime codes: anytype) [1 << bits]u16 {
    @setEvalBranchQuota(200_000);
    var t: [1 << bits]u16 = @splat(0);
    for (codes ++ extended_codes) |c| {
        const len = c[0].len;
        var v: u16 = 0;
        for (c[0]) |ch| v = v << 1 | (ch - '0');
        const fill = 1 << (bits - len);
        for (0..fill) |k| {
            const i = (@as(usize, v) << (bits - len)) | k;
            if (t[i] != 0) @compileError("codes overlap");
            t[i] = @as(u16, c[1]) << 4 | len;
        }
    }
    return t;
}

const white_table = runTable(12, white_codes);
const black_table = runTable(13, black_codes);

const Mode = enum(u4) { invalid, pass, horizontal, v0, vr1, vr2, vr3, vl1, vl2, vl3, extension };

// T.4 table 4, indexed by the next 7 bits: mode in the high nibble, code
// length in the low.
const mode_table = blk: {
    const codes = [_]struct { []const u8, Mode }{
        .{ "1", .v0 },        .{ "011", .vr1 },           .{ "010", .vl1 },    .{ "001", .horizontal },
        .{ "0001", .pass },   .{ "000011", .vr2 },        .{ "000010", .vl2 }, .{ "0000011", .vr3 },
        .{ "0000010", .vl3 }, .{ "0000001", .extension },
    };
    var t: [128]u8 = @splat(0);
    for (codes) |c| {
        var v: u8 = 0;
        for (c[0]) |ch| v = v << 1 | (ch - '0');
        const len = c[0].len;
        for (0..1 << (7 - len)) |k| t[(@as(usize, v) << (7 - len)) | k] = @as(u8, @intFromEnum(c[1])) << 4 | len;
    }
    break :blk t;
};

/// Work memory for a row `width` pixels wide: two lists of changes, and
/// room to align them.
pub fn workLen(width: u64) ?u64 {
    const per = std.math.add(u64, width, 4) catch return null;
    const lists = std.math.mul(u64, per, 8) catch return null;
    return std.math.add(u64, lists, 3) catch null;
}

pub const Decoder = struct {
    src: *Io.Reader,
    kind: Kind,
    /// Group 3: rows are tagged one- or two-dimensional.
    two_d: bool,
    width: u32,
    /// Changing elements: positions where the color changes, starting
    /// white to black, followed by three copies of `width`. `ref` is the
    /// row above's.
    ref: []u32,
    cur: []u32,
    bits: u64 = 0,
    /// Valid bits at the top of `bits`.
    nbits: u7 = 0,
    eof: bool = false,
    /// Group 3 data without EOLs, decoded as libtiff decodes it again
    /// after `error.NoEol`: rows follow each other with nothing between.
    no_eol: bool = false,

    pub fn init(src: *Io.Reader, kind: Kind, two_d: bool, width: u32, work: []u8) Decoder {
        const n = @as(usize, width) + 4;
        const pad = std.mem.alignForward(usize, @intFromPtr(work.ptr), 4) - @intFromPtr(work.ptr);
        const words: [*]u32 = @ptrCast(@alignCast(work.ptr + pad));
        const ref = words[0..n];
        // The row above the first is white.
        @memset(ref[0..3], width);
        return .{ .src = src, .kind = kind, .two_d = two_d, .width = width, .ref = ref, .cur = words[n .. 2 * n] };
    }

    /// Reads the data again from the start of `src`, which the caller has
    /// moved back, without EOLs; the row above stays.
    pub fn restart(d: *Decoder) void {
        d.bits = 0;
        d.nbits = 0;
        d.eof = false;
        d.no_eol = true;
    }

    /// Decodes the next row into `dst`, `(width + 7) / 8` bytes.
    pub fn read(d: *Decoder, dst: []u8) Error!void {
        switch (d.kind) {
            .mh => {
                try d.row1d();
                // Each row ends on a byte boundary.
                d.consume(d.nbits % 8);
            },
            .g3 => {
                try d.eol();
                const one_d = !d.two_d or try d.take(1) == 1;
                if (one_d) try d.row1d() else try d.row2d();
            },
            .g4 => try d.row2d(),
        }
        render(d.cur, d.width, dst);
        std.mem.swap([]u32, &d.ref, &d.cur);
    }

    fn fill(d: *Decoder) Error!void {
        while (d.nbits <= 56 and !d.eof) {
            const b = d.src.takeByte() catch |e| switch (e) {
                error.EndOfStream => {
                    d.eof = true;
                    return;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            d.bits |= @as(u64, b) << @intCast(56 - d.nbits);
            d.nbits += 8;
        }
    }

    /// The next `n` bits, zeros past the end of the data.
    fn peekRaw(d: *Decoder, comptime n: u6) Error!u64 {
        if (d.nbits < n) try d.fill();
        return d.bits >> (64 - @as(u7, n));
    }

    /// The next `n` bits of a code. Data that ends partway through them
    /// has zeros added to make `n`, and data that has ended is
    /// `error.NotEnoughData`, as libtiff reads codes.
    fn peek(d: *Decoder, comptime n: u6) Error!u64 {
        const v = try d.peekRaw(n);
        if (d.nbits < n) {
            if (d.nbits == 0) return error.NotEnoughData;
            d.nbits = n;
        }
        return v;
    }

    fn consume(d: *Decoder, n: u7) void {
        d.bits = if (n == 64) 0 else d.bits << @intCast(n);
        d.nbits -= n;
    }

    /// Consumes `n` bits, which must be data.
    fn advance(d: *Decoder, n: u7) Error!void {
        if (n > d.nbits) return error.NotEnoughData;
        d.consume(n);
    }

    fn take(d: *Decoder, comptime n: u6) Error!u64 {
        const v = try d.peek(n);
        try d.advance(n);
        return v;
    }

    /// Skips to the row's EOL and past it, with any bits before it: fill,
    /// or damage that libtiff skips too to find the EOL again. Two EOLs end
    /// the data.
    fn eol(d: *Decoder) Error!void {
        if (d.no_eol) return;
        var eols: u32 = 0;
        while (true) {
            const v = try d.peekRaw(12);
            if (d.nbits == 0) return error.NotEnoughData;
            if (d.nbits < 12) {
                if (eols == 0) return error.NoEol;
                break;
            }
            if (v == 1) {
                d.consume(12);
                eols += 1;
            } else if (v == 0) {
                // Fill bits: keep the EOL's own eleven zeros.
                const lead: u7 = @min(@clz(d.bits), d.nbits);
                d.consume(lead - 11);
            } else if (eols == 0) {
                d.consume(1);
            } else break;
        }
        if (eols >= 2) return error.NotEnoughData;
    }

    /// A run of `black` or white pixels: makeup codes, then a terminating
    /// code.
    fn run(d: *Decoder, black: bool, room: u32) Error!u32 {
        var total: u32 = 0;
        while (true) {
            const e = if (black) black_table[@intCast(try d.peek(13))] else white_table[@intCast(try d.peek(12))];
            if (e == 0) return error.BadFax;
            try d.advance(@intCast(e & 15));
            const r = e >> 4;
            total += r;
            if (total > room) return error.BadFax;
            if (r < 64) return total;
        }
    }

    fn row1d(d: *Decoder) Error!void {
        var pos: u32 = 0;
        var k: usize = 0;
        var black = false;
        while (pos < d.width) {
            if (k + 1 > d.width + 1) return error.BadFax;
            pos += try d.run(black, d.width - pos);
            d.cur[k] = pos;
            k += 1;
            black = !black;
        }
        @memset(d.cur[k..][0..3], d.width);
    }

    fn row2d(d: *Decoder) Error!void {
        const w = d.width;
        const ref = d.ref;
        // a0 is -1 before the row's first pixel.
        var a0: i64 = -1;
        var black = false;
        var j: usize = 0;
        var k: usize = 0;
        while (a0 < w) {
            // b1: the first change on the row above past a0 to the color
            // opposite a0's; changes at even indices are to black.
            while (j > 0 and ref[j - 1] > a0) j -= 1;
            while (ref[j] <= a0) j += 1;
            if ((j & 1 == 1) != black) j += 1;
            const b1: i64 = ref[j];
            const b2: i64 = ref[j + 1];
            const m = mode_table[@intCast(try d.peek(7))];
            if (m == 0) return error.BadFax;
            try d.advance(@intCast(m & 15));
            switch (@as(Mode, @enumFromInt(m >> 4))) {
                .invalid => unreachable,
                .extension => return error.Unsupported,
                .pass => a0 = b2,
                .horizontal => {
                    const start: u32 = @intCast(@max(a0, 0));
                    const r1 = try d.run(black, w - start);
                    const a1 = start + r1;
                    const r2 = try d.run(!black, w - a1);
                    if (k + 2 > w + 1) return error.BadFax;
                    d.cur[k] = a1;
                    d.cur[k + 1] = a1 + r2;
                    k += 2;
                    a0 = a1 + r2;
                },
                else => |v| {
                    const delta: i64 = switch (v) {
                        .v0 => 0,
                        .vr1 => 1,
                        .vr2 => 2,
                        .vr3 => 3,
                        .vl1 => -1,
                        .vl2 => -2,
                        .vl3 => -3,
                        else => unreachable,
                    };
                    // a1 may equal a0, an empty run, which encoders
                    // write and libtiff reads; it may not go back.
                    const a1 = b1 + delta;
                    if (a1 < @max(a0, 0) or a1 > w or k + 1 > w + 1) return error.BadFax;
                    d.cur[k] = @intCast(a1);
                    k += 1;
                    a0 = a1;
                    black = !black;
                },
            }
        }
        @memset(d.cur[k..][0..3], w);
    }
};

/// Writes a row's pixels from its changes: black from each even-indexed
/// change to the next.
fn render(changes: []const u32, width: u32, dst: []u8) void {
    @memset(dst, 0);
    var i: usize = 0;
    while (changes[i] < width) : (i += 2) setBits(dst, changes[i], @min(changes[i + 1], width));
}

fn setBits(dst: []u8, from: u32, to: u32) void {
    if (from >= to) return;
    const first = from / 8;
    const last = (to - 1) / 8;
    const head: u8 = @as(u8, 0xff) >> @intCast(from % 8);
    const tail: u8 = @as(u8, 0xff) << @intCast(7 - (to - 1) % 8);
    if (first == last) {
        dst[first] |= head & tail;
        return;
    }
    dst[first] |= head;
    @memset(dst[first + 1 .. last], 0xff);
    dst[last] |= tail;
}

/// Bits written most significant first, for building test streams.
const TestBits = struct {
    out: std.ArrayList(u8) = .empty,
    acc: u8 = 0,
    n: u3 = 0,

    fn put(t: *TestBits, code: []const u8) !void {
        for (code) |c| {
            t.acc |= @as(u8, @intCast(c - '0')) << (7 - t.n);
            if (t.n == 7) {
                try t.out.append(testing.allocator, t.acc);
                t.acc = 0;
                t.n = 0;
            } else t.n += 1;
        }
    }

    fn runs(t: *TestBits, black: bool, length: u16) !void {
        var left = length;
        while (left >= 64) {
            const m = @min(left / 64 * 64, 2560);
            try t.put(codeFor(black, m));
            left -= m;
        }
        try t.put(codeFor(black, left));
    }

    fn align8(t: *TestBits) !void {
        while (t.n != 0) try t.put("0");
    }

    fn bytes(t: *TestBits) ![]u8 {
        try t.align8();
        return t.out.toOwnedSlice(testing.allocator);
    }
};

fn codeFor(black: bool, r: u16) []const u8 {
    for (if (black) &black_codes else &white_codes) |c| if (c[1] == r) return c[0];
    for (extended_codes) |c| if (c[1] == r) return c[0];
    unreachable;
}

fn testDecode(data: []const u8, kind: Kind, two_d: bool, width: u32, rows: []const []const u8) !void {
    var r: Io.Reader = .fixed(data);
    const work = try testing.allocator.alloc(u8, @intCast(workLen(width).?));
    defer testing.allocator.free(work);
    var d: Decoder = .init(&r, kind, two_d, width, work);
    var out: [64]u8 = undefined;
    for (rows) |want| {
        const row = out[0 .. (width + 7) / 8];
        try d.read(row);
        try testing.expectEqualSlices(u8, want, row);
    }
}

test "the tables are prefix-free and complete" {
    // runTable rejects overlapping codes at compile time; check every run
    // decodes back.
    for (white_codes ++ extended_codes) |c| {
        var v: usize = 0;
        for (c[0]) |ch| v = v << 1 | (ch - '0');
        try testing.expectEqual(c[1], white_table[v << @intCast(12 - c[0].len)] >> 4);
    }
    for (black_codes ++ extended_codes) |c| {
        var v: usize = 0;
        for (c[0]) |ch| v = v << 1 | (ch - '0');
        try testing.expectEqual(c[1], black_table[v << @intCast(13 - c[0].len)] >> 4);
    }
}

test "modified Huffman rows" {
    // 20 pixels: 3 white, 2 black, 15 white; then all white; then a long
    // black run.
    var t: TestBits = .{};
    try t.runs(false, 3);
    try t.runs(true, 2);
    try t.runs(false, 15);
    try t.align8();
    try t.runs(false, 20);
    try t.align8();
    try t.runs(false, 0);
    try t.runs(true, 20);
    const data = try t.bytes();
    defer testing.allocator.free(data);
    try testDecode(data, .mh, false, 20, &.{ &.{ 0x18, 0x00, 0x00 }, &.{ 0, 0, 0 }, &.{ 0xff, 0xff, 0xf0 } });
}

test "group 3 with EOLs, fill bits, damage, and 2D rows; group 4" {
    const w = 100;
    // Row 1 (1D): 10 white, 80 black, 10 white. Row 2 (2D): the same but
    // the black run one pixel longer at each end: VL1, VR1.
    var row1: [13]u8 = @splat(0);
    setBits(&row1, 10, 90);
    var row2: [13]u8 = @splat(0);
    setBits(&row2, 9, 91);
    for ([_]bool{ false, true }) |g4| {
        var t: TestBits = .{};
        if (!g4) {
            // Fill bits, an EOL, the 1D tag.
            try t.put("0000" ++ "000000000001" ++ "1");
            try t.runs(false, 10);
            try t.runs(true, 80);
            try t.runs(false, 10);
            // Damage before the next EOL, skipped to find it.
            try t.put("1101" ++ "000000000001" ++ "0");
        } else {
            // The first row against a white row above: horizontal, then
            // V0 against the imaginary changes at the width.
            try t.put("001");
            try t.runs(false, 10);
            try t.runs(true, 80);
            try t.put("1");
        }
        try t.put("010" ++ "011");
        // The rest of the row matches the row above: V0 at the end.
        try t.put("1");
        const data = try t.bytes();
        defer testing.allocator.free(data);
        try testDecode(data, if (g4) .g4 else .g3, true, w, &.{ &row1, &row2 });
    }
}

test "malformed rows" {
    var r: Io.Reader = .fixed("\x00\x00");
    var work: [8 * 24 + 3]u8 = undefined;
    var d: Decoder = .init(&r, .g4, true, 20, &work);
    var row: [3]u8 = undefined;
    try testing.expectError(error.BadFax, d.read(&row));
    // A white run past the width.
    var t: TestBits = .{};
    try t.runs(false, 30);
    const data = try t.bytes();
    defer testing.allocator.free(data);
    r = .fixed(data);
    d = .init(&r, .mh, false, 20, &work);
    try testing.expectError(error.BadFax, d.read(&row));
    r = .fixed("");
    d = .init(&r, .g3, false, 20, &work);
    try testing.expectError(error.NotEnoughData, d.read(&row));
}

test "group 3 without EOLs: NoEol, then rows back to back with no_eol" {
    const w = 100;
    var row: [13]u8 = @splat(0);
    setBits(&row, 10, 90);
    var t: TestBits = .{};
    for (0..2) |_| {
        try t.runs(false, 10);
        try t.runs(true, 80);
        try t.runs(false, 10);
    }
    const data = try t.bytes();
    defer testing.allocator.free(data);
    var r: Io.Reader = .fixed(data);
    var work: [8 * (w + 4) + 3]u8 = undefined;
    var d: Decoder = .init(&r, .g3, false, w, &work);
    var out: [13]u8 = undefined;
    try testing.expectError(error.NoEol, d.read(&out));
    r = .fixed(data);
    d = .init(&r, .g3, false, w, &work);
    d.no_eol = true;
    for (0..2) |_| {
        try d.read(&out);
        try testing.expectEqualSlices(u8, &row, &out);
    }
}
