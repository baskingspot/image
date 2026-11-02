//! A streaming TIFF decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, and allocates nothing.
//!
//! Format: TIFF 6.0 with BigTIFF. Classic and BigTIFF files in either byte
//! order; strips and tiles; uncompressed, PackBits, LZW, Deflate, and CCITT
//! modified Huffman, Group 3, and Group 4 data; predictors 2 and 3; 1 to
//! 32-bit integer and 16, 24, 32, and 64-bit float samples, chunky or
//! planar; gray, palette, RGB, CMYK (as `cmyk8` or `cmyk16`), and YCbCr with
//! subsampling. Every IFD in the main chain is a page and a frame.
//! samples.zig says how samples become the native format;
//! docs/slop/tiff.md records the decisions.
//!
//! The input is read forward, as every decoder here reads it. TIFF's
//! offsets point anywhere, and the usual writer puts the IFD after the
//! pixels, so data behind the reader needs `Options.seeker`
//! (`error.DataBehind` without one). With a seeker, `decodeConfig` walks
//! the whole IFD chain to report the page count, a canvas as large as the
//! largest page, the work memory the largest page needs, and a native
//! format that holds every page; a chain that loops ends where it repeats,
//! as in libtiff. Without one, the config is the first page's,
//! `frame_count` is null when there is a second page, and a later page
//! that does not fit it is `error.PageMismatch`.
//!
//! Each frame is a page, written to the top-left corner of the canvas; the
//! rest of the canvas becomes black, transparent if the native format has
//! alpha.
//! Work memory is the page's strip or tile offsets and byte counts, the
//! decompressor's state, and one row of the strip or tile (one strip or
//! tile of every plane for planar data, which interleaves them), so for
//! chunky data it does not grow with the image's height.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zlib = @import("compress").zlib;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const ifd = @import("ifd.zig");
const samples = @import("samples.zig");
const lzw = @import("lzw.zig");
const packbits = @import("packbits.zig");
const fax = @import("fax.zig");

const Decoder = @This();

pub const Options = struct {
    limits: decode.Limits = .{},
    blob_sink: ?decode.BlobSink = null,
    /// Moves back to data behind the reader (`image.Seeker`). Without it,
    /// such data is `error.DataBehind`.
    seeker: ?decode.Seeker = null,
};

pub const Error = decode.Error || error{
    /// An IFD, a value, or a strip or tile lies before the reader's
    /// position, and `Options.seeker` is null.
    DataBehind,
    /// Without a seeker, a page after the first does not fit the config
    /// the first page gave: it is larger than the canvas, needs more work
    /// memory than `Config.work_len`, or has pixels `Config.native` cannot
    /// hold.
    PageMismatch,
    /// A strip or tile's data ends before its rows do.
    NotEnoughData,
    /// LZW data does not start with Clear, or has a code past the table.
    BadLzw,
    /// Deflate data is not a valid zlib stream.
    BadZlib,
    /// CCITT data has an invalid code, or runs past a row.
    BadFax,
};

in: ifd.Input,
options: Options,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,
state: State = .start,
config: decode.Config = undefined,
/// The page being decoded, and how its pixels are laid out.
page: ifd.Page = .{},
layout: Layout = undefined,
/// Whether `page` is the next page to decode, already read.
loaded: bool = false,
colormap: [3][256]u16 = undefined,
/// The next frame's index, and its IFD's offset when not loaded.
index: u32 = 0,
next_ifd: u64 = 0,

const State = enum { start, frames, done };

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .in = .{ .r = reader, .seeker = options.seeker }, .options = options };
}

/// Reads the header and the first page's IFD and, with a seeker, every
/// other page's. Calling it again returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHead() catch |e| return d.fail(e);
        d.state = .frames;
    }
    return d.config;
}

/// Decodes the next page into the top-left corner of `dst`, which must be
/// the canvas's size, in any format. Returns null after the last page.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    const config = try d.decodeConfig();
    if (d.state == .done) return null;
    try dst.check();
    if (dst.width != config.width or dst.height != config.height) return error.SizeMismatch;
    if (work.len < config.work_len) return error.WorkTooSmall;
    return d.nextFrame(dst, work[0..config.work_len]) catch |e| return d.fail(e);
}

/// Reads the next page's IFD and returns the frame the next `decodeFrame`
/// returns, without decoding it, or null after the last page. Calling it
/// again returns the same frame.
pub fn decodeFrameConfig(d: *Decoder) Error!?decode.Frame {
    if (d.err) |e| return e;
    _ = try d.decodeConfig();
    if (d.state == .done) return null;
    d.loadNext() catch |e| return d.fail(e);
    return d.pageFrame();
}

fn pageFrame(d: *const Decoder) decode.Frame {
    const p = &d.page;
    return .{ .index = d.index, .width = p.width, .height = p.height, .is_opaque = !d.layout.native.hasAlpha() };
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

fn readHead(d: *Decoder) Error!void {
    const h = try ifd.readHeader(&d.in);
    if (h.first < d.in.pos) return error.BadHeader;
    try d.in.goTo(h.first);
    var metadata: decode.Metadata = .{};
    try d.loadPage(&metadata, d.options.blob_sink);
    const p = &d.page;
    metadata.orientation = decode.Orientation.fromExif(p.orientation) orelse .top_left;
    metadata.density = ifd.density(p);
    var canvas: [2]u32 = .{ p.width, p.height };
    var work = d.layout.work_len;
    var native = d.layout.native;
    var count: ?u32 = if (p.next == 0) 1 else null;
    const next = p.next;
    if (d.in.seeker != null and next != 0) count = try d.scan(&canvas, &work, &native);
    if (count) |n| if (n > d.options.limits.max_frames) {
        count = null;
    };
    d.config = .{
        .width = canvas[0],
        .height = canvas[1],
        .native = native,
        .frame_count = count,
        .work_len = work,
        .is_opaque = !native.hasAlpha(),
        .metadata = metadata,
    };
    d.loaded = true;
}

/// Reads the IFD at the reader's position and its values into `page`,
/// and plans its decoding.
fn loadPage(d: *Decoder, metadata: *decode.Metadata, sink: ?decode.BlobSink) Error!void {
    d.page = .{};
    const p = &d.page;
    try ifd.readIfd(&d.in, p);
    if (!p.has_width or !p.has_height) return error.BadHeader;
    try d.options.limits.checkSize(p.width, p.height);
    try ifd.loadValues(&d.in, p, .{ .layout = true, .rest = true }, &d.colormap, sink, metadata);
    d.layout = try plan(p, &d.colormap);
    try d.options.limits.checkWork(d.layout.work_len);
}

/// Walks the IFD chain after the first page, widening the canvas and the
/// work memory to every page's, and returns the page count, or null past
/// `max_frames`, whose page fails when it is reached. A chain that loops
/// ends before the first repeated IFD (Brent's cycle finding), and one
/// that reaches an unreadable IFD ends with that page, which fails when it
/// is decoded; so does a page that is unsupported. A page or a canvas over
/// the limits fails here.
fn scan(d: *Decoder, canvas: *[2]u32, work: *usize, native: *PixelFormat) Error!?u32 {
    const limits = d.options.limits;
    const start = d.page.offset;
    var tortoise = start;
    var hare = d.page.next;
    var power: u64 = 1;
    var lam: u64 = 1;
    var steps: u64 = 1;
    var colormap: [3][256]u16 = undefined;
    while (hare != 0) {
        if (hare == tortoise) {
            // A loop of length `lam`; the pages before it are the chain's
            // first `mu`.
            var a = start;
            var b = start;
            for (0..lam) |_| b = try d.nextOf(b);
            var mu: u64 = 0;
            while (a != b) : (mu += 1) {
                a = try d.nextOf(a);
                b = try d.nextOf(b);
            }
            steps = mu + lam;
            break;
        }
        if (power == lam) {
            tortoise = hare;
            power *= 2;
            lam = 0;
        }
        steps += 1;
        // Distinct pages are at most `steps`, and a loop is found within
        // twice the pages before it repeats, so past that the chain has
        // more pages than the limit.
        if (steps > 2 * @as(u64, limits.max_frames) + 2) return null;
        var p: ifd.Page = .{};
        d.in.goTo(hare) catch |e| {
            try passRead(e);
            break;
        };
        ifd.readIfd(&d.in, &p) catch |e| {
            try passRead(e);
            break;
        };
        hare = p.next;
        lam += 1;
        // Until a loop is found, `steps` numbers this page in the chain;
        // pages past the limit fail when reached and need no room.
        if (steps > limits.max_frames) continue;
        if (!p.has_width or !p.has_height) continue;
        // The limits hold for every page, as for the first.
        try limits.checkSize(p.width, p.height);
        var unused: decode.Metadata = .{};
        ifd.loadValues(&d.in, &p, .{}, &colormap, null, &unused) catch |e| {
            try passRead(e);
            continue;
        };
        const l = planLayout(&p) catch continue;
        try limits.checkWork(l.work_len);
        // A page no native format holds with the others fails when
        // decoded.
        native.* = samples.join(native.*, l.native) orelse continue;
        canvas.* = .{ @max(canvas[0], p.width), @max(canvas[1], p.height) };
        try limits.checkSize(canvas[0], canvas[1]);
        work.* = @max(work.*, l.work_len);
    }
    return std.math.cast(u32, steps);
}

/// A reader failure stops the walk; any other error is the page's own.
fn passRead(e: ifd.Error) Error!void {
    if (e == error.ReadFailed) return error.ReadFailed;
}

/// The offset of the IFD after the one at `offset`, read without its
/// entries.
fn nextOf(d: *Decoder, offset: u64) Error!u64 {
    try d.in.goTo(offset);
    const n = if (d.in.big) try d.in.int(u64) else try d.in.int(u16);
    const entry: u64 = if (d.in.big) 20 else 12;
    const skip = std.math.mul(u64, n, entry) catch return error.BadHeader;
    try d.in.goTo(std.math.add(u64, d.in.pos, skip) catch return error.BadHeader);
    return d.in.word();
}

/// Reads the next page's IFD unless it is read already, and checks that it
/// fits the config.
fn loadNext(d: *Decoder) Error!void {
    if (d.loaded) return;
    try d.options.limits.checkFrames(@as(u64, d.index) + 1);
    try d.in.goTo(d.next_ifd);
    var unused: decode.Metadata = .{};
    try d.loadPage(&unused, null);
    d.loaded = true;
    const p = &d.page;
    const c = &d.config;
    if (p.width > c.width or p.height > c.height or d.layout.work_len > c.work_len or
        samples.join(c.native, d.layout.native) != c.native) return error.PageMismatch;
}

fn nextFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!decode.Frame {
    try d.loadNext();
    d.loaded = false;
    const p = &d.page;
    clearOutside(dst, p.width, p.height, d.config.native);
    try d.decodePage(dst.sub(0, 0, p.width, p.height), work);
    const f = d.pageFrame();
    d.index += 1;
    d.next_ifd = p.next;
    const last = if (d.config.frame_count) |n| d.index >= n else p.next == 0;
    if (last) d.state = .done;
    return f;
}

/// Fills the canvas outside a page's `width` by `height` corner with
/// black in the native format (transparent when it has alpha), so that
/// what a frame leaves is the same in every pixel format.
fn clearOutside(dst: PixelBuffer, width: u32, height: u32, native: PixelFormat) void {
    if (width == dst.width and height == dst.height) return;
    const zero: [16]u8 = @splat(0);
    var px: [16]u8 = undefined;
    Converter.init(dst.format, native).run(&px, &zero, 1);
    const bpp = dst.format.bytesPerPixel();
    for (0..dst.height) |y| {
        const row = dst.row(@intCast(y));
        const from: usize = if (y < height) width else 0;
        var x = from;
        while (x < dst.width) : (x += 1) @memcpy(row[x * bpp ..][0..bpp], px[0..bpp]);
    }
}

/// How a page's pixels are stored and decoded, and where each part of the
/// work memory goes.
const Layout = struct {
    native: PixelFormat,
    chunk_w: u32,
    chunk_h: u32,
    across: u32,
    down: u32,
    /// 1 for chunky data, or the samples per pixel for planar data.
    planes: u16,
    per_plane: u64,
    /// The bytes of one row of a chunk (of one plane), or for subsampled
    /// YCbCr, of one row of data units.
    line_len: usize,
    /// YCbCr subsampling, 1 by 1 for everything else.
    unit: [2]u16,
    /// Bytes per sample, 0 for bit-packed samples.
    bytes: u8,
    /// Samples per pixel in a line, the predictor's stride.
    stride: usize,
    swap: bool,
    predictor: u16,
    palette_8bit: bool,
    offsets_len: usize,
    counts_len: usize,
    stage_at: usize,
    codec_at: usize,
    lines_at: usize,
    temp_at: usize,
    work_len: usize,

    fn chunks(l: *const Layout) u64 {
        return l.per_plane * l.planes;
    }

    /// The lines of a chunk whose visible part is `rows` rows.
    fn lines(l: *const Layout, rows: u32) u32 {
        return (rows + l.unit[1] - 1) / l.unit[1];
    }
};

const stage_len = 4096;

fn plan(p: *ifd.Page, colormap: *const [3][256]u16) Error!Layout {
    var l = try planLayout(p);
    if (p.model() == .palette) {
        const entries = @as(usize, 1) << @intCast(p.bits);
        var narrow = true;
        for (colormap) |channel| {
            for (channel[0..entries]) |v| narrow = narrow and v >> 8 == v & 0xff;
        }
        l.palette_8bit = narrow;
        l.native = samples.nativeFormat(p, narrow);
    }
    return l;
}

/// Checks a page's fields and lays out its decoding: everything but the
/// color map, which `plan` adds.
fn planLayout(p: *ifd.Page) Error!Layout {
    if (p.width == 0 or p.height == 0) return error.BadHeader;
    // Values outside the specification's, which libtiff refuses.
    if (p.orientation == 0 or p.orientation > 8) return error.BadHeader;
    if (p.res_unit == 0 or p.res_unit > 3) return error.BadHeader;
    const fax_kind = p.compression == 2 or p.compression == 3 or p.compression == 4;
    if (p.photometric == null) p.photometric = if (fax_kind) 0 else if (p.spp >= 3) 2 else 1;
    const map_ok = p.bits <= 16 and p.bits_field.present() and p.colormap.count == @as(u64, 3) << @intCast(p.bits);
    if (p.photometric == 3 and !map_ok) {
        // A palette page without a color map of the right length, or
        // without BitsPerSample to check it against, is gray or RGB when its
        // samples are 8 bits or wider, as libtiff takes it.
        if (p.bits < 8) return error.BadHeader;
        p.photometric = if (p.spp == 3) 2 else 1;
    }
    switch (p.photometric.?) {
        0, 1, 2, 3, 6 => {},
        5 => if (p.ink_set != 1) return error.Unsupported,
        else => return error.Unsupported,
    }
    if (p.spp == 0 or p.spp < p.colorChannels()) return error.BadHeader;
    switch (p.compression) {
        1, 5, 8, 32946, 32773 => {},
        2, 3, 4 => if (p.bits != 1 or p.spp != 1) return error.BadHeader,
        else => return error.Unsupported,
    }
    if (p.bits == 0 or p.bits > 64) return error.BadHeader;
    switch (p.sample) {
        .float => switch (p.bits) {
            16, 24, 32, 64 => {},
            else => return error.Unsupported,
        },
        else => if (p.bits > 32) return error.Unsupported,
    }
    const model = p.model();
    switch (model) {
        .palette => if (p.bits > 8 or p.sample != .uint or p.spp != 1) return error.Unsupported,
        .ycbcr => {
            if (p.bits != 8 or p.sample != .uint or p.spp != 3) return error.Unsupported;
            const h = p.subsampling[0];
            const v = p.subsampling[1];
            if (!(h == 1 or h == 2 or h == 4) or !(v == 1 or v == 2 or v == 4) or v > h) return error.BadHeader;
        },
        .gray, .rgb, .cmyk => if (p.sample == .float and p.photometric.? == 0) return error.Unsupported,
    }
    if (p.fill_order != 1 and p.fill_order != 2) return error.BadHeader;
    if (p.planar != 1 and p.planar != 2) return error.BadHeader;
    const planar = p.planar == 2 and p.spp > 1;
    if (planar and p.subsampled()) return error.Unsupported;
    const predictor: u16 = switch (p.compression) {
        5, 8, 32946 => p.predictor,
        else => 1,
    };
    const bytes = samples.sampleBytes(p.bits);
    switch (predictor) {
        1 => {},
        2 => if (bytes == 0 or bytes == 3 or p.subsampled()) return error.Unsupported,
        3 => if (p.sample != .float) return error.Unsupported,
        else => return error.Unsupported,
    }

    var l: Layout = undefined;
    l.native = samples.nativeFormat(p, false);
    l.palette_8bit = false;
    l.planes = if (planar) p.spp else 1;
    l.unit = if (p.subsampled()) p.subsampling else .{ 1, 1 };
    l.bytes = bytes;
    l.stride = if (planar) 1 else p.spp;
    l.swap = p.compression != 7 and bytes > 1 and predictor != 3 and samples.native_endian != p.endian;
    l.predictor = predictor;
    if (p.tiled()) {
        const tw = p.tile_width orelse return error.BadHeader;
        const th = p.tile_height orelse return error.BadHeader;
        if (tw == 0 or th == 0) return error.BadHeader;
        // The tiles across and down must be countable in 32 bits, as in
        // libtiff.
        if (p.width + tw - 1 > std.math.maxInt(u32) or p.height + th - 1 > std.math.maxInt(u32)) return error.BadHeader;
        l.chunk_w = std.math.cast(u32, tw) orelse return error.ImageTooLarge;
        l.chunk_h = std.math.cast(u32, th) orelse return error.ImageTooLarge;
    } else {
        if (p.rows_per_strip == 0) return error.BadHeader;
        l.chunk_w = p.width;
        l.chunk_h = @intCast(@min(p.rows_per_strip, p.height));
    }
    if (l.chunk_h % l.unit[1] != 0 and (p.tiled() or l.chunk_h != p.height)) return error.BadHeader;
    l.across = @intCast((@as(u64, p.width) + l.chunk_w - 1) / l.chunk_w);
    l.down = @intCast((@as(u64, p.height) + l.chunk_h - 1) / l.chunk_h);
    l.per_plane = @as(u64, l.across) * l.down;
    const chunks = std.math.mul(u64, l.per_plane, l.planes) catch return error.ImageTooLarge;

    if (l.unit[0] != 1 or l.unit[1] != 1) {
        const units = (@as(u64, l.chunk_w) + l.unit[0] - 1) / l.unit[0];
        const unit_len = @as(u64, l.unit[0]) * l.unit[1] + 2;
        l.line_len = std.math.cast(usize, units * unit_len) orelse return error.ImageTooLarge;
    } else {
        const per_pixel: u64 = @as(u64, if (planar) 1 else p.spp) * p.bits;
        const bits = std.math.mul(u64, l.chunk_w, per_pixel) catch return error.ImageTooLarge;
        l.line_len = std.math.cast(usize, (bits + 7) / 8) orelse return error.ImageTooLarge;
    }

    if (!p.offsets.present() or !p.counts.present()) return error.BadHeader;
    for ([_]ifd.Field{ p.offsets, p.counts }) |f| {
        switch (f.type) {
            3, 4, 16 => {},
            else => return error.BadHeader,
        }
        if (f.count < chunks) return error.BadHeader;
    }
    var at: u64 = 0;
    l.offsets_len = try arrayLen(p.offsets, chunks);
    l.counts_len = try arrayLen(p.counts, chunks);
    at = try add(at, l.offsets_len);
    at = try add(at, l.counts_len);
    l.stage_at = @intCast(at);
    if (p.compression != 1) at = try add(at, stage_len);
    l.codec_at = @intCast(at);
    at = try add(at, switch (p.compression) {
        5 => lzw.work_len,
        8, 32946 => @sizeOf(zlib.Reader.Buffer),
        2, 3, 4 => fax.workLen(l.chunk_w) orelse return error.WorkTooLarge,
        else => 0,
    });
    l.lines_at = @intCast(at);
    const lines = if (planar)
        std.math.mul(u64, try mulWork(l.line_len, l.chunk_h), l.planes) catch return error.WorkTooLarge
    else
        l.line_len;
    at = try add(at, lines);
    l.temp_at = @intCast(at);
    if (predictor == 3) at = try add(at, l.line_len);
    l.work_len = std.math.cast(usize, at) orelse return error.WorkTooLarge;
    return l;
}

fn mulWork(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.WorkTooLarge;
}

fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.WorkTooLarge;
}

/// The work memory a stored array of `n` values takes; none when inline.
fn arrayLen(f: ifd.Field, n: u64) Error!u64 {
    if (f.at == null) return 0;
    return std.math.mul(u64, n, f.size()) catch error.WorkTooLarge;
}

/// The strip or tile offsets and byte counts, inline or in work memory.
const Arrays = struct {
    offsets: ifd.Field,
    counts: ifd.Field,
    offsets_bytes: []const u8,
    counts_bytes: []const u8,
    endian: std.builtin.Endian,

    fn offset(a: *const Arrays, i: u64) u64 {
        return a.offsets.get(a.offsets_bytes, @intCast(i), a.endian);
    }

    fn count(a: *const Arrays, i: u64) u64 {
        return a.counts.get(a.counts_bytes, @intCast(i), a.endian);
    }
};

/// Reads the stored arrays into work memory, the earlier first.
fn loadArrays(d: *Decoder, work: []u8) Error!Arrays {
    const p = &d.page;
    const l = &d.layout;
    const a: Arrays = .{
        .offsets = p.offsets,
        .counts = p.counts,
        .offsets_bytes = work[0..l.offsets_len],
        .counts_bytes = work[l.offsets_len..][0..l.counts_len],
        .endian = d.in.endian,
    };
    const first_counts = p.offsets.at != null and p.counts.at != null and p.counts.at.? < p.offsets.at.?;
    const order = if (first_counts) [2]u1{ 1, 0 } else [2]u1{ 0, 1 };
    for (order) |which| {
        const f = if (which == 0) p.offsets else p.counts;
        const at = f.at orelse continue;
        try d.in.goTo(at);
        try d.in.read(work[if (which == 0) 0 else l.offsets_len..][0..if (which == 0) l.offsets_len else l.counts_len]);
    }
    return a;
}

fn decodePage(d: *Decoder, region: PixelBuffer, work: []u8) Error!void {
    const p = &d.page;
    const l = &d.layout;
    const arrays = try d.loadArrays(work);
    var out: Out = undefined;
    out.init(p, l, &d.colormap, region);
    for (0..l.down) |cy| {
        for (0..l.across) |cx| {
            const x0: u32 = @intCast(cx * l.chunk_w);
            const y0: u32 = @intCast(cy * l.chunk_h);
            const vw = @min(l.chunk_w, p.width - x0);
            const vh = @min(l.chunk_h, p.height - y0);
            const index = cy * l.across + cx;
            // A tile is decoded whole, its rows below the image too, as
            // libtiff decodes it.
            const rows = if (p.tiled()) l.chunk_h else vh;
            if (l.planes > 1) {
                const plane_len = l.line_len * l.chunk_h;
                const buf = work[l.lines_at..];
                for (0..l.planes) |pl| {
                    var t: PlaneTarget = .{ .buf = buf[pl * plane_len ..][0..plane_len], .line_len = l.line_len };
                    try d.decodeChunk(&arrays, work, pl * l.per_plane + index, rows, vh, &t);
                }
                var planes: [64][]const u8 = undefined;
                const n = @min(l.planes, planes.len);
                for (0..vh) |r| {
                    for (planes[0..n], 0..) |*s, pl| s.* = buf[pl * plane_len + r * l.line_len ..][0..l.line_len];
                    out.emitRow(planes[0..n], y0 + @as(u32, @intCast(r)), x0, vw);
                }
            } else {
                var t: RowTarget = .{
                    .out = &out,
                    .line = work[l.lines_at..][0..l.line_len],
                    .x0 = x0,
                    .y0 = y0,
                    .vw = vw,
                    .vh = vh,
                    .full = vw == l.chunk_w,
                };
                try d.decodeChunk(&arrays, work, index, l.lines(rows), l.lines(vh), &t);
            }
        }
    }
}

/// Where a chunky chunk's lines go: straight to the caller's rows.
const RowTarget = struct {
    out: *Out,
    line: []u8,
    x0: u32,
    y0: u32,
    vw: u32,
    vh: u32,
    /// Whether a line is exactly its visible pixels.
    full: bool,

    const zero_copy = true;

    fn buffer(t: *RowTarget, r: u32) []u8 {
        if (t.full and t.out.direct and t.out.kind == .copy) return t.out.dstRow(t.y0 + r, t.x0, t.vw);
        return t.line;
    }

    fn scratch(t: *RowTarget, _: u32) []u8 {
        return t.line;
    }

    fn done(t: *RowTarget, r: u32, line: []const u8) void {
        if (t.out.kind == .units) {
            const v = t.out.unit[1];
            const y = t.y0 + r * v;
            t.out.emitUnits(line, y, @min(v, t.y0 + t.vh - y), t.x0, t.vw);
        } else {
            t.out.emitRow(&.{line}, t.y0 + r, t.x0, t.vw);
        }
    }
};

/// Where a planar chunk's lines go: a plane's buffer, interleaved later.
const PlaneTarget = struct {
    buf: []u8,
    line_len: usize,

    const zero_copy = false;

    fn buffer(t: *PlaneTarget, r: u32) []u8 {
        return t.buf[r * t.line_len ..][0..t.line_len];
    }

    fn scratch(t: *PlaneTarget, r: u32) []u8 {
        return t.buffer(r);
    }

    fn done(_: *PlaneTarget, _: u32, _: []const u8) void {}
};

/// The bytes of one strip or tile, from the input, as a reader the
/// decompressors pull from, bit-reversed for FillOrder 2.
const Source = struct {
    reader: Io.Reader,
    in: *ifd.Input,
    left: u64,
    reverse: bool,
    err: ?Error = null,

    fn init(in: *ifd.Input, left: u64, reverse: bool, stage: []u8) Source {
        return .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = stage, .seek = 0, .end = 0 },
            .in = in,
            .left = left,
            .reverse = reverse,
        };
    }

    fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const s: *Source = @alignCast(@fieldParentPtr("reader", io_r));
        if (s.err != null) return error.ReadFailed;
        if (s.left == 0) return error.EndOfStream;
        const got = s.in.r.peekGreedy(1) catch |e| {
            s.err = ifd.mapRead(e);
            return error.ReadFailed;
        };
        const dest = try w.writableSliceGreedy(1);
        const n: usize = @intCast(@min(@min(got.len, dest.len), @min(s.left, limit.minInt(got.len))));
        if (s.reverse) {
            for (dest[0..n], got[0..n]) |*o, b| o.* = @bitReverse(b);
        } else @memcpy(dest[0..n], got[0..n]);
        w.advance(n);
        s.in.r.toss(n);
        s.in.pos += n;
        s.left -= n;
        return n;
    }
};

const Codec = union(enum) {
    lzw: lzw.Decoder,
    zlib: zlib.Reader,
    packbits: packbits.Decoder,
    fax: fax.Decoder,

    fn read(c: *Codec, src: *const Source, buf: []u8) LinesError!void {
        switch (c.*) {
            .lzw => |*z| z.read(buf) catch |e| return switch (e) {
                error.ReadFailed => src.err orelse error.ReadFailed,
                else => |x| x,
            },
            .packbits => |*z| z.read(buf) catch |e| return switch (e) {
                error.ReadFailed => src.err orelse error.ReadFailed,
                else => |x| x,
            },
            .fax => |*z| z.read(buf) catch |e| return switch (e) {
                error.ReadFailed => src.err orelse error.ReadFailed,
                else => |x| x,
            },
            .zlib => |*z| z.reader.readSliceAll(buf) catch |e| return switch (e) {
                error.EndOfStream => error.NotEnoughData,
                error.ReadFailed => src.err orelse switch (z.err orelse return error.BadZlib) {
                    error.Truncated => error.NotEnoughData,
                    error.ReadFailed => error.ReadFailed,
                    else => error.BadZlib,
                },
            },
        }
    }
};

/// Decodes `lines` lines of chunk `index`, the first `shown` into
/// `target`, and moves to the chunk's end, which must be in the input.
fn decodeChunk(
    d: *Decoder,
    arrays: *const Arrays,
    work: []u8,
    index: u64,
    lines: u32,
    shown: u32,
    target: anytype,
) Error!void {
    var len = arrays.count(index);
    // A byte count over 1 MiB and over ten times the chunk's decoded size
    // (plus 4096) is cut to that, as libtiff cuts it.
    const decoded = @as(u64, d.layout.line_len) * d.layout.lines(d.layout.chunk_h);
    if (len > 1 << 20 and (len - 4096) / 10 > decoded) len = decoded * 10 + 4096;
    const offset = arrays.offset(index);
    const end = std.math.add(u64, offset, len) catch return error.BadHeader;
    try d.in.goTo(offset);
    d.decodeLines(work, len, lines, shown, target, false) catch |e| switch (e) {
        // libtiff decodes Group 3 data without EOLs again from the start,
        // expecting none; so does this decoder, with the seeker if it is
        // behind.
        error.NoEol => {
            try d.in.goTo(offset);
            d.decodeLines(work, len, lines, shown, target, true) catch |e2| return switch (e2) {
                error.NoEol => unreachable,
                else => |x| x,
            };
        },
        else => |x| return x,
    };
    // What a decompressor read ahead of the rows depends on how the reader
    // chunks the input; past the chunk's end, it does not.
    try d.in.goTo(end);
}

/// The errors of decoding a chunk once.
const LinesError = Error || error{NoEol};

fn decodeLines(
    d: *Decoder,
    work: []u8,
    len: u64,
    lines: u32,
    shown: u32,
    target: anytype,
    no_eol: bool,
) LinesError!void {
    const p = &d.page;
    const l = &d.layout;
    const temp = work[l.temp_at..][0..if (l.predictor == 3) l.line_len else 0];
    if (p.compression == 1) {
        var left = len;
        const plain = p.fill_order == 1 and !l.swap;
        for (0..lines) |ri| {
            const r: u32 = @intCast(ri);
            if (left < l.line_len) return error.NotEnoughData;
            left -= l.line_len;
            if (r >= shown) {
                try d.in.goTo(d.in.pos + l.line_len);
            } else if (@TypeOf(target.*).zero_copy and plain and d.in.r.buffer.len >= l.line_len) {
                const got = d.in.r.peek(l.line_len) catch |e| return ifd.mapRead(e);
                target.done(r, got);
                d.in.r.toss(l.line_len);
                d.in.pos += l.line_len;
            } else {
                const buf = target.buffer(r);
                try d.in.read(buf);
                if (p.fill_order == 2) samples.reverseBits(buf);
                post(l, buf, temp);
                target.done(r, buf);
            }
        }
        return;
    }
    var src: Source = .init(&d.in, len, p.fill_order == 2, work[l.stage_at..][0..stage_len]);
    const codec_mem = work[l.codec_at..l.lines_at];
    var codec: Codec = switch (p.compression) {
        5 => .{ .lzw = .init(&src.reader, codec_mem) },
        8, 32946 => .{ .zlib = .init(&src.reader, codec_mem[0..@sizeOf(zlib.Reader.Buffer)], null) },
        32773 => .{ .packbits = .init(&src.reader) },
        2 => .{ .fax = .init(&src.reader, .mh, false, l.chunk_w, codec_mem) },
        3 => .{ .fax = .init(&src.reader, .g3, p.t4 & 1 != 0, l.chunk_w, codec_mem) },
        4 => .{ .fax = .init(&src.reader, .g4, true, l.chunk_w, codec_mem) },
        else => unreachable,
    };
    if (codec == .fax) codec.fax.no_eol = no_eol;
    for (0..lines) |ri| {
        const r: u32 = @intCast(ri);
        const buf = if (r < shown) target.buffer(r) else target.scratch(r);
        try codec.read(&src, buf);
        if (r >= shown) continue;
        post(l, buf, temp);
        target.done(r, buf);
    }
    // A zlib stream that ends with the rows has its Adler-32 checked. One
    // with more data after them is left unchecked, as libtiff leaves it.
    if (codec == .zlib) _ = codec.zlib.reader.peekByte() catch |e| switch (e) {
        error.EndOfStream => {},
        error.ReadFailed => return src.err orelse switch (codec.zlib.err orelse return error.BadZlib) {
            error.Truncated => error.NotEnoughData,
            error.ReadFailed => error.ReadFailed,
            else => error.BadZlib,
        },
    };
}

/// Byte order and the predictor, in place on a decompressed line.
fn post(l: *const Layout, buf: []u8, temp: []u8) void {
    if (l.swap) samples.swap(buf, l.bytes);
    switch (l.predictor) {
        2 => samples.horizontal(buf, l.bytes, l.stride),
        3 => samples.floating(buf, temp, l.bytes, l.stride),
        else => {},
    }
}

/// Pixels converted per step.
const span = 256;

/// Where a page's rows go: the caller's region, in its format, by way of
/// the native format.
const Out = struct {
    region: PixelBuffer,
    e: samples.Expand,
    kind: Kind,
    native: PixelFormat,
    to_dst: Converter,
    /// Whether the caller asked for the native format.
    direct: bool,
    dbpp: usize,
    /// YCbCr subsampling.
    unit: [2]u16,
    /// Palette entries in the caller's format.
    palette: [256][16]u8,

    const Kind = enum {
        /// The samples are the native format: 8 or 16-bit gray, gray and
        /// alpha, RGB, or RGBA, chunky.
        copy,
        palette,
        /// 1-bit gray, chunky.
        gray1,
        /// YCbCr data units, chunky.
        units,
        general,
    };

    fn init(o: *Out, p: *const ifd.Page, l: *const Layout, colormap: *const [3][256]u16, region: PixelBuffer) void {
        const model = p.model();
        const planar = l.planes > 1;
        o.region = region;
        o.native = l.native;
        o.e = .init(p, l.native);
        o.unit = l.unit;
        o.kind = if (model == .palette)
            .palette
        else if (model == .ycbcr and !planar)
            .units
        else if (!planar and p.sample == .uint and (p.bits == 8 or p.bits == 16) and
            (model == .rgb or model == .gray and p.photometric.? == 1) and p.spp == o.e.used)
            .copy
        else if (!planar and model == .gray and p.bits == 1 and p.spp == 1)
            .gray1
        else
            .general;
        o.to_dst = .init(region.format, l.native);
        o.direct = region.format == l.native;
        o.dbpp = region.format.bytesPerPixel();
        if (o.kind == .palette) {
            const entries = @as(usize, 1) << @intCast(p.bits);
            const c: Converter = .init(region.format, l.native);
            for (0..entries) |i| {
                var native: [6]u8 = undefined;
                for (0..3) |ch| {
                    const v = colormap[ch][i];
                    if (l.palette_8bit) {
                        native[ch] = @intCast(v >> 8);
                    } else std.mem.writeInt(u16, native[2 * ch ..][0..2], v, samples.native_endian);
                }
                c.run(&o.palette[i], &native, 1);
            }
        }
    }

    fn dstRow(o: *const Out, y: u32, x0: u32, n: u32) []u8 {
        return o.region.row(y)[x0 * o.dbpp ..][0 .. n * o.dbpp];
    }

    /// Writes `n` pixels from the start of a line, whose planes are
    /// `planes`, to row `y` from column `x0`.
    fn emitRow(o: *const Out, planes: []const []const u8, y: u32, x0: u32, n: u32) void {
        const dst = o.dstRow(y, x0, n);
        switch (o.kind) {
            .copy => {
                const src = planes[0][0 .. n * o.native.bytesPerPixel()];
                if (!o.direct) return o.to_dst.run(dst, src, n);
                if (src.ptr != dst.ptr) @memcpy(dst, src);
            },
            .palette => {
                const row = planes[0];
                const bits = o.e.bits;
                for (0..n) |x| {
                    const i: usize = if (bits == 8) row[x] else @intCast(samples.readBits(row, x * bits, bits));
                    @memcpy(dst[x * o.dbpp ..][0..o.dbpp], o.palette[i][0..o.dbpp]);
                }
            },
            .gray1 => {
                const row = planes[0];
                const on: u8 = if (o.e.min_is_white) 0 else 255;
                var buf: [span]u8 = undefined;
                var x: usize = 0;
                while (x < n) {
                    const m: usize = @min(span, n - x);
                    const out = if (o.direct) dst[x..][0..m] else buf[0..m];
                    for (out, x..) |*v, i| v.* = if (row[i / 8] >> @intCast(7 - i % 8) & 1 != 0) on else ~on;
                    if (!o.direct) o.to_dst.run(dst[x * o.dbpp ..], out, m);
                    x += m;
                }
            },
            .general => {
                const nbpp = o.native.bytesPerPixel();
                var buf: [span * 16]u8 = undefined;
                var x: usize = 0;
                while (x < n) {
                    const m: usize = @min(span, n - x);
                    const out = if (o.direct) dst[x * nbpp ..][0 .. m * nbpp] else buf[0 .. m * nbpp];
                    o.e.run(planes, x, m, out);
                    if (!o.direct) o.to_dst.run(dst[x * o.dbpp ..], out, m);
                    x += m;
                }
            },
            .units => unreachable,
        }
    }

    /// Writes `rows` rows from `y` of a line of YCbCr data units.
    fn emitUnits(o: *const Out, line: []const u8, y: u32, rows: u32, x0: u32, n: u32) void {
        const h: usize = o.unit[0];
        const v: usize = o.unit[1];
        const unit = h * v + 2;
        var buf: [span * 3]u8 = undefined;
        for (0..rows) |j| {
            const dst = o.dstRow(y + @as(u32, @intCast(j)), x0, n);
            var x: usize = 0;
            while (x < n) {
                const m: usize = @min(span, n - x);
                const out = if (o.direct) dst[3 * x ..][0 .. 3 * m] else buf[0 .. 3 * m];
                for (0..m) |k| {
                    const px = x + k;
                    const u = line[px / h * unit ..][0..unit];
                    const rgb = o.e.ycc.rgb(u[j * h + px % h], u[h * v], u[h * v + 1]);
                    out[3 * k ..][0..3].* = rgb;
                }
                if (!o.direct) o.to_dst.run(dst[x * o.dbpp ..], out, m);
                x += m;
            }
        }
    }
};

/// How `testFile` lays out a page.
const TestPage = struct {
    width: u32,
    height: u32,
    /// 1 (gray), 3 (RGB), or 4 (CMYK) samples of `bits` (8 or 16) bits.
    spp: u16,
    bits: u16 = 8,
    compression: u16 = 1,
    predictor: u16 = 1,
    planar: bool = false,
    /// Rows per strip, or 0 for 16×16 tiles.
    rows: u32 = 0,
    /// Whether the IFD comes before the page's data.
    ifd_first: bool = true,
    /// The samples, row by row.
    pixels: []const u16,
};

/// A TIFF file of `pages`, each page's IFD and data together, in order.
/// `loop` makes the last IFD's next offset point at the first.
fn testFile(gpa: std.mem.Allocator, endian: std.builtin.Endian, big: bool, pages: []const TestPage, loop: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, if (endian == .little) "II" else "MM");
    try testInt(u16, gpa, &out, endian, if (big) 43 else 42);
    if (big) {
        try testInt(u16, gpa, &out, endian, 8);
        try testInt(u16, gpa, &out, endian, 0);
    }
    var next_at = out.items.len;
    try testWord(gpa, &out, endian, big, 0);
    var first: u64 = 0;
    for (pages) |pg| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        var offsets: std.ArrayList(u64) = .empty;
        defer offsets.deinit(gpa);
        var counts: std.ArrayList(u64) = .empty;
        defer counts.deinit(gpa);
        const planes: u32 = if (pg.planar) pg.spp else 1;
        const per: u32 = if (pg.planar) 1 else pg.spp;
        const cw = if (pg.rows == 0) 16 else pg.width;
        const ch = if (pg.rows == 0) 16 else pg.rows;
        const across = (pg.width + cw - 1) / cw;
        const down = (pg.height + ch - 1) / ch;
        for (0..planes) |plane| for (0..down) |ty| for (0..across) |tx| {
            // One chunk's samples, predicted, in the file's byte order.
            const rows = if (pg.rows == 0) ch else @min(ch, pg.height - @as(u32, @intCast(ty)) * ch);
            var raw: std.ArrayList(u8) = .empty;
            defer raw.deinit(gpa);
            for (0..rows) |r| {
                var line: [16 * 3 * 64]u16 = undefined;
                const n = cw * per;
                for (0..cw) |c| for (0..per) |s| {
                    const x = tx * cw + c;
                    const y = ty * ch + r;
                    line[c * per + s] = if (x < pg.width and y < pg.height)
                        pg.pixels[(y * pg.width + x) * pg.spp + plane + s]
                    else
                        0;
                };
                if (pg.predictor == 2) {
                    var i = n;
                    while (i > per) {
                        i -= 1;
                        line[i] -%= line[i - per];
                    }
                }
                for (line[0..n]) |v| {
                    if (pg.bits == 8) try raw.append(gpa, @truncate(v)) else try testInt(u16, gpa, &raw, endian, v);
                }
            }
            try offsets.append(gpa, data.items.len);
            const start = data.items.len;
            switch (pg.compression) {
                1 => try data.appendSlice(gpa, raw.items),
                5 => {
                    const z = try lzw.testEncode(gpa, raw.items, false);
                    defer gpa.free(z);
                    try data.appendSlice(gpa, z);
                },
                8 => {
                    // Stored deflate blocks of at most 100 bytes.
                    try data.appendSlice(gpa, &.{ 0x78, 0x01 });
                    var at: usize = 0;
                    while (true) {
                        const n: u16 = @intCast(@min(100, raw.items.len - at));
                        const last = at + n == raw.items.len;
                        try data.append(gpa, @intFromBool(last));
                        var lens: [4]u8 = undefined;
                        std.mem.writeInt(u16, lens[0..2], n, .little);
                        std.mem.writeInt(u16, lens[2..4], ~n, .little);
                        try data.appendSlice(gpa, &lens);
                        try data.appendSlice(gpa, raw.items[at..][0..n]);
                        at += n;
                        if (last) break;
                    }
                    var adler: [4]u8 = undefined;
                    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw.items), .big);
                    try data.appendSlice(gpa, &adler);
                },
                32773 => {
                    // A no-op, literal runs, and a repeat when two bytes match.
                    try data.append(gpa, 0x80);
                    var at: usize = 0;
                    if (raw.items.len >= 2 and raw.items[0] == raw.items[1]) {
                        try data.appendSlice(gpa, &.{ 0xff, raw.items[0] });
                        at = 2;
                    }
                    while (at < raw.items.len) {
                        const n = @min(128, raw.items.len - at);
                        try data.append(gpa, @intCast(n - 1));
                        try data.appendSlice(gpa, raw.items[at..][0..n]);
                        at += n;
                    }
                },
                else => unreachable,
            }
            try counts.append(gpa, data.items.len - start);
        };

        // The IFD, sized first so its offsets are known.
        const entries = 12;
        const words: usize = offsets.items.len;
        const wl: usize = if (big) 8 else 4;
        const table: usize = if (big) 8 + 20 * entries + 8 else 2 + 12 * entries + 4;
        const ifd_len = table + 2 * words * wl + 2 * 4;
        const ifd_at = out.items.len + if (pg.ifd_first) 0 else data.items.len;
        const data_at = out.items.len + if (pg.ifd_first) ifd_len else 0;
        if (!pg.ifd_first) try out.appendSlice(gpa, data.items);
        std.mem.writeInt(u32, out.items[next_at..][0..4], 0, endian);
        testPut(out.items, next_at, big, endian, ifd_at);
        if (first == 0) first = ifd_at;
        const ext = ifd_at + table;
        const long: u16 = if (big) 16 else 4;
        const tags = [entries][4]u64{
            .{ 256, 4, 1, pg.width },
            .{ 257, 4, 1, pg.height },
            .{ 258, 3, 1, pg.bits },
            .{ 259, 3, 1, pg.compression },
            .{ 262, 3, 1, switch (pg.spp) {
                3 => 2,
                4 => 5,
                else => 1,
            } },
            .{ if (pg.rows == 0) 322 else 278, 4, 1, if (pg.rows == 0) 16 else pg.rows },
            if (pg.rows == 0) .{ 323, 4, 1, 16 } else .{ 273, long, words, ext },
            .{ 277, 3, 1, pg.spp },
            .{ if (pg.rows == 0) 324 else 279, long, words, ext + (if (pg.rows == 0) 0 else words * wl) },
            if (pg.rows == 0) .{ 325, long, words, ext + words * wl } else .{ 284, 3, 1, if (pg.planar) 2 else 1 },
            .{ if (pg.rows == 0) 284 else 317, 3, 1, if (pg.rows == 0) (if (pg.planar) 2 else 1) else pg.predictor },
            .{ if (pg.rows == 0) 317 else 339, 3, 1, if (pg.rows == 0) pg.predictor else 1 },
        };
        if (big) try testInt(u64, gpa, &out, endian, entries) else try testInt(u16, gpa, &out, endian, entries);
        for (tags) |t| {
            try testInt(u16, gpa, &out, endian, @intCast(t[0]));
            try testInt(u16, gpa, &out, endian, @intCast(t[1]));
            try testWord(gpa, &out, endian, big, t[2]);
            const one = t[2] == 1;
            if (t[0] == 273 or t[0] == 324) {
                try testWord(gpa, &out, endian, big, if (one) data_at + offsets.items[0] else t[3]);
            } else if (t[0] == 279 or t[0] == 325) {
                try testWord(gpa, &out, endian, big, if (one) counts.items[0] else t[3]);
            } else if (one and t[1] == 3) {
                try testInt(u16, gpa, &out, endian, @intCast(t[3]));
                try out.appendNTimes(gpa, 0, wl - 2);
            } else if (one and t[1] == 4) {
                try testInt(u32, gpa, &out, endian, @intCast(t[3]));
                try out.appendNTimes(gpa, 0, wl - 4);
            } else unreachable;
        }
        next_at = out.items.len;
        try testWord(gpa, &out, endian, big, 0);
        for (offsets.items) |o| try testWord(gpa, &out, endian, big, data_at + o);
        for (counts.items) |c| try testWord(gpa, &out, endian, big, c);
        try out.appendNTimes(gpa, 0, 8);
        if (pg.ifd_first) try out.appendSlice(gpa, data.items);
    }
    if (loop) {
        testPut(out.items, next_at, big, endian, first);
    }
    return out.toOwnedSlice(gpa);
}

fn testInt(comptime T: type, gpa: std.mem.Allocator, out: *std.ArrayList(u8), endian: std.builtin.Endian, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, endian);
    try out.appendSlice(gpa, &b);
}

fn testPut(buf: []u8, at: usize, big: bool, endian: std.builtin.Endian, v: u64) void {
    if (big) {
        std.mem.writeInt(u64, buf[at..][0..8], v, endian);
    } else std.mem.writeInt(u32, buf[at..][0..4], @intCast(v), endian);
}

fn testWord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), endian: std.builtin.Endian, big: bool, v: u64) !void {
    if (big) try testInt(u64, gpa, out, endian, v) else try testInt(u32, gpa, out, endian, @intCast(v));
}

/// Decodes every frame of `file` in its native format and checks each
/// against `pages`, with black outside the page.
fn testDecode(file: []const u8, pages: []const TestPage, seek: bool) !void {
    const gpa = testing.allocator;
    var r: Io.Reader = .fixed(file);
    var d = Decoder.init(&r, .{ .seeker = if (seek) .fixed(&r) else null });
    const config = try d.decodeConfig();
    var w: u32 = 0;
    var h: u32 = 0;
    for (pages) |pg| {
        w = @max(w, pg.width);
        h = @max(h, pg.height);
    }
    if (seek) {
        try testing.expectEqual(@as(?u32, @intCast(pages.len)), config.frame_count);
        try testing.expectEqual(.{ w, h }, .{ config.width, config.height });
    }
    const native = config.native;
    const want_format: PixelFormat = switch (pages[0].spp) {
        1 => if (pages[0].bits == 8) .gray8 else .gray16,
        else => if (pages[0].bits == 8) .rgb8 else .rgb16,
    };
    try testing.expectEqual(want_format, native);
    const pixels = try gpa.alloc(u8, PixelBuffer.len(native, config.width, config.height).?);
    defer gpa.free(pixels);
    const want = try gpa.alloc(u8, pixels.len);
    defer gpa.free(want);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    const dst = try PixelBuffer.init(pixels, native, config.width, config.height);
    for (pages, 0..) |pg, i| {
        @memset(pixels, 0xa5);
        const next = (try d.decodeFrameConfig()).?;
        try testing.expectEqual(next, (try d.decodeFrameConfig()).?);
        const frame = (try d.decodeFrame(dst, work)).?;
        try testing.expectEqual(next, frame);
        const got = .{ frame.index, frame.width, frame.height };
        try testing.expectEqual(.{ @as(u32, @intCast(i)), pg.width, pg.height }, got);
        @memset(want, 0);
        for (0..pg.height) |y| for (0..pg.width * pg.spp) |k| {
            const at = y * dst.stride + k * (pg.bits / 8);
            const v = pg.pixels[y * pg.width * pg.spp + k];
            if (pg.bits == 8) {
                want[at] = @intCast(v);
            } else std.mem.writeInt(u16, want[at..][0..2], v, samples.native_endian);
        };
        try testing.expectEqualSlices(u8, want, pixels);
    }
    try testing.expectEqual(null, try d.decodeFrameConfig());
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
}

test "strips and tiles, chunky and planar, each compression and predictor, both byte orders, classic and BigTIFF" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const compressions = [_]u16{ 1, 5, 8, 32773 };
    for (0..256) |round| {
        const spp: u16 = if (round % 2 == 0) 3 else 1;
        const bits: u16 = if (round / 2 % 2 == 0) 8 else 16;
        const width = 1 + random.uintLessThan(u32, 40);
        const height = 1 + random.uintLessThan(u32, 40);
        const pixels = try gpa.alloc(u16, width * height * spp);
        defer gpa.free(pixels);
        for (pixels, 0..) |*v, i| v.* = if (random.boolean()) @intCast(i * 7 % 256) else random.int(u16);
        if (bits == 8) for (pixels) |*v| {
            v.* &= 0xff;
        };
        const compression = compressions[round / 4 % compressions.len];
        const pg: TestPage = .{
            .width = width,
            .height = height,
            .spp = spp,
            .bits = bits,
            .compression = compression,
            // As in libtiff, only LZW and Deflate data has a predictor.
            .predictor = if (round / 16 % 2 == 0 or compression == 1 or compression == 32773) 1 else 2,
            .planar = spp == 3 and round / 32 % 2 == 1,
            .rows = if (round / 64 % 2 == 0) 0 else 1 + random.uintLessThan(u32, height + 2),
            .ifd_first = random.boolean(),
            .pixels = pixels,
        };
        const endian: std.builtin.Endian = if (round / 128 % 2 == 0) .little else .big;
        const file = try testFile(gpa, endian, random.boolean(), &.{pg}, false);
        defer gpa.free(file);
        errdefer std.debug.print("round {} page {} {}\n", .{ round, pg, endian });
        try testDecode(file, &.{pg}, true);
        // Planar data is stored plane by plane, but decoded a strip or tile
        // of every plane at a time.
        const forward = !pg.planar or (if (pg.rows == 0) width <= 16 and height <= 16 else pg.rows >= height);
        if (pg.ifd_first and forward) try testDecode(file, &.{pg}, false);
    }
}

test "CMYK keeps its inks, inverted, in cmyk8 or cmyk16, and converts to color naively" {
    const gpa = testing.allocator;
    // C, M, Y, K: no ink; full cyan; some cyan and black; everything.
    const inks = [_]u16{ 0, 0, 0, 0, 255, 0, 0, 0, 100, 0, 0, 50, 255, 255, 255, 255 };
    var wide: [16]u16 = undefined;
    for (&wide, inks) |*w, v| w.* = v * 257;
    var work: [4096]u8 = undefined;
    for ([_][]const u16{ &inks, &wide }, [_]u16{ 8, 16 }) |values, bits| {
        const pg: TestPage = .{ .width = 2, .height = 2, .spp = 4, .bits = bits, .rows = 2, .pixels = values };
        const file = try testFile(gpa, .little, false, &.{pg}, false);
        defer gpa.free(file);
        var r: Io.Reader = .fixed(file);
        var d = Decoder.init(&r, .{});
        const config = try d.decodeConfig();
        try testing.expectEqual(if (bits == 8) PixelFormat.cmyk8 else .cmyk16, config.native);
        try testing.expect(config.is_opaque);
        var pixels: [32]u8 = undefined;
        const dst = try PixelBuffer.init(pixels[0..PixelBuffer.len(config.native, 2, 2).?], config.native, 2, 2);
        _ = (try d.decodeFrame(dst, work[0..config.work_len])).?;
        for (values, 0..) |v, i| {
            const got = if (bits == 8)
                pixels[i]
            else
                std.mem.readInt(u16, pixels[2 * i ..][0..2], samples.native_endian);
            try testing.expectEqual(if (bits == 8) 255 - v else 65535 - v, got);
        }
        // To color by image.convert: 155 * 205 / 255 rounds to 125.
        r = .fixed(file);
        d = Decoder.init(&r, .{});
        var rgb: [12]u8 = undefined;
        _ = (try d.decodeFrame(try PixelBuffer.init(&rgb, .rgb8, 2, 2), work[0..config.work_len])).?;
        try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0, 255, 255, 125, 205, 205, 0, 0, 0 }, &rgb);
    }
}

test "pages are frames: the canvas holds the largest, and data behind needs a seeker" {
    const gpa = testing.allocator;
    var a: [6 * 3]u16 = undefined;
    for (&a, 0..) |*v, i| v.* = @intCast(10 + i);
    var b: [2 * 5]u16 = undefined;
    for (&b, 0..) |*v, i| v.* = @intCast(100 + i);
    const pages = [_]TestPage{
        .{ .width = 6, .height = 3, .spp = 1, .rows = 2, .pixels = &a },
        .{ .width = 2, .height = 5, .spp = 1, .compression = 5, .pixels = &b },
    };
    const file = try testFile(gpa, .little, false, &pages, false);
    defer gpa.free(file);
    try testDecode(file, &pages, true);

    // Without a seeker, the first page sets the config, and the second does
    // not fit it.
    var r: Io.Reader = .fixed(file);
    var d = Decoder.init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(.{ 6, 3, null }, .{ config.width, config.height, config.frame_count });
    var pixels: [6 * 3]u8 = undefined;
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    const dst = try PixelBuffer.init(&pixels, .gray8, 6, 3);
    _ = (try d.decodeFrame(dst, work)).?;
    // decodeFrameConfig reads the second page's IFD and finds the mismatch.
    try testing.expectError(error.PageMismatch, d.decodeFrameConfig());
    try testing.expectError(error.PageMismatch, d.decodeFrame(dst, work));

    // An IFD after its data.
    var behind = pages;
    behind[0].ifd_first = false;
    const file2 = try testFile(gpa, .big, true, &behind, false);
    defer gpa.free(file2);
    try testDecode(file2, &behind, true);
    r = .fixed(file2);
    d = Decoder.init(&r, .{});
    const config2 = try d.decodeConfig();
    const work2 = try gpa.alloc(u8, config2.work_len);
    defer gpa.free(work2);
    try testing.expectError(error.DataBehind, d.decodeFrame(dst, work2));

    // A chain that loops ends where it repeats.
    const file3 = try testFile(gpa, .little, false, &pages, true);
    defer gpa.free(file3);
    try testDecode(file3, &pages, true);
    r = .fixed(file3);
    d = Decoder.init(&r, .{ .seeker = .fixed(&r), .limits = .{ .max_frames = 2 } });
    try testing.expectEqual(2, (try d.decodeConfig()).frame_count);

    // Past max_frames the count is null, and the page past it fails when
    // reached.
    const three = [_]TestPage{ pages[0], pages[1], pages[0] };
    const file4 = try testFile(gpa, .little, false, &three, false);
    defer gpa.free(file4);
    r = .fixed(file4);
    d = Decoder.init(&r, .{ .seeker = .fixed(&r), .limits = .{ .max_frames = 2 } });
    const config4 = try d.decodeConfig();
    try testing.expectEqual(.{ 6, 5, null }, .{ config4.width, config4.height, config4.frame_count });
    var pixels4: [6 * 5]u8 = undefined;
    const work4 = try gpa.alloc(u8, config4.work_len);
    defer gpa.free(work4);
    const dst4 = try PixelBuffer.init(&pixels4, .gray8, 6, 5);
    _ = (try d.decodeFrame(dst4, work4)).?;
    _ = (try d.decodeFrame(dst4, work4)).?;
    try testing.expectError(error.TooManyFrames, d.decodeFrame(dst4, work4));
}
