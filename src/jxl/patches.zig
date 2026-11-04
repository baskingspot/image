//! Patches (ISO/IEC 18181-1, the patch dictionary): rectangles copied
//! from a reference frame saved before its color transform, each placed
//! at one or more positions in the frame and blended there by its own
//! mode per channel.

const std = @import("std");

const Arena = @import("Arena.zig");
const BitReader = @import("BitReader.zig");
const entropy = @import("entropy.zig");
const headers = @import("headers.zig");

pub const Error = entropy.Error || error{BadImage};

/// A reference slot as patches read it: three color planes then the
/// extra channels, `w` by `h`, rows of `w`.
pub const Source = struct {
    planes: []const []const f32,
    w: usize,
    h: usize,
};

const Mode = enum(u8) {
    none,
    replace,
    add,
    mul,
    blend_above,
    blend_below,
    alpha_weighted_add_above,
    alpha_weighted_add_below,

    fn usesAlpha(m: Mode) bool {
        return switch (m) {
            .blend_above, .blend_below, .alpha_weighted_add_above, .alpha_weighted_add_below => true,
            else => false,
        };
    }
};

const Blending = struct { mode: Mode, alpha: u8, clamp: bool };

const Ref = struct { slot: u8, x0: u32, y0: u32, w: u32, h: u32 };

const Position = struct { x: u32, y: u32, ref: u32 };

pub const Dictionary = struct {
    refs: []Ref,
    positions: []Position,
    /// `num_ec + 1` per position: the colors', then each extra channel's.
    blendings: []Blending,
    stride: usize,
};

const ctx_num_refs = 0;
const ctx_ref_frame = 1;
const ctx_size = 2;
const ctx_ref_position = 3;
const ctx_position = 4;
const ctx_blend_mode = 5;
const ctx_offset = 6;
const ctx_count = 7;
const ctx_alpha = 8;
const ctx_clamp = 9;
const num_contexts = 10;

/// The most patches a dictionary may hold in work memory, for a frame of
/// `px` padded pixels (docs/slop/jxl.md, work memory).
pub fn budget(px: u64) u64 {
    return (1 << 16) + px / 16;
}

/// The bytes `budget(px)` patches take with `num_ec` extra channels.
pub fn budgetBytes(px: u64, num_ec: u32) u64 {
    const n = budget(px);
    return n * (@sizeOf(Position) + @sizeOf(Ref) + (num_ec + 1) * @sizeOf(Blending)) + 4096;
}

/// Reads the dictionary for a frame of `xsize` by `ysize` (padded)
/// pixels, whose patches may come from `refs`.
pub fn read(
    br: *BitReader,
    arena: *Arena,
    xsize: u64,
    ysize: u64,
    image: *const headers.ImageHeader,
    refs: *const [4]?Source,
) Error!Dictionary {
    const num_ec = image.num_ec;
    const code = try entropy.Code.read(br, arena, num_contexts);
    var r: entropy.Reader = try .init(&code, br, arena, 0, entropy.window_size);
    const px = xsize * ysize;
    const max_refs = 1024 + px / 4;
    const max_patches = @min(max_refs * 4, budget(px));
    const num_refs = try r.read(br, ctx_num_refs);
    if (num_refs > max_refs) return error.BadImage;
    if (num_refs > max_patches) return error.TooComplex;
    const stride = num_ec + 1;
    const ref_list = try arena.alloc(Ref, num_refs);
    // The positions and blendings take the rest of their budget, and give
    // back what they do not use only with the arena.
    const positions = try arena.alloc(Position, max_patches);
    const blendings = try arena.alloc(Blending, max_patches * stride);
    var total: usize = 0;
    for (ref_list, 0..) |*ref, id| {
        const slot = try r.read(br, ctx_ref_frame);
        if (slot >= 4) return error.BadImage;
        const src = refs[slot] orelse return error.BadImage;
        ref.* = .{
            .slot = @intCast(slot),
            .x0 = try r.read(br, ctx_ref_position),
            .y0 = try r.read(br, ctx_ref_position),
            .w = (try r.read(br, ctx_size)) +| 1,
            .h = (try r.read(br, ctx_size)) +| 1,
        };
        if (@as(u64, ref.x0) + ref.w > src.w or @as(u64, ref.y0) + ref.h > src.h) return error.BadImage;
        const count = @as(u64, try r.read(br, ctx_count)) + 1;
        if (total + count > max_refs * 4) return error.BadImage;
        if (total + count > max_patches) return error.TooComplex;
        for (0..count) |i| {
            var pos: Position = .{ .x = 0, .y = 0, .ref = @intCast(id) };
            if (i == 0) {
                pos.x = try r.read(br, ctx_position);
                pos.y = try r.read(br, ctx_position);
            } else {
                const prev = positions[total - 1];
                pos.x = try offset(prev.x, try r.read(br, ctx_offset));
                pos.y = try offset(prev.y, try r.read(br, ctx_offset));
            }
            if (@as(u64, pos.x) + ref.w > xsize or @as(u64, pos.y) + ref.h > ysize) return error.BadImage;
            for (blendings[total * stride ..][0..stride]) |*b| {
                const mode = try r.read(br, ctx_blend_mode);
                if (mode >= 8) return error.BadImage;
                b.* = .{ .mode = @fromBackingInt(@intCast(mode)), .alpha = 0, .clamp = false };
                if (b.mode.usesAlpha() and num_ec > 1) {
                    const a = try r.read(br, ctx_alpha);
                    if (a >= num_ec) return error.BadImage;
                    b.alpha = @intCast(a);
                }
                if (b.mode.usesAlpha() or b.mode == .mul) b.clamp = try r.read(br, ctx_clamp) != 0;
            }
            positions[total] = pos;
            total += 1;
        }
    }
    if (!r.finalOk()) return error.BadEntropy;
    return .{
        .refs = ref_list,
        .positions = positions[0..total],
        .blendings = blendings[0 .. total * stride],
        .stride = stride,
    };
}

fn offset(base: u32, packed_delta: u32) Error!u32 {
    const mag: i64 = packed_delta >> 1;
    const delta: i64 = if (packed_delta & 1 == 1) -mag - 1 else mag;
    const v = @as(i64, base) + delta;
    if (v < 0 or v > std.math.maxInt(u32)) return error.BadImage;
    return @intCast(v);
}

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

/// Blends every patch, in order, into rows `y0 .. y1` of a frame `w` by
/// `h`, which `planes` holds from row `y0` (three colors, rows of
/// `stride`, then the extra channels, rows of `ec_stride`). Each pixel
/// takes the patches that cover it in the same order, whatever the rows.
pub fn apply(
    dict: *const Dictionary,
    image: *const headers.ImageHeader,
    refs: *const [4]?Source,
    planes: []const []f32,
    stride: usize,
    ec_stride: usize,
    w: usize,
    h: usize,
    y0: usize,
    y1: usize,
) void {
    const ne = image.num_ec;
    var has_alpha = false;
    for (image.ec[0..ne]) |e| has_alpha = has_alpha or e.kind == .alpha;
    for (dict.positions, 0..) |pos, pi| {
        const ref = dict.refs[pos.ref];
        const src = refs[ref.slot].?;
        const bl = dict.blendings[pi * dict.stride ..][0..dict.stride];
        const x1 = @min(w, @as(usize, pos.x) + ref.w);
        const py1 = @min(@min(h, y1), @as(usize, pos.y) + ref.h);
        if (pos.x >= x1) continue;
        var y: usize = @max(pos.y, y0);
        while (y < py1) : (y += 1) {
            const sy = ref.y0 + (y - pos.y);
            const at = y - y0;
            for (pos.x..x1) |x| {
                const sx = ref.x0 + (x - pos.x);
                var bg: [3 + headers.max_extra_channels]f32 = undefined;
                var fg: [3 + headers.max_extra_channels]f32 = undefined;
                for (0..3 + ne) |c| {
                    bg[c] = planes[c][at * (if (c < 3) stride else ec_stride) + x];
                    fg[c] = src.planes[c][sy * src.w + sx];
                }
                var out = bg;
                blendPixel(image, bl, has_alpha, &bg, &fg, &out);
                for (0..3 + ne) |c| planes[c][at * (if (c < 3) stride else ec_stride) + x] = out[c];
            }
        }
    }
}

/// One pixel of the reference's blending of a patch: the extra channels
/// first, by the alpha before blending, then the colors, which blending
/// by alpha also set that alpha. "Below" swaps the patch and the image.
fn blendPixel(
    image: *const headers.ImageHeader,
    bl: []const Blending,
    has_alpha: bool,
    bg: []const f32,
    fg: []const f32,
    out: []f32,
) void {
    const ne = image.num_ec;
    for (0..ne) |i| {
        const b = bl[1 + i];
        const c = 3 + i;
        const a = 3 + @as(usize, b.alpha);
        const below = b.mode == .blend_below or b.mode == .alpha_weighted_add_below;
        const lo = if (below) fg else bg;
        const hi = if (below) bg else fg;
        out[c] = switch (b.mode) {
            .none => bg[c],
            .replace => fg[c],
            .add => bg[c] + fg[c],
            .mul => bg[c] * (if (b.clamp) clamp01(fg[c]) else fg[c]),
            .blend_above, .blend_below => blk: {
                const fa = if (b.clamp) clamp01(hi[a]) else hi[a];
                if (c == a) break :blk 1 - (1 - fa) * (1 - lo[a]);
                if (image.ec[b.alpha].alpha_associated) break :blk hi[c] + lo[c] * (1 - fa);
                const new_a = 1 - (1 - fa) * (1 - lo[a]);
                const rnew: f32 = if (new_a > 0) 1 / new_a else 0;
                break :blk (hi[c] * fa + lo[c] * lo[a] * (1 - fa)) * rnew;
            },
            .alpha_weighted_add_above, .alpha_weighted_add_below => blk: {
                if (c == a) break :blk lo[c];
                break :blk lo[c] + hi[c] * (if (b.clamp) clamp01(hi[a]) else hi[a]);
            },
        };
    }
    const b = bl[0];
    const a = 3 + @as(usize, b.alpha);
    const below = b.mode == .blend_below or b.mode == .alpha_weighted_add_below;
    const lo = if (below) fg else bg;
    const hi = if (below) bg else fg;
    switch (b.mode) {
        .none => for (0..3) |c| {
            out[c] = bg[c];
        },
        .replace => for (0..3) |c| {
            out[c] = fg[c];
        },
        .add => for (0..3) |c| {
            out[c] = bg[c] + fg[c];
        },
        .mul => for (0..3) |c| {
            out[c] = bg[c] * (if (b.clamp) clamp01(fg[c]) else fg[c]);
        },
        .alpha_weighted_add_above, .alpha_weighted_add_below => for (0..3) |c| {
            out[c] = if (has_alpha) lo[c] + hi[c] * (if (b.clamp) clamp01(hi[a]) else hi[a]) else bg[c] + fg[c];
        },
        .blend_above, .blend_below => {
            if (!has_alpha) {
                for (0..3) |c| out[c] = fg[c];
                return;
            }
            const fa = if (b.clamp) clamp01(hi[a]) else hi[a];
            if (image.ec[b.alpha].alpha_associated) {
                for (0..3) |c| out[c] = hi[c] + lo[c] * (1 - fa);
            } else {
                const new_a = 1 - (1 - fa) * (1 - lo[a]);
                const rnew: f32 = if (new_a > 0) 1 / new_a else 0;
                for (0..3) |c| out[c] = (hi[c] * fa + lo[c] * lo[a] * (1 - fa)) * rnew;
            }
            out[a] = 1 - (1 - fa) * (1 - lo[a]);
        },
    }
}
