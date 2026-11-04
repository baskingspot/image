//! The PNG and APNG encoder (the PNG specification, third edition). It
//! writes the smallest color type and bit depth that hold the pixels
//! exactly (reduce.zig), filters each row (forward.zig), and compresses the
//! rows with `compress`'s zlib writer, whose output becomes IDAT (or fdAT)
//! chunks as it is written. src/encode.zig has the contract; nothing is
//! allocated, and the work memory is the zlib writer's state and window,
//! a chunk buffer, and a few rows, so nothing scales with the height.
//!
//! - The file decodes to the source converted by `image.convert` to the
//!   base format: the source's channels, straight, at 8 bits for 8-bit
//!   sources and 16 bits otherwise (8 with `EncodeOptions.max_depth`
//!   `.@"8"`, each row converted as it is read). Alpha that is everywhere opaque is
//!   dropped, never composited. Colors under transparent pixels are kept.
//! - Rows are not interlaced. Palette and sub-byte images are not filtered,
//!   as section 12.7 suggests; the rest take `EncodeOptions.filter`, or the
//!   effort's choice.
//! - An APNG (`encodeAnimation`) stores its first frame as the default
//!   image, so it must cover the canvas, and every frame shares the color
//!   type, depth, and palette the survey of all frames picks.
//! - gAMA, cHRM, sRGB, iCCP, cICP, mDCV, cLLI, pHYs, and eXIf are written
//!   when the options carry them, before PLTE and the image data.
//! - The bytes written depend only on the pixels, the options, and the
//!   work memory's length, never on what the work memory held: encoding
//!   twice over the same memory, once to measure (`Io.Writer.Discarding`)
//!   and once to write, gives the same file, as ICO's PNG entries need.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zlib = @import("compress").zlib;

const shared = @import("../encode.zig");
const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const crc32 = @import("crc32.zig");
const forward = @import("forward.zig");
const reduce = @import("reduce.zig");

pub const Filter = forward.Filter;

/// How hard the encoder works to make the file small. Every effort
/// chooses each row's filter by the least sum of magnitudes.
pub const Effort = enum {
    /// Greedy deflate (zlib level 6).
    fast,
    /// Lazy deflate with a short search, tuned for filtered rows.
    default,
    /// Lazy deflate with a long search: the smallest file, the slowest.
    best,
};

/// sRGB's rendering intent.
pub const RenderingIntent = enum(u8) {
    perceptual = 0,
    relative_colorimetric = 1,
    saturation = 2,
    absolute_colorimetric = 3,
};

/// An ICC profile for iCCP: the profile as it is (the encoder compresses
/// it) and its name.
pub const Icc = struct {
    /// 1 to 79 Latin-1 characters, no leading, trailing, or doubled spaces.
    name: []const u8 = "ICC profile",
    profile: []const u8,
};

pub const MaxDepth = enum { @"8", @"16" };

pub const EncodeOptions = struct {
    effort: Effort = .default,
    /// One filter for every row that is filtered, instead of the effort's.
    filter: ?Filter = null,
    /// Write the smallest color type and bit depth that hold the pixels
    /// exactly; otherwise the base format's.
    reduce: bool = true,
    /// The most bits a sample may have: `.@"8"` stores 16-bit and float
    /// sources at 8 bits, converting each row as it is read (no more work
    /// memory), and reduction still picks the smallest type that holds
    /// those 8-bit samples. ICO's PNG entries use it.
    max_depth: MaxDepth = .@"16",
    /// gAMA: the image's gamma times 100,000.
    gamma: ?u32 = null,
    /// cHRM: red, green, blue, and white xy, as `Metadata.primaries`
    /// reports them, each stored times 100,000, rounded.
    primaries: ?[8]f32 = null,
    /// sRGB; not with `icc`.
    srgb: ?RenderingIntent = null,
    /// iCCP; not with `srgb`.
    icc: ?Icc = null,
    /// cICP: ITU-T H.273 code points, as `Metadata.cicp` reports them;
    /// the matrix must be 0. Readers that know it ignore iCCP, sRGB,
    /// gAMA, and cHRM.
    cicp: ?decode.Metadata.Cicp = null,
    /// mDCV: chromaticities stored times 50,000 and luminances times
    /// 10,000, rounded.
    mastering_display: ?decode.Metadata.MasteringDisplay = null,
    /// cLLI: light levels stored times 10,000, rounded.
    content_light_level: ?decode.Metadata.ContentLightLevel = null,
    /// eXIf: an EXIF profile, starting with its TIFF header.
    exif: ?[]const u8 = null,
    /// pHYs: pixels per meter, or only the aspect ratio with `.none`. Pixels
    /// per inch are stored per meter, rounded to the nearest.
    density: ?decode.Density = null,
    /// An APNG's play count: 0 plays forever.
    loop_count: u32 = 0,
};

pub const EncodeError = shared.Error || error{
    /// PNG cannot store an image without rows or columns.
    EmptyImage,
    /// An APNG with no frames, a frame outside the canvas, or a first
    /// frame that is not the whole canvas.
    BadFrame,
    /// A metadata option PNG cannot store: a gamma or density of 0, a value
    /// past 2^31 - 1 (for `primaries`, once times 100,000; for luminances
    /// and light levels, once times 10,000), a negative or NaN value, an
    /// HDR chromaticity past 1.3107, a cICP matrix other than 0, a bad
    /// profile name, both `srgb` and `icc`, or a chunk longer than
    /// 2^31 - 1 bytes.
    BadMetadata,
};

/// One frame of an APNG.
pub const AnimationFrame = struct {
    /// The frame's pixels, in any format, the size of its region.
    pixels: PixelBuffer,
    /// The region's top left corner on the canvas.
    x: u32 = 0,
    y: u32 = 0,
    /// How long to show the frame, in flicks (`image.flicks_per_second`);
    /// stored exactly when it is a fraction of a second with a numerator
    /// and denominator below 65536, and as the nearest such fraction
    /// otherwise.
    duration: u64 = 0,
    disposal: decode.Frame.Disposal = .none,
    blend: decode.Frame.Blend = .src,
};

/// PNG's largest width or height.
const max_side = std.math.maxInt(i32);
/// The image data chunks' buffer: data the zlib writer writes in pieces
/// smaller than this is gathered into a chunk this long.
const chunk_len = 16 * 1024;

/// The work memory's fixed part.
const Work = struct {
    zw: zlib.Writer,
    window: zlib.Writer.Buffer,
    chunk: [chunk_len]u8,
    palette: reduce.Palette,
};

/// The widest pixel any source converts to: 16-bit RGBA.
const max_bpp = 8;

/// The work memory `encode` and `encodeAnimation` need for a `width` by
/// `height` canvas, or null when PNG cannot store it.
pub fn workLen(options: EncodeOptions, width: u32, height: u32) ?usize {
    if (width > max_side or height > max_side) return null;
    const row = std.math.mul(usize, width, max_bpp) catch return null;
    // A base row, the zero row, the current and previous file rows, and a
    // filtered row for each candidate.
    const rows: usize = 4 + @as(usize, if (searches(options)) 5 else 1);
    const all = std.math.mul(usize, row, rows) catch return null;
    return std.math.add(usize, @sizeOf(Work) + @alignOf(Work) - 1, all) catch null;
}

fn searches(options: EncodeOptions) bool {
    return options.filter == null;
}

fn zlibOptions(effort: Effort) zlib.encode.Options {
    return switch (effort) {
        .fast => .{ .level = .@"6", .dict = null, .strategy = .default },
        .default => .{ .level = .@"7", .dict = null, .strategy = .filtered },
        .best => .{ .level = .@"9", .dict = null, .strategy = .filtered },
    };
}

/// Starts a zlib stream in the work memory's writer. Assigning a new
/// writer copies all of it, about 400 KiB, which is most of an icon's
/// encode; `initInPlace` writes it in place.
fn startZlib(fixed: *Work, out: *Io.Writer, options: zlib.encode.Options) void {
    fixed.zw.initInPlace(out, &fixed.window, options);
}

/// Writes `src` as a PNG file. The bytes depend only on `src`'s pixels,
/// `options`, and `work.len`, not on what `work` held before.
pub fn encode(w: *Io.Writer, src: PixelBuffer, options: EncodeOptions, work: []u8) EncodeError!void {
    const frame: AnimationFrame = .{ .pixels = src };
    return write(w, src.width, src.height, (&frame)[0..1], false, options, work);
}

/// Writes `frames` as an APNG on a `width` by `height` canvas. The first
/// frame is also the default image, so it must be the whole canvas. As
/// with `encode`, the bytes do not depend on what `work` held before.
pub fn encodeAnimation(
    w: *Io.Writer,
    width: u32,
    height: u32,
    frames: []const AnimationFrame,
    options: EncodeOptions,
    work: []u8,
) EncodeError!void {
    return write(w, width, height, frames, true, options, work);
}

fn write(
    w: *Io.Writer,
    width: u32,
    height: u32,
    frames: []const AnimationFrame,
    animated: bool,
    options: EncodeOptions,
    work: []u8,
) EncodeError!void {
    for (frames) |f| try f.pixels.check();
    if (width == 0 or height == 0) return error.EmptyImage;
    const need = workLen(options, width, height) orelse return error.ImageTooLarge;
    if (work.len < need) return error.WorkTooSmall;
    if (frames.len == 0 or frames.len > max_side) return error.BadFrame;
    for (frames, 0..) |f, i| {
        const p = f.pixels;
        if (p.width == 0 or p.height == 0) return error.BadFrame;
        if (@as(u64, f.x) + p.width > width or @as(u64, f.y) + p.height > height) return error.BadFrame;
        if (i == 0 and (f.x != 0 or f.y != 0 or p.width != width or p.height != height)) return error.BadFrame;
    }
    try checkMetadata(options);

    const at = std.mem.alignForward(usize, @intFromPtr(work.ptr), @alignOf(Work)) - @intFromPtr(work.ptr);
    const fixed: *Work = @ptrCast(@alignCast(work[at..][0..@sizeOf(Work)]));
    var rest = work[at + @sizeOf(Work) ..];
    const row_len = @as(usize, width) * max_bpp;
    var rows: Rows = undefined;
    inline for (.{ "base", "zero", "cur", "prev" }) |name| {
        @field(rows, name) = rest[0..row_len];
        rest = rest[row_len..];
    }
    for (&rows.outs, 0..) |*o, i| {
        if (i > 0 and !searches(options)) {
            o.* = rows.outs[0];
            continue;
        }
        o.* = rest[0..row_len];
        rest = rest[row_len..];
    }

    const plan = makePlan(frames, options, rows.base, &fixed.palette);

    // Signature, header, and the chunks before the image data.
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = plan.depth;
    ihdr[9] = @backingInt(plan.color);
    ihdr[10..13].* = .{ 0, 0, 0 };
    try writeChunk(w, "IHDR", &ihdr);
    try writeMetadata(w, options, fixed);
    if (plan.color == .palette) {
        const pal = plan.palette;
        var plte: [256 * 3]u8 = undefined;
        for (pal.colors[0..pal.len], 0..) |c, i| plte[i * 3 ..][0..3].* = c[0..3].*;
        try writeChunk(w, "PLTE", plte[0 .. pal.len * 3]);
        if (pal.trns_len > 0) {
            var trns: [256]u8 = undefined;
            for (pal.colors[0..pal.trns_len], 0..) |c, i| trns[i] = c[3];
            try writeChunk(w, "tRNS", trns[0..pal.trns_len]);
        }
    } else if (plan.key) |k| {
        var trns: [6]u8 = undefined;
        for (k, 0..) |v, i| std.mem.writeInt(u16, trns[i * 2 ..][0..2], v, .big);
        try writeChunk(w, "tRNS", trns[0..if (plan.color == .gray) 2 else 6]);
    }

    var seq: u32 = 0;
    if (animated) {
        var actl: [8]u8 = undefined;
        std.mem.writeInt(u32, actl[0..4], @intCast(frames.len), .big);
        std.mem.writeInt(u32, actl[4..8], options.loop_count, .big);
        try writeChunk(w, "acTL", &actl);
    }
    for (frames, 0..) |f, i| {
        if (animated) {
            var fctl: [26]u8 = undefined;
            std.mem.writeInt(u32, fctl[0..4], seq, .big);
            seq += 1;
            std.mem.writeInt(u32, fctl[4..8], f.pixels.width, .big);
            std.mem.writeInt(u32, fctl[8..12], f.pixels.height, .big);
            std.mem.writeInt(u32, fctl[12..16], f.x, .big);
            std.mem.writeInt(u32, fctl[16..20], f.y, .big);
            const d = delay(f.duration);
            std.mem.writeInt(u16, fctl[20..22], d[0], .big);
            std.mem.writeInt(u16, fctl[22..24], d[1], .big);
            fctl[24] = @backingInt(f.disposal);
            fctl[25] = @backingInt(f.blend);
            try writeChunk(w, "fcTL", &fctl);
        }
        var chunks: Chunks = .init(w, fixed.chunk[0..], if (i == 0) "IDAT" else "fdAT", if (i == 0) null else &seq);
        try writeImage(&chunks.writer, f.pixels, plan, options, fixed, &rows);
        try chunks.end();
    }
    try writeChunk(w, "IEND", "");
}

/// The work memory's rows, each a 16-bit RGBA row of the canvas long.
const Rows = struct {
    /// A source row converted to the base format.
    base: []u8,
    /// Zeros: the row above the first.
    zero: []u8,
    /// The current and previous rows of the file's samples.
    cur: []u8,
    prev: []u8,
    /// The filtered rows, one per filter when the filter is searched for
    /// (otherwise they are all the same memory).
    outs: [5][]u8,
};

fn makePlan(frames: []const AnimationFrame, options: EncodeOptions, row: []u8, palette: *reduce.Palette) reduce.Plan {
    var base = reduce.baseOf(frames[0].pixels.format);
    var float = false;
    for (frames) |f| {
        base = reduce.baseOfAll(&[_]PixelFormat{ base, f.pixels.format });
        float = float or f.pixels.format.sample() == .f32;
    }
    if (options.max_depth == .@"8") base = switch (base) {
        .gray16 => .gray8,
        .gray_alpha16 => .gray_alpha8,
        .rgb16 => .rgb8,
        .rgba16 => .rgba8,
        else => base,
    };
    if (!options.reduce) {
        const color: reduce.ColorType = switch (base) {
            .gray8, .gray16 => .gray,
            .gray_alpha8, .gray_alpha16 => .gray_alpha,
            .rgb8, .rgb16 => .rgb,
            else => .rgba,
        };
        return .{ .color = color, .depth = @intCast(8 * base.bytesPerSample()), .base = base };
    }
    var s: reduce.Survey = .init(base, float, palette);
    for (frames) |f| s.add(f.pixels, row);
    if (s.plan(null)) |p| return p;
    const clear = for (frames) |f| {
        if (!reduce.keyClear(base, s.key.?, f.pixels, row)) break false;
    } else true;
    return s.plan(clear).?;
}

/// Filters and compresses one frame's rows into `out`, a zlib stream.
fn writeImage(
    out: *Io.Writer,
    src: PixelBuffer,
    plan: reduce.Plan,
    options: EncodeOptions,
    fixed: *Work,
    rows: *const Rows,
) EncodeError!void {
    startZlib(fixed, out, zlibOptions(options.effort));
    const z = &fixed.zw.writer;
    const width: usize = src.width;
    const len = plan.rowBytes(src.width);
    const bpp = plan.filterBpp();
    const conv: Converter = .init(plan.base, src.format);
    const layout = plan.sameLayout();
    const direct = layout and src.format == plan.base and plan.depth == 8;
    const unfiltered = plan.color == .palette or plan.depth < 8;
    const fixed_filter: ?Filter = if (unfiltered) .none else options.filter;
    @memset(rows.zero[0..len], 0);
    var prev: []const u8 = rows.zero[0..len];
    const bufs: [2][]u8 = .{ rows.cur[0..len], rows.prev[0..len] };
    for (0..src.height) |y| {
        const raw = src.row(@intCast(y));
        const buf = bufs[y & 1];
        const cur: []const u8 = blk: {
            if (direct) break :blk raw;
            if (layout and plan.depth == 8) {
                conv.run(buf, raw, width);
                break :blk buf;
            }
            var b = raw;
            if (src.format != plan.base) {
                conv.run(rows.base, raw, width);
                b = rows.base[0 .. width * plan.base.bytesPerPixel()];
            }
            plan.pack(buf, b, width);
            break :blk buf;
        };
        var filter: Filter = undefined;
        var filtered: []const u8 = undefined;
        if (fixed_filter) |f| {
            filter = f;
            filtered = cur;
            if (f != .none) {
                _ = forward.apply(f, rows.outs[0][0..len], cur, prev, bpp, false);
                filtered = rows.outs[0][0..len];
            }
        } else {
            var outs: [5][]u8 = undefined;
            for (&outs, rows.outs) |*o, r| o.* = r[0..len];
            filter = forward.choose(&outs, cur, prev, bpp);
            filtered = outs[@backingInt(filter)];
        }
        try z.writeByte(@backingInt(filter));
        try z.writeAll(filtered);
        prev = cur;
    }
    try fixed.zw.finish();
}

/// An `Io.Writer` that writes what it is given as PNG chunks of one type,
/// gathering small writes in its buffer: IDAT, or fdAT with a sequence
/// number first. Flushing does nothing, so that the zlib trailer, which
/// follows a flush, shares the last chunk; `end` writes what is left.
const Chunks = struct {
    writer: Io.Writer,
    out: *Io.Writer,
    kind: *const [4]u8,
    seq: ?*u32,

    fn init(out: *Io.Writer, buffer: []u8, kind: *const [4]u8, seq: ?*u32) Chunks {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain, .flush = keep }, .buffer = buffer },
            .out = out,
            .kind = kind,
            .seq = seq,
        };
    }

    fn keep(_: *Io.Writer) Io.Writer.Error!void {}

    /// Writes the buffered bytes as the last chunk.
    fn end(c: *Chunks) Io.Writer.Error!void {
        _ = try drain(&c.writer, &.{""}, 1);
    }

    /// One chunk of the buffered bytes and all of `data`.
    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const c: *Chunks = @fieldParentPtr("writer", io_w);
        const buffered = io_w.buffer[0..io_w.end];
        var len: usize = buffered.len;
        for (data[0 .. data.len - 1]) |d| len += d.len;
        const last = data[data.len - 1];
        len += last.len * splat;
        const taken = len - buffered.len;
        if (len == 0) return 0;
        var head: [12]u8 = undefined;
        var head_len: usize = 8;
        const seq_len: usize = if (c.seq != null) 4 else 0;
        if (len + seq_len > max_side) return error.WriteFailed;
        std.mem.writeInt(u32, head[0..4], @intCast(len + seq_len), .big);
        head[4..8].* = c.kind.*;
        if (c.seq) |s| {
            std.mem.writeInt(u32, head[8..12], s.*, .big);
            s.* += 1;
            head_len = 12;
        }
        var crc = crc32.update(crc32.init, head[4..head_len]);
        try c.out.writeAll(head[0..head_len]);
        crc = crc32.update(crc, buffered);
        try c.out.writeAll(buffered);
        for (data[0 .. data.len - 1]) |d| {
            crc = crc32.update(crc, d);
            try c.out.writeAll(d);
        }
        for (0..splat) |_| {
            crc = crc32.update(crc, last);
            try c.out.writeAll(last);
        }
        var tail: [4]u8 = undefined;
        std.mem.writeInt(u32, &tail, ~crc, .big);
        try c.out.writeAll(&tail);
        io_w.end = 0;
        return taken;
    }
};

fn writeChunk(w: *Io.Writer, kind: *const [4]u8, data: []const u8) Io.Writer.Error!void {
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(data.len), .big);
    head[4..8].* = kind.*;
    try w.writeAll(&head);
    try w.writeAll(data);
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, &tail, ~crc32.update(crc32.update(crc32.init, kind), data), .big);
    try w.writeAll(&tail);
}

fn checkMetadata(o: EncodeOptions) EncodeError!void {
    const max = max_side;
    if (o.gamma) |g| if (g == 0 or g > max) return error.BadMetadata;
    if (o.primaries) |p| _ = chrm(p) orelse return error.BadMetadata;
    if (o.srgb != null and o.icc != null) return error.BadMetadata;
    if (o.icc) |icc| {
        const n = icc.name;
        if (n.len < 1 or n.len > 79 or n[0] == ' ' or n[n.len - 1] == ' ') return error.BadMetadata;
        for (n, 0..) |ch, i| {
            if (ch < 32 or (ch > 126 and ch < 161)) return error.BadMetadata;
            if (ch == ' ' and n[i - 1] == ' ') return error.BadMetadata;
        }
        // The compressed profile's bound must fit a chunk.
        if (zlib.encode.maxCompressedLength(icc.profile.len) + n.len + 2 > max) return error.BadMetadata;
    }
    if (o.exif) |e| if (e.len > max) return error.BadMetadata;
    if (o.cicp) |c| if (c.matrix != 0) return error.BadMetadata;
    if (o.mastering_display) |m| _ = mdcv(m) orelse return error.BadMetadata;
    if (o.content_light_level) |c| _ = clli(c) orelse return error.BadMetadata;
    if (o.density) |density| {
        for (physDensity(density)) |v| if (v == 0 or v > max) return error.BadMetadata;
    }
}

/// `density` as pHYs stores it: per meter, or unitless.
fn physDensity(density: decode.Density) [2]u64 {
    return switch (density.unit) {
        .none, .per_meter => .{ density.x, density.y },
        // 0.0254 meters to the inch.
        .per_inch => .{
            (@as(u64, density.x) * 10000 + 127) / 254,
            (@as(u64, density.y) * 10000 + 127) / 254,
        },
    };
}

/// cHRM's eight values for `primaries`: white first, then red, green, and
/// blue, each times 100,000, rounded; null if one is negative, NaN, or past
/// what a chunk field holds.
fn chrm(primaries: [8]f32) ?[8]u32 {
    var v: [8]u32 = undefined;
    for (&v, 0..) |*x, i| {
        const f = primaries[(i + 6) % 8] * 100_000;
        if (!(f >= 0 and f < @as(f32, @floatFromInt(max_side)))) return null;
        x.* = @intFromFloat(@round(f));
    }
    return v;
}

/// `v` times `scale`, rounded, if `v` is not negative or NaN and that is
/// at most `max`.
fn stored(v: f32, scale: f64, max: u32) ?u32 {
    const r = @round(@as(f64, v) * scale);
    if (!(v >= 0 and r <= @as(f64, @floatFromInt(max)))) return null;
    return @intFromFloat(r);
}

/// mDCV's 24 bytes for `m`, or null if a value does not fit.
fn mdcv(m: decode.Metadata.MasteringDisplay) ?[24]u8 {
    var b: [24]u8 = undefined;
    for (m.primaries, 0..) |x, i| {
        std.mem.writeInt(u16, b[i * 2 ..][0..2], @intCast(stored(x, 50_000, 0xffff) orelse return null), .big);
    }
    std.mem.writeInt(u32, b[16..20], stored(m.max_luminance, 10_000, max_side) orelse return null, .big);
    std.mem.writeInt(u32, b[20..24], stored(m.min_luminance, 10_000, max_side) orelse return null, .big);
    return b;
}

/// cLLI's 8 bytes for `c`, or null if a value does not fit.
fn clli(c: decode.Metadata.ContentLightLevel) ?[8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], stored(c.max_cll, 10_000, max_side) orelse return null, .big);
    std.mem.writeInt(u32, b[4..8], stored(c.max_fall, 10_000, max_side) orelse return null, .big);
    return b;
}

/// cHRM, gAMA, sRGB, iCCP, cICP, mDCV, and cLLI, then pHYs and eXIf.
fn writeMetadata(w: *Io.Writer, o: EncodeOptions, fixed: *Work) EncodeError!void {
    if (o.primaries) |p| {
        var b: [32]u8 = undefined;
        for (chrm(p).?, 0..) |x, i| std.mem.writeInt(u32, b[i * 4 ..][0..4], x, .big);
        try writeChunk(w, "cHRM", &b);
    }
    if (o.gamma) |g| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, g, .big);
        try writeChunk(w, "gAMA", &b);
    }
    if (o.srgb) |intent| try writeChunk(w, "sRGB", &.{@backingInt(intent)});
    if (o.icc) |icc| {
        // The chunk's length is the compressed profile's: compress it once
        // to count, then again into the chunk.
        var discard: Io.Writer.Discarding = .init(&.{});
        try compressInto(&discard.writer, icc.profile, fixed);
        const len = icc.name.len + 2 + discard.fullCount();
        var head: [8]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], @intCast(len), .big);
        head[4..8].* = "iCCP".*;
        try w.writeAll(&head);
        var crc_w: CrcWriter = .{ .out = w, .crc = crc32.update(crc32.init, "iCCP") };
        try crc_w.writer.writeAll(icc.name);
        try crc_w.writer.writeAll(&.{ 0, 0 });
        try compressInto(&crc_w.writer, icc.profile, fixed);
        var tail: [4]u8 = undefined;
        std.mem.writeInt(u32, &tail, ~crc_w.crc, .big);
        try w.writeAll(&tail);
    }
    if (o.cicp) |c| try writeChunk(w, "cICP", &.{ c.primaries, c.transfer, c.matrix, @intFromBool(c.full_range) });
    if (o.mastering_display) |m| try writeChunk(w, "mDCV", &mdcv(m).?);
    if (o.content_light_level) |c| try writeChunk(w, "cLLI", &clli(c).?);
    if (o.density) |density| {
        var b: [9]u8 = undefined;
        const xy = physDensity(density);
        std.mem.writeInt(u32, b[0..4], @intCast(xy[0]), .big);
        std.mem.writeInt(u32, b[4..8], @intCast(xy[1]), .big);
        b[8] = @intFromBool(density.unit != .none);
        try writeChunk(w, "pHYs", &b);
    }
    if (o.exif) |e| try writeChunk(w, "eXIf", e);
}

fn compressInto(out: *Io.Writer, bytes: []const u8, fixed: *Work) Io.Writer.Error!void {
    startZlib(fixed, out, .{ .level = .@"6", .dict = null });
    try fixed.zw.writer.writeAll(bytes);
    try fixed.zw.finish();
}

/// An unbuffered `Io.Writer` that passes bytes on, folding them into a
/// CRC-32.
const CrcWriter = struct {
    out: *Io.Writer,
    crc: u32 = crc32.init,
    writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const c: *CrcWriter = @fieldParentPtr("writer", io_w);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            c.crc = crc32.update(c.crc, d);
            try c.out.writeAll(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            c.crc = crc32.update(c.crc, last);
            try c.out.writeAll(last);
            n += last.len;
        }
        return n;
    }
};

/// A duration in flicks as fcTL's delay fraction of a second: exact when
/// both terms fit 16 bits, and otherwise the nearest fraction that fits.
fn delay(flicks: u64) [2]u16 {
    const f: u64 = decode.flicks_per_second;
    if (flicks == 0) return .{ 0, 1 };
    const g = std.math.gcd(flicks, f);
    if (flicks / g <= 65535 and f / g <= 65535) return .{ @intCast(flicks / g), @intCast(f / g) };
    if (flicks >= 65535 * f) return .{ 65535, 1 };
    // The best approximation n/d of flicks/f with n and d at most 65535:
    // the continued fraction's convergents, and the last semiconvergent.
    const max_d: u64 = @min(65535, 65535 * f / flicks);
    var p0: u64 = 0;
    var q0: u64 = 1;
    var p1: u64 = 1;
    var q1: u64 = 0;
    var n = flicks;
    var d = f;
    while (d != 0) {
        const a = n / d;
        const q2 = q0 + a * q1;
        if (q2 > max_d) break;
        const p2 = p0 + a * p1;
        p0 = p1;
        q0 = q1;
        p1 = p2;
        q1 = q2;
        const r = n - a * d;
        n = d;
        d = r;
    }
    // The semiconvergent with the largest denominator in bounds, if it is
    // nearer than the last convergent.
    const k = (max_d - q0) / q1;
    const ps = p0 + k * p1;
    const qs = q0 + k * q1;
    const err_s = @abs(@as(i128, ps) * f - @as(i128, flicks) * qs) * q1;
    const err_c = @abs(@as(i128, p1) * f - @as(i128, flicks) * q1) * qs;
    const pick: [2]u64 = if (err_s < err_c) .{ ps, qs } else .{ p1, q1 };
    return .{ @intCast(@min(pick[0], 65535)), @intCast(@max(pick[1], 1)) };
}

const Decoder = @import("Decoder.zig");

test {
    _ = forward;
    _ = reduce;
}

fn testWork() []u8 {
    const S = struct {
        var work: [1 << 20]u8 = undefined;
    };
    return &S.work;
}

test "a still image reads back" {
    var file: [4096]u8 = undefined;
    var px: [4 * 6]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @intCast(i * 9);
    const src = try PixelBuffer.init(&px, .rgba8, 3, 2);
    var w: Io.Writer = .fixed(&file);
    try encode(&w, src, .{}, testWork());
    var r: Io.Reader = .fixed(w.buffered());
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(PixelFormat.rgba8, config.native);
    var out: [4 * 6]u8 = undefined;
    _ = (try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 3, 2), testWork())).?;
    try testing.expectEqualSlices(u8, &px, &out);
    try testing.expectEqual(null, try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 3, 2), testWork()));
}

test "max_depth 8 stores 16-bit sources at 8 bits, still reduced" {
    const convertBuffer = @import("../convert.zig").convertBuffer;
    var file: [4096]u8 = undefined;
    var px: [8 * 256]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // 256 RGBA16 pixels of three opaque colors whose low bytes are not
    // their high bytes, so only 16 bits hold them exactly; and the same of
    // random colors with alpha.
    for ([_]bool{ true, false }) |few| {
        for (0..256) |i| {
            const c: u16 = random.uintLessThan(u16, 3);
            for (0..4) |k| {
                const kk: u16 = @intCast(k);
                const color = 0x1234 +% c *% 0x3111 +% kk *% 0x0707;
                const v: u16 = if (!few) random.int(u16) else if (k == 3) 0xffff else color;
                std.mem.writeInt(u16, px[i * 8 + k * 2 ..][0..2], v, .little);
            }
        }
        const src = try PixelBuffer.init(&px, .rgba16, 16, 16);
        for ([_]MaxDepth{ .@"16", .@"8" }) |max| {
            var w: Io.Writer = .fixed(&file);
            try encode(&w, src, .{ .max_depth = max }, testWork());
            const f = w.buffered();
            // IHDR's depth and color type.
            const depth = f[24];
            const color = f[25];
            if (max == .@"16") {
                try testing.expectEqual(16, depth);
                continue;
            }
            try testing.expect(depth <= 8);
            // Three colors, opaque: a palette; random colors: RGBA.
            try testing.expectEqual(@as(u8, if (few) 3 else 6), color);
            var r: Io.Reader = .fixed(f);
            var d: Decoder = .init(&r, .{});
            _ = try d.decodeConfig();
            var out: [4 * 256]u8 = undefined;
            var want: [4 * 256]u8 = undefined;
            _ = (try d.decodeFrame(try PixelBuffer.init(&out, .rgba8, 16, 16), testWork())).?;
            try convertBuffer(try PixelBuffer.init(&want, .rgba8, 16, 16), src);
            try testing.expectEqualSlices(u8, &want, &out);
        }
    }
}

test "the bytes do not depend on what the work memory held" {
    // ICO sizes a PNG entry by encoding it into a discarding writer, then
    // encodes it again over the same work memory, so the two must agree.
    // Debug and ReleaseSafe write 0xaa over memory set to `undefined`,
    // which hides a match-finder table a stream fails to clear; only a
    // ReleaseFast build (`zig build test -Doptimize=ReleaseFast`) catches
    // that here.
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // Tiles repeated with noise, so the match finders have many candidates
    // at many distances.
    const width = 120;
    const height = 90;
    const px = try gpa.alloc(u8, 4 * width * height);
    defer gpa.free(px);
    var tile: [4 * 16]u8 = undefined;
    random.bytes(&tile);
    for (px, 0..) |*b, i| {
        const x = i / 4 % width;
        const y = i / 4 / width;
        const noise = random.uintLessThan(u8, 4) * @intFromBool(random.uintLessThan(u8, 8) == 0);
        b.* = tile[(x + 3 * y) % 16 * 4 + i % 4] +% noise;
    }
    const src = try PixelBuffer.init(px, .rgba8, width, height);
    // Another image, larger and at its own effort, to leave the work
    // memory as a real encode does.
    const other_px = try gpa.alloc(u8, 3 * 200 * 150);
    defer gpa.free(other_px);
    for (other_px, 0..) |*b, i| b.* = @truncate(i / 3 % 200 * 7 + i / 600 * 3 + random.uintLessThan(u8, 3));
    const other = try PixelBuffer.init(other_px, .rgb8, 200, 150);

    const len = workLen(.{ .effort = .best }, 200, 150).?;
    const work = try gpa.alloc(u8, len);
    defer gpa.free(work);
    const want = try gpa.alloc(u8, 1 << 18);
    defer gpa.free(want);
    const got = try gpa.alloc(u8, 1 << 18);
    defer gpa.free(got);

    const top = src.sub(0, 0, width, height / 2);
    const half: AnimationFrame = .{ .pixels = src.sub(0, 0, width / 2, height / 2), .x = 7, .y = 5 };
    for (std.enums.values(Effort)) |effort| {
        const options: EncodeOptions = .{ .effort = effort };
        for (0..2) |animated| {
            const frames = [_]AnimationFrame{ .{ .pixels = src }, half };
            @memset(work, 0);
            var w: Io.Writer = .fixed(want);
            if (animated == 1) {
                try encodeAnimation(&w, width, height, &frames, options, work);
            } else {
                try encode(&w, src, options, work);
            }
            const n = w.end;
            for (0..6) |dirt| {
                var sink: Io.Writer.Discarding = .init(&.{});
                switch (dirt) {
                    0 => @memset(work, 0xff),
                    1 => random.bytes(work),
                    2 => for (std.enums.values(Effort)) |e| {
                        try encode(&sink.writer, other, .{ .effort = e }, work);
                    },
                    // The image's top half, at each effort, leaves
                    // match-finder entries that point back at this
                    // image's own bytes, the stale state most likely to
                    // change a match if a stream did not start clean.
                    else => try encode(&sink.writer, top, .{ .effort = @fromBackingInt(@intCast(dirt - 3)) }, work),
                }
                // ICO's two passes: the length, then the bytes.
                sink = .init(&.{});
                if (animated == 1) {
                    try encodeAnimation(&sink.writer, width, height, &frames, options, work);
                } else {
                    try encode(&sink.writer, src, options, work);
                }
                try testing.expectEqual(n, sink.fullCount());
                w = .fixed(got);
                if (animated == 1) {
                    try encodeAnimation(&w, width, height, &frames, options, work);
                } else {
                    try encode(&w, src, options, work);
                }
                try testing.expectEqualSlices(u8, want[0..n], w.buffered());
            }
        }
    }
}

test "metadata chunks are written and read" {
    var file: [8192]u8 = undefined;
    var px = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const src = try PixelBuffer.init(&px, .rgb8, 2, 1);
    // Big-endian TIFF, one IFD entry: orientation (0x0112), SHORT, 6.
    const exif_data = "MM\x00\x2a\x00\x00\x00\x08" ++ "\x00\x01" ++
        "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00" ++ "\x00\x00\x00\x00";
    // sRGB's primaries and D65.
    const primaries = [8]f32{ 0.64, 0.33, 0.3, 0.6, 0.15, 0.06, 0.3127, 0.329 };
    var profile: [3000]u8 = undefined;
    for (&profile, 0..) |*b, i| b.* = @truncate(i / 7);
    var w: Io.Writer = .fixed(&file);
    try encode(&w, src, .{
        .gamma = 45455,
        .primaries = primaries,
        .icc = .{ .profile = &profile },
        .exif = exif_data,
        .density = .{ .x = 72, .y = 96, .unit = .per_inch },
    }, testWork());
    var r: Io.Reader = .fixed(w.buffered());
    var d: Decoder = .init(&r, .{});
    const m = (try d.decodeConfig()).metadata;
    try testing.expectEqual(45455, m.gamma.?);
    try testing.expectEqual(primaries, m.primaries.?);
    // Stored white first, times 100,000.
    const at = std.mem.find(u8, w.buffered(), "cHRM").? + 4;
    try testing.expectEqual(31270, std.mem.readInt(u32, w.buffered()[at..][0..4], .big));
    try testing.expectEqual(64000, std.mem.readInt(u32, w.buffered()[at + 8 ..][0..4], .big));
    // 72 and 96 per inch are 2834.6 and 3779.5 per meter.
    try testing.expectEqual(decode.Density{ .x = 2835, .y = 3780, .unit = .per_meter }, m.density.?);
    try testing.expectEqual(decode.Orientation.right_top, m.orientation);
    const icc = m.icc.?;
    try testing.expectEqual(decode.Blob.Encoding.zlib, icc.encoding);
    var inflated: [4000]u8 = undefined;
    const n = try zlib.decode.decompress(w.buffered()[icc.offset..][0..@intCast(icc.len.?)], &inflated, null);
    try testing.expectEqualSlices(u8, &profile, inflated[0..n]);
    const both: EncodeOptions = .{ .srgb = .perceptual, .icc = .{ .profile = "x" } };
    try testing.expectError(error.BadMetadata, encode(&w, src, both, testWork()));
    const spaces: EncodeOptions = .{ .icc = .{ .name = "two  spaces", .profile = "x" } };
    try testing.expectError(error.BadMetadata, encode(&w, src, spaces, testWork()));
    const zero: EncodeOptions = .{ .density = .{ .x = 0, .y = 1, .unit = .none } };
    try testing.expectError(error.BadMetadata, encode(&w, src, zero, testWork()));
    // 2^31 - 1 per meter is 54,546,084.6 per inch, which rounds down.
    w = .fixed(&file);
    try encode(&w, src, .{ .density = .{ .x = 54_546_084, .y = 1, .unit = .per_inch } }, testWork());
    const dense: EncodeOptions = .{ .density = .{ .x = 54_546_085, .y = 1, .unit = .per_inch } };
    try testing.expectError(error.BadMetadata, encode(&w, src, dense, testWork()));
    w = .fixed(&file);
    try encode(&w, src, .{
        .srgb = .relative_colorimetric,
        .density = .{ .x = 3, .y = 2, .unit = .none },
    }, testWork());
    r = .fixed(w.buffered());
    d = .init(&r, .{});
    const m2 = (try d.decodeConfig()).metadata;
    try testing.expectEqual(decode.Transfer.srgb, m2.transfer.?);
    try testing.expectEqual(decode.Density{ .x = 3, .y = 2, .unit = .none }, m2.density.?);
}

test "HDR chunks are written and read" {
    var file: [1024]u8 = undefined;
    var px = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const src = try PixelBuffer.init(&px, .rgb8, 2, 1);
    const cicp: decode.Metadata.Cicp = .{ .primaries = 9, .transfer = 16, .matrix = 0, .full_range = false };
    // Display P3 and D65; a 4000-nit display; light levels near the
    // largest a chunk holds, 214,748.3647 nits.
    const display: decode.Metadata.MasteringDisplay = .{
        .primaries = .{ 0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329 },
        .min_luminance = 0.005,
        .max_luminance = 4000,
    };
    const light: decode.Metadata.ContentLightLevel = .{ .max_cll = 214_748.36, .max_fall = 0 };
    var w: Io.Writer = .fixed(&file);
    const options: EncodeOptions = .{
        .srgb = .perceptual,
        .cicp = cicp,
        .mastering_display = display,
        .content_light_level = light,
    };
    try encode(&w, src, options, testWork());
    const out = w.buffered();
    const mdcv_at = std.mem.find(u8, out, "mDCV").? + 4;
    try testing.expectEqualSlices(u8, "\x84\xd0\x3e\x80\x33\xc2\x86\xc4\x1d\x4c\x0b\xb8\x3d\x13\x40\x42" ++
        "\x02\x62\x5a\x00\x00\x00\x00\x32", out[mdcv_at..][0..24]);
    const clli_at = std.mem.find(u8, out, "cLLI").? + 4;
    // 214,748.36 is the f32 214,748.359375.
    try testing.expectEqualSlices(u8, "\x7f\xff\xff\xca\x00\x00\x00\x00", out[clli_at..][0..8]);
    try testing.expectEqualSlices(u8, "\x09\x10\x00\x00", out[std.mem.find(u8, out, "cICP").? + 4 ..][0..4]);
    var r: Io.Reader = .fixed(out);
    var d: Decoder = .init(&r, .{});
    const m = (try d.decodeConfig()).metadata;
    try testing.expectEqual(cicp, m.cicp.?);
    try testing.expectEqual(decode.Transfer.pq, m.transfer.?);
    try testing.expectEqual(display, m.mastering_display.?);
    // Above 1024 nits an f32 cannot hold every ten-thousandth, but the
    // value read back is the one written.
    try testing.expectEqual(light, m.content_light_level.?);

    const bad = [_]EncodeOptions{
        .{ .cicp = .{ .primaries = 1, .transfer = 1, .matrix = 1, .full_range = true } },
        .{ .mastering_display = .{ .primaries = @splat(1.32), .min_luminance = 0, .max_luminance = 1 } },
        .{ .mastering_display = .{ .primaries = @splat(0.3), .min_luminance = -1, .max_luminance = 1 } },
        .{ .mastering_display = .{ .primaries = @splat(0.3), .min_luminance = 0, .max_luminance = std.math.nan(f32) } },
        .{ .content_light_level = .{ .max_cll = 214_748.37, .max_fall = 0 } },
        .{ .content_light_level = .{ .max_cll = 0, .max_fall = std.math.inf(f32) } },
    };
    for (bad) |o| try testing.expectError(error.BadMetadata, encode(&w, src, o, testWork()));
}

test "an animation reads back frame by frame" {
    var file: [8192]u8 = undefined;
    var a: [4 * 4 * 4]u8 = undefined;
    for (&a, 0..) |*b, i| b.* = @intCast(i * 3);
    var b: [2 * 1 * 3]u8 = .{ 9, 8, 7, 6, 5, 4 };
    const frames = [_]AnimationFrame{
        .{
            .pixels = try PixelBuffer.init(&a, .rgba8, 4, 4),
            .duration = decode.flicks_per_second / 10,
            .disposal = .background,
        },
        .{
            .pixels = try PixelBuffer.init(&b, .rgb8, 2, 1),
            .x = 1,
            .y = 2,
            .duration = decode.flicks_per_second / 30,
        },
    };
    var w: Io.Writer = .fixed(&file);
    try encodeAnimation(&w, 4, 4, &frames, .{ .loop_count = 3 }, testWork());
    var r: Io.Reader = .fixed(w.buffered());
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(2, config.frame_count.?);
    try testing.expectEqual(3, config.loop_count.?);
    var canvas: [4 * 4 * 4]u8 = undefined;
    const dst = try PixelBuffer.init(&canvas, .rgba8, 4, 4);
    const f0 = (try d.decodeFrame(dst, testWork())).?;
    try testing.expectEqualSlices(u8, &a, &canvas);
    try testing.expectEqual(frames[0].duration, f0.duration);
    try testing.expectEqual(decode.Frame.Disposal.background, f0.disposal);
    const f1 = (try d.decodeFrame(dst, testWork())).?;
    try testing.expectEqual(frames[1].duration, f1.duration);
    try testing.expectEqual(@as(u32, 1), f1.x);
    try testing.expectEqualSlices(u8, &.{ 9, 8, 7, 255, 6, 5, 4, 255 }, canvas[(2 * 4 + 1) * 4 ..][0..8]);
    try testing.expectEqual(null, try d.decodeFrame(dst, testWork()));
    // A first frame that is not the canvas.
    try testing.expectError(error.BadFrame, encodeAnimation(&w, 4, 4, frames[1..], .{}, testWork()));
}

test "delays are exact when they fit and nearest otherwise" {
    const f = decode.flicks_per_second;
    try testing.expectEqual([2]u16{ 1, 10 }, delay(f / 10));
    try testing.expectEqual([2]u16{ 1, 30 }, delay(f / 30));
    try testing.expectEqual([2]u16{ 1001, 30000 }, delay(f / 30000 * 1001));
    try testing.expectEqual([2]u16{ 65535, 1 }, delay(f * 70000));
    // One flick: 1/705600000 s, nearest is 0/1... or 1/65535; it must
    // stay within the bounds whatever it picks.
    const tiny = delay(1);
    try testing.expect(tiny[1] >= 1);
    // pi seconds: 355/113 is the classic best fraction.
    const pi = delay(@intFromFloat(std.math.pi * @as(f64, f)));
    try testing.expectApproxEqRel(std.math.pi, @as(f64, @floatFromInt(pi[0])) / @as(f64, @floatFromInt(pi[1])), 1e-6);
}
