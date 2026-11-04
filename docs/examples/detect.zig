const std = @import("std");
const image = @import("image");

const testing = std.testing;

test "name a file's format" {
    const prefix = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
    try testing.expectEqual(image.Format.png, image.detect(prefix).?);
    try testing.expectEqual(null, image.detect("plain text, not an image"));

    // CUR files decode through the ICO namespace.
    try testing.expectEqualStrings("ico", image.Format.cur.namespace());
    try testing.expect(image.Decoder.supports(.jxl));
}

test "decode any format" {
    // A 1 by 1 QOI file. `initDetect` peeks at the first bytes and leaves
    // them in the reader for the format's decoder.
    const file = "qoif\x00\x00\x00\x01\x00\x00\x00\x01\x04\x00\xfe\x01\x02\x03" ++ @as([7]u8, @splat(0)) ++ "\x01";
    var reader: std.Io.Reader = .fixed(file);
    var decoder: image.Decoder = try .initDetect(&reader, .{});
    try testing.expectEqual(image.Format.qoi, decoder.format());

    const config = try decoder.decodeConfig();
    var pixel: [4]u8 = undefined;
    const dst = try image.PixelBuffer.init(&pixel, .rgba8, config.width, config.height);
    _ = (try decoder.decodeFrame(dst, &.{})).?;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &pixel);
}
