//! Resizing: scale an image to any size, in any pixel format, with a
//! separable filter, a buffer at once or a row at a time.
//!
//! `resize` writes a whole destination buffer from a whole source buffer;
//! `Resizer` takes source rows as they arrive and hands back destination
//! rows as soon as their source rows are in, holding only as many
//! rows as the vertical filter spans (the whole height with `Edge.wrap`,
//! whose first rows read the last ones). Neither allocates: `workLen` says how
//! much work memory to pass, and the filter weights are computed into it
//! once.
//!
//! The source is filtered in its own channel layout at `f32` precision:
//! along the rows and down the columns. Straight-alpha sources are
//! premultiplied before filtering and unpremultiplied after, so that a
//! transparent pixel's color does not bleed into its neighbors;
//! premultiplied sources, and formats without alpha, are filtered as they
//! are stored. The result is rounded to the destination's samples (clamped
//! for integer samples), and converted with `image.convert` when the
//! destination's channel layout differs from the source's.
//!
//! Destination pixel `j`'s center lies at source position
//! `(j + 0.5) * src / dst - 0.5`, and on an axis that shrinks the filter is
//! stretched by the ratio, so that it averages over the pixels each
//! destination pixel covers. With the default options the results are
//! stb_image_resize's `stbir_resize_uint8`'s: Catmull-Rom on an axis that
//! grows, Mitchell–Netravali on one that shrinks, edges clamped, samples
//! filtered as stored.
//!
//! `orient` turns and flips an image into another buffer as an
//! `Orientation` says, the eight EXIF transforms, to show a photo upright.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const pixel = @import("pixel.zig");
const PixelFormat = pixel.PixelFormat;
const PixelBuffer = pixel.PixelBuffer;
const convert = @import("convert.zig");
const Orientation = @import("decode.zig").Orientation;

/// The filter each axis is resampled with. Its argument is a distance in
/// source pixels on an axis that grows, and in destination pixels on one
/// that shrinks.
pub const Filter = enum {
    /// Catmull-Rom on an axis that grows or keeps its size, Mitchell on one
    /// that shrinks, as stb_image_resize chooses.
    default,
    /// Nearest neighbor: each destination pixel is the source pixel under
    /// its center, copied.
    point,
    /// Area averaging: each source pixel weighs as much as the destination
    /// pixel covers of it.
    box,
    /// The tent `1 - |x|`, support 1: bilinear on an axis that grows.
    triangle,
    /// The cubic B-spline (Mitchell–Netravali B = 1, C = 0), support 2:
    /// smooth, and it blurs even at the same size.
    b_spline,
    /// Catmull-Rom (Mitchell–Netravali B = 0, C = 1/2; Keys's cubic with
    /// a = -1/2), support 2: interpolating, and sharp.
    catmull_rom,
    /// Mitchell–Netravali B = C = 1/3, support 2: their recommended
    /// balance of blur and ringing.
    mitchell,
    /// Lanczos, `sinc(x) sinc(x / 3)`, support 3.
    lanczos3,
};

/// What a filter reads past the source's edges.
pub const Edge = enum {
    /// The edge pixel, repeated.
    clamp,
    /// The image mirrored about its edge, so the edge pixel repeats once:
    /// `... 2 1 0 | 0 1 2 ...`.
    reflect,
    /// The image repeated, as a tile.
    wrap,
    /// Zero (transparent black). The weights past the edge still count, so
    /// edges darken.
    zero,
};

/// The space samples are filtered in.
pub const Colorspace = enum {
    /// The stored values, as stb_image_resize's `stbir_resize_uint8`,
    /// libvips, and Pillow filter them.
    linear,
    /// Linear light: 8- and 16-bit color and gray samples are decoded from
    /// the sRGB curve (IEC 61966-2-1) before filtering and encoded after.
    /// Alpha, float samples, and CMYK inks are filtered as stored.
    srgb,
};

pub const Options = struct {
    filter: Filter = .default,
    edge: Edge = .clamp,
    colorspace: Colorspace = .linear,
};

pub const Error = error{
    /// A pixel buffer is smaller than its dimensions and stride need.
    BufferTooSmall,
    /// `work` is shorter than `workLen` says.
    WorkTooSmall,
    /// The work memory this resize needs does not fit in `usize`.
    ImageTooLarge,
    /// The source has no pixels and the destination has some.
    EmptySource,
};

/// The bytes of work memory that resizing a `src_width` by `src_height`
/// image in `src_format` to `dst_width` by `dst_height` in `dst_format`
/// takes, for `resize` and `Resizer.init` alike; null if that overflows
/// `usize`. It grows with the destination's width, the source's width, and
/// the filter's reach, and with the heights only through the weights,
/// except that `Edge.wrap` keeps every filtered row.
pub fn workLen(
    dst_format: PixelFormat,
    dst_width: u32,
    dst_height: u32,
    src_format: PixelFormat,
    src_width: u32,
    src_height: u32,
    options: Options,
) ?usize {
    if (dst_width == 0 or dst_height == 0 or src_width == 0 or src_height == 0) return 0;
    const l = Layout.init(dst_format, dst_width, dst_height, src_format, src_width, src_height, options) orelse
        return null;
    return l.total;
}

/// Resizes `src` into `dst`, whatever their sizes and formats. `work` holds
/// at least `workLen` bytes. An empty destination is left as it is.
pub fn resize(dst: PixelBuffer, src: PixelBuffer, work: []u8, options: Options) Error!void {
    try dst.check();
    try src.check();
    if (dst.width == 0 or dst.height == 0) return;
    var r: Resizer = try .init(dst.format, dst.width, dst.height, src.format, src.width, src.height, options, work);
    var y: u32 = 0;
    for (0..src.height) |sy| {
        // Every ready row is taken before the next push, so it cannot fail.
        r.push(src.row(@intCast(sy))) catch unreachable;
        while (y < dst.height and r.take(dst.row(y))) y += 1;
    }
    std.debug.assert(y == dst.height);
}

/// A resize a row at a time: push the source's rows in order, and after
/// each push take every destination row that is ready, in order. Its work
/// memory holds the rows the vertical filter spans, not a frame,
/// and must outlive it.
///
/// ```
/// var r: image.resize.Resizer = try .init(.gray8, 32, 32, .gray8, 128, 128, .{}, work);
/// var y: u32 = 0;
/// for (0..128) |sy| {
///     try r.push(src.row(@intCast(sy)));
///     while (r.take(dst.row(y))) y += 1;
/// }
/// ```
pub const Resizer = struct {
    dst_format: PixelFormat,
    src_format: PixelFormat,
    dst_width: u32,
    dst_height: u32,
    src_width: u32,
    src_height: u32,
    /// Source rows pushed so far.
    pushed: u32 = 0,
    /// The next destination row to take.
    next: u32 = 0,

    edge: Edge,
    channels: u3,
    /// Floats a pixel takes while filtered: the channels, with RGB padded
    /// to four so it runs RGBA's kernels.
    floats_per_pixel: u3,
    /// Where alpha sits in the source's layout, if it has alpha.
    alpha: ?u2,
    /// Premultiply the source, and unpremultiply the result.
    premultiply: bool,
    unpremultiply: bool,
    /// Decode the source's samples from sRGB, and encode the result's.
    decode_srgb: bool,
    encode_srgb: bool,
    /// The format rows are rounded to before the converter, when that is
    /// not the destination's: the source's layout in the destination's
    /// samples and alpha if their layouts match, and otherwise the
    /// source's format with the destination's alpha. For `point`, the
    /// source's format.
    pack_format: PixelFormat,
    converter: ?convert.Converter,
    point: bool,
    /// Filter down the columns first, then along the rows: for one float a
    /// pixel when the image shrinks vertically, so that the horizontal
    /// filter, which fills its vectors worst there, runs on destination
    /// rows. The ring then holds source rows.
    v_first: bool,
    /// 8-bit samples filtered as stored that shrink vertically: the ring
    /// holds the source rows' bytes, and the vertical filter sums them with
    /// 16-bit integer weights (`v_fixed`, two taps at a time, each row's
    /// scaled by its own power of two, undone by `v_scale`) before the
    /// horizontal filter takes them as floats.
    fixed: bool,

    // Horizontal: each destination pixel's first tap in `line` (for
    // `point`, its source pixel), and its `h_taps` weights, each repeated
    // for every float of a pixel and zero past its last tap, so that every
    // pixel is one run of whole vectors. A source row is unpacked into
    // `line`, `pad_left` pixels in, with what the edge mode reads past
    // each edge around it, `pad_right` pixels, and zeros after, as far as
    // the last pixel's padded taps reach.
    h_taps: usize,
    /// Floats in the horizontal filter's vectors (see `filterRow`).
    h_lanes: u5,
    h_start: []u32,
    h_weights: []f32,
    pad_left: usize,
    pad_right: usize,
    line: []f32,
    /// Every destination pixel is its own source pixel, so rows are
    /// unpacked straight into the ring.
    h_identity: bool,

    // Vertical: each destination row's source rows and weights, `v_taps`
    // apart; one past the last row it reads; and the first row it or any
    // row after it reads.
    v_taps: usize,
    v_count: []u32,
    v_rows: []u32,
    v_weights: []f32,
    need: []u32,
    keep: []u32,
    /// A destination row's taps' ring rows, while it is filtered.
    taps: [][]const f32,
    /// With `fixed`: each destination row's weights as integers,
    /// `v_pairs` apart, a zero after an odd count; their scale back to
    /// floats from 0 to 1; and the taps' ring rows, as bytes.
    v_pairs: usize,
    v_fixed: []i16,
    v_scale: []f32,
    byte_taps: [][]const u8,

    /// Source row `y` lives in ring row `y % ring_rows`: filtered to the
    /// destination's width (unfiltered, with `v_first`), `row_stride`
    /// floats long (`floats_per_pixel` a pixel), or for `point` the
    /// source row's bytes, `row_stride` bytes long.
    ring: []u8,
    ring_rows: usize,
    /// `2^64 / ring_rows`, rounded up, for `ringRow` (0 for an empty image).
    ring_magic: u64,
    row_stride: usize,
    /// The vertical filter's result, or with `v_first` the horizontal's.
    out: []f32,
    /// A row in `pack_format`, for the converter.
    pack: []u8,

    pub const PushError = error{
        /// A destination row is ready: take it before pushing another row.
        RowReady,
        /// Every source row has been pushed.
        TooManyRows,
    };

    /// A resizer from a `src_width` by `src_height` image in `src_format`
    /// to `dst_width` by `dst_height` in `dst_format`, which keeps its
    /// weights and rows in `work`, at least `workLen` bytes.
    pub fn init(
        dst_format: PixelFormat,
        dst_width: u32,
        dst_height: u32,
        src_format: PixelFormat,
        src_width: u32,
        src_height: u32,
        options: Options,
        work: []u8,
    ) Error!Resizer {
        const empty = dst_width == 0 or dst_height == 0;
        if (!empty and (src_width == 0 or src_height == 0)) return error.EmptySource;
        const l: Layout = if (empty) .{} else Layout.init(
            dst_format,
            dst_width,
            dst_height,
            src_format,
            src_width,
            src_height,
            options,
        ) orelse return error.ImageTooLarge;
        if (work.len < l.total) return error.WorkTooSmall;
        const linear = options.colorspace == .linear or src_format.isCmyk();
        var r: Resizer = .{
            .dst_format = dst_format,
            .src_format = src_format,
            .dst_width = dst_width,
            .dst_height = dst_height,
            .src_width = src_width,
            .src_height = src_height,
            .edge = options.edge,
            .channels = @intCast(src_format.channelCount()),
            .floats_per_pixel = @intCast(floatsPerPixel(src_format)),
            .alpha = src_format.channels().a,
            .premultiply = src_format.hasAlpha() and !src_format.isPremultiplied(),
            .unpremultiply = l.pack_format.hasAlpha() and !l.pack_format.isPremultiplied(),
            .decode_srgb = !linear and src_format.sample() != .f32,
            .encode_srgb = !linear and l.pack_format.sample() != .f32,
            .pack_format = l.pack_format,
            .converter = if (l.pack_format == dst_format) null else .init(dst_format, l.pack_format),
            .point = l.point,
            .v_first = l.v_first,
            .fixed = l.fixed,
            .h_taps = l.h_taps,
            .h_lanes = 16,
            .h_start = l.slice(u32, work, .h_start),
            .h_weights = l.slice(f32, work, .h_weights),
            .pad_left = l.pad_left,
            .pad_right = l.pad_right,
            .line = l.slice(f32, work, .line),
            .h_identity = false,
            .v_taps = l.v_taps,
            .v_count = l.slice(u32, work, .v_count),
            .v_rows = l.slice(u32, work, .v_rows),
            .v_weights = l.slice(f32, work, .v_weights),
            .need = l.slice(u32, work, .need),
            .keep = l.slice(u32, work, .keep),
            .taps = l.slice([]const f32, work, .taps),
            .v_pairs = l.v_pairs,
            .v_fixed = l.slice(i16, work, .v_fixed),
            .v_scale = l.slice(f32, work, .v_scale),
            .byte_taps = l.slice([]const u8, work, .byte_taps),
            .ring = l.slice(u8, work, .ring),
            .ring_rows = l.ring_rows,
            .ring_magic = if (l.ring_rows == 0) 0 else (std.math.maxInt(u64) / l.ring_rows) +% 1,
            .row_stride = l.row_stride,
            .out = l.slice(f32, work, .out),
            .pack = l.slice(u8, work, .pack),
        };
        if (empty) return r;
        const h: Axis = .init(src_width, dst_width, options.filter);
        const v: Axis = .init(src_height, dst_height, options.filter);
        if (r.point) {
            for (r.h_start, 0..) |*s, x| s.* = @intCast(h.window(@intCast(x)).lo);
        } else {
            r.h_identity = r.planRow(h);
            // Read only with zero weights, but read: finite.
            const inner = (r.pad_left + src_width + r.pad_right) * r.floats_per_pixel;
            @memset(r.line[inner..], 0);
        }
        // A vertical axis like the horizontal one takes its weights.
        r.planColumn(v, !r.point and std.meta.eql(h, v));
        if (r.fixed) r.planFixed(v.period);
        return r;
    }

    /// Hands the resizer the next source row: `src_width` pixels in
    /// `src_format`. Fails if a destination row is ready, since the rows it
    /// reads may be overwritten, or if every source row is in.
    pub fn push(r: *Resizer, row: []const u8) PushError!void {
        if (r.pushed >= r.src_height) return error.TooManyRows;
        if (r.next < r.dst_height and r.need[r.next] <= r.pushed) return error.RowReady;
        const y = r.pushed;
        r.pushed += 1;
        // A row that no destination row still reads is not kept.
        if (r.next >= r.dst_height or y < r.keep[r.next]) return;
        const src = row[0 .. r.src_width * r.src_format.bytesPerPixel()];
        const slot = r.ringRow(y) * r.row_stride;
        if (r.point or r.fixed) {
            @memcpy(r.ring[slot..][0..src.len], src);
            return;
        }
        const fp: usize = r.floats_per_pixel;
        const ring = floats(r.ring)[slot..][0..r.row_stride];
        if (r.h_identity or r.v_first) return r.unpack(src, ring[0 .. r.src_width * fp]);
        r.unpack(src, r.line[r.pad_left * fp ..][0 .. r.src_width * fp]);
        r.padLine();
        r.filterLine(ring);
    }

    /// `line`, padded, through the horizontal filter into `out`.
    fn filterLine(r: *const Resizer, out: []f32) void {
        switch (r.floats_per_pixel) {
            1 => switch (r.h_lanes) {
                inline 4, 8 => |n| filterRow(1, n, r.line, out, r.h_start, r.h_weights, r.h_taps),
                else => unreachable,
            },
            inline 2, 4 => |c| filterRow(c, 16, r.line, out, r.h_start, r.h_weights, r.h_taps),
            else => unreachable,
        }
    }

    /// Writes the next destination row, `dst_width` pixels in
    /// `dst_format`, to `row` and returns true if the source rows it reads
    /// are in; returns false if they are not, or once every row is out.
    pub fn take(r: *Resizer, row: []u8) bool {
        if (r.next >= r.dst_height or r.need[r.next] > r.pushed) return false;
        const y = r.next;
        r.next += 1;
        const dst = row[0 .. r.dst_width * r.dst_format.bytesPerPixel()];
        const to = if (r.converter == null) dst else r.pack;
        const n = r.v_count[y];
        const rows = r.v_rows[y * r.v_taps ..][0..n];
        if (r.point) {
            const bpp = r.src_format.bytesPerPixel();
            const src = r.ring[r.ringRow(rows[0]) * r.row_stride ..][0 .. r.src_width * bpp];
            for (r.h_start, 0..) |sx, x| @memcpy(to[x * bpp ..][0..bpp], src[sx * bpp ..][0..bpp]);
        } else if (r.fixed) {
            r.takeFixed(y, rows, to);
        } else {
            const fp: usize = r.floats_per_pixel;
            const weights = r.v_weights[y * r.v_taps ..][0..n];
            const ring = floats(r.ring);
            // With `v_first`, the vertical filter writes into `line` for
            // the horizontal, exactly a source row long.
            const len = if (r.v_first) r.src_width * fp else r.row_stride;
            const out = if (r.v_first) r.line[r.pad_left * fp ..][0..len] else r.out[0..len];
            var filtered = out;
            if (n == 1 and weights[0] == 1) {
                const one = ring[r.ringRow(rows[0]) * r.row_stride ..][0..len];
                if (r.v_first) @memcpy(out, one) else filtered = one;
            } else {
                for (r.taps[0..n], rows) |*t, s| t.* = ring[r.ringRow(s) * r.row_stride ..][0..len];
                filterColumn(out, r.taps[0..n], weights);
            }
            if (r.v_first and !r.h_identity) {
                r.padLine();
                r.filterLine(r.out);
                filtered = r.out;
            }
            r.packRow(filtered[0 .. r.dst_width * fp], to);
        }
        if (r.converter) |c| c.run(dst, r.pack, r.dst_width);
        return true;
    }

    /// Source row `y`'s ring row, `y % ring_rows`, by Lemire, Kaser, and
    /// Kurz's direct remainder ("Faster Remainder by Direct Computation",
    /// 2019), exact for 32-bit `y` and `ring_rows`: a division for each
    /// tap costs more than the tap on an icon.
    fn ringRow(r: *const Resizer, y: u32) usize {
        const low = r.ring_magic *% y;
        return @intCast((@as(u128, low) * r.ring_rows) >> 64);
    }

    /// `take`'s destination row `y` from 8-bit source `rows`, the vertical
    /// pass in integers, into `to`.
    fn takeFixed(r: *Resizer, y: usize, rows: []const u32, to: []u8) void {
        const fp: usize = r.floats_per_pixel;
        const n = rows.len;
        const pairs = n + n % 2;
        const len = r.src_width * r.src_format.bytesPerPixel();
        for (r.byte_taps[0..pairs], 0..) |*t, k| {
            const s = rows[if (k < n) k else 0];
            t.* = r.ring[r.ringRow(s) * r.row_stride ..][0..len];
        }
        const out = r.line[r.pad_left * fp ..][0 .. r.src_width * fp];
        const weights = r.v_fixed[y * r.v_pairs ..][0..pairs];
        filterColumnFixed(out[0..len], r.byte_taps[0..pairs], weights, r.v_scale[y]);
        if (fp != r.channels) spreadRgb(out);
        var filtered = out;
        if (!r.h_identity) {
            r.padLine();
            r.filterLine(r.out);
            filtered = r.out;
        }
        r.packRow(filtered[0 .. r.dst_width * fp], to);
    }

    /// Plans the horizontal pass, and returns whether it is the identity.
    fn planRow(r: *Resizer, a: Axis) bool {
        var identity = a.src == a.dst;
        const fp: usize = r.floats_per_pixel;
        // The widest window sets the taps every pixel is padded to: at
        // most `l.h_taps`, and often a vector fewer.
        // Pixels past the first period copy the pixel a period before.
        const once = @min(a.period, a.dst);
        var widest: usize = 0;
        for (0..once) |x| {
            const win = a.window(@intCast(x));
            widest = @max(widest, @as(usize, @intCast(win.hi - win.lo + 1)));
        }
        r.h_lanes = @intCast(hLanes(fp, widest));
        const per_vector = r.h_lanes / fp;
        r.h_taps = std.mem.alignForward(usize, widest, per_vector);
        const len = r.h_taps * fp;
        for (r.h_start, 0..) |*start, x| {
            const w = r.h_weights[x * len ..][0..len];
            if (x >= a.dst) {
                // Past the last pixel, to fill the last group.
                start.* = 0;
                @memset(w, 0);
                continue;
            }
            if (x >= once) {
                // The same weights, `shift` pixels on (an identity has a
                // period and shift of 1, so it stays one).
                start.* = r.h_start[x - a.period] + a.shift;
                @memcpy(w, r.h_weights[(x - a.period) * len ..][0..len]);
                continue;
            }
            const win = a.window(@intCast(x));
            const n: usize = @intCast(win.hi - win.lo + 1);
            a.weights(@intCast(x), win, w[0..n]);
            // Zero weights at either end are left out.
            var first: usize = 0;
            var last = n;
            while (first < last and w[first] == 0) first += 1;
            while (last > first and w[last - 1] == 0) last -= 1;
            const count = last - first;
            @memmove(w[0..count], w[first..last]);
            const s = win.lo + @as(i64, @intCast(r.pad_left + first));
            start.* = @intCast(s);
            if (count != 1 or w[0] != 1 or s != @as(i64, @intCast(r.pad_left + x))) identity = false;
            // Each weight for every float of a pixel, from the last, which
            // moves furthest, so none is overwritten before it moves.
            var k = count;
            while (k > 0) {
                k -= 1;
                @memset(w[k * fp ..][0..fp], w[k]);
            }
            @memset(w[count * fp ..], 0);
        }
        return identity;
    }

    /// Plans the vertical pass: each destination row's source rows, with
    /// the edge mode applied, a run of one row merged, and zero weights
    /// left out. If `same`, the axis is the horizontal one, already
    /// planned.
    fn planColumn(r: *Resizer, a: Axis, same: bool) void {
        for (0..a.dst) |y| {
            const rows = r.v_rows[y * r.v_taps ..][0..r.v_taps];
            const w = r.v_weights[y * r.v_taps ..][0..r.v_taps];
            if (r.point) {
                rows[0] = @intCast(a.window(@intCast(y)).lo);
                w[0] = 1;
                r.v_count[y] = 1;
                r.need[y] = rows[0] + 1;
                r.keep[y] = rows[0];
                continue;
            }
            if (y >= a.period) {
                // A row whose taps, a period before, lay inside the image
                // and still do `shift` rows on, copies them.
                const from = y - a.period;
                const before = a.window(@intCast(from));
                if (before.lo >= 0 and before.hi + a.shift < a.src) {
                    const n = r.v_count[from];
                    for (rows[0..n], r.v_rows[from * r.v_taps ..][0..n]) |*to, f| to.* = f + a.shift;
                    @memcpy(w[0..n], r.v_weights[from * r.v_taps ..][0..n]);
                    r.v_count[y] = n;
                    r.need[y] = r.need[from] + a.shift;
                    r.keep[y] = r.keep[from] + a.shift;
                    continue;
                }
            }
            var win = a.window(@intCast(y));
            var n: usize = @intCast(win.hi - win.lo + 1);
            if (same) {
                // The horizontal axis's weights, every float of a pixel's
                // first, from its first tap, zero after its last.
                const fp: usize = r.floats_per_pixel;
                win.lo = @as(i64, r.h_start[y]) - @as(i64, @intCast(r.pad_left));
                n = @min(r.h_taps, r.v_taps);
                for (w[0..n], 0..) |*to, k| to.* = r.h_weights[(y * r.h_taps + k) * fp];
            } else a.weights(@intCast(y), win, w[0..n]);
            var merged: usize = 0;
            switch (r.edge) {
                inline else => |edge| for (0..n) |k| {
                    const s = edgeIndex(win.lo + @as(i64, @intCast(k)), a.src, edge) orelse continue;
                    if (merged > 0 and rows[merged - 1] == s) {
                        w[merged - 1] += w[k];
                    } else {
                        rows[merged] = s;
                        w[merged] = w[k];
                        merged += 1;
                    }
                },
            }
            // Merged weights can cancel to zero too.
            var kept: usize = 0;
            var need: u32 = 0;
            var first: u32 = std.math.maxInt(u32);
            for (rows[0..merged], w[0..merged]) |s, wk| {
                if (wk == 0) continue;
                rows[kept] = s;
                w[kept] = wk;
                kept += 1;
                need = @max(need, s + 1);
                first = @min(first, s);
            }
            r.v_count[y] = @intCast(kept);
            r.need[y] = need;
            r.keep[y] = first;
        }
        // From each row on, the first source row any of them reads.
        var first: u32 = std.math.maxInt(u32);
        var y = a.dst;
        while (y > 0) {
            y -= 1;
            first = @min(first, r.keep[y]);
            r.keep[y] = first;
        }
    }

    /// Turns each destination row's vertical weights into integers for
    /// `filterColumnFixed`: scaled by the largest power of two that keeps
    /// every weight within 16 bits and every sum of 8-bit samples times
    /// them within 32, and rounded cumulatively, so that they sum to
    /// exactly that power and a flat image stays flat.
    /// Rows a `period` apart with the same weights share them.
    fn planFixed(r: *Resizer, period: u32) void {
        for (0..r.dst_height) |y| {
            const n = r.v_count[y];
            const w = r.v_weights[y * r.v_taps ..][0..n];
            const q = r.v_fixed[y * r.v_pairs ..][0 .. n + n % 2];
            if (y >= period and r.v_count[y - period] == n and
                std.mem.eql(f32, w, r.v_weights[(y - period) * r.v_taps ..][0..n]))
            {
                @memcpy(q, r.v_fixed[(y - period) * r.v_pairs ..][0..q.len]);
                r.v_scale[y] = r.v_scale[y - period];
                continue;
            }
            var total: f64 = 0;
            var abs: f64 = 0;
            var most: f64 = 0;
            for (w) |wk| {
                total += wk;
                abs += @abs(wk);
                most = @max(most, @abs(wk));
            }
            // Weights that sum to 1 but for the `f32` rounding are made to
            // sum to exactly 1; those of a row with taps past a zero edge
            // left out sum to less, and stay so.
            const norm = if (@abs(total - 1) < 1e-4) total else 1;
            // Each weight rounds by under 1, so |q| is under |w| 2^p + 1.
            const nf: f64 = @floatFromInt(n);
            const limit = norm * @min((max_fixed_weight - 1) / most, (std.math.maxInt(i32) / 255 - nf) / abs);
            // floor(log2(x)) from the exponent bits: x is a positive
            // normal float, at least 32766 / 1.0001 or 2^23 / 4096 / 1.0001.
            const exponent: i32 = @intCast(@as(u64, @bitCast(limit)) >> 52);
            const shift = std.math.clamp(exponent - 1023, 0, 30);
            const scale: f64 = @floatFromInt(@as(u32, 1) << @intCast(shift));
            const per = scale / norm;
            var sum: f64 = 0;
            var before: i64 = 0;
            for (w, q[0..n]) |wk, *qk| {
                sum += wk;
                const upto: i64 = @intFromFloat(@round(sum * per));
                qk.* = @intCast(upto - before);
                before = upto;
            }
            if (n % 2 == 1) q[n] = 0;
            r.v_scale[y] = @floatCast(1 / (scale * 255));
        }
    }

    /// Fills `line` past each edge of the source row in it, as the edge
    /// mode reads it.
    fn padLine(r: *Resizer) void {
        switch (r.floats_per_pixel) {
            inline 1, 2, 4 => |fp| {
                const P = [fp]f32;
                const line = std.mem.bytesAsSlice(P, std.mem.sliceAsBytes(r.line));
                const inner = r.pad_left + r.src_width;
                const left = line[0..r.pad_left];
                const right = line[inner..][0..r.pad_right];
                switch (r.edge) {
                    .clamp => {
                        @memset(left, line[r.pad_left]);
                        @memset(right, line[inner - 1]);
                    },
                    .zero => {
                        @memset(left, @splat(0));
                        @memset(right, @splat(0));
                    },
                    inline .reflect, .wrap => |edge| for (0..r.pad_left + r.pad_right) |q| {
                        const p = if (q < r.pad_left) q else inner + q - r.pad_left;
                        const i = @as(i64, @intCast(p)) - @as(i64, @intCast(r.pad_left));
                        line[p] = line[r.pad_left + edgeIndex(i, r.src_width, edge).?];
                    },
                }
            },
            else => unreachable,
        }
    }

    /// A source row to floats from 0 to 1 (as stored, for float samples),
    /// `floats_per_pixel` a pixel, decoded from sRGB and premultiplied as
    /// the options say.
    fn unpack(r: *const Resizer, src: []const u8, out: []f32) void {
        const ch: usize = r.channels;
        const fp: usize = r.floats_per_pixel;
        const sample = r.src_format.sample();
        if (sample == .u8 and !r.decode_srgb and ch == fp) {
            unpack8(src, out);
        } else if (sample == .u8 and !r.decode_srgb and ch == 3) {
            unpack8x3(src, out);
        } else switch (sample) {
            inline else => |t| switch (r.channels) {
                inline 1...4 => |c| switch (r.decode_srgb) {
                    inline else => |srgb| unpackSamples(t, c, srgb, r.alpha, src, out),
                },
                else => unreachable,
            },
        }
        if (r.premultiply) switch (r.alpha.?) {
            inline else => |a| switch (r.floats_per_pixel) {
                inline 2, 4 => |n| if (a < n) {
                    const V = @Vector(n, f32);
                    var keep: @Vector(n, bool) = @splat(false);
                    keep[a] = true;
                    var p: usize = 0;
                    while (p < out.len) : (p += n) {
                        const v: V = out[p..][0..n].*;
                        out[p..][0..n].* = v * @select(f32, keep, @as(V, @splat(1)), @as(V, @splat(v[a])));
                    }
                },
                else => unreachable,
            },
        };
    }

    /// Filtered floats to a row in `pack_format`: unpremultiplied, encoded
    /// to sRGB, and rounded as the options and format say.
    fn packRow(r: *const Resizer, in: []const f32, out: []u8) void {
        const f = r.pack_format;
        const ch: usize = r.channels;
        const fp: usize = r.floats_per_pixel;
        if (f.sample() == .u8 and !r.encode_srgb) {
            if (!r.unpremultiply) return if (ch == fp) pack8(in, out) else pack8x3(in, out);
            switch (r.alpha.?) {
                inline else => |a| switch (r.floats_per_pixel) {
                    inline 2, 4 => |n| if (a < n) return unpremultiply8(n, a, in, out),
                    else => unreachable,
                },
            }
        }
        var p: usize = 0;
        var o: usize = 0;
        while (p < in.len) : ({
            p += fp;
            o += ch;
        }) {
            var px: [4]f32 = undefined;
            @memcpy(px[0..ch], in[p..][0..ch]);
            if (r.unpremultiply) {
                // A pixel written fully transparent is transparent black:
                // a color divided by an alpha that rounds to 0 is noise.
                const a = r.alpha.?;
                const visible = switch (f.sample()) {
                    .u8 => quantize(px[a], 255) != 0,
                    .u16 => quantize(px[a], 65535) != 0,
                    .f32 => px[a] > 0,
                };
                const scale: f32 = if (visible) 1 / px[a] else 0;
                for (px[0..ch], 0..) |*s, c| {
                    if (c != a) s.* *= scale;
                }
            }
            for (px[0..ch], o..) |s, i| {
                const color = r.alpha == null or i - o != r.alpha.?;
                switch (f.sample()) {
                    .u8 => out[i] = if (r.encode_srgb and color) srgbEncode8(s) else @intCast(quantize(s, 255)),
                    .u16 => {
                        const e = if (r.encode_srgb and color) srgbEncode(f32, std.math.clamp(s, 0, 1)) else s;
                        std.mem.writeInt(u16, out[2 * i ..][0..2], @intCast(quantize(e, 65535)), native);
                    },
                    .f32 => std.mem.writeInt(u32, out[4 * i ..][0..4], @bitCast(s), native),
                }
            }
        }
    }
};

const native = builtin.target.cpu.arch.endian();

/// `bytes` as floats; its address is a multiple of 64.
fn floats(bytes: []u8) []f32 {
    const aligned: []align(64) u8 = @alignCast(bytes);
    return std.mem.bytesAsSlice(f32, aligned);
}

/// A float sample to an integer one: rounded to nearest, clamped, NaN to 0.
inline fn quantize(v: f32, comptime max: f32) u32 {
    return @intFromFloat(@min(@max(v * max + 0.5, 0), max));
}

/// Vectors of this many floats in the filter loops.
const lanes = 16;
const F = @Vector(lanes, f32);

fn unpack8(src: []const u8, out: []f32) void {
    var i: usize = 0;
    while (i + lanes <= out.len) : (i += lanes) {
        const v: @Vector(lanes, u8) = src[i..][0..lanes].*;
        out[i..][0..lanes].* = @as(F, @floatFromInt(v)) * @as(F, @splat(1.0 / 255.0));
    }
    while (i < out.len) : (i += 1) out[i] = @as(f32, @floatFromInt(src[i])) * (1.0 / 255.0);
}

/// `Resizer.unpack` for any samples, decoded from sRGB if `srgb`, but not
/// premultiplied.
fn unpackSamples(
    comptime t: PixelFormat.Sample,
    comptime ch: usize,
    comptime srgb: bool,
    alpha: ?u2,
    src: []const u8,
    out: []f32,
) void {
    const fp = comptime if (ch == 3) 4 else ch;
    for (0..out.len / fp) |p| {
        const px = out[p * fp ..][0..fp];
        inline for (0..ch) |c| {
            const i = p * ch + c;
            const color = alpha == null or c != alpha.?;
            px[c] = switch (t) {
                .u8 => if (srgb and color) srgb_decode8[src[i]] else @as(f32, @floatFromInt(src[i])) / 255,
                .u16 => v: {
                    const v = @as(f32, @floatFromInt(std.mem.readInt(u16, src[2 * i ..][0..2], native))) / 65535;
                    break :v if (srgb and color) srgbDecode(f32, v) else v;
                },
                .f32 => @bitCast(std.mem.readInt(u32, src[4 * i ..][0..4], native)),
            };
        }
        if (fp > ch) px[3] = 0;
    }
}

/// RGB bytes to floats, four a pixel, the fourth 0.
fn unpack8x3(src: []const u8, out: []f32) void {
    const mask = comptime blk: {
        var m: [64]i32 = undefined;
        for (&m, 0..) |*v, i| v.* = if (i % 4 == 3) -1 else @intCast(i / 4 * 3 + i % 4);
        break :blk m;
    };
    const pixels = out.len / 4;
    var p: usize = 0;
    while (p + 16 <= pixels) : (p += 16) {
        const v: @Vector(48, u8) = src[p * 3 ..][0..48].*;
        const e: @Vector(64, u8) = @shuffle(u8, v, @as(@Vector(48, u8), @splat(0)), mask);
        out[p * 4 ..][0..64].* = @as(@Vector(64, f32), @floatFromInt(e)) * @as(@Vector(64, f32), @splat(1.0 / 255.0));
    }
    while (p < pixels) : (p += 1) {
        for (0..3) |c| out[p * 4 + c] = @as(f32, @floatFromInt(src[p * 3 + c])) * (1.0 / 255.0);
        out[p * 4 + 3] = 0;
    }
}

/// Floats, four a pixel, to RGB bytes, dropping the fourth.
fn pack8x3(in: []const f32, out: []u8) void {
    const mask = comptime blk: {
        var m: [48]i32 = undefined;
        for (&m, 0..) |*v, i| v.* = @intCast(i / 3 * 4 + i % 3);
        break :blk m;
    };
    const pixels = in.len / 4;
    var p: usize = 0;
    while (p + 16 <= pixels) : (p += 16) {
        const V = @Vector(64, f32);
        const v: V = in[p * 4 ..][0..64].*;
        const q = @min(@max(v * @as(V, @splat(255)) + @as(V, @splat(0.5)), @as(V, @splat(0))), @as(V, @splat(255)));
        const b: @Vector(64, u8) = @intFromFloat(q);
        out[p * 3 ..][0..48].* = @shuffle(u8, b, undefined, mask);
    }
    while (p < pixels) : (p += 1) {
        for (0..3) |c| out[p * 3 + c] = @intCast(quantize(in[p * 4 + c], 255));
    }
}

/// Premultiplied floats, `n` a pixel with alpha at `a`, to straight 8-bit
/// samples, as `Resizer.packRow` does them one at a time.
fn unpremultiply8(comptime n: usize, comptime a: usize, in: []const f32, out: []u8) void {
    const V = @Vector(n, f32);
    var keep: @Vector(n, bool) = @splat(false);
    keep[a] = true;
    var p: usize = 0;
    while (p < in.len) : (p += n) {
        const v: V = in[p..][0..n].*;
        const visible = @min(@max(v[a] * 255 + 0.5, 0), 255) >= 1;
        const scale: f32 = if (visible) 1 / v[a] else 0;
        const u = v * @select(f32, keep, @as(V, @splat(1)), @as(V, @splat(scale)));
        const q = @min(@max(u * @as(V, @splat(255)) + @as(V, @splat(0.5)), @as(V, @splat(0))), @as(V, @splat(255)));
        out[p..][0..n].* = @as(@Vector(n, u8), @intFromFloat(q));
    }
}

fn pack8(in: []const f32, out: []u8) void {
    var i: usize = 0;
    while (i + lanes <= in.len) : (i += lanes) {
        const v: F = in[i..][0..lanes].*;
        const q = @min(@max(v * @as(F, @splat(255)) + @as(F, @splat(0.5)), @as(F, @splat(0))), @as(F, @splat(255)));
        out[i..][0..lanes].* = @as(@Vector(lanes, u8), @intFromFloat(q));
    }
    while (i < in.len) : (i += 1) out[i] = @intCast(quantize(in[i], 255));
}

/// Taps summed into a partial sum before it is added to the total, in both
/// passes: a box shrinking 1016 rows of 16-bit samples to one, summed
/// straight into one f32, came out a step above every source sample.
/// Blocks keep the rounding to about (taps / block + block) additions
/// rather than taps, and change nothing up to `block` taps.
const block = 16;

/// Floats in the horizontal filter's vectors for `fp` floats a pixel and
/// `taps` taps (null for the most any number of taps takes): 16, but for
/// one channel, whose taps are few on an axis that grows, 4 or 8.
fn hLanes(fp: usize, taps: ?usize) usize {
    if (fp != 1) return 16;
    const t = taps orelse return 8;
    return if (t <= 4) 4 else 8;
}

/// The most destination pixels the horizontal filter computes together:
/// as many as fill one vector once each is folded to `fp` floats.
fn hGroup(fp: usize) usize {
    return hLanes(fp, null) / fp;
}

/// One row through the horizontal filter, `fp` floats a pixel, in vectors
/// of `n` floats: each destination pixel is the sum of `taps` source
/// pixels from its start in `line` times its weights. A group of pixels is
/// summed side by side, so that their sums do not wait on each other, then
/// folded together into one vector of the group's pixels. `starts` holds
/// whole groups.
fn filterRow(
    comptime fp: usize,
    comptime n: usize,
    line: []const f32,
    out: []f32,
    starts: []const u32,
    weights: []const f32,
    taps: usize,
) void {
    const g = n / fp;
    const V = @Vector(n, f32);
    const len = taps * fp;
    switch (len / n) {
        // Few vectors a pixel, as on an axis that grows: unrolled.
        inline 1...4 => |steps| {
            var x: usize = 0;
            while (x < starts.len) : (x += g) {
                var acc: [g]V = @splat(@splat(0));
                inline for (0..steps) |step| {
                    inline for (&acc, 0..) |*a, i| {
                        const w = weights[(x + i) * len + step * n ..][0..n].*;
                        const v = line[starts[x + i] * fp + step * n ..][0..n].*;
                        a.* += @as(V, w) * @as(V, v);
                    }
                }
                out[x * fp ..][0..n].* = foldGroup(n, fp, g, acc);
            }
            return;
        },
        else => {},
    }
    var x: usize = 0;
    while (x < starts.len) : (x += g) {
        var acc: [g]V = @splat(@splat(0));
        var k: usize = 0;
        while (k < len) {
            const end = @min(len, k + block * n);
            var part: [g]V = @splat(@splat(0));
            while (k < end) : (k += n) {
                inline for (&part, 0..) |*p, i| {
                    const w = weights[(x + i) * len + k ..][0..n].*;
                    const v = line[starts[x + i] * fp + k ..][0..n].*;
                    p.* += @as(V, w) * @as(V, v);
                }
            }
            inline for (&acc, part) |*a, p| a.* += p;
        }
        out[x * fp ..][0..n].* = foldGroup(n, fp, g, acc);
    }
}

/// `acc`'s vectors, each folded to `fp` floats (the sum of its lanes `fp`
/// apart), side by side: pairs of vectors become one by adding the even
/// and odd runs of `fp` lanes of the two, until one is left.
inline fn foldGroup(comptime n: usize, comptime fp: usize, comptime g: usize, acc: [g]@Vector(n, f32)) @Vector(n, f32) {
    if (g == 1) return acc[0];
    var next: [g / 2]@Vector(n, f32) = undefined;
    inline for (&next, 0..) |*v, i| {
        v.* = @shuffle(f32, acc[2 * i], acc[2 * i + 1], runs(n, fp, 0)) +
            @shuffle(f32, acc[2 * i], acc[2 * i + 1], runs(n, fp, 1));
    }
    return foldGroup(n, fp, g / 2, next);
}

/// A shuffle mask of the even (`odd` 0) or odd runs of `fp` lanes of two
/// vectors of `n` lanes, one after the other.
fn runs(comptime n: usize, comptime fp: usize, comptime odd: usize) @Vector(n, i32) {
    @setEvalBranchQuota(10_000);
    var mask: [n]i32 = undefined;
    for (&mask, 0..) |*m, i| {
        const from = (2 * (i / fp) + odd) * fp + i % fp;
        m.* = if (from < n) @intCast(from) else ~@as(i32, @intCast(from - n));
    }
    return mask;
}

/// One row through the vertical filter: `out` is the sum of each tap's row
/// times its weight. Every row is as long as `out`.
fn filterColumn(out: []f32, taps: []const []const f32, weights: []const f32) void {
    var i: usize = 0;
    while (i + 4 * lanes <= out.len) : (i += 4 * lanes) columns(4, out, taps, weights, i);
    while (i + lanes <= out.len) : (i += lanes) columns(1, out, taps, weights, i);
    while (i < out.len) : (i += 1) {
        var acc: f32 = 0;
        var k: usize = 0;
        while (k < taps.len) {
            const end = @min(taps.len, k + block);
            var part: f32 = 0;
            while (k < end) : (k += 1) part += taps[k][i] * weights[k];
            acc += part;
        }
        out[i] = acc;
    }
}

/// The largest integer weight (`Resizer.planFixed`).
const max_fixed_weight = std.math.maxInt(i16);

/// The most vertical taps the integer filter takes: past it, weights of a
/// few units each would round too coarsely, and floats do it.
const max_fixed_taps = 4096;

/// The narrowest source row, in bytes, the integer filter takes: below one
/// 64-byte run, planning its weights costs more than it saves, and floats
/// do it.
// Measured in results/resize-fast-20261105.md.
const min_fixed_row = 64;

/// One row through the vertical filter on 8-bit rows, `taps` an even
/// number of them: each byte's sum of the taps' bytes times their integer
/// `weights`, two taps at a time (as `vpmaddwd` and `vpdpwssd` do), times
/// `scale`, into `out`, a float a byte, in runs of 64 bytes (several
/// vectors summed side by side), then 16.
fn filterColumnFixed(out: []f32, taps: []const []const u8, weights: []const i16, scale: f32) void {
    var i: usize = 0;
    while (i + 64 <= out.len) : (i += 64) columnsFixed(64, out, taps, weights, scale, i);
    while (i + 16 <= out.len) : (i += 16) columnsFixed(16, out, taps, weights, scale, i);
    while (i < out.len) : (i += 1) {
        var acc: i32 = 0;
        for (taps, weights) |t, wk| acc += @as(i32, t[i]) * wk;
        out[i] = @as(f32, @floatFromInt(acc)) * scale;
    }
}

/// `run` bytes of `filterColumnFixed`'s output from `at` on.
inline fn columnsFixed(
    comptime run: usize,
    out: []f32,
    taps: []const []const u8,
    weights: []const i16,
    scale: f32,
    at: usize,
) void {
    const masks = comptime blk: {
        var interleave: [2 * run]i32 = undefined;
        var even: [run]i32 = undefined;
        var odd: [run]i32 = undefined;
        var pair: [2 * run]i32 = undefined;
        for (&interleave, 0..) |*m, i| m.* = if (i % 2 == 0) @intCast(i / 2) else ~@as(i32, @intCast(i / 2));
        for (&even, &odd, 0..) |*e, *o, i| {
            e.* = @intCast(2 * i);
            o.* = @intCast(2 * i + 1);
        }
        for (&pair, 0..) |*m, i| m.* = @intCast(i % 2);
        break :blk .{ .interleave = interleave, .even = even, .odd = odd, .pair = pair };
    };
    var acc: @Vector(run, i32) = @splat(0);
    var k: usize = 0;
    while (k < taps.len) : (k += 2) {
        const two: @Vector(2, i16) = .{ weights[k], weights[k + 1] };
        const w: @Vector(2 * run, i16) = @shuffle(i16, two, undefined, masks.pair);
        const b0: @Vector(run, u8) = taps[k][at..][0..run].*;
        const b1: @Vector(run, u8) = taps[k + 1][at..][0..run].*;
        const x: @Vector(2 * run, u8) = @shuffle(u8, b0, b1, masks.interleave);
        const product = @as(@Vector(2 * run, i32), @as(@Vector(2 * run, i16), x)) * @as(@Vector(2 * run, i32), w);
        acc += @shuffle(i32, product, undefined, masks.even) + @shuffle(i32, product, undefined, masks.odd);
    }
    out[at..][0..run].* = @as(@Vector(run, f32), @floatFromInt(acc)) * @as(@Vector(run, f32), @splat(scale));
}

/// RGB floats at the start of `px`, three a pixel, spread in place to four
/// a pixel, the fourth 0: from the last pixel back, so that every pixel is
/// read before a later one is written over it.
fn spreadRgb(px: []f32) void {
    const pixels = px.len / 4;
    const mask = comptime blk: {
        var m: [64]i32 = undefined;
        for (&m, 0..) |*v, i| v.* = if (i % 4 == 3) -1 else @intCast(i / 4 * 3 + i % 4);
        break :blk m;
    };
    var p = pixels;
    while (p % 16 != 0) {
        p -= 1;
        const c = px[p * 3 ..][0..3].*;
        px[p * 4 ..][0..4].* = .{ c[0], c[1], c[2], 0 };
    }
    while (p > 0) {
        p -= 16;
        const v: @Vector(48, f32) = px[p * 3 ..][0..48].*;
        px[p * 4 ..][0..64].* = @shuffle(f32, v, @as(@Vector(48, f32), @splat(0)), mask);
    }
}

/// `m` vectors of `filterColumn`'s output from `i` on, summed side by side.
inline fn columns(comptime m: usize, out: []f32, taps: []const []const f32, weights: []const f32, i: usize) void {
    var acc: [m]F = @splat(@splat(0));
    var k: usize = 0;
    while (k < taps.len) {
        const end = @min(taps.len, k + block);
        var part: [m]F = @splat(@splat(0));
        while (k < end) : (k += 1) {
            const w: F = @splat(weights[k]);
            inline for (&part, 0..) |*p, j| p.* += @as(F, taps[k][i + j * lanes ..][0..lanes].*) * w;
        }
        inline for (&acc, part) |*a, p| a.* += p;
    }
    inline for (acc, 0..) |a, j| out[i + j * lanes ..][0..lanes].* = a;
}

/// Source index `i` as the edge mode reads it, or null for a zero.
fn edgeIndex(i: i64, n: u32, comptime edge: Edge) ?u32 {
    if (i >= 0 and i < n) return @intCast(i);
    return switch (edge) {
        .clamp => if (i < 0) 0 else n - 1,
        .zero => null,
        .wrap => @intCast(@mod(i, n)),
        .reflect => {
            const p = @mod(i, 2 * @as(i64, n));
            return @intCast(if (p < n) p else 2 * @as(i64, n) - 1 - p);
        },
    };
}

/// One axis's geometry: where each destination pixel's taps are, and their
/// weights.
const Axis = struct {
    src: u32,
    dst: u32,
    /// Never `default`.
    filter: Filter,
    /// Source pixels per destination pixel.
    scale: f64,
    /// How far the filter is stretched: by the scale when the axis
    /// shrinks.
    stretch: f64,
    /// The filter's reach, in source pixels.
    radius: f64,
    /// The most pixels a window holds.
    taps: i64,
    /// Every `period` destination pixels, the windows and weights repeat
    /// `shift` source pixels on: `src / dst` in lowest terms is
    /// `shift / period`.
    period: u32,
    shift: u32,

    const Window = struct { lo: i64, hi: i64 };

    fn init(src: u32, dst: u32, filter: Filter) Axis {
        const scale = @as(f64, @floatFromInt(src)) / @as(f64, @floatFromInt(dst));
        const f: Filter = if (filter == .default) (if (scale > 1) .mitchell else .catmull_rom) else filter;
        const stretch = @max(scale, 1);
        const support: f64 = switch (f) {
            .triangle => 1,
            .b_spline, .catmull_rom, .mitchell => 2,
            .lanczos3 => 3,
            .default, .point, .box => 0,
        };
        const radius = support * stretch;
        // ceil(x + R) - floor(x - R) - 1 is below 2R + 1, and below
        // ceil(s) + 2 for a box's footprint, with a pixel to spare for
        // rounding.
        const taps: f64 = switch (f) {
            .point => 1,
            .box => @ceil(scale) + 2,
            else => @ceil(2 * radius) + 1,
        };
        return .{
            .src = src,
            .dst = dst,
            .filter = f,
            .scale = scale,
            .stretch = stretch,
            .radius = radius,
            .taps = @intFromFloat(taps),
            .period = dst / std.math.gcd(src, dst),
            .shift = src / std.math.gcd(src, dst),
        };
    }

    /// The source pixels destination pixel `j` may read, before the edge
    /// mode: every pixel the filter is not zero at, and for `point` the one
    /// it copies.
    fn window(a: Axis, j: u32) Window {
        const jf: f64 = @floatFromInt(j);
        switch (a.filter) {
            .point => {
                // floor((j + 0.5) * src / dst), in integers so that a pixel
                // center on a source pixel's edge picks the same pixel at
                // every ratio.
                const i: u128 = (2 * @as(u128, j) + 1) * a.src / (2 * @as(u128, a.dst));
                const c: i64 = @intCast(@min(i, a.src - 1));
                return .{ .lo = c, .hi = c };
            },
            .box => {
                // The source pixels destination pixel j's footprint,
                // from j * src / dst to (j + 1) * src / dst, overlaps.
                const lo: i64 = @intCast(@as(u128, j) * a.src / a.dst);
                const hi: i64 = @intCast(((@as(u128, j) + 1) * a.src + a.dst - 1) / a.dst - 1);
                return .{ .lo = lo, .hi = std.math.clamp(hi, lo, lo + a.taps - 1) };
            },
            else => {
                const c = (jf + 0.5) * a.scale - 0.5;
                const lo: i64 = @as(i64, @intFromFloat(@floor(c - a.radius))) + 1;
                const hi: i64 = @as(i64, @intFromFloat(@ceil(c + a.radius))) - 1;
                return .{ .lo = lo, .hi = std.math.clamp(hi, lo, lo + a.taps - 1) };
            },
        }
    }

    /// Destination pixel `j`'s weights for the pixels of `win`, summing
    /// to 1.
    fn weights(a: Axis, j: u32, win: Window, out: []f32) void {
        const jf: f64 = @floatFromInt(j);
        const c = (jf + 0.5) * a.scale - 0.5;
        var sum: f64 = 0;
        const inv = 1 / a.stretch;
        switch (a.filter) {
            inline else => |f| for (out, 0..) |*w, k| {
                const v: f64 = switch (f) {
                    .box => box: {
                        // The overlap in units of 1 / dst, exactly.
                        const ii = win.lo + @as(i64, @intCast(k));
                        const lo = @max(@as(i128, ii) * a.dst, @as(i128, j) * a.src);
                        const hi = @min((@as(i128, ii) + 1) * a.dst, (@as(i128, j) + 1) * a.src);
                        break :box @floatFromInt(@max(0, hi - lo));
                    },
                    .point => 1,
                    .default => unreachable,
                    else => kernel(f, (@as(f64, @floatFromInt(win.lo + @as(i64, @intCast(k)))) - c) * inv),
                };
                w.* = @floatCast(v);
                sum += v;
            },
        }
        const norm: f32 = if (sum == 0) 0 else @floatCast(1 / sum);
        for (out) |*w| w.* *= norm;
    }
};

/// A filter's value at `x`.
inline fn kernel(comptime f: Filter, x: f64) f64 {
    const ax = @abs(x);
    return switch (f) {
        .triangle => @max(0, 1 - ax),
        .b_spline => cubic(1, 0, ax),
        .catmull_rom => cubic(0, 0.5, ax),
        .mitchell => cubic(1.0 / 3.0, 1.0 / 3.0, ax),
        .lanczos3 => if (ax < 3) sinc(x) * sinc(x / 3) else 0,
        .default, .point, .box => unreachable,
    };
}

/// Mitchell and Netravali's cubic family ("Reconstruction Filters in
/// Computer Graphics", 1988) at `x` ≥ 0.
inline fn cubic(comptime b: f64, comptime c: f64, x: f64) f64 {
    // The coefficients over 6, so that no division is left at run time.
    const near = comptime [3]f64{ (12 - 9 * b - 6 * c) / 6, (-18 + 12 * b + 6 * c) / 6, (6 - 2 * b) / 6 };
    const far = comptime [4]f64{ (-b - 6 * c) / 6, (6 * b + 30 * c) / 6, (-12 * b - 48 * c) / 6, (8 * b + 24 * c) / 6 };
    if (x < 1) return (near[0] * x + near[1]) * x * x + near[2];
    if (x < 2) return ((far[0] * x + far[1]) * x + far[2]) * x + far[3];
    return 0;
}

fn sinc(x: f64) f64 {
    if (x == 0) return 1;
    const px = std.math.pi * x;
    return @sin(px) / px;
}

/// The sRGB curve, encoded to linear.
fn srgbDecode(comptime T: type, v: T) T {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(T, (v + 0.055) / 1.055, 2.4);
}

/// The sRGB curve, linear to encoded.
fn srgbEncode(comptime T: type, v: T) T {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(T, v, 1.0 / 2.4) - 0.055;
}

const srgb_decode8: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| v.* = @floatCast(srgbDecode(f64, @as(f64, @floatFromInt(i)) / 255));
    break :blk t;
};

/// Where each 8-bit code's rounding interval ends, in linear light: code
/// `k` covers values from `srgb_bounds[k - 1]` up to `srgb_bounds[k]`.
const srgb_bounds: [255]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [255]f32 = undefined;
    for (&t, 0..) |*v, k| v.* = @floatCast(srgbDecode(f64, (@as(f64, @floatFromInt(k)) + 0.5) / 255));
    break :blk t;
};

/// A linear value to its nearest 8-bit sRGB code, clamped, NaN to 0.
fn srgbEncode8(v: f32) u8 {
    var k: usize = 0;
    inline for (.{ 128, 64, 32, 16, 8, 4, 2, 1 }) |step| {
        if (v >= srgb_bounds[k + step - 1]) k += step;
    }
    return @intCast(k);
}

/// The format a filtered row is rounded to before any conversion (see
/// `Resizer.pack_format`).
fn packFormat(dst: PixelFormat, src: PixelFormat) PixelFormat {
    const same = dst.isCmyk() == src.isCmyk() and dst.channelCount() == src.channelCount() and
        std.meta.eql(dst.channels(), src.channels());
    if (same) return dst;
    if (src.hasAlpha() and dst.hasAlpha() and src.isPremultiplied() != dst.isPremultiplied()) {
        return switch (src) {
            .gray_alpha8 => .gray_alpha8_premul,
            .gray_alpha8_premul => .gray_alpha8,
            .rgba8 => .rgba8_premul,
            .rgba8_premul => .rgba8,
            .bgra8 => .bgra8_premul,
            .bgra8_premul => .bgra8,
            .gray_alpha16 => .gray_alpha16_premul,
            .gray_alpha16_premul => .gray_alpha16,
            .rgba16 => .rgba16_premul,
            .rgba16_premul => .rgba16,
            .bgra16 => .bgra16_premul,
            .bgra16_premul => .bgra16,
            .rgba_f32 => .rgba_f32_premul,
            .rgba_f32_premul => .rgba_f32,
            else => unreachable,
        };
    }
    return src;
}

/// Floats a pixel takes while filtered: RGB is padded to four.
fn floatsPerPixel(f: PixelFormat) usize {
    const ch = f.channelCount();
    return if (ch == 3) 4 else ch;
}

/// Where each part of the work memory lies, and how long the whole is.
const Layout = struct {
    point: bool = false,
    v_first: bool = false,
    fixed: bool = false,
    v_pairs: usize = 0,
    pack_format: PixelFormat = .gray8,
    h_taps: usize = 0,
    pad_left: usize = 0,
    pad_right: usize = 0,
    v_taps: usize = 0,
    ring_rows: usize = 0,
    row_stride: usize = 0,
    /// Each part's offset from the work memory's first 64-byte boundary,
    /// in bytes, and length, in elements.
    parts: std.enums.EnumArray(Part, [2]usize) = .initFill(.{ 0, 0 }),
    total: usize = 0,

    const Part = enum {
        h_start,
        h_weights,
        line,
        v_count,
        v_rows,
        v_weights,
        need,
        keep,
        taps,
        v_fixed,
        v_scale,
        byte_taps,
        ring,
        out,
        pack,
    };
    const alignment = 64;

    fn init(
        dst_format: PixelFormat,
        dst_width: u32,
        dst_height: u32,
        src_format: PixelFormat,
        src_width: u32,
        src_height: u32,
        options: Options,
    ) ?Layout {
        const point = options.filter == .point;
        const h: Axis = .init(src_width, dst_width, options.filter);
        const v: Axis = .init(src_height, dst_height, options.filter);
        const fp = floatsPerPixel(src_format);
        const shrinks = !point and dst_height < src_height;
        // 8-bit samples filtered as stored (results/resize-fast-20261105.md).
        const fixed = shrinks and @as(usize, src_width) * src_format.bytesPerPixel() >= min_fixed_row and
            src_format.sample() == .u8 and v.taps <= max_fixed_taps and
            (options.colorspace == .linear or src_format.isCmyk()) and
            !(src_format.hasAlpha() and !src_format.isPremultiplied());
        var l: Layout = .{
            .point = point,
            // For floats, only for one float a pixel: with more, the
            // horizontal filter's vectors are full anyway, and source rows
            // in the ring cost memory and cache (results/resize-20261105.md).
            .v_first = shrinks and (fixed or fp == 1),
            .fixed = fixed,
            .pack_format = if (point) src_format else packFormat(dst_format, src_format),
        };
        if (!point) {
            // Windows move right with the destination pixel, so the first
            // reaches furthest left and the last furthest right. Taps are
            // padded to whole vectors (see `filterRow`).
            const per_vector = hLanes(fp, null) / fp;
            const taps = std.math.cast(usize, h.taps) orelse return null;
            l.h_taps = mul(std.math.divCeil(usize, taps, per_vector) catch unreachable, per_vector) orelse return null;
            const first = h.window(0);
            const final = h.window(dst_width - 1);
            if (first.lo < 0) l.pad_left = std.math.cast(usize, -first.lo) orelse return null;
            if (final.hi >= src_width) l.pad_right = std.math.cast(usize, final.hi - src_width + 1) orelse return null;
        }
        l.v_taps = std.math.cast(usize, v.taps) orelse return null;
        l.ring_rows = std.math.cast(usize, ringRows(v, options.edge)) orelse return null;
        const bpp_src = src_format.bytesPerPixel();
        // A destination row as the filters write it: room for the last
        // group of pixels, and whole vectors.
        const dst_row = std.mem.alignForward(
            usize,
            mul(std.mem.alignForward(usize, dst_width, hGroup(fp)), fp) orelse return null,
            lanes,
        );
        if (point or fixed) {
            l.row_stride = std.mem.alignForward(usize, mul(src_width, bpp_src) orelse return null, alignment);
        } else {
            // Ring rows are destination rows, or with `v_first` source rows.
            const row = if (l.v_first) mul(src_width, fp) orelse return null else dst_row;
            l.row_stride = std.mem.alignForward(usize, row, lanes);
        }
        var at: usize = 0;
        // Whole groups of pixels for the horizontal filter.
        const h_pixels = if (point) dst_width else std.mem.alignForward(usize, dst_width, hGroup(fp));
        l.place(&at, .h_start, h_pixels, @sizeOf(u32)) orelse return null;
        if (!point) {
            const weights = mul(mul(h_pixels, l.h_taps) orelse return null, fp) orelse return null;
            l.place(&at, .h_weights, weights, @sizeOf(f32)) orelse return null;
            const inner = add(add(l.pad_left, src_width) orelse return null, l.pad_right) orelse return null;
            const line_px = add(inner, l.h_taps) orelse return null;
            l.place(&at, .line, mul(line_px, fp) orelse return null, @sizeOf(f32)) orelse return null;
        }
        const v_len = mul(dst_height, l.v_taps) orelse return null;
        l.place(&at, .v_count, dst_height, @sizeOf(u32)) orelse return null;
        l.place(&at, .v_rows, v_len, @sizeOf(u32)) orelse return null;
        l.place(&at, .v_weights, v_len, @sizeOf(f32)) orelse return null;
        l.place(&at, .need, dst_height, @sizeOf(u32)) orelse return null;
        l.place(&at, .keep, dst_height, @sizeOf(u32)) orelse return null;
        if (point) {
            l.place(&at, .ring, mul(l.ring_rows, l.row_stride) orelse return null, 1) orelse return null;
        } else if (fixed) {
            l.v_pairs = l.v_taps + l.v_taps % 2;
            l.place(&at, .v_fixed, mul(dst_height, l.v_pairs) orelse return null, @sizeOf(i16)) orelse return null;
            l.place(&at, .v_scale, dst_height, @sizeOf(f32)) orelse return null;
            l.place(&at, .byte_taps, l.v_pairs, @sizeOf([]const u8)) orelse return null;
            l.place(&at, .ring, mul(l.ring_rows, l.row_stride) orelse return null, 1) orelse return null;
            l.place(&at, .out, dst_row, @sizeOf(f32)) orelse return null;
        } else {
            l.place(&at, .taps, l.v_taps, @sizeOf([]const f32)) orelse return null;
            const ring = mul(mul(l.ring_rows, l.row_stride) orelse return null, @sizeOf(f32)) orelse return null;
            l.place(&at, .ring, ring, 1) orelse return null;
            l.place(&at, .out, dst_row, @sizeOf(f32)) orelse return null;
        }
        if (l.pack_format != dst_format) {
            l.place(&at, .pack, mul(dst_width, l.pack_format.bytesPerPixel()) orelse return null, 1) orelse return null;
        }
        // Room to move the parts to a 64-byte boundary.
        l.total = add(at, alignment - 1) orelse return null;
        return l;
    }

    fn place(l: *Layout, at: *usize, part: Part, len: usize, size: usize) ?void {
        const bytes = mul(len, size) orelse return null;
        l.parts.set(part, .{ at.*, len });
        const end = add(at.*, bytes) orelse return null;
        at.* = std.mem.alignForward(usize, end, alignment);
        if (at.* < end) return null;
    }

    fn slice(l: Layout, comptime T: type, work: []u8, part: Part) []T {
        const p = l.parts.get(part);
        if (p[1] == 0) return &.{};
        const base = std.mem.alignForward(usize, @intFromPtr(work.ptr), alignment) - @intFromPtr(work.ptr);
        const bytes: []align(alignment) u8 = @alignCast(work[base + p[0] ..][0 .. p[1] * @sizeOf(T)]);
        return std.mem.bytesAsSlice(T, bytes);
    }
};

fn mul(a: usize, b: usize) ?usize {
    return std.math.mul(usize, a, b) catch null;
}

fn add(a: usize, b: usize) ?usize {
    return std.math.add(usize, a, b) catch null;
}

/// The most rows the ring must hold: every row from the first that a
/// destination row still to come reads to the last pushed, which is at most
/// the last that any destination row so far reads. Windows move down with
/// the destination row, and so do the rows they read, after the edge mode,
/// unless they wrap, or reflect more than once.
fn ringRows(v: Axis, edge: Edge) i64 {
    const n: i64 = v.src;
    const first = v.window(0);
    const final = v.window(v.dst - 1);
    const whole = switch (edge) {
        .clamp, .zero => false,
        .reflect => first.lo < -n or final.hi > 2 * n - 1,
        .wrap => first.lo < 0 or final.hi > n - 1,
    };
    return if (whole) n else @min(v.taps, n);
}

/// Resizes a `sw` by `sh` image of `src` samples in `format` to `dw` by `dh`,
/// with work memory from the testing allocator, into `dst`.
pub const OrientError = error{
    /// A pixel buffer is smaller than its dimensions and stride need.
    BufferTooSmall,
    /// `dst` is not `src`'s size once oriented: the same for the first four
    /// orientations, width and height swapped for the last four.
    SizeMismatch,
    /// `dst` and `src` are in different pixel formats.
    FormatMismatch,
};

/// Writes `src` into `dst` turned and flipped as `orientation` says, so
/// that an image whose metadata reports `orientation` (`Metadata.orientation`)
/// comes out upright: its first row and column go where `orientation`
/// names, and `.top_left` copies. For `.left_top` to `.left_bottom`, which
/// swap the axes, `dst` is `src`'s height wide and its width tall. Both are
/// in the same pixel format, and they must not overlap.
pub fn orient(dst: PixelBuffer, src: PixelBuffer, orientation: Orientation) OrientError!void {
    try dst.check();
    try src.check();
    if (dst.format != src.format) return error.FormatMismatch;
    const swap = @backingInt(orientation) >= @backingInt(Orientation.left_top);
    const w = if (swap) src.height else src.width;
    const h = if (swap) src.width else src.height;
    if (dst.width != w or dst.height != h) return error.SizeMismatch;
    switch (src.format.bytesPerPixel()) {
        inline 1, 2, 3, 4, 6, 8, 12, 16 => |bpp| orientPixels(bpp, dst, src, orientation),
        else => unreachable,
    }
}

fn orientPixels(comptime bpp: usize, dst: PixelBuffer, src: PixelBuffer, orientation: Orientation) void {
    const sw: usize = src.width;
    const sh: usize = src.height;
    switch (orientation) {
        .top_left, .top_right, .bottom_right, .bottom_left => {
            const mirror = orientation == .top_right or orientation == .bottom_right;
            const flip = orientation == .bottom_right or orientation == .bottom_left;
            for (0..sh) |y| {
                const from = src.row(@intCast(y));
                const to = dst.row(@intCast(if (flip) sh - 1 - y else y));
                if (!mirror) {
                    @memcpy(to, from);
                    continue;
                }
                for (0..sw) |x| to[(sw - 1 - x) * bpp ..][0..bpp].* = from[x * bpp ..][0..bpp].*;
            }
        },
        .left_top, .right_top, .right_bottom, .left_bottom => {
            // Destination pixel (x, y) is source pixel (y, x), each counted
            // from the far end where the orientation says, in tiles, so
            // that reading down a source column stays in cache.
            const from_right = orientation == .right_bottom or orientation == .left_bottom;
            const from_bottom = orientation == .right_top or orientation == .right_bottom;
            const tile = 32;
            var ty: usize = 0;
            while (ty < sw) : (ty += tile) {
                var tx: usize = 0;
                while (tx < sh) : (tx += tile) {
                    for (ty..@min(ty + tile, sw)) |y| {
                        const to = dst.row(@intCast(y));
                        const sx = if (from_right) sw - 1 - y else y;
                        for (tx..@min(tx + tile, sh)) |x| {
                            const sy = if (from_bottom) sh - 1 - x else x;
                            to[x * bpp ..][0..bpp].* = src.row(@intCast(sy))[sx * bpp ..][0..bpp].*;
                        }
                    }
                }
            }
        },
    }
}

fn testResize(
    dst: []u8,
    dst_format: PixelFormat,
    dw: u32,
    dh: u32,
    src: []const u8,
    format: PixelFormat,
    sw: u32,
    sh: u32,
    options: Options,
) !void {
    const work = try testing.allocator.alloc(u8, workLen(dst_format, dw, dh, format, sw, sh, options).?);
    defer testing.allocator.free(work);
    try resize(
        try .init(dst, dst_format, dw, dh),
        try .init(@constCast(src), format, sw, sh),
        work,
        options,
    );
}

test "one row against stb_image_resize2" {
    // Float rows through stb_image_resize2 2.18's extended API, one row
    // high, five digits: each filter shrinking and growing a ramp, and
    // each edge mode on a step. Reflect differs from stb's on the left,
    // which mirrors about the edge pixel's center there.
    const Case = struct { filter: Filter, edge: Edge = .clamp, src: []const f32, want: []const f32 };
    const ramp8 = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const ramp4 = [_]f32{ 0, 1, 2, 3 };
    const step = [_]f32{ 1, 0, 0, 0, 0, 0, 0, 0 };
    const last = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 1 };
    const cases = [_]Case{
        .{ .filter = .default, .src = &ramp8, .want = &.{ 0.58247, 2.49262, 4.50738, 6.41753 } },
        .{ .filter = .box, .src = &ramp8, .want = &.{ 0.87500, 3.50000, 6.12500 } },
        .{ .filter = .triangle, .src = &ramp8, .want = &.{ 0.97674, 3.50000, 6.02326 } },
        .{ .filter = .b_spline, .src = &ramp8, .want = &.{ 1.10570, 3.50000, 5.89430 } },
        .{ .filter = .catmull_rom, .src = &ramp8, .want = &.{ 0.83107, 3.50000, 6.16893 } },
        .{
            .filter = .default,
            .src = &ramp4,
            .want = &.{ -0.07031, 0.17969, 0.72656, 1.25000, 1.75000, 2.27344, 2.82031, 3.07031 },
        },
        .{ .filter = .box, .src = &ramp4, .want = &.{ 0, 0, 1, 1, 2, 2, 3, 3 } },
        .{ .filter = .triangle, .src = &ramp4, .want = &.{ 0, 0.25, 0.75, 1.25, 1.75, 2.25, 2.75, 3 } },
        .{
            .filter = .mitchell,
            .src = &ramp4,
            .want = &.{ -0.02344, 0.22656, 0.73524, 1.25000, 1.75000, 2.26476, 2.77344, 3.02344 },
        },
        .{ .filter = .mitchell, .edge = .wrap, .src = &step, .want = &.{ 0.39106, -0.01172, -0.00738, 0.12804 } },
        .{
            .filter = .catmull_rom,
            .edge = .zero,
            .src = &step,
            .want = &.{ 0.86719, 0.86719, 0.22656, -0.07031, -0.02344, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .filter = .catmull_rom,
            .edge = .reflect,
            .src = &last,
            .want = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -0.02344, -0.07031, 0.20312, 0.79688, 1.09375 },
        },
        .{
            .filter = .catmull_rom,
            .src = &last,
            .want = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -0.02344, -0.07031, 0.20312, 0.79688, 1.07031 },
        },
    };
    for (cases) |c| {
        var got: [16]f32 = undefined;
        const dw: u32 = @intCast(c.want.len);
        const sw: u32 = @intCast(c.src.len);
        const options: Options = .{ .filter = c.filter, .edge = c.edge };
        const src = std.mem.sliceAsBytes(c.src);
        try testResize(std.mem.sliceAsBytes(got[0..dw]), .gray_f32, dw, 1, src, .gray_f32, sw, 1, options);
        for (c.want, got[0..dw]) |w, g| try testing.expectApproxEqAbs(w, g, 1e-4);
    }
}

test "flat images stay flat, and the same size is a copy" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var src: [13 * 7 * 8]u8 = undefined;
    var dst: [29 * 3 * 8]u8 = undefined;
    for (std.enums.values(Filter)) |filter| {
        for ([_]Edge{ .clamp, .reflect, .wrap }) |edge| {
            for ([_]PixelFormat{ .gray8, .rgba8, .bgra8_premul, .rgb16 }) |format| {
                const bpp = format.bytesPerPixel();
                // Opaque, or alpha premultiplying would change the color.
                random.bytes(src[0..bpp]);
                if (format.hasAlpha()) src[3] = 255;
                for (1..13 * 7) |p| @memcpy(src[p * bpp ..][0..bpp], src[0..bpp]);
                for ([_][2]u32{ .{ 29, 3 }, .{ 2, 5 }, .{ 13, 1 } }) |size| {
                    const n = size[0] * size[1];
                    const options: Options = .{ .filter = filter, .edge = edge };
                    const flat = src[0 .. 13 * 7 * bpp];
                    try testResize(dst[0 .. n * bpp], format, size[0], size[1], flat, format, 13, 7, options);
                    for (0..n) |p| try testing.expectEqualSlices(u8, src[0..bpp], dst[p * bpp ..][0..bpp]);
                }
            }
        }
    }
    // Interpolating filters at the same size copy every pixel.
    random.bytes(&src);
    for ([_]Filter{ .default, .point, .box, .triangle, .catmull_rom, .lanczos3 }) |filter| {
        const pixels = 13 * 7 * 4;
        const options: Options = .{ .filter = filter };
        try testResize(dst[0..pixels], .rgba8_premul, 13, 7, src[0..pixels], .rgba8_premul, 13, 7, options);
        try testing.expectEqualSlices(u8, src[0 .. 13 * 7 * 4], dst[0 .. 13 * 7 * 4]);
    }
}

test "straight alpha is filtered premultiplied" {
    // Opaque blue beside transparent red: halving keeps blue, at half
    // alpha, where filtering the stored values would give purple.
    const src: [16]u8 = std.simd.repeat(16, [_]u8{ 0, 0, 255, 255, 255, 0, 0, 0 });
    var dst: [4]u8 = undefined;
    try testResize(&dst, .rgba8, 1, 1, &src, .rgba8, 2, 2, .{ .filter = .box });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, &dst);
    // Written premultiplied, and in another layout through the converter.
    try testResize(&dst, .bgra8_premul, 1, 1, &src, .rgba8, 2, 2, .{ .filter = .box });
    try testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, &dst);
    var gray: [1]u8 = undefined;
    try testResize(&gray, .gray8, 1, 1, &src, .rgba8, 2, 2, .{ .filter = .box });
    try testing.expectEqual(29, gray[0]);
}

test "sRGB filters in linear light" {
    // Black and white average to 0.5 in linear light, sRGB 188, not 128.
    const src = [_]u8{ 0, 255 };
    var dst: [1]u8 = undefined;
    try testResize(&dst, .gray8, 1, 1, &src, .gray8, 2, 1, .{ .filter = .box, .colorspace = .srgb });
    try testing.expectEqual(188, dst[0]);
    try testResize(&dst, .gray8, 1, 1, &src, .gray8, 2, 1, .{ .filter = .box });
    try testing.expectEqual(128, dst[0]);
    // Every code survives the round trip.
    var all: [256]u8 = undefined;
    for (&all, 0..) |*v, i| v.* = @intCast(i);
    var out: [256]u8 = undefined;
    try testResize(&out, .gray8, 256, 1, &all, .gray8, 256, 1, .{ .colorspace = .srgb });
    try testing.expectEqualSlices(u8, &all, &out);
    for (0..256) |i| try testing.expectEqual(i, srgbEncode8(srgb_decode8[i]));
}

test "Resizer streams rows" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var src: [9 * 40]u8 = undefined;
    random.bytes(&src);
    var want: [5 * 7]u8 = undefined;
    var got: [5 * 7]u8 = undefined;
    for (std.enums.values(Edge)) |edge| {
        for ([_][2]u32{ .{ 7, 40 }, .{ 7, 3 } }) |size| {
            const options: Options = .{ .filter = .lanczos3, .edge = edge };
            const sh = size[1];
            try testResize(&want, .gray8, 5, size[0], src[0 .. 9 * sh], .gray8, 9, sh, options);
            const work = try testing.allocator.alloc(u8, workLen(.gray8, 5, 7, .gray8, 9, sh, options).?);
            defer testing.allocator.free(work);
            var r: Resizer = try .init(.gray8, 5, 7, .gray8, 9, sh, options, work);
            var y: u32 = 0;
            for (0..sh) |sy| {
                try r.push(src[9 * sy ..][0..9]);
                if (y < 7 and r.take(got[5 * y ..][0..5])) {
                    y += 1;
                    // Another ready row must be taken before the next push.
                    if (y < 7 and r.need[y] <= r.pushed and sy + 1 < sh) {
                        try testing.expectError(error.RowReady, r.push(src[9 * (sy + 1) ..][0..9]));
                    }
                    while (y < 7 and r.take(got[5 * y ..][0..5])) y += 1;
                }
            }
            try testing.expectEqual(7, y);
            try testing.expectError(error.TooManyRows, r.push(src[0..9]));
            try testing.expectEqualSlices(u8, &want, &got);
        }
    }
}

test "work memory" {
    // A ring of every row (wrapping) of the widest rows.
    const max = std.math.maxInt(u32);
    try testing.expectEqual(null, workLen(.rgba_f32, max, 2, .rgba_f32, 2, max, .{ .edge = .wrap }));
    try testing.expectEqual(0, workLen(.gray8, 0, 5, .gray8, 3, 3, .{}));
    const need = workLen(.gray8, 3, 3, .rgba8, 50, 50, .{}).?;
    var work: [16384]u8 = undefined;
    var src: [50 * 50 * 4]u8 = @splat(0);
    var dst: [9]u8 = undefined;
    const s: PixelBuffer = try .init(&src, .rgba8, 50, 50);
    const d: PixelBuffer = try .init(&dst, .gray8, 3, 3);
    try testing.expectError(error.WorkTooSmall, resize(d, s, work[0 .. need - 1], .{}));
    // Any alignment.
    try resize(d, s, work[1..][0..need], .{});
    try testing.expectError(error.EmptySource, resize(d, try .init(&src, .rgba8, 0, 50), &work, .{}));
}

test "orient applies each EXIF orientation" {
    // A 3 by 2 image, 1 2 3 over 4 5 6, and how each orientation shows it
    // upright: row 0 goes where the orientation's first word says, column
    // 0 where its second says (EXIF 2.3, Orientation).
    const src_pixels = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const src = try PixelBuffer.init(@constCast(&src_pixels), .gray8, 3, 2);
    const cases = [_]struct { Orientation, []const u8 }{
        .{ .top_left, &.{ 1, 2, 3, 4, 5, 6 } },
        .{ .top_right, &.{ 3, 2, 1, 6, 5, 4 } },
        .{ .bottom_right, &.{ 6, 5, 4, 3, 2, 1 } },
        .{ .bottom_left, &.{ 4, 5, 6, 1, 2, 3 } },
        .{ .left_top, &.{ 1, 4, 2, 5, 3, 6 } },
        .{ .right_top, &.{ 4, 1, 5, 2, 6, 3 } },
        .{ .right_bottom, &.{ 6, 3, 5, 2, 4, 1 } },
        .{ .left_bottom, &.{ 3, 6, 2, 5, 1, 4 } },
    };
    for (cases) |c| {
        var out: [6]u8 = undefined;
        const swap = @backingInt(c[0]) >= @backingInt(Orientation.left_top);
        const dst = try PixelBuffer.init(&out, .gray8, if (swap) 2 else 3, if (swap) 3 else 2);
        try orient(dst, src, c[0]);
        try testing.expectEqualSlices(u8, c[1], &out);
    }
}

test "orient moves whole pixels, strided, and checks its buffers" {
    // RGB pixels 0 to 69 in a 7 by 10 image whose rows have room for 9,
    // turned a quarter clockwise into 10 by 7, past the tile size in
    // neither direction but crossing the stride; four turns are the start.
    var a: [10 * 9 * 3]u8 = undefined;
    for (&a, 0..) |*v, i| v.* = @intCast(i / 3 % 9 + i / (9 * 3) * 7);
    const src = try PixelBuffer.initStride(&a, .rgb8, 7, 10, 9 * 3);
    var b: [7 * 10 * 3]u8 = undefined;
    var c: [10 * 7 * 3]u8 = undefined;
    const turned = try PixelBuffer.init(&b, .rgb8, 10, 7);
    const back = try PixelBuffer.init(&c, .rgb8, 7, 10);
    try orient(turned, src, .right_top);
    // The source's bottom-left pixel is the top-left one, upright.
    try testing.expectEqualSlices(u8, src.row(9)[0..3], turned.row(0)[0..3]);
    try orient(back, turned, .left_bottom);
    for (0..10) |y| try testing.expectEqualSlices(u8, src.row(@intCast(y)), back.row(@intCast(y)));

    try testing.expectError(error.SizeMismatch, orient(back, src, .right_top));
    try testing.expectError(error.FormatMismatch, orient(try .init(&c, .bgr8, 10, 7), src, .right_top));
    try testing.expectError(error.BufferTooSmall, orient(try .initStride(&c, .rgb8, 10, 7, 30), .{
        .pixels = a[0..10],
        .format = .rgb8,
        .width = 7,
        .height = 10,
        .stride = 27,
    }, .right_top));
}
