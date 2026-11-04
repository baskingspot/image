const std = @import("std");
const image = @import("image");

const testing = std.testing;

/// An image's pixels as RGBA8, owned by the caller.
pub const Rgba = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

/// Decodes the first frame of the file at `path` to RGBA8, in any format
/// this build reads.
pub fn decodeFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Rgba {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);

    // The seeker lets ICO and TIFF reach data behind the reader.
    var decoder: image.Decoder = try .initDetect(&reader.interface, .{ .seeker = .file(&reader) });
    const config = try decoder.decodeConfig();

    const len = image.PixelBuffer.len(.rgba8, config.width, config.height) orelse
        return error.ImageTooLarge;
    const pixels = try gpa.alloc(u8, len);
    errdefer gpa.free(pixels);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);

    const dst = try image.PixelBuffer.init(pixels, .rgba8, config.width, config.height);
    _ = try decoder.decodeFrame(dst, work) orelse return error.NoFrames;
    return .{ .pixels = pixels, .width = config.width, .height = config.height };
}

test "decode a file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try squarePng(gpa);
    defer gpa.free(file);
    try tmp.dir.writeFile(io, .{ .sub_path = "square.png", .data = file });

    const rgba = try decodeFile(gpa, io, tmp.dir, "square.png");
    defer gpa.free(rgba.pixels);
    try testing.expectEqual(.{ 16, 16 }, .{ rgba.width, rgba.height });
    try testing.expectEqualSlices(u8, &.{ 200, 40, 10, 255 }, rgba.pixels[0..4]);
}

test "refuse an image over a limit" {
    const gpa = testing.allocator;
    const file = try squarePng(gpa);
    defer gpa.free(file);

    var reader: std.Io.Reader = .fixed(file);
    var decoder: image.png.Decoder = .init(&reader, .{ .limits = .{ .max_pixels = 100 } });
    try testing.expectError(error.ImageTooLarge, decoder.decodeConfig());
    // Errors are sticky: every later call returns the same one.
    try testing.expectError(error.ImageTooLarge, decoder.decodeConfig());
}

test "play an animation" {
    const gpa = testing.allocator;
    const file = try blinkingApng(gpa);
    defer gpa.free(file);

    var reader: std.Io.Reader = .fixed(file);
    var decoder: image.png.Decoder = .init(&reader, .{});
    const config = try decoder.decodeConfig();
    const len = image.PixelBuffer.len(.rgba8, config.width, config.height).?;
    const canvas = try gpa.alloc(u8, len);
    defer gpa.free(canvas);
    const saved = try gpa.alloc(u8, len);
    defer gpa.free(saved);
    const work = try gpa.alloc(u8, config.work_len);
    defer gpa.free(work);
    const dst = try image.PixelBuffer.init(canvas, .rgba8, config.width, config.height);

    var shown: u32 = 0;
    while (try decoder.decodeFrameConfig()) |next| {
        // Restoring to the previous canvas needs a copy made before the
        // frame is drawn.
        if (next.disposal == .previous) @memcpy(saved, canvas);
        const frame = (try decoder.decodeFrame(dst, work)).?;
        shown += 1; // Show `canvas` for `frame.duration` flicks here.
        switch (frame.disposal) {
            .none => {},
            .background => {
                const region = dst.sub(frame.x, frame.y, frame.width, frame.height);
                for (0..region.height) |y| @memset(region.row(@intCast(y)), 0);
            },
            .previous => @memcpy(canvas, saved),
        }
    }
    try testing.expectEqual(2, shown);
    try testing.expectEqual(null, try decoder.decodeFrame(dst, work));
}

/// A 16 by 16 PNG of one color.
fn squarePng(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [16 * 16 * 3]u8 = undefined;
    for (0..16 * 16) |i| pixels[i * 3 ..][0..3].* = .{ 200, 40, 10 };
    const src = try image.PixelBuffer.init(&pixels, .rgb8, 16, 16);
    const work = try gpa.alloc(u8, image.png.workLen(.{}, 16, 16).?);
    defer gpa.free(work);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try image.png.encode(&out.writer, src, .{}, work);
    return out.toOwnedSlice();
}

/// A two-frame APNG whose second frame is a 2 by 2 dot, cleared after it
/// is shown.
fn blinkingApng(gpa: std.mem.Allocator) ![]u8 {
    var full: [8 * 8 * 4]u8 = @splat(255);
    var dot: [2 * 2 * 4]u8 = @splat(0);
    for (0..4) |i| dot[i * 4 + 3] = 255;
    const frames = [_]image.png.AnimationFrame{
        .{ .pixels = try .init(&full, .rgba8, 8, 8), .duration = image.flicks_per_second / 2 },
        .{
            .pixels = try .init(&dot, .rgba8, 2, 2),
            .x = 3,
            .y = 3,
            .duration = image.flicks_per_second / 2,
            .disposal = .background,
        },
    };
    const work = try gpa.alloc(u8, image.png.workLen(.{}, 8, 8).?);
    defer gpa.free(work);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try image.png.encodeAnimation(&out.writer, 8, 8, &frames, .{}, work);
    return out.toOwnedSlice();
}
