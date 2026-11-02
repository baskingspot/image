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

    // The codestream's size.
    try seeker.seek(seeker.context, 0);
    var d = Decoder.init(r.reader, .{ .limits = r.options.limits });
    const config = try d.decodeConfig();
    p.width = config.width;
    p.height = config.height;
    if (p.width > 0xffff or p.height > 0xffff) return error.BadJbrd;

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
    // Coefficients for three components at up to twice the subsampling
    // of the others, in whole 16-pixel MCUs; the compressed metadata
    // boxes are read into the same bytes before the coefficients.
    const mcus = @as(u64, (p.width + 15) / 16) * ((p.height + 15) / 16);
    var coef_bytes = mcus * 3 * 4 * 64 * 2;
    for ([_]?Box{ p.exif, p.xmp }) |b| if (b) |box| if (box.brotli) {
        coef_bytes = @max(coef_bytes, box.len);
    };
    p.coefs = try take(&total, coef_bytes);
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
        const head = in.peek(8) catch |e| switch (e) {
            error.EndOfStream => {
                if (in.bufferedLen() == 0) break;
                return error.Truncated;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        const size32 = std.mem.readInt(u32, head[0..4], .big);
        const kind = head[4..8].*;
        in.toss(8);
        pos += 8;
        var len: ?u64 = null;
        if (size32 == 1) {
            const big = in.takeArray(8) catch |e| return mapRead(e);
            pos += 8;
            const n = std.mem.readInt(u64, big, .big);
            if (n < 16) return error.BadBox;
            len = n - 16;
        } else if (size32 != 0) {
            if (size32 < 8) return error.BadBox;
            len = size32 - 8;
        }
        if (first) {
            if (!std.mem.eql(u8, &kind, "ftyp")) return error.BadBox;
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
            const inner = in.takeArray(4) catch |e| return mapRead(e);
            pos += 4;
            if (len) |*n| n.* -= 4;
            box = .{ .at = pos, .len = len orelse 0, .brotli = true };
            if (std.mem.eql(u8, inner, "Exif") and boxes.exif == null) note = &boxes.exif;
            if (std.mem.eql(u8, inner, "xml ") and boxes.xmp == null) note = &boxes.xmp;
        }
        if (len) |n| {
            if (note) |slot| slot.* = box;
            in.discardAll64(n) catch |e| return mapRead(e);
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
    try jbrd.split(&j, raw[raw.len - rest ..], p.payload.of(work));

    // The metadata boxes the APP markers copy.
    var img: jbrd.Image = .{
        .width = p.width,
        .height = p.height,
        .h = @splat(1),
        .v = @splat(1),
        .quant = undefined,
        .coefs = @splat(&.{}),
    };
    if (p.exif_len != null) img.exif = try r.readBox(p.exif.?, p.exif_buf.of(work), p.coefs.of(work));
    if (p.xmp_len != null) img.xmp = try r.readBox(p.xmp.?, p.xmp_buf.of(work), p.coefs.of(work));
    return writeWithCoefficients(writer, &j, &img, p.scratch.of(work));
}

/// The coefficients wait for the codestream's coefficient pass
/// (docs/slop/jxl-jbrd.md); until then reconstruction is unsupported.
fn writeWithCoefficients(writer: *Io.Writer, j: *jbrd.Jbrd, img: *jbrd.Image, scratch: []u8) Error!void {
    if (img.coefs[0].len == 0) return error.Unsupported;
    return jbrd.write(writer, j, img, scratch);
}

/// Reads a metadata box's contents into `out`, which must be exactly as
/// long, through Brotli for a `brob` box, whose compressed bytes go to
/// `temp` first.
fn readBox(r: *JpegReconstructor, box: Box, out: []u8, temp: []u8) Error![]const u8 {
    const seeker = r.options.seeker.?;
    try seeker.seek(seeker.context, box.at);
    if (!box.brotli) {
        if (box.len != out.len) return error.BadJbrd;
        r.reader.readSliceAll(out) catch |e| return mapRead(e);
        return out;
    }
    const compressed = temp[0..@intCast(box.len)];
    r.reader.readSliceAll(compressed) catch |e| return mapRead(e);
    try jbrd.decompressExact(compressed, out);
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
