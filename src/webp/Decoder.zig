//! A streaming WebP decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, and allocates nothing.
//!
//! Format: RFC 9649, the WebP container and the lossless bitstream, and
//! RFC 6386 for the lossy one. It decodes simple files and extended (VP8X)
//! images, lossless or lossy, with a lossy image's ALPH chunk, still or
//! animated. ICCP, EXIF, and XMP chunks before the image (or the first
//! frame) are reported in `Config.metadata`, and every one goes to the blob
//! sink as it passes; EXIF's orientation is read.
//!
//! As libwebp reads them: a still image's bitstream must match the VP8X
//! canvas, chunks before the image may come in any order (only the image
//! chunk ends them), and chunks after it are skipped, but the RIFF payload
//! must be all there, so a still image's `decodeFrame` reads to its end.
//! An animation's chunks follow libwebp's demuxer, and its frames are
//! composited as libwebp's animation decoder composites them, given a
//! caller that disposes of each frame's region to transparent black.
// Design notes and decisions: docs/slop/webp.md.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const exif = @import("../exif.zig");
const lossless = @import("lossless.zig");
const vp8 = @import("vp8.zig");
const alpha = @import("alpha.zig");
const yuv = @import("yuv.zig");

const Decoder = @This();

pub const Options = struct {
    limits: decode.Limits = .{},
    blob_sink: ?decode.BlobSink = null,
    /// Lets an animation frame's ALPH chunk be decoded at the size of the
    /// VP8 frame after it when that differs from the size its ANMF chunk
    /// gives, as libwebp decodes it (`AlphaBehind`); see `image.Seeker`.
    seeker: ?decode.Seeker = null,
    /// The most prefix code groups a lossless image may use, which sets
    /// how much work memory it needs (about 10 KiB a group); 0 is 2600,
    /// the most libwebp's encoder writes. An image that uses more is
    /// `Unsupported`.
    max_prefix_groups: u32 = 0,
};

pub const Error = decode.Error || error{
    /// A chunk's size runs past the RIFF payload, a VP8X chunk is not 10
    /// bytes, or the first chunk is not VP8, VP8L, or VP8X.
    BadChunk,
    /// A prefix code in a lossless bitstream is empty, incomplete, or
    /// oversubscribed, or reads past its alphabet.
    BadPrefixCode,
    /// A lossless bitstream breaks the specification otherwise: a
    /// transform used twice, a color cache size outside 1 to 11 bits, or a
    /// backward reference before the first pixel or past the last.
    BadLossless,
    /// A lossy bitstream is not a shown key frame, its start code or size
    /// is wrong, or its first partition is larger than its chunk.
    BadVp8,
    /// An ALPH chunk's header is malformed, or its raw plane is too short.
    BadAlpha,
    /// An animation frame's ALPH chunk is decoded at the size of the VP8
    /// frame after it, which is not the size its ANMF chunk gives, and
    /// `Options.seeker` is null, so the decoder cannot go back to it.
    AlphaBehind,
};

reader: *Io.Reader,
options: Options,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,
state: State = .start,
/// Bytes consumed from `reader`: where blobs start.
pos: u64 = 0,
/// Bytes of the RIFF payload not yet consumed.
riff_left: u64 = 0,
width: u32 = 0,
height: u32 = 0,
/// The lossless header's hint that some alpha is not 255, or for a lossy
/// image, an ALPH chunk.
alpha_hint: bool = false,
lossy: bool = false,
/// A lossy image's frame header, once read.
frame: ?vp8.FrameHeader = null,
/// An ALPH chunk whose header `decodeConfig` stopped at.
alph: ?Chunk = null,
/// Bytes of the image chunk after its header, and its padding byte.
image_left: u64 = 0,
image_pad: u64 = 0,
metadata: decode.Metadata = .{},
/// ICCP, EXIF, and XMP chunks after the image or between frames, the first
/// of each kind where none came before it.
late: decode.Metadata = .{},
seen: packed struct { icc: bool = false, exif: bool = false, xmp: bool = false } = .{},
work_len: usize = 0,
/// An animation's state, when the VP8X chunk announces one; `width` and
/// `height` are then the canvas's.
anim: ?Anim = null,
/// The next animation frame, read up to its pixels by `decodeFrameConfig`.
pending: ?Pending = null,

const Anim = struct {
    /// ANIM's background color as RGBA, and loop count.
    background: [4]u8,
    loops: u16,
    /// Frames returned so far.
    frames: u32 = 0,
    /// The last frame's region, whether it is disposed to the background,
    /// and whether it was a key frame: what decides, as in libwebp, how
    /// the next frame is composited.
    prev: Rect = .{},
    prev_dispose: bool = false,
    prev_key: bool = false,
};

const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

const State = enum { start, config, done };

/// The largest RIFF size libwebp accepts.
const max_riff = 0xffff_fff6;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

const tags = struct {
    const vp8 = fourcc("VP8 ");
    const vp8l = fourcc("VP8L");
    const vp8x = fourcc("VP8X");
    const alph = fourcc("ALPH");
    const iccp = fourcc("ICCP");
    const exif = fourcc("EXIF");
    const xmp = fourcc("XMP ");
    const anim = fourcc("ANIM");
    const anmf = fourcc("ANMF");
};

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops at the end of the RIFF
/// payload.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the chunks before the image and the bitstream's header, or a
/// lossy image's ALPH chunk header, which comes first; of an animation,
/// the chunks through ANIM. The native format of a lossless image is
/// `bgra8`, the order its pixels are decoded in; of a lossy one, `rgb8`, or
/// `rgba8` with an ALPH chunk; of an animation, `rgba8`, whose frame count
/// is not known until the end. Calling it again returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHead() catch |e| return d.fail(e);
        d.state = .config;
    }
    if (d.anim) |a| return .{
        .width = d.width,
        .height = d.height,
        .native = .rgba8,
        .loop_count = a.loops,
        .work_len = d.work_len,
        .background = a.background,
        .metadata = d.metadata,
    };
    return .{
        .width = d.width,
        .height = d.height,
        .native = d.native(),
        .frame_count = 1,
        .work_len = d.work_len,
        .is_opaque = !d.alpha_hint,
        .metadata = d.metadata,
    };
}

/// Decodes the next frame into its region of `dst`, which must be the
/// canvas's size, in any format, using `work[0..work_len]`. A still image
/// is one frame, after which the rest of the RIFF payload is read. An
/// animation's first frame clears the canvas outside its region to
/// transparent black, and a frame that blends (`Frame.blend` is
/// `src_over`) is composited over what `dst` holds: the caller applies
/// each frame's disposal before the next call. Returns null after the
/// last frame.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    try dst.check();
    if (dst.width != d.width or dst.height != d.height) return error.SizeMismatch;
    if (work.len < d.work_len) return error.WorkTooSmall;
    if (d.anim != null) {
        const p = d.pending orelse (d.nextHead() catch |e| return d.fail(e)) orelse return null;
        d.pending = null;
        return d.framePixels(p, dst, work) catch |e| return d.fail(e);
    }
    // The frame is opaque as the config says, even when an ALPH chunk
    // turns out to sit beside a lossless image whose header says otherwise.
    const is_opaque = !d.alpha_hint;
    d.image(dst, work) catch |e| return d.fail(e);
    d.state = .done;
    return .{ .width = d.width, .height = d.height, .is_opaque = is_opaque };
}

/// Sets in `config` the metadata the chunks after the image or the frames
/// held (`late`): `image.Decoder.finalConfig` calls this once
/// `decodeFrame` has returned null.
pub fn applyTrailer(d: *const Decoder, config: *decode.Config) void {
    if (d.late.icc) |b| config.metadata.icc = b;
    if (d.late.exif) |b| {
        config.metadata.exif = b;
        config.metadata.orientation = d.late.orientation;
    }
    if (d.late.xmp) |b| config.metadata.xmp = b;
}

/// The frame the next `decodeFrame` call returns, read up to its pixels,
/// or null where that call returns null. A still image's one frame is the
/// canvas; an animation's is read through its ANMF fields and its image
/// chunk's header.
pub fn decodeFrameConfig(d: *Decoder) Error!?decode.Frame {
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    if (d.anim == null) return .{ .width = d.width, .height = d.height, .is_opaque = !d.alpha_hint };
    if (d.pending == null) d.pending = d.nextHead() catch |e| return d.fail(e);
    return if (d.pending) |p| p.frame else null;
}

fn native(d: *const Decoder) PixelFormat {
    if (!d.lossy) return .bgra8;
    return if (d.alpha_hint) .rgba8 else .rgb8;
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn take(d: *Decoder, comptime n: usize) Error!*[n]u8 {
    const b = d.reader.takeArray(n) catch |e| return mapRead(e);
    d.pos += n;
    return b;
}

fn skip(d: *Decoder, n: u64) Error!void {
    d.reader.discardAll64(n) catch |e| return mapRead(e);
    d.pos += n;
}

const Chunk = struct { tag: u32, size: u32 };

/// A chunk's header, counted out of the RIFF payload with its body.
/// `padded` counts its padding byte too, as libwebp does for chunks after
/// VP8X; a simple file's image chunk may end the payload without one.
fn chunk(d: *Decoder, padded: bool) Error!Chunk {
    if (d.riff_left < 8) return error.BadChunk;
    const b = try d.take(8);
    const c: Chunk = .{
        .tag = std.mem.readInt(u32, b[0..4], .little),
        .size = std.mem.readInt(u32, b[4..8], .little),
    };
    d.riff_left -= 8;
    const need = @as(u64, c.size) + if (padded) c.size & 1 else 0;
    if (need > d.riff_left) return error.BadChunk;
    d.riff_left -= c.size;
    return c;
}

/// The padding byte after a chunk of odd size, if the payload has it.
fn skipPad(d: *Decoder, size: u32) Error!void {
    const pad = @min(size & 1, d.riff_left);
    try d.skip(pad);
    d.riff_left -= pad;
}

fn readHead(d: *Decoder) Error!void {
    const h = try d.take(12);
    if (!std.mem.eql(u8, h[0..4], "RIFF") or !std.mem.eql(u8, h[8..12], "WEBP")) return error.BadSignature;
    const size = std.mem.readInt(u32, h[4..8], .little);
    if (size < 12 or size > max_riff) return error.BadHeader;
    d.riff_left = size - 4;
    const first = try d.chunk(false);
    switch (first.tag) {
        tags.vp8l => try d.losslessHeader(first),
        tags.vp8 => try d.lossyHeader(first),
        tags.vp8x => try d.extended(first),
        else => return error.BadChunk,
    }
}

/// VP8X, and the chunks after it up to the image.
fn extended(d: *Decoder, c: Chunk) Error!void {
    if (c.size != 10) return error.BadChunk;
    const b = try d.take(10);
    const flags = b[0];
    const w = 1 + @as(u64, std.mem.readInt(u24, b[4..7], .little));
    const h = 1 + @as(u64, std.mem.readInt(u24, b[7..10], .little));
    if (w * h >= 1 << 32) return error.BadHeader;
    try d.options.limits.checkSize(@intCast(w), @intCast(h));
    if (flags & 0x02 != 0) {
        d.width = @intCast(w);
        d.height = @intCast(h);
        return d.animation(flags);
    }
    while (true) {
        const n = try d.chunk(true);
        switch (n.tag) {
            tags.vp8l => {
                try d.losslessHeader(n);
                if (d.width != w or d.height != h) return error.BadHeader;
                return;
            },
            tags.vp8 => {
                try d.lossyHeader(n);
                if (d.width != w or d.height != h) return error.BadHeader;
                return;
            },
            tags.alph => {
                // Its body needs work memory: decodeFrame reads it.
                d.alph = n;
                d.lossy = true;
                d.alpha_hint = true;
                d.width = @intCast(w);
                d.height = @intCast(h);
                try d.lossyWork();
                return;
            },
            tags.iccp, tags.exif, tags.xmp => try d.blob(n, true),
            else => try d.skip(n.size),
        }
        try d.skipPad(n.size);
    }
}

/// The 5-byte VP8L header: signature 0x2f, then the width and height less
/// one in 14 bits each, the alpha hint, and a 3-bit version, 0.
fn losslessHeader(d: *Decoder, c: Chunk) Error!void {
    if (c.size < 5) return error.BadHeader;
    const v = try losslessFields(try d.take(5));
    d.width = v.width;
    d.height = v.height;
    d.alpha_hint = v.alpha;
    try d.options.limits.checkSize(d.width, d.height);
    d.work_len = lossless.workLen(d.width, d.height, d.options.max_prefix_groups) orelse return error.ImageTooLarge;
    try d.options.limits.checkWork(d.work_len);
    d.image_left = c.size - 5;
    d.image_pad = c.size & 1;
}

fn losslessFields(b: *const [5]u8) Error!struct { width: u32, height: u32, alpha: bool } {
    if (b[0] != 0x2f) return error.BadHeader;
    const v = std.mem.readInt(u32, b[1..5], .little);
    if (v >> 29 != 0) return error.BadHeader;
    return .{ .width = (v & 0x3fff) + 1, .height = ((v >> 14) & 0x3fff) + 1, .alpha = (v >> 28) & 1 == 1 };
}

/// A VP8 chunk's 10-byte frame header.
fn lossyHeader(d: *Decoder, c: Chunk) Error!void {
    if (c.size < 10) return error.BadVp8;
    const fh = try vp8.FrameHeader.parse(try d.take(10), c.size);
    try d.options.limits.checkSize(fh.width, fh.height);
    d.lossy = true;
    d.frame = fh;
    d.width = fh.width;
    d.height = fh.height;
    d.image_left = c.size - 10;
    d.image_pad = c.size & 1;
    try d.lossyWork();
}

/// Where a lossy image's work memory goes: a row of output, the alpha
/// plane, and then the VP8 decoder's memory, which the ALPH chunk's
/// lossless decoder uses first.
const LossyLayout = struct {
    plane: usize,
    shared: usize,
    total: usize,

    /// For a `width` by `height` frame whose VP8 data is at most
    /// `data_len` bytes, with an alpha plane or not.
    fn init(width: u32, height: u32, data_len: u64, with_alpha: bool, groups: u32) ?LossyLayout {
        const w: u64 = width;
        var shared: u64 = vp8.workLen(width, height, data_len) orelse return null;
        var plane: u64 = 0;
        if (with_alpha) {
            plane = std.mem.alignForward(u64, w * height, 8);
            shared = @max(shared, alpha.workLen(width, height, groups) orelse return null);
        }
        // A row of pixels and two of upsampled chroma.
        const row = std.mem.alignForward(u64, 6 * w, 8);
        return .{
            .plane = std.math.cast(usize, row) orelse return null,
            .shared = std.math.cast(usize, row + plane) orelse return null,
            .total = std.math.cast(usize, row + plane + shared) orelse return null,
        };
    }
};

/// A still lossy image's layout. Its partitions may run on past the VP8
/// chunk (`vp8.decode`'s `after`), so they lie in what is left of the
/// payload: after the frame header, or after an ALPH chunk, less its
/// padding and the VP8 chunk and frame headers.
fn lossyLayout(d: *const Decoder) ?LossyLayout {
    const data_len: u64 = if (d.frame != null) d.image_left + d.riff_left else d.riff_left -| 19;
    return .init(d.width, d.height, data_len, d.alph != null, d.options.max_prefix_groups);
}

fn lossyWork(d: *Decoder) Error!void {
    const l = d.lossyLayout() orelse return error.ImageTooLarge;
    d.work_len = l.total;
    try d.options.limits.checkWork(d.work_len);
}

/// An ICCP, EXIF, or XMP chunk's body, passed to the blob sink and, for
/// the first of each before the image, reported in the metadata.
fn blob(d: *Decoder, c: Chunk, before_image: bool) Error!void {
    const kind: decode.Blob.Kind = switch (c.tag) {
        tags.iccp => .icc,
        tags.exif => .exif,
        else => .xmp,
    };
    const b: decode.Blob = .{ .kind = kind, .offset = d.pos, .len = c.size };
    var prefix: [4096]u8 = undefined;
    var done: u64 = 0;
    while (done < c.size) {
        const got = d.reader.peekGreedy(1) catch |e| return mapRead(e);
        const k: usize = @intCast(@min(got.len, c.size - done));
        if (d.options.blob_sink) |s| s.put(b, done, got[0..k]);
        if (done < prefix.len) {
            const m = @min(prefix.len - done, k);
            @memcpy(prefix[@intCast(done)..][0..m], got[0..m]);
        }
        d.reader.toss(k);
        d.pos += k;
        done += k;
    }
    // The first of each kind: before the image, in the config; after it,
    // for `applyTrailer`.
    const m = if (before_image) &d.metadata else &d.late;
    switch (kind) {
        .icc => if (!d.seen.icc) {
            d.seen.icc = true;
            m.icc = b;
        },
        .exif => if (!d.seen.exif) {
            d.seen.exif = true;
            m.exif = b;
            if (exif.orientation(prefix[0..@min(c.size, prefix.len)])) |o| m.orientation = o;
        },
        .xmp => if (!d.seen.xmp) {
            d.seen.xmp = true;
            m.xmp = b;
        },
    }
}

/// Writes rows of ARGB into the canvas: as BGRA bytes, converted, or
/// blended.
const Out = struct {
    dst: PixelBuffer,
    to_dst: Converter,
    blend: ?*Blender = null,

    fn row(context: *anyopaque, y: u32, argb: []u32) void {
        const o: *Out = @ptrCast(@alignCast(context));
        if (builtin.cpu.arch.endian() == .big) {
            for (argb) |*p| p.* = @byteSwap(p.*);
        }
        const bytes = std.mem.sliceAsBytes(argb);
        if (o.blend) |b| {
            Converter.init(.rgba8, .bgra8).run(b.src, bytes, argb.len);
            return b.put(y);
        }
        const out = o.dst.row(y);
        if (o.dst.format == .bgra8) @memcpy(out, bytes) else o.to_dst.run(out, bytes, argb.len);
    }
};

fn image(d: *Decoder, dst: PixelBuffer, work: []u8) Error!void {
    if (d.lossy) {
        try d.lossyImage(dst, work);
    } else {
        try d.losslessPixels(dst, work, d.width, d.height, null);
    }
    try d.trailer();
}

/// A `width` by `height` VP8L bitstream, its header read, into `dst`.
fn losslessPixels(d: *Decoder, dst: PixelBuffer, work: []u8, width: u32, height: u32, blend: ?*Blender) Error!void {
    var out: Out = .{ .dst = dst, .to_dst = .init(dst.format, .bgra8), .blend = blend };
    var br: lossless.BitReader = .init(d.reader, d.image_left);
    lossless.decode(&br, width, height, d.options.max_prefix_groups, false, work, .{
        .context = &out,
        .row = Out.row,
    }) catch |e| {
        // Zeros read past the end can look malformed: the end comes first.
        return if (br.count < br.pad) br.failed orelse error.Truncated else e;
    };
    // What the stream did not read of its chunk, and its padding.
    d.pos += d.image_left - br.left;
    try d.skip(br.left);
    try d.skipPad(@intCast(d.image_pad));
}

fn lossyImage(d: *Decoder, dst: PixelBuffer, work: []u8) Error!void {
    const l = d.lossyLayout().?;
    const w: usize = d.width;
    const plane: []u8 = if (d.alph != null) work[l.plane..][0 .. w * d.height] else &.{};
    const shared = work[l.shared..l.total];
    if (d.alph) |first| {
        // The ALPH chunk, and the chunks after it up to the image. As
        // libwebp does, the last ALPH chunk counts, and a lossless image
        // ignores them.
        var alpha_err = try d.alphaChunk(first, d.width, d.height, plane, shared);
        while (true) {
            const n = try d.chunk(true);
            switch (n.tag) {
                tags.alph => {
                    // alphaChunk skips its padding.
                    alpha_err = try d.alphaChunk(n, d.width, d.height, plane, shared);
                    continue;
                },
                tags.vp8 => {
                    const fw = d.width;
                    const fh = d.height;
                    try d.lossyHeader(n);
                    if (d.width != fw or d.height != fh) return error.BadHeader;
                    break;
                },
                tags.vp8l => {
                    const fw = d.width;
                    const fh = d.height;
                    try d.losslessHeader(n);
                    if (d.width != fw or d.height != fh) return error.BadHeader;
                    d.lossy = false;
                    return d.losslessPixels(dst, work, d.width, d.height, null);
                },
                tags.iccp, tags.exif, tags.xmp => try d.blob(n, false),
                else => try d.skip(n.size),
            }
            try d.skipPad(n.size);
        }
        if (alpha_err) |e| return e;
    }
    try d.lossyPixels(dst, work, l, d.frame.?, if (d.alph != null) plane else null, null);
}

/// A VP8 frame, its header read, into `dst`, with `plane` as its alpha.
fn lossyPixels(
    d: *Decoder,
    dst: PixelBuffer,
    work: []u8,
    l: LossyLayout,
    fh: vp8.FrameHeader,
    plane: ?[]const u8,
    blend: ?*Blender,
) Error!void {
    const w: usize = fh.width;
    const nat: PixelFormat = if (plane != null) .rgba8 else .rgb8;
    var out: LossyOut = .{
        .dst = dst,
        .native = nat,
        .to_dst = .init(dst.format, nat),
        .buf = work[0 .. 4 * w],
        .scratch = work[4 * w ..][0 .. 2 * w],
        .plane = plane,
        .width = w,
        .blend = blend,
    };
    // A still image's partitions may run on past the chunk.
    const after: ?u64 = if (d.anim == null) d.riff_left else null;
    const rest = try vp8.decode(d.reader, d.image_left, after, fh, work[l.shared..l.total], .{
        .context = &out,
        .row = LossyOut.row,
    });
    d.pos += d.image_left - rest.unread;
    try d.skip(rest.unread);
    if (rest.over > 0) {
        // A still image's last partition read on past its chunk, as
        // libwebp lets it: the chunks after it are gone, and only the rest
        // of the payload is skipped.
        d.pos += rest.over;
        try d.skip(d.riff_left -| rest.over);
        d.riff_left = 0;
        return;
    }
    try d.skipPad(@intCast(d.image_pad));
}

/// Decodes a `width` by `height` ALPH chunk into `plane`; returns why its
/// data could not be used, if it could not.
fn alphaChunk(d: *Decoder, c: Chunk, width: u32, height: u32, plane: []u8, work: []u8) Error!?Error {
    const r = try alpha.decode(d.reader, c.size, width, height, d.options.max_prefix_groups, plane, work);
    d.pos += c.size - r.unread;
    try d.skip(r.unread);
    try d.skipPad(c.size);
    return r.err;
}

/// Writes a lossy image's rows: from YUV straight into an RGB or BGR
/// destination, with or without alpha, and otherwise into `buf` in the
/// native format and converted.
const LossyOut = struct {
    dst: PixelBuffer,
    native: PixelFormat,
    to_dst: Converter,
    buf: []u8,
    scratch: []u8,
    plane: ?[]const u8,
    width: usize,
    blend: ?*Blender = null,

    fn row(context: *anyopaque, y: u32, luma: []const u8, near: [2][]const u8, far: [2][]const u8) void {
        const o: *LossyOut = @ptrCast(@alignCast(context));
        const w = o.width;
        const alpha_row = if (o.plane) |p| p[y * w ..][0..w] else null;
        if (o.blend) |b| {
            yuv.row(.rgba, b.src[0 .. 4 * w], luma, near, far, alpha_row, w, o.scratch);
            return b.put(y);
        }
        switch (o.dst.format) {
            inline .rgb8, .bgr8, .rgba8, .bgra8 => |f| {
                const layout: yuv.Layout = switch (f) {
                    .rgb8 => .rgb,
                    .bgr8 => .bgr,
                    .rgba8 => .rgba,
                    else => .bgra,
                };
                yuv.row(layout, o.dst.row(y), luma, near, far, alpha_row, w, o.scratch);
            },
            else => {
                const out = o.buf[0 .. w * o.native.bytesPerPixel()];
                if (o.plane != null) {
                    yuv.row(.rgba, out, luma, near, far, alpha_row, w, o.scratch);
                } else {
                    yuv.row(.rgb, out, luma, near, far, null, w, o.scratch);
                }
                o.to_dst.run(o.dst.row(y), out, w);
            },
        }
    }
};

// Animation. libwebp decodes an animation through its demuxer, which
// checks the whole file's chunks first; this decoder streams and checks
// each chunk as it comes, so a file that breaks the rules after its first
// frame fails at that frame rather than before the first.

/// The first `n` bytes of a chunk's body and padding: libwebp's demuxer
/// reads fixed fields from the padded body, so a body one byte short
/// lends its padding byte, which the chunk no longer has.
fn fields(d: *Decoder, c: Chunk, comptime n: usize) Error![n]u8 {
    const b = (try d.take(n)).*;
    if (c.size < n) {
        d.riff_left -= n - c.size;
    } else {
        try d.skip(c.size - n);
        try d.skipPad(c.size);
    }
    return b;
}

/// The chunks after VP8X through ANIM. As libwebp's demuxer reads them,
/// flags it does not define fail, an image chunk or frame before ANIM
/// fails, and the chunks before it may come in any order.
fn animation(d: *Decoder, flags: u8) Error!void {
    if (flags & ~@as(u8, 0x3e) != 0) return error.BadHeader;
    while (true) {
        const n = try d.chunk(true);
        switch (n.tag) {
            tags.anim => {
                if (n.size + (n.size & 1) < 6) return error.BadChunk;
                const b = try d.fields(n, 6);
                d.anim = .{
                    .background = .{ b[2], b[1], b[0], b[3] },
                    .loops = std.mem.readInt(u16, b[4..6], .little),
                };
                break;
            },
            tags.anmf, tags.alph, tags.vp8, tags.vp8l, tags.vp8x => return error.BadChunk,
            tags.iccp, tags.exif, tags.xmp => try d.blob(n, true),
            else => try d.skip(n.size),
        }
        try d.skipPad(n.size);
    }
    // Work for a frame as large as the canvas, lossless or lossy with
    // alpha, in what is left of the payload, after two rows to blend in.
    const groups = d.options.max_prefix_groups;
    const lossy = LossyLayout.init(d.width, d.height, d.riff_left, true, groups) orelse return error.ImageTooLarge;
    const ll = lossless.workLen(d.width, d.height, groups) orelse return error.ImageTooLarge;
    const total = @as(u64, blendLen(d.width)) + @max(lossy.total, ll);
    d.work_len = std.math.cast(usize, total) orelse return error.ImageTooLarge;
    try d.options.limits.checkWork(d.work_len);
}

fn blendLen(width: u32) usize {
    return std.mem.alignForward(usize, 8 * @as(usize, width), 8);
}

/// The chunks up to the next frame, and the frame's head; null at the end
/// of the payload.
fn nextHead(d: *Decoder) Error!?Pending {
    while (d.riff_left > 0) {
        const c = try d.chunk(true);
        switch (c.tag) {
            tags.anmf => if (try d.frameHead(c)) |p| return p,
            tags.alph, tags.vp8, tags.vp8l, tags.vp8x => return error.BadChunk,
            tags.iccp, tags.exif, tags.xmp => {
                try d.blob(c, false);
                try d.skipPad(c.size);
            },
            // A second ANIM, too.
            else => {
                try d.skip(c.size);
                try d.skipPad(c.size);
            },
        }
    }
    if (d.anim.?.frames == 0) return error.BadChunk;
    d.state = .done;
    return null;
}

/// The next chunk's header, left unread.
fn peekChunk(d: *Decoder) Error!Chunk {
    const b = d.reader.peekArray(8) catch |e| return mapRead(e);
    return .{
        .tag = std.mem.readInt(u32, b[0..4], .little),
        .size = std.mem.readInt(u32, b[4..8], .little),
    };
}

/// An animation frame read up to its first image chunk, which is left
/// unread: what `decodeFrameConfig` returns, and what drawing it needs.
const Pending = struct {
    frame: decode.Frame,
    /// Where the ANMF's body ends, in `riff_left`'s terms.
    end: u64,
    blend: bool,
    key: bool,
};

/// An ANMF chunk, its header read, up to its first image chunk. As
/// libwebp's demuxer reads one: its 16 bytes of fields, then an optional
/// ALPH chunk and a VP8 or VP8L chunk, which must lie in its body; whatever
/// else its body holds is read as the file's own chunks. A body that
/// starts with neither is no frame, and returns null. The frame's size is
/// its bitstream's, and so is its alpha plane's, as libwebp's demuxer and
/// decoder have them. An ALPH chunk comes before its VP8 chunk: with a
/// seeker, the VP8 frame's header is read past it and the reader moved
/// back; without one, the frame is taken to be the size the fields give,
/// and drawing it fails (`AlphaBehind`) when the VP8 frame is another.
fn frameHead(d: *Decoder, c: Chunk) Error!?Pending {
    const padded = @as(u64, c.size) + (c.size & 1);
    if (padded < 16) return error.BadChunk;
    // The body goes back to the payload, to be read chunk by chunk.
    d.riff_left += c.size;
    const b = (try d.take(16)).*;
    d.riff_left -= 16;
    const end = d.riff_left - (padded - 16);
    const x = 2 * @as(u64, std.mem.readInt(u24, b[0..3], .little));
    const y = 2 * @as(u64, std.mem.readInt(u24, b[3..6], .little));
    const fw = 1 + @as(u64, std.mem.readInt(u24, b[6..9], .little));
    const fh = 1 + @as(u64, std.mem.readInt(u24, b[9..12], .little));
    const duration = std.mem.readInt(u24, b[12..15], .little);
    const dispose = b[15] & 1 != 0;
    const no_blend = b[15] & 2 != 0;
    if (fw * fh >= 1 << 32) return error.BadChunk;
    if (d.riff_left < 8) return error.BadChunk;

    const a = &d.anim.?;
    const n = try d.peekChunk();
    if (n.tag != tags.alph and n.tag != tags.vp8 and n.tag != tags.vp8l) return null;
    try d.options.limits.checkFrames(@as(u64, a.frames) + 1);

    // The bitstream's size, and whether it has alpha, from its header,
    // peeked after the chunk's.
    var bw: u64 = fw;
    var bh: u64 = fh;
    var has_alpha = true;
    if (n.tag == tags.alph) {
        if (d.options.seeker) |s| {
            const at = d.pos;
            const alph_len = 8 + @as(u64, n.size) + (n.size & 1);
            if (alph_len + 8 > d.riff_left) return error.BadChunk;
            try d.skip(alph_len);
            const h = d.reader.peekArray(18) catch |e| return mapRead(e);
            const v_size = std.mem.readInt(u32, h[4..8], .little);
            if (std.mem.readInt(u32, h[0..4], .little) != tags.vp8) return error.BadChunk;
            const need = alph_len + 8 + v_size + (v_size & 1);
            if (need > d.riff_left or d.riff_left - need < end) return error.BadChunk;
            if (v_size < 10) return error.BadVp8;
            const v = try vp8.FrameHeader.parse(h[8..18], v_size);
            bw = v.width;
            bh = v.height;
            try s.seek(s.context, at);
            d.pos = at;
        } else if (fw > d.width or fh > d.height) return error.BadHeader;
    } else {
        const need = 8 + @as(u64, n.size) + (n.size & 1);
        if (need > d.riff_left or d.riff_left - need < end) return error.BadChunk;
        if (n.tag == tags.vp8) {
            if (n.size < 10) return error.BadVp8;
            const h = d.reader.peekArray(18) catch |e| return mapRead(e);
            const v = try vp8.FrameHeader.parse(h[8..18], n.size);
            bw = v.width;
            bh = v.height;
            has_alpha = false;
        } else {
            if (n.size < 5) return error.BadHeader;
            const h = d.reader.peekArray(13) catch |e| return mapRead(e);
            const v = try losslessFields(h[8..13]);
            bw = v.width;
            bh = v.height;
            has_alpha = v.alpha;
        }
    }
    if (x + bw > d.width or y + bh > d.height) return error.BadHeader;
    const full = bw == d.width and bh == d.height;

    // libwebp's animation decoder starts a key frame from a transparent
    // canvas and draws it without blending; the caller's canvas is
    // transparent there already if it disposes of frames as asked.
    const key = a.frames == 0 or ((!has_alpha or no_blend) and full) or
        (a.prev_dispose and ((a.prev.w == d.width and a.prev.h == d.height) or a.prev_key));
    const blend = !key and !no_blend;
    return .{
        .frame = .{
            .index = a.frames,
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(bw),
            .height = @intCast(bh),
            .duration = @as(u64, duration) * (decode.flicks_per_second / 1000),
            .disposal = if (dispose) .background else .none,
            .blend = if (blend) .src_over else .src,
            .is_opaque = !has_alpha,
        },
        .end = end,
        .blend = blend,
        .key = key,
    };
}

/// Draws the frame `frameHead` read up to its image chunks.
fn framePixels(d: *Decoder, p: Pending, dst: PixelBuffer, work: []u8) Error!decode.Frame {
    const a = &d.anim.?;
    const f = p.frame;
    const frame_work = work[blendLen(d.width)..];
    var n = try d.chunk(true);
    var plane: ?[]u8 = null;
    var layout: LossyLayout = undefined;
    if (n.tag == tags.alph) {
        // The plane is decoded now, at the frame's size.
        layout = LossyLayout.init(f.width, f.height, d.riff_left, true, d.options.max_prefix_groups).?;
        const pl = frame_work[layout.plane..][0 .. @as(usize, f.width) * f.height];
        if (try d.alphaChunk(n, f.width, f.height, pl, frame_work[layout.shared..layout.total])) |e| return e;
        plane = pl;
        if (d.riff_left < 8) return error.BadChunk;
        if ((try d.peekChunk()).tag != tags.vp8) return error.BadChunk;
        n = try d.chunk(true);
    }
    if (d.riff_left < p.end) return error.BadChunk;

    var vp8_header: vp8.FrameHeader = undefined;
    if (n.tag == tags.vp8) {
        if (n.size < 10) return error.BadVp8;
        vp8_header = try vp8.FrameHeader.parse(try d.take(10), n.size);
        // Only a frame read without a seeker can differ (`frameHead`).
        if (vp8_header.width != f.width or vp8_header.height != f.height) return error.AlphaBehind;
        d.image_left = n.size - 10;
    } else {
        _ = try d.take(5);
        d.image_left = n.size - 5;
    }
    // libwebp hands a frame's decoder its chunk with the padding byte, so
    // a bitstream may read it.
    d.image_left += n.size & 1;
    d.riff_left -= n.size & 1;
    d.image_pad = 0;
    const rect: Rect = .{ .x = f.x, .y = f.y, .w = f.width, .h = f.height };

    if (a.frames == 0 and !(f.width == d.width and f.height == d.height)) clearCanvas(dst);
    const region = dst.sub(rect.x, rect.y, rect.w, rect.h);
    var blender: Blender = undefined;
    if (p.blend) {
        const row = 4 * @as(usize, d.width);
        blender = .{
            .region = region,
            .src = work[0..row],
            .canvas = work[row..][0..row],
            .from_rgba = .init(region.format, .rgba8),
            .to_rgba = .init(.rgba8, region.format),
        };
        // Where the last frame was disposed of, libwebp copies rather
        // than blends: its region is transparent.
        if (a.prev_dispose) blender.keep = intersect(a.prev, rect);
    }
    const bp: ?*Blender = if (p.blend) &blender else null;
    if (n.tag == tags.vp8) {
        const groups = d.options.max_prefix_groups;
        if (plane == null) layout = LossyLayout.init(f.width, f.height, d.image_left, false, groups).?;
        try d.lossyPixels(region, frame_work, layout, vp8_header, plane, bp);
    } else {
        try d.losslessPixels(region, frame_work, f.width, f.height, bp);
    }

    a.frames += 1;
    a.prev = rect;
    a.prev_dispose = f.disposal == .background;
    a.prev_key = p.key;
    return f;
}

/// `r` in `frame`'s coordinates, clipped to it.
fn intersect(r: Rect, frame: Rect) Rect {
    const x0 = @max(r.x, frame.x);
    const y0 = @max(r.y, frame.y);
    const x1 = @min(r.x + r.w, frame.x + frame.w);
    const y1 = @min(r.y + r.h, frame.y + frame.h);
    if (x0 >= x1 or y0 >= y1) return .{};
    return .{ .x = x0 - frame.x, .y = y0 - frame.y, .w = x1 - x0, .h = y1 - y0 };
}

/// Fills `dst` with transparent black in its format.
fn clearCanvas(dst: PixelBuffer) void {
    const bpp = dst.format.bytesPerPixel();
    const zero: [16]u8 = @splat(0);
    var px: [16]u8 = undefined;
    Converter.init(dst.format, .rgba8).run(px[0..bpp], &zero, 1);
    for (0..dst.height) |y| {
        const row = dst.row(@intCast(y));
        var at: usize = 0;
        while (at < row.len) : (at += bpp) @memcpy(row[at..][0..bpp], px[0..bpp]);
    }
}

/// Composites a frame's rows, as RGBA8, over its region of the canvas.
const Blender = struct {
    region: PixelBuffer,
    /// The frame's row, written by the bitstream's sink.
    src: []u8,
    /// The canvas's row as RGBA8, when the canvas is in another format.
    canvas: []u8,
    from_rgba: Converter,
    to_rgba: Converter,
    /// Where the frame's pixels are copied rather than blended, in its
    /// coordinates.
    keep: Rect = .{},

    fn put(b: *Blender, y: u32) void {
        const w = b.region.width;
        const out = b.region.row(y);
        const c = if (b.region.format == .rgba8) out else b.canvas[0 .. 4 * @as(usize, w)];
        if (b.region.format != .rgba8) b.to_rgba.run(c, out, w);
        const in_keep = y >= b.keep.y and y < b.keep.y + b.keep.h;
        for (0..w) |x| {
            const s = b.src[4 * x ..][0..4];
            const px = c[4 * x ..][0..4];
            if (in_keep and x >= b.keep.x and x < b.keep.x + b.keep.w) {
                px.* = s.*;
            } else {
                blendPixel(px, s.*);
            }
        }
        if (b.region.format != .rgba8) b.from_rgba.run(out, c, w);
    }
};

/// `src` over `dst`, straight RGBA: RFC 9649's blend, rounded as
/// libwebp's animation decoder rounds it (matched to its output). An
/// opaque pixel replaces, and a transparent one leaves `dst` alone.
fn blendPixel(dst: *[4]u8, src: [4]u8) void {
    const sa: u32 = src[3];
    if (sa == 255) {
        dst.* = src;
        return;
    }
    if (sa == 0) return;
    const dfa = (@as(u32, dst[3]) * (256 - sa)) >> 8;
    const ba = sa + dfa;
    const scale = (1 << 24) / ba;
    for (0..3) |i| {
        dst[i] = @intCast(((src[i] * sa + dst[i] * dfa) * scale) >> 24);
    }
    dst[3] = @intCast(ba);
}

/// The chunks after the image, to the end of the RIFF payload: metadata
/// goes to the blob sink, and the rest is skipped. A chunk that runs past
/// the payload ends the walk, and the payload's last bytes are skipped.
fn trailer(d: *Decoder) Error!void {
    while (d.riff_left >= 8) {
        const b = try d.take(8);
        d.riff_left -= 8;
        const c: Chunk = .{
            .tag = std.mem.readInt(u32, b[0..4], .little),
            .size = std.mem.readInt(u32, b[4..8], .little),
        };
        if (c.size > d.riff_left) break;
        d.riff_left -= c.size;
        switch (c.tag) {
            tags.iccp, tags.exif, tags.xmp => try d.blob(c, false),
            else => try d.skip(c.size),
        }
        try d.skipPad(c.size);
    }
    try d.skip(d.riff_left);
    d.riff_left = 0;
}

/// Bits written least significant first, as a lossless bitstream holds them.
const TestBits = struct {
    bytes: [64]u8 = @splat(0),
    n: usize = 0,
    fn put(t: *TestBits, v: u32, bits: u5) void {
        for (0..bits) |i| {
            t.bytes[t.n / 8] |= @as(u8, @intCast((v >> @intCast(i)) & 1)) << @intCast(t.n % 8);
            t.n += 1;
        }
    }
    fn slice(t: *const TestBits) []const u8 {
        return t.bytes[0 .. (t.n + 7) / 8];
    }
};

fn testDecode(file: []const u8, format: PixelFormat, out: []u8) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    const work = try testing.allocator.alloc(u8, config.work_len);
    defer testing.allocator.free(work);
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    _ = (try d.decodeFrame(dst, work)) orelse return error.NoFrame;
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    try testing.expectEqual(0, r.bufferedLen());
    // With what followed the image, as `image.Decoder.finalConfig` has it.
    var final = config;
    d.applyTrailer(&final);
    return final;
}

/// A 3x2 lossless bitstream written by hand: no transforms, no color
/// cache, and one group of simple codes. Green has two symbols, 200 then
/// 10; the smaller takes code 0, whatever order they are listed in. Red is
/// 0x40, blue 0x80, and alpha `a`.
fn testLossless(bits: *TestBits, a: u8) []const u8 {
    bits.put(0x2f, 8);
    bits.put(3 - 1, 14);
    bits.put(2 - 1, 14);
    bits.put(@intFromBool(a != 0xff), 1); // alpha hint
    bits.put(0, 3); // version
    bits.put(0, 1); // no transform
    bits.put(0, 1); // no color cache
    bits.put(0, 1); // no meta prefix codes
    bits.put(0b111, 3); // green: simple, two symbols, 8 bits
    bits.put(200, 8);
    bits.put(10, 8);
    for ([_]u32{ 0x40, 0x80, a }) |v| { // red, blue, alpha
        bits.put(0b101, 3);
        bits.put(v, 8);
    }
    bits.put(0b001, 3); // distance: one 1-bit symbol, 0
    bits.put(0, 1);
    for ([_]u1{ 0, 1, 1, 0, 0, 1 }) |b| bits.put(b, 1);
    return bits.slice();
}

/// testLossless's greens, in raster order.
const test_greens = [6]u8{ 10, 200, 200, 10, 10, 200 };

const TestChunk = struct {
    fn put(wr: *Io.Writer, tag: *const [4]u8, body: []const u8) !void {
        try wr.writeAll(tag);
        try wr.writeInt(u32, @intCast(body.len), .little);
        try wr.writeAll(body);
        if (body.len & 1 == 1) try wr.writeByte(0);
    }
};

test "an extended lossless file: metadata, pixels, and truncation" {
    var bits: TestBits = .{};
    const vp8l = testLossless(&bits, 0xff);

    const exif_body = "II*\x00\x08\x00\x00\x00" ++ "\x01\x00" ++ "\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00";
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const Put = struct {
        const chunk = TestChunk.put;
    };
    try w.writeAll("RIFF\x00\x00\x00\x00WEBP");
    try Put.chunk(&w, "VP8X", "\x2c\x00\x00\x00\x02\x00\x00\x01\x00\x00");
    const icc_at = w.end + 8;
    try Put.chunk(&w, "ICCP", "abcde");
    const exif_at = w.end + 8;
    try Put.chunk(&w, "EXIF", exif_body);
    try Put.chunk(&w, "VP8L", vp8l);
    const xmp_at = w.end + 8;
    try Put.chunk(&w, "XMP ", "<x/>");
    const file = w.buffered();
    std.mem.writeInt(u32, file[4..8], @intCast(file.len - 8), .little);

    var out: [3 * 2 * 4]u8 = undefined;
    const config = try testDecode(file, .rgba8, &out);
    try testing.expectEqual(3, config.width);
    try testing.expectEqual(2, config.height);
    try testing.expect(config.is_opaque);
    // The XMP chunk after the image is in the final config.
    try testing.expectEqual(decode.Metadata{
        .orientation = .right_top,
        .icc = .{ .kind = .icc, .offset = icc_at, .len = 5 },
        .exif = .{ .kind = .exif, .offset = exif_at, .len = exif_body.len },
        .xmp = .{ .kind = .xmp, .offset = xmp_at, .len = 4 },
    }, config.metadata);
    var want: [3 * 2 * 4]u8 = undefined;
    for (test_greens, 0..) |g, i| want[i * 4 ..][0..4].* = .{ 0x40, g, 0x80, 0xff };
    try testing.expectEqualSlices(u8, &want, &out);

    for (0..file.len) |n| try testing.expectError(error.Truncated, testDecode(file[0..n], .rgba8, &out));

    // The bitstream must match the canvas.
    const copy = try testing.allocator.dupe(u8, file);
    defer testing.allocator.free(copy);
    copy[24] = 3;
    try testing.expectError(error.BadHeader, testDecode(copy, .rgba8, &out));
    // An animation needs ANIM before anything else that bears an image.
    @memcpy(copy, file);
    copy[20] |= 0x02;
    try testing.expectError(error.BadChunk, testDecode(copy, .rgba8, &out));
}

/// A 2x2 VP8 frame of 0x4080c0, as cwebp writes it at quality 75.
const test_vp8 = "\xd0\x01\x00\x9d\x01\x2a\x02\x00\x02\x00\x02\x00\x34\x25\xa0\x02\x74\xba\x01\xf8\x00" ++
    "\x03\xb0\x00\xfe\xdf\x80\x3f\xf1\xbb\x71\x86\xfc\x17\x7f\xe1\x57\xc6\xe4\x2c\x28\x00";

/// test_vp8's pixels under the alpha values 10, 20, 30, and 40.
const test_vp8_rgba = [16]u8{
    0x41, 0x80, 0xbf, 0x0a, 0x41, 0x80, 0xbf, 0x14,
    0x41, 0x80, 0xbf, 0x1e, 0x41, 0x80, 0xbf, 0x28,
};

test "a lossy file with two ALPH chunks of odd size" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll("RIFF\x00\x00\x00\x00WEBP");
    try TestChunk.put(&w, "VP8X", "\x10\x00\x00\x00\x01\x00\x00\x01\x00\x00");
    // Raw and unfiltered; each is followed by its padding byte, and the
    // last one counts.
    try TestChunk.put(&w, "ALPH", "\x00\x01\x02\x03\x04");
    try TestChunk.put(&w, "ALPH", "\x00\x0a\x14\x1e\x28");
    try TestChunk.put(&w, "VP8 ", test_vp8);
    const file = w.buffered();
    std.mem.writeInt(u32, file[4..8], @intCast(file.len - 8), .little);

    var out: [2 * 2 * 4]u8 = undefined;
    _ = try testDecode(file, .rgba8, &out);
    try testing.expectEqualSlices(u8, &test_vp8_rgba, &out);
}

test "an animation frame whose alpha is another size than its ANMF says" {
    // The ANMF says 1x1; its VP8 frame, and so its alpha plane, is 2x2.
    var buf: [160]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll("RIFF\x00\x00\x00\x00WEBP");
    try TestChunk.put(&w, "VP8X", "\x12\x00\x00\x00\x01\x00\x00\x01\x00\x00");
    try TestChunk.put(&w, "ANIM", "\x00\x00\x00\x00\x00\x00");
    var body: [96]u8 = undefined;
    var bw: Io.Writer = .fixed(&body);
    try bw.writeAll(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, 0, 0, 0 });
    try TestChunk.put(&bw, "ALPH", "\x00\x0a\x14\x1e\x28");
    try TestChunk.put(&bw, "VP8 ", test_vp8);
    try TestChunk.put(&w, "ANMF", bw.buffered());
    const file = w.buffered();
    std.mem.writeInt(u32, file[4..8], @intCast(file.len - 8), .little);

    var out: [2 * 2 * 4]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgba8, 2, 2);
    for ([_]bool{ true, false }) |seeking| {
        var r: Io.Reader = .fixed(file);
        var d: Decoder = .init(&r, .{ .seeker = if (seeking) .fixed(&r) else null });
        const config = try d.decodeConfig();
        const work = try testing.allocator.alloc(u8, config.work_len);
        defer testing.allocator.free(work);
        const announced = (try d.decodeFrameConfig()).?;
        if (seeking) {
            // libwebp's size: the bitstream's.
            try testing.expectEqual(2, announced.width);
            try testing.expectEqual(announced, (try d.decodeFrame(dst, work)).?);
            try testing.expectEqualSlices(u8, &test_vp8_rgba, &out);
            try testing.expectEqual(null, try d.decodeFrame(dst, work));
        } else {
            try testing.expectEqual(1, announced.width);
            try testing.expectError(error.AlphaBehind, d.decodeFrame(dst, work));
        }
    }
}

test "an animation: regions, blending, and the previous frame's disposal" {
    // A 6x2 canvas and three 3x2 frames: opaque at (0, 0); half alpha at
    // (2, 0), blended, then disposed to the background; and alpha 0xc0 at
    // (0, 0), blended where the second frame was not.
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll("RIFF\x00\x00\x00\x00WEBP");
    try TestChunk.put(&w, "VP8X", "\x12\x00\x00\x00\x05\x00\x00\x01\x00\x00");
    try TestChunk.put(&w, "ANIM", "\x10\x20\x30\x40\x03\x00");
    const frames = [_]struct { x: u8, alpha: u8, flags: u8 }{
        .{ .x = 0, .alpha = 0xff, .flags = 0x02 },
        .{ .x = 1, .alpha = 0x80, .flags = 0x01 },
        .{ .x = 0, .alpha = 0xc0, .flags = 0x00 },
    };
    for (frames) |f| {
        var bits: TestBits = .{};
        var body: [96]u8 = undefined;
        var bw: Io.Writer = .fixed(&body);
        // X and Y in units of two, the size less one, 50 ms, the flags.
        try bw.writeAll(&.{ f.x, 0, 0, 0, 0, 0, 2, 0, 0, 1, 0, 0, 50, 0, 0, f.flags });
        try TestChunk.put(&bw, "VP8L", testLossless(&bits, f.alpha));
        try TestChunk.put(&w, "ANMF", bw.buffered());
    }
    try TestChunk.put(&w, "XMP ", "<x/>");
    const file = w.buffered();
    std.mem.writeInt(u32, file[4..8], @intCast(file.len - 8), .little);

    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(6, config.width);
    try testing.expectEqual(.rgba8, config.native);
    try testing.expectEqual(null, config.frame_count);
    try testing.expectEqual(3, config.loop_count);
    try testing.expectEqual([4]u8{ 0x30, 0x20, 0x10, 0x40 }, config.background);
    const work = try testing.allocator.alloc(u8, config.work_len);
    defer testing.allocator.free(work);
    var px: [6 * 2 * 4]u8 = @splat(0xaa);
    const dst = try PixelBuffer.init(&px, .rgba8, 6, 2);
    var want: [6 * 2 * 4]u8 = undefined;
    const greens = test_greens;

    // The first frame clears the rest of the canvas.
    const f0 = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(decode.Frame{ .width = 3, .height = 2, .duration = 50 * 705_600, .is_opaque = true }, f0);
    @memset(&want, 0);
    for (0..2) |y| for (0..3) |x| {
        want[(y * 6 + x) * 4 ..][0..4].* = .{ 0x40, greens[y * 3 + x], 0x80, 0xff };
    };
    try testing.expectEqualSlices(u8, &want, &px);

    // Over the first frame's column, libwebp's rounding: (64 * 128 + 64 *
    // 127) * (2^24 / 255) >> 24 is 63, and green 10 over 200 is 104. Over
    // transparent pixels, the frame's own. decodeFrameConfig reports the
    // frame before it is drawn, however often it is asked.
    const c1 = (try d.decodeFrameConfig()).?;
    try testing.expectEqual(c1, (try d.decodeFrameConfig()).?);
    const f1 = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(c1, f1);
    try testing.expectEqual(decode.Frame{
        .index = 1,
        .x = 2,
        .width = 3,
        .height = 2,
        .duration = 50 * 705_600,
        .disposal = .background,
        .blend = .src_over,
    }, f1);
    for (0..2) |y| {
        want[(y * 6 + 2) * 4 ..][0..4].* = .{ 63, 104, 127, 0xff };
        for (1..3) |x| want[(y * 6 + 2 + x) * 4 ..][0..4].* = .{ 0x40, greens[y * 3 + x], 0x80, 0x80 };
    }
    try testing.expectEqualSlices(u8, &want, &px);

    // The caller disposes of the second frame's region. Where it was, the
    // third frame is copied; elsewhere, blended over the first.
    for (0..2) |y| @memset(px[(y * 6 + 2) * 4 ..][0..12], 0);
    const c2 = (try d.decodeFrameConfig()).?;
    const f2 = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(c2, f2);
    try testing.expectEqual(decode.Frame{
        .index = 2,
        .width = 3,
        .height = 2,
        .duration = 50 * 705_600,
        .blend = .src_over,
    }, f2);
    for (0..2) |y| {
        for (0..2) |x| want[(y * 6 + x) * 4 ..][0..4].* = .{ 63, greens[y * 3 + x] - 1, 127, 0xff };
        want[(y * 6 + 2) * 4 ..][0..4].* = .{ 0x40, greens[y * 3 + 2], 0x80, 0xc0 };
        @memset(want[(y * 6 + 3) * 4 ..][0..12], 0);
    }
    try testing.expectEqualSlices(u8, &want, &px);
    try testing.expectEqual(null, try d.decodeFrameConfig());
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    try testing.expectEqual(0, r.bufferedLen());

    // Cut short anywhere, it fails, after the frames it holds.
    for (0..file.len) |n| {
        var cut: Io.Reader = .fixed(file[0..n]);
        var c: Decoder = .init(&cut, .{});
        if (c.decodeConfig()) |_| {
            while (c.decodeFrame(dst, work) catch null) |_| {}
            try testing.expect(c.err != null);
        } else |_| {}
    }
}
