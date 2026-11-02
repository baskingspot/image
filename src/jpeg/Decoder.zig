//! A streaming JPEG decoder: reads from a `std.Io.Reader`, writes any
//! `PixelFormat`, and allocates nothing. It needs `Config.work_len` bytes
//! of work memory: the Huffman tables, a few rows of each component, and,
//! for progressive and multi-scan files, every component's coefficients.
//!
//! Format: ITU T.81 (JPEG), with T.871 (JFIF) and Adobe's APP14 for the
//! color transform. Sequential and progressive Huffman-coded DCT images
//! with 8-bit samples, every sampling factor libjpeg-turbo accepts,
//! restart intervals, grayscale, YCbCr, RGB, CMYK, and YCCK, and decoding
//! at 1/2, 1/4, or 1/8 size in the DCT domain (`Options.scale`).
//! Arithmetic coding, lossless (process 14), and 12-bit samples are
//! `Unsupported` so far.
//!
//! The pixels are libjpeg-turbo's with its default settings, bit for bit:
//! its accurate integer IDCT, its "fancy" upsampling, and its YCbCr to RGB
//! (owner decision 2; docs/slop/jpeg.md has the details). CMYK and YCCK
//! images decode to RGB by libjpeg-turbo's naive conversion, or to their
//! stored inks with `Options.cmyk = .raw`.
//!
//! Strict, as libjpeg-turbo is when it treats warnings as errors: a
//! truncated file, a marker segment of the wrong length, an undefined
//! Huffman code, entropy-coded data that ends before its scan or restart
//! interval does, a wrong restart marker, or an inconsistent progression
//! is an error. Bytes that are not a marker between segments are skipped,
//! as the reference skips them. `decodeFrame` reads through EOI.
//!
//! Metadata is reported in `Config` and never applied: JFIF density, the
//! EXIF orientation, and the ICC profile (reassembled from its APP2
//! segments), EXIF, and XMP blobs, which go to the blob sink as they pass.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;
const exif = @import("../exif.zig");
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");
const sample = @import("sample.zig");

const Decoder = @This();

pub const Options = struct {
    limits: decode.Limits = .{},
    blob_sink: ?decode.BlobSink = null,
    /// Decode at a fraction of the size, in the DCT domain, as
    /// libjpeg-turbo's `scale_num / scale_denom` does: the canvas is the
    /// image's size times the scale, rounded up.
    scale: Scale = .full,
    /// A table-specification stream (SOI, then DQT, DHT, DAC, or DRI
    /// segments, then EOI) whose tables apply as if they came before the
    /// image's own: TIFF's JPEGTables, for its abbreviated image streams.
    tables: ?[]const u8 = null,
    /// How to read a three- or four-component image's color: from its
    /// markers and component IDs, as libjpeg-turbo guesses (`auto`), or as
    /// the caller knows it, as TIFF's photometric interpretation says.
    color: ColorHint = .auto,
    /// What a CMYK or YCCK image decodes to.
    cmyk: Cmyk = .rgb,
};

pub const Scale = enum(u2) {
    full,
    half,
    quarter,
    eighth,

    /// The size of a block's samples at this scale.
    fn blockSize(s: Scale) u4 {
        return @as(u4, 8) >> @intFromEnum(s);
    }
};

pub const ColorHint = enum {
    auto,
    /// RGB or CMYK, without a color transform.
    none,
    /// YCbCr or YCCK.
    ycc,
};

pub const Cmyk = enum {
    /// RGB by libjpeg-turbo's naive conversion (each channel is the ink's
    /// stored sample times black's, over the maximum); native is RGB.
    rgb,
    /// The stored inks, C, M, Y, and K in the R, G, B, and A channels of an
    /// RGBA pixel, as Adobe stores them (inverted: 0 is full ink). Native
    /// is `rgba8`, and other formats convert from it as if it were RGBA.
    raw,
};

pub const Error = decode.Error || error{
    /// A marker that is not allowed where it appears, an unknown marker,
    /// or a marker segment whose length or contents break the
    /// specification.
    BadMarker,
    /// A DHT table with more codes than its lengths allow, or a DC symbol
    /// past 15.
    BadHuffmanTable,
    /// A code in the entropy-coded data that its table does not have, or a
    /// refinement coefficient whose size is not 1.
    BadHuffmanCode,
    /// A scan names a component, table, or band the frame does not have:
    /// an unknown component, a component twice, a missing quantization or
    /// Huffman table, more than 10 blocks per MCU, or a spectral band or
    /// successive approximation the progressive process does not allow.
    BadScan,
    /// A progressive scan out of order: an AC scan before the component's
    /// DC scan, or a refinement whose bit position does not follow the
    /// previous scan of its coefficients.
    BadProgression,
    /// A progressive DC coefficient past 32 bits.
    BadCoefficient,
    /// A scan's entropy-coded data ends before its last MCU, or before
    /// the end of a restart interval.
    NotEnoughData,
    /// A restart interval ends at a marker other than the expected RSTn.
    BadRestart,
};

reader: *Io.Reader,
options: Options,
/// The error that stopped the decoder, returned again by later calls.
err: ?Error = null,
state: State = .start,
/// Bytes consumed from `reader`: where blobs start.
pos: u64 = 0,
/// A marker the entropy decoder read when its data ended.
pending: ?u8 = null,

// The frame (SOF).
saw_sof: bool = false,
progressive: bool = false,
precision: u8 = 8,
width: u32 = 0,
height: u32 = 0,
ncomp: u8 = 0,
comps: [4]Component = undefined,

// Tables, as defined so far.
quant: [4][64]u16 = undefined,
quant_set: [4]bool = @splat(false),
dc_spec: [4]huffman.Spec = undefined,
ac_spec: [4]huffman.Spec = undefined,
dc_set: [4]bool = @splat(false),
ac_set: [4]bool = @splat(false),
restart: u16 = 0,

// Markers before the first scan.
jfif: bool = false,
adobe: ?u8 = null,
metadata: decode.Metadata = .{},
icc: Icc = .{},

/// The scan whose header was read last.
scan: Scan = undefined,
/// Progressive: each component's coefficients' successive approximation
/// bit, or -1 before their first scan (G.1.1.1.1).
coef_bits: [4][64]i8 = undefined,
geo: Geometry = undefined,

const State = enum {
    start,
    /// Read through the first SOS header.
    config,
    done,
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    /// The quantization table, latched at the component's first scan, as
    /// libjpeg-turbo's multipliers: 16-bit signed.
    quant: [64]i16 = undefined,
    latched: bool = false,
    // Geometry.
    /// Blocks with image data in them, across and down.
    wb: u32 = 0,
    hb: u32 = 0,
    /// Blocks in the coefficient buffer: whole MCUs.
    bw: u32 = 0,
    bh: u32 = 0,
    /// A block's samples at the chosen scale: 8, 4, 2, or 1.
    ss: u4 = 8,
    /// The component's samples at the chosen scale.
    w: u32 = 0,
    ht: u32 = 0,
    up: sample.Up = .full,
    /// Where its coefficients, sample rows, and upsampled row are in the
    /// work memory, in samples (or coefficients) from their region's
    /// start.
    coef: usize = 0,
    plane: usize = 0,
    stride: usize = 0,
    ring: u32 = 0,
    row: usize = 0,
    // The current scan.
    dc: u8 = 0,
    ac: u8 = 0,
    pred: i32 = 0,
};

const Scan = struct {
    n: u8,
    /// Frame component indices, in scan order.
    comp: [4]u8,
    ss: u8,
    se: u8,
    ah: u4,
    al: u4,
};

const Color = enum { gray, ycc, rgb, cmyk, ycck };

const Geometry = struct {
    hmax: u8,
    vmax: u8,
    min_ss: u4,
    out_w: u32,
    out_h: u32,
    /// The image in MCUs of the interleaved layout.
    mcus_x: u32,
    mcus_y: u32,
    /// Whether every coefficient is kept until the last scan.
    multi: bool,
    /// Whether some component's upsampling reads the rows around it, so
    /// output lags decoding by one MCU row.
    context: bool,
    color: Color,
    native: PixelFormat,
    // Work memory regions, in bytes from the aligned start.
    tables: usize,
    coefs: usize,
    planes: usize,
    rows: usize,
    native_row: usize,
    work_len: usize,
};

const Icc = struct {
    state: enum { none, open, done, bad } = .none,
    next: u8 = 1,
    count: u8 = 0,
    at: u64 = 0,
    blob: decode.Blob = undefined,
};

/// The most samples per block row an MCU may cover (T.81's limit).
const max_blocks_in_mcu = 10;
/// libjpeg-turbo's largest dimension.
const max_dimension = 65500;

const markers = struct {
    const sof0 = 0xc0;
    const sof1 = 0xc1;
    const sof2 = 0xc2;
    const sof3 = 0xc3;
    const dht = 0xc4;
    const sof5 = 0xc5;
    const sof6 = 0xc6;
    const sof7 = 0xc7;
    const jpg = 0xc8;
    const sof9 = 0xc9;
    const sof10 = 0xca;
    const sof11 = 0xcb;
    const dac = 0xcc;
    const sof13 = 0xcd;
    const sof14 = 0xce;
    const sof15 = 0xcf;
    const rst0 = 0xd0;
    const rst7 = 0xd7;
    const soi = 0xd8;
    const eoi = 0xd9;
    const sos = 0xda;
    const dqt = 0xdb;
    const dnl = 0xdc;
    const dri = 0xdd;
    const app0 = 0xe0;
    const app1 = 0xe1;
    const app2 = 0xe2;
    const app14 = 0xee;
    const app15 = 0xef;
    const com = 0xfe;
    const tem = 0x01;
};

/// Starts a decoder on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes. The decoder reads nothing until
/// `decodeConfig` or `decodeFrame`, and stops after EOI.
pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .reader = reader, .options = options };
}

/// Reads the markers through the first scan's header. The native format
/// is `gray8` for one component and `rgb8` for three or four (`rgba8`
/// with `Options.cmyk = .raw`). Calling it again returns the same config.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHeader() catch |e| return d.fail(e);
        d.state = .config;
    }
    return .{
        .width = d.geo.out_w,
        .height = d.geo.out_h,
        .native = d.geo.native,
        .frame_count = 1,
        .work_len = d.geo.work_len,
        .is_opaque = true,
        .metadata = d.metadata,
    };
}

/// Decodes the image into `dst`, which must be the canvas's size, in any
/// format, reading through EOI. Returns null once the image is decoded.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    if (d.state == .done) return null;
    _ = try d.decodeConfig();
    try dst.check();
    if (dst.width != d.geo.out_w or dst.height != d.geo.out_h) return error.SizeMismatch;
    if (work.len < d.geo.work_len) return error.WorkTooSmall;
    d.frame(dst, work) catch |e| return d.fail(e);
    d.state = .done;
    return .{ .width = d.geo.out_w, .height = d.geo.out_h, .is_opaque = true };
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

// Reading marker segments. Every byte goes through these, which count
// `pos`.

fn readByte(d: *Decoder) Error!u8 {
    const b = d.reader.takeByte() catch |e| return mapRead(e);
    d.pos += 1;
    return b;
}

fn readU16(d: *Decoder) Error!u16 {
    const b = d.reader.takeArray(2) catch |e| return mapRead(e);
    d.pos += 2;
    return std.mem.readInt(u16, b, .big);
}

fn readInto(d: *Decoder, buf: []u8) Error!void {
    d.reader.readSliceAll(buf) catch |e| return mapRead(e);
    d.pos += buf.len;
}

fn skip(d: *Decoder, n: usize) Error!void {
    d.reader.discardAll(n) catch |e| return mapRead(e);
    d.pos += n;
}

/// Hands the next `n` bytes to the blob sink as `blob` from offset `at`,
/// keeping the first of them in `prefix`.
fn pass(d: *Decoder, n: usize, blob: decode.Blob, at: u64, prefix: []u8) Error!void {
    var done: usize = 0;
    while (done < n) {
        const got = d.reader.peekGreedy(1) catch |e| return mapRead(e);
        const k = @min(got.len, n - done);
        const bytes = got[0..k];
        if (d.options.blob_sink) |s| s.put(blob, at + done, bytes);
        if (done < prefix.len) {
            const m = @min(prefix.len - done, k);
            @memcpy(prefix[done..][0..m], bytes[0..m]);
        }
        d.reader.toss(k);
        d.pos += k;
        done += k;
    }
}

/// The next marker: one the entropy decoder stopped at, or the next 0xFF
/// (after any fill bytes) followed by a byte other than 0, skipping
/// anything else, as libjpeg-turbo does.
fn nextMarker(d: *Decoder) Error!u8 {
    if (d.pending) |m| {
        d.pending = null;
        return m;
    }
    while (true) {
        var c = try d.readByte();
        while (c != 0xff) c = try d.readByte();
        c = try d.readByte();
        while (c == 0xff) c = try d.readByte();
        if (c != 0) return c;
    }
}

/// A segment's length field, less its own two bytes, or 0 for a length
/// below 2 (which the reference reads as empty).
fn segmentLen(d: *Decoder) Error!usize {
    const len = try d.readU16();
    return if (len < 2) 0 else len - 2;
}

fn readHeader(d: *Decoder) Error!void {
    if (d.options.tables) |t| try d.readTables(t);
    const soi = d.reader.takeArray(2) catch |e| return mapRead(e);
    d.pos += 2;
    if (soi[0] != 0xff or soi[1] != markers.soi) return error.BadSignature;
    while (true) {
        const m = try d.nextMarker();
        if (m == markers.sos) break;
        try d.readMarker(m, true);
    }
    if (!d.saw_sof) return error.BadMarker;
    try d.readSos();
    try d.setup();
}

/// The table-specification stream in `Options.tables`.
fn readTables(d: *Decoder, tables: []const u8) Error!void {
    var r: Io.Reader = .fixed(tables);
    const main = d.reader;
    const pos = d.pos;
    defer {
        d.reader = main;
        d.pos = pos;
    }
    d.reader = &r;
    const soi = r.takeArray(2) catch return error.BadMarker;
    if (soi[0] != 0xff or soi[1] != markers.soi) return error.BadMarker;
    while (true) {
        const m = try d.nextMarker();
        switch (m) {
            markers.eoi => return,
            markers.dht, markers.dqt, markers.dac, markers.dri, markers.com => try d.readMarker(m, false),
            markers.app0...markers.app15 => try d.skip(try d.segmentLen()),
            else => return error.BadMarker,
        }
    }
}

/// Every marker but SOS. `header` is whether the first scan is still to
/// come, when APPn segments are read for metadata.
fn readMarker(d: *Decoder, m: u8, header: bool) Error!void {
    switch (m) {
        markers.sof0, markers.sof1 => try d.readSof(false),
        markers.sof2 => try d.readSof(true),
        // Lossless and arithmetic coding come later; the differential
        // (hierarchical) processes, as in libjpeg-turbo, never.
        markers.sof3, markers.sof9, markers.sof10, markers.sof11 => return error.Unsupported,
        markers.sof5, markers.sof6, markers.sof7, markers.jpg => return error.Unsupported,
        markers.sof13, markers.sof14, markers.sof15 => return error.Unsupported,
        markers.dht => try d.readDht(),
        markers.dqt => try d.readDqt(),
        markers.dac => try d.readDac(),
        markers.dri => {
            if (try d.readU16() != 4) return error.BadMarker;
            d.restart = try d.readU16();
        },
        markers.app0...markers.app15 => if (header) try d.readApp(m) else try d.skip(try d.segmentLen()),
        markers.com, markers.dnl => try d.skip(try d.segmentLen()),
        markers.rst0...markers.rst7, markers.tem => {},
        markers.soi => return error.BadMarker,
        markers.eoi => return error.BadMarker,
        else => return error.BadMarker,
    }
}

fn readSof(d: *Decoder, progressive: bool) Error!void {
    if (d.saw_sof) return error.BadMarker;
    d.saw_sof = true;
    d.progressive = progressive;
    const len = try d.readU16();
    const b = d.reader.takeArray(6) catch |e| return mapRead(e);
    d.pos += 6;
    d.precision = b[0];
    d.height = std.mem.readInt(u16, b[1..3], .big);
    d.width = std.mem.readInt(u16, b[3..5], .big);
    const nc = b[5];
    // A height of 0, to be set by DNL, is unsupported, as in libjpeg-turbo.
    if (d.width == 0 or nc == 0) return error.BadHeader;
    if (d.height == 0) return error.Unsupported;
    if (len != 8 + 3 * @as(u32, nc)) return error.BadMarker;
    const s = d.options.scale.blockSize();
    try d.options.limits.checkSize(ceilDiv(d.width * s, 8), ceilDiv(d.height * s, 8));
    if (d.width > max_dimension or d.height > max_dimension) return error.Unsupported;
    if (d.precision != 8) return error.Unsupported;
    if (nc != 1 and nc != 3 and nc != 4) return error.Unsupported;
    d.ncomp = nc;
    for (d.comps[0..nc]) |*c| {
        const p = d.reader.takeArray(3) catch |e| return mapRead(e);
        d.pos += 3;
        c.* = .{ .id = p[0], .h = p[1] >> 4, .v = p[1] & 15, .tq = p[2] };
        if (c.h < 1 or c.h > 4 or c.v < 1 or c.v > 4) return error.BadHeader;
    }
}

fn readDht(d: *Decoder) Error!void {
    var left: i32 = @as(i32, try d.readU16()) - 2;
    while (left > 16) {
        const index = try d.readByte();
        var spec: huffman.Spec = .{ .counts = undefined, .values = @splat(0) };
        try d.readInto(&spec.counts);
        left -= 17;
        const n = spec.count();
        if (n > 256 or n > left) return error.BadHuffmanTable;
        try d.readInto(spec.values[0..n]);
        left -= @intCast(n);
        const slot = index & 0x0f;
        if (index & 0xf0 == 0x10 and slot < 4) {
            d.ac_spec[slot] = spec;
            d.ac_set[slot] = true;
        } else if (index & 0xf0 == 0 and slot < 4) {
            d.dc_spec[slot] = spec;
            d.dc_set[slot] = true;
        } else return error.BadMarker;
    }
    if (left != 0) return error.BadMarker;
}

fn readDqt(d: *Decoder) Error!void {
    var left: i32 = @as(i32, try d.readU16()) - 2;
    while (left > 0) {
        const pt = try d.readByte();
        const n = pt & 0x0f;
        if (n >= 4) return error.BadMarker;
        // Any nonzero precision nibble is 16-bit, as in libjpeg-turbo.
        const wide = pt >> 4 != 0;
        var raw: [128]u8 = undefined;
        const bytes = raw[0..if (wide) 128 else 64];
        try d.readInto(bytes);
        for (0..64) |i| {
            d.quant[n][huffman.natural[i]] = if (wide) std.mem.readInt(u16, raw[2 * i ..][0..2], .big) else raw[i];
        }
        d.quant_set[n] = true;
        left -= @intCast(1 + bytes.len);
    }
    if (left != 0) return error.BadMarker;
}

/// DAC: checked as libjpeg-turbo checks it, though arithmetic coding is
/// not decoded yet.
fn readDac(d: *Decoder) Error!void {
    var left: i32 = @as(i32, try d.readU16()) - 2;
    while (left > 0) {
        const index = try d.readByte();
        const val = try d.readByte();
        left -= 2;
        if (index >= 8) return error.BadMarker;
        if (index < 4 and val & 0x0f > val >> 4) return error.BadMarker;
    }
    if (left != 0) return error.BadMarker;
}

/// APPn: JFIF, EXIF, XMP, ICC profiles, and Adobe's color transform.
fn readApp(d: *Decoder, m: u8) Error!void {
    const n = try d.segmentLen();
    var head: [32]u8 = undefined;
    switch (m) {
        markers.app0 => {
            const k = @min(n, 14);
            try d.readInto(head[0..k]);
            if (k == 14 and std.mem.eql(u8, head[0..5], "JFIF\x00")) {
                d.jfif = true;
                const x = std.mem.readInt(u16, head[8..10], .big);
                const y = std.mem.readInt(u16, head[10..12], .big);
                if (d.metadata.density == null and x != 0 and y != 0) switch (head[7]) {
                    0 => d.metadata.density = .{ .x = x, .y = y, .unit = .none },
                    1 => d.metadata.density = .{ .x = x, .y = y, .unit = .per_inch },
                    2 => d.metadata.density = .{ .x = @as(u32, x) * 100, .y = @as(u32, y) * 100, .unit = .per_meter },
                    else => {},
                };
            }
            return d.skip(n - k);
        },
        markers.app14 => {
            const k = @min(n, 12);
            try d.readInto(head[0..k]);
            if (k == 12 and std.mem.eql(u8, head[0..5], "Adobe")) d.adobe = head[11];
            return d.skip(n - k);
        },
        markers.app1 => {
            const exif_id = "Exif\x00\x00";
            const xmp_id = "http://ns.adobe.com/xap/1.0/\x00";
            const k = @min(n, exif_id.len);
            try d.readInto(head[0..k]);
            if (k == exif_id.len and std.mem.eql(u8, head[0..k], exif_id)) {
                if (d.metadata.exif != null) return d.skip(n - k);
                const blob: decode.Blob = .{ .kind = .exif, .offset = d.pos, .len = n - k };
                var prefix: [4096]u8 = undefined;
                const p = @min(n - k, prefix.len);
                try d.pass(n - k, blob, 0, prefix[0..p]);
                d.metadata.exif = blob;
                if (exif.orientation(prefix[0..p])) |o| d.metadata.orientation = o;
                return;
            }
            const k2 = @min(n, xmp_id.len);
            try d.readInto(head[k..k2]);
            if (k2 == xmp_id.len and std.mem.eql(u8, head[0..k2], xmp_id) and d.metadata.xmp == null) {
                const blob: decode.Blob = .{ .kind = .xmp, .offset = d.pos, .len = n - k2 };
                try d.pass(n - k2, blob, 0, &.{});
                d.metadata.xmp = blob;
                return;
            }
            return d.skip(n - k2);
        },
        markers.app2 => {
            const id = "ICC_PROFILE\x00";
            const k = @min(n, id.len + 2);
            try d.readInto(head[0..k]);
            if (k == id.len + 2 and std.mem.eql(u8, head[0..id.len], id)) {
                return d.readIcc(head[id.len], head[id.len + 1], n - k);
            }
            return d.skip(n - k);
        },
        else => return d.skip(n),
    }
}

/// One APP2 piece of an ICC profile, `len` bytes, number `seq` of
/// `count`. The pieces must come in order, each count the same, and add up
/// to the size the profile's header gives; then `Config.metadata.icc` is
/// the profile, its offset the first piece's. The sink sees each piece as
/// it passes, at its offset in the reassembled profile.
fn readIcc(d: *Decoder, seq: u8, count: u8, len: usize) Error!void {
    const icc = &d.icc;
    if (icc.state == .done or icc.state == .bad or seq != icc.next or count == 0 or
        (icc.state == .open and count != icc.count))
    {
        if (icc.state == .open) icc.state = .bad;
        if (icc.state == .none) icc.state = .bad;
        return d.skip(len);
    }
    if (seq == 1) {
        // The profile's size is its header's first four bytes.
        var size: [4]u8 = undefined;
        if (len < 4) {
            icc.state = .bad;
            return d.skip(len);
        }
        const peeked = d.reader.peek(4) catch |e| return mapRead(e);
        @memcpy(&size, peeked);
        icc.* = .{
            .state = .open,
            .count = count,
            .blob = .{ .kind = .icc, .offset = d.pos, .len = std.mem.readInt(u32, &size, .big) },
        };
    }
    if (icc.at + len > icc.blob.len) {
        icc.state = .bad;
        return d.skip(len);
    }
    try d.pass(len, icc.blob, icc.at, &.{});
    icc.at += len;
    icc.next +%= 1;
    if (seq == count) {
        if (icc.at == icc.blob.len) {
            icc.state = .done;
            d.metadata.icc = icc.blob;
        } else icc.state = .bad;
    }
}

fn readSos(d: *Decoder) Error!void {
    const len = try d.readU16();
    const n = try d.readByte();
    if (n < 1 or n > 4 or len != 6 + 2 * @as(u32, n)) return error.BadMarker;
    var s: Scan = .{ .n = n, .comp = undefined, .ss = 0, .se = 0, .ah = 0, .al = 0 };
    for (0..n) |i| {
        const b = d.reader.takeArray(2) catch |e| return mapRead(e);
        d.pos += 2;
        // As libjpeg-turbo matches them: the first frame component, among
        // the first four, with this ID and an index no lower than the
        // scan position, and not already in the scan.
        const ci = for (i..@min(d.ncomp, 4)) |ci| {
            if (d.comps[ci].id == b[0]) break ci;
        } else return error.BadScan;
        for (s.comp[0..i]) |prev| if (prev == ci) return error.BadScan;
        s.comp[i] = @intCast(ci);
        d.comps[ci].dc = b[1] >> 4;
        d.comps[ci].ac = b[1] & 15;
    }
    const b = d.reader.takeArray(3) catch |e| return mapRead(e);
    d.pos += 3;
    s.ss = b[0];
    s.se = b[1];
    s.ah = @intCast(b[2] >> 4);
    s.al = @intCast(b[2] & 15);
    d.scan = s;
}

fn ceilDiv(a: u64, b: u64) u32 {
    return @intCast((a + b - 1) / b);
}

/// The geometry and work memory, at the first scan.
fn setup(d: *Decoder) Error!void {
    var g: Geometry = undefined;
    const comps = d.comps[0..d.ncomp];
    g.hmax = 1;
    g.vmax = 1;
    for (comps) |c| {
        g.hmax = @max(g.hmax, c.h);
        g.vmax = @max(g.vmax, c.v);
    }
    g.min_ss = d.options.scale.blockSize();
    g.out_w = ceilDiv(@as(u64, d.width) * g.min_ss, 8);
    g.out_h = ceilDiv(@as(u64, d.height) * g.min_ss, 8);
    g.mcus_x = ceilDiv(d.width, 8 * @as(u32, g.hmax));
    g.mcus_y = ceilDiv(d.height, 8 * @as(u32, g.vmax));
    g.multi = d.progressive or d.scan.n < d.ncomp;
    g.color = try d.colorSpace();
    g.native = switch (g.color) {
        .gray => .gray8,
        .ycc, .rgb => .rgb8,
        .cmyk, .ycck => if (d.options.cmyk == .raw) .rgba8 else .rgb8,
    };
    g.context = false;
    const fancy = g.min_ss > 1;
    for (comps) |*c| {
        // Scale chroma up through the IDCT rather than by upsampling where
        // the ratios allow, as libjpeg-turbo does.
        var ss: u32 = g.min_ss;
        while (ss < 8 and (@as(u32, g.hmax) * g.min_ss) % (c.h * ss * 2) == 0 and
            (@as(u32, g.vmax) * g.min_ss) % (c.v * ss * 2) == 0) ss *= 2;
        c.ss = @intCast(ss);
        c.w = ceilDiv(@as(u64, d.width) * c.h * ss, @as(u64, g.hmax) * 8);
        c.ht = ceilDiv(@as(u64, d.height) * c.v * ss, @as(u64, g.vmax) * 8);
        c.wb = ceilDiv(ceilDiv(@as(u64, d.width) * c.h, g.hmax), 8);
        c.hb = ceilDiv(ceilDiv(@as(u64, d.height) * c.v, g.vmax), 8);
        c.bw = g.mcus_x * c.h;
        c.bh = g.mcus_y * c.v;
        const hin = c.h * ss / g.min_ss;
        const vin = c.v * ss / g.min_ss;
        const hout = g.hmax;
        const vout = g.vmax;
        c.up = if (hin == hout and vin == vout)
            .full
        else if (hin * 2 == hout and vin == vout)
            (if (fancy and c.w > 2) .h2v1 else .{ .box = .{ .h = 2, .v = 1 } })
        else if (hin == hout and vin * 2 == vout and fancy)
            .h1v2
        else if (hin * 2 == hout and vin * 2 == vout)
            (if (fancy and c.w > 2) .h2v2 else .{ .box = .{ .h = 2, .v = 2 } })
        else if (hout % hin == 0 and vout % vin == 0)
            .{ .box = .{ .h = @intCast(hout / hin), .v = @intCast(vout / vin) } }
        else
            return error.Unsupported;
        if (c.up.context()) g.context = true;
    }
    // Work memory: Huffman tables, coefficients, sample rows, upsampled
    // rows, and a row of the native format.
    var off: u64 = 0;
    g.tables = 0;
    off += 8 * @sizeOf(huffman.Table);
    off = std.mem.alignForward(u64, off, 64);
    g.coefs = @intCast(off);
    if (g.multi) {
        var n: u64 = 0;
        for (comps) |*c| {
            c.coef = @intCast(n);
            n += @as(u64, c.bw) * c.bh * 64;
        }
        off += n * 2;
    }
    off = std.mem.alignForward(u64, off, 64);
    g.planes = @intCast(off);
    var n: u64 = 0;
    for (comps) |*c| {
        c.stride = @as(usize, c.bw) * c.ss;
        const rows = c.v * @as(u32, c.ss);
        c.ring = if (g.context) 3 * rows else rows;
        c.plane = @intCast(n);
        n = std.mem.alignForward(u64, n + @as(u64, c.ring) * c.stride, 64);
    }
    off += n;
    g.rows = @intCast(off);
    n = 0;
    for (comps) |*c| {
        c.row = @intCast(n);
        if (c.up != .full) n = std.mem.alignForward(u64, n + @as(u64, c.up.hexp()) * c.stride + 16, 64);
    }
    off += n;
    g.native_row = @intCast(off);
    off += @as(u64, g.out_w) * g.native.bytesPerPixel();
    // Room to align the start.
    off += 64;
    try d.options.limits.checkWork(off);
    g.work_len = std.math.cast(usize, off) orelse return error.WorkTooLarge;
    d.geo = g;
    d.coef_bits = @splat(@splat(-1));
}

/// libjpeg-turbo's guess (or the caller's `Options.color`).
fn colorSpace(d: *const Decoder) Error!Color {
    switch (d.ncomp) {
        1 => return .gray,
        3 => {
            switch (d.options.color) {
                .none => return .rgb,
                .ycc => return .ycc,
                .auto => {},
            }
            if (d.jfif) return .ycc;
            if (d.adobe) |t| return switch (t) {
                0 => .rgb,
                1 => .ycc,
                // The reference warns of an unknown transform.
                else => error.BadMarker,
            };
            const c = d.comps;
            if (c[0].id == 'R' and c[1].id == 'G' and c[2].id == 'B') return .rgb;
            return .ycc;
        },
        else => {
            switch (d.options.color) {
                .none => return .cmyk,
                .ycc => return .ycck,
                .auto => {},
            }
            if (d.adobe) |t| return switch (t) {
                0 => .cmyk,
                2 => .ycck,
                else => error.BadMarker,
            };
            return .cmyk;
        },
    }
}

/// Checks the scan whose header was just read and prepares its tables,
/// in the order libjpeg-turbo does.
fn startScan(d: *Decoder, tables: *[8]huffman.Table) Error!void {
    const s = d.scan;
    var blocks: u32 = 0;
    for (s.comp[0..s.n]) |ci| blocks += @as(u32, d.comps[ci].h) * d.comps[ci].v;
    if (s.n > 1 and blocks > max_blocks_in_mcu) return error.BadScan;
    for (s.comp[0..s.n]) |ci| {
        const c = &d.comps[ci];
        if (c.latched) continue;
        if (c.tq >= 4 or !d.quant_set[c.tq]) return error.BadScan;
        for (&c.quant, d.quant[c.tq]) |*q, v| q.* = @bitCast(v);
        c.latched = true;
    }
    if (d.progressive) {
        const dc_band = s.ss == 0;
        var bad = false;
        if (dc_band) {
            if (s.se != 0) bad = true;
        } else {
            if (s.ss > s.se or s.se >= 64) bad = true;
            if (s.n != 1) bad = true;
        }
        if (s.ah != 0 and @as(u5, s.al) + 1 != s.ah) bad = true;
        if (s.al > 13) bad = true;
        if (bad) return error.BadScan;
        for (s.comp[0..s.n]) |ci| {
            const bits = &d.coef_bits[ci];
            if (!dc_band and bits[0] < 0) return error.BadProgression;
            for (s.ss..@as(usize, s.se) + 1) |k| {
                const expected: i8 = if (bits[k] < 0) 0 else bits[k];
                if (s.ah != expected) return error.BadProgression;
                bits[k] = s.al;
            }
        }
        for (s.comp[0..s.n]) |ci| {
            const c = &d.comps[ci];
            if (dc_band) {
                if (s.ah == 0) try d.table(tables, .dc, c.dc, false);
            } else try d.table(tables, .ac, c.ac, false);
        }
    } else {
        for (s.comp[0..s.n]) |ci| {
            const c = &d.comps[ci];
            try d.table(tables, .dc, c.dc, true);
            try d.table(tables, .ac, c.ac, true);
        }
    }
    for (d.comps[0..d.ncomp]) |*c| c.pred = 0;
}

/// Builds Huffman table `slot` of `kind`. A sequential scan may name table
/// 0 or 1 without a DHT for it: then it is T.81's standard table, as in
/// libjpeg-turbo.
fn table(d: *Decoder, tables: *[8]huffman.Table, kind: enum { dc, ac }, slot: u8, standard: bool) Error!void {
    if (slot >= 4) return error.BadScan;
    const set = if (kind == .dc) d.dc_set else d.ac_set;
    const spec: *const huffman.Spec = if (set[slot])
        (if (kind == .dc) &d.dc_spec[slot] else &d.ac_spec[slot])
    else if (standard and slot < 2) switch (kind) {
        .dc => if (slot == 0) &huffman.standard.dc_luma else &huffman.standard.dc_chroma,
        .ac => if (slot == 0) &huffman.standard.ac_luma else &huffman.standard.ac_chroma,
    } else return error.BadScan;
    const t = &tables[if (kind == .dc) slot else 4 + slot];
    switch (kind) {
        .dc => try t.init(spec, .dc),
        .ac => try t.init(spec, .ac),
    }
}

// Decoding.

/// The work memory, typed.
const Work = struct {
    tables: *[8]huffman.Table,
    coefs: []i16,
    planes: []u8,
    rows: []u8,
    native_row: []u8,
};

fn workMemory(d: *const Decoder, work: []u8) Work {
    const g = d.geo;
    const skew = std.mem.alignForward(usize, @intFromPtr(work.ptr), 64) - @intFromPtr(work.ptr);
    const w = work[skew..][0 .. g.work_len - 64];
    const coef_end = if (g.multi) g.planes else g.coefs;
    return .{
        .tables = @ptrCast(@alignCast(w[g.tables..][0 .. 8 * @sizeOf(huffman.Table)])),
        .coefs = @alignCast(std.mem.bytesAsSlice(i16, w[g.coefs..coef_end])),
        .planes = w[g.planes..g.rows],
        .rows = w[g.rows..g.native_row],
        .native_row = w[g.native_row..],
    };
}

fn frame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!void {
    const w = d.workMemory(work);
    var out: Output = .init(d, dst, w);
    try d.startScan(w.tables);
    if (!d.geo.multi) {
        try d.sequentialDirect(w, &out);
        // A single-scan image ends at EOI; another scan is an error.
        while (true) {
            const m = try d.nextMarker();
            if (m == markers.eoi) return;
            if (m == markers.sos) return error.BadMarker;
            try d.readMarker(m, false);
        }
    }
    @memset(w.coefs, 0);
    while (true) {
        try d.scanToCoefs(w);
        const m = while (true) {
            const m = try d.nextMarker();
            if (m == markers.eoi or m == markers.sos) break m;
            try d.readMarker(m, false);
        };
        if (m == markers.eoi) break;
        try d.readSos();
        try d.startScan(w.tables);
    }
    for (0..d.geo.mcus_y) |my| {
        d.idctRow(w, @intCast(my));
        out.rowDecoded(@intCast(my));
    }
}

/// Where the entropy decoder is in a scan: the restart interval.
const Restarts = struct {
    interval: u16,
    togo: u16,
    next: u3 = 0,
};

/// Ends a restart interval: the next marker must be RSTn.
fn restartMarker(d: *Decoder, br: *huffman.BitReader, r: *Restarts) Error!void {
    try d.endSegment(br);
    const m = try d.nextMarker();
    if (m != markers.rst0 + @as(u8, r.next)) return error.BadRestart;
    r.next +%= 1;
    r.togo = r.interval;
    for (d.comps[0..d.ncomp]) |*c| c.pred = 0;
}

/// Hands the reader back from the entropy decoder: drops the bits it
/// buffered and keeps the marker it stopped at, if any.
fn endSegment(d: *Decoder, br: *huffman.BitReader) Error!void {
    d.pos += br.consumed;
    br.consumed = 0;
    br.reset();
    switch (br.stop) {
        .none => {},
        .marker => |m| d.pending = m,
        .end => return error.Truncated,
    }
    br.stop = .none;
}

fn checkOverrun(br: *const huffman.BitReader) Error!void {
    if (br.overran()) return if (br.stop == .end) error.Truncated else error.NotEnoughData;
}

/// A single-scan sequential image, decoded, transformed, and written row
/// by row.
fn sequentialDirect(d: *Decoder, w: Work, out: *Output) Error!void {
    const g = d.geo;
    const s = d.scan;
    var br: huffman.BitReader = .{ .reader = d.reader };
    var rs: Restarts = .{ .interval = d.restart, .togo = d.restart };
    var block: [64]i16 = @splat(0);
    var qu: idct.Queue = .{};
    for (0..g.mcus_y) |my_| {
        const my: u32 = @intCast(my_);
        if (s.n == 1) {
            // One component: an MCU is one block, rows of blocks as wide
            // as the component.
            const c = &d.comps[s.comp[0]];
            const rows = @min(c.v, c.hb - my * c.v);
            for (0..rows) |j| {
                const row = ringRow(c, my, @intCast(j));
                for (0..c.wb) |bx| {
                    try d.restartPoint(&br, &rs);
                    try d.decodeOne(w, &br, c, &block);
                    try checkOverrun(&br);
                    putBlock(w, c, &block, @intCast(bx), row, &qu);
                }
            }
        } else {
            for (0..g.mcus_x) |mx_| {
                const mx: u32 = @intCast(mx_);
                try d.restartPoint(&br, &rs);
                for (s.comp[0..s.n]) |ci| {
                    const c = &d.comps[ci];
                    for (0..c.v) |j| {
                        for (0..c.h) |i| {
                            try d.decodeOne(w, &br, c, &block);
                            const bx = mx * c.h + @as(u32, @intCast(i));
                            const by = my * c.v + @as(u32, @intCast(j));
                            if (bx < c.wb and by < c.hb) putBlock(w, c, &block, bx, ringRow(c, my, @intCast(j)), &qu);
                            @memset(&block, 0);
                        }
                    }
                }
                try checkOverrun(&br);
            }
        }
        qu.flush();
        out.rowDecoded(my);
    }
    try d.endSegment(&br);
}

inline fn restartPoint(d: *Decoder, br: *huffman.BitReader, rs: *Restarts) Error!void {
    if (rs.interval == 0) return;
    if (rs.togo == 0) {
        try d.restartMarker(br, rs);
        br.* = .{ .reader = d.reader };
    }
    rs.togo -= 1;
}

inline fn decodeOne(d: *Decoder, w: Work, br: *huffman.BitReader, c: *Component, block: *[64]i16) Error!void {
    _ = d;
    try huffman.sequential(br, &w.tables[c.dc], &w.tables[4 + c.ac], &c.pred, block);
}

/// Where block row `j` of iMCU row `my` starts in the component's ring of
/// rows: three iMCU rows when upsampling needs the rows around, else one.
inline fn ringRow(c: *const Component, my: u32, j: u32) usize {
    const per = c.v * @as(u32, c.ss);
    const slot = if (c.ring == per) 0 else my % 3;
    return (slot * c.v + j) * @as(usize, c.ss);
}

/// The inverse DCT of a block into row `row` of the component's ring;
/// zeroes the block.
fn putBlock(w: Work, c: *const Component, block: *[64]i16, bx: u32, row: usize, qu: *idct.Queue) void {
    const out = w.planes[c.plane + row * c.stride + bx * @as(usize, c.ss) ..];
    transform(c, block, out, qu);
    @memset(block, 0);
}

/// The inverse DCT of a block into `out`: full-size blocks through `qu`,
/// which may hold one until the next block or its flush.
fn transform(c: *const Component, block: *const [64]i16, out: []u8, qu: *idct.Queue) void {
    if (c.ss == 8) return qu.put(.{ .block = block, .q = &c.quant, .out = out, .stride = c.stride });
    const ac = !idct.acZero(block);
    switch (c.ss) {
        inline 4, 2, 1 => |n| {
            if (!ac) {
                idct.dcOnly(8, n, block[0], c.quant[0], out, c.stride);
            } else {
                idct.idct(8, n, block, &c.quant, out, c.stride);
            }
        },
        else => unreachable,
    }
}

/// Decodes the current scan into the coefficient buffer.
fn scanToCoefs(d: *Decoder, w: Work) Error!void {
    const s = d.scan;
    const Kind = enum { sequential, dc_first, dc_refine, ac_first, ac_refine };
    const kind: Kind = if (!d.progressive)
        .sequential
    else if (s.ss == 0)
        (if (s.ah == 0) .dc_first else .dc_refine)
    else if (s.ah == 0) .ac_first else .ac_refine;
    switch (kind) {
        inline else => |k| try d.scanLoop(w, k),
    }
}

fn scanLoop(d: *Decoder, w: Work, comptime kind: anytype) Error!void {
    const g = d.geo;
    const s = d.scan;
    var br: huffman.BitReader = .{ .reader = d.reader };
    var rs: Restarts = .{ .interval = d.restart, .togo = d.restart };
    var prog: huffman.Progressive = .{};
    if (s.n == 1) {
        const c = &d.comps[s.comp[0]];
        for (0..c.hb) |by| {
            for (0..c.wb) |bx| {
                try d.restartPoint(&br, &rs);
                if (rs.interval != 0 and rs.togo + 1 == rs.interval) prog = .{};
                const block = coefBlock(w, c, @intCast(bx), @intCast(by));
                try decodeBlock(kind, w, &br, c, &prog, s, block);
                try checkOverrun(&br);
            }
        }
    } else {
        for (0..g.mcus_y) |my| {
            for (0..g.mcus_x) |mx| {
                try d.restartPoint(&br, &rs);
                if (rs.interval != 0 and rs.togo + 1 == rs.interval) prog = .{};
                for (s.comp[0..s.n]) |ci| {
                    const c = &d.comps[ci];
                    for (0..c.v) |j| {
                        for (0..c.h) |i| {
                            const bx = @as(u32, @intCast(mx)) * c.h + @as(u32, @intCast(i));
                            const by = @as(u32, @intCast(my)) * c.v + @as(u32, @intCast(j));
                            const block = coefBlock(w, c, bx, by);
                            try decodeBlock(kind, w, &br, c, &prog, s, block);
                        }
                    }
                }
                try checkOverrun(&br);
            }
        }
    }
    try d.endSegment(&br);
}

fn coefBlock(w: Work, c: *const Component, bx: u32, by: u32) *[64]i16 {
    return w.coefs[c.coef + (@as(usize, by) * c.bw + bx) * 64 ..][0..64];
}

inline fn decodeBlock(
    comptime kind: anytype,
    w: Work,
    br: *huffman.BitReader,
    c: *Component,
    prog: *huffman.Progressive,
    s: Scan,
    block: *[64]i16,
) Error!void {
    switch (kind) {
        .sequential => {
            // A sequential scan of a multi-scan image replaces the block.
            @memset(block, 0);
            try huffman.sequential(br, &w.tables[c.dc], &w.tables[4 + c.ac], &c.pred, block);
        },
        .dc_first => try huffman.dcFirst(br, &w.tables[c.dc], &c.pred, s.al, block),
        .dc_refine => try huffman.dcRefine(br, s.al, block),
        .ac_first => try huffman.acFirst(br, &w.tables[4 + c.ac], prog, s.ss, s.se, s.al, block),
        .ac_refine => try huffman.acRefine(br, &w.tables[4 + c.ac], prog, s.ss, s.se, s.al, block),
    }
}

/// The inverse DCT of iMCU row `my` from the coefficient buffer.
fn idctRow(d: *Decoder, w: Work, my: u32) void {
    var qu: idct.Queue = .{};
    defer qu.flush();
    for (d.comps[0..d.ncomp]) |*c| {
        const rows = @min(c.v, c.hb -| my * c.v);
        for (0..rows) |j| {
            const by = my * c.v + @as(u32, @intCast(j));
            const row = ringRow(c, my, @intCast(j));
            for (0..c.wb) |bx| {
                const block = coefBlock(w, c, @intCast(bx), by);
                transform(c, block, w.planes[c.plane + row * c.stride + bx * @as(usize, c.ss) ..], &qu);
            }
        }
    }
}

/// Upsampling, color conversion, and writing rows, as MCU rows of samples
/// become ready.
const Output = struct {
    d: *Decoder,
    dst: PixelBuffer,
    w: Work,
    conv: ?Converter,

    fn init(d: *Decoder, dst: PixelBuffer, w: Work) Output {
        const native = d.geo.native;
        return .{
            .d = d,
            .dst = dst,
            .w = w,
            .conv = if (dst.format == native) null else Converter.init(dst.format, native),
        };
    }

    /// Called once iMCU row `my` is in the component rows: writes the
    /// rows that are complete.
    fn rowDecoded(o: *Output, my: u32) void {
        const g = o.d.geo;
        if (!g.context) return o.emit(my);
        if (my > 0) o.emit(my - 1);
        if (my + 1 == g.mcus_y) o.emit(my);
    }

    fn emit(o: *Output, my: u32) void {
        const g = o.d.geo;
        const per = @as(u32, g.vmax) * g.min_ss;
        const y0 = my * per;
        const y1 = @min(y0 + per, g.out_h);
        var y = y0;
        while (y < y1) : (y += 1) o.row(y);
    }

    fn planeRow(o: *const Output, c: *const Component, r: u32) []const u8 {
        const i = r % c.ring;
        return o.w.planes[c.plane + i * c.stride ..][0..c.stride];
    }

    fn row(o: *Output, y: u32) void {
        const d = o.d;
        const g = d.geo;
        var rows: [4][]const u8 = undefined;
        for (d.comps[0..d.ncomp], 0..) |*c, i| {
            const buf = o.w.rows[c.row..];
            rows[i] = switch (c.up) {
                .full => o.planeRow(c, y),
                .h2v1 => blk: {
                    sample.h2v1(u8, buf, o.planeRow(c, y), c.w);
                    break :blk buf;
                },
                .h1v2, .h2v2 => blk: {
                    const k = y / 2;
                    const far = if (y % 2 == 0) k -| 1 else @min(k + 1, c.ht - 1);
                    if (c.up == .h1v2) {
                        sample.h1v2(u8, buf, o.planeRow(c, k), o.planeRow(c, far), c.w, if (y % 2 == 0) 1 else 2);
                    } else {
                        sample.h2v2(u8, buf, o.planeRow(c, k), o.planeRow(c, far), c.w);
                    }
                    break :blk buf;
                },
                .box => |b| blk: {
                    sample.box(u8, buf, o.planeRow(c, y / b.v), c.w, b.h);
                    break :blk buf;
                },
            };
        }
        const n = g.out_w;
        const target = if (o.conv == null) o.dst.row(y) else o.w.native_row;
        switch (g.color) {
            .gray => @memcpy(target[0..n], rows[0][0..n]),
            .ycc => sample.yccToRgb(target, rows[0], rows[1], rows[2], n),
            .rgb => for (0..n) |x| {
                target[3 * x ..][0..3].* = .{ rows[0][x], rows[1][x], rows[2][x] };
            },
            .cmyk, .ycck => for (0..n) |x| {
                var p: [4]u8 = .{ rows[0][x], rows[1][x], rows[2][x], rows[3][x] };
                if (g.color == .ycck) {
                    // YCC to RGB, inverted, as the inks.
                    const rgb = sample.ycc(8, p[0], p[1], p[2]);
                    p[0..3].* = .{ @intCast(255 - rgb[0]), @intCast(255 - rgb[1]), @intCast(255 - rgb[2]) };
                }
                if (d.options.cmyk == .raw) {
                    target[4 * x ..][0..4].* = p;
                } else {
                    target[3 * x ..][0..3].* = .{
                        @intCast(sample.cmyk(8, p[0], p[3])),
                        @intCast(sample.cmyk(8, p[1], p[3])),
                        @intCast(sample.cmyk(8, p[2], p[3])),
                    };
                }
            },
        }
        if (o.conv) |conv| conv.run(o.dst.row(y), o.w.native_row, n);
    }
};

// Tests.

/// Decodes `file` as `format`, checking the second call returns null.
fn testDecode(file: []const u8, format: PixelFormat, options: Options, out: []u8) !decode.Config {
    var r: Io.Reader = .fixed(file);
    var d: Decoder = .init(&r, options);
    const config = try d.decodeConfig();
    const work = try testing.allocator.alloc(u8, config.work_len);
    defer testing.allocator.free(work);
    const dst = try PixelBuffer.init(out, format, config.width, config.height);
    _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    return config;
}

test "a tiny baseline file" {
    // 8×8 gray, one flat block of DC 0: every sample 128.
    const file = "\xff\xd8" ++
        "\xff\xdb\x00\x43\x00" ++ "\x01" ** 64 ++
        "\xff\xc0\x00\x0b\x08\x00\x08\x00\x08\x01\x01\x11\x00" ++
        "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00" ++
        // DC category 0 (00), EOB (1010), padded with ones.
        "\x28\xff\xd9" ++ "";
    var out: [64]u8 = undefined;
    const config = try testDecode(file, .gray8, .{}, &out);
    try testing.expectEqual(PixelFormat.gray8, config.native);
    for (out) |s| try testing.expectEqual(128, s);
    // Every truncation fails.
    for (0..file.len) |n| {
        var r: Io.Reader = .fixed(file[0..n]);
        var d: Decoder = .init(&r, .{});
        const c = d.decodeConfig() catch continue;
        const work = try testing.allocator.alloc(u8, c.work_len);
        defer testing.allocator.free(work);
        try testing.expectError(error.Truncated, d.decodeFrame(try PixelBuffer.init(&out, .gray8, 8, 8), work));
    }
}
