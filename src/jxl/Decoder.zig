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
const patches = @import("patches.zig");
const splines = @import("splines.zig");

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

const State = enum { start, config, frames, done };

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
    const h = &d.image;
    const px: u128 = @as(u128, h.width) * h.height;
    const c: u128 = planeCount(h);
    const plane = px * 4;
    var total: u128 = 0;
    if (d.needs_refs) {
        total += 5 * c * plane;
        for (1..5) |level| total += 3 * 4 * @as(u128, lfCapacity(h, @intCast(level)));
    }
    // One frame: the only one, when the peeked first frame is the last;
    // otherwise any.
    const only: ?*const headers.FrameHeader = if (d.next_frame) |*f| (if (f.is_last) f else null) else null;
    total += frameBound(h, only);
    // A group's channels with their transforms, at the peeked frame's
    // group size or the largest.
    const gd: u128 = if (d.next_frame) |f| @as(u128, 128) << @intCast(f.group_size_shift) else 1024;
    const group_px: u128 = @min(gd * gd, px);
    total += 4 * c * 4 * group_px;
    // The global tree and one local tree.
    const node: u128 = @sizeOf(modular.Node);
    total += @as(u128, @min(1 << 22, 1024 + frame_scale * px * c / 16)) * node;
    total += @as(u128, @min(1 << 20, 1024 + group_px * c)) * node;
    // Entropy codes: three live at once, each with tables and a window.
    const window: u128 = entropy.window_size;
    total += 3 * (entropy_budget + 4 * @as(u128, @min(px * c, window)));
    // Rows of reference properties and the weighted predictor.
    total += 1088 * @as(u128, h.width) + 65536;
    if (d.icc_size) |s| total = @max(total, icc.workLen(s) + entropy_budget + 4 * @as(u128, @min(s, window)) + 65536);
    return std.math.cast(usize, total) orelse error.WorkTooLarge;
}

/// The memory one frame's pixels take (docs/slop/jxl.md, work memory):
/// frame `f`'s, or with `f` null, the most any frame of up to
/// `frame_scale` times the canvas may take, Modular or VarDCT, with every
/// feature.
fn frameBound(h: *const headers.ImageHeader, f: ?*const headers.FrameHeader) u128 {
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
    total += 3 * nm * pre_px * 4 + pre_px * 4 + 4 * 137_728 * @max(nm, 1);
    if (vardct_frame) {
        // VarDCT's three planes, coefficients kept between passes, block
        // fields; a pass group's coefficients and scratch, the LF group's
        // channels, the dequantization tables, and each pass's orders and
        // code.
        const window: u128 = entropy.window_size;
        total += pad_px * 12 + (if (passes > 1) pad_px * 12 else 0) + pad_px / 64 * 24;
        total += 4 << 20;
        total += passes * (entropy_budget + 4 * @as(u128, @min(3 * pad_px, window)) + 786_432);
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
    if (isFloat(h)) return if (premultiplied(h)) .rgba_f32_premul else .rgba_f32;
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
    const dec = try frame.decode(&d.br, &st.arena, image, fh, &toc, .{ d.visible, d.nonvisible }, &refs, lf_in);
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
    const src: Frame = .{
        .d = d,
        .img = &dec.img,
        .num_color = dec.num_color,
        .color = dec.color,
        .color_stride = dec.color_stride,
        .ec = dec.ec,
        .w = dec.w,
        .h = dec.h,
        .x0 = fh.x0,
        .y0 = fh.y0,
    };
    if (dec.color != null) d.float_frames = true;
    if (refd and fh.save_before_ct) try d.saveFrame(fh, &src);
    frame.colorTransform(image, fh, &dec);
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
    /// The color channels as floats, when not in `img` (VarDCT).
    color: ?[3][]f32,
    color_stride: usize,
    /// The extra channels as floats, rows of `w`, when not in `img`
    /// (upsampled).
    ec: ?[]const []f32,
    w: u32,
    h: u32,
    x0: i32,
    y0: i32,

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
        const in = ch.row(y)[x..][0..out.len];
        frame.toFloat(depth, in, out);
    }

    /// Writes the frame, which covers the canvas, to `dst`, through the
    /// native format, so that every format is the native pixels
    /// converted. (A blended canvas goes through `pivot` instead, which
    /// keeps the blend's precision as the reference does.)
    fn write(f: *const Frame, dst: PixelBuffer) void {
        const h = &f.d.image;
        const p = f.d.native_format;
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
    var q: [chunk]u16 = undefined;
    const max: f32 = if (p.sample() == .u8) 255 else 65535;
    for (0..nc) |k| {
        const c = if (k < num_color) k else ai.?;
        quantize(fl[c][0..n], q[0..n], max);
        if (p.sample() == .u8) {
            for (0..n) |x| buf[x * nc + k] = @intCast(q[x]);
        } else {
            const out = std.mem.bytesAsSlice(u16, buf[0 .. n * nc * 2]);
            for (0..n) |x| out[x * nc + k] = q[x];
        }
    }
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
