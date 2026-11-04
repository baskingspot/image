const std = @import("std");
const image = @import("image");

const testing = std.testing;

test "convert pixels" {
    // Two straight-alpha pixels: half-transparent red, opaque green.
    const src = [_]u8{ 255, 0, 0, 128, 0, 255, 0, 255 };
    var dst: [8]u8 = undefined;
    image.convert.convert(&dst, .bgra8_premul, &src, .rgba8, 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128, 0, 255, 0, 255 }, &dst);
}

test "convert many rows" {
    // Pick the kernel once, then run it on each row.
    const converter: image.convert.Converter = .init(.gray8, .rgb8);
    const rows = [_][6]u8{ .{ 255, 255, 255, 0, 0, 0 }, .{ 255, 0, 0, 0, 0, 255 } };
    var gray: [2][2]u8 = undefined;
    for (rows, &gray) |row, *out| converter.run(out, &row, 2);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 76, 29 }, std.mem.sliceAsBytes(&gray));
}

test "write into part of a larger buffer" {
    // A 4 by 2 RGBA8 canvas with 32 bytes between rows: room for 8 pixels,
    // of which 4 are the image.
    var memory: [64]u8 = @splat(0);
    const canvas = try image.PixelBuffer.initStride(&memory, .rgba8, 4, 2, 32);
    const right = canvas.sub(2, 0, 2, 2);

    var red: [2 * 2 * 3]u8 = undefined;
    for (0..4) |i| red[i * 3 ..][0..3].* = .{ 255, 0, 0 };
    try image.convert.convertBuffer(right, try .init(&red, .rgb8, 2, 2));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 255, 0, 0, 255 }, canvas.row(1)[4..12]);
}
