//! The codestream headers (ISO/IEC 18181-1): the size header, the image
//! metadata with its extra channels, colour encoding, tone mapping and
//! custom transform data, and each frame's header with its passes,
//! blending, and restoration filters. Each bundle reads its fields in the
//! specification's order, with its defaults when `all_default` is set.

const std = @import("std");
const testing = std.testing;

const BitReader = @import("BitReader.zig");
const Dist = BitReader.Dist;
const weights = @import("upsample_weights.zig");

pub const Error = BitReader.Error || error{
    /// More extra channels than this decoder holds (`max_extra_channels`).
    Unsupported,
};

/// The most extra channels this decoder accepts. The format allows 4096;
/// more than this is `Unsupported`.
pub const max_extra_channels = 16;

pub const BitDepth = struct {
    float: bool = false,
    bits: u32 = 8,
    exp_bits: u32 = 0,

    fn read(br: *BitReader) Error!BitDepth {
        var d: BitDepth = .{};
        d.float = try br.boolean();
        if (!d.float) {
            d.bits = try br.u32Dist(.{ .v(8), .v(10), .v(12), .bo(6, 1) });
            if (d.bits > 31) return error.BadHeader;
        } else {
            d.bits = try br.u32Dist(.{ .v(32), .v(16), .v(24), .bo(6, 1) });
            d.exp_bits = 1 + try br.bits(4);
            if (d.exp_bits < 2 or d.exp_bits > 8) return error.BadHeader;
            const mantissa = @as(i64, d.bits) - d.exp_bits - 1;
            if (mantissa < 2 or mantissa > 23) return error.BadHeader;
        }
        return d;
    }
};

pub const ExtraKind = enum(u32) {
    alpha = 0,
    depth = 1,
    spot_color = 2,
    selection_mask = 3,
    black = 4,
    cfa = 5,
    thermal = 6,
    optional = 16,
};

pub const ExtraChannel = struct {
    kind: ExtraKind = .alpha,
    depth: BitDepth = .{},
    dim_shift: u32 = 0,
    alpha_associated: bool = false,
    spot: [4]f32 = @splat(0),
    cfa: u32 = 1,

    fn read(br: *BitReader) Error!ExtraChannel {
        var e: ExtraChannel = .{};
        if (try br.boolean()) return e;
        const kind = try br.enumField();
        e.kind = switch (kind) {
            0...6, 16 => @fromBackingInt(@intCast(kind)),
            else => return error.BadHeader,
        };
        e.depth = try .read(br);
        e.dim_shift = try br.u32Dist(.{ .v(0), .v(3), .v(4), .bo(3, 1) });
        if (e.dim_shift > 3) return error.BadHeader;
        try skipName(br);
        if (e.kind == .alpha) e.alpha_associated = try br.boolean();
        if (e.kind == .spot_color) {
            for (&e.spot) |*c| c.* = try br.f16Field();
        }
        if (e.kind == .cfa) e.cfa = try br.u32Dist(.{ .v(1), .b(2), .bo(4, 3), .bo(8, 19) });
        return e;
    }
};

fn skipName(br: *BitReader) Error!void {
    const len = try br.u32Dist(.{ .v(0), .b(4), .bo(5, 16), .bo(10, 48) });
    try br.skipBits(@as(u64, len) * 8);
}

pub const ColourSpace = enum(u32) { rgb = 0, grey = 1, xyb = 2, unknown = 3 };
pub const WhitePoint = enum(u32) { d65 = 1, custom = 2, e = 10, dci = 11 };
pub const Primaries = enum(u32) { srgb = 1, custom = 2, bt2100 = 9, p3 = 11 };
pub const TransferFunction = enum(u32) {
    bt709 = 1,
    unknown = 2,
    linear = 8,
    srgb = 13,
    pq = 16,
    dci = 17,
    hlg = 18,
};

pub const ColourEncoding = struct {
    want_icc: bool = false,
    space: ColourSpace = .rgb,
    white_point: WhitePoint = .d65,
    white: [2]i32 = .{ 0, 0 },
    primaries: Primaries = .srgb,
    /// Red, green, and blue xy, times 1e6.
    prim: [3][2]i32 = @splat(.{ 0, 0 }),
    /// Gamma times 1e7, when `have_gamma`.
    have_gamma: bool = false,
    gamma: u32 = 0,
    transfer: TransferFunction = .srgb,
    intent: u32 = 1,

    fn read(br: *BitReader) Error!ColourEncoding {
        var c: ColourEncoding = .{};
        if (try br.boolean()) return c;
        c.want_icc = try br.boolean();
        c.space = std.enums.fromInt(ColourSpace, try br.enumField()) orelse return error.BadHeader;
        if (c.want_icc) return c;
        if (c.space != .xyb) {
            c.white_point = std.enums.fromInt(WhitePoint, try br.enumField()) orelse return error.BadHeader;
            if (c.white_point == .custom) c.white = try readXy(br);
        }
        if (c.space != .grey and c.space != .xyb) {
            c.primaries = std.enums.fromInt(Primaries, try br.enumField()) orelse return error.BadHeader;
            if (c.primaries == .custom) {
                for (&c.prim) |*p| p.* = try readXy(br);
            }
        }
        if (c.space == .xyb) {
            c.have_gamma = true;
            c.gamma = 3333333;
        } else {
            c.have_gamma = try br.boolean();
            if (c.have_gamma) {
                c.gamma = try br.bits(24);
                if (c.gamma > 10_000_000 or @as(u64, c.gamma) * 8192 < 10_000_000) return error.BadHeader;
            } else {
                c.transfer = std.enums.fromInt(TransferFunction, try br.enumField()) orelse return error.BadHeader;
            }
        }
        const intent = try br.enumField();
        if (intent > 3) return error.BadHeader;
        c.intent = intent;
        if (c.space == .unknown or (!c.have_gamma and c.transfer == .unknown)) return error.BadHeader;
        return c;
    }

    fn readXy(br: *BitReader) Error![2]i32 {
        const d: [4]Dist = .{ .b(19), .bo(19, 524288), .bo(20, 1048576), .bo(21, 2097152) };
        return .{ unpackSigned(try br.u32Dist(d)), unpackSigned(try br.u32Dist(d)) };
    }
};

pub fn unpackSigned(v: u32) i32 {
    return if (v & 1 == 0) @intCast(v >> 1) else -@as(i32, @intCast(v >> 1)) - 1;
}

pub const ToneMapping = struct {
    intensity_target: f32 = 255,
    min_nits: f32 = 0,
    relative_to_max_display: bool = false,
    linear_below: f32 = 0,

    fn read(br: *BitReader) Error!ToneMapping {
        var t: ToneMapping = .{};
        if (try br.boolean()) return t;
        t.intensity_target = try br.f16Field();
        if (t.intensity_target <= 0) return error.BadHeader;
        t.min_nits = try br.f16Field();
        if (t.min_nits < 0 or t.min_nits > t.intensity_target) return error.BadHeader;
        t.relative_to_max_display = try br.boolean();
        t.linear_below = try br.f16Field();
        if (t.linear_below < 0 or (t.relative_to_max_display and t.linear_below > 1)) return error.BadHeader;
        return t;
    }
};

pub const OpsinInverse = struct {
    matrix: [3][3]f32 = .{
        .{ 11.031566901960783, -9.866943921568629, -0.16462299647058826 },
        .{ -3.254147380392157, 4.418770392156863, -0.16462299647058826 },
        .{ -3.6588512862745097, 2.7129230470588235, 1.9459282392156863 },
    },
    bias: [3]f32 = @splat(-0.0037930732552754493),
    quant_bias: [3]f32 = .{ 1 - 0.05465007330715401, 1 - 0.07005449891748593, 1 - 0.049935103337343655 },
    quant_bias_numerator: f32 = 0.145,

    fn read(br: *BitReader) Error!OpsinInverse {
        var o: OpsinInverse = .{};
        if (try br.boolean()) return o;
        for (&o.matrix) |*row| {
            for (row) |*v| v.* = try br.f16Field();
        }
        for (&o.bias) |*v| v.* = try br.f16Field();
        for (&o.quant_bias) |*v| v.* = try br.f16Field();
        o.quant_bias_numerator = try br.f16Field();
        return o;
    }
};

pub const Animation = struct {
    tps_numerator: u32,
    tps_denominator: u32,
    num_loops: u32,
    have_timecodes: bool,
};

/// The size header and image metadata, and the custom transform data.
pub const ImageHeader = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// EXIF orientation minus one.
    orientation: u3 = 0,
    intrinsic: ?[2]u32 = null,
    preview: ?[2]u32 = null,
    animation: ?Animation = null,
    depth: BitDepth = .{},
    modular_16bit: bool = true,
    num_ec: u32 = 0,
    ec: [max_extra_channels]ExtraChannel = undefined,
    xyb: bool = true,
    colour: ColourEncoding = .{},
    tone: ToneMapping = .{},
    opsin: OpsinInverse = .{},
    up2: [15]f32 = weights.up2,
    up4: [55]f32 = weights.up4,
    up8: [210]f32 = weights.up8,

    pub fn read(br: *BitReader) Error!ImageHeader {
        var h: ImageHeader = .{};
        const size = try readSize(br);
        h.width = size[0];
        h.height = size[1];
        // ImageMetadata.
        if (!try br.boolean()) {
            const extra_fields = try br.boolean();
            if (extra_fields) {
                h.orientation = @intCast(try br.bits(3));
                if (try br.boolean()) h.intrinsic = try readSize(br);
                if (try br.boolean()) h.preview = try readPreview(br);
                if (try br.boolean()) {
                    h.animation = .{
                        .tps_numerator = try br.u32Dist(.{ .v(100), .v(1000), .bo(10, 1), .bo(30, 1) }),
                        .tps_denominator = try br.u32Dist(.{ .v(1), .v(1001), .bo(8, 1), .bo(10, 1) }),
                        .num_loops = try br.u32Dist(.{ .v(0), .b(3), .b(16), .b(32) }),
                        .have_timecodes = try br.boolean(),
                    };
                }
            }
            h.depth = try .read(br);
            h.modular_16bit = try br.boolean();
            h.num_ec = try br.u32Dist(.{ .v(0), .v(1), .bo(4, 2), .bo(12, 1) });
            if (h.num_ec > max_extra_channels) return error.Unsupported;
            for (h.ec[0..h.num_ec]) |*e| e.* = try .read(br);
            h.xyb = try br.boolean();
            h.colour = try .read(br);
            if (extra_fields) h.tone = try .read(br);
            try readExtensions(br);
        }
        // CustomTransformData.
        if (!try br.boolean()) {
            if (h.xyb) h.opsin = try .read(br);
            const mask = try br.bits(3);
            if (mask & 1 != 0) for (&h.up2) |*w| {
                w.* = try br.f16Field();
            };
            if (mask & 2 != 0) for (&h.up4) |*w| {
                w.* = try br.f16Field();
            };
            if (mask & 4 != 0) for (&h.up8) |*w| {
                w.* = try br.f16Field();
            };
        }
        return h;
    }

    /// The index of the first alpha channel, if any.
    pub fn alphaChannel(h: *const ImageHeader) ?u32 {
        for (h.ec[0..h.num_ec], 0..) |e, i| {
            if (e.kind == .alpha) return @intCast(i);
        }
        return null;
    }

    /// The number of colour channels: 1 for grey, else 3.
    pub fn colourChannels(h: *const ImageHeader) u32 {
        return if (h.colour.space == .grey) 1 else 3;
    }
};

fn readSize(br: *BitReader) Error![2]u32 {
    const d: [4]Dist = .{ .bo(9, 1), .bo(13, 1), .bo(18, 1), .bo(30, 1) };
    const small = try br.boolean();
    const height = if (small) (try br.bits(5) + 1) * 8 else try br.u32Dist(d);
    const ratio = try br.bits(3);
    const width = if (ratio != 0)
        applyRatio(ratio, height)
    else if (small)
        (try br.bits(5) + 1) * 8
    else
        try br.u32Dist(d);
    return .{ width, height };
}

fn applyRatio(ratio: u32, y: u32) u32 {
    const r = [7][2]u64{ .{ 1, 1 }, .{ 12, 10 }, .{ 4, 3 }, .{ 3, 2 }, .{ 16, 9 }, .{ 5, 4 }, .{ 2, 1 } };
    const v = @as(u64, y) * r[ratio - 1][0] / r[ratio - 1][1];
    return @intCast(@min(v, std.math.maxInt(u32)));
}

fn readPreview(br: *BitReader) Error![2]u32 {
    const d8: [4]Dist = .{ .v(16), .v(32), .bo(5, 1), .bo(9, 33) };
    const d: [4]Dist = .{ .bo(6, 1), .bo(8, 65), .bo(10, 321), .bo(12, 1345) };
    const div8 = try br.boolean();
    const height = if (div8) try br.u32Dist(d8) * 8 else try br.u32Dist(d);
    const ratio = try br.bits(3);
    const width = if (ratio != 0)
        applyRatio(ratio, height)
    else if (div8)
        try br.u32Dist(d8) * 8
    else
        try br.u32Dist(d);
    if (width > 4096 or height > 4096) return error.BadHeader;
    return .{ width, height };
}

/// An extensions field: a mask, a bit count per extension, and the bits,
/// all skipped since this decoder knows no extensions.
fn readExtensions(br: *BitReader) Error!void {
    var mask = try br.u64Field();
    if (mask != 0) br.extensions +|= 1;
    var total: u64 = 0;
    while (mask != 0) : (mask &= mask - 1) {
        total = std.math.add(u64, total, try br.u64Field()) catch return error.BadHeader;
    }
    try br.skipBits(total);
}

pub const FrameType = enum(u32) { regular = 0, lf = 1, reference_only = 2, skip_progressive = 3 };

pub const BlendMode = enum(u32) { replace = 0, add = 1, blend = 2, alpha_weighted_add = 3, mul = 4 };

pub const BlendingInfo = struct {
    mode: BlendMode = .replace,
    alpha_channel: u32 = 0,
    clamp: bool = false,
    source: u32 = 0,

    fn read(br: *BitReader, num_ec: u32, partial: bool) Error!BlendingInfo {
        var b: BlendingInfo = .{};
        const mode = try br.u32Dist(.{ .v(0), .v(1), .v(2), .bo(2, 3) });
        b.mode = std.enums.fromInt(BlendMode, mode) orelse return error.BadHeader;
        const uses_alpha = num_ec > 0 and (b.mode == .blend or b.mode == .alpha_weighted_add);
        if (uses_alpha) {
            b.alpha_channel = try br.u32Dist(.{ .v(0), .v(1), .v(2), .bo(3, 3) });
            if (b.alpha_channel >= num_ec) return error.BadHeader;
        }
        if (uses_alpha or b.mode == .mul) b.clamp = try br.boolean();
        if (b.mode != .replace or partial) b.source = try br.bits(2);
        return b;
    }
};

pub const Passes = struct {
    num: u32 = 1,
    num_ds: u32 = 0,
    shift: [11]u32 = @splat(0),
    downsample: [4]u32 = @splat(1),
    last_pass: [4]u32 = @splat(0),

    fn read(br: *BitReader) Error!Passes {
        var p: Passes = .{};
        p.num = try br.u32Dist(.{ .v(1), .v(2), .v(3), .bo(3, 4) });
        if (p.num == 1) return p;
        p.num_ds = try br.u32Dist(.{ .v(0), .v(1), .v(2), .bo(1, 3) });
        if (p.num_ds > p.num) return error.BadHeader;
        for (p.shift[0 .. p.num - 1]) |*s| s.* = try br.bits(2);
        for (0..p.num_ds) |i| {
            p.downsample[i] = try br.u32Dist(.{ .v(1), .v(2), .v(4), .v(8) });
            if (i > 0 and p.downsample[i] >= p.downsample[i - 1]) return error.BadHeader;
        }
        for (0..p.num_ds) |i| {
            p.last_pass[i] = try br.u32Dist(.{ .v(0), .v(1), .v(2), .b(3) });
            if (i > 0 and p.last_pass[i] <= p.last_pass[i - 1]) return error.BadHeader;
            if (p.last_pass[i] >= p.num) return error.BadHeader;
        }
        return p;
    }
};

pub const RestorationFilter = struct {
    gab: bool = true,
    /// Gaborish weights for X, Y, B: the side and the diagonal neighbours.
    gab_weights: [3][2]f32 = @splat(.{ 1.1 * 0.104699568, 1.1 * 0.055680538 }),
    epf_iters: u32 = 2,
    epf_sharp_lut: [8]f32 = .{ 0.0 / 7.0, 1.0 / 7.0, 2.0 / 7.0, 3.0 / 7.0, 4.0 / 7.0, 5.0 / 7.0, 6.0 / 7.0, 7.0 / 7.0 },
    epf_channel_scale: [3]f32 = .{ 40, 5, 3.5 },
    epf_pass1_zeroflush: f32 = 0.45,
    epf_pass2_zeroflush: f32 = 0.6,
    epf_quant_mul: f32 = 0.46,
    epf_pass0_sigma_scale: f32 = 0.9,
    epf_pass2_sigma_scale: f32 = 6.5,
    epf_border_sad_mul: f32 = 2.0 / 3.0,
    epf_sigma_for_modular: f32 = 1,

    fn read(br: *BitReader, modular: bool) Error!RestorationFilter {
        var f: RestorationFilter = .{};
        if (try br.boolean()) return f;
        f.gab = try br.boolean();
        if (f.gab and try br.boolean()) {
            for (&f.gab_weights) |*w| {
                w[0] = try br.f16Field();
                w[1] = try br.f16Field();
                if (@abs(1 + (w[0] + w[1]) * 4) < 1e-8) return error.BadHeader;
            }
        }
        f.epf_iters = try br.bits(2);
        if (f.epf_iters > 0) {
            if (!modular and try br.boolean()) {
                for (&f.epf_sharp_lut) |*v| v.* = try br.f16Field();
            }
            if (try br.boolean()) {
                for (&f.epf_channel_scale) |*v| v.* = try br.f16Field();
                f.epf_pass1_zeroflush = try br.f16Field();
                f.epf_pass2_zeroflush = try br.f16Field();
            }
            if (try br.boolean()) {
                if (!modular) f.epf_quant_mul = try br.f16Field();
                f.epf_pass0_sigma_scale = try br.f16Field();
                f.epf_pass2_sigma_scale = try br.f16Field();
                f.epf_border_sad_mul = try br.f16Field();
            }
            if (modular) {
                f.epf_sigma_for_modular = try br.f16Field();
                if (f.epf_sigma_for_modular < 1e-8) return error.BadHeader;
            }
        }
        try readExtensions(br);
        return f;
    }
};

pub const flag_noise: u64 = 1;
pub const flag_patches: u64 = 2;
pub const flag_splines: u64 = 16;
pub const flag_use_lf_frame: u64 = 32;
pub const flag_skip_adaptive_lf_smoothing: u64 = 128;

pub const FrameHeader = struct {
    kind: FrameType = .regular,
    modular: bool = false,
    flags: u64 = 0,
    ycbcr: bool = false,
    /// Per channel (in JPEG order: Y, Cb, Cr... stored as read) the chroma
    /// subsampling mode, 0 to 3.
    chroma: [3]u32 = @splat(0),
    upsampling: u32 = 1,
    ec_upsampling: [max_extra_channels]u32 = @splat(1),
    group_size_shift: u32 = 1,
    x_qm_scale: u32 = 3,
    b_qm_scale: u32 = 2,
    passes: Passes = .{},
    lf_level: u32 = 0,
    have_crop: bool = false,
    x0: i32 = 0,
    y0: i32 = 0,
    /// The frame's size before upsampling is undone: the crop, or the
    /// image's (divided by 8 per LF level).
    width: u32 = 0,
    height: u32 = 0,
    blending: BlendingInfo = .{},
    ec_blending: [max_extra_channels]BlendingInfo = @splat(.{}),
    duration: u32 = 0,
    timecode: u32 = 0,
    is_last: bool = true,
    save_as_reference: u32 = 0,
    save_before_ct: bool = false,
    filter: RestorationFilter = .{},

    pub fn read(br: *BitReader, image: *const ImageHeader, preview: bool) Error!FrameHeader {
        var f: FrameHeader = .{};
        const default_w = if (preview) image.preview.?[0] else image.width;
        const default_h = if (preview) image.preview.?[1] else image.height;
        f.width = default_w;
        f.height = default_h;
        if (!image.xyb) f.x_qm_scale = 2;
        if (try br.boolean()) {
            if (image.xyb) {
                f.x_qm_scale = 3;
            }
            f.save_before_ct = false;
            return f;
        }
        f.kind = std.enums.fromInt(FrameType, try br.bits(2)) orelse unreachable;
        if (preview and f.kind != .regular) return error.BadHeader;
        f.modular = try br.boolean();
        f.flags = try br.u64Field();
        if (!image.xyb) f.ycbcr = try br.boolean();
        if (f.flags & flag_use_lf_frame == 0) {
            if (f.ycbcr) {
                for (&f.chroma) |*c| c.* = try br.bits(2);
            }
            f.upsampling = try br.u32Dist(.{ .v(1), .v(2), .v(4), .v(8) });
            for (0..image.num_ec) |i| {
                const shift = image.ec[i].dim_shift;
                const up = try br.u32Dist(.{ .v(1), .v(2), .v(4), .v(8) });
                f.ec_upsampling[i] = up << @intCast(shift);
                if (f.ec_upsampling[i] < f.upsampling or f.ec_upsampling[i] > 8) return error.BadHeader;
            }
        }
        if (f.modular) f.group_size_shift = try br.bits(2);
        if (!f.modular and image.xyb) {
            f.x_qm_scale = try br.bits(3);
            f.b_qm_scale = try br.bits(3);
        } else {
            f.x_qm_scale = 2;
            f.b_qm_scale = 2;
        }
        if (f.kind != .reference_only) f.passes = try .read(br);
        if (f.kind == .lf) f.lf_level = try br.u32Dist(.{ .v(1), .v(2), .v(3), .v(4) });
        var partial = false;
        if (f.kind != .lf) {
            f.have_crop = try br.boolean();
            if (f.have_crop) {
                const d: [4]Dist = .{ .b(8), .bo(11, 256), .bo(14, 2304), .bo(30, 18688) };
                if (f.kind == .regular or f.kind == .skip_progressive) {
                    f.x0 = unpackSigned(try br.u32Dist(d));
                    f.y0 = unpackSigned(try br.u32Dist(d));
                }
                f.width = try br.u32Dist(d);
                f.height = try br.u32Dist(d);
                if (f.width == 0 or f.height == 0) return error.BadHeader;
                if (f.kind == .regular or f.kind == .skip_progressive) {
                    partial = f.x0 > 0 or f.y0 > 0 or
                        @as(i64, f.width) + f.x0 < default_w or @as(i64, f.height) + f.y0 < default_h;
                }
            }
        }
        if (f.kind == .regular or f.kind == .skip_progressive) {
            f.blending = try .read(br, image.num_ec, partial);
            var replace_all = f.blending.mode == .replace;
            for (f.ec_blending[0..image.num_ec]) |*b| {
                b.* = try .read(br, image.num_ec, partial);
                replace_all = replace_all and b.mode == .replace;
            }
            if (preview and (!replace_all or f.have_crop)) return error.BadHeader;
            if (image.animation) |a| {
                f.duration = try br.u32Dist(.{ .v(0), .v(1), .b(8), .b(32) });
                if (a.have_timecodes) f.timecode = try br.bits(32);
            }
            f.is_last = try br.boolean();
        } else {
            f.is_last = false;
        }
        if (f.kind != .lf and !f.is_last) f.save_as_reference = try br.bits(2);
        if (f.kind != .lf) {
            const can_reference = !f.is_last and (f.duration == 0 or f.save_as_reference != 0);
            if (can_reference and f.blending.mode == .replace and !partial and
                (f.kind == .regular or f.kind == .skip_progressive))
            {
                f.save_before_ct = try br.boolean();
            } else if (f.kind == .reference_only) {
                f.save_before_ct = try br.boolean();
                if (!f.save_before_ct and (f.width < image.width or f.height < image.height or f.x0 != 0 or f.y0 != 0))
                    return error.BadHeader;
            }
        } else {
            f.save_before_ct = true;
        }
        try skipName(br);
        f.filter = try .read(br, f.modular);
        try readExtensions(br);
        if (f.lf_level != 0) {
            const shift: u5 = @intCast(3 * f.lf_level);
            f.width = @intCast((@as(u64, f.width) + (@as(u64, 1) << shift) - 1) >> shift);
            f.height = @intCast((@as(u64, f.height) + (@as(u64, 1) << shift) - 1) >> shift);
        }
        return f;
    }

    pub fn maxHShift(f: *const FrameHeader) u32 {
        var m: u32 = 0;
        for (f.chroma) |c| m = @max(m, chroma_h[c]);
        return m;
    }

    pub fn maxVShift(f: *const FrameHeader) u32 {
        var m: u32 = 0;
        for (f.chroma) |c| m = @max(m, chroma_v[c]);
        return m;
    }

    /// The horizontal and vertical subsampling shift of channel `c` (0 X
    /// or Cb, 1 Y, 2 B or Cr; the file stores Cb, Y, Cr order... see
    /// `chroma`).
    pub fn hShift(f: *const FrameHeader, c: usize) u32 {
        return f.maxHShift() - chroma_h[f.chroma[c]];
    }

    pub fn vShift(f: *const FrameHeader, c: usize) u32 {
        return f.maxVShift() - chroma_v[f.chroma[c]];
    }

    /// Whether this frame's colour channels are XYB after decoding.
    pub fn isLast(f: *const FrameHeader) bool {
        return f.is_last;
    }
};

pub const chroma_h = [4]u32{ 0, 1, 1, 0 };
pub const chroma_v = [4]u32{ 0, 1, 0, 1 };

/// A frame's layout: its size in pixels and blocks, and its groups.
pub const Dims = struct {
    /// The frame before upsampling: what the sections hold.
    width: u32,
    height: u32,
    /// After upsampling.
    width_up: u32,
    height_up: u32,
    xsize_blocks: u32,
    ysize_blocks: u32,
    group_dim: u32,
    xsize_groups: u32,
    ysize_groups: u32,
    xsize_lf_groups: u32,
    ysize_lf_groups: u32,
    num_groups: u32,
    num_lf_groups: u32,

    pub fn init(f: *const FrameHeader) Dims {
        const up = f.upsampling;
        const w = std.math.divCeil(u32, f.width, up) catch unreachable;
        const h = std.math.divCeil(u32, f.height, up) catch unreachable;
        const hs: u5 = @intCast(f.maxHShift());
        const vs: u5 = @intCast(f.maxVShift());
        const gd: u32 = @as(u32, 128) << @intCast(f.group_size_shift);
        const xb = ((std.math.divCeil(u64, w, @as(u64, 8) << hs) catch unreachable) << hs);
        const yb = ((std.math.divCeil(u64, h, @as(u64, 8) << vs) catch unreachable) << vs);
        const xg = std.math.divCeil(u32, w, gd) catch unreachable;
        const yg = std.math.divCeil(u32, h, gd) catch unreachable;
        const xlg: u32 = @intCast(std.math.divCeil(u64, xb, gd) catch unreachable);
        const ylg: u32 = @intCast(std.math.divCeil(u64, yb, gd) catch unreachable);
        return .{
            .width = w,
            .height = h,
            .width_up = f.width,
            .height_up = f.height,
            .xsize_blocks = @intCast(xb),
            .ysize_blocks = @intCast(yb),
            .group_dim = gd,
            .xsize_groups = xg,
            .ysize_groups = yg,
            .xsize_lf_groups = xlg,
            .ysize_lf_groups = ylg,
            // Saturated: a frame this large fails its size check before
            // any section is read.
            .num_groups = xg *| yg,
            .num_lf_groups = xlg *| ylg,
        };
    }
};

test "size header" {
    // small, height (3+1)*8 = 32, ratio 1: 32x32.
    var r: std.Io.Reader = .fixed(&.{ 0xff, 0x0a, 0x47, 0 });
    var br: BitReader = .init(&r, null);
    _ = try br.bits(16);
    const s = try readSize(&br);
    try testing.expectEqual(@as(u32, 32), s[0]);
    try testing.expectEqual(@as(u32, 32), s[1]);
}

test "unpack signed" {
    try testing.expectEqual(@as(i32, 0), unpackSigned(0));
    try testing.expectEqual(@as(i32, -1), unpackSigned(1));
    try testing.expectEqual(@as(i32, 1), unpackSigned(2));
    try testing.expectEqual(@as(i32, -2147483648), unpackSigned(0xffff_ffff));
}
