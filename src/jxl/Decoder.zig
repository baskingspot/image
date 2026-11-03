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
const color = @import("color.zig");
const vfill = @import("../fill.zig").fill;
const vardct = @import("vardct.zig");
const icc = @import("icc.zig");
const patches = @import("patches.zig");
const splines = @import("splines.zig");

const Decoder = @This();

pub const Options = decode.Options;

/// A float destination is written from the decoder's floats, not converted
/// from the native format (plan.md decision 24); the fuzz harness checks it
/// against the native format with a tolerance instead of exactly.
pub const float_direct = true;

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
    /// `decodeJpeg`: the codestream cannot hold a recompressed JPEG.
    NotJpeg,
};

/// A recompressed JPEG's coefficients, from `decodeJpeg`.
pub const Jpeg = vardct.Jpeg;

options: Options,
br: BitReader,
err: ?Error = null,
state: State = .start,
image: headers.ImageHeader = undefined,
/// The encoded ICC profile's size, until the profile is read.
icc_size: ?u64 = null,
/// The next frame's header, when already read, and whether its TOC is
/// permuted.
next_frame: ?headers.FrameHeader = null,
next_toc_permuted: bool = true,
/// Whether frames may need the canvas and reference slots.
needs_refs: bool = true,
work_len: usize = 0,
/// `native()`, from the headers and the first frame's when read ahead;
/// fixed then, as later reads clear `next_frame`.
native_format: PixelFormat = .rgba8,
index: u32 = 0,
/// The frames shown so far, and those not shown since, which seed the
/// noise; the preview counts as not shown.
visible: u32 = 0,
nonvisible: u32 = 0,
/// Whether a frame so far was drawn in floats (VarDCT, XYB, filters,
/// upsampling, patches, splines, or noise), which makes its samples
/// approximate rather than the stored integers.
float_frames: bool = false,
store: Store = .{},
/// Whether frames that can stream do (`frame.streams`); false decodes
/// every frame whole, for tests.
stream: bool = true,
/// Receives every VarDCT frame's quantized coefficients, for rebuilding a
/// recompressed JPEG; for this package's JPEG reconstruction, not callers.
coeff_sink: ?vardct.CoeffSink = null,

/// `trailer`: the codestream is complete and the container's boxes after
/// it are still to read, which the call after the last frame does.
const State = enum { start, config, frames, trailer, done };

/// The composited canvas and the four reference slots, float planes of
/// the canvas's size at the start of work memory.
const Store = struct {
    ready: bool = false,
    canvas: [max_planes][]f32 = undefined,
    slots: [4]Slot = @splat(.{}),
    lf: [4]LfFrame = @splat(.{}),
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
    /// The saved frame's size (the canvas's, when `full`), rows of `w`;
    /// zero when it did not fit.
    w: usize = 0,
    h: usize = 0,
};

const max_planes = 3 + headers.max_extra_channels;

/// The output of the last LF frame of a level, before its color
/// transform, which a later frame takes as its LF.
const LfFrame = struct {
    planes: [3][]f32 = @splat(&.{}),
    w: usize = 0,
    h: usize = 0,
    valid: bool = false,
};

/// The floats an LF frame of `level` may hold per plane: for a frame of
/// up to `frame_scale` times the canvas.
fn lfCapacity(h: *const headers.ImageHeader, level: u5) u64 {
    const s: u6 = 3 * @as(u6, level);
    const w = (@as(u64, h.width) + (@as(u64, 1) << s) - 1) >> s;
    const hh = (@as(u64, h.height) + (@as(u64, 1) << s) - 1) >> s;
    return frame_scale * (w + 1) * (hh + 1);
}

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
        .native = d.native_format,
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
        // The TOC's first bit says whether its sections are permuted.
        d.next_toc_permuted = (br.peek(1) catch 1) == 1;
        // One frame that covers the canvas needs no canvas or slots.
        d.needs_refs = !(fh.is_last and !fh.have_crop and d.image.animation == null);
    }
    d.native_format = d.native();
    d.work_len = try d.workBound();
    try d.options.limits.checkWork(d.work_len);
}

fn planeCount(h: *const headers.ImageHeader) usize {
    return h.colourChannels() + h.num_ec;
}

/// The work memory bound (docs/slop/jxl.md, work memory).
fn workBound(d: *const Decoder) Error!usize {
    return d.boundFor(.frames);
}

/// The work memory bound for decoding frames, or for `decodeJpeg`.
fn boundFor(d: *const Decoder, kind: enum { frames, jpeg }) Error!usize {
    const h = &d.image;
    const px: u128 = @as(u128, h.width) * h.height;
    const c: u128 = planeCount(h);
    const plane = px * 4;
    var total: u128 = 0;
    if (kind == .frames and d.needs_refs) {
        total += 5 * c * plane;
        for (1..5) |level| total += 3 * 4 * @as(u128, lfCapacity(h, @intCast(level)));
    }
    // One frame: the only one, when the peeked first frame is the last;
    // otherwise any.
    const only: ?*const headers.FrameHeader = if (d.next_frame) |*f| (if (f.is_last) f else null) else null;
    // The only frame streams when its TOC, peeked, is in order.
    const stream = if (only) |f|
        !d.next_toc_permuted and !needsBlending(f, h.num_ec) and frame.streams(h, f, false)
    else
        false;
    total += if (kind == .jpeg) jpegFrameBound(h, d.next_frame) else frameBound(h, only, stream);
    // A group's channels with their transforms, at the peeked frame's
    // group size or the largest.
    const gd: u128 = if (d.next_frame) |f| @as(u128, 128) << @intCast(f.group_size_shift) else 1024;
    const group_px: u128 = @min(gd * gd, px);
    // A JPEG's frame, VarDCT without extra channels, has none.
    if (kind == .frames) total += 4 * c * 4 * group_px;
    // The global tree and one local tree.
    const node: u128 = @sizeOf(modular.Node);
    total += @as(u128, @min(1 << 22, 1024 + frame_scale * px * c / 16)) * node;
    total += @as(u128, @min(1 << 20, 1024 + group_px * c)) * node;
    // A channel's tree, flattened.
    total += modular.flat_bytes;
    // Entropy codes: three live at once, each with tables and a window.
    // A window lasts one stream, and a JPEG's frame decodes one stream at
    // a time, so it needs one.
    const window: u128 = entropy.window_size;
    const windows: u128 = if (kind == .jpeg) 1 else 3;
    total += 3 * entropy_budget + windows * 4 * @as(u128, @min(px * c, window));
    // Rows of reference properties and the weighted predictor.
    total += 1088 * @as(u128, h.width) + 65536;
    if (d.icc_size) |s| total = @max(total, icc.workLen(s) + entropy_budget + 4 * @as(u128, @min(s, window)) + 65536);
    // The arena starts each array of 4096 bytes or more on a cache line,
    // wasting at most 63 bytes, under 1/64 of it.
    total += total / 64;
    return std.math.cast(usize, total) orelse error.WorkTooLarge;
}

/// The memory one frame's pixels take (docs/slop/jxl.md, work memory):
/// frame `f`'s, or with `f` null, the most any frame of up to
/// `frame_scale` times the canvas may take, Modular or VarDCT, with every
/// feature. A frame that `stream`s keeps a ring of group rows and a band's
/// window instead of whole planes.
fn frameBound(h: *const headers.ImageHeader, f: ?*const headers.FrameHeader, stream: bool) u128 {
    const px: u128 = @as(u128, h.width) * h.height;
    const ne: u128 = h.num_ec;
    // Pixels after upsampling, before it, and padded to whole blocks.
    var up_px = frame_scale * px;
    var pre_px = up_px;
    var pad_px: u128 = frame_scale * paddedCanvas(h);
    var modular_frame = true;
    var vardct_frame = true;
    var upsampled = true;
    var flags: u64 = headers.flag_noise | headers.flag_patches | headers.flag_splines;
    var passes: u128 = 11;
    var drawn = true;
    if (f) |fh| {
        const dims: headers.Dims = .init(fh);
        up_px = @as(u128, fh.width) * fh.height;
        pre_px = @as(u128, dims.width) * dims.height;
        pad_px = @as(u128, dims.xsize_blocks) * dims.ysize_blocks * 64;
        modular_frame = fh.modular;
        vardct_frame = !fh.modular;
        upsampled = fh.upsampling != 1;
        for (fh.ec_upsampling[0..h.num_ec]) |u| upsampled = upsampled or u != 1;
        flags = fh.flags;
        passes = fh.passes.num;
        drawn = !losslessFrame(fh) or h.xyb;
    }
    var total: u128 = 0;
    // The Modular channels (colors in a Modular frame, and the extra
    // channels): three times over for undoing squeezes (each step's output
    // is new), one more for a delta palette's indices, and the largest
    // palette.
    const nm: u128 = (if (modular_frame) @as(u128, h.colourChannels()) else 0) + ne;
    // A frame without frame-sized Modular channels (VarDCT without extra
    // channels) has no delta palette there either.
    total += 3 * nm * pre_px * 4 + (if (nm > 0) pre_px * 4 else 0) + 4 * 137_728 * @max(nm, 1);
    if (vardct_frame) {
        // VarDCT's three planes, coefficients kept between passes, block
        // fields; a pass group's coefficients and scratch, the LF group's
        // channels, the dequantization tables, and each pass's orders and
        // code.
        const window: u128 = entropy.window_size;
        var planes_px = pad_px;
        if (stream) {
            const fh = f.?;
            const dims: headers.Dims = .init(fh);
            const rows: u128 = frame.ringRows(fh) + dims.group_dim + 16;
            const ring = @min(pad_px, @as(u128, dims.xsize_blocks) * 8 * rows) + pad_px / 64;
            // With extra channels, global transforms found in the frame
            // take whole planes instead (`frame.lfGlobal`).
            planes_px = if (ne > 0) @max(pad_px, ring) else ring;
        }
        total += planes_px * 12 + (if (passes > 1) pad_px * 12 else 0) + pad_px / 64 * 24;
        total += 4 << 20;
        // Each pass's orders, for the strategies that fit the frame.
        const orders = if (f) |fh| blk: {
            const dims: headers.Dims = .init(fh);
            break :blk vardct.ordersBytes(dims.xsize_blocks, dims.ysize_blocks);
        } else vardct.ordersBytes(std.math.maxInt(u32), std.math.maxInt(u32));
        total += passes * (entropy_budget + 4 * @as(u128, @min(3 * pad_px, window)) + orders);
    } else if (drawn) {
        // A Modular frame's colors as float planes, and EPF's sigmas.
        total += pre_px * 12 + pre_px / 16;
    }
    // Upsampled planes, the extra channels as floats, the noise's planes,
    // and patches and splines at their budgets.
    if (upsampled or flags & headers.flag_patches != 0) total += ne * up_px * 4 + pre_px * 4;
    if (upsampled) total += up_px * 12;
    if (flags & headers.flag_noise != 0) total += up_px * 12 + 64 * @as(u128, h.width) * 4;
    if (flags & headers.flag_patches != 0) total += patches.budgetBytes(@intCast(pad_px), h.num_ec);
    if (flags & headers.flag_splines != 0) total += splines.budgetBytes(@intCast(pre_px));
    return total;
}

/// The memory `decodeJpeg`'s frame takes: frame `f`'s, or with `f` null,
/// any VarDCT frame of the canvas's size without pixels, extra channels,
/// or the features `decodeJpeg` refuses.
fn jpegFrameBound(h: *const headers.ImageHeader, f: ?headers.FrameHeader) u128 {
    var pad_px: u128 = paddedCanvas(h);
    var passes: u128 = 11;
    // The frame's size in blocks, which bounds the strategies it uses.
    var bw: u64 = (@as(u64, h.width) + 15) / 16 * 2;
    var bh: u64 = (@as(u64, h.height) + 15) / 16 * 2;
    if (f) |fh| {
        const dims: headers.Dims = .init(&fh);
        pad_px = @min(pad_px, @as(u128, dims.xsize_blocks) * dims.ysize_blocks * 64);
        passes = fh.passes.num;
        bw = dims.xsize_blocks;
        bh = dims.ysize_blocks;
    }
    // Block fields, coefficients kept between passes, a pass group's
    // coefficients, the LF group's channels, the dequantization tables,
    // each pass's orders (for the strategies that fit) and code, and the
    // empty Modular image's palette.
    const window: u128 = entropy.window_size;
    var total: u128 = pad_px / 64 * 24 + (if (passes > 1) pad_px * 12 else 0) + (4 << 20);
    total += passes * (entropy_budget + 4 * @as(u128, @min(3 * pad_px, window)) + vardct.ordersBytes(bw, bh));
    return total + 4 * 137_728;
}

/// How many times the canvas's pixels a frame may have; a larger frame
/// is `TooComplex`.
const frame_scale = 2;

/// The canvas's pixels padded to whole 16-pixel blocks, as frames' VarDCT
/// planes are.
fn paddedCanvas(h: *const headers.ImageHeader) u64 {
    return ((@as(u64, h.width) + 15) & ~@as(u64, 15)) * ((@as(u64, h.height) + 15) & ~@as(u64, 15));
}

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
    if (isFloat(h)) return floatPivot(h);
    // Lossy frames make floats: 16 bits keep them to within the
    // conformance suite's error bounds. Only a first frame read ahead
    // shows an image is lossless.
    const first = d.next_frame orelse return pivot16(h);
    if (h.xyb or !losslessFrame(&first)) return pivot16(h);
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

/// Whether a frame's samples are its stored integers: Modular, without
/// filters, upsampling, or the features drawn in floats.
fn losslessFrame(fh: *const headers.FrameHeader) bool {
    const drawn = headers.flag_patches | headers.flag_splines | headers.flag_noise;
    return fh.modular and !fh.ycbcr and !fh.filter.gab and fh.filter.epf_iters == 0 and
        fh.upsampling == 1 and fh.flags & drawn == 0;
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
    if (isFloat(h)) return floatPivot(h);
    return pivot16(h);
}

fn floatPivot(h: *const headers.ImageHeader) PixelFormat {
    return if (premultiplied(h)) .rgba_f32_premul else .rgba_f32;
}

/// The format frames go through on their way to `dst`: a float
/// destination straight from the decoder's floats, with no 16-bit step
/// (plan.md decision 24), clamped to [0, 1] for integer samples as the
/// 16-bit step clamps; others through `p`.
fn through(dst: PixelFormat, h: *const headers.ImageHeader, p: PixelFormat) PixelFormat {
    return if (dst.sample() == .f32) floatPivot(h) else p;
}

/// The metadata, describing the pixels `decodeFrame` writes. Without an
/// ICC profile they are in the colour encoding. An XYB image with an ICC
/// profile is written in linear sRGB (as libjxl writes it without a CMS),
/// so that is what `transfer` and `primaries` say; the profile is still
/// delivered, and it describes the original image's space, not the
/// pixels' (plan.md decision 46). Other images with a profile are in its
/// space, and these fields are null.
fn metadata(d: *const Decoder) decode.Metadata {
    const h = &d.image;
    var m: decode.Metadata = .{ .orientation = @enumFromInt(h.orientation) };
    const c = &h.colour;
    if (c.want_icc and h.xyb) {
        m.transfer = .linear;
        if (c.space != .grey) m.primaries = primaries(&headers.ColourEncoding{});
    }
    if (!c.want_icc and c.space != .xyb) {
        if (c.have_gamma) {
            m.gamma = c.gamma / 100;
        } else m.transfer = switch (c.transfer) {
            .srgb => .srgb,
            .linear => .linear,
            .bt709 => .bt709,
            .dci => .dci,
            .pq => .pq,
            .hlg => .hlg,
            .unknown => null,
        };
        if (c.space == .rgb) m.primaries = primaries(c);
    }
    m.intensity_target = h.tone.intensity_target;
    m.exif = d.br.src.exif;
    m.xmp = d.br.src.xmp;
    m.jpeg_reconstruction = d.br.src.saw_jbrd;
    return m;
}

/// The colour encoding's red, green, and blue primaries and white point as
/// CIE xy (ISO/IEC 18181-1, the named primaries and white points).
fn primaries(c: *const headers.ColourEncoding) [8]f32 {
    const rgb: [6]f32 = switch (c.primaries) {
        .srgb => .{ 0.64, 0.33, 0.3, 0.6, 0.15, 0.06 },
        .bt2100 => .{ 0.708, 0.292, 0.17, 0.797, 0.131, 0.046 },
        .p3 => .{ 0.68, 0.32, 0.265, 0.69, 0.15, 0.06 },
        .custom => .{
            micro(c.prim[0][0]), micro(c.prim[0][1]),
            micro(c.prim[1][0]), micro(c.prim[1][1]),
            micro(c.prim[2][0]), micro(c.prim[2][1]),
        },
    };
    const white: [2]f32 = switch (c.white_point) {
        .d65 => .{ 0.3127, 0.329 },
        .e => .{ 1.0 / 3.0, 1.0 / 3.0 },
        .dci => .{ 0.314, 0.351 },
        .custom => .{ micro(c.white[0]), micro(c.white[1]) },
    };
    return rgb ++ white;
}

fn micro(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 1e6;
}

/// Decodes the next displayed frame into `dst`.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    if (d.err) |e| return e;
    _ = try d.decodeConfig();
    if (d.state == .trailer) {
        // The boxes after the codestream: metadata for `finalConfig`. An
        // error here comes after the image, which has been returned whole.
        d.br.src.finish() catch |e| return d.fail(e);
        d.state = .done;
    }
    if (d.state == .done) return null;
    try dst.check();
    if (dst.width != d.image.width or dst.height != d.image.height) return error.SizeMismatch;
    if (work.len < d.work_len) return error.WorkTooSmall;
    return d.nextFrame(dst, work[0..d.work_len]) catch |e| d.fail(e);
}

fn nextFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    const st = &d.store;
    if (d.state == .config) {
        try d.begin(work);
        if (d.needs_refs) {
            const px = @as(usize, d.image.width) * d.image.height;
            st.planes = planeCount(&d.image);
            for (st.canvas[0..st.planes]) |*p| p.* = try st.arena.alloc(f32, px);
            for (&st.slots) |*s| {
                for (s.planes[0..st.planes]) |*p| p.* = try st.arena.alloc(f32, px);
            }
            for (&st.lf, 1..) |*l, level| {
                for (&l.planes) |*p| p.* = try st.arena.alloc(f32, @intCast(lfCapacity(&d.image, @intCast(level))));
            }
        }
        st.frame_mark = st.arena.mark();
        d.state = .frames;
    }
    while (true) {
        const fh = if (d.next_frame) |f| f else try headers.FrameHeader.read(&d.br, &d.image, false);
        d.next_frame = null;
        // Displayed frames past the limit fail before they are drawn.
        if (shownFrame(&fh)) try d.options.limits.checkFrames(@as(u64, d.index) + 1);
        defer st.arena.release(st.frame_mark);
        var blended = false;
        const shown = try d.oneFrame(&fh, dst, &blended);
        if (fh.is_last) d.state = .trailer;
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

/// Starts work memory and reads what comes before the first frame: the
/// ICC profile, to the blob sink, and the preview.
fn begin(d: *Decoder, work: []u8) Error!void {
    const st = &d.store;
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
}

/// How `skim` finds a codestream's frames drawn.
pub const Skim = struct {
    /// A frame is drawn in floats (`float_frames`): its samples are the
    /// specification's within the conformance bounds, not exact.
    float: bool = false,
    /// A frame draws splines, which the conformance bounds give more room.
    splines: bool = false,
};

/// Reads every frame's header and table of contents and skips its
/// sections, to say in `s` how the frames are drawn without drawing them:
/// for this package's oracle, which picks its comparison before it
/// decodes, not for callers. `s`
/// keeps what the frames before an error said. Uses
/// `work[0..decodeConfig().work_len]` and leaves nothing more to decode.
pub fn skim(d: *Decoder, work: []u8, s: *Skim) Error!void {
    if (d.err) |e| return e;
    _ = try d.decodeConfig();
    if (d.state != .config) return error.BadHeader;
    if (work.len < d.work_len) return error.WorkTooSmall;
    d.skimFrames(work[0..d.work_len], s) catch |e| return d.fail(e);
}

fn skimFrames(d: *Decoder, work: []u8, s: *Skim) Error!void {
    try d.begin(work);
    d.state = .frames;
    const st = &d.store;
    while (true) {
        const fh = if (d.next_frame) |f| f else try headers.FrameHeader.read(&d.br, &d.image, false);
        d.next_frame = null;
        if (frame.needsFloat(&d.image, &fh)) s.float = true;
        if (fh.flags & headers.flag_splines != 0) s.splines = true;
        const dims: headers.Dims = .init(&fh);
        const m = st.arena.mark();
        const toc = try frame.readToc(&d.br, &st.arena, &dims, fh.passes.num);
        st.arena.release(m);
        try d.br.skipBits(toc.total * 8);
        if (fh.is_last) break;
    }
    d.state = .done;
}

/// The work memory `decodeJpeg` needs, from the headers.
pub fn jpegWorkLen(d: *Decoder) Error!usize {
    _ = try d.decodeConfig();
    const n = d.boundFor(.jpeg) catch |e| return d.fail(e);
    d.options.limits.checkWork(n) catch |e| return d.fail(e);
    return n;
}

/// For rebuilding a JPEG from its `jbrd` box: reads the codestream's one
/// frame as a recompressed JPEG's coefficients into `coefs`, which holds
/// at least `Jpeg.maxCoefs(width, height)`, using `work[0..jpegWorkLen()]`
/// and making no pixels. Call it instead of `decodeFrame`, after
/// `decodeConfig`. The ICC profile goes to `Options.blob_sink` as usual.
/// Fails with `NotJpeg` when the frame cannot be a JPEG's: VarDCT YCbCr
/// with DCT8 blocks only, raw quantization tables, the image's size, and no
/// extra channels, animation, upsampling, patches, splines, noise, or LF
/// frame.
pub fn decodeJpeg(d: *Decoder, coefs: []i16, work: []u8) Error!Jpeg {
    if (d.err) |e| return e;
    const len = try d.jpegWorkLen();
    if (d.state != .config) return error.NotJpeg;
    if (work.len < len) return error.WorkTooSmall;
    return d.jpegFrame(coefs, work[0..len]) catch |e| d.fail(e);
}

fn jpegFrame(d: *Decoder, coefs: []i16, work: []u8) Error!Jpeg {
    const st = &d.store;
    const image = &d.image;
    try d.begin(work);
    d.state = .frames;
    const fh = if (d.next_frame) |f| f else try headers.FrameHeader.read(&d.br, image, false);
    d.next_frame = null;
    const excluded = headers.flag_noise | headers.flag_patches | headers.flag_splines | headers.flag_use_lf_frame;
    if (fh.modular or !fh.ycbcr or image.xyb or fh.kind != .regular or !fh.is_last or fh.have_crop or
        fh.upsampling != 1 or fh.flags & excluded != 0 or image.num_ec != 0 or image.animation != null or
        fh.width != image.width or fh.height != image.height) return error.NotJpeg;
    try frame.checkSupported(image, &fh);
    const dims: headers.Dims = .init(&fh);
    var jpeg: Jpeg = try .init(&fh, &dims, coefs);
    const toc = try frame.readToc(&d.br, &st.arena, &dims, fh.passes.num);
    const refs: [4]?frame.PatchSource = @splat(null);
    _ = try frame.decode(&d.br, &st.arena, image, &fh, &toc, .{ 1, 0 }, &refs, null, jpeg.sink(), null);
    if (!jpeg.got_quant) return error.NotJpeg;
    d.state = .trailer;
    return jpeg;
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
    d.nonvisible +%= 1;
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

/// Whether `fh` starts a displayed frame: a regular frame that is the last
/// or has a duration.
fn shownFrame(fh: *const headers.FrameHeader) bool {
    return (fh.kind == .regular or fh.kind == .skip_progressive) and (fh.is_last or fh.duration > 0);
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
    // The frame, after upsampling and with its blocks' padding, within
    // what workBound reserves.
    if (@as(u64, fh.width) * fh.height > frame_scale * canvas) return error.TooComplex;
    const padded = @as(u64, dims.xsize_blocks) * dims.ysize_blocks * 64;
    if (padded > frame_scale * paddedCanvas(image)) return error.TooComplex;
    const toc = try frame.readToc(&d.br, &st.arena, &dims, fh.passes.num);
    const shown = shownFrame(fh);
    if (shown) {
        d.visible +%= 1;
        d.nonvisible = 0;
    } else {
        d.nonvisible +%= 1;
    }
    var refs: [4]?frame.PatchSource = @splat(null);
    if (fh.flags & headers.flag_patches != 0) {
        const nc = image.colourChannels();
        for (&refs, &st.slots) |*r, *slot| {
            if (!slot.valid or !slot.before_ct or slot.w == 0) continue;
            const planes = try st.arena.alloc([]const f32, 3 + image.num_ec);
            for (planes[0..3], 0..) |*p, c| p.* = slot.planes[if (nc == 1) 0 else c];
            for (planes[3..], slot.planes[nc..][0..image.num_ec]) |*p, q| p.* = q;
            r.* = .{ .planes = planes, .w = slot.w, .h = slot.h };
        }
    }
    var lf_in: ?frame.LfImage = null;
    if (fh.flags & headers.flag_use_lf_frame != 0) {
        if (fh.lf_level >= 4) return error.BadHeader;
        const l = &st.lf[fh.lf_level];
        if (!l.valid) return error.BadImage;
        lf_in = .{ .planes = .{ l.planes[0], l.planes[1], l.planes[2] }, .w = l.w, .h = l.h };
    }
    const counts = .{ d.visible, d.nonvisible };
    // A shown frame that replaces the canvas and is never referenced may
    // stream: filtered and written a group row at a time.
    var out: BandOut = .{ .d = d, .fh = fh, .dst = dst };
    const direct = d.stream and shown and !needsBlending(fh, image.num_ec) and !canBeReferenced(fh) and
        fh.kind == .regular;
    const band: ?frame.BandSink = if (direct) .{ .ctx = &out, .write = BandOut.write } else null;
    const dec = try frame.decode(&d.br, &st.arena, image, fh, &toc, counts, &refs, lf_in, d.coeff_sink, band);
    if (dec.streamed) {
        if (frame.needsFloat(image, fh)) d.float_frames = true;
        return true;
    }
    if (fh.kind == .lf) {
        // Kept for the frames that use it; never shown.
        const l = &st.lf[fh.lf_level - 1];
        const n = @as(u64, dec.w) * dec.h;
        if (n > l.planes[0].len) return error.TooComplex;
        const planes = dec.color.?;
        for (l.planes, planes) |to, from| {
            for (0..dec.h) |y| @memcpy(to[y * dec.w ..][0..dec.w], from[y * dec.color_stride ..][0..dec.w]);
        }
        l.w = dec.w;
        l.h = dec.h;
        l.valid = true;
        return false;
    }
    const blend = needsBlending(fh, image.num_ec);
    const refd = canBeReferenced(fh);
    if ((blend or refd) and !d.needs_refs) return error.TooComplex;
    // A frame only written takes its color transform as it is written,
    // when its rows are whole vectors (VarDCT's are whole blocks), so
    // that it is the whole planes' bit for bit.
    const fuse = shown and !blend and !refd and dec.color != null and dec.color_stride % 8 == 0;
    const src: Frame = .{
        .d = d,
        .img = &dec.img,
        .num_color = dec.num_color,
        .color = dec.color,
        .color_stride = dec.color_stride,
        .transform = if (fuse) fh else null,
        .ec = dec.ec,
        .w = dec.w,
        .h = dec.h,
        .x0 = fh.x0,
        .y0 = fh.y0,
    };
    if (dec.color != null) d.float_frames = true;
    if (refd and fh.save_before_ct) try d.saveFrame(fh, &src);
    if (!fuse) frame.colorTransform(image, fh, &dec);
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

/// Writes a streamed frame's bands to `dst`.
const BandOut = struct {
    d: *const Decoder,
    fh: *const headers.FrameHeader,
    dst: PixelBuffer,

    fn write(
        ctx: *anyopaque,
        planes: ?[3][]f32,
        stride: usize,
        extra: *const modular.Image,
        extra_y: usize,
        y0: usize,
        rows: usize,
    ) void {
        const o: *BandOut = @ptrCast(@alignCast(ctx));
        const image = &o.d.image;
        const f: Frame = .{
            .d = o.d,
            .img = extra,
            .img_y = extra_y,
            .num_color = image.colourChannels(),
            .color = planes,
            .color_stride = stride,
            .transform = if (planes != null) o.fh else null,
            .ec = null,
            .w = image.width,
            .h = @intCast(rows),
            .x0 = 0,
            .y0 = 0,
        };
        f.writeRows(o.dst, y0, rows);
    }
};

/// A decoded frame's channels and how to read them as floats.
const Frame = struct {
    d: *const Decoder,
    img: *const modular.Image,
    num_color: u32,
    /// The color channels as floats, when not in `img` (VarDCT).
    color: ?[3][]f32,
    color_stride: usize,
    /// The frame whose color transform the color planes still need, done
    /// as they are written: a streamed band's, while its chunk is in
    /// cache.
    transform: ?*const headers.FrameHeader = null,
    /// The extra channels as floats, rows of `w`, when not in `img`
    /// (upsampled).
    ec: ?[]const []f32,
    w: u32,
    h: u32,
    x0: i32,
    y0: i32,
    /// The row of `img` that is the frame's row 0: a streamed band's
    /// first.
    img_y: usize = 0,

    /// Channel `c` (colors, then extra channels) of row `y` from `x`, as
    /// floats.
    fn row(f: *const Frame, c: usize, y: usize, x: usize, out: []f32) void {
        const h = &f.d.image;
        if (f.color) |planes| {
            if (c < f.num_color) {
                @memcpy(out, planes[c][y * f.color_stride + x ..][0..out.len]);
                return;
            }
        }
        if (f.ec) |ec| {
            @memcpy(out, ec[c - f.num_color][y * f.w + x ..][0..out.len]);
            return;
        }
        const depth = if (c < f.num_color) h.depth else h.ec[c - f.num_color].depth;
        const ch = &f.img.buf[if (f.color == null) c else c - f.num_color];
        const in = ch.row(f.img_y + y)[x..][0..out.len];
        frame.toFloat(depth, in, out);
    }

    /// Writes the frame, which covers the canvas, to `dst`, through the
    /// native format, so that every integer format is the native pixels
    /// converted; a float format comes from the floats (`through`). (A
    /// blended canvas goes through `pivot` instead, which keeps the
    /// blend's precision as the reference does.)
    fn write(f: *const Frame, dst: PixelBuffer) void {
        f.writeRows(dst, 0, f.d.image.height);
    }

    /// `write` of the frame's `rows` rows, from row 0, to `dst`'s rows
    /// from `y0`.
    fn writeRows(f: *const Frame, dst: PixelBuffer, y0: usize, rows: usize) void {
        const h = &f.d.image;
        const p = through(dst.format, h, f.d.native_format);
        const conv: Converter = .init(dst.format, p);
        // Packed straight into `dst` when converting would only copy the
        // samples or add an opaque alpha.
        const direct = packsDirect(dst.format, p, h);
        const bpp = dst.format.bytesPerPixel();
        var buf: [chunk * 16]u8 align(4) = undefined;
        var fl: [max_planes][chunk]f32 = undefined;
        const alpha = h.alphaChannel();
        // The transform takes all three planes (a grey XYB image has
        // three), eight samples at a time: the planes' rows are whole
        // blocks wide, so it never takes the scalar tail, and its samples
        // are the whole planes' bit for bit.
        const xyb: ?color.Xyb = if (f.transform != null and h.xyb) color.Xyb.init(h) catch null else null;
        const ycbcr = if (f.transform) |fh| fh.ycbcr and !h.xyb else false;
        const nc_in: usize = if (xyb != null or ycbcr) 3 else f.num_color;
        for (0..rows) |y| {
            const out = dst.row(@intCast(y0 + y));
            var x: usize = 0;
            while (x < h.width) {
                const n = @min(chunk, h.width - x);
                const n8 = if (nc_in == 3 and f.transform != null) (n + 7) / 8 * 8 else n;
                const into: [3][]f32 = .{ fl[0][0..n8], fl[1][0..n8], fl[2][0..n8] };
                if (xyb) |*t| {
                    // Read from the planes, written to the chunk.
                    var from: [3][]const f32 = undefined;
                    for (&from, f.color.?) |*o, plane| o.* = plane[y * f.color_stride + x ..][0..n8];
                    t.applyTo(from, into);
                } else if (ycbcr) {
                    const planes = f.color.?;
                    for (0..3) |c| @memcpy(into[c], planes[c][y * f.color_stride + x ..][0..n8]);
                    color.ycbcrToRgb(into);
                } else for (0..f.num_color) |c| f.row(c, y, x, fl[c][0..n]);
                if (alpha) |a| f.row(f.num_color + a, y, x, fl[f.num_color + a][0..n]);
                if (direct) {
                    packPivot(dst.format, &fl, f.num_color, alpha, n, out[x * bpp ..][0 .. n * bpp], !isFloat(h));
                } else {
                    packPivot(p, &fl, f.num_color, alpha, n, &buf, !isFloat(h));
                    conv.run(out[x * bpp ..], &buf, n);
                }
                x += n;
            }
        }
    }
};

const chunk = 256;

/// Whether `packPivot` can write format `dst` itself, the samples of the
/// integer pivot `p` with nothing changed but an opaque alpha added, as
/// converting `p` to `dst` would write them.
fn packsDirect(dst: PixelFormat, p: PixelFormat, h: *const headers.ImageHeader) bool {
    if (p.sample() == .f32 or (isFloat(h) and dst.sample() == .f32)) return false;
    if (dst == p) return true;
    return switch (p) {
        .rgb16 => dst == .rgba16 or dst == .rgba16_premul,
        .rgb8 => dst == .rgba8 or dst == .rgba8_premul,
        .gray16 => dst == .gray_alpha16 or dst == .gray_alpha16_premul,
        .gray8 => dst == .gray_alpha8 or dst == .gray_alpha8_premul,
        else => false,
    };
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
/// or the native format. Floats are clamped to [0, 1] when `clamp`, as
/// the 16-bit pivot clamps.
fn packPivot(
    p: PixelFormat,
    fl: *const [max_planes][chunk]f32,
    num_color: u32,
    alpha: ?u32,
    n: usize,
    buf: []u8,
    clamp: bool,
) void {
    const ai: ?usize = if (alpha) |a| num_color + a else null;
    if (p.sample() == .f32) {
        const out = std.mem.bytesAsSlice(f32, buf[0 .. n * 16]);
        for (0..n) |x| {
            for (0..3) |c| out[x * 4 + c] = fl[if (num_color == 1) 0 else c][x];
            out[x * 4 + 3] = if (ai) |a| fl[a][x] else 1.0;
        }
        if (clamp) for (out[0 .. n * 4]) |*v| {
            v.* = std.math.clamp(v.*, 0, 1);
        };
        return;
    }
    var q: [4][chunk]u16 = undefined;
    const max: f32 = if (p.sample() == .u8) 255 else 65535;
    switch (p.channelCount()) {
        inline 1...4 => |nc| {
            for (0..nc) |k| {
                if (k >= num_color and ai == null) {
                    // An alpha the pivot lacks: opaque.
                    vfill(u16, q[k][0..n], @intFromFloat(max));
                    continue;
                }
                const c = if (k < num_color) k else ai.?;
                quantize(fl[c][0..n], q[k][0..n], max);
            }
            // Interleaved eight pixels at a time, then a pixel at a time,
            // with the channel count fixed.
            var x: usize = 0;
            if (p.sample() == .u8) {
                if (nc >= 3) while (x + 8 <= n) : (x += 8) {
                    const v = interleave(nc, &q, x);
                    const b: @Vector(8 * nc, u8) = @intCast(v);
                    buf[x * nc ..][0 .. 8 * nc].* = b;
                };
                for (x..n) |i| inline for (0..nc) |k| {
                    buf[i * nc + k] = @intCast(q[k][i]);
                };
            } else {
                const out = std.mem.bytesAsSlice(u16, buf[0 .. n * nc * 2]);
                if (nc >= 3) while (x + 8 <= n) : (x += 8) {
                    const v = interleave(nc, &q, x);
                    const o: *align(1) [8 * nc]u16 = @ptrCast(out[x * nc ..][0 .. 8 * nc]);
                    o.* = v;
                };
                for (x..n) |i| inline for (0..nc) |k| {
                    out[i * nc + k] = q[k][i];
                };
            }
        },
        else => unreachable,
    }
}

/// Pixels `x` to `x + 8` of the `nc` (3 or 4) channels of `q`,
/// interleaved: each pixel's samples together.
inline fn interleave(comptime nc: usize, q: *const [4][chunk]u16, x: usize) @Vector(8 * nc, u16) {
    const V8 = @Vector(8, u16);
    const a: V8 = q[0][x..][0..8].*;
    const b: V8 = q[1][x..][0..8].*;
    const c: V8 = q[2][x..][0..8].*;
    const d: V8 = if (nc == 4) q[3][x..][0..8].* else @splat(0);
    // a and b paired, c and d paired, then the pairs pixel by pixel.
    const ab = @shuffle(u16, a, b, pairMask());
    const cd = @shuffle(u16, c, d, pairMask());
    return @shuffle(u16, ab, cd, pixelMask(nc));
}

fn pairMask() [16]i32 {
    var m: [16]i32 = undefined;
    for (0..8) |i| {
        m[2 * i] = @intCast(i);
        m[2 * i + 1] = ~@as(i32, @intCast(i));
    }
    return m;
}

fn pixelMask(comptime nc: usize) [8 * nc]i32 {
    var m: [8 * nc]i32 = undefined;
    for (0..8) |i| {
        m[nc * i] = @intCast(2 * i);
        m[nc * i + 1] = @intCast(2 * i + 1);
        m[nc * i + 2] = ~@as(i32, @intCast(2 * i));
        if (nc == 4) m[nc * i + 3] = ~@as(i32, @intCast(2 * i + 1));
    }
    return m;
}

/// `toU16` (or `toU8`, for `max` 255) of each sample, eight at a time:
/// adding and taking away 2^23 rounds to nearest, ties to even.
fn quantize(in: []const f32, out: []u16, max: f32) void {
    const V = @Vector(8, f32);
    const big: V = @splat(8388608.0);
    var x: usize = 0;
    while (x + 8 <= in.len) : (x += 8) {
        const v: V = in[x..][0..8].*;
        const s = @min(@max(v * @as(V, @splat(max)), @as(V, @splat(0))), @as(V, @splat(max)));
        const r = (s + big) - big;
        const u: @Vector(8, u16) = @intFromFloat(r);
        out[x..][0..8].* = u;
    }
    for (in[x..], out[x..]) |v, *o| o.* = if (max == 255) toU8(v) else toU16(v);
}

/// Copies the frame (before blending) into its reference slot.
fn saveFrame(d: *Decoder, fh: *const headers.FrameHeader, f: *const Frame) Error!void {
    const st = &d.store;
    const slot = &st.slots[fh.save_as_reference];
    const W = d.image.width;
    const H = d.image.height;
    const fw = f.w;
    const fhh = f.h;
    slot.valid = true;
    slot.before_ct = true;
    slot.full = f.x0 == 0 and f.y0 == 0 and fw >= W and fhh >= H;
    // A frame that covers the canvas is kept cropped to it; a smaller one
    // whole, for patches, if it fits in the slot.
    var sw: usize = W;
    var sh: usize = H;
    if (!slot.full) {
        sw = fw;
        sh = fhh;
        if (@as(u64, fw) * fhh > @as(u64, W) * H) sw = 0;
    }
    slot.w = sw;
    slot.h = if (sw == 0) 0 else sh;
    for (0..st.planes) |c| {
        for (0..slot.h) |y| f.row(c, y, 0, slot.planes[c][y * sw ..][0..sw]);
    }
}

fn saveCanvas(d: *Decoder, k: u32) void {
    const st = &d.store;
    const slot = &st.slots[k];
    for (0..st.planes) |c| @memcpy(slot.planes[c], st.canvas[c]);
    slot.valid = true;
    slot.full = true;
    slot.w = d.image.width;
    slot.h = d.image.height;
    slot.before_ct = false;
}

fn writeCanvas(d: *const Decoder, dst: PixelBuffer) void {
    const st = &d.store;
    const h = &d.image;
    const p = through(dst.format, h, pivot(h));
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
            packPivot(p, &fl, nc, alpha, n, &buf, !isFloat(h));
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
    const fw: i64 = f.w;
    const fhh: i64 = f.h;
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

test "a streamed frame's pixels are the whole frame's" {
    // basn2c08.png resized to 8 by 1100, `cjxl -d 2 --epf=3 --gaborish=1`:
    // five group rows of VarDCT with every EPF pass, so each band's window
    // reaches into its neighbors'.
    const file =
        "\xff\x0a\x5a\x22\xe0\x00\x48\x28\x5a\x04\x00\x13\x88\x06\x00\xe8\xc0\x3b\x08\x81\x02\x48\x00\x04" ++
        "\x4c\x80\x05\xd3\x4f\x12\x00\x80\x0a\x95\x51\xc6\x0d\x5e\xce\xf5\x7c\xf9\xa1\xc3\x62\xda\xc6\x75" ++
        "\x86\xb6\xda\xb6\xb0\x84\xb1\xd9\x5e\x18\x24\x4c\x81\x02\x35\x24\x99\xf1\xee\xb0\x07\x28\x1c\xa3" ++
        "\x1d\x63\x15\xa3\x2a\xaa\x99\xf1\xe2\xc5\xe0\x25\x01\x0d\x91\x8e\x00\x00\xc2\x15\x80\xa8\xc2\xb7" ++
        "\x8a\xc3\x56\x58\x62\x4d\xc2\x4a\x34\x9e\xf7\xdb\x5e\x7f\xf3\xd9\x67\x3f\x3b\x76\x7b\xe1\xdf\xc6" ++
        "\x84\x3c\x1a\x32\x18\x58\x13\x40\x71\xcb\x2f\x4b\x37\x6b\x9c\x99\x5d\x29\x11\xec\x9b\x02\xe0\xe2" ++
        "\xfb\x73\x79\x9e\xf3\x7b\x87\xfa\xba\xf7\xeb\xff\x89\xff\xa4\x9e\xff\xff\x8d\xfc\xf3\x9b\xb9\x65" ++
        "\xd2\x08\xd9\xeb\xe9\x4a\x4f\x50\xaf\x6e\xb9\xee\x17\x89\x91\x10\x06\x91\x84\xc1\x85\x09\x02\x84" ++
        "\x78\x9c\x66\x3b\xfd\x2e\x9c\x2d\xae\xad\xbe\xbc\xbf\xbd\xc6\x2d\x44\x0f\xe8\x1f\x09\x0a\x59\x8e" ++
        "\x2c\x53\x63\xfc\x66\x9c\x94\x15\x6f\x0c\xb9\x4d\xb7\xff\xb4\xa3\xd8\xe9\xfe\x07\xd9\x21\x4d\x47" ++
        "\xb4\x4e\x44\x87\x6c\x87\xf4\x80\xc8\x4f\x08\xca\x10\xe1\xe3\x87\xf7\xee\x5a\x26\x65\xbb\x35\x08" ++
        "\x07\xd8\x2b\x99\x35\x8f\x37\x47\x34\xdc\x46\x49\x00\x62\xd0\x27\xe8\xb0\x00\xed\xc5\xcf\x15\x14" ++
        "\xf5\xc5\x30\x03\xa3\x4e\xae\x86\x17\x56\xee\xe2\x18\xe6\xd7\xc2\x64\xad\x82\x26\xb7\x1c\xd5\x4f" ++
        "\x4f\x75\xaf\xfe\x5d\xd7\xd2\xc9\x05\x88\x77\x01\x31\x04\x90\x30\x16\x2b\x18\xa0\x08\x30\x49\x58" ++
        "\x34\xc1\xa0\xda\x5d\xa8\xf3\xf2\x60\xa4\x52\x04\x00\x02\x1a\x25\x81\x87\x06\x04\x78\xad\xcb\xf6" ++
        "\x09\x04\x29\x6b\x98\xca\x46\x99\x44\x0a\x0a\x8a\x05\xd3\x63\x38\x0c\x25\x64\x41\x61\x5b\xcb\x11" ++
        "\x6a\x54\xac\x24\x45\x09\xca\x70\xee\x00\xf9\x3b\x01\x27\x04\xfd\xd4\x23\x12\x00\xad\xcf\x97\x2f" ++
        "\x13\xf0\xe3\x7c\x20\x1c\x05\x3a\xb4\xba\x7c\xbe\xc3\x00\xf0\x6f\x26\xce\x8c\x0a\x01\x19\xc4\x1d" ++
        "\x4c\xf0\x00\x55\xaa\x07\x99\x13\x8c\xae\xb4\x77\xd2\x58\x10\xd0\xd0\x37\x27\x0c\x99\x0d\x0e\xf0" ++
        "\x61\xc0\x6d\xda\x4e\x02\x36\xab\x63\x71\xe9\x29\x4d\x19\x90\x39\x94\x20\x1b";
    try expectStreamsSame(file, 1100);
}

test "a streamed Modular frame's pixels are the whole frame's" {
    // basn2c08.png resized to 8 by 300, `cjxl -d 0 -g 0`: three group rows
    // of lossless Modular without global transforms.
    const file =
        "\xff\x0a\x58\x09\x0e\x80\x80\xa2\x45\x08\x00\x01\x00\x50\x01\x00\x00\x00\x24\xb8\xc3\x0b\x4b\x28" ++
        "\x31\xdd\xa4\xbd\xb9\x1e\xce\xdc\x9b\x87\x65\xeb\xad\x15\x24\x24\x14\xc6\x7c\x78\xdd\x4a\x41\x41" ++
        "\x41\x41\x41\x42\xc1\x11\x61\xec\x9c\x43\x44\x01\x11\x05\x05\x05\x05\x3d\xc0\x20\xa5\xd8\xe8\xb4" ++
        "\x0a\x03\x6d\x6c\x32\x6a\xe4\xc6\xa0\xcd\xab\x7a\xfc\x51\xc5\x18\x1d\x11\x41\xab\x18\xa3\x23\x62" ++
        "\xb8\xfa\xaa\x6e\xfd\x01\x00\x98\x00\x00\x53\x48\x67\x00\x60\x8b\xe7\x5f\x7e\xe6\x7f\x30\x12\x6a" ++
        "\x43\x05\x8b\x8e\x10\x49\x17\x10\xb6\x43\x45\x48\x2b\x5c\xdc\x29\xab\x71\x18\x56\x83\x27\x5c\x13" ++
        "\xc6\x62\x32\x2e\x19\x9f\x2d\xc9\xea\x36\x23\xcd\xa9\x5a\x02\x05\x25\xf9\x2b\xca\x51\x96\xb2\xd7" ++
        "\x5a\x1f\xbd\x87\xee\xb2\x31\xb4\x3d\x54\x54\x5c\xab\x53\xf5\xff\x27\x06\xfa\xb1\x1a\x29\x49\x36" ++
        "\xb2\x4d\xb2\xdc\x19\x48\x7b\x8c\x94\x90\x34\x4b\xc6\x5e\x4f\xdb\x1f\xb5\xe6\xff\x7f\xf7\x44\xfa" ++
        "\x75\xb9\xa9\x9c\x94\xda\x5b\x63\xf3\x93\x91\xd9\x69\xce\xc8\x5c\xe8\x07\x76\x55\x7a\xee\xf6\x42" ++
        "\x24\xfb\x01\x88\x6c\xdd\xe8\x22\x5f\xbc\x13\x48\xd3\xe6\xe2\x5f\xda\xe8\x7c\x13\x7b\x6b\xc6\xca" ++
        "\x1d\x94\x19\xa1\x13\x65\x37\x8a\x68\xfe\x0c\x60\x18\x15\x5e\x68\x27\x12\x90\xc7\x22\xe2\x23\x19" ++
        "\x1f\x6f\xc9\x52\x1f\x27\x8d\x0f\x45\x22\x71\x30\x19\xc9\x43\x6e\xbf\x1f\x15\x3a\x5e\xc2\xce\xef" ++
        "\xc7\x3b\xd1\x20\x3c\x33\x62\xc0\x72\x9c\xf6\xd2\x8f\x59\x28\x15\x36\x5e\x7b\x51\x6f\xe8\x60\x5f" ++
        "\x00\x91\x90\x69\xb4\x10\x41\x63\x84\x3e\xfd\x7e\x34\xfc\x7e\x80\x28\xff\x6f\x89\x5b\x90\xe8\x58" ++
        "\x8d\xa4\x28\xea\x4a\x29\xe5\x28\xf5\x90\x0d\xfe\x26\x6d\x7f\xde\x8b\xff\xff\xf1\x99\xe9\x87\x1f" ++
        "\x8d\x64\x5d\xe2\x70\x9c\xf7\x4a\x04\x1b\x57\x07\x26\x67\x21\x40\xcb\x74\xcc\x4b\x5d\x8d\x90\xd8" ++
        "\x84\x41\x90\x7b\xa6\xf9\x8f\x9b\x68\x41\x63\x93\x79\x9a\x9c\x82\xdf\x50\xd8\x44\x60\x45\x3d\xcf" ++
        "\xd0\xdb\xa7\x0c\xba\xae\xc5\x1c\xd7\x89\x5d\x84\xb1\x64\x61\x49\xc6\x6f\x6a\xf2\xef\x91\x83\x13" ++
        "\xd4\x18\xce\x6f\x97\xec\xd3\x4f\x0d\x10\x60\xd6\xe1\x04\x48\xe8\x16\xb0\xea\xd2\x8a\x13\x60\x1e" ++
        "\xc3\xc3\x7a\x91\xf0\x48\x8d\x04\x07\x80\x90\xa4\xd8\x80\x48\x51\x2e\xb3\x94\xa2\x68\xea\x6b\xcb" ++
        "\x88\xb1\xb4\xac\x55\x89\x4e\xa6\x64\x04\x67\x3a\xae\x44\xf4\xff\x7f\x39\x1e\xba\x01\x15\x10\x05" ++
        "\x45\x8b\x45\xc0\x5c\x09\x90";
    try expectStreamsSame(file, 300);
}

test "a streamed Modular frame with global transforms is the whole frame" {
    // basn6a08.png resized to 8 by 300, `cjxl -d 0 -g 0`: three group rows
    // with alpha, which cjxl palettes over the whole frame; the palette is
    // undone on each band.
    const file =
        "\xff\x0a\x58\x09\x0e\x80\x05\x45\x8b\x08\x00\x10\x00\x6c\x03\x00\x00\x40\x28\x54\x84\x0b\x0b\x80" ++
        "\x02\x8e\x70\x29\x2d\x84\x0d\x00\xf3\x32\x05\x46\xdc\xbd\x3d\x55\x16\xad\x69\x2c\x18\x81\xa2\xe4" ++
        "\x19\x6a\xb2\xd4\xd8\x25\x5b\x65\xbc\x54\x01\x50\x54\x50\xa8\x08\xbb\x95\x19\x09\xf1\x6a\xec\xf5" ++
        "\x01\x20\xa2\xa0\x10\x89\x44\x22\x94\xc8\xfc\x18\x63\x5c\x94\xa8\xab\xf6\x84\x53\x23\x28\x96\x2e" ++
        "\xa2\x51\x22\x86\x31\x8c\x8e\x47\x73\x7a\x8e\x52\x18\xc3\xd8\xc8\x78\x31\xc6\xd3\x5d\xdc\x0d\x4a" ++
        "\xa5\x09\xa1\xa8\xa3\x70\x0a\xd1\x50\x92\x1a\x84\x8a\x88\x90\x6b\x1c\x15\x32\x40\x93\x92\x89\x7a" ++
        "\x25\x00\x53\x40\x08\x24\x81\x20\x4c\x01\x61\x40\x00\x30\x45\x79\x02\x9c\xca\xb8\x45\xa8\x31\x06" ++
        "\x41\x38\xb4\x3b\xdd\xdf\x2a\xe2\xd2\x42\xcd\x82\x39\x6c\xd3\x88\x15\xd1\xb6\x28\x06\x26\xb6\xb1" ++
        "\xb2\x68\x6d\x9b\x83\x5e\x50\xe4\xc0\xdc\xd9\xe2\x8f\x24\x41\xcf\x3c\x1e\x1a\xd2\xac\xd9\xf0\xfc" ++
        "\x1d\x19\x9e\xc1\x59\x7a\xf6\xcd\x9c\xea\x9d\x58\xbc\x21\xa9\xe2\xbb\xba\x01\x77\xd2\x22\x42\x8c" ++
        "\x00\x17\x88\x3e\x00\x81\xe4\x00\x00\x23\xd8\xc3\x22\xfa\xc2\xf8\x0b\x82\x6c\x87\x70\x7f\x9a\xdc" ++
        "\x0c\xd2\xd8\x1d\x33\xa4\xea\x5a\xad\xfb\x9a\xb9\x10\x0b\xd6\xc6\xec\x99\x2b\x95\x62\xee\x5c\x13" ++
        "\x54\xe4\xc8\xed\x05\x12\xe2\x0d\x55\x87\x36\x13\x9e\x85\x71\xa2\x3a\xbe\xa0\x7b\xdc\x93\xfa\x76" ++
        "\x14\x2e\xfe\x7c\xa6\x90\x5d\xe1\xfb\xde\xd9\xf3\xff\xef\xbf\xe1\xd5\x21\x99\x95\x9e\xd6\xd2\x58" ++
        "\x00\x52\xec\x1d\x18\x72\x53\xf8\x94\xec\x0a\xf8\x20\x67\x20\xe7\xdf\x28\x98\xc9\x48\x8a\x40\x9a" ++
        "\x23\x0d\xb1\x51\xea\x04\x40\x80\xf7\x61\x33\xd3\xe7\x6c\xad\xde\x1d\xb1\x00\x90\x02\x48\x58\x3a" ++
        "\x85\x15\x75\x70\x18\xbb\x4a\x9f\x95\x2b\xdf\x80\x0f\x60\x00\xac\xa5\x02\x17\x08\x40\x60\x70\x0a" ++
        "\x77\x01\xc0\x2a\x65\x5e\x5c\x6e\xab\x34\xd9\x91\x25\x42\xca\x93\x73\x26\x5c\xc4\x4a\x11\xf4\x03" ++
        "\xba\x46\x33\x12\x61\x24\x78\xab\x04\x80\xae\x84\xfb\x01\x20\xb8\x2a\x6d\x4b\xdc\x55\x80\x89\x57" ++
        "\x8c\x42\xbe\x23\x00\x57\x3f\xc4\x12\x02\x03\x10\x17\x70\x84\xe8\x22\x68\x84\xfe\x73\x80\x39\x6e" ++
        "\x9e\x2a\x5f\x4a\xa3\x98\x18\x44\xa1\x67\x43\xf3\x25\x03\xb2\x25\xd1\x7c\x04\x59\xab\xd2\x65\xe0" ++
        "\xc4\x01\x57\x9f\x86\xd2\xb0\x86\x80\xea\x37\x21\xfb\xff\xe3\x8b\xfd\xbf\xfc\x8b\xfb\x7f\x25\xb9" ++
        "\x12\x4d\x0c\xa3\x59\x2f\x09\xc2\x3d\x3a\x08\xdc\x1e\xbc\x7f\x9e\x91\xc3\x73\x76\xb4\xbe\x17\xbe" ++
        "\x34\xf1\x5d\x8c\xc2\x21\xc1\xe8\x3d\x76\xa2\xc0\x52\xb2\xa1\x3d\x9c\x86\x64\x42\x88\x10\x4d\xb2" ++
        "\xff\x22\x9f\x60\x66\xae\x2c\x55\xa5\x51\xb8\xd3\x28\x21\x21\x71\x0f\x40\x00\x50\xfe\x2d\x8e\xe8" ++
        "\x6a\x65\x08\x84\x7c\x50\xc5\x29\x43\xe8\x40\x94\x2a\x25\xbb\x3d\xdc\xe8\xa2\x47\x68\xbb\xc6\x69" ++
        "\x2e\xa0\x64\xd3\x1c\x98\xe5\xdd\x3c\x68\x01\xa3\x1c\x9c\xef\xbe\xdf\x2c\x9a\xce\x44\x84\x2e\x92" ++
        "\x5c\x0f\x65\x8d\xb0\xd4\xa0\x0e\xc1\xe9\x5b\xda\x7d\x36\x56\x58\x44\xba\xdc\x03\xf8\x0c\xa1\xf4" ++
        "\x80\x0f\x60\x00\xac\xa5\x02\x17\x88\x15\x00\xfa\x87\x05\x80\x7d\xe9\xd3\xb2\xec\x4f\xfc\x9f\xfd" ++
        "\xff\xfc\xde\xfd\xec\xff\x74\x2f\xed\x7a\xff\xbd\xc1\x47\x91\x38\x71\x43\x4c\x3e\x16\x20\x1d\x96" ++
        "\x84\x2e\x00\x67\x0c";
    try expectStreamsSame(file, 300);
}

/// Decodes the 8 pixels wide `file` streamed and whole, and expects the
/// same pixels from less memory streamed.
fn expectStreamsSame(file: []const u8, comptime h: u32) !void {
    var out: [2][8 * h * 8]u8 = undefined;
    var peak: [2]usize = undefined;
    for (0..2) |i| {
        var r: Io.Reader = .fixed(file);
        var d: Decoder = .init(&r, .{});
        d.stream = i == 0;
        const c = try d.decodeConfig();
        const work = try testing.allocator.alloc(u8, c.work_len);
        defer testing.allocator.free(work);
        _ = try d.decodeFrame(try .init(&out[i], .rgba16, 8, h), work);
        peak[i] = d.store.arena.peak;
    }
    try testing.expectEqualSlices(u8, &out[1], &out[0]);
    try testing.expect(peak[0] < peak[1]);
}

test "signature" {
    var r: Io.Reader = .fixed("\xff\x0b");
    var d: Decoder = .init(&r, .{});
    try testing.expectError(error.BadSignature, d.decodeConfig());
    r = .fixed("");
    d = .init(&r, .{});
    try testing.expectError(error.Truncated, d.decodeConfig());
}

test "a jbrd box is reported" {
    // An 8×8 codestream with default metadata, transform data, and frame
    // header, split as libjxl splits it: the headers, `jbrd`, and the rest.
    const head = "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a" ++ "\x00\x00\x00\x14ftypjxl \x00\x00\x00\x00jxl ";
    const first = "\x00\x00\x00\x10jxlp\x00\x00\x00\x00\xff\x0a\x41\x06";
    const last = "\x00\x00\x00\x0djxlp\x80\x00\x00\x01\x01";
    var r: Io.Reader = .fixed(head ++ first ++ "\x00\x00\x00\x09jbrd\x00" ++ last);
    var d: Decoder = .init(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(8, config.width);
    try testing.expect(config.metadata.jpeg_reconstruction);
    r = .fixed(head ++ first ++ last);
    d = .init(&r, .{});
    try testing.expect(!(try d.decodeConfig()).metadata.jpeg_reconstruction);
}

test "an XYB image with an ICC profile reports the linear sRGB it is written in" {
    // An 8 by 8 image with a ProPhoto profile at gamma 1.8 (jxl-oxide's
    // test profile), through cjxl: lossy, which is XYB, then lossless,
    // which keeps the profile's space. Both deliver the profile.
    const xyb =
        "\xff\x0a\x41\x40\x0a\x4f\x18\x03\x12\xa6\x01\xd0\x52\x99\x9e\x24\x96\x61\x5e\xa7\x02\xbd\x96\xb5" ++
        "\x8e\xdc\x2d\xb1\x94\x17\x91\x42\x3a\x18\x8b\x82\x5f\x2b\xd8\x76\x28\x61\x51\x69\x81\x0b\xdd\x4e" ++
        "\x0b\x5b\x35\x3a\x0d\x96\xb0\x0e\xe2\xc8\x08\x9c\x18\xf9\xad\x53\xb3\xb1\xb5\xb5\x75\x62\x44\x4f" ++
        "\x4c\xe9\x03\xe0\xe2\x60\xe3\x54\xff\x01\x6e\xb1\xae\x93\x4d\x86\x23\x44\x73\x0a\xc0\x86\x5f\x5c" ++
        "\x7c\x24\x0c\x94\x7c\x6c\x6c\x6e\x44\xcd\x8d\xbd\xfa\xd9\xec\xbd\x6e\x1e\x84\xad\xad\xaf\xa4\x83" ++
        "\xaf\xb0\xb9\xb2\xa9\xa7\xa8\x74\x40\x90\x63\x52\x80\x85\xa1\xb3\xb4\xad\xa1\x6e\x80\x8b\xaf\xa4" ++
        "\xa1\x6b\x80\x83\xaf\xad\xb0\xa1\xae\x79\x58\x40\x62\x72\x72\x72\x58\x80\xa1\xac\x6c\xc0\x4f\x94" ++
        "\x73\x80\xb2\xa5\xb3\xa5\xb2\xb6\xa5\x64\x1c\xc0\xae\x90\xb2\xaf\x90\xa8\xaf\xb4\x6f\x80\x92\x87" ++
        "\x02\x7f\xd8\xae\xbf\x7f\x84\x50\xc6\x17\x21\x44\xf1\x45\x1a\x5f\x02\x50\xc2\x03\x05\x6e\x67\x3e" ++
        "\x96\xda\x6b\x65\xae\x25\x9d\x86\x01\x33\x6d\x02\x94\x19\x0a\x26\xed\x01\x40\x44\x39\x50\x5b\x3c" ++
        "\x00\x6c\x2c\x81\x25\x74\x9a\x06\x2c\xbf\xef\x25\x17\xfe\xbd\xe1\xea\xef\x1f\x17\x7c\x90\xc0\x00" ++
        "\x17\xfe\x1f\x7f\x3e\x39\x4a\x96\x9a\x96\xca\x96\xba\x8e\x96\x01\x3e\xd6\xd2\xc2\xd6\xd2\x01\x36" ++
        "\x96\x92\xa6\xd6\xb6\xd7\x52\x5a\xd9\xd4\x31\xe8\xfb\x76\x4e\x0a\x08\x00\x00\x08\xba\x8a\x50\xc2" ++
        "\x12\x4d\x2c\x51\xc6\x12\x5d\x1c\xb1\x24\x00\x1f\xac\x91\x46\x98\xef\x2a\x00\x1b\x2c\x91\xc4\x14" ++
        "\x6b\x6c\xf9\xdd\x95\x46\x19\x53\x1c\x09\x42\x09\x1f\x6c\xb0\x21\x89\x00\x02\x9e\xd4\xc0\x03\x3e" ++
        "\x2b\xf8\x61\x79\x00\xda\x79\x9d\x8b\xc2\xfa\xcc\x2e\xe0\x6e\x0e\x00\x13\x88\x02\x00\xc4\x00\xb5" ++
        "\x9f\x20\x00\x00\x15\x2a\xa3\x8c\x1b\xbc\x9c\xeb\xf9\xf2\x43\x87\xc5\xb4\x8d\xeb\x0c\x6d\xb5\x6d" ++
        "\x61\x09\x63\xb3\xbd\x30\x48\x48\x38\x82\x8d\x8b\xc6\xdf\x1c\xfd\xae\x0a\x19\x90\x90\x4a\x12\x00";
    const lossless =
        "\xff\x0a\x41\x40\x08\x4f\x18\x03\x12\xa6\x01\xd0\x52\x99\x9e\x24\x96\x61\x5e\xa7\x02\xbd\x96\xb5" ++
        "\x8e\xdc\x2d\xb1\x94\x17\x91\x42\x3a\x18\x8b\x82\x5f\x2b\xd8\x76\x28\x61\x51\x69\x81\x0b\xdd\x4e" ++
        "\x0b\x5b\x35\x3a\x0d\x96\xb0\x0e\xe2\xc8\x08\x9c\x18\xf9\xad\x53\xb3\xb1\xb5\xb5\x75\x62\x44\x4f" ++
        "\x4c\xe9\x03\xe0\xe2\x60\xe3\x54\xff\x01\x6e\xb1\xae\x93\x4d\x86\x23\x44\x73\x0a\xc0\x86\x5f\x5c" ++
        "\x7c\x24\x0c\x94\x7c\x6c\x6c\x6e\x44\xcd\x8d\xbd\xfa\xd9\xec\xbd\x6e\x1e\x84\xad\xad\xaf\xa4\x83" ++
        "\xaf\xb0\xb9\xb2\xa9\xa7\xa8\x74\x40\x90\x63\x52\x80\x85\xa1\xb3\xb4\xad\xa1\x6e\x80\x8b\xaf\xa4" ++
        "\xa1\x6b\x80\x83\xaf\xad\xb0\xa1\xae\x79\x58\x40\x62\x72\x72\x72\x58\x80\xa1\xac\x6c\xc0\x4f\x94" ++
        "\x73\x80\xb2\xa5\xb3\xa5\xb2\xb6\xa5\x64\x1c\xc0\xae\x90\xb2\xaf\x90\xa8\xaf\xb4\x6f\x80\x92\x87" ++
        "\x02\x7f\xd8\xae\xbf\x7f\x84\x50\xc6\x17\x21\x44\xf1\x45\x1a\x5f\x02\x50\xc2\x03\x05\x6e\x67\x3e" ++
        "\x96\xda\x6b\x65\xae\x25\x9d\x86\x01\x33\x6d\x02\x94\x19\x0a\x26\xed\x01\x40\x44\x39\x50\x5b\x3c" ++
        "\x00\x6c\x2c\x81\x25\x74\x9a\x06\x2c\xbf\xef\x25\x17\xfe\xbd\xe1\xea\xef\x1f\x17\x7c\x90\xc0\x00" ++
        "\x17\xfe\x1f\x7f\x3e\x39\x4a\x96\x9a\x96\xca\x96\xba\x8e\x96\x01\x3e\xd6\xd2\xc2\xd6\xd2\x01\x36" ++
        "\x96\x92\xa6\xd6\xb6\xd7\x52\x5a\xd9\xd4\x31\xe8\xfb\x76\x4e\x0a\x08\x00\x00\x08\xba\x8a\x50\xc2" ++
        "\x12\x4d\x2c\x51\xc6\x12\x5d\x1c\xb1\x24\x00\x1f\xac\x91\x46\x98\xef\x2a\x00\x1b\x2c\x91\xc4\x14" ++
        "\x6b\x6c\xf9\xdd\x95\x46\x19\x53\x1c\x09\x42\x09\x1f\x6c\xb0\x21\x89\x00\x02\x9e\xd4\xc0\x03\x3e" ++
        "\x2b\xf8\x61\x79\x00\xda\x79\x9d\x8b\xc2\xfa\xcc\x2e\xe0\x6e\x0e\x08\x00\x01\x00\x50\x00\x4b\x18" ++
        "\x8b\x15\x00\x94\x88\xc1\xb8\x3b\x80\x93\x38\x45\x05\x00\x64\x67\x32\x01";
    var r: Io.Reader = .fixed(xyb);
    var d: Decoder = .init(&r, .{});
    var m = (try d.decodeConfig()).metadata;
    try testing.expectEqual(decode.Transfer.linear, m.transfer.?);
    try testing.expectEqual([8]f32{ 0.64, 0.33, 0.3, 0.6, 0.15, 0.06, 0.3127, 0.329 }, m.primaries.?);
    r = .fixed(lossless);
    d = .init(&r, .{});
    m = (try d.decodeConfig()).metadata;
    try testing.expectEqual(null, m.transfer);
    try testing.expectEqual(null, m.primaries);
    try testing.expectEqual(null, m.gamma);
    // `skim` reads past the profile and finds the lossy frame drawn in
    // floats and the lossless one not.
    for ([2][]const u8{ xyb, lossless }, [2]bool{ true, false }) |file, float| {
        r = .fixed(file);
        d = .init(&r, .{});
        const work = try testing.allocator.alloc(u8, (try d.decodeConfig()).work_len);
        defer testing.allocator.free(work);
        var s: Skim = .{};
        try d.skim(work, &s);
        try testing.expectEqual(Skim{ .float = float }, s);
        try testing.expectEqual(null, try d.decodeFrame(try .init(&.{}, .rgba8, 0, 0), work));
    }
}

test "the colour encoding and intensity target are reported" {
    // 8 by 8 lossless files from cjxl with `-x color_space=` and
    // `--intensity_target`: BT.2100 primaries with PQ at 4000 nits, P3 with
    // a gamma of 0.45455, and custom primaries and white point (0.7, 0.29;
    // 0.2, 0.75; 0.12, 0.05; white 0.31, 0.32) with HLG, which jxlinfo
    // reports at 1000 nits. BT.2100's primaries are BT.2020's.
    const files = [_][]const u8{
        "\x00\x00\x00\x0c\x4a\x58\x4c\x20\x0d\x0a\x87\x0a\x00\x00\x00\x14\x66\x74\x79\x70\x6a\x78\x6c\x20" ++
            "\x00\x00\x00\x00\x6a\x78\x6c\x20\x00\x00\x00\x09\x6a\x78\x6c\x6c\x0a\x00\x00\x00\x33\x6a\x78\x6c" ++
            "\x63\xff\x0a\x41\x04\xfc\x00\xe4\xd1\x03\xbd\x06\x00\x00\x00\x80\x08\x00\x01\x00\x58\x00\x4b\x18" ++
            "\x8b\x15\x00\x9c\x11\x83\x97\xbb\x03\x38\x83\x57\x54\x00\xc0\xb9\x66\x26\x33\x13",
        "\x00\x00\x00\x0c\x4a\x58\x4c\x20\x0d\x0a\x87\x0a\x00\x00\x00\x14\x66\x74\x79\x70\x6a\x78\x6c\x20" ++
            "\x00\x00\x00\x00\x6a\x78\x6c\x20\x00\x00\x00\x09\x6a\x78\x6c\x6c\x0a\x00\x00\x00\x2f\x6a\x78\x6c" ++
            "\x63\xff\x0a\x41\xf0\x03\x90\x99\x7b\xab\x08\x02\x08\x00\x01\x00\x58\x00\x4b\x18\x8b\x15\x00\x9c" ++
            "\x11\x83\x97\xbb\x03\x38\x83\x57\x54\x00\xc0\xb9\x66\x26\x33\x13",
        "\x00\x00\x00\x0c\x4a\x58\x4c\x20\x0d\x0a\x87\x0a\x00\x00\x00\x14\x66\x74\x79\x70\x6a\x78\x6c\x20" ++
            "\x00\x00\x00\x00\x6a\x78\x6c\x20\x00\x00\x00\x09\x6a\x78\x6c\x6c\x0a\x00\x00\x00\x49\x6a\x78\x6c" ++
            "\x63\xff\x0a\x41\x04\xfc\x00\x08\x81\xd7\x25\x00\xe2\x08\x02\x73\x55\xa0\xd9\x00\x50\xc3\x82\x8d" ++
            "\x1b\x80\xa9\x03\xd4\x30\x06\x00\x3d\x06\x00\x00\x00\x80\x08\x00\x01\x00\x58\x00\x4b\x18\x8b\x15" ++
            "\x00\x9c\x11\x83\x97\xbb\x03\x38\x83\x57\x54\x00\xc0\xb9\x66\x26\x33\x13",
    };
    const want = [_]decode.Metadata{
        .{
            .transfer = .pq,
            .primaries = .{ 0.708, 0.292, 0.17, 0.797, 0.131, 0.046, 0.3127, 0.329 },
            .intensity_target = 4000,
        },
        .{
            .gamma = 45455,
            .primaries = .{ 0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329 },
            .intensity_target = 255,
        },
        .{
            .transfer = .hlg,
            .primaries = .{ 0.7, 0.29, 0.2, 0.75, 0.12, 0.05, 0.31, 0.32 },
            .intensity_target = 1000,
        },
    };
    for (files, want) |file, w| {
        var r: Io.Reader = .fixed(file);
        var d: Decoder = .init(&r, .{});
        const m = (try d.decodeConfig()).metadata;
        try testing.expectEqual(w.transfer, m.transfer);
        try testing.expectEqual(w.gamma, m.gamma);
        try testing.expectEqual(w.intensity_target, m.intensity_target);
        for (w.primaries.?, m.primaries.?) |a, b| try testing.expectApproxEqAbs(a, b, 1e-6);
    }
}

test "an image survives a broken box after its codestream" {
    // cjxl's lossless 2 by 2 image of #204060 in a container.
    const file =
        "\x00\x00\x00\x0c\x4a\x58\x4c\x20\x0d\x0a\x87\x0a\x00\x00\x00\x14\x66\x74\x79\x70\x6a\x78\x6c\x20" ++
        "\x00\x00\x00\x00\x6a\x78\x6c\x20\x00\x00\x00\x27\x6a\x78\x6c\x63\xff\x0a\x08\x10\x10\x50\x5c\x08" ++
        "\x08\x00\x01\x00\x44\x00\x4b\x18\x8b\x15\xc2\x01\x63\x5c\xf0\x7f\x00\x0e\xc0\xfe\x60\x19\x00";
    var px: [2 * 2 * 3]u8 = undefined;
    const dst = try PixelBuffer.init(&px, .rgb8, 2, 2);
    // A box whose size runs past the end of the file: the image comes back
    // whole, and the call after it reports the box.
    var r: Io.Reader = .fixed(file ++ "\x00\x00\x03\xe8zzzz");
    var d: Decoder = .init(&r, .{});
    const work = try testing.allocator.alloc(u8, (try d.decodeConfig()).work_len);
    defer testing.allocator.free(work);
    _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqualSlices(u8, &([_]u8{ 0x20, 0x40, 0x60 } ** 4), &px);
    try testing.expectError(error.Truncated, d.decodeFrame(dst, work));
    // An Exif box after the codestream is reported once the decode ends.
    r = .fixed(file ++ "\x00\x00\x00\x10Exif\x00\x00\x00\x00MM\x00\x2a");
    d = .init(&r, .{});
    _ = try d.decodeConfig();
    _ = (try d.decodeFrame(dst, work)).?;
    try testing.expectEqual(null, (try d.decodeConfig()).metadata.exif);
    try testing.expectEqual(null, try d.decodeFrame(dst, work));
    try testing.expect((try d.decodeConfig()).metadata.exif != null);
}

test "16-bit output matches the reference's float path" {
    // An 8-bit sample widens to v * 257 through f32 arithmetic.
    const depth: headers.BitDepth = .{ .bits = 8 };
    var in: [256]i32 = undefined;
    for (&in, 0..) |*v, i| v.* = @intCast(i);
    var out: [256]f32 = undefined;
    frame.toFloat(depth, &in, &out);
    for (out, 0..) |v, i| try testing.expectEqual(@as(u16, @intCast(i * 257)), toU16(v));
}

test "nearest even" {
    try testing.expectEqual(@as(u32, 2), nearestEven(2.5));
    try testing.expectEqual(@as(u32, 4), nearestEven(3.5));
    try testing.expectEqual(@as(u32, 3), nearestEven(2.75));
}

test "int to float" {
    // binary16 1.0 is 0x3c00.
    try testing.expectEqual(@as(f32, 1.0), frame.intToFloat(0x3c00, 16, 5));
    try testing.expectEqual(@as(f32, -2.0), frame.intToFloat(0xc000, 16, 5));
}
