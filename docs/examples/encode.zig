const std = @import("std");
const image = @import("image");

const testing = std.testing;

test "encode a PNG" {
    const gpa = testing.allocator;
    var pixels: [64 * 32 * 4]u8 = undefined;
    for (0..64 * 32) |i| pixels[i * 4 ..][0..4].* = .{ @truncate(i), @truncate(i >> 4), 128, 255 };
    const src = try image.PixelBuffer.init(&pixels, .rgba8, 64, 32);

    const options: image.png.EncodeOptions = .{ .effort = .best };
    const work = try gpa.alloc(u8, image.png.workLen(options, 64, 32) orelse return error.ImageTooLarge);
    defer gpa.free(work);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try image.png.encode(&out.writer, src, options, work);

    try testing.expect(std.mem.startsWith(u8, out.written(), "\x89PNG"));
}

test "encode a JPEG" {
    const gpa = testing.allocator;
    var pixels: [64 * 64 * 3]u8 = undefined;
    for (0..64 * 64) |i| pixels[i * 3 ..][0..3].* = .{ @truncate(i), 90, @truncate(i >> 6) };
    const src = try image.PixelBuffer.init(&pixels, .rgb8, 64, 64);

    const options: image.jpeg.EncodeOptions = .{ .quality = 90, .progressive = true };
    const work = try gpa.alloc(u8, image.jpeg.workLen(options, 64, 64).?);
    defer gpa.free(work);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try image.jpeg.encode(&out.writer, src, options, work);

    try testing.expectEqual(image.Format.jpeg, image.detect(out.written()).?);
}

test "every encoder has the same shape" {
    const gpa = testing.allocator;
    var pixels: [32 * 16 * 4]u8 = undefined;
    for (0..32 * 16) |i| pixels[i * 4 ..][0..4].* = .{ @truncate(i * 7), @truncate(i), 0, 255 };
    const src = try image.PixelBuffer.init(&pixels, .rgba8, 32, 16);

    const formats = .{
        image.png, image.jpeg, image.gif, image.webp,   image.tiff, image.jxl,
        image.bmp, image.ico,  image.tga, image.netpbm, image.wbmp, image.qoi,
    };
    inline for (formats) |format| {
        const work = try gpa.alloc(u8, format.workLen(.{}, 32, 16).?);
        defer gpa.free(work);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try format.encode(&out.writer, src, .{}, work);

        // Every file decodes again at the same size.
        var reader: std.Io.Reader = .fixed(out.written());
        var decoder: image.Decoder = try .initDetect(&reader, .{});
        const config = try decoder.decodeConfig();
        try testing.expectEqual(.{ 32, 16 }, .{ config.width, config.height });
    }
}
