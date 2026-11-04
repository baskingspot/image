//! Trellis quantization: the levels of one block that cost least in
//! squared error plus lambda times their tokens' bits, found by dynamic
//! programming over the coding positions.
//!
//! A token's cost depends on the block type, the band, and the context
//! the previous token leaves (0, 1, or more than 1, and whether it was a
//! zero, after which no end-of-block test is coded), so a path through
//! the block is scored position by position: at each, the candidate
//! levels are the magnitude rounded to nearest and one less, and each
//! remembers the cheaper of the paths into it. The block can end after
//! any nonzero level, zeroing what follows.

const std = @import("std");
const testing = std.testing;
const tables = @import("vp8_encode_tables.zig");
const dsp = @import("vp8_encode_dsp.zig");
const coder = @import("vp8_encode_bool.zig");
const zigzag = tables.zigzag;
const bands = tables.bands;
const U32x = @Vector(16, u32);
const I32x = @Vector(16, i32);

/// The cost of a token of magnitude `a` from one context's table.
inline fn tokenCost(tab: *const [68]u16, a: u32) u32 {
    return if (a < 67) tab[a] else tab[67] + tables.cat6_cost[@min(a, tables.max_level) - 67];
}

inline fn context(a: u32) u2 {
    return if (a == 0) 0 else if (a == 1) 1 else 2;
}

/// Quantizes a block's coefficients (raster order) of token type `t`
/// from position `first`, whose first token has context `ctx0`, as
/// `dsp.quantize` does, but choosing the levels that minimize
/// `squared error << dshift` (pixel squared error in 1/256, which is 1/4
/// of the coefficients' for a DCT and 1/16 for the WHT) plus `lam` times
/// the bits in 1/256. Returns the last nonzero position, or -1.
pub fn quantize(
    costs: *const coder.Costs,
    t: usize,
    ctx0: u2,
    coefs: *const [16]i16,
    m: *const dsp.Quant,
    first: u5,
    dshift: u6,
    lam: u64,
    levels: *[16]i16,
    deq: *[16]i16,
) i32 {
    const z = @shuffle(i32, @as(@Vector(16, i32), @as(@Vector(16, i16), coefs.*)), undefined, dsp.zigzag_mask);
    const av: U32x = @abs(z);
    // The nearest level, by the reciprocal.
    var nv: U32x = @min(((av + (m.q >> @splat(1))) * m.iq) >> @splat(17), @as(U32x, @splat(tables.max_level)));
    if (first == 1) nv[0] = 0;
    // Past the last position whose nearest level is not 0, every path
    // codes zeros, so the search stops there.
    const nz: u16 = @bitCast(nv != @as(U32x, @splat(0)));
    if (nz == 0) {
        levels.* = @splat(0);
        deq.* = @splat(0);
        return -1;
    }
    const stop: usize = 16 - @clz(nz);
    // The candidates at each position: one less than the nearest level,
    // and the nearest (0 twice when the nearest is 0), and their squared
    // errors; the errors fit 32 bits.
    const zero: U32x = @splat(0);
    const some = nv != zero;
    const lo: [16]u32 = nv -| @as(U32x, @splat(1));
    const hi: [16]u32 = nv;
    const ai: I32x = @intCast(av);
    const e_hi = ai - @as(I32x, @intCast(nv * m.q));
    const e_lo = @select(i32, some, e_hi + @as(I32x, @intCast(m.q)), ai);
    const d_lo: [16]u32 = @as(U32x, @intCast(e_lo * e_lo));
    const d_hi: [16]u32 = @as(U32x, @intCast(e_hi * e_hi));
    var sq_v: U32x = av * av;
    if (first == 1) sq_v[0] = 0;
    const sq: [16]u32 = sq_v;
    // The squared error of zeroing the positions from the current one
    // until `stop` (what follows it is zeroed whatever is chosen).
    var rest: u64 = 0;
    for (sq[0..stop]) |v| rest += v;
    const shift = dshift + 8;

    var score: [16][2]u64 = undefined;
    var from: [16][2]u1 = undefined;
    // The empty block first, then ending after each nonzero candidate.
    var best = (rest << shift) + lam * costs.eob[t][bands[first]][ctx0];
    var best_n: i32 = -1;
    var best_i: u1 = 0;
    var n: usize = first;
    while (n < stop) : (n += 1) {
        const band = bands[n];
        rest -= sq[n];
        const cand = [2]u32{ lo[n], hi[n] };
        const dist = [2]u64{ @as(u64, d_lo[n]) << shift, @as(u64, d_hi[n]) << shift };
        // The token tables by the previous level's context: after a zero,
        // there is no end-of-block test.
        const tabs = [3]*const [68]u16{
            &costs.after_zero[t][band][0],
            &costs.lead[t][band][1],
            &costs.lead[t][band][2],
        };
        const eobs = &costs.eob[t][bands[n + 1]];
        for (0..2) |i| {
            const l = cand[i];
            var s: u64 = undefined;
            if (n == first) {
                s = lam * tokenCost(&costs.lead[t][band][ctx0], l);
                from[n][i] = 0;
            } else {
                const s0 = score[n - 1][0] + lam * tokenCost(tabs[context(lo[n - 1])], l);
                const s1 = score[n - 1][1] + lam * tokenCost(tabs[context(hi[n - 1])], l);
                from[n][i] = @intFromBool(s1 < s0);
                s = @min(s0, s1);
            }
            s += dist[i];
            score[n][i] = s;
            var end = s + (rest << shift);
            if (n < 15) end += lam * eobs[context(l)];
            if (l != 0 and end < best) {
                best = end;
                best_n = @intCast(n);
                best_i = @intCast(i);
            }
        }
    }

    if (best_n < 0) {
        levels.* = @splat(0);
        deq.* = @splat(0);
        return -1;
    }
    var lv: [16]u32 = @splat(0);
    var i = best_i;
    var k: usize = @intCast(best_n);
    while (true) {
        lv[k] = if (i == 0) lo[k] else hi[k];
        if (k == first) break;
        i = from[k][i];
        k -= 1;
    }
    const mag: I32x = @intCast(@as(U32x, lv));
    const v = @select(i32, z < @as(I32x, @splat(0)), -mag, mag);
    levels.* = @as(@Vector(16, i16), @intCast(v));
    deq.* = @as(@Vector(16, i16), @intCast(@shuffle(i32, v * @as(I32x, @intCast(m.q)), undefined, dsp.unzigzag)));
    return best_n;
}

test "the trellis finds the cheapest levels among its candidates" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const r = prng.random();
    var costs: coder.Costs = undefined;
    for (0..40) |round| {
        // Random probabilities, so that every table the walk picks from
        // differs from the others.
        var probs: coder.Probs = undefined;
        for (std.mem.asBytes(&probs)) |*p| p.* = 1 + r.uintLessThan(u8, 255);
        costs.init(&probs);
        const t = round % 4;
        const first: u5 = if (round % 4 == 0) 1 else 0;
        const ctx0: u2 = @intCast(round % 3);
        const step: u32 = 4 + r.uintLessThan(u32, 40);
        const m: dsp.Quant = .init(step + 3, step, 64, 64);
        // Mostly small coefficients, so many positions sit between two
        // levels, and some large ones that need DCT_CAT6.
        // The first ten coded positions vary, so that every choice can be
        // tried; the rest are zero.
        var coefs: [16]i16 = @splat(0);
        for (first..first + 10) |k| {
            const big = r.uintLessThan(u32, 10) == 0;
            const range: i32 = if (big) 4000 else @intCast(3 * step / @as(u32, @intCast(k + 1)) + 1);
            coefs[zigzag[k]] = @intCast(r.intRangeAtMost(i32, -range, range));
        }
        const dshift: u6 = if (t == 1) 4 else 6;
        // From where error dominates to where bits do (the encoder's is
        // about 5 step² for a DCT).
        const lam: u64 = step * step * (1 + r.uintLessThan(u64, 40));
        var levels: [16]i16 = undefined;
        var deq: [16]i16 = undefined;
        const last = quantize(&costs, t, ctx0, &coefs, &m, first, dshift, lam, &levels, &deq);

        // Every combination of candidates, cut off after each position,
        // scored with the coder's own block cost.
        const q: [16]u32 = m.q;
        var cands: [16][2]i16 = undefined;
        for (0..16) |k| {
            const c = coefs[zigzag[k]];
            const a: u32 = @abs(c);
            const iq: [16]u32 = m.iq;
            const near: i16 = @intCast(@min(((a + q[k] / 2) * iq[k]) >> 17, tables.max_level));
            const lo: i16 = @max(near - 1, 0);
            cands[k] = if (c < 0) .{ -lo, -near } else .{ lo, near };
        }
        const score = struct {
            fn f(
                cs: *const coder.Costs,
                tt: usize,
                c0: u2,
                fst: u5,
                lv: *const [16]i16,
                cf: *const [16]i16,
                qq: *const [16]u32,
                ds: u6,
                la: u64,
            ) u64 {
                var lst: i32 = -1;
                for (fst..16) |k| if (lv[k] != 0) {
                    lst = @intCast(k);
                };
                var d: u64 = 0;
                for (fst..16) |k| {
                    const e = @as(i64, cf[zigzag[k]]) - @as(i64, lv[k]) * qq[k];
                    d += @intCast(e * e);
                }
                return (d << (ds + 8)) + la * cs.blockCost(tt, c0, fst, lst, lv);
            }
        }.f;
        var least: u64 = std.math.maxInt(u64);
        var try_lv: [16]i16 = @splat(0);
        var combo: u32 = 0;
        while (combo < 1 << 10) : (combo += 1) {
            for (first..first + 10) |k| try_lv[k] = cands[k][(combo >> @intCast(k - first)) & 1];
            for (first..first + 11) |cut| {
                var cut_lv = try_lv;
                @memset(cut_lv[cut..], 0);
                least = @min(least, score(&costs, t, ctx0, first, &cut_lv, &coefs, &q, dshift, lam));
            }
        }
        try testing.expectEqual(least, score(&costs, t, ctx0, first, &levels, &coefs, &q, dshift, lam));
        // The levels, their last position, and the dequantized values
        // agree.
        var want_last: i32 = -1;
        for (first..16) |k| if (levels[k] != 0) {
            want_last = @intCast(k);
        };
        try testing.expectEqual(want_last, last);
        for (0..16) |k| try testing.expectEqual(@as(i32, levels[k]) * @as(i32, @intCast(q[k])), deq[zigzag[k]]);
    }
}
