//! The conversion rows: `image.convert` over a buffer of raw pixels.

const image = @import("image");
const PixelFormat = image.PixelFormat;

pub const ops = .{
    .{ "convert-rgba8-bgra8", Convert(.rgba8, .bgra8).run },
    .{ "convert-rgb8-rgba8", Convert(.rgb8, .rgba8).run },
    .{ "convert-rgba8-rgb8", Convert(.rgba8, .rgb8).run },
    .{ "convert-rgba8-premul", Convert(.rgba8, .rgba8_premul).run },
    .{ "convert-gray8-rgba8", Convert(.gray8, .rgba8).run },
    .{ "convert-rgba16-rgba8", Convert(.rgba16, .rgba8).run },
};

fn Convert(comptime src: PixelFormat, comptime dst: PixelFormat) type {
    return struct {
        fn run(in: []const u8, out: []u8) ?usize {
            const n = in.len / src.bytesPerPixel();
            if (n * dst.bytesPerPixel() > out.len) return null;
            image.convert.convert(out, dst, in, src, n);
            return n * dst.bytesPerPixel();
        }
    };
}
