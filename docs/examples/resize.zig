const std = @import("std");
const image = @import("image");

const testing = std.testing;

test "resize an image" {
    // A 4 by 4 gray glyph, shrunk to 2 by 2 with the default filter.
    const glyph = [_]u8{
        0, 0,   0,   0,
        0, 255, 255, 0,
        0, 255, 255, 0,
        0, 0,   0,   0,
    };
    const src: image.PixelBuffer = try .init(@constCast(&glyph), .gray8, 4, 4);
    var out: [2 * 2]u8 = undefined;
    const dst: image.PixelBuffer = try .init(&out, .gray8, 2, 2);

    const options: image.resize.Options = .{};
    var work: [4096]u8 = undefined;
    const len = image.resize.workLen(.gray8, 2, 2, .gray8, 4, 4, options) orelse return error.ImageTooLarge;
    try image.resize.resize(dst, src, work[0..len], options);
    // A quarter of each pixel's area is lit, and Mitchell's negative lobes
    // fall on the dark border: a little over a quarter of 255.
    try testing.expectEqualSlices(u8, &.{ 69, 69, 69, 69 }, &out);
}

test "resize and convert" {
    // Straight-alpha RGBA in, premultiplied BGRA twice the size out: the
    // source is premultiplied before it is filtered.
    const src_pixels = [_]u8{ 255, 0, 0, 255, 255, 0, 0, 0 };
    const src: image.PixelBuffer = try .init(@constCast(&src_pixels), .rgba8, 2, 1);
    var out: [4 * 2 * 4]u8 = undefined;
    const dst: image.PixelBuffer = try .init(&out, .bgra8_premul, 4, 2);
    const options: image.resize.Options = .{ .filter = .triangle };
    var work: [4096]u8 = undefined;
    const len = image.resize.workLen(.bgra8_premul, 4, 2, .rgba8, 2, 1, options).?;
    try image.resize.resize(dst, src, work[0..len], options);
    // Red fades out to the right, and no color comes from the clear pixel.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 0, 191, 191, 0, 0, 64, 64, 0, 0, 0, 0 }, out[0..16]);
}

test "resize a row at a time" {
    // Rows go in as they arrive and come out as soon as the rows they
    // read are in; the work memory holds a few rows, not the image.
    const sw = 8;
    const sh = 8;
    const options: image.resize.Options = .{};
    var work: [8192]u8 = undefined;
    const len = image.resize.workLen(.rgb8, 3, 3, .rgb8, sw, sh, options).?;
    var resizer: image.resize.Resizer = try .init(.rgb8, 3, 3, .rgb8, sw, sh, options, work[0..len]);
    var row: [sw * 3]u8 = undefined;
    var out: [3][3 * 3]u8 = undefined;
    var taken: usize = 0;
    for (0..sh) |y| {
        @memset(&row, @intCast(y * 32));
        try resizer.push(&row);
        while (taken < out.len and resizer.take(&out[taken])) taken += 1;
    }
    try testing.expectEqual(3, taken);
}
