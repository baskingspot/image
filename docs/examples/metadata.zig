const std = @import("std");
const image = @import("image");

const testing = std.testing;

/// Keeps the EXIF blob a decoder passes to its `BlobSink`, piece by piece.
const ExifCollector = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn sink(c: *ExifCollector) image.BlobSink {
        return .{ .context = c, .write = write };
    }

    fn write(context: *anyopaque, blob: image.Blob, at: u64, bytes: []const u8) void {
        const c: *ExifCollector = @ptrCast(@alignCast(context));
        if (blob.kind != .exif or blob.encoding != .raw) return;
        if (at + bytes.len > c.bytes.len) return;
        @memcpy(c.bytes[@intCast(at)..][0..bytes.len], bytes);
        c.len = @max(c.len, @as(usize, @intCast(at)) + bytes.len);
    }
};

test "collect EXIF and read the orientation" {
    const gpa = testing.allocator;
    const file = try photoPng(gpa);
    defer gpa.free(file);

    var exif: ExifCollector = .{};
    var reader: std.Io.Reader = .fixed(file);
    var decoder: image.Decoder = try .initDetect(&reader, .{ .blob_sink = exif.sink() });
    const config = try decoder.decodeConfig();

    // The decoder reads the orientation; the bytes are the caller's to keep.
    try testing.expectEqual(image.Orientation.right_top, config.metadata.orientation);
    try testing.expectEqual(image.Orientation.right_top, image.exif.orientation(exif.bytes[0..exif.len]).?);
    try testing.expectEqual(exif.len, config.metadata.exif.?.len.?);

    // Metadata after the frames arrives in `finalConfig` once the last
    // `decodeFrame` has returned null.
    var pixels: [4 * 2 * 4]u8 = undefined;
    const dst = try image.PixelBuffer.init(&pixels, .rgba8, config.width, config.height);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    while (try decoder.decodeFrame(dst, work)) |_| {}
    try testing.expectEqual(image.Orientation.right_top, decoder.finalConfig().?.metadata.orientation);
}

/// A 4 by 2 PNG with an EXIF orientation of 6: rotate 90° clockwise to show.
fn photoPng(gpa: std.mem.Allocator) ![]u8 {
    const exif = "MM\x00*\x00\x00\x00\x08" ++ "\x00\x01" ++
        "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00" ++ "\x00\x00\x00\x00";
    var pixels: [4 * 2 * 3]u8 = @splat(90);
    const src = try image.PixelBuffer.init(&pixels, .rgb8, 4, 2);
    const options: image.png.EncodeOptions = .{ .exif = exif };
    const work = try gpa.alloc(u8, image.png.workLen(options, 4, 2).?);
    defer gpa.free(work);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try image.png.encode(&out.writer, src, options, work);
    return out.toOwnedSlice();
}
