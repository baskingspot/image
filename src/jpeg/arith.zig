//! Arithmetic entropy decoding (ITU T.81 Annex D) and the block decoders
//! that use it: sequential scans (F.2.4) and progressive scans (G.1.3).
//! Lossless arithmetic coding (SOF11) is not decoded, as libjpeg-turbo
//! does not decode it.
//!
//! The decoder is the specification's: a 16-bit interval register A, a
//! code register C whose upper 16 bits are compared with A, and a count of
//! the bits left in C's lower byte before the next byte comes in. When the
//! entropy-coded data ends at a marker, or at the end of the input, it is
//! fed zero bytes, as D.2.6 says, and that is not an error: the decisions
//! decoded from them are the encoder's padding. libjpeg-turbo agrees; it
//! warns only when the decoded values themselves are impossible, a run of
//! zeros past the end of the band or a magnitude past 15 bits, which here
//! is `BadArithmeticCode`.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const huffman = @import("huffman.zig");
const natural = huffman.natural;

pub const Error = error{
    ReadFailed,
    /// A decoded value the specification does not allow: a run of zero
    /// coefficients past the end of the band, or a magnitude category
    /// past 15.
    BadArithmeticCode,
};

/// One row of Table D.3: a probability estimate and where it goes after
/// each kind of decision.
const State = struct { qe: u16, lps: u8, mps: u8, switch_mps: bool };

/// Table D.3, and after it a state that never moves, for the decisions
/// the specification codes with a fixed estimate of one half (the signs
/// of AC coefficients and the refinement bits of DC coefficients).
const states = blk: {
    const raw = [_]struct { u16, u8, u8, u1 }{
        .{ 0x5a1d, 1, 1, 1 },     .{ 0x2586, 14, 2, 0 },    .{ 0x1114, 16, 3, 0 },    .{ 0x080b, 18, 4, 0 },
        .{ 0x03d8, 20, 5, 0 },    .{ 0x01da, 23, 6, 0 },    .{ 0x00e5, 25, 7, 0 },    .{ 0x006f, 28, 8, 0 },
        .{ 0x0036, 30, 9, 0 },    .{ 0x001a, 33, 10, 0 },   .{ 0x000d, 35, 11, 0 },   .{ 0x0006, 9, 12, 0 },
        .{ 0x0003, 10, 13, 0 },   .{ 0x0001, 12, 13, 0 },   .{ 0x5a7f, 15, 15, 1 },   .{ 0x3f25, 36, 16, 0 },
        .{ 0x2cf2, 38, 17, 0 },   .{ 0x207c, 39, 18, 0 },   .{ 0x17b9, 40, 19, 0 },   .{ 0x1182, 42, 20, 0 },
        .{ 0x0cef, 43, 21, 0 },   .{ 0x09a1, 45, 22, 0 },   .{ 0x072f, 46, 23, 0 },   .{ 0x055c, 48, 24, 0 },
        .{ 0x0406, 49, 25, 0 },   .{ 0x0303, 51, 26, 0 },   .{ 0x0240, 52, 27, 0 },   .{ 0x01b1, 54, 28, 0 },
        .{ 0x0144, 56, 29, 0 },   .{ 0x00f5, 57, 30, 0 },   .{ 0x00b7, 59, 31, 0 },   .{ 0x008a, 60, 32, 0 },
        .{ 0x0068, 62, 33, 0 },   .{ 0x004e, 63, 34, 0 },   .{ 0x003b, 32, 35, 0 },   .{ 0x002c, 33, 9, 0 },
        .{ 0x5ae1, 37, 37, 1 },   .{ 0x484c, 64, 38, 0 },   .{ 0x3a0d, 65, 39, 0 },   .{ 0x2ef1, 67, 40, 0 },
        .{ 0x261f, 68, 41, 0 },   .{ 0x1f33, 69, 42, 0 },   .{ 0x19a8, 70, 43, 0 },   .{ 0x1518, 72, 44, 0 },
        .{ 0x1177, 73, 45, 0 },   .{ 0x0e74, 74, 46, 0 },   .{ 0x0bfb, 75, 47, 0 },   .{ 0x09f8, 77, 48, 0 },
        .{ 0x0861, 78, 49, 0 },   .{ 0x0706, 79, 50, 0 },   .{ 0x05cd, 48, 51, 0 },   .{ 0x04de, 50, 52, 0 },
        .{ 0x040f, 50, 53, 0 },   .{ 0x0363, 51, 54, 0 },   .{ 0x02d4, 52, 55, 0 },   .{ 0x025c, 53, 56, 0 },
        .{ 0x01f8, 54, 57, 0 },   .{ 0x01a4, 55, 58, 0 },   .{ 0x0160, 56, 59, 0 },   .{ 0x0125, 57, 60, 0 },
        .{ 0x00f6, 58, 61, 0 },   .{ 0x00cb, 59, 62, 0 },   .{ 0x00ab, 61, 63, 0 },   .{ 0x008f, 61, 32, 0 },
        .{ 0x5b12, 65, 65, 1 },   .{ 0x4d04, 80, 66, 0 },   .{ 0x412c, 81, 67, 0 },   .{ 0x37d8, 82, 68, 0 },
        .{ 0x2fe8, 83, 69, 0 },   .{ 0x293c, 84, 70, 0 },   .{ 0x2379, 86, 71, 0 },   .{ 0x1edf, 87, 72, 0 },
        .{ 0x1aa9, 87, 73, 0 },   .{ 0x174e, 72, 74, 0 },   .{ 0x1424, 72, 75, 0 },   .{ 0x119c, 74, 76, 0 },
        .{ 0x0f6b, 74, 77, 0 },   .{ 0x0d51, 75, 78, 0 },   .{ 0x0bb6, 77, 79, 0 },   .{ 0x0a40, 77, 48, 0 },
        .{ 0x5832, 80, 81, 1 },   .{ 0x4d1c, 88, 82, 0 },   .{ 0x438e, 89, 83, 0 },   .{ 0x3bdd, 90, 84, 0 },
        .{ 0x34ee, 91, 85, 0 },   .{ 0x2eae, 92, 86, 0 },   .{ 0x299a, 93, 87, 0 },   .{ 0x2516, 86, 71, 0 },
        .{ 0x5570, 88, 89, 1 },   .{ 0x4ca9, 95, 90, 0 },   .{ 0x44d9, 96, 91, 0 },   .{ 0x3e22, 97, 92, 0 },
        .{ 0x3824, 99, 93, 0 },   .{ 0x32b4, 99, 94, 0 },   .{ 0x2e17, 93, 86, 0 },   .{ 0x56a8, 95, 96, 1 },
        .{ 0x4f46, 101, 97, 0 },  .{ 0x47e5, 102, 98, 0 },  .{ 0x41cf, 103, 99, 0 },  .{ 0x3c3d, 104, 100, 0 },
        .{ 0x375e, 99, 93, 0 },   .{ 0x5231, 105, 102, 0 }, .{ 0x4c0f, 106, 103, 0 }, .{ 0x4639, 107, 104, 0 },
        .{ 0x415e, 103, 99, 0 },  .{ 0x5627, 105, 106, 1 }, .{ 0x50e7, 108, 107, 0 }, .{ 0x4b85, 109, 103, 0 },
        .{ 0x5597, 110, 109, 0 }, .{ 0x504f, 111, 107, 0 }, .{ 0x5a10, 110, 111, 1 }, .{ 0x5522, 112, 109, 0 },
        .{ 0x59eb, 112, 111, 1 },
    };
    var t: [raw.len + 1]State = undefined;
    for (raw, 0..) |r, i| t[i] = .{ .qe = r[0], .lps = r[1], .mps = r[2], .switch_mps = r[3] == 1 };
    t[raw.len] = .{ .qe = 0x5a1d, .lps = raw.len, .mps = raw.len, .switch_mps = false };
    break :blk t;
};

/// A statistics bin: the index of its state in `states` in the low seven
/// bits and its MPS in the top bit. Zero is the initial state.
pub const Bin = u8;
/// The bin of the fixed one-half estimate: it never changes state.
pub const fixed: Bin = states.len - 1;

/// Reads decisions from the entropy-coded data.
pub const Reader = struct {
    reader: *Io.Reader,
    /// The code register: Cx in the upper 16 bits.
    c: u32 = 0,
    /// The interval register. 0x10000 at the start (D.2.7's note).
    a: u32 = 0,
    /// Bits left in C's lower half before the next byte comes in.
    ct: i32 = 0,
    stop: huffman.Stop = .none,
    /// Bytes consumed from the reader.
    consumed: u64 = 0,

    /// Nothing to drop: bytes come in one at a time, as needed.
    pub fn reset(r: *Reader) void {
        _ = r;
    }

    /// Initdec (D.2.7).
    pub fn init(reader: *Io.Reader) error{ReadFailed}!Reader {
        var r: Reader = .{ .reader = reader };
        try r.byteIn();
        r.c <<= 8;
        try r.byteIn();
        r.c <<= 8;
        r.a = 0x10000;
        r.ct = 0;
        return r;
    }

    /// Byte_in and Unstuff_0 (D.2.6): the next data byte into the high
    /// byte of C's lower half, or nothing (a zero byte) once the data has
    /// ended.
    fn byteIn(r: *Reader) error{ReadFailed}!void {
        if (r.stop != .none) return;
        const b = r.reader.takeByte() catch |e| return r.ended(e);
        r.consumed += 1;
        if (b != 0xff) {
            r.c += @as(u32, b) << 8;
            return;
        }
        while (true) {
            const n = r.reader.takeByte() catch |e| return r.ended(e);
            r.consumed += 1;
            if (n == 0xff) continue;
            if (n == 0) {
                r.c += 0xff00;
            } else {
                r.stop = .{ .marker = n };
            }
            return;
        }
    }

    fn ended(r: *Reader, e: Io.Reader.Error) error{ReadFailed}!void {
        switch (e) {
            error.EndOfStream => r.stop = .end,
            error.ReadFailed => return error.ReadFailed,
        }
    }

    /// Decode(S) (D.2.4) for the decision whose statistics are `bin`.
    pub fn decode(r: *Reader, bin: *Bin) error{ReadFailed}!u1 {
        const s = &states[bin.* & 0x7f];
        const mps: u1 = @intCast(bin.* >> 7);
        const qe: u32 = s.qe;
        r.a -= qe;
        var d: u1 = undefined;
        if (r.c >> 16 < r.a) {
            if (r.a >= 0x8000) return mps;
            // Cond_MPS_exchange.
            if (r.a < qe) {
                d = ~mps;
                bin.* = afterLps(bin.*, s);
            } else {
                d = mps;
                bin.* = (bin.* & 0x80) | s.mps;
            }
        } else {
            // Cond_LPS_exchange.
            r.c -= r.a << 16;
            if (r.a < qe) {
                d = mps;
                bin.* = (bin.* & 0x80) | s.mps;
            } else {
                d = ~mps;
                bin.* = afterLps(bin.*, s);
            }
            r.a = qe;
        }
        // Renorm_d (D.2.6).
        while (r.a < 0x8000) {
            if (r.ct == 0) {
                try r.byteIn();
                r.ct = 8;
            }
            r.a <<= 1;
            r.c <<= 1;
            r.ct -= 1;
        }
        return d;
    }

    fn afterLps(bin: Bin, s: *const State) Bin {
        const mps = if (s.switch_mps) (bin & 0x80) ^ 0x80 else bin & 0x80;
        return mps | s.lps;
    }
};

/// The conditioning DAC sets for one table destination (F.1.4.4.1.4,
/// F.1.4.4.2.1), with the defaults.
pub const Conditioning = struct {
    l: u4 = 0,
    u: u4 = 1,
    kx: u8 = 5,
};

/// The statistics areas: one per DC and one per AC table destination,
/// sixteen of each as DAC allows (libjpeg-turbo's limit too), and the bin
/// of the fixed estimate.
pub const Stats = struct {
    dc: [16][dc_bins]Bin,
    ac: [16][ac_bins]Bin,
    fixed: Bin,

    /// Table F.4's 49 bins.
    pub const dc_bins = 49;
    /// Table F.5's 245 bins.
    pub const ac_bins = 245;
};

/// The magnitude of a nonzero value, after its sign: Decode_log2_Sz and
/// Decode_Sz_bits (F.2.4.3.1.2 and .3), with bins from `bins`: `s` is the
/// Sz < 1 decision's, `x1` the Sz < 2 decision's, and `x2` the first of
/// those for Sz < 4 and on, each category's magnitude bits using the bin
/// 14 past its decision's. Returns |V|.
fn magnitude(r: *Reader, bins: []Bin, s: usize, x1: usize, x2: usize) Error!i32 {
    // The leading bit of Sz = |V| - 1.
    var m: u32 = 0;
    var x = x2;
    if (try r.decode(&bins[s]) != 0) {
        m = 1;
        if (try r.decode(&bins[x1]) != 0) {
            m = 2;
            while (try r.decode(&bins[x]) != 0) {
                m <<= 1;
                if (m == 0x8000) return error.BadArithmeticCode;
                x += 1;
            }
        }
    }
    var sz = m;
    if (m > 1) {
        var bit = m >> 1;
        while (bit != 0) : (bit >>= 1) {
            if (try r.decode(&bins[x + 14]) != 0) sz |= bit;
        }
    }
    return @intCast(sz + 1);
}

/// The context S0 for a DC difference (or a lossless one) from the
/// previous difference `da`: its classification (F.1.4.4.1.2) as zero,
/// small positive, small negative, large positive, or large negative,
/// numbered 0 to 4.
pub fn classify(da: i32, c: Conditioning) u8 {
    if (da == 0) return 0;
    const mag: u32 = @abs(da);
    // Magnitudes up to 2^(L-1) count as zero (none when L is 0); past 2^U
    // they are large.
    if (c.l > 0 and mag <= @as(u32, 1) << (c.l - 1)) return 0;
    const large = mag > @as(u32, 1) << c.u;
    return @as(u8, if (large) 3 else 1) + @intFromBool(da < 0);
}

/// Decode_DC_DIFF (F.2.4.1) with Table F.4's bins: `ctx` is the
/// component's classification of its previous difference, updated here.
pub fn dcDiff(r: *Reader, bins: *[Stats.dc_bins]Bin, ctx: *u8, c: Conditioning) Error!i32 {
    const s0: usize = @as(usize, ctx.*) * 4;
    if (try r.decode(&bins[s0]) == 0) {
        ctx.* = 0;
        return 0;
    }
    const negative = try r.decode(&bins[s0 + 1]);
    // SP or SN, then X1 = 20 and X2 = 21 on.
    const mag = try magnitude(r, bins, s0 + 2 + @as(usize, negative), 20, 21);
    const v: i32 = if (negative == 1) -mag else mag;
    ctx.* = classify(v, c);
    return v;
}

/// Decodes one block of a sequential scan (F.2.4) into `block`: `pred` is
/// the component's DC predictor and `ctx` its DC conditioning. It writes
/// the DC and the nonzero AC coefficients, as the Huffman version does.
pub fn sequential(
    r: *Reader,
    stats: *Stats,
    dc: u4,
    ac: u4,
    cond_dc: Conditioning,
    cond_ac: Conditioning,
    pred: *i32,
    ctx: *u8,
    block: *[64]i16,
) Error!void {
    pred.* +%= try dcDiff(r, &stats.dc[dc], ctx, cond_dc);
    block[0] = @truncate(pred.*);
    try acBand(r, stats, ac, cond_ac, 1, 63, 0, block);
}

/// Figure F.20 over the band `ss` to `se` (G.1.3.2 for a progressive
/// first scan), each coefficient shifted left by `al`.
pub fn acBand(
    r: *Reader,
    stats: *Stats,
    ac: u4,
    c: Conditioning,
    ss: u32,
    se: u32,
    al: u4,
    block: *[64]i16,
) Error!void {
    const bins = &stats.ac[ac];
    var k = ss;
    while (k <= se) : (k += 1) {
        // EOB, then V = 0 for each zero in the run.
        if (try r.decode(&bins[3 * (k - 1)]) != 0) return;
        while (try r.decode(&bins[3 * (k - 1) + 1]) == 0) {
            k += 1;
            if (k > se) return error.BadArithmeticCode;
        }
        const negative = try r.decode(&stats.fixed);
        // SP, SN, and X1 are all S0 + 1; X2 is AC_Context(K).
        const s = 3 * (k - 1) + 2;
        const x2: usize = if (k <= c.kx) 189 else 217;
        const mag = try magnitude(r, bins, s, s, x2);
        const v: i32 = if (negative == 1) -mag else mag;
        block[natural[k]] = @truncate(v << al);
    }
}

/// G.1.3.1: the first DC scan of a progressive image. Fails when the
/// predictor would overflow 32 bits, as the Huffman version does.
pub fn dcFirst(
    r: *Reader,
    stats: *Stats,
    dc: u4,
    cond: Conditioning,
    pred: *i32,
    ctx: *u8,
    al: u4,
    block: *[64]i16,
) (Error || error{BadCoefficient})!void {
    const d = try dcDiff(r, &stats.dc[dc], ctx, cond);
    pred.* = std.math.add(i32, pred.*, d) catch return error.BadCoefficient;
    block[0] = @truncate(@as(i64, pred.*) << al);
}

/// G.1.3.1: a DC refinement bit, at the fixed estimate.
pub fn dcRefine(r: *Reader, stats: *Stats, al: u4, block: *[64]i16) Error!void {
    if (try r.decode(&stats.fixed) != 0) block[0] |= @as(i16, 1) << al;
}

/// G.1.3.3: a refinement scan of an AC band (Figures G.10 and G.11,
/// reversed).
pub fn acRefine(r: *Reader, stats: *Stats, ac: u4, ss: u32, se: u32, al: u4, block: *[64]i16) Error!void {
    const bins = &stats.ac[ac];
    const p1: i16 = @as(i16, 1) << al;
    const m1: i16 = @as(i16, -1) << al;
    // The end of the band from the previous scans: no EOB decision comes
    // before it.
    var eobx: u32 = se;
    while (eobx > 0 and block[natural[eobx]] == 0) eobx -= 1;
    var k = ss;
    while (k <= se) : (k += 1) {
        if (k > eobx and try r.decode(&bins[3 * (k - 1)]) != 0) return;
        while (true) {
            const coef = &block[natural[k]];
            if (coef.* != 0) {
                // A coefficient already nonzero: its next bit (SC).
                if (try r.decode(&bins[3 * (k - 1) + 2]) != 0) coef.* +%= if (coef.* < 0) m1 else p1;
                break;
            }
            if (try r.decode(&bins[3 * (k - 1) + 1]) != 0) {
                coef.* = if (try r.decode(&stats.fixed) != 0) m1 else p1;
                break;
            }
            k += 1;
            if (k > se) return error.BadArithmeticCode;
        }
    }
}

test "Table D.3's chains" {
    // Every transition stays in the table, and the fixed state stays put.
    for (states) |s| {
        try testing.expect(s.lps < states.len and s.mps < states.len);
    }
    try testing.expectEqual(fixed, states[fixed].lps);
    try testing.expectEqual(fixed, states[fixed].mps);
}

test "K.4.1's test sequence" {
    // 256 decisions coded with one statistics bin, and the encoder's
    // output, ending at EOI.
    const want = [_]u8{
        0x00, 0x02, 0x00, 0x51, 0x00, 0x00, 0x00, 0xc0, 0x03, 0x52, 0x87, 0x2a, 0xaa, 0xaa, 0xaa, 0xaa,
        0x82, 0xc0, 0x20, 0x00, 0xfc, 0xd7, 0x9e, 0xf6, 0x74, 0xea, 0xab, 0xf7, 0x69, 0x7e, 0xe7, 0x4c,
    };
    const data = [_]u8{
        0x65, 0x5b, 0x51, 0x44, 0xf7, 0x96, 0x9d, 0x51, 0x78, 0x55, 0xbf, 0xff, 0x00, 0xfc, 0x51, 0x84,
        0xc7, 0xce, 0xf9, 0x39, 0x00, 0x28, 0x7d, 0x46, 0x70, 0x8e, 0xcb, 0xc0, 0xf6, 0xff, 0xd9,
    };
    var input: Io.Reader = .fixed(&data);
    var r: Reader = try .init(&input);
    var bin: Bin = 0;
    for (want) |byte| {
        var got: u8 = 0;
        for (0..8) |_| got = got << 1 | try r.decode(&bin);
        try testing.expectEqual(byte, got);
    }
    try testing.expectEqual(huffman.Stop{ .marker = 0xd9 }, r.stop);
}

test "classification of the previous difference" {
    // The defaults: 0 is zero, 1 and 2 small, 3 and on large.
    const d: Conditioning = .{};
    try testing.expectEqual(0, classify(0, d));
    try testing.expectEqual(1, classify(2, d));
    try testing.expectEqual(2, classify(-1, d));
    try testing.expectEqual(3, classify(3, d));
    try testing.expectEqual(4, classify(-3, d));
    // L = 2: magnitudes up to 2 count as zero.
    const c: Conditioning = .{ .l = 2, .u = 3 };
    try testing.expectEqual(0, classify(-2, c));
    try testing.expectEqual(1, classify(3, c));
    try testing.expectEqual(1, classify(8, c));
    try testing.expectEqual(3, classify(9, c));
}
