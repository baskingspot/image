//! VP8 key frames (RFC 6386), the lossy bitstream WebP stores: the boolean
//! entropy decoder, the frame header, macroblock modes and coefficient
//! tokens, dequantization, the inverse transforms, intra prediction, and the
//! loop filter, written from the specification. The container (Decoder.zig)
//! reads the 10-byte frame header (`FrameHeader.parse`); `decode` reads the
//! rest of the chunk and hands each finished luma row, with the two chroma
//! rows nearest it, to a `Sink`.
//!
//! The specification leaves no freedom in reconstruction except where a
//! coefficient or a transform overflows 16 bits, which only a crafted
//! stream does. There this decoder does what libwebp does on x86-64, the
//! oracle (docs/slop/webp.md): dequantized coefficients wrap to 16 bits, the
//! full inverse DCT wraps every intermediate to 16 bits, the transform of a
//! block whose only coefficients are the first three in zigzag order
//! saturates, and a DC-only block and the WHT compute in 32 bits.
//!
//! Partitions are read in the order the file holds them, so the first
//! partition and every token partition but the last are kept in work memory
//! (at most what the chunk holds, and never more than a decoder can read of
//! them), and the last streams from the reader. Work memory (`workLen`) also
//! holds a row of each plane's unfiltered bottom samples for prediction,
//! 24 luma and 16 chroma rows of the frame for the loop filter's reach and
//! the chroma upsampler's, and per-macroblock contexts for one row.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const tables = @import("vp8_tables.zig");

pub const Error = error{
    ReadFailed,
    /// The stream needed bytes past the end of a partition or its chunk.
    Truncated,
    /// The frame is not a shown key frame, its start code or size is wrong,
    /// or its first partition is larger than its chunk.
    BadVp8,
};

/// The 10 bytes at the start of a key frame (section 9.1).
pub const FrameHeader = struct {
    width: u32,
    height: u32,
    /// Bytes in the first partition, after these 10.
    first_part_size: u32,

    /// Checks the frame tag and start code as libwebp does; `chunk_size`
    /// is the chunk's size, which the first partition must be smaller than.
    pub fn parse(b: *const [10]u8, chunk_size: u64) Error!FrameHeader {
        const tag = @as(u32, b[0]) | @as(u32, b[1]) << 8 | @as(u32, b[2]) << 16;
        if (!std.mem.eql(u8, b[3..6], "\x9d\x01\x2a")) return error.BadVp8;
        if (tag & 1 != 0) return error.BadVp8; // an interframe
        if ((tag >> 1) & 7 > 3) return error.BadVp8; // the version
        if ((tag >> 4) & 1 == 0) return error.BadVp8; // not shown
        const first = tag >> 5;
        if (first >= chunk_size) return error.BadVp8;
        const w = std.mem.readInt(u16, b[6..8], .little) & 0x3fff;
        const h = std.mem.readInt(u16, b[8..10], .little) & 0x3fff;
        if (w == 0 or h == 0) return error.BadVp8;
        return .{ .width = w, .height = h, .first_part_size = first };
    }
};

/// Receives the frame's rows in order: luma row `y`, and the chroma rows
/// nearest it and next nearest (the same row at the top and bottom edges),
/// each at least `(width + 1) / 2` samples, for the upsampler.
pub const Sink = struct {
    context: *anyopaque,
    row: *const fn (context: *anyopaque, y: u32, luma: []const u8, near: [2][]const u8, far: [2][]const u8) void,
};

// Bounds on what a decoder can read of a partition. Every boolean shifts at
// most 7 bits out of the decoder, so a partition of n booleans is read no
// further than 7n / 8 bytes plus the decoder's initial 2 and a few ahead.

/// Booleans in a key frame's header at most (section 19.2).
const header_bools = 2 + 99 + 76 + 2 + 37 + 1 + 4 * 8 * 3 * 11 * 9 + 9;
/// Booleans in one macroblock's modes at most: a segment, the skip flag,
/// the luma mode, 16 subblock modes of at most 7, and the chroma mode.
const mode_bools = 2 + 1 + 3 + 16 * 7 + 3;
/// Booleans in one macroblock's tokens at most: 25 blocks of 16 tokens, each
/// at most 7 for the token, 11 extra bits, and the sign.
const token_bools = 25 * 16 * (7 + 11 + 1);
const slack = 16;

fn bytesFor(bools: u64) u64 {
    return bools * 7 / 8 + slack;
}

const max_first_partition = (1 << 19) - 1;

const Layout = struct {
    mbw: usize,
    mbh: usize,
    /// The most of the first partition a decoder can read.
    p0_cap: usize,
    cbuf: usize,
    cbuf_len: usize,
    top_y: usize,
    top_u: usize,
    top_v: usize,
    intra_t: usize,
    nz_t: usize,
    finfo: usize,
    ybuf: usize,
    ubuf: usize,
    vbuf: usize,
    total: usize,

    fn init(width: u32, height: u32, data_len: u64) ?Layout {
        const mbw: u64 = (@as(u64, width) + 15) / 16;
        const mbh: u64 = (@as(u64, height) + 15) / 16;
        const mbs = mbw * mbh;
        const p0 = @min(max_first_partition, bytesFor(header_bools + mode_bools * mbs));
        // Every token partition but the last, each rounded up to whole rows.
        const tokens = bytesFor(token_bools * mbw * (mbh + 7)) + 8 * slack;
        const cbuf_len = @min(data_len, p0 + tokens);
        const sizes = [_]u64{
            cbuf_len,
            16 * mbw,
            8 * mbw,
            8 * mbw,
            4 * mbw,
            2 * mbw,
            @sizeOf(FilterInfo) * mbw,
            24 * 16 * mbw,
            16 * 8 * mbw,
            16 * 8 * mbw,
        };
        var offsets: [sizes.len]u64 = undefined;
        var at: u64 = 0;
        for (sizes, &offsets) |s, *o| {
            o.* = at;
            at = std.mem.alignForward(u64, at + s, 8);
        }
        var l: Layout = undefined;
        const names = .{ "cbuf", "top_y", "top_u", "top_v", "intra_t", "nz_t", "finfo", "ybuf", "ubuf", "vbuf" };
        inline for (names, 0..) |name, i| {
            @field(l, name) = std.math.cast(usize, offsets[i]) orelse return null;
        }
        l.mbw = @intCast(mbw);
        l.mbh = @intCast(mbh);
        l.p0_cap = std.math.cast(usize, p0) orelse return null;
        l.cbuf_len = std.math.cast(usize, cbuf_len) orelse return null;
        l.total = std.math.cast(usize, at) orelse return null;
        return l;
    }
};

/// Bytes of work memory `decode` needs for a `width` by `height` frame whose
/// chunk holds at most `data_len` bytes after the frame header, or null if
/// that overflows `usize`.
pub fn workLen(width: u32, height: u32, data_len: u64) ?usize {
    const l = Layout.init(width, height, data_len) orelse return null;
    return l.total;
}

/// The bytes past a still image's chunk that its last partition may read
/// without consuming them, so the chunks after it can still be walked: what
/// `min_buffer_len` lets any reader peek.
const beyond_max = 64;

/// The boolean entropy decoder (section 7). `range` holds the range less
/// one, and `value` holds `bits + 8` bits, of which the top 8 are compared
/// with the split. A decoder that needs a byte past its partition's end
/// reads zeros and sets `eof`, as libwebp does, which fails the frame.
const Bool = struct {
    value: u64 = 0,
    range: u32 = 255 - 1,
    bits: i32 = -8,
    /// Bytes not yet loaded into `value`.
    win: []const u8,
    /// The last partition streams: bytes still in `reader`.
    reader: ?*Io.Reader = null,
    left: u64 = 0,
    eof: bool = false,
    failed: ?Error = null,
    /// A still image's last partition goes on past its chunk to the end of
    /// the input, as libwebp reads it (`loadTail`).
    tail: bool = false,
    /// The chunk's last bytes, once fewer than 8 are left in it.
    pend: [8]u8 = undefined,
    pend_len: usize = 0,
    /// Bytes past the chunk read but left in the reader.
    beyond: usize = 0,
    /// Bytes past the chunk consumed from the reader.
    over: u64 = 0,

    fn init(b: *Bool) void {
        b.load();
    }

    inline fn load(b: *Bool) void {
        if (b.win.len >= 8) {
            const v = std.mem.readInt(u64, b.win[0..8], .big) >> 8;
            b.value = (b.value << 56) | v;
            b.win = b.win[7..];
            b.bits += 56;
            return;
        }
        b.loadSlow();
    }

    fn loadSlow(b: *Bool) void {
        if (b.win.len + b.left >= 8) {
            // Seven bytes across the reader's windows: libwebp loads seven
            // whenever eight remain in the partition, and on a stream that
            // breaks the coder's interval, what it shifts out depends on it.
            var tmp: [8]u8 = @splat(0);
            var k: usize = 0;
            while (k < 7) {
                if (b.win.len == 0) b.pull();
                if (b.win.len == 0) break;
                const m = @min(7 - k, b.win.len);
                @memcpy(tmp[k..][0..m], b.win[0..m]);
                b.win = b.win[m..];
                k += m;
            }
            if (k == 7) {
                b.value = (b.value << 56) | (std.mem.readInt(u64, &tmp, .big) >> 8);
                b.bits += 56;
                return;
            }
            // The reader failed: the frame fails with it.
            b.value <<= 8;
            b.bits += 8;
            b.eof = true;
            return;
        }
        if (b.tail) return b.loadTail();
        if (b.win.len == 0) b.pull();
        if (b.win.len > 0) {
            b.value = (b.value << 8) | b.win[0];
            b.win = b.win[1..];
            b.bits += 8;
        } else {
            // Past the end: zeros. Only the first time matters.
            b.value <<= 8;
            b.bits += 8;
            b.eof = true;
        }
    }

    /// Past the chunk's last 8 bytes, for a still image's last partition:
    /// libwebp gives it every byte to the end of the input, loading seven
    /// while eight remain and one at a time after. Bytes past the chunk are
    /// peeked, not consumed, while they fit in `beyond_max`.
    fn loadTail(b: *Bool) void {
        const r = b.reader.?;
        if (b.win.len > 0 or b.left > 0) {
            const n = b.win.len;
            @memcpy(b.pend[0..n], b.win);
            b.win = &.{};
            r.readSliceAll(b.pend[n..][0..@intCast(b.left)]) catch |e| {
                b.failed = mapRead(e);
                b.value <<= 8;
                b.bits += 8;
                b.eof = true;
                return;
            };
            b.pend_len = n + @as(usize, @intCast(b.left));
            b.left = 0;
        }
        const want = 8 - b.pend_len;
        if (b.beyond + want > beyond_max) {
            r.toss(b.beyond);
            b.over += b.beyond;
            b.beyond = 0;
        }
        const got = r.peek(b.beyond + want) catch |e| switch (e) {
            error.EndOfStream => r.buffered(),
            error.ReadFailed => {
                b.failed = error.ReadFailed;
                b.value <<= 8;
                b.bits += 8;
                b.eof = true;
                return;
            },
        };
        const more = got[b.beyond..@min(got.len, b.beyond + want)];
        var tmp: [16]u8 = @splat(0);
        @memcpy(tmp[0..b.pend_len], b.pend[0..b.pend_len]);
        @memcpy(tmp[b.pend_len..][0..more.len], more);
        const have = b.pend_len + more.len;
        if (have == 0) {
            b.value <<= 8;
            b.bits += 8;
            b.eof = true;
            return;
        }
        const k: usize = if (have >= 8) 7 else 1;
        if (k == 7) {
            b.value = (b.value << 56) | (std.mem.readInt(u64, tmp[0..8], .big) >> 8);
            b.bits += 56;
        } else {
            b.value = (b.value << 8) | tmp[0];
            b.bits += 8;
        }
        const from_pend = @min(k, b.pend_len);
        @memmove(b.pend[0 .. b.pend_len - from_pend], b.pend[from_pend..b.pend_len]);
        b.pend_len -= from_pend;
        b.beyond += k - from_pend;
    }

    fn pull(b: *Bool) void {
        const r = b.reader orelse return;
        if (b.left == 0 or b.failed != null) return;
        const got = r.peekGreedy(1) catch |e| {
            b.failed = switch (e) {
                error.EndOfStream => error.Truncated,
                error.ReadFailed => error.ReadFailed,
            };
            return;
        };
        const n: usize = @intCast(@min(got.len, b.left));
        b.win = got[0..n];
        r.toss(n);
        b.left -= n;
    }

    inline fn read(b: *Bool, prob: u8) u1 {
        if (b.bits < 0) b.load();
        const shift: u6 = @intCast(b.bits);
        const split = (b.range * prob) >> 8;
        const v: u32 = @truncate(b.value >> shift);
        // As in `Hot.read`: each arm renormalizes on its own.
        if (v > split) {
            b.value -= @as(u64, split + 1) << shift;
            b.renorm(b.range - split);
            return 1;
        }
        b.renorm(split + 1);
        return 0;
    }

    inline fn renorm(b: *Bool, r: u32) void {
        const n: u5 = @clz(@as(u8, @intCast(r)));
        b.range = (r << n) - 1;
        b.bits -= n;
    }

    fn literal(b: *Bool, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | b.read(128);
        return v;
    }

    /// A magnitude of `n` bits, then its sign.
    fn signed(b: *Bool, n: u5) i32 {
        const v: i32 = @intCast(b.literal(n));
        return if (b.read(128) == 1) -v else v;
    }

    /// An optional signed value: a flag, then the value if set.
    fn maybeSigned(b: *Bool, n: u5) i32 {
        return if (b.read(128) == 1) b.signed(n) else 0;
    }

    /// The error that ended the stream, if it has run past its end.
    fn check(b: *const Bool) Error!void {
        if (b.eof) return b.failed orelse error.Truncated;
    }
};

/// A `Bool`'s arithmetic state in locals, for a hot loop: what `read`
/// changes stays in registers, and only a refill touches the `Bool`.
const Hot = struct {
    value: u64,
    range: u32,
    bits: i32,
    b: *Bool,

    fn init(b: *Bool) Hot {
        return .{ .value = b.value, .range = b.range, .bits = b.bits, .b = b };
    }

    fn store(h: *const Hot, b: *Bool) void {
        b.value = h.value;
        b.range = h.range;
        b.bits = h.bits;
    }

    inline fn read(h: *Hot, prob: u8) u1 {
        if (h.bits < 0) {
            h.b.value = h.value;
            h.b.bits = h.bits;
            h.b.load();
            h.value = h.b.value;
            h.bits = h.b.bits;
        }
        const shift: u6 = @intCast(h.bits);
        const split = (h.range * prob) >> 8;
        const v: u32 = @truncate(h.value >> shift);
        if (v > split) {
            // A branch, not a select: a token's bits are mostly the likely
            // one, and a predicted branch does not wait on the comparison.
            // Each arm renormalizes on its own, so the caller's test of the
            // bit folds into this branch.
            @branchHint(.unlikely);
            h.value -= @as(u64, split + 1) << shift;
            h.renorm(h.range - split);
            return 1;
        }
        h.renorm(split + 1);
        return 0;
    }

    /// Takes the new range, not less one, and shifts it back to 128 or more.
    inline fn renorm(h: *Hot, r: u32) void {
        const n: u5 = @clz(@as(u8, @intCast(r)));
        h.range = (r << n) - 1;
        h.bits -= n;
    }

    /// `v`, negated if the next even-odds bit is set, without a branch:
    /// at probability 128 the range always renormalizes by one bit.
    inline fn sign(h: *Hot, v: i32) i32 {
        if (h.bits < 0) {
            h.b.value = h.value;
            h.b.bits = h.bits;
            h.b.load();
            h.value = h.b.value;
            h.bits = h.b.bits;
        }
        const shift: u6 = @intCast(h.bits);
        const split = h.range >> 1;
        const value: u32 = @truncate(h.value >> shift);
        const mask: i32 = @as(i32, @bitCast(split -% value)) >> 31;
        const m: u32 = @bitCast(mask);
        h.bits -= 1;
        h.range = (h.range +% m) | 1;
        h.value -%= @as(u64, (split + 1) & m) << shift;
        return (v ^ mask) - mask;
    }
};

const Quant = struct { y1: [2]i32, y2: [2]i32, uv: [2]i32 };

/// The loop filter's controls for one macroblock (section 15.4); a limit
/// of 0 skips it.
const FilterInfo = extern struct { limit: u8, ilevel: u8, hev: u8, inner: u8 };

const Header = struct {
    update_map: bool = false,
    seg_probs: [3]u8 = .{ 255, 255, 255 },
    /// 0: none, 1: simple, 2: normal.
    filter_type: u2 = 0,
    partitions: u4 = 1,
    quant: [4]Quant = undefined,
    /// Per segment, for 16x16 and for subblock-predicted macroblocks.
    filters: [4][2]FilterInfo = undefined,
    probs: [4][8][3][11]u8 = tables.default_coeff_probs,
    skip_prob: ?u8 = null,
};

fn clampIndex(v: i32, max: i32) usize {
    return @intCast(std.math.clamp(v, 0, max));
}

/// The frame header in the first partition (sections 9.2 to 9.11, 19.2).
fn parseHeader(b: *Bool, h: *Header) Error!void {
    _ = b.read(128); // color space
    _ = b.read(128); // clamping type
    // Segmentation: libwebp's defaults are absolute values of 0.
    var use_segment = false;
    var absolute = true;
    var seg_quant: [4]i32 = @splat(0);
    var seg_lf: [4]i32 = @splat(0);
    if (b.read(128) == 1) {
        use_segment = true;
        h.update_map = b.read(128) == 1;
        if (b.read(128) == 1) {
            absolute = b.read(128) == 1;
            for (&seg_quant) |*q| q.* = b.maybeSigned(7);
            for (&seg_lf) |*f| f.* = b.maybeSigned(6);
        }
        if (h.update_map) {
            for (&h.seg_probs) |*p| p.* = if (b.read(128) == 1) @intCast(b.literal(8)) else 255;
        }
    }
    // The loop filter.
    const simple = b.read(128) == 1;
    const level: i32 = @intCast(b.literal(6));
    const sharpness: i32 = @intCast(b.literal(3));
    var ref_delta: i32 = 0;
    var mode_delta: i32 = 0;
    const use_lf_delta = b.read(128) == 1;
    if (use_lf_delta and b.read(128) == 1) {
        for (0..4) |i| {
            const d = b.maybeSigned(6);
            if (i == 0) ref_delta = d;
        }
        for (0..4) |i| {
            const d = b.maybeSigned(6);
            if (i == 0) mode_delta = d;
        }
    }
    h.filter_type = if (level == 0) 0 else if (simple) 1 else 2;
    h.partitions = @as(u4, 1) << @intCast(b.literal(2));
    // Quantizers.
    const base_q: i32 = @intCast(b.literal(7));
    const dq = [5]i32{ b.maybeSigned(4), b.maybeSigned(4), b.maybeSigned(4), b.maybeSigned(4), b.maybeSigned(4) };
    for (0..4) |s| {
        var q = base_q;
        if (use_segment) {
            q = seg_quant[s];
            if (!absolute) q += base_q;
        }
        const y2ac: i32 = @intCast(@as(u32, tables.ac_qlookup[clampIndex(q + dq[2], 127)]) * 155 / 100);
        h.quant[s] = .{
            .y1 = .{ tables.dc_qlookup[clampIndex(q + dq[0], 127)], tables.ac_qlookup[clampIndex(q, 127)] },
            .y2 = .{ @as(i32, tables.dc_qlookup[clampIndex(q + dq[1], 127)]) * 2, @max(8, y2ac) },
            .uv = .{ tables.dc_qlookup[clampIndex(q + dq[3], 117)], tables.ac_qlookup[clampIndex(q + dq[4], 127)] },
        };
        // Filter strength, as libwebp computes it: deltas, then one clamp.
        var base_level = level;
        if (use_segment) {
            base_level = seg_lf[s];
            if (!absolute) base_level += level;
        }
        for (0..2) |i4x4| {
            var l = base_level;
            if (use_lf_delta) {
                l += ref_delta;
                if (i4x4 == 1) l += mode_delta;
            }
            l = std.math.clamp(l, 0, 63);
            var info: FilterInfo = .{ .limit = 0, .ilevel = 0, .hev = 0, .inner = @intCast(i4x4) };
            if (l > 0) {
                var il = l;
                if (sharpness > 0) {
                    il >>= if (sharpness > 4) 2 else 1;
                    il = @min(il, 9 - sharpness);
                }
                il = @max(il, 1);
                info.ilevel = @intCast(il);
                info.limit = @intCast(2 * l + il);
                info.hev = if (l >= 40) 2 else if (l >= 15) 1 else 0;
            }
            h.filters[s][i4x4] = info;
        }
    }
    _ = b.read(128); // refresh_entropy_probs
    for (0..4) |i| for (0..8) |j| for (0..3) |k| for (0..11) |t| {
        if (b.read(tables.coeff_update_probs[i][j][k][t]) == 1) h.probs[i][j][k][t] = @intCast(b.literal(8));
    };
    h.skip_prob = if (b.read(128) == 1) @intCast(b.literal(8)) else null;
}

// Prediction modes. The 16x16 and chroma modes, and the subblock modes in
// the order of section 11.2, whose first four double as the contexts the
// 16x16 modes leave.
const dc_pred = 0;
const v_pred = 1;
const h_pred = 2;
const tm_pred = 3;
const b_dc = 0;
const b_tm = 1;
const b_ve = 2;
const b_he = 3;
const b_ld = 4;
const b_rd = 5;
const b_vr = 6;
const b_vl = 7;
const b_hd = 8;
const b_hu = 9;

const bmode_tree = [18]i8{
    -b_dc, 2,     -b_tm, 4,     -b_ve, 6,     8,  12,    -b_he,
    10,    -b_rd, -b_vr, -b_ld, 14,    -b_vl, 16, -b_hd, -b_hu,
};

const Mb = struct {
    segment: u2 = 0,
    skip: bool = false,
    /// 16 subblock modes, or null for a 16x16 mode.
    i4x4: bool = false,
    ymode: u8 = 0,
    bmodes: [16]u8 = undefined,
    uvmode: u8 = 0,
};

/// One macroblock's modes from the first partition (section 11, 19.3).
fn parseModes(b: *Bool, h: *const Header, top: *[4]u8, left: *[4]u8, mb: *Mb) void {
    mb.segment = 0;
    if (h.update_map) {
        mb.segment = if (b.read(h.seg_probs[0]) == 1)
            @as(u2, 2) + b.read(h.seg_probs[2])
        else
            b.read(h.seg_probs[1]);
    }
    mb.skip = if (h.skip_prob) |p| b.read(p) == 1 else false;
    mb.i4x4 = b.read(145) == 0;
    if (!mb.i4x4) {
        mb.ymode = if (b.read(156) == 1)
            (if (b.read(128) == 1) tm_pred else h_pred)
        else
            (if (b.read(163) == 1) v_pred else dc_pred);
        const ctx: u8 = switch (mb.ymode) {
            dc_pred => b_dc,
            v_pred => b_ve,
            h_pred => b_he,
            else => b_tm,
        };
        top.* = @splat(ctx);
        left.* = @splat(ctx);
    } else {
        for (0..4) |y| {
            var l = left[y];
            for (0..4) |x| {
                const p = &tables.kf_bmode_probs[top[x]][l];
                var i: i8 = 0;
                while (true) {
                    i = bmode_tree[@as(usize, @intCast(i)) + b.read(p[@as(usize, @intCast(i)) >> 1])];
                    if (i <= 0) break;
                }
                l = @intCast(-i);
                top[x] = l;
                mb.bmodes[y * 4 + x] = l;
            }
            left[y] = l;
        }
    }
    mb.uvmode = if (b.read(142) == 0)
        dc_pred
    else if (b.read(114) == 0)
        v_pred
    else if (b.read(183) == 1)
        tm_pred
    else
        h_pred;
}

const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
const bands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
const cat3456 = [4][]const u8{
    &.{ 173, 148, 140 },
    &.{ 176, 155, 140, 135 },
    &.{ 180, 157, 141, 134, 130 },
    &.{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 },
};

/// A plane type's probabilities by position rather than band.
const BandProbs = [17]*const [3][11]u8;

/// One block's tokens (section 13), dequantized into `out` in raster
/// order and wrapped to 16 bits as libwebp stores them. Returns the
/// position after the last token: `first` when the block is empty.
fn coeffs(br: *Bool, probs: *const BandProbs, ctx: u2, dq: [2]i32, first: u5, out: *[16]i16) u5 {
    var hot: Hot = .init(br);
    defer hot.store(br);
    const b = &hot;
    var n = first;
    var p = &probs[n][ctx];
    while (n < 16) {
        if (b.read(p[0]) == 0) return n; // end of block
        while (b.read(p[1]) == 0) { // a zero
            n += 1;
            if (n == 16) return 16;
            p = &probs[n][0];
        }
        var v: i32 = 1;
        var next: u2 = 1;
        if (b.read(p[2]) != 0) {
            @branchHint(.unlikely);
            v = large(b, p);
            next = 2;
        }
        v = b.sign(v);
        out[zigzag[n]] = @truncate(v * dq[@intFromBool(n > 0)]);
        n += 1;
        if (n == 16) return 16;
        p = &probs[n][next];
    }
    return 16;
}

/// A token's magnitude past 1 (section 13.2): rarer, so kept out of the
/// zero-and-one loop.
inline fn large(b: *Hot, p: *const [11]u8) i32 {
    if (b.read(p[3]) == 0) {
        return if (b.read(p[4]) == 0) 2 else @as(i32, 3) + b.read(p[5]);
    }
    if (b.read(p[6]) == 0) {
        if (b.read(p[7]) == 0) return @as(i32, 5) + b.read(159);
        const v = 7 + 2 * @as(i32, b.read(165));
        return v + b.read(145);
    }
    const bit1 = b.read(p[8]);
    const bit0 = b.read(p[9 + @as(usize, bit1)]);
    const cat = 2 * @as(u3, bit1) + bit0;
    var e: i32 = 0;
    for (cat3456[cat]) |q| e = 2 * e + b.read(q);
    return e + 3 + (@as(i32, 8) << cat);
}

/// The inverse WHT (section 14.3), in 32 bits as libwebp computes it, into
/// the DC of each luma block.
fn inverseWht(in: *const [16]i16, out: *[16][16]i16) void {
    var tmp: [16]i32 = undefined;
    for (0..4) |i| {
        const a0 = @as(i32, in[0 + i]) + in[12 + i];
        const a1 = @as(i32, in[4 + i]) + in[8 + i];
        const a2 = @as(i32, in[4 + i]) - in[8 + i];
        const a3 = @as(i32, in[0 + i]) - in[12 + i];
        tmp[0 + i] = a0 + a1;
        tmp[8 + i] = a0 - a1;
        tmp[4 + i] = a3 + a2;
        tmp[12 + i] = a3 - a2;
    }
    for (0..4) |i| {
        const dc = tmp[0 + i * 4] + 3;
        const a0 = dc + tmp[3 + i * 4];
        const a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
        const a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
        const a3 = dc - tmp[3 + i * 4];
        out[i * 4 + 0][0] = @truncate((a0 + a1) >> 3);
        out[i * 4 + 1][0] = @truncate((a3 + a2) >> 3);
        out[i * 4 + 2][0] = @truncate((a0 - a1) >> 3);
        out[i * 4 + 3][0] = @truncate((a3 - a2) >> 3);
    }
}

fn mulhi(x: i16, k: i16) i16 {
    return @intCast((@as(i32, x) * k) >> 16);
}

fn clamp255(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// The inverse DCT of section 14.4 added to `dst`, every intermediate
/// wrapped to 16 bits, four lanes at a time: the first pass runs down the
/// columns, the second across the rows of its transpose.
fn idctFull(in: *const [16]i16, dst: []u8, stride: usize) void {
    const V = @Vector(4, i16);
    const k1: i16 = 20091;
    const k2: i16 = -30068; // 35468 - 65536
    const rows: [4]V = @bitCast(in.*);
    const t = transpose4(pass(rows[0], rows[1], rows[2], rows[3], k1, k2));
    const o = transpose4(pass(t[0] +% @as(V, @splat(4)), t[1], t[2], t[3], k1, k2));
    for (0..4) |r| {
        const row = dst[r * stride ..][0..4];
        const px: @Vector(4, i16) = row.*;
        const sum = px + (o[r] >> @splat(3));
        row.* = @as(@Vector(4, u8), @intCast(@min(@max(sum, @as(V, @splat(0))), @as(V, @splat(255)))));
    }
}

/// One pass of the inverse DCT over four lanes.
inline fn pass(
    x0: @Vector(4, i16),
    x1: @Vector(4, i16),
    x2: @Vector(4, i16),
    x3: @Vector(4, i16),
    k1: i16,
    k2: i16,
) [4]@Vector(4, i16) {
    const a = x0 +% x2;
    const b = x0 -% x2;
    const c = (mulhiV(x1, k2) -% mulhiV(x3, k1)) +% (x1 -% x3);
    const d = (mulhiV(x1, k1) +% mulhiV(x3, k2)) +% (x1 +% x3);
    return .{ a +% d, b +% c, b -% c, a -% d };
}

inline fn mulhiV(x: @Vector(4, i16), k: i16) @Vector(4, i16) {
    const W = @Vector(4, i32);
    return @truncate((@as(W, x) * @as(W, @splat(k))) >> @splat(16));
}

inline fn transpose4(m: [4]@Vector(4, i16)) [4]@Vector(4, i16) {
    const all: @Vector(16, i16) = @bitCast(m);
    const t = @shuffle(i16, all, undefined, [16]i32{ 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15 });
    return @bitCast(t);
}

fn mul1(a: i32) i32 {
    return ((a * 20091) >> 16) + a;
}

fn mul2(a: i32) i32 {
    return (a * 35468) >> 16;
}

/// Adds `v` to a row of four pixels, clamped.
inline fn addRow(row: *[4]u8, v: @Vector(4, i32)) void {
    const W = @Vector(4, i32);
    const px: @Vector(4, u8) = row.*;
    const sum = @as(W, px) + v;
    row.* = @as(@Vector(4, u8), @intCast(@min(@max(sum, @as(W, @splat(0))), @as(W, @splat(255)))));
}

/// The inverse DCT of a block whose only coefficients are 0, 1, and 4
/// (raster order), in 32 bits, as libwebp's x86 build runs it: its
/// products are not wrapped to 16 bits as the full transform's are.
fn idctAc3(in: *const [16]i16, dst: []u8, stride: usize) void {
    const W = @Vector(4, i32);
    const a: i32 = @as(i32, in[0]) + 4;
    const c4 = mul2(in[4]);
    const d4 = mul1(in[4]);
    const c1 = mul2(in[1]);
    const d1 = mul1(in[1]);
    const cd: W = .{ d1, c1, -c1, -d1 };
    const vert = [4]i32{ d4, c4, -c4, -d4 };
    for (0..4) |r| addRow(dst[r * stride ..][0..4], (@as(W, @splat(a + vert[r])) + cd) >> @splat(3));
}

/// The inverse DCT of a block with only a DC coefficient, in 32 bits.
fn idctDc(in: *const [16]i16, dst: []u8, stride: usize) void {
    const dc: @Vector(4, i32) = @splat((@as(i32, in[0]) + 4) >> 3);
    for (0..4) |r| addRow(dst[r * stride ..][0..4], dc);
}

/// How much of a block's transform is needed, as libwebp chooses: 3 for
/// coefficients past the third in zigzag order, 2 for some among the first
/// three, 1 for a nonzero DC alone, 0 for none.
fn nzCode(nz: u5, dc: i16) u2 {
    return if (nz > 3) 3 else if (nz > 1) 2 else @intFromBool(dc != 0);
}

fn transform(code: u2, in: *const [16]i16, dst: []u8, stride: usize) void {
    switch (code) {
        3 => idctFull(in, dst, stride),
        2 => idctAc3(in, dst, stride),
        1 => idctDc(in, dst, stride),
        0 => {},
    }
}

// The reconstruction scratch for one macroblock: rows -1 to 15 and columns
// -1 to 19 of luma (the row above, the column to the left, and four above
// and to the right), and rows -1 to 7 and columns -1 to 7 of each chroma
// plane, so prediction addresses its neighbors as in the frame (section 12).
const ys = 32;
const y0 = ys + 8;
const cs = 16;
const c0 = cs + 8;

const Scratch = struct {
    y: [ys * 17]u8 = undefined,
    u: [cs * 9]u8 = undefined,
    v: [cs * 9]u8 = undefined,
};

fn avg2(x: u8, y: u8) u8 {
    return @intCast((@as(u16, x) + y + 1) >> 1);
}

fn avg3(x: u8, y: u8, z: u8) u8 {
    return @intCast((@as(u16, x) + 2 * @as(u16, y) + z + 2) >> 2);
}

/// A 16x16 or 8x8 block's prediction (sections 12.2, 12.3), `n` wide, at
/// `at` in `buf` with stride `s`. DC prediction averages only the edges
/// inside the frame.
fn predictBlock(comptime n: usize, buf: []u8, at: usize, s: usize, mode: u8, has_top: bool, has_left: bool) void {
    const shift = std.math.log2_int(usize, n);
    switch (mode) {
        dc_pred => {
            var sum: u32 = 0;
            var v: u8 = 128;
            // The sums in vectors of n bytes: a plain loop vectorizes to
            // 512 bits (see `toRgbVec` in yuv.zig).
            const W = @Vector(n, u16);
            const top: W = @as(@Vector(n, u8), buf[at - s ..][0..n].*);
            var left_px: [n]u8 = undefined;
            inline for (0..n) |i| left_px[i] = buf[at + i * s - 1];
            const left: W = @as(@Vector(n, u8), left_px);
            if (has_top and has_left) {
                sum = @reduce(.Add, top + left);
                v = @intCast((sum + n) >> (shift + 1));
            } else if (has_top) {
                sum = @reduce(.Add, top);
                v = @intCast((sum + n / 2) >> shift);
            } else if (has_left) {
                sum = @reduce(.Add, left);
                v = @intCast((sum + n / 2) >> shift);
            }
            for (0..n) |r| @memset(buf[at + r * s ..][0..n], v);
        },
        v_pred => for (0..n) |r| @memcpy(buf[at + r * s ..][0..n], buf[at - s ..][0..n]),
        h_pred => for (0..n) |r| @memset(buf[at + r * s ..][0..n], buf[at + r * s - 1]),
        else => {
            // In 16-bit lanes: l + top is within ±510. Wider lanes would
            // make a 512-bit vector for n = 16 (see `toRgbVec` in yuv.zig).
            const V = @Vector(n, i16);
            const top: V = @as(@Vector(n, u8), buf[at - s ..][0..n].*);
            const p: i16 = buf[at - s - 1];
            for (0..n) |r| {
                const l: V = @splat(@as(i16, buf[at + r * s - 1]) - p);
                const px = @min(@max(top + l, @as(V, @splat(0))), @as(V, @splat(255)));
                buf[at + r * s ..][0..n].* = @as(@Vector(n, u8), @intCast(px));
            }
        },
    }
}

/// A 4x4 subblock's prediction (section 12.3) at `at` in the luma scratch.
fn predictSub(buf: *[ys * 17]u8, at: usize, mode: u8) void {
    const s = ys;
    // a: P, then the row above with the four above and to the right.
    var a: [9]u8 = undefined;
    @memcpy(&a, buf[at - s - 1 ..][0..9]);
    const p = a[0];
    const above = a[1..9];
    const left = [4]u8{ buf[at - 1], buf[at + s - 1], buf[at + 2 * s - 1], buf[at + 3 * s - 1] };
    // edge[0..8]: left[3], left[2], left[1], left[0], P, above[0..3].
    const edge = [9]u8{ left[3], left[2], left[1], left[0], p, above[0], above[1], above[2], above[3] };
    var B: [4][4]u8 = undefined;
    switch (mode) {
        b_dc => {
            var v: u32 = 4;
            for (0..4) |i| v += @as(u32, above[i]) + left[i];
            B = @splat(@splat(@intCast(v >> 3)));
        },
        b_tm => for (0..4) |r| for (0..4) |c| {
            B[r][c] = clamp255(@as(i32, left[r]) + above[c] - p);
        },
        b_ve => for (0..4) |c| {
            const v = avg3(if (c == 0) p else above[c - 1], above[c], above[c + 1]);
            for (0..4) |r| B[r][c] = v;
        },
        b_he => {
            B[0] = @splat(avg3(p, left[0], left[1]));
            B[1] = @splat(avg3(left[0], left[1], left[2]));
            B[2] = @splat(avg3(left[1], left[2], left[3]));
            B[3] = @splat(avg3(left[2], left[3], left[3]));
        },
        b_ld => for (0..4) |r| for (0..4) |c| {
            const i = r + c;
            B[r][c] = if (i == 6) avg3(above[6], above[7], above[7]) else avg3(above[i], above[i + 1], above[i + 2]);
        },
        b_rd => for (0..4) |r| for (0..4) |c| {
            // (r, c) lies on the diagonal through edge[4 - r + c].
            const i = 4 + c - r;
            B[r][c] = avg3(edge[i - 1], edge[i], edge[i + 1]);
        },
        b_vr => {
            B[3][0] = avg3(edge[1], edge[2], edge[3]);
            B[2][0] = avg3(edge[2], edge[3], edge[4]);
            B[3][1] = avg3(edge[3], edge[4], edge[5]);
            B[1][0] = B[3][1];
            B[2][1] = avg2(edge[4], edge[5]);
            B[0][0] = B[2][1];
            B[3][2] = avg3(edge[4], edge[5], edge[6]);
            B[1][1] = B[3][2];
            B[2][2] = avg2(edge[5], edge[6]);
            B[0][1] = B[2][2];
            B[3][3] = avg3(edge[5], edge[6], edge[7]);
            B[1][2] = B[3][3];
            B[2][3] = avg2(edge[6], edge[7]);
            B[0][2] = B[2][3];
            B[1][3] = avg3(edge[6], edge[7], edge[8]);
            B[0][3] = avg2(edge[7], edge[8]);
        },
        b_vl => {
            B[0][0] = avg2(above[0], above[1]);
            B[1][0] = avg3(above[0], above[1], above[2]);
            B[2][0] = avg2(above[1], above[2]);
            B[0][1] = B[2][0];
            B[1][1] = avg3(above[1], above[2], above[3]);
            B[3][0] = B[1][1];
            B[2][1] = avg2(above[2], above[3]);
            B[0][2] = B[2][1];
            B[3][1] = avg3(above[2], above[3], above[4]);
            B[1][2] = B[3][1];
            B[2][2] = avg2(above[3], above[4]);
            B[0][3] = B[2][2];
            B[3][2] = avg3(above[3], above[4], above[5]);
            B[1][3] = B[3][2];
            B[2][3] = avg3(above[4], above[5], above[6]);
            B[3][3] = avg3(above[5], above[6], above[7]);
        },
        b_hd => {
            B[3][0] = avg2(edge[0], edge[1]);
            B[3][1] = avg3(edge[0], edge[1], edge[2]);
            B[2][0] = avg2(edge[1], edge[2]);
            B[3][2] = B[2][0];
            B[2][1] = avg3(edge[1], edge[2], edge[3]);
            B[3][3] = B[2][1];
            B[2][2] = avg2(edge[2], edge[3]);
            B[1][0] = B[2][2];
            B[2][3] = avg3(edge[2], edge[3], edge[4]);
            B[1][1] = B[2][3];
            B[1][2] = avg2(edge[3], edge[4]);
            B[0][0] = B[1][2];
            B[1][3] = avg3(edge[3], edge[4], edge[5]);
            B[0][1] = B[1][3];
            B[0][2] = avg3(edge[4], edge[5], edge[6]);
            B[0][3] = avg3(edge[5], edge[6], edge[7]);
        },
        else => { // b_hu
            B[0][0] = avg2(left[0], left[1]);
            B[0][1] = avg3(left[0], left[1], left[2]);
            B[0][2] = avg2(left[1], left[2]);
            B[1][0] = B[0][2];
            B[0][3] = avg3(left[1], left[2], left[3]);
            B[1][1] = B[0][3];
            B[1][2] = avg2(left[2], left[3]);
            B[2][0] = B[1][2];
            B[1][3] = avg3(left[2], left[3], left[3]);
            B[2][1] = B[1][3];
            B[2][2] = left[3];
            B[2][3] = left[3];
            B[3] = @splat(left[3]);
        },
    }
    for (0..4) |r| @memcpy(buf[at + r * s ..][0..4], &B[r]);
}

// The loop filter (section 15), on 16 segments at once: the 16 of a luma
// edge, or the 8 of a U edge and the 8 of the V edge beside it. A segment's
// eight pixels p3 p2 p1 p0 | q0 q1 q2 q3 are loaded into `Seg.v[0..8]`,
// lane by lane, as signed values (pixel - 128).

const lanes = 16;
const B16 = @Vector(lanes, u8);
/// Pixels less 128, where the filter's arithmetic happens: every clamp of
/// section 15.2 to a signed byte is a saturating byte operation.
const S16 = @Vector(lanes, i8);
const Mask = @Vector(lanes, bool);

/// Eight pixels across an edge, p3 to q3, in 16 lanes.
const Seg = struct {
    v: [8]B16,

    /// A horizontal edge at `at`: segments run down, one per column.
    fn loadRows(buf: []const u8, at: usize, stride: usize) Seg {
        var s: Seg = undefined;
        for (0..8) |k| s.v[k] = buf[at + k * stride - 4 * stride ..][0..lanes].*;
        return s;
    }

    fn storeRows(s: *const Seg, buf: []u8, at: usize, stride: usize) void {
        for (1..7) |k| buf[at + k * stride - 4 * stride ..][0..lanes].* = s.v[k];
    }

    /// The horizontal edges of U and V at `at`, side by side.
    fn loadRows2(u: []const u8, v: []const u8, at: usize, stride: usize) Seg {
        var s: Seg = undefined;
        for (0..8) |k| {
            const o = at + k * stride - 4 * stride;
            s.v[k] = pair(u[o..], v[o..]);
        }
        return s;
    }

    fn storeRows2(s: *const Seg, u: []u8, v: []u8, at: usize, stride: usize) void {
        for (1..7) |k| {
            const o = at + k * stride - 4 * stride;
            store8(u[o..], s.v[k], 0);
            store8(v[o..], s.v[k], 1);
        }
    }

    /// A vertical edge at `at`: segments run across, one per row; `rows`
    /// gives each lane's eight pixels. The 16 by 8 transpose is four rounds
    /// of interleaving 16-byte vectors, by bytes, then 2, 4, and 8 bytes.
    fn loadCols(rows: [lanes][]const u8) Seg {
        // Rows i and i + 8 share a vector, so the first round's low halves
        // pair rows 0 to 7 and its high halves rows 8 to 15.
        var r: [8]B16 = undefined;
        for (&r, 0..) |*v, i| v.* = pair(rows[i], rows[i + 8]);
        var a: [8]B16 = undefined;
        for (0..4) |j| {
            a[j] = zip(u8, r[2 * j], r[2 * j + 1], false);
            a[4 + j] = zip(u8, r[2 * j], r[2 * j + 1], true);
        }
        var b: [4][2]B16 = undefined;
        for (&b, 0..) |*v, j| {
            v.* = .{ zip(u16, a[2 * j], a[2 * j + 1], false), zip(u16, a[2 * j], a[2 * j + 1], true) };
        }
        var s: Seg = undefined;
        inline for (0..2) |h| inline for (0..2) |q| {
            const top = zip(u32, b[0][h], b[1][h], q == 1);
            const bottom = zip(u32, b[2][h], b[3][h], q == 1);
            inline for (0..2) |e| s.v[4 * h + 2 * q + e] = zip(u64, top, bottom, e == 1);
        };
        return s;
    }

    fn storeCols(s: *const Seg, rows: [lanes][]u8) void {
        const t = s.v;
        inline for (0..2) |half| {
            var e: [4]B16 = undefined;
            for (&e, 0..) |*v, m| v.* = zip(u8, t[2 * m], t[2 * m + 1], half == 1);
            inline for (0..2) |sub| {
                const f0 = zip(u16, e[0], e[1], sub == 1);
                const f1 = zip(u16, e[2], e[3], sub == 1);
                inline for (0..2) |q| {
                    const g = zip(u32, f0, f1, q == 1);
                    const i = 8 * half + 4 * sub + 2 * q;
                    store8(rows[i], g, 0);
                    store8(rows[i + 1], g, 1);
                }
            }
        }
    }
};

/// Eight bytes at `a` and eight at `b` in one vector, built in registers:
/// a vector loaded from two narrower stores waits for both to retire.
fn pair(a: []const u8, b: []const u8) B16 {
    const lo: u64 = @bitCast(a[0..8].*);
    const hi: u64 = @bitCast(b[0..8].*);
    return @bitCast(@Vector(2, u64){ lo, hi });
}

/// Half `half` of `v` to eight bytes at `p`.
fn store8(p: []u8, v: B16, comptime half: u1) void {
    const q: @Vector(2, u64) = @bitCast(v);
    p[0..8].* = @bitCast(q[half]);
}

/// Interleaves the low (or high) halves of `a` and `b`, as elements of
/// type `E`.
fn zip(comptime E: type, a: B16, b: B16, comptime hi: bool) B16 {
    const n = 16 / @sizeOf(E);
    const V = @Vector(n, E);
    const mask = comptime blk: {
        var m: [n]i32 = undefined;
        const base = if (hi) n / 2 else 0;
        for (0..n / 2) |i| {
            m[2 * i] = @intCast(base + i);
            m[2 * i + 1] = ~@as(i32, @intCast(base + i));
        }
        break :blk m;
    };
    return @bitCast(@shuffle(E, @as(V, @bitCast(a)), @as(V, @bitCast(b)), mask));
}

fn signed(v: B16) S16 {
    return @bitCast(v ^ @as(B16, @splat(0x80)));
}

fn unsigned(v: S16) B16 {
    return @as(B16, @bitCast(v)) ^ @as(B16, @splat(0x80));
}

fn absDiff(a: B16, b: B16) B16 {
    return (a -| b) | (b -| a);
}

fn splat(v: u32) B16 {
    return @splat(@intCast(@min(v, 255)));
}

fn none() Mask {
    return @splat(false);
}

/// 2|p0 - q0| + |p1 - q1| / 2 <= limit: the edge test of every filter.
/// A sum that saturates exceeds every limit, which is at most 193.
fn edgeMask(s: *const Seg, limit: u32) Mask {
    const d0 = absDiff(s.v[3], s.v[4]);
    const d = (d0 +| d0) +| (absDiff(s.v[2], s.v[5]) >> @splat(1));
    return d <= splat(limit);
}

fn interiorMask(s: *const Seg, il: u32) Mask {
    const l = splat(il);
    var m = absDiff(s.v[0], s.v[1]);
    for ([_]usize{ 1, 2, 5, 6 }) |k| m = @max(m, absDiff(s.v[k], s.v[k + 1]));
    m = @max(m, absDiff(s.v[4], s.v[5]));
    return m <= l;
}

fn hevMask(s: *const Seg, thresh: u32) Mask {
    return @max(absDiff(s.v[2], s.v[3]), absDiff(s.v[5], s.v[4])) > splat(thresh);
}

/// c(c(p1 - q1) + 3(q0 - p0)), the outer taps only where `outer` is set.
/// Saturating q0 - p0 first, then adding it three times, gives the same
/// clamp: the partial sums move one way.
fn baseDelta(p1: S16, p0: S16, q0: S16, q1: S16, outer: Mask) S16 {
    const d = q0 -| p0;
    const taps = @select(i8, outer, p1 -| q1, @as(S16, @splat(0)));
    return taps +| d +| d +| d;
}

/// common_adjust where `mask` is set, with the outer taps where `outer`
/// is; returns the adjustment made to q0, 0 outside `mask`.
fn commonAdjust(s: *Seg, mask: Mask, outer: Mask) S16 {
    const p0 = signed(s.v[3]);
    const q0 = signed(s.v[4]);
    const a0 = @select(i8, mask, baseDelta(signed(s.v[2]), p0, q0, signed(s.v[5]), outer), @as(S16, @splat(0)));
    const b = (a0 +| @as(S16, @splat(3))) >> @splat(3);
    const a = (a0 +| @as(S16, @splat(4))) >> @splat(3);
    s.v[4] = unsigned(q0 -| a);
    s.v[3] = unsigned(p0 +| b);
    return a;
}

fn simpleFilter(s: *Seg, limit: u32) void {
    _ = commonAdjust(s, edgeMask(s, limit), @splat(true));
}

fn subblockFilter(s: *Seg, limit: u32, il: u32, thresh: u32) void {
    const mask = @select(bool, edgeMask(s, limit), interiorMask(s, il), none());
    const hv = hevMask(s, thresh);
    const a = (commonAdjust(s, mask, hv) +| @as(S16, @splat(1))) >> @splat(1);
    const inner = @select(bool, mask, !hv, none());
    const d = @select(i8, inner, a, @as(S16, @splat(0)));
    s.v[5] = unsigned(signed(s.v[5]) -| d);
    s.v[2] = unsigned(signed(s.v[2]) +| d);
}

fn mbFilter(s: *Seg, limit: u32, il: u32, thresh: u32) void {
    const mask = @select(bool, edgeMask(s, limit), interiorMask(s, il), none());
    const hv = hevMask(s, thresh);
    const p2 = signed(s.v[1]);
    const p1 = signed(s.v[2]);
    const p0 = signed(s.v[3]);
    const q0 = signed(s.v[4]);
    const q1 = signed(s.v[5]);
    const q2 = signed(s.v[6]);
    // Where the variance is high, the simple filter.
    _ = commonAdjust(s, @select(bool, mask, hv, none()), @splat(true));
    const wide = @select(bool, mask, !hv, none());
    const W = @Vector(lanes, i16);
    const w: W = @select(i8, wide, baseDelta(p1, p0, q0, q1, @splat(true)), @as(S16, @splat(0)));
    // At most 27 in size: no clamp needed.
    const a0: S16 = @intCast((@as(W, @splat(27)) * w + @as(W, @splat(63))) >> @splat(7));
    const a1: S16 = @intCast((@as(W, @splat(18)) * w + @as(W, @splat(63))) >> @splat(7));
    const a2: S16 = @intCast((@as(W, @splat(9)) * w + @as(W, @splat(63))) >> @splat(7));
    s.v[4] = @select(u8, wide, unsigned(q0 -| a0), s.v[4]);
    s.v[3] = @select(u8, wide, unsigned(p0 +| a0), s.v[3]);
    s.v[5] = unsigned(q1 -| a1);
    s.v[2] = unsigned(p1 +| a1);
    s.v[6] = unsigned(q2 -| a2);
    s.v[1] = unsigned(p2 +| a2);
}

const EdgeKind = enum { simple, subblock, mb };

fn filterSeg(comptime kind: EdgeKind, s: *Seg, limit: u32, il: u32, thresh: u32) void {
    switch (kind) {
        .simple => simpleFilter(s, limit),
        .subblock => subblockFilter(s, limit, il, thresh),
        .mb => mbFilter(s, limit, il, thresh),
    }
}

/// A horizontal luma edge at `at`.
fn lumaH(comptime kind: EdgeKind, buf: []u8, at: usize, stride: usize, limit: u32, il: u32, thresh: u32) void {
    var s = Seg.loadRows(buf, at, stride);
    filterSeg(kind, &s, limit, il, thresh);
    s.storeRows(buf, at, stride);
}

/// A vertical luma edge at `at`, 16 rows down.
fn lumaV(comptime kind: EdgeKind, buf: []u8, at: usize, stride: usize, limit: u32, il: u32, thresh: u32) void {
    var rows: [lanes][]u8 = undefined;
    for (&rows, 0..) |*r, i| r.* = buf[at + i * stride - 4 ..][0..8];
    var s = Seg.loadCols(rows);
    filterSeg(kind, &s, limit, il, thresh);
    s.storeCols(rows);
}

fn chromaH(comptime kind: EdgeKind, u: []u8, v: []u8, at: usize, stride: usize, limit: u32, il: u32, thresh: u32) void {
    var s = Seg.loadRows2(u, v, at, stride);
    filterSeg(kind, &s, limit, il, thresh);
    s.storeRows2(u, v, at, stride);
}

fn chromaV(comptime kind: EdgeKind, u: []u8, v: []u8, at: usize, stride: usize, limit: u32, il: u32, thresh: u32) void {
    var rows: [lanes][]u8 = undefined;
    for (0..8) |i| {
        rows[i] = u[at + i * stride - 4 ..][0..8];
        rows[8 + i] = v[at + i * stride - 4 ..][0..8];
    }
    var s = Seg.loadCols(rows);
    filterSeg(kind, &s, limit, il, thresh);
    s.storeCols(rows);
}

const State = struct {
    h: Header = .{},
    l: Layout,
    width: u32,
    height: u32,
    work: []u8,
    parts: [8]Bool = undefined,
    p0: Bool = undefined,

    fn slice(s: *State, comptime T: type, at: usize, n: usize) []T {
        return @alignCast(std.mem.bytesAsSlice(T, s.work[at..][0 .. n * @sizeOf(T)]));
    }
};

/// Reads `n` bytes of the chunk into `dst[0..min(n, dst.len)]` and skips the
/// rest of them.
fn readPart(reader: *Io.Reader, dst: []u8, n: u64) Error![]u8 {
    const k: usize = @intCast(@min(n, dst.len));
    reader.readSliceAll(dst[0..k]) catch |e| return mapRead(e);
    reader.discardAll64(n - k) catch |e| return mapRead(e);
    return dst[0..k];
}

fn mapRead(e: anyerror) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        else => error.ReadFailed,
    };
}

/// What `decode` left of its chunk, or read past it.
pub const Rest = struct {
    /// Bytes of the chunk not read.
    unread: u64,
    /// Bytes past the chunk consumed from the reader (`tail` only); the
    /// chunks after it are lost when this is not 0.
    over: u64,
};

/// Decodes the frame whose header is `fh`, from the `len` bytes of its
/// chunk after the header, in `work[0..workLen(...)]`. For a still image,
/// `after` is the bytes of the payload after the chunk, and the partitions
/// go on past the chunk to the end of the input, as libwebp reads them;
/// `workLen` is then for `len + after` bytes. Otherwise (null) the chunk
/// bounds them.
pub fn decode(reader: *Io.Reader, len: u64, after: ?u64, fh: FrameHeader, work: []u8, sink: Sink) Error!Rest {
    const tail = after != null;
    const l = Layout.init(fh.width, fh.height, len + (after orelse 0)).?;
    std.debug.assert(work.len >= l.total);
    var st: State = .{ .l = l, .width = fh.width, .height = fh.height, .work = work };
    const cbuf = work[l.cbuf..][0..l.cbuf_len];
    var left = len;
    var over: u64 = 0;

    // The first partition.
    if (fh.first_part_size > left and !tail) return error.Truncated;
    const p0 = try readPart(reader, cbuf[0..@min(cbuf.len, l.p0_cap)], fh.first_part_size);
    over += fh.first_part_size -| left;
    left -|= fh.first_part_size;
    var used = p0.len;
    st.p0 = .{ .win = p0 };
    st.p0.init();
    try parseHeader(&st.p0, &st.h);
    const np: usize = st.h.partitions;

    // The token partitions: sizes, then all but the last kept.
    if (left < 3 * (np - 1) and !tail) return error.Truncated;
    var sizes: [7]u32 = undefined;
    for (sizes[0 .. np - 1]) |*s| {
        const b = reader.takeArray(3) catch |e| return mapRead(e);
        s.* = std.mem.readInt(u24, b, .little);
    }
    over += 3 * (np - 1) -| left;
    left -|= 3 * (np - 1);
    const per_part = bytesFor(token_bools * l.mbw * ((l.mbh + np - 1) / np));
    for (0..np - 1) |p| {
        const size = if (tail) sizes[p] else @min(sizes[p], left);
        const room = cbuf[used..];
        const keep = try readPart(reader, room[0..@intCast(@min(room.len, per_part))], size);
        used += keep.len;
        over += size -| left;
        left -|= size;
        st.parts[p] = .{ .win = keep };
        st.parts[p].init();
    }
    // The last partition needs a byte, in the chunk or, for a still image,
    // after it.
    if (left == 0) {
        if (!tail) return error.Truncated;
        _ = reader.peek(1) catch |e| return mapRead(e);
    }
    st.parts[np - 1] = .{ .win = &.{}, .reader = reader, .left = left, .tail = tail };
    st.parts[np - 1].init();

    try decodeFrame(&st, sink);
    const last = &st.parts[np - 1];
    over += last.over;
    // Bytes past the chunk only peeked stay in the reader while nothing
    // past it was consumed.
    if (over > 0) {
        reader.toss(last.beyond);
        over += last.beyond;
    }
    return .{ .unread = last.left, .over = over };
}

fn decodeFrame(st: *State, sink: Sink) Error!void {
    const l = st.l;
    const h = &st.h;
    const mbw = l.mbw;
    const w16 = 16 * mbw;
    const w8 = 8 * mbw;
    const top_y = st.work[l.top_y..][0 .. 16 * mbw];
    const top_u = st.work[l.top_u..][0 .. 8 * mbw];
    const top_v = st.work[l.top_v..][0 .. 8 * mbw];
    const intra_t = st.work[l.intra_t..][0 .. 4 * mbw];
    // Per macroblock: the nonzero flags of the bottom blocks (4 luma, 2 U,
    // 2 V) and of the Y2 block.
    const nz_t = st.work[l.nz_t..][0 .. 2 * mbw];
    const finfo = st.slice(FilterInfo, l.finfo, mbw);
    const ybuf = st.work[l.ybuf..][0 .. 24 * w16];
    const ubuf = st.work[l.ubuf..][0 .. 16 * w8];
    const vbuf = st.work[l.vbuf..][0 .. 16 * w8];
    @memset(intra_t, b_dc);
    @memset(nz_t, 0);

    var bp: [4]BandProbs = undefined;
    for (&bp, &h.probs) |*t, *pr| {
        for (t, bands) |*e, band| e.* = &pr[band];
    }
    var sc: Scratch = .{};
    var mb: Mb = .{};
    // Kept zero between macroblocks: a block is cleared after use only if
    // it had coefficients, which a zero code rules out.
    var coef: [24][16]i16 = @splat(@splat(0));
    var y2: [16]i16 = undefined;

    for (0..l.mbh) |mby| {
        const part = &st.parts[mby & (h.partitions - 1)];
        var intra_l: [4]u8 = @splat(b_dc);
        var nz_l: u8 = 0;
        var nzdc_l: u8 = 0;
        for (0..mbw) |mbx| {
            // The decoders' state in locals, which stores through other
            // pointers cannot touch, for the length of the macroblock.
            var p0 = st.p0;
            parseModes(&p0, h, intra_t[4 * mbx ..][0..4], &intra_l, &mb);
            st.p0 = p0;
            var tok = part.*;
            const tb = &tok;

            // Tokens.
            var codes_y: u32 = 0; // two bits per luma block, block 0 highest
            var codes_uv: u16 = 0;
            var skip = mb.skip;
            if (!skip) {
                const q = h.quant[mb.segment];
                var first: u5 = 0;
                var ytype: usize = 3;
                if (!mb.i4x4) {
                    @memset(&y2, 0);
                    const ctx: u2 = @intCast(nz_t[2 * mbx + 1] + nzdc_l);
                    const nz = coeffs(tb, &bp[1], ctx, q.y2, 0, &y2);
                    const f = @intFromBool(nz > 0);
                    nz_t[2 * mbx + 1] = f;
                    nzdc_l = f;
                    if (nz > 1) {
                        inverseWht(&y2, coef[0..16]);
                    } else {
                        const dc: i16 = @truncate((@as(i32, y2[0]) + 3) >> 3);
                        for (coef[0..16]) |*blk| blk[0] = dc;
                    }
                    first = 1;
                    ytype = 0;
                }
                var tnz = nz_t[2 * mbx];
                const lnz = nz_l;
                var out_t: u8 = 0;
                var out_l: u8 = 0;
                for (0..4) |y| {
                    var lf: u1 = @truncate(lnz >> @intCast(y));
                    for (0..4) |x| {
                        const tf: u1 = @truncate(tnz >> @intCast(x));
                        const blk = &coef[y * 4 + x];
                        const nz = coeffs(tb, &bp[ytype], @as(u2, lf) + tf, q.y1, first, blk);
                        const f: u1 = @intFromBool(nz > first);
                        lf = f;
                        tnz = (tnz & ~(@as(u8, 1) << @intCast(x))) | (@as(u8, f) << @intCast(x));
                        codes_y = (codes_y << 2) | nzCode(nz, blk[0]);
                    }
                    out_l |= @as(u8, lf) << @intCast(y);
                }
                out_t = tnz & 0x0f;
                for (0..2) |ch| {
                    const shift: u3 = @intCast(4 + 2 * ch);
                    var ct: u8 = (nz_t[2 * mbx] >> shift) & 3;
                    var cl: u8 = (nz_l >> shift) & 3;
                    for (0..2) |y| {
                        var lf: u1 = @truncate(cl >> @intCast(y));
                        for (0..2) |x| {
                            const tf: u1 = @truncate(ct >> @intCast(x));
                            const blk = &coef[16 + ch * 4 + y * 2 + x];
                            const nz = coeffs(tb, &bp[2], @as(u2, lf) + tf, q.uv, 0, blk);
                            const f: u1 = @intFromBool(nz > 0);
                            lf = f;
                            ct = (ct & ~(@as(u8, 1) << @intCast(x))) | (@as(u8, f) << @intCast(x));
                            codes_uv = (codes_uv << 2) | nzCode(nz, blk[0]);
                        }
                        cl = (cl & ~(@as(u8, 1) << @intCast(y))) | (@as(u8, lf) << @intCast(y));
                    }
                    out_t |= ct << shift;
                    out_l |= cl << shift;
                }
                nz_t[2 * mbx] = out_t;
                nz_l = out_l;
                skip = codes_y == 0 and codes_uv == 0;
            } else {
                nz_t[2 * mbx] = 0;
                nz_l = 0;
                if (!mb.i4x4) {
                    nz_t[2 * mbx + 1] = 0;
                    nzdc_l = 0;
                }
            }
            part.* = tok;
            try tb.check();

            if (h.filter_type > 0) {
                var f = h.filters[mb.segment][@intFromBool(mb.i4x4)];
                f.inner |= @intFromBool(!skip);
                finfo[mbx] = f;
            }

            reconstruct(&sc, &mb, &coef, codes_y, codes_uv, mbx, mby, mbw, top_y, top_u, top_v);
            if (!skip) {
                const codes = @as(u64, codes_y) << 16 | codes_uv;
                for (&coef, 0..) |*blk, n| {
                    if (codes >> @intCast(46 - 2 * n) & 3 != 0) blk.* = @splat(0);
                }
            }

            // Into the frame rows, and the bottom row kept for prediction.
            for (0..16) |r| @memcpy(ybuf[(8 + r) * w16 + 16 * mbx ..][0..16], sc.y[y0 + r * ys ..][0..16]);
            for (0..8) |r| {
                @memcpy(ubuf[(8 + r) * w8 + 8 * mbx ..][0..8], sc.u[c0 + r * cs ..][0..8]);
                @memcpy(vbuf[(8 + r) * w8 + 8 * mbx ..][0..8], sc.v[c0 + r * cs ..][0..8]);
            }
            @memcpy(top_y[16 * mbx ..][0..16], sc.y[y0 + 15 * ys ..][0..16]);
            @memcpy(top_u[8 * mbx ..][0..8], sc.u[c0 + 7 * cs ..][0..8]);
            @memcpy(top_v[8 * mbx ..][0..8], sc.v[c0 + 7 * cs ..][0..8]);
        }
        try st.p0.check();

        if (h.filter_type > 0) filterRow(h.filter_type, finfo, ybuf, ubuf, vbuf, w16, w8, mby);
        emitRows(st, sink, ybuf, ubuf, vbuf, w16, w8, mby);
        // Keep the last 8 rows of each plane for the next row's filter and
        // upsampler.
        @memmove(ybuf[0 .. 8 * w16], ybuf[16 * w16 ..][0 .. 8 * w16]);
        @memmove(ubuf[0 .. 8 * w8], ubuf[8 * w8 ..][0 .. 8 * w8]);
        @memmove(vbuf[0 .. 8 * w8], vbuf[8 * w8 ..][0 .. 8 * w8]);
    }
}

fn reconstruct(
    sc: *Scratch,
    mb: *const Mb,
    coef: *const [24][16]i16,
    codes_y: u32,
    codes_uv: u16,
    mbx: usize,
    mby: usize,
    mbw: usize,
    top_y: []const u8,
    top_u: []const u8,
    top_v: []const u8,
) void {
    // The left column: the last macroblock's right column, or 129; and the
    // corner: the row above's pixel, 127 on the top row, 129 on the left.
    if (mbx == 0) {
        for (0..16) |r| sc.y[y0 + r * ys - 1] = 129;
        for (0..8) |r| {
            sc.u[c0 + r * cs - 1] = 129;
            sc.v[c0 + r * cs - 1] = 129;
        }
        const corner: u8 = if (mby == 0) 127 else 129;
        sc.y[y0 - ys - 1] = corner;
        sc.u[c0 - cs - 1] = corner;
        sc.v[c0 - cs - 1] = corner;
    } else {
        // Rows -1 to 15: the corner comes from the old row above.
        for (0..17) |r| sc.y[y0 - ys + r * ys - 1] = sc.y[y0 - ys + r * ys + 15];
        for (0..9) |r| {
            sc.u[c0 - cs + r * cs - 1] = sc.u[c0 - cs + r * cs + 7];
            sc.v[c0 - cs + r * cs - 1] = sc.v[c0 - cs + r * cs + 7];
        }
    }
    // The row above, with four more to the right for subblocks.
    if (mby == 0) {
        @memset(sc.y[y0 - ys ..][0..20], 127);
        @memset(sc.u[c0 - cs ..][0..8], 127);
        @memset(sc.v[c0 - cs ..][0..8], 127);
    } else {
        @memcpy(sc.y[y0 - ys ..][0..16], top_y[16 * mbx ..][0..16]);
        @memcpy(sc.u[c0 - cs ..][0..8], top_u[8 * mbx ..][0..8]);
        @memcpy(sc.v[c0 - cs ..][0..8], top_v[8 * mbx ..][0..8]);
        if (mbx + 1 < mbw) {
            @memcpy(sc.y[y0 - ys + 16 ..][0..4], top_y[16 * (mbx + 1) ..][0..4]);
        } else {
            @memset(sc.y[y0 - ys + 16 ..][0..4], top_y[16 * mbx + 15]);
        }
    }

    if (mb.i4x4) {
        // Subblocks on the right edge use the macroblock's above-right.
        for ([_]usize{ 3, 7, 11 }) |r| @memcpy(sc.y[y0 + r * ys + 16 ..][0..4], sc.y[y0 - ys + 16 ..][0..4]);
        var bits = codes_y;
        for (0..16) |n| {
            const at = y0 + (n / 4) * 4 * ys + (n % 4) * 4;
            predictSub(&sc.y, at, mb.bmodes[n]);
            transform(@truncate(bits >> 30), &coef[n], sc.y[at..], ys);
            bits <<= 2;
        }
    } else {
        predictBlock(16, &sc.y, y0, ys, mb.ymode, mby > 0, mbx > 0);
        var bits = codes_y;
        for (0..16) |n| {
            const at = y0 + (n / 4) * 4 * ys + (n % 4) * 4;
            transform(@truncate(bits >> 30), &coef[n], sc.y[at..], ys);
            bits <<= 2;
        }
    }

    predictBlock(8, &sc.u, c0, cs, mb.uvmode, mby > 0, mbx > 0);
    predictBlock(8, &sc.v, c0, cs, mb.uvmode, mby > 0, mbx > 0);
    for (0..2) |ch| {
        const buf: []u8 = if (ch == 0) &sc.u else &sc.v;
        const codes: u8 = @truncate(codes_uv >> @intCast(8 * (1 - ch)));
        if (codes == 0) continue;
        // Any AC coefficient: libwebp runs the full transform on all four.
        const full = codes & 0xaa != 0;
        for (0..4) |n| {
            const at = c0 + (n / 2) * 4 * cs + (n % 2) * 4;
            const blk = &coef[16 + ch * 4 + n];
            if (full) idctFull(blk, buf[at..], cs) else if (blk[0] != 0) idctDc(blk, buf[at..], cs);
        }
    }
}

/// Filters macroblock row `mby`, whose pixels are rows 8 to 23 of `ybuf`
/// (8 to 15 of the chroma buffers), with the row above's last eight rows
/// before them, in macroblock order (section 15.1).
fn filterRow(
    ft: u2,
    finfo: []const FilterInfo,
    ybuf: []u8,
    ubuf: []u8,
    vbuf: []u8,
    w16: usize,
    w8: usize,
    mby: usize,
) void {
    for (finfo, 0..) |f, mbx| {
        if (f.limit == 0) continue;
        const ya = 8 * w16 + 16 * mbx;
        const limit: u32 = f.limit;
        const mbl = limit + 4;
        if (ft == 1) {
            if (mbx > 0) lumaV(.simple, ybuf, ya, w16, mbl, 0, 0);
            if (f.inner != 0) for (1..4) |i| lumaV(.simple, ybuf, ya + 4 * i, w16, limit, 0, 0);
            if (mby > 0) lumaH(.simple, ybuf, ya, w16, mbl, 0, 0);
            if (f.inner != 0) for (1..4) |i| lumaH(.simple, ybuf, ya + 4 * i * w16, w16, limit, 0, 0);
            continue;
        }
        const il: u32 = f.ilevel;
        const hv: u32 = f.hev;
        const ca = 8 * w8 + 8 * mbx;
        if (mbx > 0) {
            lumaV(.mb, ybuf, ya, w16, mbl, il, hv);
            chromaV(.mb, ubuf, vbuf, ca, w8, mbl, il, hv);
        }
        if (f.inner != 0) {
            for (1..4) |i| lumaV(.subblock, ybuf, ya + 4 * i, w16, limit, il, hv);
            chromaV(.subblock, ubuf, vbuf, ca + 4, w8, limit, il, hv);
        }
        if (mby > 0) {
            lumaH(.mb, ybuf, ya, w16, mbl, il, hv);
            chromaH(.mb, ubuf, vbuf, ca, w8, mbl, il, hv);
        }
        if (f.inner != 0) {
            for (1..4) |i| lumaH(.subblock, ybuf, ya + 4 * i * w16, w16, limit, il, hv);
            chromaH(.subblock, ubuf, vbuf, ca + 4 * w8, w8, limit, il, hv);
        }
    }
}

/// Hands the sink every luma row the filter has finished with and whose
/// chroma neighbors are final: through frame row 16 * mby + 7, or to the
/// end on the last macroblock row. Buffer row 0 is frame row 16 * mby - 8
/// (chroma: 8 * mby - 8).
fn emitRows(
    st: *State,
    sink: Sink,
    ybuf: []const u8,
    ubuf: []const u8,
    vbuf: []const u8,
    w16: usize,
    w8: usize,
    mby: usize,
) void {
    const last = mby + 1 == st.l.mbh;
    const base: i64 = 16 * @as(i64, @intCast(mby)) - 8;
    const from: u32 = @intCast(@max(0, base));
    const to: u32 = if (last) st.height else @intCast(@min(st.height, base + 16));
    const chroma_rows: i64 = (st.height + 1) / 2;
    const cbase = 8 * @as(i64, @intCast(mby)) - 8;
    var y = from;
    while (y < to) : (y += 1) {
        // Row 2k - 1 sits between chroma rows k - 1 (near) and k; row 2k
        // between k (near) and k - 1.
        const k: i64 = (y + 1) / 2;
        var near: i64 = if (y & 1 == 1) k - 1 else k;
        var far: i64 = if (y & 1 == 1) k else k - 1;
        near = std.math.clamp(near, 0, chroma_rows - 1);
        far = std.math.clamp(far, 0, chroma_rows - 1);
        const ny: usize = @intCast(near - cbase);
        const fy: usize = @intCast(far - cbase);
        const ly: usize = @intCast(@as(i64, y) - base);
        sink.row(sink.context, y, ybuf[ly * w16 ..][0..w16], .{
            ubuf[ny * w8 ..][0..w8],
            vbuf[ny * w8 ..][0..w8],
        }, .{
            ubuf[fy * w8 ..][0..w8],
            vbuf[fy * w8 ..][0..w8],
        });
    }
}

test "frame header" {
    const ok = "\x50\x05\x00\x9d\x01\x2a\x10\x00\x08\x40";
    const h = try FrameHeader.parse(ok, 100);
    try testing.expectEqual(16, h.width);
    try testing.expectEqual(8, h.height);
    try testing.expectEqual(0x50 >> 5 | 0x05 << 3, h.first_part_size);
    try testing.expectError(error.BadVp8, FrameHeader.parse(ok, 42));
    var b = ok.*;
    b[0] |= 1;
    try testing.expectError(error.BadVp8, FrameHeader.parse(&b, 100));
    b = ok.*;
    b[5] = 0;
    try testing.expectError(error.BadVp8, FrameHeader.parse(&b, 100));
}

test "vertical edges transpose" {
    var buf: [16 * 8]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    var rows: [lanes][]u8 = undefined;
    for (&rows, 0..) |*r, i| r.* = buf[8 * i ..][0..8];
    var s = Seg.loadCols(rows);
    for (0..8) |k| {
        const col: [lanes]u8 = s.v[k];
        for (0..lanes) |i| try testing.expectEqual(buf[8 * i + k], col[i]);
    }
    s.v[3] +%= @splat(1);
    s.storeCols(rows);
    for (0..lanes) |i| try testing.expectEqual(@as(u8, @truncate((8 * i + 3) * 7 + 3)) +% 1, buf[8 * i + 3]);
}

test "inverse transforms agree where nothing overflows" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    for (0..2000) |_| {
        var in: [16]i16 = @splat(0);
        for ([_]usize{ 0, 1, 4 }) |i| in[i] = r.intRangeAtMost(i16, -2048, 2047);
        var a: [4 * 4]u8 = undefined;
        r.bytes(&a);
        var b = a;
        var c = a;
        idctFull(&in, &a, 4);
        idctAc3(&in, &b, 4);
        try testing.expectEqualSlices(u8, &a, &b);
        in[1] = 0;
        in[4] = 0;
        @memcpy(&b, &c);
        idctFull(&in, &c, 4);
        idctDc(&in, &b, 4);
        try testing.expectEqualSlices(u8, &c, &b);
    }
}
