//! image.resize against stb_image_resize2 2.18 (test/oracle/resize.c),
//! with the same filter, edge mode, colorspace, and alpha handling, on the
//! requests test/fuzz/resize.zig generates: the source is made in each
//! pixel format below from the request's bytes, and both resize it to the
//! request's size in that format. And its defaults against stb_image_resize
//! 0.97's `stbir_resize_uint8` (`stb097`, test/oracle/resize_stb097.c), the
//! call rockorager/monstar makes.
//!
//! The tolerances are stb's rounding, not ours. Both filter in `f32`, but
//! stb computes its sample positions and kernels in `f32`, and a position
//! near 1000 is only good to 6e-5 of a pixel there: on 20,000 one-row
//! resizes of 1 to 1024 pixels its results are within 6.5e-5 of an exact
//! sum, where ours are within 3e-7 (our weights are computed in `f64`). So
//! formats filtered as stored compare within 1 step at 8 bits, where 6.5e-5
//! is a fiftieth of a step and only moves a value lying on a rounding
//! boundary, and within 8 steps of 1/65535 at 16 bits and in floats, where
//! the two passes' 6.5e-5 each come to 8.5 steps (the most seen in 3,000
//! requests was 5).
//!
//! 8-bit formats filtered as stored that shrink vertically, from rows of 64
//! bytes, take the vertical pass in integers: each row's weights scaled by
//! 2^p, the largest power of two that keeps them within 16 bits and their
//! sums of 8-bit samples within 32 (at least 2^14 over the largest weight,
//! or 2^22), and rounded cumulatively, so that every partial sum is within
//! half a unit. A result then moves by at most half a unit for each step
//! between neighbouring taps' samples, T taps' 255 at worst, which with T
//! times the largest weight at most 8 for these filters is under a tenth
//! of a step. So the tolerance stays 1 step: of 828 million samples in 12,000
//! requests, 0.13% differ by 1 from the same resize in floats and none by
//! more, and on the 5,000 requests the oracle run takes with seed 1, 2,318
//! need the step against stb_image_resize2 where 2,195 did in floats, and
//! 1,252 against 0.97 where 953 did.
//!
//! Straight alpha (`alpha`, `alpha_wide`) is compared on sources whose
//! alpha is at least half (test/fuzz/resize.zig): dividing by a filtered
//! alpha near 0 magnifies stb's rounding past any bound, and a pixel whose
//! alpha rounds to 0 on one side and to 1 on the other is black on one and
//! colored on the other. Transparent pixels in straight-alpha formats are
//! covered by the unit tests and the fuzz target, and the premultiplied
//! formats above take any alpha.

const std = @import("std");
const image = @import("image");
const PixelFormat = image.PixelFormat;
const request = @import("fuzz").resize;
const adaptRequest = adapt;

pub const name = "resize";
pub const Decoder = request.Decoder(.plain);
pub const fuzz = request;
pub const oracles = [_][]const u8{"resize-stbir2"};
/// Every 8-bit layout filtered as stored.
pub const formats = [_]PixelFormat{ .gray8, .gray_alpha8_premul, .rgb8, .bgr8, .rgba8_premul, .bgra8_premul, .cmyk8 };
pub const tolerance: u16 = 1;

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}

/// 16-bit and float samples filtered as stored.
pub const wide = struct {
    pub const name = "resize_wide";
    pub const Decoder = request.Decoder(.plain);
    pub const fuzz = request;
    pub const oracles = [_][]const u8{"resize-stbir2"};
    pub const formats = [_]PixelFormat{ .gray16, .rgba16_premul, .cmyk16, .rgba_f32_premul, .rgb_f32, .gray_f32 };
    pub const tolerance: u16 = 8;
    pub const adapt = adaptRequest;
};

/// Straight 8-bit alpha, premultiplied before filtering and
/// unpremultiplied after, alpha from half to opaque.
pub const alpha = struct {
    pub const name = "resize_alpha";
    pub const Decoder = request.Decoder(.high_alpha);
    pub const fuzz = request;
    pub const oracles = [_][]const u8{"resize-stbir2-alpha"};
    pub const formats = [_]PixelFormat{ .gray_alpha8, .rgba8, .bgra8 };
    pub const tolerance: u16 = 1;
    pub const adapt = adaptRequest;
};

/// Straight 16-bit and float alpha, alpha from half to opaque: dividing by
/// it at most doubles the 8 steps above.
pub const alpha_wide = struct {
    pub const name = "resize_alpha_wide";
    pub const Decoder = request.Decoder(.high_alpha);
    pub const fuzz = request;
    pub const oracles = [_][]const u8{"resize-stbir2-alpha"};
    pub const formats = [_]PixelFormat{ .gray_alpha16, .rgba16, .bgra16, .rgba_f32 };
    pub const tolerance: u16 = 16;
    pub const adapt = adaptRequest;
};

/// monstar's two calls: `stbir_resize_uint8` on gray8 coverage and
/// premultiplied BGRA, whatever the request's options. An axis that keeps
/// its size is left out: 0.97 filters it with Mitchell, which blurs it
/// (up to 30 steps on one-pixel detail), where image.resize's default and
/// stb_image_resize2 take Catmull-Rom, which leaves it as it is. Of 22,210
/// comparisons of the rest, none differed by more than 1.
pub const stb097 = struct {
    pub const name = "resize_stb097";
    pub const Decoder = request.Decoder(.defaults);
    pub const fuzz = request;
    pub const oracles = [_][]const u8{"resize-stbir097"};
    pub const formats = [_]PixelFormat{ .gray8, .bgra8_premul };
    pub const tolerance: u16 = 1;
    pub const adapt = adaptRequest;

    pub fn comparable(op: []const u8, format: PixelFormat, input: []const u8) bool {
        _ = op;
        _ = format;
        const req = request.Request.parse(input) orelse return true;
        return req.src_width != req.dst_width and req.src_height != req.dst_height;
    }
};
