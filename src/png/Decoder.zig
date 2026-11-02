//! A streaming PNG and APNG decoder: reads from a `std.Io.Reader`, writes
//! any `PixelFormat`, and allocates nothing. It needs `Config.work_len`
//! bytes of work memory: the 64 KiB inflate window, an 8 KiB staging buffer
//! for the image data, and two rows.
//!
//! Format: the PNG specification, third edition (W3C, 2025), which includes
//! APNG. Every color type, bit depth, and Adam7 interlacing; tRNS becomes an
//! alpha channel in the native format. gAMA, cHRM, sRGB, pHYs, iCCP, eXIf,
//! and bKGD are reported in `Config` and never applied; iCCP and eXIf bytes
//! go to the blob sink as they pass.
//!
//! Strict, as Wuffs is: the CRC-32 of every critical chunk (IHDR, PLTE,
//! IDAT, IEND) is checked, and so is the image data's Adler-32, unless
//! `Options.ignore_checksums` is set. Ancillary chunks' CRCs are not
//! checked, as in Wuffs; libpng and libspng accept a bad one too. The image
//! data must decompress to exactly the rows the image needs, with nothing
//! after the zlib stream in its chunks; an interlaced frame one row tall is
//! the exception, as in Wuffs: data after its last row is skipped. Chunks
//! that shape the pixels (IHDR, PLTE, tRNS, IDAT, IEND, acTL, fcTL, fdAT)
//! must follow the specification; a chunk that cannot change the pixels (a
//! metadata chunk with a malformed body, a tRNS beside an alpha channel) is
//! ignored, as the specification allows, and the first of a duplicate
//! wins. An unknown critical chunk is
//! `Unsupported`. An out-of-range palette index is opaque black, as the
//! specification requires. docs/slop/png.md records these choices.
//!
//! APNG: the frames are the animation's. A default image outside the
//! animation (no fcTL before IDAT) is skipped, as APNG decoders are to do.
//! `decodeFrame` writes each frame into its region of the caller's canvas:
//! blend-over frames are composited onto what the canvas holds, and the
//! first frame clears the canvas outside its region to transparent black.
//! Disposal is the caller's: `Frame.disposal` says what to do with the
//! region before the next call. A still image's IEND is read by the second
//! `decodeFrame`, which returns null.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zlib = @import("compress").zlib;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const convert = @import("../convert.zig");
const Converter = convert.Converter;
const exif = @import("../exif.zig");
const crc32 = @import("crc32.zig");
const filter = @import("filter.zig");

const Decoder = @This();

pub const Options = struct {
    limits: decode.Limits = .{},
    blob_sink: ?decode.BlobSink = null,
    /// Skip the CRC-32 of critical chunks and the image data's Adler-32,
    /// as Wuffs's IGNORE_CHECKSUM quirk does, so a file whose only fault is
    /// a checksum decodes. Off by default.
    ignore_checksums: bool = false,
};

pub const Error = decode.Error || error{
    /// A critical chunk's CRC-32 does not match its type and data (not
    /// with `Options.ignore_checksums`).
    BadCrc,
    /// A chunk's length, contents, or position breaks the specification:
    /// a missing or misplaced PLTE or IDAT, a malformed
    /// tRNS, acTL, fcTL, or fdAT, out-of-order sequence numbers, or a
    /// frame count that disagrees with acTL.
    BadChunk,
    /// A row's filter type is not 0 to 4.
    BadFilter,
    /// The image data is not a valid zlib stream, or names a preset
    /// dictionary.
    BadZlib,
    /// The image data's Adler-32 does not match (not with
    /// `Options.ignore_checksums`).
    BadChecksum,
    /// The image data ends before the frame's last row.
    NotEnoughData,
    /// The image data holds more than the frame's rows, or its chunks hold
    /// bytes after the zlib stream. Not for an interlaced frame one row
    /// tall, whose data past its last row is skipped, as in Wuffs.
    TooMuchData,
};

reader: *Io.Reader,
options: Options,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,
state: State = .start,
/// Bytes consumed from `reader`: where blobs start.
pos: u64 = 0,
/// The CRC register of the chunk being read, whether it is checked (only
/// critical chunks' are), and the bytes of its data not yet read.
crc: u32 = 0,
check_crc: bool = false,
left: u32 = 0,
ihdr: Ihdr = undefined,
/// Straight RGBA with tRNS applied; opaque black past `palette_len`.
palette: [256][4]u8 = undefined,
palette_len: u16 = 0,
/// tRNS for gray and truecolor: the transparent sample values, masked to
/// the bit depth, or `no_key`, which no sample equals.
key: [3]u32 = @splat(no_key),
has_trns: bool = false,
seen: Seen = .{},
metadata: decode.Metadata = .{},
background: ?[4]u8 = null,
work_len: usize = 0,
/// APNG: whether acTL came before IDAT, and its counts.
animated: bool = false,
num_frames: u32 = 0,
num_plays: u32 = 0,
/// The next sequence number fcTL and fdAT must carry.
seq: u32 = 0,
/// fcTL chunks read, and frames decoded.
controls: u32 = 0,
frames: u32 = 0,
/// An fcTL read but not yet decoded, and one seen before IDAT, kept raw
/// until IDAT shows whether acTL made the file animated.
fctl: ?FrameControl = null,
early_fctl: ?[26]u8 = null,
/// Whether IDAT is the default image outside the animation, never decoded.
skip_idat: bool = false,
/// The next frame, once `decodeFrameConfig` has read up to its first data
/// chunk's header and before `decodeFrame` draws it.
pending: ?Pending = null,
/// An eXIf after the image data, as PNG's extensions before the third
/// edition allowed: `applyTrailer` reports it.
late_exif: ?decode.Blob = null,
late_orientation: ?decode.Orientation = null,

const Pending = struct { fc: FrameControl, kind: u32 };

const State = enum {
    start,
    /// Config read; the first IDAT's header is consumed.
    at_idat,
    /// Between frames, before a chunk header.
    between,
    done,
};

const Seen = packed struct {
    plte: bool = false,
    trns: bool = false,
    actl: bool = false,
    gama: bool = false,
    chrm: bool = false,
    srgb: bool = false,
    iccp: bool = false,
    exif: bool = false,
    phys: bool = false,
    bkgd: bool = false,
};

const Ihdr = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: u8,
    interlaced: bool,

    fn channels(h: Ihdr) u8 {
        return switch (h.color) {
            2 => 3,
            4 => 2,
            6 => 4,
            else => 1,
        };
    }

    fn bitsPerPixel(h: Ihdr) u32 {
        return @as(u32, h.channels()) * h.depth;
    }

    /// Section 9.2's bytes per complete pixel, at least 1.
    fn filterBpp(h: Ihdr) usize {
        return @max(1, h.bitsPerPixel() / 8);
    }

    /// The bytes of one row `width` pixels wide, without its filter byte.
    fn rowBytes(h: Ihdr, width: u32) ?usize {
        const bits = std.math.mul(u64, width, h.bitsPerPixel()) catch return null;
        return std.math.cast(usize, (bits + 7) / 8);
    }
};

const FrameControl = struct {
    width: u32,
    height: u32,
    x: u32 = 0,
    y: u32 = 0,
    duration: u64 = 0,
    disposal: decode.Frame.Disposal = .none,
    over: bool = false,
};

fn tag(comptime name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .big);
}

/// Chunk types, as `Chunk.type` holds them.
const types = struct {
    const ihdr = tag("IHDR");
    const plte = tag("PLTE");
    const idat = tag("IDAT");
    const iend = tag("IEND");
    const trns = tag("tRNS");
    const gama = tag("gAMA");
    const chrm = tag("cHRM");
    const srgb = tag("sRGB");
    const iccp = tag("iCCP");
    const exif = tag("eXIf");
    const phys = tag("pHYs");
    const bkgd = tag("bKGD");
    const actl = tag("acTL");
    const fctl = tag("fcTL");
    const fdat = tag("fdAT");
};

const signature = "\x89PNG\r\n\x1a\n";
/// A tRNS key no 16-bit sample equals.
const no_key: u32 = 1 << 16;
/// The staging buffer between the chunks and inflate.
const data_buffer_len = 8 << 10;
const window_len = @sizeOf(zlib.Reader.Buffer);

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops after IEND.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the chunks before the first IDAT. The native format holds the
/// samples at their depth (8 bits for depths below 8, 16 bits in the
/// machine's byte order for 16), as gray, gray and alpha, RGB, or RGBA;
/// palette images are RGB. tRNS adds alpha, and so does APNG, whose canvas
/// can be cleared to transparent black. Calling it again returns the same
/// config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHead() catch |e| return d.fail(e);
        d.state = .at_idat;
    }
    return .{
        .width = d.ihdr.width,
        .height = d.ihdr.height,
        .native = d.native(),
        .frame_count = if (!d.animated) 1 else if (d.num_frames <= d.options.limits.max_frames) d.num_frames else null,
        .loop_count = if (d.animated) d.num_plays else null,
        .work_len = d.work_len,
        .is_opaque = !d.hasAlpha(),
        .background = d.background,
        .metadata = d.metadata,
    };
}

/// Decodes the next frame into its region of `dst`, which must be the
/// canvas's size, in any format, using `work[0..work_len]`. Returns null
/// after the last frame, once IEND is read.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    try dst.check();
    if (dst.width != d.ihdr.width or dst.height != d.ihdr.height) return error.SizeMismatch;
    if (work.len < d.work_len) return error.WorkTooSmall;
    return d.nextFrame(dst, work) catch |e| return d.fail(e);
}

/// Reads up to the next frame's pixels and returns the frame `decodeFrame`
/// will decode next, without drawing it, or null after the last frame. A
/// caller saves the region here for a frame whose disposal is `previous`.
pub fn decodeFrameConfig(d: *Decoder) Error!?decode.Frame {
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    const p = (d.advance() catch |e| return d.fail(e)) orelse return null;
    return d.frameOf(p.fc);
}

/// Sets in `config` an eXIf found after the image data, and the
/// orientation it gives. `image.Decoder.finalConfig` calls it once the
/// frames end. The other metadata chunks must come before the image data
/// and are ignored after it.
pub fn applyTrailer(d: *const Decoder, config: *decode.Config) void {
    const blob = d.late_exif orelse return;
    config.metadata.exif = blob;
    if (d.late_orientation) |o| config.metadata.orientation = o;
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

/// Whether the image's pixels can be transparent: an alpha channel or tRNS.
fn pixelAlpha(d: *const Decoder) bool {
    return d.ihdr.color == 4 or d.ihdr.color == 6 or d.has_trns;
}

/// Whether the canvas can be transparent, and so the native format has
/// alpha: an APNG's canvas always can, since frame 0 may not cover it and
/// disposal to background clears a region to transparent black.
fn hasAlpha(d: *const Decoder) bool {
    return d.pixelAlpha() or d.animated;
}

fn native(d: *const Decoder) PixelFormat {
    const wide = d.ihdr.depth == 16;
    const alpha = d.hasAlpha();
    return switch (d.ihdr.color) {
        0 => if (alpha)
            (if (wide) .gray_alpha16 else .gray_alpha8)
        else
            (if (wide) .gray16 else .gray8),
        2 => if (alpha) (if (wide) .rgba16 else .rgba8) else (if (wide) .rgb16 else .rgb8),
        3 => if (alpha) .rgba8 else .rgb8,
        4 => if (wide) .gray_alpha16 else .gray_alpha8,
        else => if (wide) .rgba16 else .rgba8,
    };
}

// Reading chunks. Every byte goes through these, which count `pos` and
// fold the chunk's bytes into `crc`.

fn take(d: *Decoder, comptime n: usize) Error!*[n]u8 {
    const b = d.reader.takeArray(n) catch |e| return mapRead(e);
    d.pos += n;
    return b;
}

const Chunk = struct { len: u32, type: u32 };

fn beginChunk(d: *Decoder) Error!Chunk {
    const b = try d.take(8);
    const len = std.mem.readInt(u32, b[0..4], .big);
    if (len > 0x7fff_ffff) return error.BadChunk;
    // Chunk type bytes outside A-Z and a-z are not rejected, as in Wuffs:
    // an unknown ancillary chunk is skipped and an unknown critical one is
    // Unsupported either way.
    const t = std.mem.readInt(u32, b[4..8], .big);
    d.check_crc = isCritical(t) and !d.options.ignore_checksums;
    if (d.check_crc) d.crc = crc32.update(crc32.init, b[4..8]);
    d.left = len;
    return .{ .len = len, .type = t };
}

fn isCritical(t: u32) bool {
    return t & 0x2000_0000 == 0;
}

/// The next chunk's length and type, without consuming them.
fn peekChunk(d: *Decoder) Error!Chunk {
    const b = d.reader.peek(8) catch |e| return mapRead(e);
    return .{ .len = std.mem.readInt(u32, b[0..4], .big), .type = std.mem.readInt(u32, b[4..8], .big) };
}

/// Reads `buf.len` bytes of the chunk's data, at most `left`.
fn readData(d: *Decoder, buf: []u8) Error!void {
    std.debug.assert(buf.len <= d.left);
    d.reader.readSliceAll(buf) catch |e| return mapRead(e);
    if (d.check_crc) d.crc = crc32.update(d.crc, buf);
    d.left -= @intCast(buf.len);
    d.pos += buf.len;
}

/// Reads `n` bytes of the chunk's data, handing them to `sink` as `blob`
/// from offset `at`, and keeping the first of them in `prefix`.
fn passData(d: *Decoder, n: u32, sink: ?decode.BlobSink, blob: decode.Blob, at: u64, prefix: []u8) Error!void {
    var done: u32 = 0;
    while (done < n) {
        const got = d.reader.peekGreedy(1) catch |e| return mapRead(e);
        const k: u32 = @intCast(@min(got.len, n - done));
        const bytes = got[0..k];
        if (d.check_crc) d.crc = crc32.update(d.crc, bytes);
        const offset = at + done;
        if (sink) |s| s.put(blob, offset, bytes);
        if (offset < prefix.len) {
            const m = @min(prefix.len - offset, k);
            @memcpy(prefix[@intCast(offset)..][0..m], bytes[0..m]);
        }
        d.reader.toss(k);
        d.pos += k;
        d.left -= k;
        done += k;
    }
}

/// Skips the rest of the chunk's data and checks its CRC if it is
/// critical.
fn endChunk(d: *Decoder) Error!void {
    try d.passData(d.left, null, undefined, 0, &.{});
    const b = try d.take(4);
    if (d.check_crc and std.mem.readInt(u32, b, .big) != crc32.final(d.crc)) return error.BadCrc;
}

/// A whole chunk of at most `buf.len` bytes, CRC checked, or null if it is
/// longer (and then skipped).
fn readSmall(d: *Decoder, buf: []u8) Error!?[]u8 {
    if (d.left > buf.len) {
        try d.endChunk();
        return null;
    }
    const body = buf[0..d.left];
    try d.readData(body);
    try d.endChunk();
    return body;
}

fn readHead(d: *Decoder) Error!void {
    if (!std.mem.eql(u8, try d.take(8), signature)) return error.BadSignature;
    const first = try d.beginChunk();
    if (first.type != types.ihdr or first.len != 13) return error.BadHeader;
    var b: [13]u8 = undefined;
    try d.readData(&b);
    try d.endChunk();
    const h: Ihdr = .{
        .width = std.mem.readInt(u32, b[0..4], .big),
        .height = std.mem.readInt(u32, b[4..8], .big),
        .depth = b[8],
        .color = b[9],
        .interlaced = b[12] == 1,
    };
    if (h.width == 0 or h.height == 0 or h.width > 0x7fff_ffff or h.height > 0x7fff_ffff) return error.BadHeader;
    const depth_ok = switch (h.color) {
        0 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
        3 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
        2, 4, 6 => h.depth == 8 or h.depth == 16,
        else => false,
    };
    if (!depth_ok or b[10] != 0 or b[11] != 0 or b[12] > 1) return error.BadHeader;
    d.ihdr = h;
    try d.options.limits.checkSize(h.width, h.height);
    d.work_len = workLen(h) orelse return error.ImageTooLarge;
    try d.options.limits.checkWork(d.work_len);
    @memset(&d.palette, .{ 0, 0, 0, 255 });

    while (true) {
        const c = try d.beginChunk();
        switch (c.type) {
            types.idat => break,
            types.ihdr, types.iend, types.fdat => return error.BadChunk,
            types.plte => try d.readPlte(),
            types.trns => try d.readTrns(),
            types.actl => try d.readActl(),
            types.fctl => {
                if (d.early_fctl != null or c.len != 26) return error.BadChunk;
                var raw: [26]u8 = undefined;
                try d.readData(&raw);
                try d.endChunk();
                d.early_fctl = raw;
            },
            else => try d.readOther(c),
        }
    }
    if (h.color == 3 and !d.seen.plte) return error.BadChunk;
    if (d.animated) {
        if (d.early_fctl) |raw| d.fctl = try d.parseFctl(&raw, true);
    }
}

/// The work memory any PNG no wider than `width` needs: `Config.work_len`
/// for 16-bit RGBA, the widest pixel. For a container that must state the
/// work memory before it reaches a PNG's header (ICO).
pub fn maxWorkLen(width: u32) ?usize {
    return workLen(.{ .width = width, .height = 1, .depth = 16, .color = 6, .interlaced = false });
}

fn workLen(h: Ihdr) ?usize {
    const row = h.rowBytes(h.width) orelse return null;
    const rows = std.math.mul(usize, row, 2) catch return null;
    return std.math.add(usize, window_len + data_buffer_len, rows) catch null;
}

/// Metadata and unknown chunks, before or after the image data.
fn readOther(d: *Decoder, c: Chunk) Error!void {
    var buf: [32]u8 = undefined;
    // These must come before the image data and could not change `Config`
    // after it, so they are skipped there, as libpng skips them.
    if (d.state != .start) switch (c.type) {
        types.gama, types.chrm, types.srgb, types.phys, types.bkgd, types.iccp => return d.endChunk(),
        else => {},
    };
    switch (c.type) {
        types.gama => if (try d.readSmall(&buf)) |b| {
            if (b.len != 4 or d.seen.gama) return;
            const v = std.mem.readInt(u32, b[0..4], .big);
            if (v == 0) return;
            d.seen.gama = true;
            d.metadata.gamma = v;
        },
        types.chrm => if (try d.readSmall(&buf)) |b| {
            if (b.len != 32 or d.seen.chrm) return;
            d.seen.chrm = true;
            // White, red, green, blue there; red, green, blue, white here.
            var v: [8]f32 = undefined;
            for (&v, 0..) |*x, i| {
                const at = (i + 2) % 8 * 4;
                x.* = @as(f32, @floatFromInt(std.mem.readInt(u32, b[at..][0..4], .big))) / 100_000;
            }
            d.metadata.primaries = v;
        },
        types.srgb => if (try d.readSmall(&buf)) |b| {
            if (b.len != 1 or b[0] > 3 or d.seen.srgb) return;
            d.seen.srgb = true;
            d.metadata.transfer = .srgb;
        },
        types.phys => if (try d.readSmall(&buf)) |b| {
            if (b.len != 9 or b[8] > 1 or d.seen.phys) return;
            d.seen.phys = true;
            d.metadata.density = .{
                .x = std.mem.readInt(u32, b[0..4], .big),
                .y = std.mem.readInt(u32, b[4..8], .big),
                .unit = if (b[8] == 1) .per_meter else .none,
            };
        },
        types.bkgd => if (try d.readSmall(&buf)) |b| d.readBkgd(b),
        types.iccp => try d.readIccp(),
        types.exif => try d.readExif(),
        else => {
            if (isCritical(c.type)) return error.Unsupported;
            try d.endChunk();
        },
    }
}

fn readPlte(d: *Decoder) Error!void {
    const h = d.ihdr;
    // A suggested palette for truecolor is not used.
    if (h.color == 2 or h.color == 6) return d.endChunk();
    if (h.color != 3 or d.seen.plte) return error.BadChunk;
    const n = d.left / 3;
    if (d.left % 3 != 0 or n == 0 or n > @as(u32, 1) << @intCast(h.depth)) return error.BadChunk;
    var b: [768]u8 = undefined;
    try d.readData(b[0 .. n * 3]);
    try d.endChunk();
    for (0..n) |i| d.palette[i] = .{ b[i * 3], b[i * 3 + 1], b[i * 3 + 2], 255 };
    d.palette_len = @intCast(n);
    d.seen.plte = true;
}

fn readTrns(d: *Decoder) Error!void {
    const h = d.ihdr;
    // Forbidden with an alpha channel, and ignored there by libpng,
    // libspng, and Wuffs alike.
    if (h.color == 4 or h.color == 6) return d.endChunk();
    if (d.seen.trns) return error.BadChunk;
    var b: [256]u8 = undefined;
    const mask: u16 = @truncate((@as(u32, 1) << @intCast(h.depth)) - 1);
    switch (h.color) {
        0, 2 => {
            const len: u32 = if (h.color == 0) 2 else 6;
            if (d.left != len) return error.BadChunk;
            try d.readData(b[0..len]);
            for (0..len / 2) |i| d.key[i] = std.mem.readInt(u16, b[i * 2 ..][0..2], .big) & mask;
        },
        3 => {
            if (!d.seen.plte or d.left > d.palette_len) return error.BadChunk;
            const n = d.left;
            try d.readData(b[0..n]);
            for (b[0..n], 0..) |a, i| d.palette[i][3] = a;
        },
        else => unreachable,
    }
    try d.endChunk();
    d.seen.trns = true;
    d.has_trns = true;
}

fn readActl(d: *Decoder) Error!void {
    if (d.seen.actl or d.left != 8) return error.BadChunk;
    var b: [8]u8 = undefined;
    try d.readData(&b);
    try d.endChunk();
    const frames = std.mem.readInt(u32, b[0..4], .big);
    const plays = std.mem.readInt(u32, b[4..8], .big);
    // A play count past 2^31 - 1 breaks the PNG integer rule but cannot
    // change the pixels, so it is reported as written, as Wuffs reads it.
    if (frames == 0 or frames > 0x7fff_ffff) return error.BadChunk;
    d.seen.actl = true;
    d.animated = true;
    d.num_frames = frames;
    d.num_plays = plays;
}

/// An 8-bit sample from a `depth`-bit one, as the conversions scale them.
fn to8(v: u16, depth: u8) u8 {
    return switch (depth) {
        1 => @intCast(v * 255),
        2 => @intCast(v * 85),
        4 => @intCast(v * 17),
        8 => @intCast(v),
        else => @intCast(v >> 8),
    };
}

fn readBkgd(d: *Decoder, b: []const u8) void {
    const h = d.ihdr;
    if (d.seen.bkgd) return;
    const mask: u16 = @truncate((@as(u32, 1) << @intCast(h.depth)) - 1);
    switch (h.color) {
        3 => {
            if (b.len != 1 or b[0] >= d.palette_len) return;
            const p = d.palette[b[0]];
            d.background = .{ p[0], p[1], p[2], 255 };
        },
        0, 4 => {
            if (b.len != 2) return;
            const v = to8(std.mem.readInt(u16, b[0..2], .big) & mask, h.depth);
            d.background = .{ v, v, v, 255 };
        },
        else => {
            if (b.len != 6) return;
            var c: [4]u8 = .{ 0, 0, 0, 255 };
            for (0..3) |i| c[i] = to8(std.mem.readInt(u16, b[i * 2 ..][0..2], .big) & mask, h.depth);
            d.background = c;
        },
    }
    d.seen.bkgd = true;
}

/// iCCP: a profile name of 1 to 79 bytes, a zero, compression method 0,
/// then the zlib-compressed profile, which is the blob.
fn readIccp(d: *Decoder) Error!void {
    if (d.seen.iccp) return d.endChunk();
    var b: [81]u8 = undefined;
    const head = b[0..@min(d.left, b.len)];
    try d.readData(head);
    const name_len = std.mem.findScalar(u8, head, 0) orelse return d.endChunk();
    if (name_len == 0 or name_len > 79 or name_len + 1 >= head.len or head[name_len + 1] != 0) return d.endChunk();
    const start = name_len + 2;
    const blob: decode.Blob = .{
        .kind = .icc,
        .offset = d.pos - head.len + start,
        .len = d.left + head.len - start,
        .encoding = .zlib,
    };
    const sink = d.options.blob_sink;
    if (sink) |s| if (head.len > start) s.put(blob, 0, head[start..]);
    try d.passData(d.left, sink, blob, head.len - start, &.{});
    try d.endChunk();
    d.seen.iccp = true;
    d.metadata.icc = blob;
}

/// eXIf: the blob is the whole chunk. Its orientation is read from its
/// first 4 KiB, where IFD0 almost always lies.
fn readExif(d: *Decoder) Error!void {
    if (d.seen.exif) return d.endChunk();
    const blob: decode.Blob = .{ .kind = .exif, .offset = d.pos, .len = d.left };
    var prefix: [4096]u8 = undefined;
    const n = @min(d.left, prefix.len);
    try d.passData(d.left, d.options.blob_sink, blob, 0, prefix[0..n]);
    try d.endChunk();
    d.seen.exif = true;
    const orientation = exif.orientation(prefix[0..n]);
    if (d.state == .start) {
        d.metadata.exif = blob;
        if (orientation) |o| d.metadata.orientation = o;
    } else {
        d.late_exif = blob;
        d.late_orientation = orientation;
    }
}

/// Reads an fdAT chunk's sequence number, its first four bytes.
fn sequence(d: *Decoder) Error!void {
    if (d.left < 4) return error.BadChunk;
    var b: [4]u8 = undefined;
    try d.readData(&b);
    if (std.mem.readInt(u32, &b, .big) != d.seq) return error.BadChunk;
    d.seq += 1;
}

/// fcTL's 26 bytes. The default image's must cover the canvas.
fn parseFctl(d: *Decoder, b: *const [26]u8, default_image: bool) Error!FrameControl {
    const be = std.builtin.Endian.big;
    if (std.mem.readInt(u32, b[0..4], be) != d.seq) return error.BadChunk;
    d.seq += 1;
    d.controls += 1;
    if (d.controls > d.num_frames) return error.BadChunk;
    const w = std.mem.readInt(u32, b[4..8], be);
    const h = std.mem.readInt(u32, b[8..12], be);
    const x = std.mem.readInt(u32, b[12..16], be);
    const y = std.mem.readInt(u32, b[16..20], be);
    const num = std.mem.readInt(u16, b[20..22], be);
    const den = std.mem.readInt(u16, b[22..24], be);
    const dispose = b[24];
    const blend = b[25];
    if (w == 0 or h == 0 or dispose > 2 or blend > 1) return error.BadChunk;
    if (@as(u64, x) + w > d.ihdr.width or @as(u64, y) + h > d.ihdr.height) return error.BadChunk;
    if (default_image and (x != 0 or y != 0 or w != d.ihdr.width or h != d.ihdr.height)) return error.BadChunk;
    const first = d.controls == 1;
    return .{
        .width = w,
        .height = h,
        .x = x,
        .y = y,
        .duration = @as(u64, num) * decode.flicks_per_second / (if (den == 0) 100 else den),
        .disposal = switch (dispose) {
            0 => .none,
            1 => .background,
            // The first frame has nothing to revert to.
            else => if (first) .background else .previous,
        },
        .over = blend == 1 and !first,
    };
}

fn nextFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    const p = try d.advance() orelse return null;
    d.pending = null;
    const f = try d.frame(dst, work, p.fc, p.kind);
    return f;
}

/// Reads up to the next frame's first data chunk, through its header, and
/// keeps the frame in `pending`; or reads IEND and returns null. The frame
/// limit counts frames reached, not acTL's count, so a file whose acTL
/// claims too many frames still gives the frames within the limit.
fn advance(d: *Decoder) Error!?Pending {
    if (d.pending) |p| return p;
    if (d.state == .done) return null;
    const p = try d.findFrame() orelse return null;
    try d.options.limits.checkFrames(@as(u64, d.frames) + 1);
    d.pending = p;
    return p;
}

fn findFrame(d: *Decoder) Error!?Pending {
    if (d.state == .at_idat) {
        d.state = .between;
        if (!d.animated or d.fctl != null) {
            const fc = d.fctl orelse FrameControl{ .width = d.ihdr.width, .height = d.ihdr.height };
            d.fctl = null;
            return .{ .fc = fc, .kind = types.idat };
        }
        // The default image is not part of the animation: its IDAT
        // chunks are skipped wherever they are, as Wuffs skips them.
        d.skip_idat = true;
        try d.endChunk();
    }
    while (true) {
        const c = try d.beginChunk();
        switch (c.type) {
            types.iend => {
                if (c.len != 0) return error.BadChunk;
                try d.endChunk();
                if (d.animated and (d.frames != d.num_frames or d.fctl != null)) return error.BadChunk;
                d.state = .done;
                return null;
            },
            types.ihdr, types.plte => return error.BadChunk,
            // Empty IDAT chunks may follow the image's; data is too much.
            types.idat => {
                if (c.len != 0 and !d.skip_idat) return error.TooMuchData;
                try d.endChunk();
            },
            types.fctl => {
                if (!d.animated) {
                    try d.endChunk();
                    continue;
                }
                if (d.fctl != null or c.len != 26) return error.BadChunk;
                var raw: [26]u8 = undefined;
                try d.readData(&raw);
                try d.endChunk();
                d.fctl = try d.parseFctl(&raw, false);
            },
            types.fdat => {
                if (!d.animated) {
                    try d.endChunk();
                    continue;
                }
                const fc = d.fctl orelse {
                    // An empty fdAT may follow a frame's.
                    if (c.len < 4 or d.frames == 0) return error.BadChunk;
                    if (c.len > 4) return error.TooMuchData;
                    try d.sequence();
                    try d.endChunk();
                    continue;
                };
                d.fctl = null;
                return .{ .fc = fc, .kind = types.fdat };
            },
            // acTL counts only before IDAT.
            types.actl => try d.endChunk(),
            else => try d.readOther(c),
        }
    }
}

/// Decodes one frame whose first data chunk's header has been read.
fn frame(d: *Decoder, dst: PixelBuffer, work: []u8, fc: FrameControl, kind: u32) Error!decode.Frame {
    const index = d.frames;
    if (index == 0 and (fc.width != dst.width or fc.height != dst.height)) {
        // The canvas starts transparent black: the native format's zero
        // pixel (an APNG's always has alpha), converted to `dst`'s.
        const bpp = dst.format.bytesPerPixel();
        const zero: [16]u8 = @splat(0);
        var px: [16]u8 = undefined;
        Converter.init(dst.format, d.native()).run(px[0..bpp], &zero, 1);
        for (0..dst.height) |y| {
            const row = dst.row(@intCast(y));
            var x: usize = 0;
            while (x < row.len) : (x += bpp) @memcpy(row[x..][0..bpp], px[0..bpp]);
        }
    }
    const f = d.frameOf(fc);
    try d.pixels(dst.sub(fc.x, fc.y, fc.width, fc.height), work, kind, f.blend == .src_over);
    d.frames += 1;
    return f;
}

/// The frame `fc` describes, as the next to decode.
fn frameOf(d: *const Decoder, fc: FrameControl) decode.Frame {
    return .{
        .index = d.frames,
        .x = fc.x,
        .y = fc.y,
        .width = fc.width,
        .height = fc.height,
        .duration = fc.duration,
        .disposal = fc.disposal,
        .blend = if (fc.over and d.pixelAlpha()) .src_over else .src,
        .is_opaque = !d.pixelAlpha(),
    };
}

/// An `Io.Reader` over a frame's image data: the data of consecutive IDAT
/// chunks, or of fdAT chunks after their sequence numbers, checking each
/// chunk's CRC as it ends. It ends before the first chunk of another kind,
/// leaving that chunk's header unread.
const DataReader = struct {
    d: *Decoder,
    kind: u32,
    reader: Io.Reader,
    /// Why the reader failed, when it returned `error.ReadFailed`.
    err: ?Error = null,
    /// Whether the data chunks have ended: the last one's CRC is checked
    /// and the next chunk is of another kind.
    ended: bool = false,

    fn init(d: *Decoder, kind: u32, buffer: []u8) DataReader {
        return .{
            .d = d,
            .kind = kind,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    /// Moves past the current chunk to the next data chunk, or ends.
    fn next(r: *DataReader) Error!void {
        const d = r.d;
        try d.endChunk();
        if ((try d.peekChunk()).type != r.kind) {
            r.ended = true;
            return;
        }
        _ = try d.beginChunk();
        if (r.kind == types.fdat) try d.sequence();
    }

    fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const r: *DataReader = @alignCast(@fieldParentPtr("reader", io_r));
        const d = r.d;
        if (r.err != null) return error.ReadFailed;
        while (d.left == 0) {
            if (r.ended) return error.EndOfStream;
            r.next() catch |e| {
                r.err = e;
                return error.ReadFailed;
            };
        }
        const got = d.reader.peekGreedy(1) catch |e| {
            r.err = mapRead(e);
            return error.ReadFailed;
        };
        const n = limit.minInt(@min(got.len, d.left));
        const written = try w.write(got[0..n]);
        if (d.check_crc) d.crc = crc32.update(d.crc, got[0..written]);
        d.reader.toss(written);
        d.left -= @intCast(written);
        d.pos += written;
        return written;
    }
};

const Pass = struct { x: u8, y: u8, dx: u8, dy: u8 };
const adam7 = [7]Pass{
    .{ .x = 0, .y = 0, .dx = 8, .dy = 8 },
    .{ .x = 4, .y = 0, .dx = 8, .dy = 8 },
    .{ .x = 0, .y = 4, .dx = 4, .dy = 8 },
    .{ .x = 2, .y = 0, .dx = 4, .dy = 4 },
    .{ .x = 0, .y = 2, .dx = 2, .dy = 4 },
    .{ .x = 1, .y = 0, .dx = 2, .dy = 2 },
    .{ .x = 0, .y = 1, .dx = 1, .dy = 2 },
};
const whole = [1]Pass{.{ .x = 0, .y = 0, .dx = 1, .dy = 1 }};

fn zlibError(zr: *const zlib.Reader, dr: *const DataReader) Error {
    if (dr.err) |e| return e;
    return switch (zr.err orelse return error.BadZlib) {
        error.Truncated => if (dr.ended) error.NotEnoughData else error.Truncated,
        // Only the end of the stream checks it: before the last row, the
        // rows are short whether or not the checksum is ignored.
        error.WrongChecksum => if (dr.d.options.ignore_checksums) error.NotEnoughData else error.BadChecksum,
        error.ReadFailed => error.ReadFailed,
        else => error.BadZlib,
    };
}

/// The longest row `pixels` reads in place from the inflate window, which
/// holds that much contiguously however the window has slid.
const max_peek = window_len / 2;

/// Inflates and unfilters a frame's rows into `region`, then checks that
/// its data ends with its zlib stream.
fn pixels(d: *Decoder, region: PixelBuffer, work: []u8, kind: u32, over: bool) Error!void {
    const h = d.ihdr;
    var dr: DataReader = .init(d, kind, work[window_len..][0..data_buffer_len]);
    if (kind == types.fdat) try d.sequence();
    var zr: zlib.Reader = .init(&dr.reader, work[0..window_len], null);
    const in = &zr.reader;
    const row_len = h.rowBytes(h.width).?;
    const rows = work[window_len + data_buffer_len ..];
    var prev = rows[0..row_len];
    var cur = rows[row_len..][0..row_len];
    const out: Out = .init(d, region, over);
    // Unfilter straight into the canvas when its rows are the raw samples.
    const direct = !h.interlaced and out.expand == .copy and !over and region.format == out.native;
    const bpp = h.filterBpp();
    for (if (h.interlaced) &adam7 else &whole) |p| {
        if (region.width <= p.x or region.height <= p.y) continue;
        const pw = (region.width - p.x + p.dx - 1) / p.dx;
        const ph = (region.height - p.y + p.dy - 1) / p.dy;
        const n = h.rowBytes(pw).?;
        @memset(prev[0..n], 0);
        var y: u32 = 0;
        while (y < ph) : (y += 1) {
            const f = in.takeByte() catch |e| return switch (e) {
                error.EndOfStream => error.NotEnoughData,
                error.ReadFailed => zlibError(&zr, &dr),
            };
            const row = if (direct) region.row(y)[0..n] else cur[0..n];
            const above = if (direct and y > 0) region.row(y - 1) else prev[0..n];
            // Two Average or Paeth rows at once: each row's pixels depend
            // on the pixel to the left, and two such chains run faster
            // side by side (not Average's 1-byte pixels, whose byte loop
            // is as fast). The second row goes over the row above the
            // first. Anything short of two such rows whole takes the
            // one-row path.
            const pair = f == 4 or (f == 3 and bpp >= 2);
            if (pair and y + 1 < ph and n < max_peek) two: {
                const next = if (direct) region.row(y + 1)[0..n] else prev[0..n];
                if (2 * n + 1 <= max_peek) {
                    const both = in.peek(2 * n + 1) catch break :two;
                    if (both[n] != f) break :two;
                    filter.unfilter2(f, bpp, row, both[0..n], next, both[n + 1 ..][0..n], above);
                    in.toss(2 * n + 1);
                } else {
                    // A longer first row is read out of the window first.
                    in.readSliceAll(row) catch |e| return switch (e) {
                        error.EndOfStream => error.NotEnoughData,
                        error.ReadFailed => zlibError(&zr, &dr),
                    };
                    const second = in.peek(n + 1) catch null;
                    if (second == null or second.?[0] != f) {
                        try filter.unfilter(f, row, row, above, bpp);
                        if (!direct) {
                            out.put(cur[0..n], p.y + y * p.dy, p.x, p.dx, pw);
                            std.mem.swap([]u8, &prev, &cur);
                        }
                        continue;
                    }
                    filter.unfilter2(f, bpp, row, row, next, second.?[1..][0..n], above);
                    in.toss(n + 1);
                }
                if (!direct) {
                    out.put(cur[0..n], p.y + y * p.dy, p.x, p.dx, pw);
                    out.put(prev[0..n], p.y + (y + 1) * p.dy, p.x, p.dx, pw);
                }
                y += 1;
                continue;
            }
            if (n <= max_peek) {
                // Unfiltered straight out of the inflate window.
                const filtered = in.peek(n) catch |e| return switch (e) {
                    error.EndOfStream => error.NotEnoughData,
                    error.ReadFailed => zlibError(&zr, &dr),
                };
                try filter.unfilter(f, row, filtered, above, bpp);
                in.toss(n);
            } else {
                in.readSliceAll(row) catch |e| return switch (e) {
                    error.EndOfStream => error.NotEnoughData,
                    error.ReadFailed => zlibError(&zr, &dr),
                };
                try filter.unfilter(f, row, row, above, bpp);
            }
            if (!direct) {
                out.put(cur[0..n], p.y + y * p.dy, p.x, p.dx, pw);
                std.mem.swap([]u8, &prev, &cur);
            }
        }
    }
    // The zlib stream ends here, its Adler-32 checked as it ends.
    if (in.peekByte()) |_| {
        if (!h.interlaced or region.height != 1) return error.TooMuchData;
        // Wuffs reads an interlaced frame one row tall only to its last
        // row, so data after it is skipped unread, Adler-32 and all; the
        // chunks' CRCs are still checked.
        _ = dr.reader.discardRemaining() catch return dr.err.?;
        return;
    } else |e| switch (e) {
        error.EndOfStream => {},
        error.ReadFailed => {
            const sum = if (zr.err) |z| z == error.WrongChecksum else false;
            if (!sum or !d.options.ignore_checksums) return zlibError(&zr, &dr);
        },
    }
    if (dr.ended) return;
    if (dr.reader.bufferedLen() != 0 or d.left != 0) return error.TooMuchData;
    // The frame is done once its last chunk is; what follows is read by
    // the next call.
    try d.endChunk();
}

/// How a row's raw samples become the native format.
const Expand = enum {
    /// They already are: 8-bit samples without tRNS.
    copy,
    /// 16-bit samples, big endian to the machine's order.
    swap16,
    /// Gray below 8 bits, scaled to 8.
    gray_low,
    gray_low_key,
    gray8_key,
    gray16_key,
    rgb8_key,
    rgb16_key,
    palette_rgb,
    palette_rgba,
};

/// Pixels converted and written per step.
const span = 256;

/// Where a frame's rows go: the canvas region, in its format, by way of
/// the native format.
const Out = struct {
    d: *const Decoder,
    region: PixelBuffer,
    /// What `expandSpan` writes: the native format, or RGBA8 for a palette
    /// image written as RGBA8.
    native: PixelFormat,
    expand: Expand,
    over: bool,
    to_dst: Converter,

    fn init(d: *const Decoder, region: PixelBuffer, over: bool) Out {
        const h = d.ihdr;
        const nat = d.native();
        // Gray and truecolor gain alpha from tRNS or an APNG canvas; the
        // key compare then makes a pixel transparent only if tRNS says so.
        const key = d.hasAlpha();
        const wide = h.depth == 16;
        const expand: Expand = switch (h.color) {
            0 => if (wide)
                (if (key) .gray16_key else .swap16)
            else if (h.depth == 8)
                (if (key) .gray8_key else .copy)
            else
                (if (key) .gray_low_key else .gray_low),
            2 => if (wide) (if (key) .rgb16_key else .swap16) else (if (key) .rgb8_key else .copy),
            // Palette entries are RGBA already, so RGBA8 is as cheap as RGB8.
            3 => if (key or region.format == .rgba8) .palette_rgba else .palette_rgb,
            else => if (wide) .swap16 else .copy,
        };
        const from: PixelFormat = if (expand == .palette_rgba) .rgba8 else nat;
        return .{
            .d = d,
            .region = region,
            .native = from,
            .expand = expand,
            .over = over,
            .to_dst = .init(region.format, from),
        };
    }

    /// Writes `n` pixels of the unfiltered row `raw` to row `y` of the
    /// region, from column `x` every `dx` columns.
    fn put(o: *const Out, raw: []const u8, y: u32, x: u32, dx: u32, n: u32) void {
        const nbpp = o.native.bytesPerPixel();
        const dbpp = o.region.format.bytesPerPixel();
        const row = o.region.row(y);
        var native_buf: [span * 8]u8 = undefined;
        var out_buf: [span * 16]u8 = undefined;
        if (o.expand == .copy and !o.over and dx == 1) {
            // A whole row in one conversion: each call has a fixed cost.
            o.to_dst.run(row[x * dbpp ..], raw[0 .. n * nbpp], n);
            return;
        }
        var i: u32 = 0;
        while (i < n) {
            const m = @min(span, n - i);
            const at = x + i * dx;
            if (o.expand != .copy and !o.over and dx == 1 and o.native == o.region.format) {
                // Expanded straight into the region: no conversion to do.
                o.expandSpan(row[at * dbpp ..][0 .. m * dbpp], raw, i, m);
                i += m;
                continue;
            }
            const src = if (o.expand == .copy) raw[i * nbpp ..][0 .. m * nbpp] else blk: {
                o.expandSpan(native_buf[0 .. m * nbpp], raw, i, m);
                break :blk native_buf[0 .. m * nbpp];
            };
            if (o.over) {
                o.blend(row, at, dx, src, m);
            } else if (dx == 1) {
                o.to_dst.run(row[at * dbpp ..], src, m);
            } else {
                o.to_dst.run(&out_buf, src, m);
                for (0..m) |k| @memcpy(row[(at + k * dx) * dbpp ..][0..dbpp], out_buf[k * dbpp ..][0..dbpp]);
            }
            i += m;
        }
    }

    /// The native pixels `start` to `start + m` of the raw row. `start` is
    /// a multiple of `span`, so for depths below 8 it starts a byte.
    fn expandSpan(o: *const Out, out: []u8, raw: []const u8, start: u32, m: u32) void {
        const d = o.d;
        const depth = d.ihdr.depth;
        switch (o.expand) {
            .copy => unreachable,
            .swap16 => {
                const in = raw[start * out.len / m ..][0..out.len];
                for (0..out.len / 2) |k| {
                    const v = std.mem.readInt(u16, in[k * 2 ..][0..2], .big);
                    std.mem.writeInt(u16, out[k * 2 ..][0..2], v, .native);
                }
            },
            .gray_low, .gray_low_key => {
                const in = raw[start * depth / 8 ..];
                const per: u8 = 8 / depth;
                const mask: u8 = @truncate((@as(u16, 1) << @intCast(depth)) - 1);
                const key = o.expand == .gray_low_key;
                for (0..m) |k| {
                    const shift: u3 = @intCast(8 - depth - (k % per) * depth);
                    const v = (in[k / per] >> shift) & mask;
                    const g = to8(v, depth);
                    if (key) {
                        out[k * 2] = g;
                        out[k * 2 + 1] = if (v == d.key[0]) 0 else 255;
                    } else out[k] = g;
                }
            },
            .gray8_key => for (0..m) |k| {
                const v = raw[start + k];
                out[k * 2] = v;
                out[k * 2 + 1] = if (v == d.key[0]) 0 else 255;
            },
            .gray16_key => for (0..m) |k| {
                const v = std.mem.readInt(u16, raw[(start + k) * 2 ..][0..2], .big);
                std.mem.writeInt(u16, out[k * 4 ..][0..2], v, .native);
                const a: u16 = if (v == d.key[0]) 0 else 65535;
                std.mem.writeInt(u16, out[k * 4 + 2 ..][0..2], a, .native);
            },
            .rgb8_key => for (0..m) |k| {
                const p = raw[(start + k) * 3 ..][0..3];
                const clear = p[0] == d.key[0] and p[1] == d.key[1] and p[2] == d.key[2];
                out[k * 4 ..][0..4].* = .{ p[0], p[1], p[2], if (clear) 0 else 255 };
            },
            .rgb16_key => for (0..m) |k| {
                const p = raw[(start + k) * 6 ..][0..6];
                var clear = true;
                for (0..3) |c| {
                    const v = std.mem.readInt(u16, p[c * 2 ..][0..2], .big);
                    clear = clear and v == d.key[c];
                    std.mem.writeInt(u16, out[k * 8 + c * 2 ..][0..2], v, .native);
                }
                std.mem.writeInt(u16, out[k * 8 + 6 ..][0..2], if (clear) 0 else 65535, .native);
            },
            .palette_rgb, .palette_rgba => {
                const rgba = o.expand == .palette_rgba;
                if (depth == 8) {
                    // A loop each, with nothing to decide per pixel.
                    const in = raw[start..][0..m];
                    if (rgba) {
                        for (in, 0..) |index, k| out[k * 4 ..][0..4].* = d.palette[index];
                    } else {
                        for (in, 0..) |index, k| out[k * 3 ..][0..3].* = d.palette[index][0..3].*;
                    }
                    return;
                }
                const in = raw[start * depth / 8 ..];
                const per: u8 = 8 / depth;
                const mask: u8 = @truncate((@as(u16, 1) << @intCast(depth)) - 1);
                for (0..m) |k| {
                    const index = if (depth == 8) in[k] else blk: {
                        const shift: u3 = @intCast(8 - depth - (k % per) * depth);
                        break :blk (in[k / per] >> shift) & mask;
                    };
                    if (rgba) {
                        out[k * 4 ..][0..4].* = d.palette[index];
                    } else out[k * 3 ..][0..3].* = d.palette[index][0..3].*;
                }
            },
        }
    }

    /// Composites `m` native pixels over the region's pixels at `x`, every
    /// `dx` columns of `row`, in straight 16-bit RGBA.
    fn blend(o: *const Out, row: []u8, x: u32, dx: u32, src: []const u8, m: u32) void {
        const dbpp = o.region.format.bytesPerPixel();
        var s: [span][4]u16 = undefined;
        var t: [span][4]u16 = undefined;
        var buf: [span * 16]u8 = undefined;
        Converter.init(.rgba16, o.native).run(std.mem.sliceAsBytes(&s), src, m);
        for (0..m) |k| @memcpy(buf[k * dbpp ..][0..dbpp], row[(x + k * dx) * dbpp ..][0..dbpp]);
        Converter.init(.rgba16, o.region.format).run(std.mem.sliceAsBytes(&t), &buf, m);
        for (s[0..m], t[0..m]) |a, *b| b.* = over16(a, b.*);
        Converter.init(o.region.format, .rgba16).run(&buf, std.mem.sliceAsBytes(&t), m);
        for (0..m) |k| @memcpy(row[(x + k * dx) * dbpp ..][0..dbpp], buf[k * dbpp ..][0..dbpp]);
    }
};

/// Straight-alpha `src` over `dst`, APNG's blend_op 1, rounded to nearest.
fn over16(src: [4]u16, dst: [4]u16) [4]u16 {
    const sa: u64 = src[3];
    if (sa == 65535) return src;
    if (sa == 0) return dst;
    const da: u64 = dst[3];
    const total = sa * 65535 + da * (65535 - sa);
    var out: [4]u16 = undefined;
    for (0..3) |c| {
        const num = @as(u64, src[c]) * sa * 65535 + @as(u64, dst[c]) * da * (65535 - sa);
        out[c] = @intCast((num + total / 2) / total);
    }
    out[3] = @intCast((total + 32767) / 65535);
    return out;
}

// Tests. `TestPng` writes PNG files: chunks with their CRCs, and image data
// filtered with a random filter per row and compressed by compress's zlib.

const TestPng = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(t: *TestPng) void {
        t.bytes.deinit(testing.allocator);
        t.* = undefined;
    }

    fn chunk(t: *TestPng, name: *const [4]u8, data: []const u8) !void {
        const a = testing.allocator;
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(data.len), .big);
        try t.bytes.appendSlice(a, &len);
        try t.bytes.appendSlice(a, name);
        try t.bytes.appendSlice(a, data);
        var crc: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc, crc32.final(crc32.update(crc32.update(crc32.init, name), data)), .big);
        try t.bytes.appendSlice(a, &crc);
    }

    fn head(t: *TestPng, w: u32, h: u32, depth: u8, color: u8, interlaced: bool) !void {
        try t.bytes.appendSlice(testing.allocator, signature);
        var b: [13]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], w, .big);
        std.mem.writeInt(u32, b[4..8], h, .big);
        b[8..13].* = .{ depth, color, 0, 0, @intFromBool(interlaced) };
        try t.chunk("IHDR", &b);
    }

    /// Image data chunks for `raw`, the unfiltered rows of a `w` by `h`
    /// image packed at `bits` per pixel, split into chunks of `split`
    /// bytes. `seq` numbers fdAT chunks.
    fn image(
        t: *TestPng,
        name: *const [4]u8,
        raw: []const u8,
        w: u32,
        h: u32,
        bits: u32,
        interlaced: bool,
        random: std.Random,
        split: usize,
        seq: *u32,
    ) !void {
        const a = testing.allocator;
        const z = try compressRows(raw, w, h, bits, interlaced, random);
        defer a.free(z);
        try t.chunks(name, z, split, seq);
    }

    /// Image data chunks holding `z`, `split` bytes each.
    fn chunks(t: *TestPng, name: *const [4]u8, z: []const u8, split: usize, seq: *u32) !void {
        const a = testing.allocator;
        var at: usize = 0;
        while (true) {
            const k = @min(split, z.len - at);
            if (std.mem.eql(u8, name, "fdAT")) {
                const c = try a.alloc(u8, 4 + k);
                defer a.free(c);
                std.mem.writeInt(u32, c[0..4], seq.*, .big);
                seq.* += 1;
                @memcpy(c[4..], z[at..][0..k]);
                try t.chunk(name, c);
            } else try t.chunk(name, z[at..][0..k]);
            at += k;
            if (at == z.len) break;
        }
    }

    fn fctl(t: *TestPng, seq: *u32, w: u32, h: u32, x: u32, y: u32, dispose: u8, blend: u8) !void {
        var b: [26]u8 = undefined;
        for ([_]u32{ seq.*, w, h, x, y }, 0..) |v, i| std.mem.writeInt(u32, b[i * 4 ..][0..4], v, .big);
        b[20..26].* = .{ 0, 1, 0, 10, dispose, blend };
        seq.* += 1;
        try t.chunk("fcTL", &b);
    }
};

/// The zlib stream of `raw`'s rows, each filtered with a random filter.
fn compressRows(raw: []const u8, w: u32, h: u32, bits: u32, interlaced: bool, random: std.Random) ![]u8 {
    const a = testing.allocator;
    {
        var filtered: std.ArrayList(u8) = .empty;
        defer filtered.deinit(a);
        const stride = (w * bits + 7) / 8;
        const bpp = @max(1, bits / 8);
        for (if (interlaced) &adam7 else &whole) |p| {
            if (w <= p.x or h <= p.y) continue;
            const pw = (w - p.x + p.dx - 1) / p.dx;
            const ph = (h - p.y + p.dy - 1) / p.dy;
            const n = (pw * bits + 7) / 8;
            const prev = try a.alloc(u8, n);
            defer a.free(prev);
            const cur = try a.alloc(u8, n);
            defer a.free(cur);
            @memset(prev, 0);
            for (0..ph) |j| {
                @memset(cur, 0);
                for (0..pw) |i| {
                    const v = getBits(raw[(p.y + j * p.dy) * stride ..], p.x + i * p.dx, bits);
                    setBits(cur, i, bits, v);
                }
                const f = random.uintLessThan(u8, 5);
                try filtered.append(a, f);
                for (0..n) |i| {
                    const left: u8 = if (i >= bpp) cur[i - bpp] else 0;
                    const ul: u8 = if (i >= bpp) prev[i - bpp] else 0;
                    try filtered.append(a, cur[i] -% switch (f) {
                        0 => 0,
                        1 => left,
                        2 => prev[i],
                        3 => @as(u8, @intCast((@as(u16, left) + prev[i]) / 2)),
                        else => filter.predict(left, prev[i], ul),
                    });
                }
                @memcpy(prev, cur);
            }
        }
        const z = try a.alloc(u8, zlib.encode.maxCompressedLength(filtered.items.len));
        errdefer a.free(z);
        const zn = try zlib.encode.compress(filtered.items, z, .{});
        return a.realloc(z, zn);
    }
}

fn getBits(row: []const u8, x: usize, bits: u32) u64 {
    if (bits >= 8) {
        var v: u64 = 0;
        for (row[x * bits / 8 ..][0 .. bits / 8]) |b| v = v << 8 | b;
        return v;
    }
    const at = x * bits;
    return (row[at / 8] >> @intCast(8 - bits - at % 8)) & ((@as(u8, 1) << @intCast(bits)) - 1);
}

fn setBits(row: []u8, x: usize, bits: u32, v: u64) void {
    if (bits >= 8) {
        var rest = v;
        var i = bits / 8;
        while (i > 0) : (i -= 1) {
            row[x * bits / 8 + i - 1] = @truncate(rest);
            rest >>= 8;
        }
        return;
    }
    const at = x * bits;
    row[at / 8] |= @as(u8, @intCast(v)) << @intCast(8 - bits - at % 8);
}

fn testDecode(file: []const u8, format: PixelFormat, out: []u8) !decode.Config {
    return testDecodeWith(file, format, out, .{});
}

fn testDecodeWith(file: []const u8, format: PixelFormat, out: []u8, options: Options) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, options);
    const config = try d.decodeConfig();
    const work = try testing.allocator.alloc(u8, config.work_len);
    defer testing.allocator.free(work);
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    _ = (try d.decodeFrame(dst, work)) orelse return error.NoFrame;
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    try testing.expectEqual(0, r.bufferedLen());
    return config;
}

test "every color type, depth, and interlacing, with and without tRNS" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const kinds = [_][2]u8{
        .{ 0, 1 }, .{ 0, 2 },  .{ 0, 4 },  .{ 0, 8 }, .{ 0, 16 },
        .{ 2, 8 }, .{ 2, 16 }, .{ 3, 1 },  .{ 3, 2 }, .{ 3, 4 },
        .{ 3, 8 }, .{ 4, 8 },  .{ 4, 16 }, .{ 6, 8 }, .{ 6, 16 },
    };
    for (0..600) |round| {
        const kind = kinds[round % kinds.len];
        const color = kind[0];
        const depth = kind[1];
        const interlaced = round / kinds.len % 2 == 1;
        const key = color < 4 and round / kinds.len / 2 % 2 == 1;
        const w = 1 + random.uintLessThan(u32, if (round % 7 == 0) 300 else 13);
        const h = 1 + random.uintLessThan(u32, 12);
        const ihdr: Ihdr = .{ .width = w, .height = h, .depth = depth, .color = color, .interlaced = interlaced };
        const bits = ihdr.bitsPerPixel();
        const stride = ihdr.rowBytes(w).?;
        const raw = try a.alloc(u8, stride * h);
        defer a.free(raw);
        @memset(raw, 0);
        const max: u64 = (@as(u64, 1) << @intCast(depth)) - 1;
        var palette: [256][3]u8 = undefined;
        random.bytes(std.mem.sliceAsBytes(&palette));
        var alphas: [256]u8 = undefined;
        random.bytes(&alphas);
        const palette_len: u32 = 1 + random.uintAtMost(u32, @intCast(@min(255, max)));
        const alpha_len: u32 = random.uintAtMost(u32, palette_len);
        var key_value: [3]u16 = undefined;
        for (&key_value) |*k| k.* = @intCast(random.uintAtMost(u64, max) & 1);
        for (0..h) |y| for (0..w) |x| {
            var v: u64 = 0;
            for (0..ihdr.channels()) |_| {
                // Small values often, so the tRNS key matches some pixels.
                const s = if (random.boolean()) random.uintAtMost(u64, max) else random.uintAtMost(u64, 1);
                v = v << @intCast(depth) | s;
            }
            setBits(raw[y * stride ..], x, bits, v);
        };

        var png: TestPng = .{};
        defer png.deinit();
        try png.head(w, h, depth, color, interlaced);
        if (color == 3) {
            try png.chunk("PLTE", std.mem.sliceAsBytes(palette[0..palette_len]));
            if (key) try png.chunk("tRNS", alphas[0..alpha_len]);
        } else if (key) {
            var b: [6]u8 = undefined;
            for (0..3) |c| std.mem.writeInt(u16, b[c * 2 ..][0..2], key_value[c], .big);
            try png.chunk("tRNS", b[0..if (color == 0) 2 else 6]);
        }
        var seq: u32 = 0;
        try png.image("IDAT", raw, w, h, bits, interlaced, random, 1 + random.uintLessThan(usize, 200), &seq);
        try png.chunk("IEND", "");

        // The native pixels, from the definitions.
        const nat: PixelFormat = switch (color) {
            0 => if (key)
                (if (depth == 16) .gray_alpha16 else .gray_alpha8)
            else
                (if (depth == 16) .gray16 else .gray8),
            2 => if (key) (if (depth == 16) .rgba16 else .rgba8) else (if (depth == 16) .rgb16 else .rgb8),
            3 => if (key) .rgba8 else .rgb8,
            4 => if (depth == 16) .gray_alpha16 else .gray_alpha8,
            else => if (depth == 16) .rgba16 else .rgba8,
        };
        const want = try a.alloc(u8, PixelBuffer.len(nat, w, h).?);
        defer a.free(want);
        const nbpp = nat.bytesPerPixel();
        for (0..h) |y| for (0..w) |x| {
            const v = getBits(raw[y * stride ..], x, bits);
            var s: [4]u64 = undefined;
            var count: usize = 0;
            if (color == 3) {
                const opaque_black = [3]u8{ 0, 0, 0 };
                const p = if (v < palette_len) palette[v] else opaque_black;
                s[0..3].* = .{ p[0], p[1], p[2] };
                count = 3;
                if (key) {
                    s[3] = if (v < alpha_len) alphas[v] else 255;
                    count = 4;
                }
            } else {
                count = ihdr.channels();
                for (0..count) |c| s[c] = (v >> @intCast((count - 1 - c) * depth)) & max;
                if (key) {
                    var clear = true;
                    for (0..count) |c| clear = clear and s[c] == key_value[c];
                    s[count] = if (clear) 0 else max;
                    count += 1;
                }
                // Depths below 8 scale to 8 bits.
                if (depth < 8) for (s[0..count]) |*c| {
                    c.* = c.* * 255 / max;
                };
            }
            const px = want[(y * w + x) * nbpp ..][0..nbpp];
            for (0..count) |c| {
                if (depth == 16) {
                    std.mem.writeInt(u16, px[c * 2 ..][0..2], @intCast(s[c]), .native);
                } else px[c] = @intCast(s[c]);
            }
        };

        const got = try a.alloc(u8, want.len);
        defer a.free(got);
        const config = try testDecode(png.bytes.items, nat, got);
        try testing.expectEqual(nat, config.native);
        try testing.expectEqual(!key and color != 4 and color != 6, config.is_opaque);
        try testing.expectEqualSlices(u8, want, got);
        // Any other format is the native pixels converted.
        const other: PixelFormat = @enumFromInt(round % 20);
        const conv = try a.alloc(u8, PixelBuffer.len(other, w, h).?);
        defer a.free(conv);
        _ = try testDecode(png.bytes.items, other, conv);
        const conv_want = try a.alloc(u8, conv.len);
        defer a.free(conv_want);
        convert.convert(conv_want, other, want, nat, w * h);
        try testing.expectEqualSlices(u8, conv_want, conv);
    }
}

/// The zlib stream of `bytes` as they are.
fn zlibOf(bytes: []const u8) ![]u8 {
    const a = testing.allocator;
    const z = try a.alloc(u8, zlib.encode.maxCompressedLength(bytes.len));
    errdefer a.free(z);
    return a.realloc(z, try zlib.encode.compress(bytes, z, .{}));
}

/// A 5 by 3 RGB file around the image data `z`, split into two IDAT
/// chunks, with `extra` chunks' bytes before them.
fn rgbFile(t: *TestPng, z: []const u8, extra: []const u8) !void {
    try t.head(5, 3, 8, 2, false);
    try t.bytes.appendSlice(testing.allocator, extra);
    var seq: u32 = 0;
    try t.chunks("IDAT", z, z.len / 2 + 1, &seq);
    try t.chunk("IEND", "");
}

test "an interlaced frame one row tall skips data after its last row" {
    const a = testing.allocator;
    // 5 by 1 RGB, interlaced: passes 1, 2, 4, and 6 hold rows of 1, 1, 1,
    // and 2 pixels, 19 bytes with their filter types; 5 by 2 adds pass 7's
    // row of 5 pixels.
    const zeros: [64]u8 = @splat(0);
    const Case = struct { h: u32, rows: usize, suffix: []const u8 = "", flip: bool = false, err: ?Error };
    const cases = [_]Case{
        .{ .h = 1, .rows = 19, .err = null },
        .{ .h = 1, .rows = 40, .err = null },
        // The skipped data's Adler-32 and the bytes after its stream go
        // unread, as in Wuffs.
        .{ .h = 1, .rows = 40, .flip = true, .suffix = "abc", .err = null },
        // A stream that ends at the last row is checked as any other.
        .{ .h = 1, .rows = 19, .flip = true, .err = error.BadChecksum },
        .{ .h = 1, .rows = 19, .suffix = "\x00", .err = error.TooMuchData },
        .{ .h = 2, .rows = 35, .err = null },
        .{ .h = 2, .rows = 40, .err = error.TooMuchData },
    };
    var out: [5 * 2 * 3]u8 = undefined;
    for (cases) |c| {
        const z = try zlibOf(zeros[0..c.rows]);
        defer a.free(z);
        if (c.flip) z[z.len - 1] ^= 1;
        const data = try std.mem.concat(a, u8, &.{ z, c.suffix });
        defer a.free(data);
        var t: TestPng = .{};
        defer t.deinit();
        try t.head(5, c.h, 8, 2, true);
        var seq: u32 = 0;
        try t.chunks("IDAT", data, 7, &seq);
        try t.chunk("IEND", "");
        const dst = out[0 .. 15 * c.h];
        @memset(dst, 0xaa);
        if (c.err) |e| {
            try testing.expectError(e, testDecode(t.bytes.items, .rgb8, dst));
        } else {
            _ = try testDecode(t.bytes.items, .rgb8, dst);
            try testing.expect(std.mem.allEqual(u8, dst, 0));
        }
    }
}

test "malformed streams" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var raw: [45]u8 = undefined;
    random.bytes(&raw);
    const z = try compressRows(&raw, 5, 3, 24, false, random);
    defer a.free(z);
    var out: [45]u8 = undefined;

    var good: TestPng = .{};
    defer good.deinit();
    try rgbFile(&good, z, "");
    const file = good.bytes.items;
    _ = try testDecode(file, .rgb8, &out);
    try testing.expectEqualSlices(u8, &raw, &out);
    for (0..file.len) |n| try testing.expectError(error.Truncated, testDecode(file[0..n], .rgb8, &out));

    // A critical chunk's CRC is checked: IHDR's, IDAT's, and IEND's.
    const copy = try a.dupe(u8, file);
    defer a.free(copy);
    for ([_]usize{ 32, 33 + 8 + z.len / 2 + 1, file.len - 1 }) |at| {
        @memcpy(copy, file);
        copy[at] ^= 1;
        try testing.expectError(error.BadCrc, testDecode(copy, .rgb8, &out));
        @memset(&out, 0);
        _ = try testDecodeWith(copy, .rgb8, &out, .{ .ignore_checksums = true });
        try testing.expectEqualSlices(u8, &raw, &out);
    }

    const Case = struct { rows: []const u8, err: Error, suffix: []const u8 = "" };
    // Rows of 16 bytes: filter type 0 and 15 zeros.
    const zeros: [4 * 16]u8 = @splat(0);
    var bad_filter = zeros;
    bad_filter[16] = 5;
    const cases = [_]Case{
        .{ .rows = bad_filter[0..48], .err = error.BadFilter },
        .{ .rows = zeros[0..32], .err = error.NotEnoughData },
        .{ .rows = &zeros, .err = error.TooMuchData },
        .{ .rows = zeros[0..48], .err = error.TooMuchData, .suffix = "\x00" },
    };
    for (cases) |c| {
        const zc = try zlibOf(c.rows);
        defer a.free(zc);
        const data = try std.mem.concat(a, u8, &.{ zc, c.suffix });
        defer a.free(data);
        var t: TestPng = .{};
        defer t.deinit();
        try rgbFile(&t, data, "");
        try testing.expectError(c.err, testDecode(t.bytes.items, .rgb8, &out));
    }

    // The Adler-32 and the zlib header.
    const zb = try a.dupe(u8, z);
    defer a.free(zb);
    const flips = [_]struct { at: usize, err: Error }{
        .{ .at = z.len - 1, .err = error.BadChecksum },
        .{ .at = 1, .err = error.BadZlib },
    };
    for (flips) |c| {
        @memcpy(zb, z);
        zb[c.at] ^= 1;
        var t: TestPng = .{};
        defer t.deinit();
        try rgbFile(&t, zb, "");
        try testing.expectError(c.err, testDecode(t.bytes.items, .rgb8, &out));
        if (c.err != error.BadChecksum) continue;
        @memset(&out, 0);
        _ = try testDecodeWith(t.bytes.items, .rgb8, &out, .{ .ignore_checksums = true });
        try testing.expectEqualSlices(u8, &raw, &out);
    }
    // Ignoring the Adler-32 still finds the rows short or too many.
    for ([_]Case{
        .{ .rows = zeros[0..32], .err = error.NotEnoughData },
        .{ .rows = &zeros, .err = error.TooMuchData },
        .{ .rows = zeros[0..48], .err = error.TooMuchData, .suffix = "\x00" },
    }) |c| {
        const zc = try zlibOf(c.rows);
        defer a.free(zc);
        zc[zc.len - 1] ^= 1;
        const data = try std.mem.concat(a, u8, &.{ zc, c.suffix });
        defer a.free(data);
        var t: TestPng = .{};
        defer t.deinit();
        try rgbFile(&t, data, "");
        try testing.expectError(c.err, testDecodeWith(t.bytes.items, .rgb8, &out, .{ .ignore_checksums = true }));
    }

    // An ancillary chunk's CRC is not checked, and an unknown one is
    // skipped; an unknown critical chunk is not.
    var extra: TestPng = .{};
    defer extra.deinit();
    try extra.chunk("gAMA", "\x00\x00\xb1\x8f");
    try extra.chunk("zzZz", "abc");
    extra.bytes.items[extra.bytes.items.len - 1] ^= 1;
    extra.bytes.items[15] ^= 1;
    var t: TestPng = .{};
    defer t.deinit();
    try rgbFile(&t, z, extra.bytes.items);
    try testing.expectEqual(45455, (try testDecode(t.bytes.items, .rgb8, &out)).metadata.gamma);
    try testing.expectEqualSlices(u8, &raw, &out);
    extra.bytes.clearRetainingCapacity();
    try extra.chunk("ZZZZ", "");
    t.bytes.clearRetainingCapacity();
    try rgbFile(&t, z, extra.bytes.items);
    try testing.expectError(error.Unsupported, testDecode(t.bytes.items, .rgb8, &out));

    // Empty IDAT chunks may follow the image data; a full one may not.
    const extras = [_]struct { body: []const u8, err: ?Error }{
        .{ .body = "", .err = null },
        .{ .body = "\x00", .err = error.TooMuchData },
    };
    for (extras) |c| {
        t.bytes.clearRetainingCapacity();
        try t.bytes.appendSlice(a, file[0 .. file.len - 12]);
        try t.chunk("tEXt", "a\x00b");
        try t.chunk("IDAT", c.body);
        try t.chunk("IEND", "");
        if (c.err) |e| {
            try testing.expectError(e, testDecode(t.bytes.items, .rgb8, &out));
        } else _ = try testDecode(t.bytes.items, .rgb8, &out);
    }

    // A palette image needs PLTE.
    t.bytes.clearRetainingCapacity();
    try t.head(1, 1, 8, 3, false);
    try t.chunk("IDAT", z);
    try testing.expectError(error.BadChunk, testDecode(t.bytes.items, .rgb8, &out));

    // Limits apply before any image data, and the buffers are checked.
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_width = 4 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
    r = .fixed(file);
    d = .init(&r, .{ .limits = .{ .max_work = 1000 } });
    try testing.expectError(error.WorkTooLarge, d.decodeConfig());
    r = .fixed(file);
    d = .init(&r, .{});
    const config = try d.decodeConfig();
    const work = try a.alloc(u8, config.work_len);
    defer a.free(work);
    try testing.expectError(error.WorkTooSmall, d.decodeFrame(try PixelBuffer.init(&out, .rgb8, 5, 3), work[1..]));
    try testing.expectError(error.SizeMismatch, d.decodeFrame(try PixelBuffer.init(&out, .rgb8, 3, 5), work));
    _ = try d.decodeFrame(try PixelBuffer.init(&out, .rgb8, 5, 3), work);
}

test "APNG frames: regions, blending, and the default image" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // Frame 0 covers the 4 by 3 canvas; frame 1 is 2 by 2 at (1, 1) and
    // blends over it, with alphas of 255, 0, 128, and 128.
    var f0: [4 * 3 * 4]u8 = undefined;
    random.bytes(&f0);
    for (0..12) |i| f0[i * 4 + 3] = 255;
    f0[(2 * 4 + 2) * 4 ..][0..4].* = .{ 0, 0, 255, 255 };
    const f1 = [16]u8{ 1, 2, 3, 255, 4, 5, 6, 0, 7, 8, 9, 128, 255, 0, 0, 128 };

    for ([_]bool{ false, true }) |default_skipped| {
        var t: TestPng = .{};
        defer t.deinit();
        var seq: u32 = 0;
        var fseq: u32 = 0;
        try t.head(4, 3, 8, 6, false);
        try t.chunk("acTL", "\x00\x00\x00\x02\x00\x00\x00\x03");
        if (default_skipped) {
            // A default image outside the animation, then frame 0 as fdAT.
            const junk: [48]u8 = @splat(9);
            try t.image("IDAT", &junk, 4, 3, 32, false, random, 1000, &seq);
            try t.fctl(&fseq, 4, 3, 0, 0, 0, 0);
            try t.image("fdAT", &f0, 4, 3, 32, false, random, 20, &fseq);
        } else {
            try t.fctl(&fseq, 4, 3, 0, 0, 0, 1);
            try t.image("IDAT", &f0, 4, 3, 32, false, random, 20, &seq);
        }
        try t.fctl(&fseq, 2, 2, 1, 1, 1, 1);
        try t.image("fdAT", &f1, 2, 2, 32, false, random, 1000, &fseq);
        try t.chunk("IEND", "");

        for ([_]PixelFormat{ .rgba8, .rgba16 }) |format| {
            var r: Io.Reader = .fixed(t.bytes.items);
            var d: Decoder = .init(&r, .{});
            const config = try d.decodeConfig();
            try testing.expectEqual(2, config.frame_count);
            try testing.expectEqual(3, config.loop_count);
            const work = try a.alloc(u8, config.work_len);
            defer a.free(work);
            var canvas: [4 * 3 * 8]u8 align(2) = undefined;
            const dst = try PixelBuffer.init(canvas[0 .. 12 * format.bytesPerPixel()], format, 4, 3);
            // In 8 bits, each frame is announced before it is drawn.
            const announce = format == .rgba8;
            const next0 = if (announce) try d.decodeFrameConfig() else null;
            const first = (try d.decodeFrame(dst, work)).?;
            if (announce) try testing.expectEqual(first, next0.?);
            // The first frame's blend is src whatever fcTL says.
            const tenth = decode.flicks_per_second / 10;
            try testing.expectEqual(decode.Frame{ .index = 0, .width = 4, .height = 3, .duration = tenth }, first);
            const next1 = if (announce) try d.decodeFrameConfig() else null;
            const second = (try d.decodeFrame(dst, work)).?;
            if (announce) try testing.expectEqual(second, next1.?);
            if (announce) try testing.expectEqual(null, try d.decodeFrameConfig());
            try testing.expectEqual(decode.Frame{
                .index = 1,
                .x = 1,
                .y = 1,
                .width = 2,
                .height = 2,
                .duration = tenth,
                .disposal = .background,
                .blend = .src_over,
            }, second);
            try testing.expectEqual(null, try d.decodeFrame(dst, work));

            var want: [12][4]u16 = undefined;
            for (&want, 0..) |*p, i| for (p, 0..) |*c, k| {
                c.* = f0[i * 4 + k];
            };
            want[1 * 4 + 1] = .{ 1, 2, 3, 255 };
            // (7, 8, 9, 128) over opaque (r, g, b), then the half-red
            // pixel over opaque blue: src·α + dst·(1 − α).
            for (0..3) |k| {
                const s: u32 = f1[8 + k];
                const t0: u32 = want[2 * 4 + 1][k];
                // In 16 bits, rounded, then narrowed by the high byte.
                const wide: u32 = (s * 257 * 32896 + t0 * 257 * (65535 - 32896) + 32767) / 65535;
                want[2 * 4 + 1][k] = @intCast(wide >> 8);
            }
            want[2 * 4 + 2] = .{ 128, 0, 127, 255 };
            if (format == .rgba8) {
                for (want, 0..) |p, i| for (0..4) |k| try testing.expectEqual(p[k], canvas[i * 4 + k]);
            } else {
                // In 16 bits the half-red pixel is exact: 0x8080 is 128
                // widened, and 65535 − 0x8080 is left of the blue.
                const px: *const [48]u16 = @ptrCast(&canvas);
                const half_red = px[(2 * 4 + 2) * 4 ..][0..4];
                try testing.expectEqualSlices(u16, &.{ 0x8080, 0, 65535 - 0x8080, 65535 }, half_red);
                for (want, 0..) |p, i| {
                    if (i == 2 * 4 + 2 or i == 2 * 4 + 1) continue;
                    for (0..4) |k| try testing.expectEqual(p[k] * 257, px[i * 4 + k]);
                }
            }
        }
    }
}

test "an acTL count past the frame limit fails at the frame past it" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var px: [4]u8 = .{ 1, 2, 3, 255 };
    var t: TestPng = .{};
    defer t.deinit();
    var seq: u32 = 0;
    var fseq: u32 = 0;
    try t.head(1, 1, 8, 6, false);
    try t.chunk("acTL", "\x00\x00\x00\x02\x00\x00\x00\x00");
    try t.fctl(&fseq, 1, 1, 0, 0, 0, 0);
    try t.image("IDAT", &px, 1, 1, 32, false, random, 100, &seq);
    try t.fctl(&fseq, 1, 1, 0, 0, 0, 0);
    try t.image("fdAT", &px, 1, 1, 32, false, random, 100, &fseq);
    try t.chunk("IEND", "");
    var r: Io.Reader = .fixed(t.bytes.items);
    var d: Decoder = .init(&r, .{ .limits = .{ .max_frames = 1 } });
    const config = try d.decodeConfig();
    // The count over the limit is not reported; the frames within it decode.
    try testing.expectEqual(null, config.frame_count);
    const work = try a.alloc(u8, config.work_len);
    defer a.free(work);
    var out: [4]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgba8, 1, 1);
    _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqualSlices(u8, &px, &out);
    try testing.expectError(error.TooManyFrames, d.decodeFrameConfig());
    try testing.expectError(error.TooManyFrames, d.decodeFrame(dst, work));
}

test "a tRNS with a bad CRC applies, in an interlaced APNG too" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // Reduced from an oracle input: gray 4-bit, Adam7, key 3, whose frame 0
    // is the default image. Wuffs applies such a tRNS (it rejects every
    // interlaced APNG, so on a still image); libpng and libspng drop it.
    for ([_]bool{ false, true }) |animated| {
        const raw = [4]u8{ 0x35, 0x30, 0x0f, 0x30 };
        var t: TestPng = .{};
        defer t.deinit();
        var seq: u32 = 0;
        var fseq: u32 = 0;
        try t.head(3, 2, 4, 0, true);
        if (animated) try t.chunk("acTL", "\x00\x00\x00\x01\x00\x00\x00\x00");
        try t.chunk("tRNS", "\x00\x03");
        t.bytes.items[t.bytes.items.len - 1] ^= 1;
        if (animated) try t.fctl(&fseq, 3, 2, 0, 0, 0, 0);
        try t.image("IDAT", &raw, 3, 2, 4, true, random, 100, &seq);
        try t.chunk("IEND", "");
        var out: [24]u8 = undefined;
        _ = try testDecode(t.bytes.items, .rgba8, &out);
        try testing.expectEqualSlices(u8, &[_]u8{
            51, 51, 51, 0,   85,  85,  85,  255, 51, 51, 51, 0,
            0,  0,  0,  255, 255, 255, 255, 255, 51, 51, 51, 0,
        }, &out);
    }
}

test "an eXIf after the image data reaches the final config, other late chunks do not" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // Orientation 6 (right_top), big endian.
    const exif_body = "MM\x00*\x00\x00\x00\x08" ++ "\x00\x01" ++ "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00";
    var raw: [3]u8 = .{ 9, 8, 7 };
    var t: TestPng = .{};
    defer t.deinit();
    var seq: u32 = 0;
    try t.head(1, 1, 8, 2, false);
    try t.image("IDAT", &raw, 1, 1, 24, false, random, 100, &seq);
    try t.chunk("gAMA", "\x00\x00\xb1\x8f");
    try t.chunk("bKGD", "\x00\x01\x00\x02\x00\x03");
    const exif_at = t.bytes.items.len + 8;
    try t.chunk("eXIf", exif_body);
    try t.chunk("IEND", "");
    var r: Io.Reader = .fixed(t.bytes.items);
    var d: ImageDecoder = try .init(.png, &r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(decode.Metadata{}, config.metadata);
    const work = try a.alloc(u8, config.work_len);
    defer a.free(work);
    var out: [3]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgb8, 1, 1);
    while (try d.decodeFrame(dst, work)) |_| {}
    // decodeConfig still gives the first answer; finalConfig adds the eXIf.
    try testing.expectEqual(config, try d.decodeConfig());
    const final = d.finalConfig().?;
    try testing.expectEqual(decode.Metadata{
        .orientation = .right_top,
        .exif = .{ .kind = .exif, .offset = exif_at, .len = exif_body.len },
    }, final.metadata);
    try testing.expectEqual(null, final.background);
}

const ImageDecoder = @import("../Decoder.zig");

test "an APNG canvas has alpha, and frame 0 clears what it does not cover" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    // An RGB animation whose default image is skipped and whose frame 0 is
    // 2 by 1 at (1, 1) on a 3 by 2 canvas.
    var t: TestPng = .{};
    defer t.deinit();
    var seq: u32 = 0;
    var fseq: u32 = 0;
    try t.head(3, 2, 8, 2, false);
    try t.chunk("acTL", "\x00\x00\x00\x01\x00\x00\x00\x00");
    const junk: [18]u8 = @splat(7);
    try t.image("IDAT", &junk, 3, 2, 24, false, random, 100, &seq);
    try t.fctl(&fseq, 2, 1, 1, 1, 0, 0);
    const f0 = [6]u8{ 1, 2, 3, 4, 5, 6 };
    try t.image("fdAT", &f0, 2, 1, 24, false, random, 100, &fseq);
    try t.chunk("IEND", "");
    var r: Io.Reader = .fixed(t.bytes.items);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(PixelFormat.rgba8, config.native);
    try testing.expect(!config.is_opaque);
    const work = try a.alloc(u8, config.work_len);
    defer a.free(work);
    var canvas: [24]u8 = @splat(0xaa);
    const frame0 = (try d.decodeFrame(try PixelBuffer.init(&canvas, .rgba8, 3, 2), work)).?;
    try testing.expect(frame0.is_opaque);
    try testing.expectEqualSlices(u8, &(.{ 0, 0, 0, 0 } ** 4 ++ .{ 1, 2, 3, 255, 4, 5, 6, 255 }), &canvas);
}

test "metadata and blobs, through a reader that trickles" {
    const a = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const exif_body = "MM\x00*\x00\x00\x00\x08" ++ "\x00\x01" ++ "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00";
    var profile: [300]u8 = undefined;
    random.bytes(&profile);
    var t: TestPng = .{};
    defer t.deinit();
    try t.head(19, 7, 4, 0, true);
    try t.chunk("sRGB", "\x00");
    try t.chunk("gAMA", "\x00\x00\xb1\x8f");
    // A second gAMA is ignored.
    try t.chunk("gAMA", "\x00\x00\x00\x01");
    try t.chunk("cHRM", "\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04" ++
        "\x00\x00\x00\x05\x00\x00\x00\x06\x00\x00\x00\x07\x00\x00\x00\x08");
    try t.chunk("pHYs", "\x00\x00\x0b\x13\x00\x00\x0b\x12\x01");
    try t.chunk("bKGD", "\x00\x05");
    const icc_at = t.bytes.items.len + 8;
    const iccp = try std.mem.concat(a, u8, &.{ "ab\x00\x00", &profile });
    defer a.free(iccp);
    try t.chunk("iCCP", iccp);
    const exif_at = t.bytes.items.len + 8;
    try t.chunk("eXIf", exif_body);
    var raw: [7 * 10]u8 = undefined;
    random.bytes(&raw);
    var seq: u32 = 0;
    try t.image("IDAT", &raw, 19, 7, 4, true, random, 9, &seq);
    try t.chunk("IEND", "");
    const file = t.bytes.items;

    var want: [19 * 7]u8 = undefined;
    _ = try testDecode(file, .gray8, &want);
    for (0..7) |y| for (0..19) |x| {
        try testing.expectEqual(17 * getBits(raw[y * 10 ..], x, 4), want[y * 19 + x]);
    };

    const Sink = struct {
        const Self = @This();
        icc: [303]u8 = undefined,
        exif: [exif_body.len]u8 = undefined,
        fn write(context: *anyopaque, blob: decode.Blob, at: u64, bytes: []const u8) void {
            const s: *Self = @ptrCast(@alignCast(context));
            const to: []u8 = if (blob.kind == .icc) &s.icc else &s.exif;
            @memcpy(to[@intCast(at)..][0..bytes.len], bytes);
        }
    };
    var sink: Sink = .{};
    var buffer: [decode.min_buffer_len]u8 = undefined;
    var trickle: Trickle = .{
        .data = file,
        .reader = .{ .vtable = &.{ .stream = Trickle.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
    };
    var d: Decoder = .init(&trickle.reader, .{ .blob_sink = .{ .context = &sink, .write = Sink.write } });
    const config = try d.decodeConfig();
    try testing.expectEqual(decode.Metadata{
        .orientation = .right_top,
        .transfer = .srgb,
        .gamma = 45455,
        .primaries = .{ 3e-5, 4e-5, 5e-5, 6e-5, 7e-5, 8e-5, 1e-5, 2e-5 },
        .density = .{ .x = 2835, .y = 2834, .unit = .per_meter },
        .icc = .{ .kind = .icc, .offset = icc_at + 4, .len = 300, .encoding = .zlib },
        .exif = .{ .kind = .exif, .offset = exif_at, .len = exif_body.len },
    }, config.metadata);
    try testing.expectEqual([4]u8{ 85, 85, 85, 255 }, config.background.?);
    try testing.expectEqualSlices(u8, &profile, sink.icc[0..300]);
    try testing.expectEqualSlices(u8, &profile, file[icc_at + 4 ..][0..300]);
    try testing.expectEqualSlices(u8, exif_body, &sink.exif);
    const work = try a.alloc(u8, config.work_len);
    defer a.free(work);
    var got: [19 * 7]u8 = undefined;
    const dst = try PixelBuffer.init(&got, .gray8, 19, 7);
    _ = try d.decodeFrame(dst, work);
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    try testing.expectEqualSlices(u8, &want, &got);
}

/// A reader that hands over at most 3 bytes per read.
const Trickle = struct {
    data: []const u8,
    reader: Io.Reader,
    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("reader", r);
        if (t.data.len == 0) return error.EndOfStream;
        const n = try w.write(t.data[0..limit.minInt(@min(3, t.data.len))]);
        t.data = t.data[n..];
        return n;
    }
};
