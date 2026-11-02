//! The lossy WebP encoder: one VP8 key frame (RFC 6386) in a RIFF
//! container (RFC 9649), and an ALPH chunk when the source has alpha that
//! is not everywhere opaque. Written from the specifications.
//! src/encode.zig has the contract: nothing is allocated, and `workLen`
//! states the work memory up front.
//!
//! - The source is converted with `image.convert` to RGB8 (RGBA8 with
//!   alpha), then to BT.601 limited-range YUV 4:2:0, a macroblock row at a
//!   time: each chroma sample from the average of its 2x2 pixels.
//! - `EncodeOptions.quality` picks the quantizer. With segments (every
//!   effort but `fast`), macroblocks are clustered by their luma activity
//!   into four segments, each with its own quantizer and loop filter
//!   level: busier ones, where artifacts hide, quantize more coarsely.
//! - Each macroblock's luma is predicted as one 16x16 block or as sixteen
//!   4x4 blocks, and its chroma as two 8x8 blocks, choosing the modes that
//!   cost least in squared error plus lambda times the bits, the bits
//!   estimated from the token probabilities. Above `fast`, trellis
//!   quantization (vp8_encode_trellis.zig) chooses the levels the same
//!   way.
//! - Coefficients are kept compactly in work memory as they are chosen,
//!   with the counts of every token. After the last macroblock the token
//!   probabilities are chosen from the counts, the token partition is
//!   coded into the spare room of the coefficients' memory (or sized,
//!   when it does not fit), the first is sized by a pass of the boolean
//!   coder that writes nothing, and the file is written in one pass.
//! - Alpha goes in ALPH, compressed by the lossless encoder
//!   (src/webp/encode.zig) when that is smaller than raw.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const shared = @import("../encode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const lossless = @import("encode.zig");
const tables = @import("vp8_encode_tables.zig");
const dsp = @import("vp8_encode_dsp.zig");
const coder = @import("vp8_encode_bool.zig");
const trellis = @import("vp8_encode_trellis.zig");

/// How hard the encoder works to make the file small for its quality.
pub const Effort = enum {
    /// No segments. Each block's mode is the one whose prediction is
    /// closest (4x4 blocks try only DC, TM, VE, and HE); rate and
    /// distortion choose only between 16x16 and 4x4 luma.
    fast,
    /// Segments. The 16x16 and chroma modes are chosen by rate and
    /// distortion, and each 4x4 block's by rate and distortion among the
    /// three closest predictions; the chosen modes' levels are chosen
    /// again by trellis quantization.
    default,
    /// As `default` with every 4x4 mode tried, trellis quantization in
    /// every choice, and every macroblock tried as 4x4, after a first
    /// pass whose token statistics refine the rate estimates.
    best,
};

pub const EncodeOptions = struct {
    /// 0 (smallest) to 100 (best); values past 100 are 100.
    quality: u8 = 75,
    effort: Effort = .default,
    /// An ICC profile for an ICCP chunk.
    icc: ?[]const u8 = null,
    /// An EXIF profile, starting with its TIFF header, for an EXIF chunk.
    exif: ?[]const u8 = null,
    /// XMP for an XMP chunk.
    xmp: ?[]const u8 = null,
    /// Whether alpha is compressed with the lossless encoder (ALPH
    /// compression 1), kept only when that is smaller than storing it
    /// raw, as libwebp does. While it is on, `workLen` includes the
    /// lossless encoder's work memory whatever the source, about 29 to 38
    /// bytes per pixel at a megapixel; a caller whose images are opaque
    /// turns it off to ask for about 3.2. False stores alpha raw.
    alpha_compression: bool = true,
};

pub const EncodeError = shared.Error || error{
    /// VP8 cannot store an image without rows or columns.
    EmptyImage,
};

/// VP8's largest width or height.
const max_side = 16383;

/// A macroblock's modes, kept from the main pass for the first partition.
const MbInfo = extern struct {
    /// Bits 0-1 the segment, 2 a 4x4-predicted macroblock, 3 no nonzero
    /// coefficient, 4-5 the 16x16 mode, 6-7 the chroma mode.
    flags: u8,
    /// The sixteen 4x4 modes, two to a byte.
    bmodes: [8]u8,

    fn segment(m: MbInfo) u2 {
        return @truncate(m.flags);
    }
    fn isI4(m: MbInfo) bool {
        return m.flags & 4 != 0;
    }
    fn empty(m: MbInfo) bool {
        return m.flags & 8 != 0;
    }
    fn ymode(m: MbInfo) u8 {
        return (m.flags >> 4) & 3;
    }
    fn uvmode(m: MbInfo) u8 {
        return m.flags >> 6;
    }
    fn bmode(m: MbInfo, n: usize) u8 {
        return (m.bmodes[n / 2] >> @intCast(4 * (n % 2))) & 15;
    }
};

/// The most bytes one macroblock's coefficients take in the store: 25
/// counts, and at most 384 coefficients of at most 2 bytes.
const max_mb_bytes = 25 + 384 * 2;

/// What the encoder keeps in work memory beside its rows.
const State = struct {
    /// Token counts of the macroblocks that have coefficients, and
    /// the end-of-block tokens of those that have none, which are only
    /// coded when the skip flag is off.
    counts: coder.Hist,
    empty_counts: coder.Hist,
    costs: coder.Costs,
    probs: coder.Probs,
    y: [dsp.ys * 17]u8,
    u: [dsp.cs * 9]u8,
    v: [dsp.cs * 9]u8,
};

const Layout = struct {
    mbw: usize,
    mbh: usize,
    state: usize,
    info: usize,
    act: usize,
    coefs: usize,
    coefs_len: usize,
    band_y: usize,
    band_u: usize,
    band_v: usize,
    rgb: usize,
    top_y: usize,
    top_u: usize,
    top_v: usize,
    top_modes: usize,
    top_nz: usize,
    alpha: usize,
    band_hidden: usize,
    band_hidden_uv: usize,
    /// The alpha plane, its compressed stream, and the lossless encoder's
    /// work memory, with `alpha_compression`.
    alpha_plane: usize,
    alpha_out: usize,
    alpha_work: usize,
    alpha_work_len: usize,
    total: usize,

    fn init(options: EncodeOptions, width: u32, height: u32) ?Layout {
        const w: u64 = @max(width, 1);
        const mbw: u64 = (w + 15) / 16;
        const mbh: u64 = (@as(u64, @max(height, 1)) + 15) / 16;
        const mbs = mbw * mbh;
        const alpha_options: lossless.EncodeOptions = .{ .effort = alphaEffort(options.effort) };
        const alpha_work: u64 = if (options.alpha_compression)
            lossless.workLen(alpha_options, @max(width, 1), @max(height, 1)) orelse return null
        else
            0;
        const sizes = [_]u64{
            @sizeOf(State),
            mbs * @sizeOf(MbInfo),
            mbs,
            mbs * max_mb_bytes,
            16 * 16 * mbw,
            8 * 8 * mbw,
            8 * 8 * mbw,
            2 * 4 * w,
            16 * mbw + 4,
            8 * mbw,
            8 * mbw,
            4 * mbw,
            2 * mbw,
            w,
            16 * 16 * mbw,
            8 * 8 * mbw,
            if (options.alpha_compression) w * @max(height, 1) else 0,
            if (options.alpha_compression) w * @max(height, 1) else 0,
            alpha_work,
        };
        var offsets: [sizes.len]u64 = undefined;
        var at: u64 = 0;
        for (sizes, &offsets) |s, *o| {
            o.* = at;
            at = std.mem.alignForward(u64, at + s, 16);
        }
        var l: Layout = undefined;
        const names = .{
            "state",       "info",           "act",         "coefs",     "band_y",     "band_u", "band_v",
            "rgb",         "top_y",          "top_u",       "top_v",     "top_modes",  "top_nz", "alpha",
            "band_hidden", "band_hidden_uv", "alpha_plane", "alpha_out", "alpha_work",
        };
        inline for (names, 0..) |name, i| {
            @field(l, name) = std.math.cast(usize, offsets[i]) orelse return null;
        }
        l.mbw = @intCast(mbw);
        l.mbh = @intCast(mbh);
        l.coefs_len = std.math.cast(usize, sizes[3]) orelse return null;
        l.alpha_work_len = std.math.cast(usize, alpha_work) orelse return null;
        // Room to align the state.
        l.total = std.math.cast(usize, at + @alignOf(State)) orelse return null;
        return l;
    }
};

/// The work memory `encode` needs for a `width` by `height` image, or null
/// when VP8 cannot store it: with `alpha_compression`, the lossless
/// encoder's for the alpha too, since the source's format is not known.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    if (width > max_side or height > max_side) return null;
    const l = Layout.init(options, width, height) orelse return null;
    return l.total;
}

/// The lossless encoder's effort for alpha at each effort (plan.md
/// decision 65): effort 1 is 4% smaller than libwebp's -m 2 alpha and
/// within 1% of -m 4's, in less time, and 8 within 2% of -m 6's in a
/// twenty-fifth of its time
/// (results/webp-encode-alpha-20261102.md).
fn alphaEffort(effort: Effort) u4 {
    return switch (effort) {
        .fast => 1,
        .default => 1,
        .best => 8,
    };
}

/// The base quantizer index (0 to 127, section 9.6) for a quality: what
/// cwebp chooses at the same quality without segments, measured at the
/// points below and interpolated between them, so a quality means about
/// the same in both encoders.
pub fn quantizerIndex(quality: u8) u7 {
    return quality_index[@min(quality, 100)];
}

const quality_index: [101]u7 = blk: {
    const points = [_][2]u32{
        .{ 0, 127 }, .{ 5, 86 },  .{ 10, 75 }, .{ 20, 62 }, .{ 30, 52 }, .{ 40, 45 },
        .{ 50, 38 }, .{ 60, 33 }, .{ 70, 28 }, .{ 75, 26 }, .{ 80, 19 }, .{ 85, 14 },
        .{ 90, 9 },  .{ 95, 4 },  .{ 98, 1 },  .{ 100, 0 },
    };
    var t: [101]u7 = undefined;
    for (points[0 .. points.len - 1], points[1..]) |a, b| {
        for (a[0]..b[0] + 1) |q| {
            const num = a[1] * (b[0] - q) + b[1] * (q - a[0]);
            t[q] = @intCast((num + (b[0] - a[0]) / 2) / (b[0] - a[0]));
        }
    }
    break :blk t;
};

/// Lambda, in 1/10000 of the squared AC step per bit, weighting rate
/// against squared error: 150 to 220 measured best against cwebp.
const lambda = 180;
/// Quantizer rounding in 1/128 of a step: half a step for DC, and 3/8 for
/// AC, below the half that minimizes error, because a smaller level costs
/// fewer bits.
const round_dc = 64;
const round_ac = 48;
/// Trellis quantization's lambdas, in 1/16 of the mode decisions': bits
/// weigh less there. More made files smaller at equal PSNR and larger at
/// equal SSIM, and chroma, which PSNR over RGB weighs heavily, keeps more
/// of its levels.
const trellis_luma = 10;
const trellis_chroma = 5;
/// Below `best`, a macroblock whose 16x16 choice costs less than this
/// many bits' worth of squared error and bits is not tried as 4x4: such
/// flat ones rarely gain from it. Skipping them measured as small at
/// `fast` and 0.1% larger at `default`, for 4-13% more speed.
const i4_threshold = 64;

/// One segment's quantizers and rate-distortion weights.
const Segment = struct {
    qi: u7,
    filter: u6,
    y1: dsp.Quant,
    y2: dsp.Quant,
    uv: dsp.Quant,
    /// Lambda in 1/256 squared error per bit.
    lam: u64,
    /// Lambdas for trellis quantization of luma and chroma blocks.
    tlam: u64,
    tlam_uv: u64,

    fn init(qi: u7) Segment {
        const q: usize = qi;
        const dc = tables.dc_qlookup;
        const ac = tables.ac_qlookup;
        const y2ac = @max(8, @as(u32, ac[q]) * 155 / 100);
        const ac_q: u64 = ac[q];
        const lam = ac_q * ac_q * 256 * lambda / 10000;
        return .{
            .qi = qi,
            .filter = filterLevel(qi),
            .y1 = .init(dc[q], ac[q], round_dc, round_ac),
            .y2 = .init(2 * @as(u32, dc[q]), y2ac, round_dc, round_ac),
            .uv = .init(dc[@min(q, 117)], ac[q], round_dc, round_ac),
            .lam = lam,
            .tlam = lam * trellis_luma / 16,
            .tlam_uv = lam * trellis_chroma / 16,
        };
    }
};

/// The loop filter level for a quantizer index: 3/8 of it, which measured
/// as well as 1/4 and better than 1/2.
fn filterLevel(qi: u7) u6 {
    return @intCast(@min(63, @as(u32, qi) * 3 / 8));
}

// Mode costs in 1/256 bits, from the key frame's fixed probabilities
// (sections 11.2 to 11.4).
const i4_flag_cost = [2]u32{ tables.cost(145, 1), tables.cost(145, 0) };
const ymode_cost = [4]u32{
    tables.cost(156, 0) + tables.cost(163, 0),
    tables.cost(156, 0) + tables.cost(163, 1),
    tables.cost(156, 1) + tables.cost(128, 0),
    tables.cost(156, 1) + tables.cost(128, 1),
};
const uvmode_cost = [4]u32{
    tables.cost(142, 0),
    tables.cost(142, 1) + tables.cost(114, 0),
    tables.cost(142, 1) + tables.cost(114, 1) + tables.cost(183, 0),
    tables.cost(142, 1) + tables.cost(114, 1) + tables.cost(183, 1),
};

/// Each subblock mode's path through the tree of section 11.2: the
/// booleans, most significant first, and how many.
const bmode_bits = [10]u8{ 0b0, 0b10, 0b110, 0b11100, 0b11110, 0b111010, 0b111011, 0b111110, 0b1111110, 0b1111111 };
const bmode_len = [10]u4{ 1, 2, 3, 5, 5, 6, 6, 6, 7, 7 };
/// The probability index of each boolean on a path, by its position.
const bmode_node = [10][7]u4{
    .{ 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 4, 0, 0 },
    .{ 0, 1, 2, 3, 6, 0, 0 },
    .{ 0, 1, 2, 3, 4, 5, 0 },
    .{ 0, 1, 2, 3, 4, 5, 0 },
    .{ 0, 1, 2, 3, 6, 7, 0 },
    .{ 0, 1, 2, 3, 6, 7, 8 },
    .{ 0, 1, 2, 3, 6, 7, 8 },
};

fn writeBmode(bw: anytype, above: u8, left: u8, mode: u8) void {
    const p = &tables.kf_bmode_probs[above][left];
    const n = bmode_len[mode];
    for (0..n) |i| {
        const bit: u1 = @truncate(bmode_bits[mode] >> @intCast(n - 1 - i));
        bw.put(p[bmode_node[mode][i]], bit);
    }
}

/// The cost of each subblock mode given the modes above and to the left.
const bmode_cost: [10][10][10]u16 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [10][10][10]u16 = undefined;
    for (0..10) |a| for (0..10) |l| for (0..10) |m| {
        var c: u32 = 0;
        const n = bmode_len[m];
        for (0..n) |i| {
            const bit: u1 = @truncate(bmode_bits[m] >> (n - 1 - i));
            c += tables.cost(tables.kf_bmode_probs[a][l][bmode_node[m][i]], bit);
        }
        t[a][l][m] = c;
    };
    break :blk t;
};

/// The subblock mode context a 16x16 mode leaves (section 11.3).
const ymode_context = [4]u8{ dsp.b_dc, dsp.b_ve, dsp.b_he, dsp.b_tm };

/// One macroblock's luma choice.
const Luma = struct {
    i4: bool = false,
    mode: u8 = 0,
    bmodes: [16]u8 = undefined,
    y2: [16]i16 = undefined,
    y2_last: i32 = -1,
    lv: [16][16]i16 = undefined,
    last: [16]i32 = undefined,
    recon: [256]u8 = undefined,
    j: u64 = std.math.maxInt(u64),
    /// The modes' bits in 1/256, for the first partition's budget.
    mode_rate: u32 = 0,
};

/// One macroblock's chroma choice: blocks 0-3 U, 4-7 V.
const Chroma = struct {
    mode: u8 = 0,
    lv: [8][16]i16 = undefined,
    last: [8]i32 = undefined,
    recon: [2][64]u8 = undefined,
    j: u64 = std.math.maxInt(u64),
};

/// `src` with the pixels `hide` marks taken from `pred`.
fn unhidden(comptime n: usize, src: *const [n]u8, pred: *const [n]u8, hide: *const [n]bool) [n]u8 {
    var out: [n]u8 = undefined;
    for (&out, src, pred, hide) |*o, s, p, h| o.* = if (h) p else s;
    return out;
}

/// The mode whose prediction of `plain` (`n` pixels, `w` wide, packed;
/// exact where `hide` marks) has the least Hadamard error plus its mode cost weighted by the AC step `q`.
fn bestPrediction(
    comptime w: usize,
    comptime n: usize,
    plain: *const [n]u8,
    hide: ?*const [n]bool,
    preds: *const [4][n]u8,
    mode_cost: *const [4]u32,
    q: u32,
) u8 {
    var best: u8 = 0;
    var least: u64 = std.math.maxInt(u64);
    for (preds, 0..) |*p, m| {
        var blended: [n]u8 = undefined;
        if (hide) |h| blended = unhidden(n, plain, p, h);
        const src = if (hide != null) &blended else plain;
        var sum: u64 = 0;
        for (0..n / w / 4) |ty| sum += dsp.satdStrip(w, src[ty * 4 * w ..][0 .. 4 * w], p[ty * 4 * w ..][0 .. 4 * w]);
        const score = (sum << 8) + mode_cost[m] * @as(u64, q) / 2;
        if (score < least) {
            least = score;
            best = @intCast(m);
        }
    }
    return best;
}

inline fn rdCost(d: u32, rate: u32, lam: u64) u64 {
    return (@as(u64, d) << 8) + ((lam * rate) >> 8);
}

const Trellis = enum { off, final, all };

const Enc = struct {
    src: PixelBuffer,
    width: u32,
    height: u32,
    mbw: usize,
    mbh: usize,
    effort: Effort,
    st: *State,
    info: []MbInfo,
    act: []u8,
    coefs: []u8,
    coefs_end: usize = 0,
    w16: usize,
    w8: usize,
    band_y: []u8,
    band_u: []u8,
    band_v: []u8,
    rgb: []u8,
    top_y: []u8,
    top_u: []u8,
    top_v: []u8,
    top_modes: []u8,
    top_nz: []u8,
    alpha_rows: []u8,
    /// Whether each pixel of the band, and each chroma sample (all four
    /// of its pixels), has alpha 0, with `rgb_format` RGBA8.
    band_hidden: []bool,
    band_hidden_uv: []bool,
    /// The same for the current macroblock, and whether any is.
    hide_y: [256]bool = undefined,
    hide_uv: [64]bool = undefined,
    hidden: bool = false,
    alpha_plane: []u8,
    alpha_out: []u8,
    alpha_work: []u8,
    left_modes: [4]u8 = undefined,
    left_nz: [2]u8 = undefined,
    /// The format rows are converted to before YUV: RGB8, or RGBA8 when
    /// the source has alpha.
    rgb_format: PixelFormat,
    conv: Converter,
    segments: bool = false,
    /// Where trellis quantization chooses the levels.
    trellis: Trellis = .off,
    segs: [4]Segment = undefined,
    seg_probs: [3]u8 = .{ 255, 255, 255 },
    frame_filter: u6 = 0,
    skip: bool = false,
    skip_prob: u8 = 255,
    /// The mode bits (in 1/256) a macroblock may take on average, so that
    /// the first partition fits its 19-bit length, and those taken so
    /// far: a macroblock past its share is not predicted 4x4.
    mode_budget: u64 = std.math.maxInt(u64),
    mode_spent: u64 = 0,

    /// Source row `y` as `rgb_format`, converted into slot `slot` of the
    /// row buffer when the source is in another format.
    fn rgbRow(e: *Enc, y: u32, slot: usize) []const u8 {
        const row = e.src.row(y);
        if (e.src.format == e.rgb_format) return row;
        const bpp = e.rgb_format.bytesPerPixel();
        const out = e.rgb[slot * 4 * @as(usize, e.width) ..][0 .. bpp * @as(usize, e.width)];
        e.conv.run(out, row, e.width);
        return out;
    }

    /// Converts macroblock row `mby` of the source to YUV in the band,
    /// repeating the last column and row past the image.
    fn loadBand(e: *Enc, mby: usize) void {
        const bpp = e.rgb_format.bytesPerPixel();
        const w: usize = e.width;
        const cw = (w + 1) / 2;
        var r: usize = 0;
        while (r < 16) : (r += 2) {
            const ya: u32 = @intCast(@min(16 * mby + r, e.height - 1));
            const yb: u32 = @intCast(@min(16 * mby + r + 1, e.height - 1));
            const a = e.rgbRow(ya, 0);
            const b = e.rgbRow(yb, 1);
            const la = e.band_y[r * e.w16 ..][0..e.w16];
            const lb = e.band_y[(r + 1) * e.w16 ..][0..e.w16];
            for (0..w) |x| {
                la[x] = luma(a[x * bpp ..][0..3]);
                lb[x] = luma(b[x * bpp ..][0..3]);
            }
            if (bpp == 4) {
                const ha = e.band_hidden[r * e.w16 ..][0..e.w16];
                const hb = e.band_hidden[(r + 1) * e.w16 ..][0..e.w16];
                for (0..w) |x| {
                    ha[x] = a[4 * x + 3] == 0;
                    hb[x] = b[4 * x + 3] == 0;
                }
                @memset(ha[w..], ha[w - 1]);
                @memset(hb[w..], hb[w - 1]);
                const hc = e.band_hidden_uv[(r / 2) * e.w8 ..][0..e.w8];
                for (0..cw) |cx| {
                    const x1 = @min(2 * cx + 1, w - 1);
                    hc[cx] = ha[2 * cx] and ha[x1] and hb[2 * cx] and hb[x1];
                }
                @memset(hc[cw..], hc[cw - 1]);
            }
            @memset(la[w..], la[w - 1]);
            @memset(lb[w..], lb[w - 1]);
            const u = e.band_u[(r / 2) * e.w8 ..][0..e.w8];
            const v = e.band_v[(r / 2) * e.w8 ..][0..e.w8];
            for (0..cw) |cx| {
                const x0 = 2 * cx;
                const x1 = @min(x0 + 1, w - 1);
                var sum: [3]i32 = undefined;
                for (0..3) |c| {
                    sum[c] = @as(i32, a[x0 * bpp + c]) + a[x1 * bpp + c] + b[x0 * bpp + c] + b[x1 * bpp + c];
                }
                u[cx] = @intCast((-9714 * sum[0] - 19070 * sum[1] + 28784 * sum[2] + (128 << 18) + (1 << 17)) >> 18);
                v[cx] = @intCast((28784 * sum[0] - 24103 * sum[1] - 4681 * sum[2] + (128 << 18) + (1 << 17)) >> 18);
            }
            @memset(u[cw..], u[cw - 1]);
            @memset(v[cw..], v[cw - 1]);
        }
    }

    /// Each macroblock's luma activity, as 16 times the log2 of its 4x4
    /// blocks' mean variance plus 1, for clustering into segments.
    fn analyze(e: *Enc) void {
        for (0..e.mbh) |mby| {
            e.loadBand(mby);
            for (0..e.mbw) |mbx| {
                var total: u64 = 0;
                for (0..16) |n| {
                    var s: u32 = 0;
                    var ss: u32 = 0;
                    const at = (n / 4) * 4 * e.w16 + 16 * mbx + (n % 4) * 4;
                    for (0..4) |r| for (0..4) |c| {
                        const p: u32 = e.band_y[at + r * e.w16 + c];
                        s += p;
                        ss += p * p;
                    };
                    total += 16 * ss - s * s;
                }
                // 16 blocks of 256 times the variance.
                const mean = total / 4096;
                const lg: u64 = std.math.log2_int(u64, mean + 1);
                // A fractional part from the next four bits.
                const v = mean + 1;
                const frac: u64 = if (lg >= 4) (v >> @intCast(lg - 4)) & 15 else (v << @intCast(4 - lg)) & 15;
                e.act[mby * e.mbw + mbx] = @intCast(@min(255, lg * 16 + frac));
            }
        }
    }

    /// Clusters the activities into four segments (k-means over their
    /// histogram) and sets each segment's quantizer.
    fn chooseSegments(e: *Enc, base: u7) void {
        var hist: [256]u32 = @splat(0);
        for (e.act) |a| hist[a] += 1;
        var lo: usize = 0;
        while (hist[lo] == 0) lo += 1;
        var hi: usize = 255;
        while (hist[hi] == 0) hi -= 1;
        var centers: [4]u32 = undefined;
        for (&centers, 0..) |*c, i| c.* = @intCast(lo + (hi - lo) * (2 * i + 1) / 8);
        var assign: [256]u2 = undefined;
        for (0..12) |_| {
            var sum: [4]u64 = @splat(0);
            var n: [4]u64 = @splat(0);
            for (lo..hi + 1) |a| {
                if (hist[a] == 0) continue;
                var best: u2 = 0;
                var bd: u32 = std.math.maxInt(u32);
                for (centers, 0..) |c, i| {
                    const d = @abs(@as(i32, @intCast(a)) - @as(i32, @intCast(c)));
                    if (d < bd) {
                        bd = d;
                        best = @intCast(i);
                    }
                }
                assign[a] = best;
                sum[best] += a * hist[a];
                n[best] += hist[a];
            }
            for (&centers, sum, n) |*c, s, k| {
                if (k > 0) c.* = @intCast((s + k / 2) / k);
            }
        }
        var mean: u64 = 0;
        for (e.act) |a| mean += a;
        mean /= e.act.len;
        for (&e.segs, centers) |*s, c| {
            // One and a half quantizer indices per doubling of activity.
            // Equal quantizers measured best on PSNR and worst on SSIM;
            // this balances the two.
            const d = @divTrunc((@as(i32, @intCast(c)) - @as(i32, @intCast(mean))) * 3, 32);
            const qi: u7 = @intCast(std.math.clamp(@as(i32, base) + d, 0, 127));
            s.* = .init(qi);
        }
        for (e.info, e.act) |*m, a| m.flags = assign[a];
        var count: [4]u64 = @splat(0);
        for (e.info) |m| count[m.segment()] += 1;
        e.seg_probs = .{
            branchProb(count[0] + count[1], count[2] + count[3]),
            branchProb(count[0], count[1]),
            branchProb(count[2], count[3]),
        };
    }

    /// Sets up the reconstruction scratch's edges for macroblock (`mbx`,
    /// `mby`), as a decoder does.
    fn edges(e: *Enc, mbx: usize, mby: usize) void {
        const st = e.st;
        const ys = dsp.ys;
        const cs = dsp.cs;
        const y0 = dsp.y0;
        const c0 = dsp.c0;
        if (mbx == 0) {
            for (0..16) |r| st.y[y0 + r * ys - 1] = 129;
            for (0..8) |r| {
                st.u[c0 + r * cs - 1] = 129;
                st.v[c0 + r * cs - 1] = 129;
            }
            const corner: u8 = if (mby == 0) 127 else 129;
            st.y[y0 - ys - 1] = corner;
            st.u[c0 - cs - 1] = corner;
            st.v[c0 - cs - 1] = corner;
        } else {
            for (0..17) |r| st.y[y0 - ys + r * ys - 1] = st.y[y0 - ys + r * ys + 15];
            for (0..9) |r| {
                st.u[c0 - cs + r * cs - 1] = st.u[c0 - cs + r * cs + 7];
                st.v[c0 - cs + r * cs - 1] = st.v[c0 - cs + r * cs + 7];
            }
        }
        if (mby == 0) {
            @memset(st.y[y0 - ys ..][0..20], 127);
            @memset(st.u[c0 - cs ..][0..8], 127);
            @memset(st.v[c0 - cs ..][0..8], 127);
        } else {
            @memcpy(st.y[y0 - ys ..][0..16], e.top_y[16 * mbx ..][0..16]);
            @memcpy(st.u[c0 - cs ..][0..8], e.top_u[8 * mbx ..][0..8]);
            @memcpy(st.v[c0 - cs ..][0..8], e.top_v[8 * mbx ..][0..8]);
            if (mbx + 1 < e.mbw) {
                @memcpy(st.y[y0 - ys + 16 ..][0..4], e.top_y[16 * (mbx + 1) ..][0..4]);
            } else {
                @memset(st.y[y0 - ys + 16 ..][0..4], e.top_y[16 * mbx + 15]);
            }
        }
        // Subblocks on the right edge use the macroblock's above-right.
        for ([_]usize{ 3, 7, 11 }) |r| @memcpy(st.y[y0 + r * ys + 16 ..][0..4], st.y[y0 - ys + 16 ..][0..4]);
    }

    fn encodeMb(e: *Enc, mbx: usize, mby: usize) void {
        const st = e.st;
        e.edges(mbx, mby);
        const info = &e.info[mby * e.mbw + mbx];
        const seg = &e.segs[info.segment()];
        var sy: [256]u8 = undefined;
        for (0..16) |r| @memcpy(sy[r * 16 ..][0..16], e.band_y[r * e.w16 + 16 * mbx ..][0..16]);
        var suv: [2][64]u8 = undefined;
        for (0..8) |r| {
            @memcpy(suv[0][r * 8 ..][0..8], e.band_u[r * e.w8 + 8 * mbx ..][0..8]);
            @memcpy(suv[1][r * 8 ..][0..8], e.band_v[r * e.w8 + 8 * mbx ..][0..8]);
        }
        const top = e.top_nz[2 * mbx ..][0..2];
        const has_top = mby > 0;
        const has_left = mbx > 0;
        // Pixels whose alpha is 0 show nothing, so every prediction is taken
        // as exact there: they cost no residual and count no error.
        e.hidden = false;
        if (e.rgb_format == .rgba8) {
            for (0..16) |r| @memcpy(e.hide_y[r * 16 ..][0..16], e.band_hidden[r * e.w16 + 16 * mbx ..][0..16]);
            for (0..8) |r| @memcpy(e.hide_uv[r * 8 ..][0..8], e.band_hidden_uv[r * e.w8 + 8 * mbx ..][0..8]);
            for (e.hide_y) |h| e.hidden = e.hidden or h;
            for (e.hide_uv) |h| e.hidden = e.hidden or h;
        }

        var best: Luma = .{};
        var ch: Chroma = .{};
        // Specialized so that opaque macroblocks pay nothing for the masks.
        switch (e.hidden) {
            inline else => |hidden| {
                e.lumaI16(hidden, seg, &sy, top.*, e.left_nz, has_top, has_left, &best);
                var sub: Luma = .{};
                const k: u64 = mby * e.mbw + mbx;
                const unlimited = e.mode_budget == std.math.maxInt(u64);
                const within = unlimited or (e.mode_budget > 0 and e.mode_spent <= k * e.mode_budget);
                const top_modes = e.top_modes[4 * mbx ..][0..4];
                const worth = e.effort == .best or best.j >= i4_threshold * seg.lam;
                if (within and worth and e.lumaI4(hidden, seg, &sy, top[0], e.left_nz[0], top_modes, best.j, &sub)) {
                    best = sub;
                }
                for (0..16) |r| @memcpy(st.y[dsp.y0 + r * dsp.ys ..][0..16], best.recon[r * 16 ..][0..16]);
                e.chroma(hidden, seg, &suv, top[0], e.left_nz[0], has_top, has_left, &ch);
            },
        }
        for (0..8) |r| {
            @memcpy(st.u[dsp.c0 + r * dsp.cs ..][0..8], ch.recon[0][r * 8 ..][0..8]);
            @memcpy(st.v[dsp.c0 + r * dsp.cs ..][0..8], ch.recon[1][r * 8 ..][0..8]);
        }

        e.mode_spent += best.mode_rate + uvmode_cost[ch.mode];

        // The modes, and the subblock contexts the next macroblocks see.
        info.flags = (info.flags & 3) | @as(u8, if (best.i4) 4 else 0) | (best.mode << 4) | (ch.mode << 6);
        if (best.i4) {
            for (0..8) |i| info.bmodes[i] = best.bmodes[2 * i] | (best.bmodes[2 * i + 1] << 4);
            for (0..4) |x| e.top_modes[4 * mbx + x] = best.bmodes[12 + x];
            for (0..4) |y| e.left_modes[y] = best.bmodes[4 * y + 3];
        } else {
            @memset(e.top_modes[4 * mbx ..][0..4], ymode_context[best.mode]);
            @memset(&e.left_modes, ymode_context[best.mode]);
        }

        // The coefficients into the store, and their tokens counted.
        const first: u5 = if (best.i4) 0 else 1;
        var empty = best.i4 or best.y2_last < 0;
        for (best.last) |l| empty = empty and l < first;
        for (ch.last) |l| empty = empty and l < 0;
        if (empty) info.flags |= 8;
        const start = e.coefs_end;
        if (!empty) {
            if (!best.i4) e.store(&best.y2, 0, best.y2_last);
            for (&best.lv, best.last) |*lv, l| e.store(lv, first, l);
            for (&ch.lv, ch.last) |*lv, l| e.store(lv, 0, l);
        }
        const counts = if (empty) &st.empty_counts else &st.counts;
        const tally: [4]coder.Tally = .{
            .{ .counts = &counts[0] },
            .{ .counts = &counts[1] },
            .{ .counts = &counts[2] },
            .{ .counts = &counts[3] },
        };
        var at = start;
        walkMb(coder.Tally, &tally, info.*, e.coefs, &at, top, &e.left_nz, false);

        @memcpy(e.top_y[16 * mbx ..][0..16], st.y[dsp.y0 + 15 * dsp.ys ..][0..16]);
        @memcpy(e.top_u[8 * mbx ..][0..8], st.u[dsp.c0 + 7 * dsp.cs ..][0..8]);
        @memcpy(e.top_v[8 * mbx ..][0..8], st.v[dsp.c0 + 7 * dsp.cs ..][0..8]);
    }

    /// Appends one block's levels from `first` through `last`: their
    /// count, then each in one byte (-64 to 63) or two.
    fn store(e: *Enc, lv: *const [16]i16, first: u5, last: i32) void {
        const n: usize = if (last < first) 0 else @intCast(last + 1 - first);
        var at = e.coefs_end;
        e.coefs[at] = @intCast(n);
        at += 1;
        for (lv[first..][0..n]) |v| {
            if (v >= -64 and v < 64) {
                e.coefs[at] = @as(u7, @bitCast(@as(i7, @intCast(v))));
                at += 1;
            } else {
                const u: u15 = @bitCast(@as(i15, @intCast(v)));
                e.coefs[at] = 0x80 | @as(u8, @intCast(u >> 8));
                e.coefs[at + 1] = @truncate(u);
                at += 2;
            }
        }
        e.coefs_end = at;
    }

    fn lumaI16(
        e: *Enc,
        comptime hidden: bool,
        seg: *const Segment,
        sy: *const [256]u8,
        top: [2]u8,
        left: [2]u8,
        has_top: bool,
        has_left: bool,
        out: *Luma,
    ) void {
        var cand: Luma = .{};
        var preds: [4][256]u8 = undefined;
        for (&preds, 0..) |*p, m| dsp.predictBlock(16, &e.st.y, dsp.y0, dsp.ys, @intCast(m), has_top, has_left, p);
        const hide: ?*const [256]bool = if (hidden) &e.hide_y else null;
        // At `fast`, only the mode that predicts best is coded.
        const only: ?u8 = if (e.effort == .fast)
            bestPrediction(16, 256, sy, hide, &preds, &ymode_cost, seg.y1.q[1])
        else
            null;
        var best_mode: u8 = 0;
        for (0..4) |m| {
            const mode: u8 = @intCast(m);
            if (only) |o| if (o != mode) continue;
            e.codeI16(hidden, seg, sy, &preds[m], mode, top, left, e.trellis == .all, &cand);
            if (cand.j < out.j) {
                out.* = cand;
                best_mode = mode;
            }
        }
        // With trellis quantization for the final choice only, the best
        // mode is coded again with it.
        if (e.trellis == .final) e.codeI16(hidden, seg, sy, &preds[best_mode], best_mode, top, left, true, out);
    }

    /// Codes the macroblock's luma predicted as 16x16 by `pred` into `out`.
    fn codeI16(
        e: *Enc,
        comptime hidden: bool,
        seg: *const Segment,
        sy: *const [256]u8,
        pred: *const [256]u8,
        mode: u8,
        top: [2]u8,
        left: [2]u8,
        use_trellis: bool,
        cand: *Luma,
    ) void {
        var blended: [256]u8 = undefined;
        if (hidden) blended = unhidden(256, sy, pred, &e.hide_y);
        const src = if (hidden) &blended else sy;
        var coefs: [16][16]i16 = undefined;
        var dcs: [16]i32 = undefined;
        for (0..16) |b| {
            var res: [16]i16 = undefined;
            const at = (b / 4) * 64 + (b % 4) * 4;
            for (0..4) |r| for (0..4) |c| {
                res[r * 4 + c] = @as(i16, src[at + r * 16 + c]) - pred[at + r * 16 + c];
            };
            dsp.fdct(&res, &coefs[b]);
            dcs[b] = coefs[b][0];
        }
        var y2c: [16]i16 = undefined;
        dsp.fwht(&dcs, &y2c);
        var y2deq: [16]i16 = undefined;
        const y2ctx: u2 = @intCast(top[1] + left[1]);
        cand.y2_last = if (use_trellis)
            trellis.quantize(&e.st.costs, 1, y2ctx, &y2c, &seg.y2, 0, 4, seg.tlam, &cand.y2, &y2deq)
        else
            dsp.quantize(&y2c, &seg.y2, 0, &cand.y2, &y2deq);
        // The blocks' DC, from the Y2 block.
        var dc_blocks: [16][16]i16 = undefined;
        if (cand.y2_last > 0) {
            dsp.inverseWht(&y2deq, &dc_blocks);
        } else {
            const dc: i16 = @truncate((@as(i32, y2deq[0]) + 3) >> 3);
            for (&dc_blocks) |*blk| blk[0] = dc;
        }
        cand.recon = pred.*;
        var rate = i4_flag_cost[0] + ymode_cost[mode];
        rate += e.st.costs.blockCost(1, y2ctx, 0, cand.y2_last, &cand.y2);
        var tnz = top[0];
        var lnz = left[0];
        for (0..16) |b| {
            const at = (b / 4) * 64 + (b % 4) * 4;
            const x: u3 = @intCast(b % 4);
            const y: u3 = @intCast(b / 4);
            const ctx: u2 = @intCast(((tnz >> x) & 1) + ((lnz >> y) & 1));
            var deq: [16]i16 = undefined;
            cand.last[b] = if (use_trellis)
                trellis.quantize(&e.st.costs, 0, ctx, &coefs[b], &seg.y1, 1, 6, seg.tlam, &cand.lv[b], &deq)
            else
                dsp.quantize(&coefs[b], &seg.y1, 1, &cand.lv[b], &deq);
            deq[0] = dc_blocks[b][0];
            dsp.inverse(@max(cand.last[b] + 1, 1), &deq, cand.recon[at..], 16);
            rate += e.st.costs.blockCost(0, ctx, 1, cand.last[b], &cand.lv[b]);
            const f: u8 = @intFromBool(cand.last[b] >= 1);
            tnz = (tnz & ~(@as(u8, 1) << x)) | (f << x);
            lnz = (lnz & ~(@as(u8, 1) << y)) | (f << y);
        }
        const d = dsp.sse(16, 16, &cand.recon, 16, src);
        cand.j = rdCost(d, rate, seg.lam);
        cand.mode = mode;
        cand.mode_rate = i4_flag_cost[0] + ymode_cost[mode];
    }

    /// The 4x4 choice for a macroblock, into `out`; false when it costs
    /// `limit` or more, the best 16x16 choice's cost.
    fn lumaI4(
        e: *Enc,
        comptime hidden: bool,
        seg: *const Segment,
        sy: *const [256]u8,
        top_nz: u8,
        left_nz: u8,
        top_modes: *const [4]u8,
        limit: u64,
        out: *Luma,
    ) bool {
        var sc = e.st.y;
        out.i4 = true;
        out.mode = 0;
        out.y2_last = -1;
        var tnz = top_nz;
        var lnz = left_nz;
        var tm = top_modes.*;
        var lm = e.left_modes;
        var total: u64 = rdCost(0, i4_flag_cost[1], seg.lam);
        out.mode_rate = i4_flag_cost[1];
        for (0..16) |n| {
            const x: u3 = @intCast(n % 4);
            const y: u3 = @intCast(n / 4);
            const xi: usize = x;
            const yi: usize = y;
            const at = dsp.y0 + yi * 4 * dsp.ys + xi * 4;
            var src: [16]u8 = undefined;
            var hide: [16]bool = undefined;
            for (0..4) |r| {
                const o = (yi * 4 + r) * 16 + xi * 4;
                @memcpy(src[r * 4 ..][0..4], sy[o..][0..4]);
                if (hidden) @memcpy(hide[r * 4 ..][0..4], e.hide_y[o..][0..4]);
            }
            // Each mode's source, with its hidden pixels predicted exactly.
            var blended: [10][16]u8 = undefined;
            var srcs: [10]*const [16]u8 = undefined;
            const ctx: u2 = @intCast(((tnz >> x) & 1) + ((lnz >> y) & 1));
            const mode_costs = &bmode_cost[tm[x]][lm[y]];
            var best_j: u64 = std.math.maxInt(u64);
            var best_mode: u8 = 0;
            var best_lv: [16]i16 = undefined;
            var best_last: i32 = -1;
            var best_recon: [16]u8 = undefined;
            // Every mode's prediction, ranked by its error and mode cost;
            // only the best few are transformed and coded (one at `fast`).
            var preds: [10][16]u8 = undefined;
            var order: [10]u8 = undefined;
            var score: [10]u64 = undefined;
            // `fast` ranks only the four simplest modes: DC, TM, VE, HE.
            const ranked: usize = if (e.effort == .fast) 4 else 10;
            for (0..ranked) |m| {
                dsp.predictSub(&sc, at, @intCast(m), &preds[m]);
                srcs[m] = &src;
                if (hidden) {
                    blended[m] = unhidden(16, &src, &preds[m], &hide);
                    srcs[m] = &blended[m];
                }
                score[m] = (@as(u64, dsp.satd4(srcs[m], &preds[m])) << 8) + mode_costs[m] * @as(u64, seg.y1.q[1]) / 2;
                // Insertion into `order` by score.
                var k = m;
                while (k > 0 and score[order[k - 1]] > score[m]) : (k -= 1) order[k] = order[k - 1];
                order[k] = @intCast(m);
            }
            const tries: usize = switch (e.effort) {
                .fast => 1,
                .default => 3,
                .best => 10,
            };
            const tried = order[0..@min(tries, ranked)];
            for (0..tried.len + @intFromBool(e.trellis == .final)) |k| {
                // With trellis quantization for the final choice only, the
                // best mode is coded again with it.
                const again = k == tried.len;
                const mode = if (again) best_mode else tried[k];
                const pred = &preds[mode];
                var res: [16]i16 = undefined;
                for (&res, srcs[mode], pred) |*r, s, p| r.* = @as(i16, s) - p;
                var coefs: [16]i16 = undefined;
                dsp.fdct(&res, &coefs);
                var lv: [16]i16 = undefined;
                var deq: [16]i16 = undefined;
                const last = if (again or e.trellis == .all)
                    trellis.quantize(&e.st.costs, 3, ctx, &coefs, &seg.y1, 0, 6, seg.tlam, &lv, &deq)
                else
                    dsp.quantize(&coefs, &seg.y1, 0, &lv, &deq);
                var recon = pred.*;
                dsp.inverse(last + 1, &deq, &recon, 4);
                const d = dsp.sse(4, 4, &recon, 4, srcs[mode]);
                const rate = mode_costs[mode] + e.st.costs.blockCost(3, ctx, 0, last, &lv);
                const j = rdCost(d, rate, seg.lam);
                if (j < best_j or again) {
                    best_j = j;
                    best_mode = mode;
                    best_lv = lv;
                    best_last = last;
                    best_recon = recon;
                }
            }
            total += best_j;
            if (total >= limit) return false;
            for (0..4) |r| {
                @memcpy(sc[at + r * dsp.ys ..][0..4], best_recon[r * 4 ..][0..4]);
                @memcpy(out.recon[(yi * 4 + r) * 16 + xi * 4 ..][0..4], best_recon[r * 4 ..][0..4]);
            }
            out.bmodes[n] = best_mode;
            out.mode_rate += mode_costs[best_mode];
            out.lv[n] = best_lv;
            out.last[n] = best_last;
            const f: u8 = @intFromBool(best_last >= 0);
            tnz = (tnz & ~(@as(u8, 1) << x)) | (f << x);
            lnz = (lnz & ~(@as(u8, 1) << y)) | (f << y);
            tm[x] = best_mode;
            lm[y] = best_mode;
        }
        out.j = total;
        return true;
    }

    fn chroma(
        e: *Enc,
        comptime hidden: bool,
        seg: *const Segment,
        suv: *const [2][64]u8,
        top_nz: u8,
        left_nz: u8,
        has_top: bool,
        has_left: bool,
        out: *Chroma,
    ) void {
        var cand: Chroma = .{};
        var preds: [4][2][64]u8 = undefined;
        for (&preds, 0..) |*p, m| {
            dsp.predictBlock(8, &e.st.u, dsp.c0, dsp.cs, @intCast(m), has_top, has_left, &p[0]);
            dsp.predictBlock(8, &e.st.v, dsp.c0, dsp.cs, @intCast(m), has_top, has_left, &p[1]);
        }
        // Both planes share the hidden mask.
        var hide2: [2][64]bool = undefined;
        if (hidden) hide2 = .{ e.hide_uv, e.hide_uv };
        const hide: ?*const [128]bool = if (hidden) @ptrCast(&hide2) else null;
        const only: ?u8 = if (e.effort == .fast)
            bestPrediction(8, 128, @ptrCast(suv), hide, @ptrCast(&preds), &uvmode_cost, seg.uv.q[1])
        else
            null;
        var best_mode: u8 = 0;
        for (0..5) |m| {
            // With trellis quantization only for the final choice, the
            // best mode is coded again with it.
            const again = m == 4;
            if (again and e.trellis != .final) break;
            const mode: u8 = if (again) best_mode else @intCast(m);
            if (only) |o| if (o != mode) continue;
            const use_trellis = again or e.trellis == .all;
            var rate = uvmode_cost[mode];
            var d: u32 = 0;
            var blended: [2][64]u8 = undefined;
            if (hide != null) for (0..2) |ch| {
                blended[ch] = unhidden(64, &suv[ch], &preds[mode][ch], &e.hide_uv);
            };
            const srcs = if (hide != null) &blended else suv;
            for (0..2) |ch| {
                const pred = &preds[mode][ch];
                cand.recon[ch] = pred.*;
                const shift: u3 = @intCast(4 + 2 * ch);
                var ct: u8 = (top_nz >> shift) & 3;
                var cl: u8 = (left_nz >> shift) & 3;
                for (0..4) |b| {
                    const x: u3 = @intCast(b % 2);
                    const y: u3 = @intCast(b / 2);
                    const at = @as(usize, y) * 32 + @as(usize, x) * 4;
                    var res: [16]i16 = undefined;
                    for (0..4) |r| for (0..4) |c| {
                        res[r * 4 + c] = @as(i16, srcs[ch][at + r * 8 + c]) - pred[at + r * 8 + c];
                    };
                    var coefs: [16]i16 = undefined;
                    dsp.fdct(&res, &coefs);
                    const k = ch * 4 + b;
                    var deq: [16]i16 = undefined;
                    const ctx: u2 = @intCast(((ct >> x) & 1) + ((cl >> y) & 1));
                    cand.last[k] = if (use_trellis)
                        trellis.quantize(&e.st.costs, 2, ctx, &coefs, &seg.uv, 0, 6, seg.tlam_uv, &cand.lv[k], &deq)
                    else
                        dsp.quantize(&coefs, &seg.uv, 0, &cand.lv[k], &deq);
                    dsp.inverse(cand.last[k] + 1, &deq, cand.recon[ch][at..], 8);
                    rate += e.st.costs.blockCost(2, ctx, 0, cand.last[k], &cand.lv[k]);
                    const f: u8 = @intFromBool(cand.last[k] >= 0);
                    ct = (ct & ~(@as(u8, 1) << x)) | (f << x);
                    cl = (cl & ~(@as(u8, 1) << y)) | (f << y);
                }
                d += dsp.sse(8, 8, &cand.recon[ch], 8, &srcs[ch]);
            }
            cand.j = rdCost(d, rate, seg.lam);
            cand.mode = mode;
            if (cand.j < out.j or again) {
                out.* = cand;
                best_mode = mode;
            }
        }
    }

    /// The main pass: every macroblock's modes and coefficients.
    fn run(e: *Enc) void {
        @memset(e.top_nz, 0);
        @memset(e.top_modes, dsp.b_dc);
        e.coefs_end = 0;
        e.mode_spent = 0;
        e.st.counts = std.mem.zeroes(coder.Hist);
        e.st.empty_counts = std.mem.zeroes(coder.Hist);
        for (0..e.mbh) |mby| {
            e.loadBand(mby);
            @memset(&e.left_modes, dsp.b_dc);
            e.left_nz = .{ 0, 0 };
            for (0..e.mbw) |mbx| e.encodeMb(mbx, mby);
        }
    }

    /// Chooses the token probabilities, and whether to code the skip flag.
    fn chooseProbs(e: *Enc) void {
        const st = e.st;
        var counts: coder.Counts = undefined;
        var empty_counts: coder.Counts = undefined;
        coder.nodeCounts(&st.counts, &counts);
        coder.nodeCounts(&st.empty_counts, &empty_counts);
        var empty: u64 = 0;
        for (e.info) |m| empty += @intFromBool(m.empty());
        const n: u64 = e.info.len;
        // Without the flag, empty macroblocks code an end of block per
        // block: the flag pays when it costs less than those.
        var eob_bits: u64 = 0;
        for (0..4) |t| for (0..8) |b| for (0..3) |c| {
            const k = empty_counts[t][b][c][0];
            eob_bits += @as(u64, k[0]) * tables.cost(tables.default_coeff_probs[t][b][c][0], 0);
        };
        e.skip_prob = branchProb(n - empty, empty);
        const flag_bits = 8 * 256 + (n - empty) * tables.cost(e.skip_prob, 0) + empty * tables.cost(e.skip_prob, 1);
        e.skip = empty > 0 and flag_bits < eob_bits;
        for (0..4) |t| for (0..8) |b| for (0..3) |c| for (0..11) |i| {
            var k = counts[t][b][c][i];
            if (!e.skip) {
                k[0] += empty_counts[t][b][c][i][0];
                k[1] += empty_counts[t][b][c][i][1];
            }
            const old = tables.default_coeff_probs[t][b][c][i];
            st.probs[t][b][c][i] = old;
            if (k[0] + k[1] == 0) continue;
            const new = branchProb(k[0], k[1]);
            const upd = tables.coeff_update_probs[t][b][c][i];
            const zeros: u64 = k[0];
            const ones: u64 = k[1];
            const before = zeros * tables.cost(old, 0) + ones * tables.cost(old, 1) + tables.cost(upd, 0);
            const after = zeros * tables.cost(new, 0) + ones * tables.cost(new, 1) + tables.cost(upd, 1) + 8 * 256;
            if (after < before) st.probs[t][b][c][i] = new;
        };
    }

    /// The first partition: the frame header, then every macroblock's
    /// modes (sections 9, 11, 19.2, 19.3).
    fn writeFirst(e: *Enc, bw: anytype) void {
        const st = e.st;
        bw.put(128, 0); // color space
        bw.put(128, 0); // clamping required
        bw.put(128, @intFromBool(e.segments));
        if (e.segments) {
            bw.put(128, 1); // update the map
            bw.put(128, 1); // update the data
            bw.put(128, 1); // absolute values
            for (e.segs) |s| coder.maybeSigned(bw, 7, s.qi);
            for (e.segs) |s| coder.maybeSigned(bw, 6, s.filter);
            for (e.seg_probs) |p| {
                bw.put(128, @intFromBool(p != 255));
                if (p != 255) coder.literal(bw, 8, p);
            }
        }
        bw.put(128, 0); // the normal filter
        coder.literal(bw, 6, e.frame_filter);
        coder.literal(bw, 3, 0); // sharpness
        bw.put(128, 0); // no mode and reference deltas
        coder.literal(bw, 2, 0); // one token partition
        coder.literal(bw, 7, e.segs[0].qi);
        for (0..5) |_| bw.put(128, 0); // no quantizer deltas
        bw.put(128, 0); // refresh_entropy_probs
        for (0..4) |t| for (0..8) |b| for (0..3) |c| for (0..11) |i| {
            const p = st.probs[t][b][c][i];
            const upd = tables.coeff_update_probs[t][b][c][i];
            if (p != tables.default_coeff_probs[t][b][c][i]) {
                bw.put(upd, 1);
                coder.literal(bw, 8, p);
            } else {
                bw.put(upd, 0);
            }
        };
        bw.put(128, @intFromBool(e.skip));
        if (e.skip) coder.literal(bw, 8, e.skip_prob);

        @memset(e.top_modes, dsp.b_dc);
        for (0..e.mbh) |mby| {
            var left: [4]u8 = @splat(dsp.b_dc);
            for (0..e.mbw) |mbx| {
                const m = e.info[mby * e.mbw + mbx];
                const top = e.top_modes[4 * mbx ..][0..4];
                if (e.segments) {
                    const s = m.segment();
                    bw.put(e.seg_probs[0], @intCast(s >> 1));
                    bw.put(e.seg_probs[1 + @as(usize, s >> 1)], @intCast(s & 1));
                }
                if (e.skip) bw.put(e.skip_prob, @intFromBool(m.empty()));
                bw.put(145, @intFromBool(!m.isI4()));
                if (m.isI4()) {
                    for (0..16) |k| {
                        const mode = m.bmode(k);
                        writeBmode(bw, top[k % 4], left[k / 4], mode);
                        top[k % 4] = mode;
                        left[k / 4] = mode;
                    }
                } else {
                    const ym = m.ymode();
                    bw.put(156, @intCast(ym >> 1));
                    bw.put(if (ym >> 1 == 0) 163 else 128, @intCast(ym & 1));
                    @memset(top, ymode_context[ym]);
                    @memset(&left, ymode_context[ym]);
                }
                const uv = m.uvmode();
                bw.put(142, @intFromBool(uv != dsp.dc_pred));
                if (uv != dsp.dc_pred) {
                    bw.put(114, @intFromBool(uv != dsp.v_pred));
                    if (uv != dsp.v_pred) bw.put(183, @intFromBool(uv == dsp.tm_pred));
                }
            }
        }
    }

    /// Source row `y`'s alpha into `out`.
    fn alphaRow(e: *Enc, y: u32, out: []u8) void {
        const px = e.rgbRow(y, 0);
        for (out, 0..) |*a, x| a.* = px[4 * x + 3];
    }

    /// Whether any alpha is not opaque.
    fn hasAlpha(e: *Enc) bool {
        const row = e.alpha_rows;
        for (0..e.height) |y| {
            e.alphaRow(@intCast(y), row);
            for (row) |a| if (a != 255) return true;
        }
        return false;
    }

    /// The alpha plane into `alpha_plane`, and its lossless stream into
    /// `alpha_out`; the stream's length, or null when it is no smaller
    /// than the plane.
    fn compressAlpha(e: *Enc, effort: Effort) EncodeError!?usize {
        const w: usize = e.width;
        for (0..e.height) |y| e.alphaRow(@intCast(y), e.alpha_plane[y * w ..][0..w]);
        var out: Io.Writer = .fixed(e.alpha_out);
        const level = alphaEffort(effort);
        lossless.encodeAlpha(&out, e.alpha_plane, e.width, e.height, level, e.alpha_work) catch |err| switch (err) {
            // The stream would not fit in the plane's size.
            error.WriteFailed => return null,
            error.BadMetadata => unreachable,
            else => |x| return x,
        };
        return out.end;
    }

    /// The ALPH chunk, unfiltered: the lossless stream `compressed`, or the
    /// plane raw, streamed from the source when it was not kept.
    fn writeAlpha(e: *Enc, w: *Io.Writer, compressed: ?usize, len: u64) EncodeError!void {
        try w.writeAll("ALPH");
        try w.writeInt(u32, @intCast(len), .little);
        try w.writeByte(@intFromBool(compressed != null));
        const n = @as(usize, e.width) * e.height;
        if (compressed) |c| {
            try w.writeAll(e.alpha_out[0..c]);
        } else if (e.alpha_plane.len == n) {
            try w.writeAll(e.alpha_plane);
        } else for (0..e.height) |y| {
            e.alphaRow(@intCast(y), e.alpha_rows);
            try w.writeAll(e.alpha_rows);
        }
        if (len % 2 == 1) try w.writeByte(0);
    }

    /// The token partition.
    fn writeTokens(e: *Enc, comptime W: type, bw: *W) void {
        const E = coder.Emit(W);
        const ems: [4]E = .{
            .{ .w = bw, .probs = &e.st.probs[0] },
            .{ .w = bw, .probs = &e.st.probs[1] },
            .{ .w = bw, .probs = &e.st.probs[2] },
            .{ .w = bw, .probs = &e.st.probs[3] },
        };
        @memset(e.top_nz, 0);
        var at: usize = 0;
        for (0..e.mbh) |mby| {
            var left: [2]u8 = .{ 0, 0 };
            for (0..e.mbw) |mbx| {
                const m = e.info[mby * e.mbw + mbx];
                walkMb(E, &ems, m, e.coefs, &at, e.top_nz[2 * mbx ..][0..2], &left, e.skip);
            }
        }
    }
};

/// The probability of a 0 for a branch taken `zeros` and `ones` times,
/// as a decoder reads it: 1 to 255.
fn branchProb(zeros: u64, ones: u64) u8 {
    const n = zeros + ones;
    if (n == 0) return 255;
    return @intCast(std.math.clamp((zeros * 256 + n / 2) / n, 1, 255));
}

/// One macroblock's tokens from the store at `at`, in the order a decoder
/// reads them (section 19.3), through emitters by block type, keeping the
/// nonzero contexts above (`top`) and to the left: byte 0 the luma and
/// chroma blocks' flags, byte 1 the Y2 block's. With `skip`, a macroblock
/// without coefficients codes none.
fn walkMb(
    comptime E: type,
    ems: *const [4]E,
    m: MbInfo,
    data: []const u8,
    at: *usize,
    top: *[2]u8,
    left: *[2]u8,
    skip: bool,
) void {
    const is_i4 = m.isI4();
    if (m.empty() and skip) {
        top[0] = 0;
        left[0] = 0;
        if (!is_i4) {
            top[1] = 0;
            left[1] = 0;
        }
        return;
    }
    const has_data = !m.empty();
    var lv: [16]i16 = @splat(0);
    if (!is_i4) {
        const last = load(data, at, has_data, 0, &lv);
        coder.block(ems[1], @intCast(top[1] + left[1]), 0, last, &lv);
        const f: u8 = @intFromBool(last >= 0);
        top[1] = f;
        left[1] = f;
    }
    const first: u5 = if (is_i4) 0 else 1;
    const ytype: usize = if (is_i4) 3 else 0;
    var tnz = top[0];
    var lnz = left[0];
    for (0..16) |n| {
        const x: u3 = @intCast(n % 4);
        const y: u3 = @intCast(n / 4);
        const last = load(data, at, has_data, first, &lv);
        coder.block(ems[ytype], @intCast(((tnz >> x) & 1) + ((lnz >> y) & 1)), first, last, &lv);
        const f: u8 = @intFromBool(last >= first);
        tnz = (tnz & ~(@as(u8, 1) << x)) | (f << x);
        lnz = (lnz & ~(@as(u8, 1) << y)) | (f << y);
    }
    for (0..2) |ch| {
        const shift: u3 = @intCast(4 + 2 * ch);
        for (0..4) |b| {
            const x: u3 = @intCast(shift + b % 2);
            const y: u3 = @intCast(shift + b / 2);
            const last = load(data, at, has_data, 0, &lv);
            coder.block(ems[2], @intCast(((tnz >> x) & 1) + ((lnz >> y) & 1)), 0, last, &lv);
            const f: u8 = @intFromBool(last >= 0);
            tnz = (tnz & ~(@as(u8, 1) << x)) | (f << x);
            lnz = (lnz & ~(@as(u8, 1) << y)) | (f << y);
        }
    }
    top[0] = tnz;
    left[0] = lnz;
}

/// One block's levels from the store into `lv` from `first`; returns the
/// last position, below `first` for none.
fn load(data: []const u8, at: *usize, has_data: bool, first: u5, lv: *[16]i16) i32 {
    if (!has_data) return @as(i32, first) - 1;
    var i = at.*;
    const n = data[i];
    i += 1;
    for (lv[first..][0..n]) |*v| {
        const b = data[i];
        if (b & 0x80 == 0) {
            v.* = @as(i7, @bitCast(@as(u7, @truncate(b))));
            i += 1;
        } else {
            const u: u15 = @intCast(@as(u16, b & 0x7f) << 8 | data[i + 1]);
            v.* = @as(i15, @bitCast(u));
            i += 2;
        }
    }
    at.* = i;
    return @as(i32, first) + n - 1;
}

/// Writes `src` as a lossy WebP file to `w`.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    try src.check();
    if (src.width == 0 or src.height == 0) return error.EmptyImage;
    if (src.width > max_side or src.height > max_side) return error.ImageTooLarge;
    const l = Layout.init(options, src.width, src.height).?;
    if (work.len < l.total) return error.WorkTooSmall;
    const base = std.mem.alignForward(usize, @intFromPtr(work.ptr), @alignOf(State)) - @intFromPtr(work.ptr);
    const mem = work[base..];
    const mbs = l.mbw * l.mbh;
    const pixels = @as(usize, src.width) * src.height;
    const rgb_format: PixelFormat = if (src.format.hasAlpha()) .rgba8 else .rgb8;
    var e: Enc = .{
        .src = src,
        .width = src.width,
        .height = src.height,
        .mbw = l.mbw,
        .mbh = l.mbh,
        .effort = options.effort,
        .st = @ptrCast(@alignCast(mem[l.state..].ptr)),
        .info = @as([*]MbInfo, @ptrCast(mem[l.info..].ptr))[0..mbs],
        .act = mem[l.act..][0..mbs],
        .coefs = mem[l.coefs..][0..l.coefs_len],
        .w16 = 16 * l.mbw,
        .w8 = 8 * l.mbw,
        .band_y = mem[l.band_y..][0 .. 256 * l.mbw],
        .band_u = mem[l.band_u..][0 .. 64 * l.mbw],
        .band_v = mem[l.band_v..][0 .. 64 * l.mbw],
        .rgb = mem[l.rgb..][0 .. 8 * @as(usize, src.width)],
        .top_y = mem[l.top_y..][0 .. 16 * l.mbw + 4],
        .top_u = mem[l.top_u..][0 .. 8 * l.mbw],
        .top_v = mem[l.top_v..][0 .. 8 * l.mbw],
        .top_modes = mem[l.top_modes..][0 .. 4 * l.mbw],
        .top_nz = mem[l.top_nz..][0 .. 2 * l.mbw],
        .alpha_rows = mem[l.alpha..][0..src.width],
        .band_hidden = @as([*]bool, @ptrCast(mem[l.band_hidden..].ptr))[0 .. 256 * l.mbw],
        .band_hidden_uv = @as([*]bool, @ptrCast(mem[l.band_hidden_uv..].ptr))[0 .. 64 * l.mbw],
        .alpha_plane = if (options.alpha_compression) mem[l.alpha_plane..][0..pixels] else &.{},
        .alpha_out = if (options.alpha_compression) mem[l.alpha_out..][0..pixels] else &.{},
        .alpha_work = mem[l.alpha_work..][0..l.alpha_work_len],
        .rgb_format = rgb_format,
        .conv = .init(rgb_format, src.format),
    };

    // Alpha, when any is not opaque: compressed when that is smaller.
    // Prediction filters before the lossless encoder measured larger
    // than none, whose own predictors do better, and raw alpha is the
    // same size filtered or not, so the ALPH chunk is never filtered.
    const has_alpha = rgb_format == .rgba8 and e.hasAlpha();
    var compressed: ?usize = null;
    if (has_alpha and options.alpha_compression) compressed = try e.compressAlpha(options.effort);

    const base_qi = quantizerIndex(options.quality);
    e.trellis = switch (options.effort) {
        .fast => .off,
        .default => .final,
        .best => .all,
    };
    for (e.info) |*m| m.* = .{ .flags = 0, .bmodes = @splat(0) };
    e.segments = options.effort != .fast and mbs > 1;
    if (e.segments) {
        e.analyze();
        e.chooseSegments(base_qi);
    } else {
        e.segs = @splat(.init(base_qi));
    }
    for (e.segs) |s| e.frame_filter = @max(e.frame_filter, s.filter);

    // 15/16 of the first partition, less about 2 bits a macroblock for its
    // segment and skip flag, which the budget does not count.
    const budget = (((1 << 19) - 64) * 8 * 256 / 16 * 15) / mbs;
    if (budget < 160 * 256) e.mode_budget = budget -| 2 * 256;

    e.st.costs.init(&tables.default_coeff_probs);
    if (options.effort == .best) {
        e.run();
        e.chooseProbs();
        e.st.costs.init(&e.st.probs);
    }
    e.run();
    e.chooseProbs();

    // The first partition's length has 19 bits. A large image's modes can
    // overflow it, since a 4x4-predicted macroblock's take about 3 bytes
    // and a 16x16 one's well under 1, so past about 6 megapixels the
    // modes are held to a budget (`mode_budget`). Should they overflow
    // anyway, 4x4 prediction and the segment map are given up. Past about
    // 150 megapixels even that can overflow, and the image is too large,
    // as it is for libwebp.
    var first_len = firstLen(&e);
    if (first_len >= 1 << 19) {
        e.mode_budget = 0;
        if (e.segments) {
            e.segments = false;
            e.segs = @splat(.init(base_qi));
            e.frame_filter = e.segs[0].filter;
            for (e.info) |*m| m.flags &= ~@as(u8, 3);
        }
        e.run();
        e.chooseProbs();
        first_len = firstLen(&e);
    }
    if (first_len >= 1 << 19) return error.ImageTooLarge;

    // Size the second, then write the file.
    // The token partition is coded into the level store's spare room,
    // which its worst case leaves, and copied out from there; should it
    // not fit, its length is still counted, and it is coded again
    // straight to the output.
    var spare: Io.Writer = .fixed(e.coefs[e.coefs_end..]);
    var b1: coder.Writer = .{ .out = &spare };
    e.writeTokens(coder.Writer, &b1);
    const held: ?[]const u8 = if (b1.finish()) spare.buffered() else |_| null;
    const vp8_len = 10 + first_len + b1.written;
    const alpha_len: u64 = if (!has_alpha) 0 else 1 + (compressed orelse @as(u64, src.width) * src.height);
    const extended = has_alpha or options.icc != null or options.exif != null or options.xmp != null;
    var riff_len: u64 = 4 + chunkLen(vp8_len);
    if (extended) {
        riff_len += chunkLen(10);
        if (options.icc) |b| riff_len += chunkLen(b.len);
        if (has_alpha) riff_len += chunkLen(alpha_len);
        if (options.exif) |b| riff_len += chunkLen(b.len);
        if (options.xmp) |b| riff_len += chunkLen(b.len);
    }
    if (riff_len > std.math.maxInt(u32) - 8) return error.ImageTooLarge;

    try w.writeAll("RIFF");
    try w.writeInt(u32, @intCast(riff_len), .little);
    try w.writeAll("WEBP");
    if (extended) {
        var x: [10]u8 = @splat(0);
        if (options.icc != null) x[0] |= 0x20;
        if (has_alpha) x[0] |= 0x10;
        if (options.exif != null) x[0] |= 0x08;
        if (options.xmp != null) x[0] |= 0x04;
        std.mem.writeInt(u24, x[4..7], @intCast(src.width - 1), .little);
        std.mem.writeInt(u24, x[7..10], @intCast(src.height - 1), .little);
        try writeChunk(w, "VP8X", &x);
        if (options.icc) |b| try writeChunk(w, "ICCP", b);
        if (has_alpha) try e.writeAlpha(w, compressed, alpha_len);
    }
    try w.writeAll("VP8 ");
    try w.writeInt(u32, @intCast(vp8_len), .little);
    var head: [10]u8 = undefined;
    // A key frame, version 0, shown, and the first partition's size.
    std.mem.writeInt(u24, head[0..3], @intCast((1 << 4) | (first_len << 5)), .little);
    head[3..6].* = .{ 0x9d, 0x01, 0x2a };
    std.mem.writeInt(u16, head[6..8], @intCast(src.width), .little);
    std.mem.writeInt(u16, head[8..10], @intCast(src.height), .little);
    try w.writeAll(&head);
    var b0: coder.Writer = .{ .out = w };
    e.writeFirst(&b0);
    try b0.finish();
    if (held) |bytes| {
        try w.writeAll(bytes);
    } else {
        var again: coder.Writer = .{ .out = w };
        e.writeTokens(coder.Writer, &again);
        try again.finish();
        std.debug.assert(again.written == b1.written);
    }
    std.debug.assert(b0.written == first_len);
    if (vp8_len % 2 == 1) try w.writeByte(0);
    if (extended) {
        if (options.exif) |b| try writeChunk(w, "EXIF", b);
        if (options.xmp) |b| try writeChunk(w, "XMP ", b);
    }
}

/// The first partition's length in bytes.
fn firstLen(e: *Enc) u64 {
    var c: coder.Counter = .{};
    e.writeFirst(&c);
    return c.bytes();
}

/// A chunk's bytes in the file: its header, payload, and padding.
fn chunkLen(n: u64) u64 {
    return 8 + n + (n & 1);
}

fn writeChunk(w: *Io.Writer, fourcc: *const [4]u8, payload: []const u8) EncodeError!void {
    try w.writeAll(fourcc);
    try w.writeInt(u32, @intCast(payload.len), .little);
    try w.writeAll(payload);
    if (payload.len % 2 == 1) try w.writeByte(0);
}

/// BT.601 limited-range luma of an RGB pixel, in 16-bit fixed point.
inline fn luma(p: *const [3]u8) u8 {
    const r: i32 = p[0];
    const g: i32 = p[1];
    const b: i32 = p[2];
    return @intCast((16829 * r + 33039 * g + 6416 * b + (16 << 16) + (1 << 15)) >> 16);
}

test {
    _ = dsp;
    _ = coder;
    _ = trellis;
}

const Decoder = @import("Decoder.zig");

/// Encodes `src` and decodes it with our decoder into `dst` (its native
/// format), returning the file's length.
fn roundTrip(src: PixelBuffer, options: EncodeOptions, dst: []u8) !usize {
    const gpa = testing.allocator;
    const work = try gpa.alloc(u8, workLen(options, src.width, src.height).?);
    defer gpa.free(work);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try encode(&out.writer, src, options, work);
    var r: Io.Reader = .fixed(out.written());
    var d = Decoder.init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(src.width, config.width);
    try testing.expectEqual(src.height, config.height);
    const dwork = try gpa.alloc(u8, config.work_len);
    defer gpa.free(dwork);
    const buf = try PixelBuffer.init(dst, config.native, src.width, src.height);
    _ = try d.decodeFrame(buf, dwork);
    return out.written().len;
}

/// Peak signal to noise ratio of `a` against `b`, in dB.
fn psnr(a: []const u8, b: []const u8) f64 {
    return psnrVisible(a, b, 1);
}

/// The same over RGBA pixels' color, leaving out those whose alpha in `b`
/// is 0 (`bpp` 4), or over every byte (`bpp` 1).
fn psnrVisible(a: []const u8, b: []const u8, comptime bpp: usize) f64 {
    var sum: f64 = 0;
    var n: f64 = 0;
    for (0..a.len / bpp) |i| {
        if (bpp == 4 and b[4 * i + 3] == 0) continue;
        for (0..@min(bpp, 3)) |c| {
            const d = @as(f64, @floatFromInt(a[bpp * i + c])) - @as(f64, @floatFromInt(b[bpp * i + c]));
            sum += d * d;
            n += 1;
        }
    }
    const mse = sum / @max(n, 1);
    return 10 * @log10(255.0 * 255.0 / @max(mse, 1e-9));
}

test "a smooth image round-trips at every effort, better at higher quality" {
    const w = 77;
    const h = 45;
    var px: [w * h * 3]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 3;
        px[i] = @intCast((x * 255) / w);
        px[i + 1] = @intCast((y * 255) / h);
        px[i + 2] = @intCast(128 + @as(i32, @intFromFloat(60 * @sin(@as(f64, @floatFromInt(x + y)) / 6))));
    };
    const src = try PixelBuffer.init(&px, .rgb8, w, h);
    var got: [w * h * 3]u8 = undefined;
    for ([_]Effort{ .fast, .default, .best }) |effort| {
        var last_psnr: f64 = 0;
        var last_len: usize = 0;
        for ([_]u8{ 30, 75, 95 }) |q| {
            const len = try roundTrip(src, .{ .quality = q, .effort = effort }, &got);
            const p = psnr(&got, &px);
            try testing.expect(p > last_psnr);
            try testing.expect(len > last_len);
            last_psnr = p;
            last_len = len;
        }
        try testing.expect(last_psnr > 38);
    }
}

test "alpha is kept exactly" {
    const w = 19;
    const h = 23;
    var px: [w * h * 4]u8 = undefined;
    var got: [w * h * 4]u8 = undefined;
    // A pattern, and a gradient that the lossless encoder compresses.
    for (0..2) |pattern| {
        for (0..h) |y| for (0..w) |x| {
            const i = (y * w + x) * 4;
            px[i] = @intCast(x * 13);
            px[i + 1] = @intCast(y * 11);
            px[i + 2] = 90;
            px[i + 3] = if (pattern == 0) @intCast((x * y * 7) % 256) else @intCast(x * 8);
        };
        const src = try PixelBuffer.init(&px, .rgba8, w, h);
        var lens: [2]usize = undefined;
        for (&lens, [_]bool{ true, false }) |*len, compress| {
            len.* = try roundTrip(src, .{ .alpha_compression = compress }, &got);
            for (0..w * h) |i| try testing.expectEqual(px[4 * i + 3], got[4 * i + 3]);
            try testing.expect(psnrVisible(&got, &px, 4) > 30);
        }
        if (pattern == 1) try testing.expect(lens[0] + w * h / 2 < lens[1]);
    }
}
