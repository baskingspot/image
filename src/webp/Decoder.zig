//! A streaming WebP decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, and allocates nothing.
//!
//! Format: RFC 9649, the WebP container and the lossless bitstream, and
//! RFC 6386 for the lossy one. It decodes simple files and extended (VP8X)
//! still images, lossless or lossy, with a lossy image's ALPH chunk;
//! animations are `Unsupported` for now. ICCP, EXIF, and XMP chunks before
//! the image are reported in `Config.metadata`, and every one goes to the
//! blob sink as it passes; EXIF's orientation is read.
//!
//! As libwebp reads them: a still image's bitstream must match the VP8X
//! canvas, chunks before the image may come in any order (only the image
//! chunk ends them), and chunks after it are skipped, but the RIFF payload
//! must be all there, so a still image's `decodeFrame` reads to its end.
//! docs/slop/webp.md records these choices.

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
seen: packed struct { icc: bool = false, exif: bool = false, xmp: bool = false } = .{},
work_len: usize = 0,

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
};

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops at the end of the RIFF
/// payload.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the chunks before the image and the bitstream's header, or a
/// lossy image's ALPH chunk header, which comes first. The native format
/// of a lossless image is `bgra8`, the order its pixels are decoded in; of
/// a lossy one, `rgb8`, or `rgba8` with an ALPH chunk. Calling it again
/// returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHead() catch |e| return d.fail(e);
        d.state = .config;
    }
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

/// Decodes the image into `dst`, which must be the canvas's size, in any
/// format, using `work[0..work_len]`, and reads the rest of the RIFF
/// payload. Returns null after the image.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    try dst.check();
    if (dst.width != d.width or dst.height != d.height) return error.SizeMismatch;
    if (work.len < d.work_len) return error.WorkTooSmall;
    // The frame is opaque as the config says, even when an ALPH chunk
    // turns out to sit beside a lossless image whose header says otherwise.
    const is_opaque = !d.alpha_hint;
    d.image(dst, work) catch |e| return d.fail(e);
    d.state = .done;
    return .{ .width = d.width, .height = d.height, .is_opaque = is_opaque };
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
    if (flags & 0x02 != 0) return error.Unsupported;
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
    const b = try d.take(5);
    if (b[0] != 0x2f) return error.BadHeader;
    const v = std.mem.readInt(u32, b[1..5], .little);
    if (v >> 29 != 0) return error.BadHeader;
    d.width = (v & 0x3fff) + 1;
    d.height = ((v >> 14) & 0x3fff) + 1;
    d.alpha_hint = (v >> 28) & 1 == 1;
    try d.options.limits.checkSize(d.width, d.height);
    d.work_len = lossless.workLen(d.width, d.height, d.options.max_prefix_groups) orelse return error.ImageTooLarge;
    try d.options.limits.checkWork(d.work_len);
    d.image_left = c.size - 5;
    d.image_pad = c.size & 1;
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

    fn init(d: *const Decoder) ?LossyLayout {
        const w: u64 = d.width;
        // The partitions may run on past the VP8 chunk (`vp8.decode`'s
        // `after`), so they lie in what is left of the payload: after the
        // frame header, or after an ALPH chunk, less its padding and the
        // VP8 chunk and frame headers.
        const data_len: u64 = if (d.frame != null) d.image_left + d.riff_left else d.riff_left -| 19;
        var shared: u64 = vp8.workLen(d.width, d.height, data_len) orelse return null;
        var plane: u64 = 0;
        if (d.alph != null) {
            plane = std.mem.alignForward(u64, w * d.height, 8);
            shared = @max(shared, alpha.workLen(d.width, d.height, d.options.max_prefix_groups) orelse return null);
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

fn lossyWork(d: *Decoder) Error!void {
    const l = LossyLayout.init(d) orelse return error.ImageTooLarge;
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
    if (!before_image) return;
    switch (kind) {
        .icc => if (!d.seen.icc) {
            d.seen.icc = true;
            d.metadata.icc = b;
        },
        .exif => if (!d.seen.exif) {
            d.seen.exif = true;
            d.metadata.exif = b;
            if (exif.orientation(prefix[0..@min(c.size, prefix.len)])) |o| d.metadata.orientation = o;
        },
        .xmp => if (!d.seen.xmp) {
            d.seen.xmp = true;
            d.metadata.xmp = b;
        },
    }
}

/// Writes rows of ARGB into the canvas: as BGRA bytes, converted.
const Out = struct {
    dst: PixelBuffer,
    to_dst: Converter,

    fn row(context: *anyopaque, y: u32, argb: []u32) void {
        const o: *Out = @ptrCast(@alignCast(context));
        if (builtin.cpu.arch.endian() == .big) {
            for (argb) |*p| p.* = @byteSwap(p.*);
        }
        const bytes = std.mem.sliceAsBytes(argb);
        const out = o.dst.row(y);
        if (o.dst.format == .bgra8) @memcpy(out, bytes) else o.to_dst.run(out, bytes, argb.len);
    }
};

fn image(d: *Decoder, dst: PixelBuffer, work: []u8) Error!void {
    if (d.lossy) return d.lossyImage(dst, work);
    return d.losslessImage(dst, work);
}

fn losslessImage(d: *Decoder, dst: PixelBuffer, work: []u8) Error!void {
    var out: Out = .{ .dst = dst, .to_dst = .init(dst.format, .bgra8) };
    var br: lossless.BitReader = .init(d.reader, d.image_left);
    lossless.decode(&br, d.width, d.height, d.options.max_prefix_groups, false, work, .{
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
    try d.trailer();
}

fn lossyImage(d: *Decoder, dst: PixelBuffer, work: []u8) Error!void {
    const l = LossyLayout.init(d).?;
    const w: usize = d.width;
    const plane: []u8 = if (d.alph != null) work[l.plane..][0 .. w * d.height] else &.{};
    const shared = work[l.shared..l.total];
    if (d.alph) |first| {
        // The ALPH chunk, and the chunks after it up to the image. As
        // libwebp does, the last ALPH chunk counts, and a lossless image
        // ignores them.
        var alpha_err = try d.alphaChunk(first, plane, shared);
        while (true) {
            const n = try d.chunk(true);
            switch (n.tag) {
                tags.alph => alpha_err = try d.alphaChunk(n, plane, shared),
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
                    return d.losslessImage(dst, work);
                },
                tags.iccp, tags.exif, tags.xmp => try d.blob(n, false),
                else => try d.skip(n.size),
            }
            try d.skipPad(n.size);
        }
        if (alpha_err) |e| return e;
    }
    var out: LossyOut = .{
        .dst = dst,
        .native = d.native(),
        .to_dst = .init(dst.format, d.native()),
        .buf = work[0 .. 4 * w],
        .scratch = work[4 * w ..][0 .. 2 * w],
        .plane = if (d.alph != null) plane else null,
        .width = w,
    };
    const rest = try vp8.decode(d.reader, d.image_left, d.riff_left, d.frame.?, shared, .{
        .context = &out,
        .row = LossyOut.row,
    });
    d.pos += d.image_left - rest.unread;
    try d.skip(rest.unread);
    if (rest.over > 0) {
        // The last partition read on past its chunk, as libwebp lets it:
        // the chunks after it are gone, and only the rest of the payload
        // is skipped.
        d.pos += rest.over;
        try d.skip(d.riff_left -| rest.over);
        d.riff_left = 0;
        return;
    }
    try d.skipPad(@intCast(d.image_pad));
    try d.trailer();
}

/// Decodes an ALPH chunk into `plane`; returns why its data could not be
/// used, if it could not.
fn alphaChunk(d: *Decoder, c: Chunk, plane: []u8, work: []u8) Error!?Error {
    const r = try alpha.decode(d.reader, c.size, d.width, d.height, d.options.max_prefix_groups, plane, work);
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

    fn row(context: *anyopaque, y: u32, luma: []const u8, near: [2][]const u8, far: [2][]const u8) void {
        const o: *LossyOut = @ptrCast(@alignCast(context));
        const w = o.width;
        const alpha_row = if (o.plane) |p| p[y * w ..][0..w] else null;
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
    return config;
}

test "an extended lossless file: metadata, pixels, and truncation" {
    // A 3x2 bitstream written by hand: no transforms, no color cache, and
    // one group of simple codes. Green has two symbols, 200 then 10; the
    // smaller takes code 0, whatever order they are listed in.
    var bits: TestBits = .{};
    bits.put(0x2f, 8);
    bits.put(3 - 1, 14);
    bits.put(2 - 1, 14);
    bits.put(0, 1); // alpha hint
    bits.put(0, 3); // version
    bits.put(0, 1); // no transform
    bits.put(0, 1); // no color cache
    bits.put(0, 1); // no meta prefix codes
    bits.put(0b111, 3); // green: simple, two symbols, 8 bits
    bits.put(200, 8);
    bits.put(10, 8);
    for ([_]u32{ 0x40, 0x80, 0xff }) |v| { // red, blue, alpha
        bits.put(0b101, 3);
        bits.put(v, 8);
    }
    bits.put(0b001, 3); // distance: one 1-bit symbol, 0
    bits.put(0, 1);
    for ([_]u1{ 0, 1, 1, 0, 0, 1 }) |b| bits.put(b, 1);
    const vp8l = bits.slice();

    const exif_body = "II*\x00\x08\x00\x00\x00" ++ "\x01\x00" ++ "\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00";
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const Put = struct {
        fn chunk(wr: *Io.Writer, tag: *const [4]u8, body: []const u8) !void {
            try wr.writeAll(tag);
            try wr.writeInt(u32, @intCast(body.len), .little);
            try wr.writeAll(body);
            if (body.len & 1 == 1) try wr.writeByte(0);
        }
    };
    try w.writeAll("RIFF\x00\x00\x00\x00WEBP");
    try Put.chunk(&w, "VP8X", "\x2c\x00\x00\x00\x02\x00\x00\x01\x00\x00");
    const icc_at = w.end + 8;
    try Put.chunk(&w, "ICCP", "abcde");
    const exif_at = w.end + 8;
    try Put.chunk(&w, "EXIF", exif_body);
    try Put.chunk(&w, "VP8L", vp8l);
    try Put.chunk(&w, "XMP ", "<x/>");
    const file = w.buffered();
    std.mem.writeInt(u32, file[4..8], @intCast(file.len - 8), .little);

    var out: [3 * 2 * 4]u8 = undefined;
    const config = try testDecode(file, .rgba8, &out);
    try testing.expectEqual(3, config.width);
    try testing.expectEqual(2, config.height);
    try testing.expect(config.is_opaque);
    try testing.expectEqual(decode.Metadata{
        .orientation = .right_top,
        .icc = .{ .kind = .icc, .offset = icc_at, .len = 5 },
        .exif = .{ .kind = .exif, .offset = exif_at, .len = exif_body.len },
    }, config.metadata);
    var want: [3 * 2 * 4]u8 = undefined;
    for ([_]u8{ 10, 200, 200, 10, 10, 200 }, 0..) |g, i| want[i * 4 ..][0..4].* = .{ 0x40, g, 0x80, 0xff };
    try testing.expectEqualSlices(u8, &want, &out);

    for (0..file.len) |n| try testing.expectError(error.Truncated, testDecode(file[0..n], .rgba8, &out));

    // The bitstream must match the canvas.
    const copy = try testing.allocator.dupe(u8, file);
    defer testing.allocator.free(copy);
    copy[24] = 3;
    try testing.expectError(error.BadHeader, testDecode(copy, .rgba8, &out));
    // An animation is not decoded yet.
    @memcpy(copy, file);
    copy[20] |= 0x02;
    try testing.expectError(error.Unsupported, testDecode(copy, .rgba8, &out));
}
