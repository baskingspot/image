//! Modular image data (ISO/IEC 18181-1, Annex on modular mode): integer
//! channels predicted by a meta-adaptive tree, the weighted predictor, and
//! the reversible transforms (RCT, palette, squeeze).
//!
//! A stream is a group header, its transforms, an optional local tree and
//! histograms, and the channels' residuals. `decodeStream` decodes one into
//! an `Image` whose channels the caller sized, and undoes the stream's
//! transforms when asked. Arithmetic follows the specification's integer
//! definitions; where it overflows on hostile input it wraps, so a decode
//! never traps.

const std = @import("std");
const testing = std.testing;

const BitReader = @import("BitReader.zig");
const entropy = @import("entropy.zig");
const Arena = @import("Arena.zig");
const vfill = @import("../fill.zig").fill;
const unpackSigned = @import("headers.zig").unpackSigned;

pub const Error = entropy.Error || error{
    /// The image data breaks the specification: an invalid tree,
    /// transform, or channel layout.
    BadImage,
};

/// Channels an image may gain from its transforms beyond those it starts
/// with; more is `TooComplex` (docs/slop/jxl.md, work memory).
pub const max_added_channels = 2048;

pub const Channel = struct {
    w: u32,
    h: u32,
    hshift: i16 = 0,
    vshift: i16 = 0,
    /// `w * h` samples, row after row; or with `ring`, `ring` rows, row
    /// `y` at `y % ring`.
    data: []i32 = &.{},
    ring: u32 = 0,

    pub fn row(c: *const Channel, y: usize) []i32 {
        const at = if (c.ring == 0) y else y % c.ring;
        return c.data[at * c.w ..][0..c.w];
    }

    fn sameShape(a: *const Channel, b: *const Channel) bool {
        return a.w == b.w and a.h == b.h and a.hshift == b.hshift and a.vshift == b.vshift;
    }
};

pub const WpHeader = struct {
    p1c: i64 = 16,
    p2c: i64 = 10,
    p3c: [5]i64 = .{ 7, 7, 7, 0, 0 },
    w: [4]u32 = .{ 0xd, 0xc, 0xc, 0xc },

    fn read(br: *BitReader) Error!WpHeader {
        var h: WpHeader = .{};
        if (try br.boolean()) return h;
        h.p1c = try br.bits(5);
        h.p2c = try br.bits(5);
        for (&h.p3c) |*p| p.* = try br.bits(5);
        for (&h.w) |*w| w.* = try br.bits(4);
        return h;
    }
};

pub const SqueezeParams = struct {
    horizontal: bool,
    in_place: bool,
    begin_c: u32,
    num_c: u32,
};

pub const Transform = struct {
    kind: Kind,
    begin_c: u32 = 0,
    rct_type: u32 = 0,
    num_c: u32 = 0,
    nb_colors: u32 = 0,
    nb_deltas: u32 = 0,
    predictor: u32 = 0,
    squeezes: []SqueezeParams = &.{},

    pub const Kind = enum { rct, palette, squeeze };

    fn read(br: *BitReader, arena: *Arena) Error!Transform {
        const id = try br.bits(2);
        var t: Transform = .{ .kind = switch (id) {
            0 => .rct,
            1 => .palette,
            2 => .squeeze,
            else => return error.BadImage,
        } };
        if (t.kind != .squeeze) {
            t.begin_c = try br.u32Dist(.{ .b(3), .bo(6, 8), .bo(10, 72), .bo(13, 1096) });
        }
        switch (t.kind) {
            .rct => {
                t.rct_type = try br.u32Dist(.{ .v(6), .b(2), .bo(4, 2), .bo(6, 10) });
                if (t.rct_type >= 42) return error.BadImage;
            },
            .palette => {
                t.num_c = try br.u32Dist(.{ .v(1), .v(3), .v(4), .bo(13, 1) });
                t.nb_colors = try br.u32Dist(.{ .bo(8, 0), .bo(10, 256), .bo(12, 1280), .bo(16, 5376) });
                t.nb_deltas = try br.u32Dist(.{ .v(0), .bo(8, 1), .bo(10, 257), .bo(16, 1281) });
                t.predictor = try br.bits(4);
                if (t.predictor >= num_predictors) return error.BadImage;
            },
            .squeeze => {
                const n = try br.u32Dist(.{ .v(0), .bo(4, 1), .bo(6, 9), .bo(8, 41) });
                t.squeezes = try arena.alloc(SqueezeParams, n);
                for (t.squeezes) |*s| s.* = .{
                    .horizontal = try br.boolean(),
                    .in_place = try br.boolean(),
                    .begin_c = try br.u32Dist(.{ .b(3), .bo(6, 8), .bo(10, 72), .bo(13, 1096) }),
                    .num_c = try br.u32Dist(.{ .v(1), .v(2), .v(3), .bo(4, 4) }),
                };
            },
        }
        return t;
    }
};

const num_predictors = 14;

pub const Predictor = enum(u8) {
    zero,
    left,
    top,
    average0,
    select,
    gradient,
    weighted,
    top_right,
    top_left,
    left_left,
    average1,
    average2,
    average3,
    average4,
};

/// A node of a meta-adaptive tree, 16 bytes. A split has its property,
/// value, and first child (the second follows it); a leaf has property
/// -1, its predictor, offset, multiplier, and context.
pub const Node = struct {
    property: i16,
    predictor: Predictor = .zero,
    /// The split value, or a leaf's offset.
    value: i32 = 0,
    /// The child taken when the property is above the value (the other
    /// is next to it), or a leaf's context.
    child: u32 = 0,
    multiplier: i32 = 1,

    inline fn next(nd: Node, v: i32) u32 {
        return if (v > nd.value) nd.child else nd.child + 1;
    }
};

pub const Tree = struct {
    nodes: []const Node,
    code: entropy.Code,
};

/// An image of channels and the transforms still to undo.
pub const Image = struct {
    /// Capacity; the first `len` are the channels.
    buf: []Channel,
    len: usize,
    nb_meta: usize = 0,
    bitdepth: u32,
    transforms: []Transform = &.{},
    wp: WpHeader = .{},

    /// An image of `n` channels of `w` by `h`, with room for the
    /// channels transforms add.
    pub fn init(arena: *Arena, n: usize, w: u32, h: u32, bitdepth: u32) Error!Image {
        const buf = try arena.alloc(Channel, n + max_added_channels);
        for (buf[0..n]) |*c| c.* = .{ .w = w, .h = h };
        return .{ .buf = buf, .len = n, .bitdepth = bitdepth };
    }

    pub fn channels(img: *const Image) []Channel {
        return img.buf[0..img.len];
    }

    fn insert(img: *Image, at: usize, c: Channel) Error!void {
        if (img.len == img.buf.len) return error.TooComplex;
        @memmove(img.buf[at + 1 .. img.len + 1], img.buf[at..img.len]);
        img.buf[at] = c;
        img.len += 1;
    }

    fn remove(img: *Image, at: usize, n: usize) void {
        @memmove(img.buf[at .. img.len - n], img.buf[at + n .. img.len]);
        img.len -= n;
    }

    /// Fails unless channels `c1` to `c2` exist, are all meta or all not,
    /// and have one shape.
    fn checkEqual(img: *const Image, c1: u64, c2: u64) Error!void {
        if (c1 > img.len or c2 >= img.len or c2 < c1) return error.BadImage;
        if (c1 < img.nb_meta and c2 >= img.nb_meta) return error.BadImage;
        const ch = img.buf[@intCast(c1)];
        for (img.buf[@intCast(c1 + 1)..@intCast(c2 + 1)]) |*o| {
            if (!ch.sameShape(o)) return error.BadImage;
        }
    }

    /// Applies a transform to the channel layout before decoding.
    fn metaApply(img: *Image, arena: *Arena, t: *Transform) Error!void {
        switch (t.kind) {
            .rct => try img.checkEqual(t.begin_c, @as(u64, t.begin_c) + 2),
            .palette => {
                const begin: u64 = t.begin_c;
                const end: u64 = begin + t.num_c - 1;
                try img.checkEqual(begin, end);
                const nb = end - begin + 1;
                if (begin >= img.nb_meta) {
                    img.nb_meta += 1;
                } else {
                    if (end >= img.nb_meta) return error.BadImage;
                    img.nb_meta = @intCast(@as(u64, img.nb_meta) + 2 - nb);
                }
                img.remove(@intCast(begin + 1), @intCast(nb - 1));
                try img.insert(0, .{
                    .w = t.nb_colors + t.nb_deltas,
                    .h = @intCast(nb),
                    .hshift = -1,
                    .vshift = -1,
                });
            },
            .squeeze => {
                if (t.squeezes.len == 0) t.squeezes = try img.defaultSqueeze(arena);
                for (t.squeezes) |p| {
                    try img.checkSqueeze(p);
                    const begin = p.begin_c;
                    const end = p.begin_c + p.num_c - 1;
                    if (begin < img.nb_meta) {
                        if (end >= img.nb_meta) return error.BadImage;
                        if (!p.in_place) return error.BadImage;
                        img.nb_meta += p.num_c;
                    }
                    const offset: usize = if (p.in_place) end + 1 else img.len;
                    for (begin..end + 1) |c| {
                        const ch = &img.buf[c];
                        if (ch.hshift > 30 or ch.vshift > 30) return error.BadImage;
                        if (ch.w == 0 or ch.h == 0) return error.BadImage;
                        var rw = ch.w;
                        var rh = ch.h;
                        if (p.horizontal) {
                            ch.w = (rw + 1) / 2;
                            if (ch.hshift >= 0) ch.hshift += 1;
                            rw -= ch.w;
                        } else {
                            ch.h = (rh + 1) / 2;
                            if (ch.vshift >= 0) ch.vshift += 1;
                            rh -= ch.h;
                        }
                        const res: Channel = .{ .w = rw, .h = rh, .hshift = ch.hshift, .vshift = ch.vshift };
                        try img.insert(offset + (c - begin), res);
                    }
                }
            },
        }
    }

    fn checkSqueeze(img: *const Image, p: SqueezeParams) Error!void {
        const c2 = @as(u64, p.begin_c) + p.num_c - 1;
        if (p.begin_c >= img.len or c2 >= img.len) return error.BadImage;
    }

    fn defaultSqueeze(img: *const Image, arena: *Arena) Error![]SqueezeParams {
        var list: [128]SqueezeParams = undefined;
        var n: usize = 0;
        const first = img.nb_meta;
        if (first >= img.len) return error.BadImage;
        const nb: u32 = @intCast(img.len - first);
        var w = img.buf[first].w;
        var h = img.buf[first].h;
        const wide = w > h;
        if (nb > 2 and img.buf[first + 1].w == w and img.buf[first + 1].h == h) {
            list[0] = .{ .horizontal = true, .in_place = false, .begin_c = @intCast(first + 1), .num_c = 2 };
            list[1] = .{ .horizontal = false, .in_place = false, .begin_c = @intCast(first + 1), .num_c = 2 };
            n = 2;
        }
        const max_first = 8;
        const base: SqueezeParams = .{ .horizontal = false, .in_place = true, .begin_c = @intCast(first), .num_c = nb };
        if (!wide and h > max_first) {
            list[n] = base;
            n += 1;
            h = (h + 1) / 2;
        }
        while (w > max_first or h > max_first) {
            if (w > max_first) {
                list[n] = base;
                list[n].horizontal = true;
                n += 1;
                w = (w + 1) / 2;
            }
            if (h > max_first) {
                list[n] = base;
                n += 1;
                h = (h + 1) / 2;
            }
        }
        const out = try arena.alloc(SqueezeParams, n);
        @memcpy(out, list[0..n]);
        return out;
    }

    /// Fails if a channel past the first too large for a group is
    /// shifted so far that a group holds none of it.
    fn validateDims(img: *const Image, group_dim: u64) Error!void {
        for ([2]bool{ true, false }) |is_dc| {
            const gd = if (is_dc) group_dim * 8 else group_dim;
            var c = img.nb_meta;
            while (c < img.len) : (c += 1) {
                const ch = &img.buf[c];
                if (ch.w > group_dim or ch.h > group_dim) break;
            }
            while (c < img.len) : (c += 1) {
                const ch = &img.buf[c];
                if (ch.w == 0 or ch.h == 0) continue;
                const dc = @min(ch.hshift, ch.vshift) >= 3;
                if (dc != is_dc) continue;
                const shift = @max(ch.hshift, ch.vshift);
                if (shift < 0) continue;
                if (shift >= 64 or (gd >> @intCast(shift)) == 0) return error.BadImage;
            }
        }
    }

    /// Undoes the transforms, last first.
    pub fn undoTransforms(img: *Image, arena: *Arena) Error!void {
        var i = img.transforms.len;
        while (i > 0) {
            i -= 1;
            const t = &img.transforms[i];
            switch (t.kind) {
                .rct => try img.invRct(t.begin_c, t.rct_type),
                .palette => try img.invPalette(arena, t),
                .squeeze => try img.invSqueeze(arena, t.squeezes),
            }
        }
        img.transforms = &.{};
    }

    fn invRct(img: *Image, begin: u32, rct_type: u32) Error!void {
        try img.checkEqual(begin, @as(u64, begin) + 2);
        if (rct_type == 0) return;
        const m: usize = begin;
        const perm = rct_type / 7;
        const custom = rct_type % 7;
        const in = [3]Channel{ img.buf[m], img.buf[m + 1], img.buf[m + 2] };
        const o0 = m + perm % 3;
        const o1 = m + (perm + 1 + perm / 3) % 3;
        const o2 = m + (perm + 2 - perm / 3) % 3;
        if (custom != 0) {
            const second = custom >> 1;
            const third = custom & 1;
            for (in[0].data, in[1].data, in[2].data) |*a, *b, *c| {
                if (custom == 6) {
                    const y = a.*;
                    const co = b.*;
                    const cg = c.*;
                    const tmp = y -% (cg >> 1);
                    const g = cg +% tmp;
                    const bl = tmp -% (co >> 1);
                    a.* = bl +% co;
                    b.* = g;
                    c.* = bl;
                } else {
                    const first = a.*;
                    var s = b.*;
                    var t = c.*;
                    if (third == 1) t +%= first;
                    if (second == 1) {
                        s +%= first;
                    } else if (second == 2) {
                        s +%= (first +% t) >> 1;
                    }
                    b.* = s;
                    c.* = t;
                }
            }
        }
        img.buf[o0] = in[0];
        img.buf[o1] = in[1];
        img.buf[o2] = in[2];
    }

    fn invPalette(img: *Image, arena: *Arena, t: *const Transform) Error!void {
        if (img.nb_meta < 1) return error.BadImage;
        const pal = img.buf[0];
        const nb: usize = pal.h;
        const c0: usize = @as(usize, t.begin_c) + 1;
        if (c0 >= img.len) return error.BadImage;
        if (nb < 1) return error.BadImage;
        const idx_ch = img.buf[c0];
        const w = idx_ch.w;
        const h = idx_ch.h;
        for (1..nb) |_| {
            const data = try arena.alloc(i32, @as(usize, w) * h);
            try img.insert(c0 + 1, .{ .w = w, .h = h, .hshift = idx_ch.hshift, .vshift = idx_ch.vshift, .data = data });
        }
        const bit_depth: u32 = @min(img.bitdepth, 24);
        const ctx: PaletteCtx = .{ .pal = pal.data, .size = pal.w, .bit_depth = bit_depth };
        if (w == 0) {
            // Nothing to fill.
        } else if (t.nb_deltas == 0 and t.predictor == 0) {
            if (nb == 1) {
                // Clamped to the stored colors as the reference does,
                // max then min, so that an empty palette gives -1 (the
                // first delta) instead of trapping.
                const last = @as(i32, @intCast(pal.w)) - 1;
                for (img.buf[c0].data) |*p| p.* = ctx.value(@min(@max(p.*, 0), last), 0);
            } else {
                // The index channel is overwritten last.
                var c = nb;
                while (c > 0) {
                    c -= 1;
                    const out = img.buf[c0 + c].data;
                    for (out, idx_ch.data) |*o, index| o.* = ctx.value(index, c);
                }
            }
        } else {
            const indices = try arena.alloc(i32, @as(usize, w) * h);
            @memcpy(indices, idx_ch.data);
            const pred: Predictor = @enumFromInt(t.predictor);
            for (0..nb) |c| {
                const ch = &img.buf[c0 + c];
                var wp: Wp = undefined;
                const m = arena.mark();
                defer arena.release(m);
                if (pred == .weighted) wp = try .init(arena, img.wp, w);
                for (0..h) |y| {
                    for (0..w) |x| {
                        const i = y * w + x;
                        const index = indices[i];
                        const entry = ctx.value(index, c);
                        var val: i64 = entry;
                        if (pred == .weighted) {
                            const nbh = neighbours(ch, x, y);
                            var unused: i64 = 0;
                            const g = wp.predict(
                                x,
                                y,
                                nbh.top,
                                nbh.left,
                                nbh.topright,
                                nbh.topleft,
                                nbh.toptop,
                                &unused,
                            );
                            if (index < @as(i64, t.nb_deltas)) val = g +% entry;
                            ch.data[i] = @truncate(val);
                            wp.update(ch.data[i], x, y);
                        } else {
                            if (index < @as(i64, t.nb_deltas)) {
                                const nbh = neighbours(ch, x, y);
                                val = predictOne(pred, nbh, 0) +% entry;
                            }
                            ch.data[i] = @truncate(val);
                        }
                    }
                }
            }
        }
        if (c0 >= img.nb_meta) {
            img.nb_meta -= 1;
        } else {
            if (img.nb_meta + nb < 2) return error.BadImage;
            img.nb_meta = img.nb_meta + nb - 2;
            if (t.begin_c + nb - 1 >= img.nb_meta) return error.BadImage;
        }
        img.remove(0, 1);
    }

    fn invSqueeze(img: *Image, arena: *Arena, params: []const SqueezeParams) Error!void {
        var i = params.len;
        while (i > 0) {
            i -= 1;
            const p = params[i];
            try img.checkSqueeze(p);
            const begin = p.begin_c;
            const end = p.begin_c + p.num_c - 1;
            const offset: usize = if (p.in_place) end + 1 else img.len + begin - end - 1;
            if (begin < img.nb_meta) {
                if (img.nb_meta <= p.num_c) return error.BadImage;
                img.nb_meta -= p.num_c;
            }
            for (begin..end + 1) |c| {
                const rc = offset + c - begin;
                if (rc >= img.len) return error.BadImage;
                const ch = &img.buf[c];
                const res = &img.buf[rc];
                if (ch.w < res.w or ch.h < res.h) return error.BadImage;
                if (p.horizontal) {
                    try invHSqueeze(arena, ch, res);
                } else {
                    try invVSqueeze(arena, ch, res);
                }
            }
            if (offset + p.num_c > img.len) return error.BadImage;
            img.remove(offset, p.num_c);
        }
    }
};

const PaletteCtx = struct {
    pal: []const i32,
    size: u32,
    bit_depth: u32,

    const delta_palette = [72][3]i32{
        .{ 0, 0, 0 },       .{ 4, 4, 4 },       .{ 11, 0, 0 },      .{ 0, 0, -13 },
        .{ 0, -12, 0 },     .{ -10, -10, -10 }, .{ -18, -18, -18 }, .{ -27, -27, -27 },
        .{ -18, -18, 0 },   .{ 0, 0, -32 },     .{ -32, 0, 0 },     .{ -37, -37, -37 },
        .{ 0, -32, -32 },   .{ 24, 24, 45 },    .{ 50, 50, 50 },    .{ -45, -24, -24 },
        .{ -24, -45, -45 }, .{ 0, -24, -24 },   .{ -34, -34, 0 },   .{ -24, 0, -24 },
        .{ -45, -45, -24 }, .{ 64, 64, 64 },    .{ -32, 0, -32 },   .{ 0, -32, 0 },
        .{ -32, 0, 32 },    .{ -24, -45, -24 }, .{ 45, 24, 45 },    .{ 24, -24, -45 },
        .{ -45, -24, 24 },  .{ 80, 80, 80 },    .{ 64, 0, 0 },      .{ 0, 0, -64 },
        .{ 0, -64, -64 },   .{ -24, -24, 45 },  .{ 96, 96, 96 },    .{ 64, 64, 0 },
        .{ 45, -24, -24 },  .{ 34, -34, 0 },    .{ 112, 112, 112 }, .{ 24, -45, -45 },
        .{ 45, 45, -24 },   .{ 0, -32, 32 },    .{ 24, -24, 45 },   .{ 0, 96, 96 },
        .{ 45, -24, 24 },   .{ 24, -45, -24 },  .{ -24, -45, 24 },  .{ 0, -64, 0 },
        .{ 96, 0, 0 },      .{ 128, 128, 128 }, .{ 64, 0, 64 },     .{ 144, 144, 144 },
        .{ 96, 96, 0 },     .{ -36, -36, 36 },  .{ 45, -24, -45 },  .{ 45, -45, -24 },
        .{ 0, 0, -96 },     .{ 0, 128, 128 },   .{ 0, 96, 0 },      .{ 45, 24, -45 },
        .{ -128, 0, 0 },    .{ 24, -45, 24 },   .{ -45, 24, -45 },  .{ 64, 0, -64 },
        .{ 64, -64, -64 },  .{ 96, 0, 96 },     .{ 45, -45, 24 },   .{ 24, 45, -45 },
        .{ 64, 64, -64 },   .{ 128, 128, 0 },   .{ 0, 0, -128 },    .{ -24, 45, -45 },
    };

    fn scale(v: u64, bit_depth: u32) i32 {
        return @truncate(@as(i64, @intCast((v * ((@as(u64, 1) << @intCast(bit_depth)) - 1)) >> 2)));
    }

    /// Channel `c` of palette entry `index`: a stored color, a delta from
    /// the built-in table (negative indices), or a color of the implicit
    /// cubes past the stored ones.
    fn value(p: PaletteCtx, index_in: i32, c: usize) i32 {
        const size: i64 = p.size;
        const index: i64 = index_in;
        if (index < 0) {
            if (c >= 3) return 0;
            var i: i64 = -(index + 1);
            i = @mod(i, 1 + 2 * (delta_palette.len - 1));
            const sign: i32 = if (i & 1 == 0) -1 else 1;
            var r = delta_palette[@intCast((i + 1) >> 1)][c] * sign;
            if (p.bit_depth > 8) r = r *% (@as(i32, 1) << @intCast(p.bit_depth - 8));
            return r;
        } else if (index >= size and index < size + 64) {
            if (c >= 3) return 0;
            const i: u64 = @intCast((index - size) >> @intCast(c * 2));
            const add: i32 = @as(i32, 1) << @intCast(if (p.bit_depth >= 3) p.bit_depth - 3 else 0);
            return scale(i % 4, p.bit_depth) +% add;
        } else if (index >= size + 64) {
            if (c >= 3) return 0;
            var i: u64 = @intCast(index - size - 64);
            if (c == 1) i /= 5;
            if (c == 2) i /= 25;
            return scale(i % 5, p.bit_depth);
        }
        return p.pal[c * p.size + @as(usize, @intCast(index))];
    }
};

fn invHSqueeze(arena: *Arena, ch: *Channel, res: *const Channel) Error!void {
    if (ch.w != (@as(u64, ch.w) + res.w + 1) / 2 or ch.h != res.h) return error.BadImage;
    if (res.w == 0) {
        ch.hshift -= 1;
        return;
    }
    const ow = ch.w + res.w;
    const out = try arena.alloc(i32, @as(usize, ow) * ch.h);
    for (0..ch.h) |y| {
        const avg_row = ch.row(y);
        const res_row = res.row(y);
        const o = out[y * ow ..][0..ow];
        for (0..res.w) |x| {
            const avg: i64 = avg_row[x];
            const next: i64 = if (x + 1 < ch.w) avg_row[x + 1] else avg;
            const left: i64 = if (x > 0) o[2 * x - 1] else avg;
            const diff = @as(i64, res_row[x]) + smoothTendency(left, avg, next);
            const a = avg + @divTrunc(diff, 2);
            o[2 * x] = @truncate(a);
            o[2 * x + 1] = @truncate(a - diff);
        }
        if (ow & 1 == 1) o[ow - 1] = avg_row[ch.w - 1];
    }
    ch.* = .{ .w = ow, .h = ch.h, .hshift = ch.hshift - 1, .vshift = ch.vshift, .data = out };
}

fn invVSqueeze(arena: *Arena, ch: *Channel, res: *const Channel) Error!void {
    if (ch.h != (@as(u64, ch.h) + res.h + 1) / 2 or ch.w != res.w) return error.BadImage;
    if (res.h == 0) {
        ch.vshift -= 1;
        return;
    }
    const oh = ch.h + res.h;
    const w = ch.w;
    const out = try arena.alloc(i32, @as(usize, w) * oh);
    for (0..res.h) |y| {
        const avg_row = ch.row(y);
        const next_row = ch.row(if (y + 1 < ch.h) y + 1 else y);
        const res_row = res.row(y);
        const o = out[2 * y * w ..][0..w];
        const no = out[(2 * y + 1) * w ..][0..w];
        const prev = if (y > 0) out[(2 * y - 1) * w ..][0..w] else avg_row;
        for (0..w) |x| {
            const avg: i64 = avg_row[x];
            const next: i64 = next_row[x];
            const top: i64 = prev[x];
            const diff = @as(i64, res_row[x]) + smoothTendency(top, avg, next);
            const a = avg + @divTrunc(diff, 2);
            o[x] = @truncate(a);
            no[x] = @truncate(a - diff);
        }
    }
    if (oh & 1 == 1) @memcpy(out[(oh - 1) * w ..][0..w], ch.row(ch.h - 1));
    ch.* = .{ .w = w, .h = oh, .hshift = ch.hshift, .vshift = ch.vshift - 1, .data = out };
}

fn smoothTendency(b: i64, a: i64, n: i64) i64 {
    var diff: i64 = 0;
    if (b >= a and a >= n) {
        diff = @divTrunc(4 * b - 3 * n - a + 6, 12);
        if (diff - (diff & 1) > 2 * (b - a)) diff = 2 * (b - a) + 1;
        if (diff + (diff & 1) > 2 * (a - n)) diff = 2 * (a - n);
    } else if (b <= a and a <= n) {
        diff = @divTrunc(4 * b - 3 * n - a - 6, 12);
        if (diff + (diff & 1) < 2 * (b - a)) diff = 2 * (b - a) - 1;
        if (diff - (diff & 1) < 2 * (a - n)) diff = 2 * (a - n);
    }
    return diff;
}

// The tree.

const max_tree_size = 1 << 22;
const tree_contexts = 6;

/// Reads a meta-adaptive tree of at most `limit` nodes and its histograms.
pub fn readTree(br: *BitReader, arena: *Arena, limit_in: usize) Error!Tree {
    const limit = @min(limit_in, max_tree_size);
    const start = arena.mark();
    const tcode = try entropy.Code.read(br, arena, tree_contexts);
    // A one-symbol property context that is not "leaf" never ends.
    if (!tcode.use_prefix and tcode.single[tcode.context_map[1]] > 0) return error.BadImage;
    var r: entropy.Reader = try .init(&tcode, br, arena, 0, @as(usize, @min(limit + 1, entropy.window_size)) * 5);
    // Nodes go in the rest of the arena, then move down over the tree's
    // own code.
    const room = ((arena.buf.len - arena.used) / @sizeOf(Node)) -| 1;
    const nodes = try arena.alloc(Node, @min(room, limit + 1));
    var n: usize = 0;
    var to_decode: usize = 1;
    var leaf_id: u32 = 0;
    while (to_decode > 0) {
        if (n > limit) return error.BadImage;
        if (n == nodes.len) return error.TooComplex;
        to_decode -= 1;
        const prop1 = try r.read(br, 1);
        if (prop1 > 256) return error.BadImage;
        if (prop1 == 0) {
            const pred = try r.read(br, 2);
            if (pred >= num_predictors) return error.BadImage;
            const offset = unpackSigned(try r.read(br, 3));
            const mul_log = try r.read(br, 4);
            if (mul_log >= 31) return error.BadImage;
            const mul_bits = try r.read(br, 5);
            if (mul_bits >= (@as(u32, 1) << @intCast(31 - mul_log)) - 1) return error.BadImage;
            nodes[n] = .{
                .property = -1,
                .child = leaf_id,
                .predictor = @enumFromInt(pred),
                .value = offset,
                .multiplier = @intCast((mul_bits + 1) << @intCast(mul_log)),
            };
            leaf_id += 1;
            n += 1;
            continue;
        }
        const split = unpackSigned(try r.read(br, 0));
        nodes[n] = .{
            .property = @intCast(prop1 - 1),
            .value = split,
            .child = @intCast(n + to_decode + 1),
        };
        to_decode += 2;
        n += 1;
    }
    if (!r.finalOk()) return error.BadEntropy;
    try validateTree(arena, nodes[0..n]);
    // Move the nodes down over the tree's code.
    arena.release(start);
    const kept = try arena.alloc(Node, n);
    @memmove(kept, nodes[0..n]);
    const code = try entropy.Code.read(br, arena, (n + 1) / 2);
    return .{ .nodes = kept, .code = code };
}

/// Fails if a split cannot be reached (its value outside the range the
/// splits above leave) or the tree is 2048 or more deep.
fn validateTree(arena: *Arena, nodes: []const Node) Error!void {
    var ranges: [256][2]i32 = undefined;
    for (&ranges) |*r| r.* = .{ std.math.minInt(i32), std.math.maxInt(i32) };
    const Item = struct { node: u32, l: i32, u: i32, action: u2 };
    const m = arena.mark();
    defer arena.release(m);
    const height_limit = 2048;
    const stack = try arena.alloc(Item, height_limit);
    var sp: usize = 1;
    stack[0] = .{ .node = 0, .l = 0, .u = 0, .action = 0 };
    while (sp > 0) {
        if (sp >= height_limit) return error.BadImage;
        const item = &stack[sp - 1];
        const node = nodes[item.node];
        switch (item.action) {
            0 => {
                if (node.property < 0) {
                    sp -= 1;
                    continue;
                }
                const p: usize = @intCast(node.property);
                const v = node.value;
                const l = ranges[p][0];
                const u = ranges[p][1];
                if (l > v or u <= v) return error.BadImage;
                item.l = l;
                item.u = u;
                item.action = 1;
                ranges[p][0] = v + 1;
                stack[sp] = .{ .node = node.child, .l = 0, .u = 0, .action = 0 };
                sp += 1;
            },
            1 => {
                const p: usize = @intCast(node.property);
                item.action = 2;
                ranges[p][0] = item.l;
                ranges[p][1] = node.value;
                stack[sp] = .{ .node = node.child + 1, .l = 0, .u = 0, .action = 0 };
                sp += 1;
            },
            else => {
                const p: usize = @intCast(node.property);
                ranges[p][1] = item.u;
                sp -= 1;
            },
        }
    }
}

// Streams.

pub const StreamOptions = struct {
    /// Decode only channels up to this size (after the meta channels).
    max_chan_size: u32 = 0xFF_FFFF,
    /// The group size, for checking channel shifts.
    group_dim: u64 = 0x1FFF_FFFF,
    /// The frame's tree and histograms, if it has them.
    global: ?*const Tree = null,
    /// Undo the stream's transforms after decoding.
    undo: bool = true,
    /// When nonzero and the stream has no transforms, the channels too
    /// large for it (which groups fill) get rings of this many rows
    /// instead of all their rows: a frame that streams keeps only the
    /// group rows it has not written yet.
    ring: u32 = 0,
};

/// Decodes one modular stream into `img`, whose channels the caller set
/// up without data: reads the group header, applies its transforms to the
/// layout, gives every channel zeroed data from `arena`, decodes the
/// channels, and undoes the transforms if asked.
pub fn decodeStream(br: *BitReader, arena: *Arena, img: *Image, stream_id: u32, opt: StreamOptions) Error!void {
    if (img.len == 0) return;
    const use_global = try br.boolean();
    img.wp = try .read(br);
    const nt = try br.u32Dist(.{ .v(0), .v(1), .bo(4, 2), .bo(8, 18) });
    img.transforms = try arena.alloc(Transform, nt);
    for (img.transforms) |*t| t.* = try .read(br, arena);
    for (img.transforms) |*t| try img.metaApply(arena, t);
    try img.validateDims(opt.group_dim);
    const ring = opt.ring != 0 and nt == 0;
    for (img.channels(), 0..) |*c, i| {
        if (c.data.len != 0) continue;
        var rows = c.h;
        if (ring and i >= img.nb_meta and (c.w > opt.max_chan_size or c.h > opt.max_chan_size) and opt.ring < c.h) {
            rows = opt.ring;
            c.ring = opt.ring;
        }
        c.data = try arena.alloc(i32, @as(usize, c.w) * rows);
        vfill(i32, c.data, 0);
    }
    try decodeChannels(br, arena, img, stream_id, use_global, opt);
    if (opt.undo) try img.undoTransforms(arena);
}

fn decodeChannels(
    br: *BitReader,
    arena: *Arena,
    img: *Image,
    stream_id: u32,
    use_global: bool,
    opt: StreamOptions,
) Error!void {
    var end: usize = 0;
    var dist_mult: u32 = 0;
    var any = false;
    var pixels: u64 = 0;
    for (img.channels(), 0..) |*c, i| {
        if (i >= img.nb_meta and (c.w > opt.max_chan_size or c.h > opt.max_chan_size)) break;
        end = i + 1;
        if (c.w == 0 or c.h == 0) continue;
        dist_mult = @max(dist_mult, c.w);
        pixels += @as(u64, c.w) * c.h;
        any = true;
    }
    if (!any) return;
    const m = arena.mark();
    defer arena.release(m);
    var local: Tree = undefined;
    const tree: *const Tree = if (use_global) opt.global orelse return error.BadImage else blk: {
        local = try readTree(br, arena, @min(1 << 20, 1024 + pixels));
        break :blk &local;
    };
    if (tree.nodes.len == 0) return error.BadImage;
    var r: entropy.Reader = try .init(&tree.code, br, arena, dist_mult, @intCast(@min(pixels, entropy.window_size)));
    for (img.channels()[0..end], 0..) |*c, i| {
        if (c.w == 0 or c.h == 0) continue;
        const cm = arena.mark();
        defer arena.release(cm);
        try decodeChannel(br, arena, img, i, stream_id, tree, &r);
    }
    if (!r.finalOk()) return error.BadEntropy;
}

const num_static = 2;
const num_nonref = 16;
const wp_prop = 15;

pub const Neighbours = struct {
    left: i64,
    top: i64,
    topleft: i64,
    topright: i64,
    leftleft: i64,
    toptop: i64,
    toprightright: i64,
};

pub inline fn neighbours(ch: *const Channel, x: usize, y: usize) Neighbours {
    const w = ch.w;
    const d = ch.data;
    const i = y * w + x;
    var n: Neighbours = undefined;
    n.left = if (x > 0) d[i - 1] else if (y > 0) d[i - w] else 0;
    n.top = if (y > 0) d[i - w] else n.left;
    n.topleft = if (x > 0 and y > 0) d[i - w - 1] else n.left;
    n.topright = if (x + 1 < w and y > 0) d[i - w + 1] else n.top;
    n.leftleft = if (x > 1) d[i - 2] else n.left;
    n.toptop = if (y > 1) d[i - 2 * w] else n.top;
    n.toprightright = if (x + 2 < w and y > 0) d[i - w + 2] else n.topright;
    return n;
}

pub inline fn clampedGradient(n: i64, w: i64, l: i64) i64 {
    const mn = @min(n, w);
    const mx = @max(n, w);
    const grad: i64 = @as(i32, @truncate(n +% w -% l));
    if (l > mx) return mn;
    if (l < mn) return mx;
    return grad;
}

pub inline fn predictOne(p: Predictor, n: Neighbours, wp_pred: i64) i64 {
    return switch (p) {
        .zero => 0,
        .left => n.left,
        .top => n.top,
        .select => blk: {
            const pp = n.left + n.top - n.topleft;
            const pa = @abs(pp - n.left);
            const pb = @abs(pp - n.top);
            break :blk if (pa < pb) n.left else n.top;
        },
        .weighted => wp_pred,
        .gradient => clampedGradient(n.left, n.top, n.topleft),
        .top_left => n.topleft,
        .top_right => n.topright,
        .left_left => n.leftleft,
        .average0 => @divTrunc(n.left + n.top, 2),
        .average1 => @divTrunc(n.left + n.topleft, 2),
        .average2 => @divTrunc(n.topleft + n.top, 2),
        .average3 => @divTrunc(n.top + n.topright, 2),
        .average4 => @divTrunc(
            6 * n.top - 2 * n.toptop + 7 * n.left + n.leftleft + n.toprightright + 3 * n.topright + 8,
            16,
        ),
    };
}

/// The weighted predictor's state for one channel.
pub const Wp = struct {
    hdr: WpHeader,
    w: usize,
    pred_err: [4][]u32,
    err: []i32,
    prediction: [4]i64 = undefined,
    pred: i64 = 0,

    const divlookup = blk: {
        var t: [64]u32 = undefined;
        for (&t, 0..) |*v, i| v.* = (1 << 24) / (i + 1);
        break :blk t;
    };

    pub fn init(arena: *Arena, hdr: WpHeader, w: usize) Error!Wp {
        var s: Wp = .{ .hdr = hdr, .w = w, .pred_err = undefined, .err = try arena.alloc(i32, (w + 2) * 2) };
        vfill(i32, s.err, 0);
        for (&s.pred_err) |*p| {
            p.* = try arena.alloc(u32, (w + 2) * 2);
            vfill(u32, p.*, 0);
        }
        return s;
    }

    inline fn errorWeight(x: u32, maxweight: u32) u32 {
        const lg: i32 = std.math.log2_int(u64, @as(u64, x) + 1);
        const shift: u5 = @intCast(@max(0, lg - 5));
        // A volatile read, so that the four weights' reads stay four loads
        // rather than becoming a vector gather, which is slow on x86.
        const d = @as(*const volatile u32, &divlookup[@intCast(@as(u64, x) >> shift)]).*;
        return 4 +% ((maxweight *% d) >> shift);
    }

    inline fn addBits(x: i64) i64 {
        return @bitCast(@as(u64, @bitCast(x)) << 3);
    }

    inline fn iabs(x: i64) i64 {
        return if (x < 0) 0 -% x else x;
    }

    /// The prediction at (x, y) from the neighbours, and the largest
    /// error around it (property 15) in `max_err`.
    pub inline fn predict(
        s: *Wp,
        x: usize,
        y: usize,
        n_in: i64,
        w_in: i64,
        ne_in: i64,
        nw_in: i64,
        nn_in: i64,
        max_err: *i64,
    ) i64 {
        const xs = s.w;
        const cur: usize = if (y & 1 == 1) 0 else xs + 2;
        const prev: usize = if (y & 1 == 1) xs + 2 else 0;
        const pos_n = prev + x;
        const pos_ne = if (x < xs - 1) pos_n + 1 else pos_n;
        const pos_nw = if (x > 0) pos_n - 1 else pos_n;
        var weights: [4]u32 = undefined;
        for (0..4) |i| {
            const e = s.pred_err[i];
            weights[i] = errorWeight(e[pos_n] +% e[pos_ne] +% e[pos_nw], s.hdr.w[i]);
        }
        const n_v = addBits(n_in);
        const w_v = addBits(w_in);
        const ne_v = addBits(ne_in);
        const nw_v = addBits(nw_in);
        const nn_v = addBits(nn_in);
        const te_w: i64 = if (x == 0) 0 else s.err[cur + x - 1];
        const te_n: i64 = s.err[pos_n];
        const te_nw: i64 = s.err[pos_nw];
        const sum_wn = te_n + te_w;
        const te_ne: i64 = s.err[pos_ne];
        var p = te_w;
        if (iabs(te_n) > iabs(p)) p = te_n;
        if (iabs(te_nw) > iabs(p)) p = te_nw;
        if (iabs(te_ne) > iabs(p)) p = te_ne;
        max_err.* = p;
        const h = &s.hdr;
        s.prediction[0] = w_v +% ne_v -% n_v;
        s.prediction[1] = n_v -% (((sum_wn + te_ne) *% h.p1c) >> 5);
        s.prediction[2] = w_v -% (((sum_wn + te_nw) *% h.p2c) >> 5);
        s.prediction[3] = n_v -% ((te_nw *% h.p3c[0] +% te_n *% h.p3c[1] +% te_ne *% h.p3c[2] +%
            (nn_v -% n_v) *% h.p3c[3] +% (nw_v -% w_v) *% h.p3c[4]) >> 5);
        // The weighted average.
        var wsum: u32 = 0;
        for (weights) |wt| wsum +%= wt;
        const lw: u5 = @intCast(std.math.log2_int(u32, wsum));
        wsum = 0;
        for (&weights) |*wt| {
            wt.* >>= lw - 4;
            wsum += wt.*;
        }
        var sum: i64 = @as(i64, wsum >> 1) - 1;
        for (s.prediction, weights) |pr, wt| sum +%= pr *% wt;
        s.pred = (sum *% divlookup[wsum - 1]) >> 24;
        if (((te_n ^ te_w) | (te_n ^ te_nw)) <= 0) {
            const mx = @max(w_v, @max(ne_v, n_v));
            const mn = @min(w_v, @min(ne_v, n_v));
            s.pred = @max(mn, @min(mx, s.pred));
        }
        return (s.pred +% 3) >> 3;
    }

    pub inline fn update(s: *Wp, val_in: i32, x: usize, y: usize) void {
        const xs = s.w;
        const cur: usize = if (y & 1 == 1) 0 else xs + 2;
        const prev: usize = if (y & 1 == 1) xs + 2 else 0;
        const val = addBits(val_in);
        s.err[cur + x] = @truncate(s.pred -% val);
        for (0..4) |i| {
            const e: u32 = @truncate(@as(u64, @bitCast((iabs(s.prediction[i] -% val) +% 3) >> 3)));
            s.pred_err[i][cur + x] = e;
            s.pred_err[i][prev + x + 1] +%= e;
        }
    }
};

/// What a channel's decoding needs from the tree, with the static
/// properties (channel and stream) known: the node to start from, the
/// properties the reachable nodes test, and whether any uses the weighted
/// predictor.
const Plan = struct {
    start: u32,
    num_props: usize,
    uses_wp: bool,
    /// Reachable splits on properties other than the static ones.
    splits: u32,
};

fn plan(tree: []const Node, chan: i32, stream: i32) Plan {
    const statics = [2]i32{ chan, stream };
    var stack: [2050]u32 = undefined;
    var sp: usize = 1;
    stack[0] = 0;
    var max_prop: i32 = -1;
    var uses_wp = false;
    var start: u32 = 0;
    var first = true;
    var splits: u32 = 0;
    while (sp > 0) {
        sp -= 1;
        var cur = stack[sp];
        while (tree[cur].property >= 0 and tree[cur].property < num_static) {
            const nd = tree[cur];
            cur = nd.next(statics[@intCast(nd.property)]);
        }
        if (first) start = cur;
        first = false;
        const nd = tree[cur];
        if (nd.property < 0) {
            uses_wp = uses_wp or nd.predictor == .weighted;
            continue;
        }
        max_prop = @max(max_prop, nd.property);
        uses_wp = uses_wp or nd.property == wp_prop;
        splits += 1;
        // The tree is less than 2048 deep, so the stack holds the pending
        // second children of one path.
        stack[sp] = nd.child + 1;
        stack[sp + 1] = nd.child;
        sp += 2;
    }
    var num_props: usize = num_nonref;
    if (max_prop + 1 > num_nonref) {
        const extra: usize = @intCast(max_prop + 1 - num_nonref);
        num_props = num_nonref + (extra + 3) / 4 * 4;
    }
    return .{ .start = start, .num_props = num_props, .uses_wp = uses_wp, .splits = splits };
}

inline fn makePixel(v: u32, mul: i32, guess: i64) i32 {
    return @truncate(@as(i64, unpackSigned(v)) *% mul +% guess);
}

fn decodeChannel(
    br: *BitReader,
    arena: *Arena,
    img: *Image,
    ci: usize,
    stream_id: u32,
    tree: *const Tree,
    r: *entropy.Reader,
) Error!void {
    const ch = &img.buf[ci];
    const w: usize = ch.w;
    const h: usize = ch.h;
    const nodes = tree.nodes;
    const ft = plan(nodes, @intCast(ci), @bitCast(stream_id));

    if (nodes[ft.start].property < 0) {
        const leaf = nodes[ft.start];
        const ctx = leaf.child;
        if (leaf.predictor == .zero) {
            if (r.singleValue(ctx, w * h)) |v| {
                vfill(i32, ch.data, makePixel(v, leaf.multiplier, leaf.value));
                return;
            }
            for (ch.data) |*p| p.* = makePixel(try r.readInline(br, ctx), leaf.multiplier, leaf.value);
            return;
        }
        if (leaf.predictor != .weighted) {
            for (0..h) |y| {
                for (0..w) |x| {
                    const g = predictOne(leaf.predictor, neighbours(ch, x, y), 0);
                    ch.data[y * w + x] = makePixel(try r.readInline(br, ctx), leaf.multiplier, g +% leaf.value);
                }
            }
            return;
        }
    }

    const props = try arena.alloc(i32, ft.num_props);
    @memset(props, 0);
    const statics = [2]i32{ @intCast(ci), @bitCast(stream_id) };
    const flattened = ft.splits <= flat_max_splits and w * h >= flat_min_pixels;
    const flat: ?[]Flat = if (flattened) try flatten(arena, nodes, ft, statics) else null;
    const nref = ft.num_props - num_nonref;
    const refs = try arena.alloc(i32, nref * w);
    var wp: Wp = undefined;
    if (ft.uses_wp) wp = try .init(arena, img.wp, w);
    props[0] = @intCast(ci);
    props[1] = @bitCast(stream_id);
    for (0..h) |y| {
        if (nref > 0) precomputeRefs(img, ci, y, refs, nref);
        var prev9: i32 = 0;
        for (0..w) |x| {
            const n = neighbours(ch, x, y);
            pixelProps(props, n, x, y, &prev9);
            var wp_pred: i64 = 0;
            if (ft.uses_wp) {
                var max_err: i64 = 0;
                wp_pred = wp.predict(x, y, n.top, n.left, n.topright, n.topleft, n.toptop, &max_err);
                props[15] = @truncate(max_err);
            }
            if (nref > 0) @memcpy(props[num_nonref..], refs[x * nref ..][0..nref]);
            const leaf = nodes[if (flat) |f| walkFlat(f, props) else walk(nodes, ft.start, props)];
            const g = predictOne(leaf.predictor, n, wp_pred) +% leaf.value;
            const v = makePixel(try r.readInline(br, leaf.child), leaf.multiplier, g);
            ch.data[y * w + x] = v;
            if (ft.uses_wp) wp.update(v, x, y);
        }
    }
}

/// Properties 2 to 14 at (x, y) from its neighbours `n`; `prev9` is
/// property 9 of the pixel to the left (0 at the start of a row) and
/// becomes this pixel's.
pub inline fn pixelProps(props: []i32, n: Neighbours, x: usize, y: usize, prev9: *i32) void {
    props[2] = @intCast(y);
    props[3] = @intCast(x);
    props[4] = @truncate(if (n.top > 0) n.top else -n.top);
    props[5] = @truncate(if (n.left > 0) n.left else -n.left);
    props[6] = @truncate(n.top);
    props[7] = @truncate(n.left);
    props[8] = @truncate(n.left - prev9.*);
    props[9] = @truncate(n.left + n.top - n.topleft);
    prev9.* = props[9];
    props[10] = @truncate(n.left - n.topleft);
    props[11] = @truncate(n.topleft - n.top);
    props[12] = @truncate(n.top - n.topright);
    props[13] = @truncate(n.top - n.toptop);
    props[14] = @truncate(n.left - n.leftleft);
}

/// The leaf that `props` reach from split `start`, two levels a step: a
/// split's two children are next to each other, so their tests load
/// alongside its own, which halves the walk's chain of dependent loads. A
/// leaf child is reached whichever way its parent goes. A child its
/// parent's static test rules out may test a property past `props`
/// (`plan` sizes them for the reachable nodes); its test reads the last
/// property instead and is discarded.
pub inline fn walk(nodes: []const Node, start: u32, props: []const i32) u32 {
    var pos = start;
    while (nodes[pos].property >= 0) {
        const nd = nodes[pos];
        const pair = nodes[nd.child..][0..2];
        const go: u32 = @intFromBool(props[@intCast(nd.property)] <= nd.value);
        var next: [2]u32 = undefined;
        for (&next, pair, 0..) |*o, c, i| {
            const leaf = c.property < 0;
            const v = props[if (leaf) 0 else @min(@as(usize, @intCast(c.property)), props.len - 1)];
            o.* = if (leaf) nd.child + @as(u32, @intCast(i)) else c.child + @intFromBool(v <= c.value);
        }
        pos = next[go];
    }
    return pos;
}

/// Channels of at least `flat_min_pixels` whose tree has at most
/// `flat_max_splits` splits after the static ones walk it flattened
/// (`flatten`), in at most `flat_bytes` of work memory. Larger trees,
/// which encoders do not write, walk the nodes, and so do small channels,
/// where flattening costs more than it saves (a 16×16 icon decoded 10%
/// slower).
pub const flat_max_splits = 4096;
const flat_min_pixels = 4096;
pub const flat_bytes = (1 + 4 * flat_max_splits) * @sizeOf(Flat);

/// A split and both its children's tests, with its four grandchildren
/// next to each other from `base`; or a leaf (`leaf` 1), `base` its node.
/// A leaf child tests property 0 against the largest value, which always
/// takes its second grandchild, the leaf.
const Flat = struct {
    p: [3]u16,
    leaf: u16,
    v: [3]i32,
    base: u32,
};

/// The node that `n` reaches past splits on the static properties.
fn resolve(nodes: []const Node, n: u32, statics: [2]i32) u32 {
    var cur = n;
    while (nodes[cur].property >= 0 and nodes[cur].property < num_static) {
        const nd = nodes[cur];
        cur = nd.next(statics[@intCast(nd.property)]);
    }
    return cur;
}

/// The tree a channel reaches (`ft`), flattened two levels to an entry,
/// which `walkFlat` walks with one load a step where `walk` takes two
/// dependent ones.
fn flatten(arena: *Arena, nodes: []const Node, ft: Plan, statics: [2]i32) Error![]Flat {
    const last: u16 = @intCast(ft.num_props - 1);
    const flat = try arena.alloc(Flat, 1 + 4 * @as(usize, ft.splits));
    var next: u32 = 1;
    var head: u32 = 0;
    // Entries are filled in order, so the unprocessed internal ones are a
    // queue from `head`.
    const Set = struct {
        fn entry(nds: []const Node, f: *Flat, n: u32, l: u16) void {
            const nd = nds[n];
            if (nd.property < 0) {
                f.* = .{ .p = .{ 0, 0, 0 }, .leaf = 1, .v = .{ 0, 0, 0 }, .base = n };
            } else {
                const p = @min(@as(u16, @intCast(nd.property)), l);
                f.* = .{ .p = .{ p, 0, 0 }, .leaf = 0, .v = .{ nd.value, 0, 0 }, .base = n };
            }
        }
    };
    Set.entry(nodes, &flat[0], ft.start, last);
    while (head < next) : (head += 1) {
        const f = &flat[head];
        if (f.leaf != 0) continue;
        const x = nodes[f.base];
        const base = next;
        next += 4;
        for (0..2) |k| {
            const c = resolve(nodes, x.child + @as(u32, @intCast(k)), statics);
            const cn = nodes[c];
            if (cn.property < 0) {
                f.p[1 + k] = 0;
                f.v[1 + k] = std.math.maxInt(i32);
                Set.entry(nodes, &flat[base + 2 * k], c, last);
                Set.entry(nodes, &flat[base + 2 * k + 1], c, last);
            } else {
                f.p[1 + k] = @min(@as(u16, @intCast(cn.property)), last);
                f.v[1 + k] = cn.value;
                for (0..2) |j| {
                    const g = resolve(nodes, cn.child + @as(u32, @intCast(j)), statics);
                    Set.entry(nodes, &flat[base + 2 * k + j], g, last);
                }
            }
        }
        f.base = base;
    }
    return flat[0..next];
}

/// The leaf node that `props` reach in `flat`.
inline fn walkFlat(flat: []const Flat, props: []const i32) u32 {
    var i: u32 = 0;
    while (flat[i].leaf == 0) {
        const f = flat[i];
        const a: u32 = @intFromBool(props[f.p[0]] <= f.v[0]);
        const t1: u32 = @intFromBool(props[f.p[1]] <= f.v[1]);
        const t2: u32 = @intFromBool(props[f.p[2]] <= f.v[2]);
        i = f.base + 2 * a + (if (a == 1) t2 else t1);
    }
    return flat[i].base;
}

/// The reference properties of row `y`: for each earlier channel shaped
/// like channel `ci`, nearest first, |v|, v, |v - g|, v - g at each x,
/// where g is that channel's clamped gradient prediction.
pub fn precomputeRefs(img: *const Image, ci: usize, y: usize, refs: []i32, nref: usize) void {
    @memset(refs, 0);
    const ch = &img.buf[ci];
    var offset: usize = 0;
    var j = ci;
    while (j > 0 and offset < nref) {
        j -= 1;
        const o = &img.buf[j];
        if (!o.sameShape(ch)) continue;
        const rp = o.row(y);
        const rprev = o.row(if (y > 0) y - 1 else 0);
        for (0..ch.w) |x| {
            const v: i64 = rp[x];
            const vleft: i64 = if (x > 0) rp[x - 1] else 0;
            const vtop: i64 = if (y > 0) rprev[x] else vleft;
            const vtopleft: i64 = if (x > 0 and y > 0) rprev[x - 1] else vleft;
            const pred = clampedGradient(vleft, vtop, vtopleft);
            const out = refs[x * nref + offset ..][0..4];
            out[0] = @truncate(if (v < 0) -v else v);
            out[1] = @truncate(v);
            out[2] = @truncate(if (v - pred < 0) pred - v else v - pred);
            out[3] = @truncate(v - pred);
        }
        offset += 4;
    }
}

test "smooth tendency" {
    try testing.expectEqual(@as(i64, 0), smoothTendency(5, 5, 5));
    // Monotone decreasing B >= a >= n.
    const d = smoothTendency(10, 6, 2);
    try testing.expect(d > 0);
}

test "palette implicit cube" {
    const p: PaletteCtx = .{ .pal = &.{}, .size = 0, .bit_depth = 8 };
    // Index 0 of the small cube: (0 * 255) >> 2 + 32.
    try testing.expectEqual(@as(i32, 32), p.value(0, 0));
    // Large cube index 64 + 4: channel 0 is 4 * 255 / 4 = 255.
    try testing.expectEqual(@as(i32, 255), p.value(64 + 4, 0));
    // Delta -1 is entry 0 negated: 0.
    try testing.expectEqual(@as(i32, 0), p.value(-1, 0));
    // Delta -2: index 1, entry 1 * +1 = 4.
    try testing.expectEqual(@as(i32, 4), p.value(-2, 0));
}

test "a one-channel palette with no stored colors" {
    // Every index clamps to -1, the first delta, which is 0, instead of
    // trapping on an empty range.
    var mem: [1 << 18]u8 align(16) = undefined;
    var arena: Arena = .init(&mem);
    var img: Image = try .init(&arena, 2, 3, 1, 8);
    img.nb_meta = 1;
    img.buf[0] = .{ .w = 0, .h = 1, .data = &.{} };
    var indices = [_]i32{ -5, 0, 7 };
    img.buf[1].data = &indices;
    try img.invPalette(&arena, &.{ .kind = .palette, .num_c = 1 });
    try testing.expectEqual(1, img.len);
    try testing.expectEqualSlices(i32, &.{ 0, 0, 0 }, img.buf[0].data);
}

test "a flattened tree reaches the leaves the tree does" {
    // Random trees with splits on the static properties among the others
    // and leaves at every depth, walked both ways on random properties.
    var prng: std.Random.DefaultPrng = .init(11);
    const rand = prng.random();
    var mem: [1 << 20]u8 align(16) = undefined;
    var arena: Arena = .init(&mem);
    for (0..300) |_| {
        var nodes: [255]Node = undefined;
        var depth: [255]u8 = undefined;
        nodes[0] = .{ .property = -1 };
        depth[0] = 0;
        var n: u32 = 1;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (n + 2 > nodes.len or depth[i] > 9 or rand.uintLessThan(u8, 4) == 0) {
                nodes[i] = .{ .property = -1, .child = i };
                continue;
            }
            const prop = rand.intRangeAtMost(i16, 0, 17);
            nodes[i] = .{ .property = prop, .value = rand.intRangeAtMost(i32, -4, 4), .child = n };
            for (0..2) |_| {
                depth[n] = depth[i] + 1;
                n += 1;
            }
        }
        const chan = rand.intRangeAtMost(i32, -4, 4);
        const stream = rand.intRangeAtMost(i32, -4, 4);
        const ft = plan(nodes[0..n], chan, stream);
        const m = arena.mark();
        defer arena.release(m);
        const flat = try flatten(&arena, nodes[0..n], ft, .{ chan, stream });
        try testing.expect(flat.len <= 1 + 4 * @as(usize, ft.splits));
        var props: [20]i32 = undefined;
        for (0..200) |_| {
            for (&props) |*p| p.* = rand.intRangeAtMost(i32, -6, 6);
            props[0] = chan;
            props[1] = stream;
            const np = ft.num_props;
            try testing.expectEqual(walk(nodes[0..n], ft.start, props[0..np]), walkFlat(flat, props[0..np]));
        }
    }
}
