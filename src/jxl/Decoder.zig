//! A streaming JPEG XL decoder: reads a bare codestream or a container from
//! a `std.Io.Reader`, writes any `PixelFormat`, and allocates nothing.
//!
//! Format: ISO/IEC 18181-1 (the codestream) and 18181-2 (the container).
//! docs/slop/jxl.md records the design, the work-memory bound, and the
//! choices made where the specification leaves room.
//!
//! Frames are coalesced as the reference decoder does: `decodeFrame`
//! returns each displayed frame (the last, and every one with a duration)
//! composited onto the canvas, after the zero-duration frames before it.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");
const PixelFormat = @import("../pixel.zig").PixelFormat;
const PixelBuffer = @import("../pixel.zig").PixelBuffer;
const Converter = @import("../convert.zig").Converter;

const BitReader = @import("BitReader.zig");
const headers = @import("headers.zig");
const entropy = @import("entropy.zig");
const Arena = @import("Arena.zig");
const modular = @import("modular.zig");
const frame = @import("frame.zig");
const icc = @import("icc.zig");

const Decoder = @This();

pub const Options = decode.Options;

pub const Error = decode.Error || error{
    /// A container box breaks ISO/IEC 18181-2.
    BadBox,
    /// An entropy-coded stream is malformed.
    BadEntropy,
    /// The image data breaks the specification: an invalid tree,
    /// transform, channel layout, or blend.
    BadImage,
    /// The embedded ICC profile's encoding is malformed.
    BadIcc,
    /// The file needs more work memory than `Config.work_len` reserves:
    /// entropy codes or trees past the budget docs/slop/jxl.md describes,
    /// or a frame of more than twice the canvas's pixels.
    TooComplex,
};

options: Options,
br: BitReader,
err: ?Error = null,
state: State = .start,
image: headers.ImageHeader = undefined,
/// The encoded ICC profile's size, until the profile is read.
icc_size: ?u64 = null,
/// The next frame's header, when already read.
next_frame: ?headers.FrameHeader = null,
/// Whether frames may need the canvas and reference slots.
needs_refs: bool = true,
work_len: usize = 0,
index: u32 = 0,
store: Store = .{},

const State = enum { start, config, frames, done };

/// The composited canvas and the four reference slots, float planes of
/// the canvas's size at the start of work memory.
const Store = struct {
    ready: bool = false,
    canvas: [max_planes][]f32 = undefined,
    slots: [4]Slot = @splat(.{}),
    planes: usize = 0,
    /// Where per-frame memory starts.
    frame_mark: usize = 0,
    arena: Arena = .{ .buf = &.{} },
};

const Slot = struct {
    planes: [max_planes][]f32 = undefined,
    /// Holds a frame.
    valid: bool = false,
    /// Covers the canvas from its origin.
    full: bool = false,
    /// Saved before the color transform.
    before_ct: bool = false,
};

const max_planes = 3 + headers.max_extra_channels;

pub fn init(reader: *Io.Reader, options: Options) Decoder {
    return .{ .options = options, .br = .init(reader, options.blob_sink) };
}

/// Reads the headers: the signature, size, and image metadata.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    if (d.err) |e| return e;
    if (d.state == .start) {
        d.readHeaders() catch |e| return d.fail(e);
        d.state = .config;
    }
    const h = &d.image;
    return .{
        .width = h.width,
        .height = h.height,
        .native = d.native(),
        .frame_count = if (h.animation == null) 1 else null,
        .loop_count = if (h.animation) |a| a.num_loops else null,
        .work_len = d.work_len,
        .is_opaque = h.alphaChannel() == null,
        .metadata = d.metadata(),
    };
}

fn readHeaders(d: *Decoder) Error!void {
    const br = &d.br;
    const sig = try br.bits(16);
    if (sig != 0x0aff) return error.BadSignature;
    d.image = try headers.ImageHeader.read(br);
    try d.options.limits.checkSize(d.image.width, d.image.height);
    if (d.image.animation == null) try d.options.limits.checkFrames(1);
    if (d.image.colour.want_icc) {
        const size = try br.u64Field();
        if (size > icc.max_size) return error.BadIcc;
        d.icc_size = size;
    } else if (d.image.preview == null) {
        try br.zeroPadToByte();
        const fh = try headers.FrameHeader.read(br, &d.image, false);
        d.next_frame = fh;
        // One frame that covers the canvas needs no canvas or slots.
        d.needs_refs = !(fh.is_last and !fh.have_crop and d.image.animation == null);
    }
    d.work_len = try d.workBound();
    try d.options.limits.checkWork(d.work_len);
}

fn planeCount(h: *const headers.ImageHeader) usize {
    return h.colourChannels() + h.num_ec;
}

/// The work memory bound (docs/slop/jxl.md, work memory).
fn workBound(d: *const Decoder) Error!usize {
    const h = &d.image;
    const px: u128 = @as(u128, h.width) * h.height;
    const c: u128 = planeCount(h);
    const plane = px * 4;
    var total: u128 = 0;
    if (d.needs_refs) total += 5 * c * plane;
    // A Modular frame, which may be up to twice the canvas: its channels,
    // twice more for undoing squeezes (each step's output is new), one
    // more for a delta palette's indices, and the largest palette.
    const fpx = frame_scale * px;
    total += 3 * c * fpx * 4 + fpx * 4 + 4 * 137_728 * c;
    // A group's channels with their transforms, at the peeked frame's
    // group size or the largest.
    const gd: u128 = if (d.next_frame) |f| @as(u128, 128) << @intCast(f.group_size_shift) else 1024;
    const group_px: u128 = @min(gd * gd, px);
    total += 4 * c * 4 * group_px;
    // The global tree and one local tree.
    const node: u128 = @sizeOf(modular.Node);
    total += @as(u128, @min(1 << 22, 1024 + fpx * c / 16)) * node;
    total += @as(u128, @min(1 << 20, 1024 + group_px * c)) * node;
    // Entropy codes: three live at once, each with tables and a window.
    const window: u128 = entropy.window_size;
    total += 3 * (entropy_budget + 4 * @as(u128, @min(px * c, window)));
    // Rows of reference properties and the weighted predictor.
    total += 1088 * @as(u128, h.width) + 65536;
    if (d.icc_size) |s| total = @max(total, icc.workLen(s) + entropy_budget + 4 * @as(u128, @min(s, window)) + 65536);
    return std.math.cast(usize, total) orelse error.WorkTooLarge;
}

/// How many times the canvas's pixels a frame may have; a larger frame
/// is `TooComplex`.
const frame_scale = 2;

/// The work memory each entropy code's tables may take.
const entropy_budget: u128 = 1 << 20;

/// Whether a channel of this depth converts to 8 bits without loss: its
/// maximum divides 255.
fn exact8(depth: headers.BitDepth) bool {
    return !depth.float and (depth.bits == 1 or depth.bits == 2 or depth.bits == 4 or depth.bits == 8);
}

fn isFloat(h: *const headers.ImageHeader) bool {
    if (h.depth.float or h.depth.bits > 16) return true;
    if (h.alphaChannel()) |a| {
        const e = h.ec[a].depth;
        if (e.float or e.bits > 16) return true;
    }
    return false;
}

fn native(d: *const Decoder) PixelFormat {
    const h = &d.image;
    if (isFloat(h)) return if (premultiplied(h)) .rgba_f32_premul else .rgba_f32;
    var eight = exact8(h.depth);
    if (h.alphaChannel()) |a| eight = eight and exact8(h.ec[a].depth);
    const p = pivot16(h);
    if (!eight) return p;
    return switch (p) {
        .gray16 => .gray8,
        .gray_alpha16 => .gray_alpha8,
        .gray_alpha16_premul => .gray_alpha8_premul,
        .rgb16 => .rgb8,
        .rgba16 => .rgba8,
        .rgba16_premul => .rgba8_premul,
        else => unreachable,
    };
}

fn premultiplied(h: *const headers.ImageHeader) bool {
    const a = h.alphaChannel() orelse return false;
    return h.ec[a].alpha_associated;
}

/// The 16-bit format frames are written through.
fn pivot16(h: *const headers.ImageHeader) PixelFormat {
    const grey = h.colour.space == .grey;
    if (h.alphaChannel() == null) return if (grey) .gray16 else .rgb16;
    const premul = premultiplied(h);
    if (grey) return if (premul) .gray_alpha16_premul else .gray_alpha16;
    return if (premul) .rgba16_premul else .rgba16;
}

fn pivot(h: *const headers.ImageHeader) PixelFormat {
    if (isFloat(h)) return if (premultiplied(h)) .rgba_f32_premul else .rgba_f32;
    return pivot16(h);
}

fn metadata(d: *const Decoder) decode.Metadata {
    const h = &d.image;
    var m: decode.Metadata = .{ .orientation = @enumFromInt(h.orientation) };
    const c = &h.colour;
    if (!c.want_icc and c.space != .xyb) {
        if (c.have_gamma) {
            m.gamma = c.gamma / 100;
        } else switch (c.transfer) {
            .srgb => m.transfer = .srgb,
            .linear => m.transfer = .linear,
            else => {},
        }
    }
    m.exif = d.br.src.exif;
    m.xmp = d.br.src.xmp;
    return m;
}

/// Decodes the next displayed frame into `dst`.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    _ = try d.decodeConfig();
    if (d.state == .done) return null;
    try dst.check();
    if (dst.width != d.image.width or dst.height != d.image.height) return error.SizeMismatch;
    if (work.len < d.work_len) return error.WorkTooSmall;
    return d.nextFrame(dst, work[0..d.work_len]) catch |e| d.fail(e);
}

fn nextFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    const st = &d.store;
    if (d.state == .config) {
        st.arena = .init(work);
        if (d.icc_size) |size| {
            const m = st.arena.mark();
            const profile = icc.read(&d.br, &st.arena, size) catch |e| return mapIcc(e);
            if (d.options.blob_sink) |sink| {
                const blob: decode.Blob = .{ .kind = .icc, .offset = 0, .len = profile.len };
                sink.put(blob, 0, profile);
            }
            st.arena.release(m);
            d.icc_size = null;
        }
        if (d.next_frame == null) {
            try d.br.zeroPadToByte();
            if (d.image.preview != null) try d.skipPreview();
        }
        if (d.needs_refs) {
            const px = @as(usize, d.image.width) * d.image.height;
            st.planes = planeCount(&d.image);
            for (st.canvas[0..st.planes]) |*p| p.* = try st.arena.alloc(f32, px);
            for (&st.slots) |*s| {
                for (s.planes[0..st.planes]) |*p| p.* = try st.arena.alloc(f32, px);
            }
        }
        st.frame_mark = st.arena.mark();
        d.state = .frames;
    }
    while (true) {
        const fh = if (d.next_frame) |f| f else try headers.FrameHeader.read(&d.br, &d.image, false);
        d.next_frame = null;
        defer st.arena.release(st.frame_mark);
        var blended = false;
        const shown = try d.oneFrame(&fh, dst, &blended);
        if (fh.is_last) {
            try d.br.src.finish();
            d.state = .done;
        }
        if (shown) {
            defer d.index += 1;
            return .{
                .index = d.index,
                .width = d.image.width,
                .height = d.image.height,
                .duration = d.flicks(fh.duration),
                .is_opaque = d.image.alphaChannel() == null,
                .blend = if (blended) .src_over else .src,
            };
        }
        if (fh.is_last) return null;
    }
}

fn flicks(d: *const Decoder, ticks: u32) u64 {
    const a = d.image.animation orelse return 0;
    if (a.tps_numerator == 0) return 0;
    const v = @as(u128, ticks) * decode.flicks_per_second * a.tps_denominator / a.tps_numerator;
    return @intCast(@min(v, std.math.maxInt(u64)));
}

fn mapIcc(e: icc.Error) Error {
    return switch (e) {
        error.BadIcc => error.BadIcc,
        else => |x| x,
    };
}

fn skipPreview(d: *Decoder) Error!void {
    const st = &d.store;
    const m = st.arena.mark();
    defer st.arena.release(m);
    const fh = try headers.FrameHeader.read(&d.br, &d.image, true);
    const dims: headers.Dims = .init(&fh);
    const toc = try frame.readToc(&d.br, &st.arena, &dims, fh.passes.num);
    try d.br.skipBits(toc.total * 8);
}

fn canBeReferenced(fh: *const headers.FrameHeader) bool {
    return !fh.is_last and fh.kind != .lf and (fh.duration == 0 or fh.save_as_reference != 0);
}

fn needsBlending(fh: *const headers.FrameHeader, num_ec: u32) bool {
    if (fh.kind != .regular and fh.kind != .skip_progressive) return false;
    var replace_all = fh.blending.mode == .replace;
    for (fh.ec_blending[0..num_ec]) |b| replace_all = replace_all and b.mode == .replace;
    return fh.have_crop or !replace_all;
}

/// Decodes one frame, composites it, saves it for reference, and writes
/// it to `dst` if it is displayed; returns whether it was, and sets
/// `blended` when it went through the canvas.
fn oneFrame(d: *Decoder, fh: *const headers.FrameHeader, dst: PixelBuffer, blended: *bool) Error!bool {
    const st = &d.store;
    const image = &d.image;
    try frame.checkSupported(image, fh);
    const dims: headers.Dims = .init(fh);
    try d.options.limits.checkSize(fh.width, fh.height);
    const canvas = @as(u64, image.width) * image.height;
    if (@as(u64, dims.width) * dims.height > frame_scale * canvas) return error.TooComplex;
    const toc = try frame.readToc(&d.br, &st.arena, &dims, fh.passes.num);
    const dec = try frame.decode(&d.br, &st.arena, image, fh, &toc);
    const shown = (fh.kind == .regular or fh.kind == .skip_progressive) and (fh.is_last or fh.duration > 0);
    const blend = needsBlending(fh, image.num_ec);
    const refd = canBeReferenced(fh);
    if ((blend or refd) and !d.needs_refs) return error.TooComplex;
    const src: Frame = .{ .d = d, .img = &dec.img, .num_color = dec.num_color, .x0 = fh.x0, .y0 = fh.y0 };
    if (refd and fh.save_before_ct) try d.saveFrame(fh, &src);
    if (blend) {
        blended.* = true;
        try d.composite(fh, &src);
        if (refd and !fh.save_before_ct) d.saveCanvas(fh.save_as_reference);
        if (shown) d.writeCanvas(dst);
    } else {
        if (refd and !fh.save_before_ct) {
            try d.saveFrame(fh, &src);
            st.slots[fh.save_as_reference].before_ct = false;
        }
        if (shown) src.write(dst);
    }
    return shown;
}

/// A decoded frame's channels and how to read them as floats.
const Frame = struct {
    d: *const Decoder,
    img: *const modular.Image,
    num_color: u32,
    x0: i32,
    y0: i32,

    /// Channel `c` (colors, then extra channels) of row `y` from `x`, as
    /// floats.
    fn row(f: *const Frame, c: usize, y: usize, x: usize, out: []f32) void {
        const h = &f.d.image;
        const depth = if (c < f.num_color) h.depth else h.ec[c - f.num_color].depth;
        const ch = &f.img.buf[c];
        const in = ch.row(y)[x..][0..out.len];
        toFloat(depth, in, out);
    }

    /// Writes the frame, which covers the canvas, to `dst`, through the
    /// native format, so that every format is the native pixels
    /// converted. (A blended canvas goes through `pivot` instead, which
    /// keeps the blend's precision as the reference does.)
    fn write(f: *const Frame, dst: PixelBuffer) void {
        const h = &f.d.image;
        const p = f.d.native();
        const conv: Converter = .init(dst.format, p);
        var buf: [chunk * 16]u8 align(4) = undefined;
        var fl: [max_planes][chunk]f32 = undefined;
        const alpha = h.alphaChannel();
        for (0..h.height) |y| {
            const out = dst.row(@intCast(y));
            var x: usize = 0;
            while (x < h.width) {
                const n = @min(chunk, h.width - x);
                for (0..f.num_color) |c| f.row(c, y, x, fl[c][0..n]);
                if (alpha) |a| f.row(f.num_color + a, y, x, fl[f.num_color + a][0..n]);
                packPivot(p, &fl, f.num_color, alpha, n, &buf);
                conv.run(out[x * dst.format.bytesPerPixel() ..], &buf, n);
                x += n;
            }
        }
    }
};

const chunk = 256;

/// Converts stored integers of `depth` to floats as the reference
/// decoder does: integers scaled by 1 / (2^bits - 1), floats unpacked.
fn toFloat(depth: headers.BitDepth, in: []const i32, out: []f32) void {
    if (depth.float) {
        for (in, out) |v, *o| o.* = intToFloat(v, depth.bits, depth.exp_bits);
        return;
    }
    const factor64 = 1.0 / @as(f64, @floatFromInt((@as(u64, 1) << @intCast(depth.bits)) - 1));
    if (depth.bits < 23) {
        const factor: f32 = @floatCast(factor64);
        for (in, out) |v, *o| o.* = @as(f32, @floatFromInt(v)) * factor;
    } else {
        for (in, out) |v, *o| o.* = @floatCast(@as(f64, @floatFromInt(v)) * factor64);
    }
}

/// A float of `bits` bits with `exp_bits` exponent bits, stored as an
/// integer, as a 32-bit float.
fn intToFloat(v: i32, bits: u32, exp_bits: u32) f32 {
    if (bits == 32) return @bitCast(v);
    var f: u32 = @bitCast(v);
    const bias: i32 = (@as(i32, 1) << @intCast(exp_bits - 1)) - 1;
    const sign_shift: u5 = @intCast(bits - 1);
    const mant_bits: u5 = @intCast(bits - exp_bits - 1);
    const mant_shift: u5 = @intCast(23 - @as(u32, mant_bits));
    const sign = (f >> sign_shift) & 1;
    f &= (@as(u32, 1) << sign_shift) - 1;
    if (f == 0) return if (sign == 1) -0.0 else 0.0;
    var exp: i32 = @intCast(f >> mant_bits);
    var mant: u32 = f & ((@as(u32, 1) << mant_bits) - 1);
    if (exp == (@as(i32, 1) << @intCast(exp_bits)) - 1) {
        const r: u32 = (sign << 31) | (0xff << 23) | (mant << mant_shift);
        return @bitCast(r);
    }
    mant <<= mant_shift;
    if (exp == 0 and exp_bits < 8) {
        while (mant & 0x800000 == 0) {
            mant <<= 1;
            exp -= 1;
        }
        exp += 1;
        mant &= 0x7fffff;
    }
    exp = exp - bias + 127;
    if (exp < 0) exp = 0;
    const r: u32 = (sign << 31) | (@as(u32, @intCast(exp)) << 23) | mant;
    return @bitCast(r);
}

/// Rounds to nearest, ties to even, as the reference's output stage does.
fn nearestEven(x: f32) u32 {
    const r = @floor(x + 0.5);
    var i: u32 = @intFromFloat(r);
    if (r - x == 0.5 and i & 1 == 1) i -= 1;
    return i;
}

fn toU16(v: f32) u16 {
    const s = v * 65535.0;
    const c = if (s > 0) @min(s, 65535.0) else 0;
    return @intCast(nearestEven(c));
}

fn toU8(v: f32) u8 {
    const s = v * 255.0;
    const c = if (s > 0) @min(s, 255.0) else 0;
    return @intCast(nearestEven(c));
}

/// Packs `n` pixels from float planes into `buf` in format `p`: the pivot
/// or the native format.
fn packPivot(p: PixelFormat, fl: *const [max_planes][chunk]f32, num_color: u32, alpha: ?u32, n: usize, buf: []u8) void {
    const ai: ?usize = if (alpha) |a| num_color + a else null;
    if (p.sample() == .f32) {
        const out = std.mem.bytesAsSlice(f32, buf[0 .. n * 16]);
        for (0..n) |x| {
            for (0..3) |c| out[x * 4 + c] = fl[if (num_color == 1) 0 else c][x];
            out[x * 4 + 3] = if (ai) |a| fl[a][x] else 1.0;
        }
        return;
    }
    const nc = p.channelCount();
    if (p.sample() == .u8) {
        for (0..n) |x| {
            for (0..num_color) |c| buf[x * nc + c] = toU8(fl[c][x]);
            if (ai) |a| buf[x * nc + num_color] = toU8(fl[a][x]);
        }
        return;
    }
    const out = std.mem.bytesAsSlice(u16, buf[0 .. n * nc * 2]);
    for (0..n) |x| {
        for (0..num_color) |c| out[x * nc + c] = toU16(fl[c][x]);
        if (ai) |a| out[x * nc + num_color] = toU16(fl[a][x]);
    }
}

/// Copies the frame (before blending) into its reference slot.
fn saveFrame(d: *Decoder, fh: *const headers.FrameHeader, f: *const Frame) Error!void {
    const st = &d.store;
    const slot = &st.slots[fh.save_as_reference];
    const W = d.image.width;
    const H = d.image.height;
    const fw = f.img.buf[0].w;
    const fhh = f.img.buf[0].h;
    slot.valid = true;
    slot.before_ct = true;
    slot.full = f.x0 == 0 and f.y0 == 0 and fw >= W and fhh >= H;
    if (!slot.full) return;
    for (0..st.planes) |c| {
        for (0..H) |y| f.row(c, y, 0, slot.planes[c][y * W ..][0..W]);
    }
}

fn saveCanvas(d: *Decoder, k: u32) void {
    const st = &d.store;
    const slot = &st.slots[k];
    for (0..st.planes) |c| @memcpy(slot.planes[c], st.canvas[c]);
    slot.valid = true;
    slot.full = true;
    slot.before_ct = false;
}

fn writeCanvas(d: *const Decoder, dst: PixelBuffer) void {
    const st = &d.store;
    const h = &d.image;
    const p = pivot(h);
    const conv: Converter = .init(dst.format, p);
    var buf: [chunk * 16]u8 align(4) = undefined;
    var fl: [max_planes][chunk]f32 = undefined;
    const alpha = h.alphaChannel();
    const nc = h.colourChannels();
    for (0..h.height) |y| {
        const out = dst.row(@intCast(y));
        var x: usize = 0;
        while (x < h.width) {
            const n = @min(chunk, h.width - x);
            const at = y * h.width + x;
            for (0..nc) |c| @memcpy(fl[c][0..n], st.canvas[c][at..][0..n]);
            if (alpha) |a| @memcpy(fl[nc + a][0..n], st.canvas[nc + a][at..][0..n]);
            packPivot(p, &fl, nc, alpha, n, &buf);
            conv.run(out[x * dst.format.bytesPerPixel() ..], &buf, n);
            x += n;
        }
    }
}

/// Blends the frame over its background slots into the canvas, as the
/// reference decoder's blending stage does.
fn composite(d: *Decoder, fh: *const headers.FrameHeader, f: *const Frame) Error!void {
    const st = &d.store;
    const h = &d.image;
    const W: usize = h.width;
    const H: usize = h.height;
    const nc = f.num_color;
    const np = st.planes;
    // The background of each plane, and the checks the reference makes.
    var src: [max_planes]u32 = undefined;
    for (0..np) |c| src[c] = if (c < nc) fh.blending.source else fh.ec_blending[c - nc].source;
    {
        const bg = &st.slots[fh.blending.source];
        if (bg.valid and bg.before_ct) return error.BadImage;
    }
    for (src[0..np]) |s| {
        const bg = &st.slots[s];
        if (bg.valid and !bg.full) return error.BadImage;
    }
    var has_alpha = false;
    for (h.ec[0..h.num_ec]) |e| has_alpha = has_alpha or e.kind == .alpha;
    const fw: i64 = f.img.buf[0].w;
    const fhh: i64 = f.img.buf[0].h;
    const x_lo: usize = @intCast(std.math.clamp(@as(i64, f.x0), 0, @as(i64, @intCast(W))));
    const x_hi: usize = @intCast(std.math.clamp(@as(i64, f.x0) + fw, 0, @as(i64, @intCast(W))));
    var fg: [max_planes][chunk]f32 = undefined;
    for (0..H) |y| {
        for (0..np) |c| {
            const row = st.canvas[c][y * W ..][0..W];
            const bg = &st.slots[src[c]];
            if (bg.valid) @memcpy(row, bg.planes[c][y * W ..][0..W]) else @memset(row, 0);
        }
        const fy = @as(i64, @intCast(y)) - f.y0;
        if (fy < 0 or fy >= fhh or x_lo >= x_hi) continue;
        var x = x_lo;
        while (x < x_hi) {
            const n = @min(chunk, x_hi - x);
            const fx: usize = @intCast(@as(i64, @intCast(x)) - f.x0);
            for (0..np) |c| f.row(c, @intCast(fy), fx, fg[c][0..n]);
            for (0..n) |i| {
                var px: Px = undefined;
                var bgv: Px = undefined;
                for (0..np) |c| {
                    px[c] = fg[c][i];
                    bgv[c] = st.canvas[c][y * W + x + i];
                }
                const out = blendPixel(h, fh, nc, has_alpha, bgv, px);
                for (0..np) |c| st.canvas[c][y * W + x + i] = out[c];
            }
            x += n;
        }
    }
}

const Px = [max_planes]f32;

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0.0, 1.0);
}

/// One pixel of the reference's `PerformBlending`: the extra channels by
/// their own modes, then the colors (which, blending by alpha, also set
/// that alpha).
fn blendPixel(
    h: *const headers.ImageHeader,
    fh: *const headers.FrameHeader,
    nc: u32,
    has_alpha: bool,
    bg: Px,
    fg: Px,
) Px {
    var out: Px = undefined;
    const ne = h.num_ec;
    for (0..ne) |i| {
        const b = fh.ec_blending[i];
        const c = nc + i;
        const a = nc + b.alpha_channel;
        out[c] = switch (b.mode) {
            .add => bg[c] + fg[c],
            .blend => blk: {
                const fa = if (b.clamp) clamp01(fg[a]) else fg[a];
                if (c == a) break :blk 1.0 - (1.0 - fa) * (1.0 - bg[a]);
                if (h.ec[b.alpha_channel].alpha_associated) break :blk fg[c] + bg[c] * (1.0 - fa);
                const new_a = 1.0 - (1.0 - fa) * (1.0 - bg[a]);
                const rnew: f32 = if (new_a > 0) 1.0 / new_a else 0.0;
                break :blk (fg[c] * fa + bg[c] * bg[a] * (1.0 - fa)) * rnew;
            },
            .alpha_weighted_add => blk: {
                if (c == a) break :blk bg[c];
                break :blk bg[c] + fg[c] * (if (b.clamp) clamp01(fg[a]) else fg[a]);
            },
            .mul => bg[c] * (if (b.clamp) clamp01(fg[c]) else fg[c]),
            .replace => fg[c],
        };
    }
    const b = fh.blending;
    const a = nc + b.alpha_channel;
    switch (b.mode) {
        .add => for (0..nc) |c| {
            out[c] = bg[c] + fg[c];
        },
        .alpha_weighted_add => for (0..nc) |c| {
            out[c] = if (has_alpha) bg[c] + fg[c] * (if (b.clamp) clamp01(fg[a]) else fg[a]) else bg[c] + fg[c];
        },
        .blend => {
            if (!has_alpha) {
                for (0..nc) |c| out[c] = fg[c];
            } else {
                const fa = if (b.clamp) clamp01(fg[a]) else fg[a];
                if (h.ec[b.alpha_channel].alpha_associated) {
                    for (0..nc) |c| out[c] = fg[c] + bg[c] * (1.0 - fa);
                    out[a] = 1.0 - (1.0 - fa) * (1.0 - bg[a]);
                } else {
                    const new_a = 1.0 - (1.0 - fa) * (1.0 - bg[a]);
                    const rnew: f32 = if (new_a > 0) 1.0 / new_a else 0.0;
                    for (0..nc) |c| out[c] = (fg[c] * fa + bg[c] * bg[a] * (1.0 - fa)) * rnew;
                    out[a] = new_a;
                }
            }
        },
        .mul => for (0..nc) |c| {
            out[c] = bg[c] * (if (b.clamp) clamp01(fg[c]) else fg[c]);
        },
        .replace => for (0..nc) |c| {
            out[c] = fg[c];
        },
    }
    return out;
}

fn fail(d: *Decoder, e: Error) Error {
    d.err = e;
    return e;
}

test "signature" {
    var r: Io.Reader = .fixed("\xff\x0b");
    var d: Decoder = .init(&r, .{});
    try testing.expectError(error.BadSignature, d.decodeConfig());
    r = .fixed("");
    d = .init(&r, .{});
    try testing.expectError(error.Truncated, d.decodeConfig());
}

test "16-bit output matches the reference's float path" {
    // An 8-bit sample widens to v * 257 through f32 arithmetic.
    const depth: headers.BitDepth = .{ .bits = 8 };
    var in: [256]i32 = undefined;
    for (&in, 0..) |*v, i| v.* = @intCast(i);
    var out: [256]f32 = undefined;
    toFloat(depth, &in, &out);
    for (out, 0..) |v, i| try testing.expectEqual(@as(u16, @intCast(i * 257)), toU16(v));
}

test "nearest even" {
    try testing.expectEqual(@as(u32, 2), nearestEven(2.5));
    try testing.expectEqual(@as(u32, 4), nearestEven(3.5));
    try testing.expectEqual(@as(u32, 3), nearestEven(2.75));
}

test "int to float" {
    // binary16 1.0 is 0x3c00.
    try testing.expectEqual(@as(f32, 1.0), intToFloat(0x3c00, 16, 5));
    try testing.expectEqual(@as(f32, -2.0), intToFloat(0xc000, 16, 5));
}
