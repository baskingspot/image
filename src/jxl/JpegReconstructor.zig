//! Rebuilds the JPEG a JPEG XL file was transcoded from (`cjxl
//! --lossless_jpeg=1`), byte for byte: the markers, tables, metadata, and
//! entropy-coded scans from the `jbrd` box (jbrd.zig), and the quantized
//! coefficients and quantization tables from the codestream, with no
//! pixels. Allocates nothing: `workLen` states the work memory `run` needs.
//!
//! The box is read twice, once to size the work memory and once into it,
//! and the `Exif`, `xml `, and codestream boxes may come before or after
//! it, so the reader must be able to move back: `Options.seeker` is
//! required (`error.NeedsSeeker`). docs/slop/jxl-jbrd.md records the
//! design.
//!
//!     var r = JpegReconstructor.init(reader, .{ .seeker = .file(&file_reader) });
//!     const work = try gpa.alloc(u8, try r.workLen());
//!     try r.run(writer, work);

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
/// The box and the JPEG writer, for the fuzz target.
pub const jbrd = @import("jbrd.zig");
const Decoder = @import("Decoder.zig");

const JpegReconstructor = @This();

pub const Options = decode.Options;

/// The codestream decoder's errors, the box's, and these.
pub const Error = Decoder.Error || jbrd.Error || error{
    /// The file has no `jbrd` box: it was not transcoded from a JPEG.
    NoJbrd,
    /// `Options.seeker` is null.
    NeedsSeeker,
    /// The writer failed.
    WriteFailed,
};

reader: *Io.Reader,
options: Options,
err: ?Error = null,
/// What `workLen` found, once it has run.
plan: ?Plan = null,

/// Where the boxes are, how large the parsed box is, and where each part
/// of the work memory goes.
const Plan = struct {
    jbrd: Box,
    exif: ?Box = null,
    xmp: ?Box = null,
    /// `jbrd.read`'s counted sizes.
    parsed_len: usize,
    payload_len: usize,
    exif_len: ?u32,
    xmp_len: ?u32,
    icc_len: usize,
    refines: bool,
    width: u32,
    height: u32,
    /// The work memory's parts, in order.
    raw: Span = .{},
    parsed: Span = .{},
    payload: Span = .{},
    exif_buf: Span = .{},
    xmp_buf: Span = .{},
    icc: Span = .{},
    scratch: Span = .{},
    /// The coefficients, and before them the compressed `brob` contents.
    coefs: Span = .{},
    /// The codestream decoder's work memory for the coefficient pass, and
    /// before it the Brotli decoder's (`jbrd.BrotliBuffer`).
    decoder: Span = .{},
    total: usize = 0,
};

const Span = struct {
    at: usize = 0,
    len: usize = 0,

    fn of(s: Span, work: []u8) []u8 {
        return work[s.at..][0..s.len];
    }
};

/// A box's payload: where it starts in the input and its length, and
/// whether it is a `brob` box's Brotli stream.
const Box = struct {
    at: u64,
    len: u64,
    brotli: bool = false,
};

pub fn init(reader: *Io.Reader, options: Options) JpegReconstructor {
    return .{ .reader = reader, .options = options };
}

/// The work memory `run` needs. Reads the container's box headers, the
/// `jbrd` box, and the codestream's headers.
pub fn workLen(r: *JpegReconstructor) Error!usize {
    if (r.err) |e| return e;
    if (r.plan == null) r.plan = r.makePlan() catch |e| {
        r.err = e;
        return e;
    };
    return r.plan.?.total;
}

fn makePlan(r: *JpegReconstructor) Error!Plan {
    const seeker = r.options.seeker orelse return error.NeedsSeeker;
    try seeker.seek(seeker.context, 0);
    const boxes = try r.findBoxes();
    var p: Plan = undefined;
    p = .{
        .jbrd = boxes.jbrd orelse return error.NoJbrd,
        .exif = boxes.exif,
        .xmp = boxes.xmp,
        .parsed_len = 0,
        .payload_len = 0,
        .exif_len = null,
        .xmp_len = null,
        .icc_len = 0,
        .refines = false,
        .width = 0,
        .height = 0,
    };

    try seeker.seek(seeker.context, p.jbrd.at);
    var bits: jbrd.Bits = .init(r.reader, p.jbrd.len);
    var count: jbrd.Mem = .{ .counting = true };
    const j = try jbrd.read(&bits, &count);
    p.parsed_len = count.used;
    p.payload_len = std.math.cast(usize, j.payload_len) orelse return error.WorkTooLarge;
    p.exif_len = j.exif_len;
    p.xmp_len = j.xmp_len;
    p.icc_len = std.math.cast(usize, j.icc_len) orelse return error.WorkTooLarge;
    p.refines = j.refines;
    if ((p.exif_len != null and p.exif == null) or (p.xmp_len != null and p.xmp == null)) return error.BadJbrd;

    // The codestream's size and the coefficient pass's work memory.
    try seeker.seek(seeker.context, 0);
    var d = Decoder.init(r.reader, .{ .limits = r.options.limits });
    const config = try d.decodeConfig();
    p.width = config.width;
    p.height = config.height;
    if (p.width > 0xffff or p.height > 0xffff) return error.BadJbrd;
    const decoder_len = try d.jpegWorkLen();

    // The parts, each aligned to 16 bytes.
    var total: usize = 0;
    const take = struct {
        fn f(t: *usize, len: u64) Error!Span {
            const n = std.math.cast(usize, len) orelse return error.WorkTooLarge;
            const at = std.mem.alignForward(usize, t.*, 16);
            t.* = std.math.add(usize, at, n) catch return error.WorkTooLarge;
            return .{ .at = at, .len = n };
        }
    }.f;
    p.raw = try take(&total, p.jbrd.len);
    p.parsed = try take(&total, p.parsed_len);
    p.payload = try take(&total, p.payload_len);
    if (p.exif_len) |n| p.exif_buf = try take(&total, @as(u64, n) + 4);
    if (p.xmp_len) |n| p.xmp_buf = try take(&total, n);
    p.icc = try take(&total, p.icc_len);
    if (p.refines) p.scratch = try take(&total, jbrd.max_correction_bytes);
    // The coefficients, i16 at any base address, so one byte more than
    // `maxCoefs` takes; the compressed metadata boxes are read into the
    // same bytes before the coefficients.
    var coef_bytes = @as(u64, Decoder.Jpeg.maxCoefs(p.width, p.height)) * 2 + 1;
    for ([_]?Box{ p.exif, p.xmp }) |b| if (b) |box| if (box.brotli) {
        coef_bytes = @max(coef_bytes, box.len);
    };
    p.coefs = try take(&total, coef_bytes);
    const brotli_len = @sizeOf(jbrd.BrotliBuffer) + @alignOf(jbrd.BrotliBuffer) - 1;
    p.decoder = try take(&total, @max(decoder_len, brotli_len));
    p.total = total;
    try r.options.limits.checkWork(total);
    return p;
}

const Boxes = struct {
    jbrd: ?Box = null,
    exif: ?Box = null,
    xmp: ?Box = null,
};

/// Walks the container's box headers from the input's start, skipping
/// payloads, and notes the boxes reconstruction reads.
fn findBoxes(r: *JpegReconstructor) Error!Boxes {
    const in = r.reader;
    var pos: u64 = 0;
    const bad = struct {
        fn f(e: Io.Reader.Error) Error {
            return switch (e) {
                error.EndOfStream => error.BadSignature,
                error.ReadFailed => error.ReadFailed,
            };
        }
    }.f;
    const magic = in.peek(2) catch |e| return bad(e);
    if (magic[0] == 0xff and magic[1] == 0x0a) return error.NoJbrd;
    const sig = in.take(12) catch |e| return bad(e);
    if (!std.mem.eql(u8, sig, "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a")) return error.BadSignature;
    pos = 12;
    var boxes: Boxes = .{};
    var first = true;
    while (true) {
        // The input may end inside a box's header or payload: that ends
        // the walk (see the payload's skip below).
        const head = in.peek(8) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        const size32 = std.mem.readInt(u32, head[0..4], .big);
        const kind = head[4..8].*;
        in.toss(8);
        pos += 8;
        var len: ?u64 = null;
        if (size32 == 1) {
            const big = in.takeArray(8) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            pos += 8;
            const n = std.mem.readInt(u64, big, .big);
            if (n < 16) return error.BadBox;
            len = n - 16;
        } else if (size32 != 0) {
            if (size32 < 8) return error.BadBox;
            len = size32 - 8;
        }
        if (first) {
            // ftyp: the major brand and a file format version libjxl
            // knows (0, or 1 for out-of-order jxlp boxes).
            if (!std.mem.eql(u8, &kind, "ftyp") or (len orelse 0) < 12) return error.BadBox;
            const ftyp = in.peek(8) catch |e| return mapRead(e);
            if (!std.mem.eql(u8, ftyp[0..4], "jxl ") or std.mem.readInt(u32, ftyp[4..8], .big) > 1) return error.BadBox;
            first = false;
        }
        var box: Box = .{ .at = pos, .len = len orelse 0 };
        var note: ?*?Box = null;
        if (std.mem.eql(u8, &kind, "jbrd")) {
            if (boxes.jbrd != null) return error.Unsupported;
            note = &boxes.jbrd;
        } else if (std.mem.eql(u8, &kind, "Exif")) {
            if (boxes.exif == null) note = &boxes.exif;
        } else if (std.mem.eql(u8, &kind, "xml ")) {
            if (boxes.xmp == null) note = &boxes.xmp;
        } else if (std.mem.eql(u8, &kind, "brob") and (len orelse 4) >= 4) {
            const inner = in.takeArray(4) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            pos += 4;
            if (len) |*n| n.* -= 4;
            box = .{ .at = pos, .len = len orelse 0, .brotli = true };
            if (std.mem.eql(u8, inner, "Exif") and boxes.exif == null) note = &boxes.exif;
            if (std.mem.eql(u8, inner, "xml ") and boxes.xmp == null) note = &boxes.xmp;
        }
        if (len) |n| {
            if (note) |slot| slot.* = box;
            // A box that runs past the input's end ends the walk: what it
            // holds is only read if it is one of the boxes noted, and then
            // the read is `Truncated`. libjxl reads no further than the
            // image needs either.
            in.discardAll64(n) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            pos += n;
        } else {
            // A box to the end of the file: its length is what is left.
            const n = in.discardRemaining() catch return error.ReadFailed;
            box.len = n;
            if (note) |slot| slot.* = box;
            break;
        }
    }
    return boxes;
}

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

/// Writes the original JPEG to `writer`, using `work[0..workLen()]`.
pub fn run(r: *JpegReconstructor, writer: *Io.Writer, work: []u8) Error!void {
    const len = try r.workLen();
    if (work.len < len) return error.WorkTooSmall;
    r.runPlan(writer, work) catch |e| {
        r.err = e;
        return e;
    };
}

fn runPlan(r: *JpegReconstructor, writer: *Io.Writer, work: []u8) Error!void {
    const p = &r.plan.?;
    const seeker = r.options.seeker.?;

    // The box, parsed into work memory, and its Brotli stream's contents.
    try seeker.seek(seeker.context, p.jbrd.at);
    const raw = p.raw.of(work);
    r.reader.readSliceAll(raw) catch |e| return mapRead(e);
    var fixed: Io.Reader = .fixed(raw);
    var bits: jbrd.Bits = .init(&fixed, raw.len);
    var mem: jbrd.Mem = .{ .buf = p.parsed.of(work) };
    var j = try jbrd.read(&bits, &mem);
    const rest: usize = @intCast(bits.remaining());
    // The Brotli streams are all read before the coefficient pass, so the
    // Brotli decoder's state shares the codestream decoder's memory.
    const dm = p.decoder.of(work);
    const at = std.mem.alignPointerOffset(dm.ptr, @alignOf(jbrd.BrotliBuffer)).?;
    const brotli: *jbrd.BrotliBuffer = @ptrCast(@alignCast(dm[at..]));
    try jbrd.split(&j, raw[raw.len - rest ..], p.payload.of(work), brotli);

    // The metadata boxes the APP markers copy. A `brob` box's compressed
    // bytes pass through the coefficients' memory, so these come first.
    var exif: ?[]const u8 = null;
    var xmp: ?[]const u8 = null;
    const temp = p.coefs.of(work);
    if (p.exif_len != null) exif = try r.readBox(p.exif.?, p.exif_buf.of(work), temp, brotli);
    if (p.xmp_len != null) xmp = try r.readBox(p.xmp.?, p.xmp_buf.of(work), temp, brotli);

    // The coefficients and quantization tables, and the ICC profile.
    try seeker.seek(seeker.context, 0);
    var icc: IccSink = .{ .buf = p.icc.of(work) };
    var d = Decoder.init(r.reader, .{ .limits = r.options.limits, .blob_sink = icc.sink() });
    _ = try d.decodeConfig();
    const coef_mem = p.coefs.of(work);
    const skip = std.mem.alignPointerOffset(coef_mem.ptr, @alignOf(i16)).?;
    const coefs = std.mem.bytesAsSlice(i16, coef_mem[skip..][0 .. (coef_mem.len - skip) & ~@as(usize, 1)]);
    var jpeg = try d.decodeJpeg(@alignCast(coefs), p.decoder.of(work));
    if (p.icc_len != 0 and (icc.overflow or icc.len != p.icc_len)) return error.BadJbrd;
    try conform(&jpeg, j.num_components);

    var img: jbrd.Image = .{
        .width = p.width,
        .height = p.height,
        .h = jpeg.h,
        .v = jpeg.v,
        .quant = jpeg.quant,
        .coefs = .{ jpeg.coefs[0], jpeg.coefs[1], jpeg.coefs[2] },
        .icc = icc.buf[0..p.icc_len],
        .exif = exif,
        .xmp = xmp,
    };
    // The box's components must lie on the codestream's blocks.
    for (0..j.num_components) |c| {
        if (img.blocksX(j.num_components, c) != jpeg.blocks_x[c] or
            img.blocksY(j.num_components, c) != jpeg.blocks_y[c]) return error.BadJbrd;
    }
    return jbrd.write(writer, &j, &img, p.scratch.of(work));
}

/// Holds the coefficients to libjxl's JPEG bounds, every block of the
/// components the JPEG has, padding included: any coefficient past ±4095
/// is refused. A file cjxl writes is within them. (`decodeJpeg` clamps DC
/// to ±2047 itself, as libjxl does.)
fn conform(jpeg: *Decoder.Jpeg, num_components: u2) Error!void {
    const n: usize = if (num_components == 1) 1 else 3;
    for (jpeg.coefs[0..n]) |coefs| {
        // A block at a time, the bound checked once: a return inside the
        // loop keeps the compiler from vectorizing it.
        var lo: @Vector(64, i16) = @splat(0);
        var hi: @Vector(64, i16) = @splat(0);
        var i: usize = 0;
        while (i < coefs.len) : (i += 64) {
            const x: @Vector(64, i16) = coefs[i..][0..64].*;
            lo = @min(lo, x);
            hi = @max(hi, x);
        }
        if (@reduce(.Min, lo) < -4095 or @reduce(.Max, hi) > 4095) return error.BadJbrd;
    }
}

/// Takes the ICC profile from the codestream decoder's blob sink into
/// `buf`, noting its length; other blobs are the boxes' and ignored.
const IccSink = struct {
    buf: []u8,
    len: u64 = 0,
    overflow: bool = false,

    fn sink(s: *IccSink) decode.BlobSink {
        return .{ .context = s, .write = write };
    }

    fn write(context: *anyopaque, blob: decode.Blob, at: u64, bytes: []const u8) void {
        const s: *IccSink = @ptrCast(@alignCast(context));
        if (blob.kind != .icc) return;
        s.len = @max(s.len, at + bytes.len);
        if (at > s.buf.len or bytes.len > s.buf.len - at) {
            s.overflow = true;
            return;
        }
        @memcpy(s.buf[@intCast(at)..][0..bytes.len], bytes);
    }
};

/// Reads a metadata box's contents into `out`, which must be exactly as
/// long, through Brotli for a `brob` box, whose compressed bytes go to
/// `temp` first.
fn readBox(
    r: *JpegReconstructor,
    box: Box,
    out: []u8,
    temp: []u8,
    brotli: *jbrd.BrotliBuffer,
) Error![]const u8 {
    const seeker = r.options.seeker.?;
    try seeker.seek(seeker.context, box.at);
    if (!box.brotli) {
        if (box.len != out.len) return error.BadJbrd;
        r.reader.readSliceAll(out) catch |e| return mapRead(e);
        return out;
    }
    const compressed = temp[0..@intCast(box.len)];
    r.reader.readSliceAll(compressed) catch |e| return mapRead(e);
    try jbrd.decompressExact(compressed, out, brotli);
    return out;
}

test "a file without a seeker, a jbrd box, or a container" {
    var r: Io.Reader = .fixed("\xff\x0a\x00");
    var x = init(&r, .{});
    try testing.expectError(error.NeedsSeeker, x.workLen());
    r = .fixed("\xff\x0a\x00");
    x = init(&r, .{ .seeker = .fixed(&r) });
    try testing.expectError(error.NoJbrd, x.workLen());
    const file = "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a" ++ "\x00\x00\x00\x14ftypjxl \x00\x00\x00\x00jxl " ++
        "\x00\x00\x00\x0ajxlc\xff\x0a";
    r = .fixed(file);
    x = init(&r, .{ .seeker = .fixed(&r) });
    try testing.expectError(error.NoJbrd, x.workLen());
    try testing.expectError(error.NoJbrd, x.run(undefined, &.{}));
}

test "a transcode rebuilds its JPEG" {
    // `cjxl --lossless_jpeg=1` of an 8 by 8 gray baseline JPEG.
    const file = "\x00\x00\x00\x0c\x4a\x58\x4c\x20\x0d\x0a\x87\x0a\x00\x00\x00\x14\x66\x74\x79\x70\x6a\x78\x6c\x20" ++
        "\x00\x00\x00\x00\x6a\x78\x6c\x20\x00\x00\x00\x13\x6a\x78\x6c\x70\x00\x00\x00\x00\xff\x0a\x41\x40" ++
        "\x50\xdc\x08\x00\x00\x00\x3d\x6a\x62\x72\x64\xc1\x0d\x20\x08\x2d\x03\x02\x00\x84\x80\x08\x00\x00" ++
        "\x00\x80\xfe\x4f\x30\x02\x00\x00\x00\x18\x63\xb2\x45\xff\x07\xf8\x01\x00\x00\x0b\x08\x80\xe0\x00" ++
        "\x10\x4a\x46\x49\x46\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\x03\x00\x00\x00\xb3\x6a\x78\x6c\x70" ++
        "\x80\x00\x00\x01\xe0\x5b\x00\x10\x00\x80\x02\x0c\x64\x0c\x64\x0c\x64\xfe\xff\x0e\x80\x60\x00\x50" ++
        "\x68\x48\x52\x00\x00\x00\x0f\x00\x00\xf0\x00\x00\x00\x00\x00\x00\x00\x00\x04\x2c\x49\x14\x19\xc7" ++
        "\x4e\x48\x73\x87\x01\x08\x29\x70\x0a\x11\x28\x22\xe4\xd8\x28\x06\x04\x00\x30\x61\x00\x00\x00\x98" ++
        "\x9c\x00\x62\xc8\x7a\x5d\x00\x80\x00\xa2\x4b\xd8\xfa\x51\xdd\x3d\xee\x7e\x64\x26\xfe\x0c\xe3\xeb" ++
        "\xa1\x01\x4b\x76\x55\x63\x54\x52\xf4\x8d\x08\x78\xc6\xa7\x9a\x7f\x97\xc6\x16\x18\xfb\x8e\x9f\x05" ++
        "\x21\xf5\x56\x2d\xab\x50\x19\xff\xdd\xfe\x49\xd3\xa9\xf1\xb1\x8f\xd4\xe0\xbb\x29\xde\xc4\xcc\x26" ++
        "\xe5\xcb\x2e\x00\x75\x00\x00\x00\x00\x00\x00\x94\x24\x56\x61\x8c\x8b\x31\x00\x18\x00\x70\xde\x81" ++
        "\x15\xa0\x00";
    const jpeg = "\xff\xd8\xff\xe0\x00\x10\x4a\x46\x49\x46\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xdb\x00\x43" ++
        "\x00\x03\x02\x02\x03\x02\x02\x03\x03\x03\x03\x04\x03\x03\x04\x05\x08\x05\x05\x04\x04\x05\x0a\x07" ++
        "\x07\x06\x08\x0c\x0a\x0c\x0c\x0b\x0a\x0b\x0b\x0d\x0e\x12\x10\x0d\x0e\x11\x0e\x0b\x0b\x10\x16\x10" ++
        "\x11\x13\x14\x15\x15\x15\x0c\x0f\x17\x18\x16\x14\x18\x12\x14\x15\x14\xff\xc0\x00\x0b\x08\x00\x08" ++
        "\x00\x08\x01\x01\x11\x00\xff\xc4\x00\x14\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x01\xff\xc4\x00\x17\x10\x00\x03\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x19\x65\xa3\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x15\x84\x8c\xcf\xff\xd9";
    var r: Io.Reader = .fixed(file);
    var x = init(&r, .{ .seeker = .fixed(&r) });
    const len = try x.workLen();
    const work = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(work);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    // One byte short of the work memory is refused before anything.
    try testing.expectError(error.WorkTooSmall, x.run(&w, work[0 .. len - 1]));
    r = .fixed(file);
    x = init(&r, .{ .seeker = .fixed(&r) });
    try x.run(&w, work[0..len]);
    try testing.expectEqualSlices(u8, jpeg, w.buffered());
}
