//! A decoder for any format this build supports: `initDetect` picks the
//! format from the input's first bytes, and the calls are the same as each
//! format's own `Decoder`. The formats come from the package root: a format
//! namespace there (`image.qoi`) with a `Decoder` is all this needs.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const image = @import("root.zig");
const decode = @import("decode.zig");
const detect = @import("detect.zig");
const Format = detect.Format;
const PixelBuffer = @import("pixel.zig").PixelBuffer;

const Decoder = @This();

/// Every supported format's errors, and `UnknownFormat` for input that
/// matches none.
pub const Error = blk: {
    var E = decode.Error || error{UnknownFormat};
    for (std.enums.values(Format)) |f| {
        if (supports(f)) E = E || Impl(f).Error;
    }
    break :blk E;
};

impl: Union,
/// The frames `decodeFrame` has returned, and whether it has returned null.
frames: u32 = 0,
done: bool = false,

/// One field per format; a format without a decoder in this build holds
/// `Missing` and is never active.
const Union = union(Format) {
    png: Impl(.png),
    jpeg: Impl(.jpeg),
    gif: Impl(.gif),
    webp: Impl(.webp),
    tiff: Impl(.tiff),
    jxl: Impl(.jxl),
    bmp: Impl(.bmp),
    ico: Impl(.ico),
    cur: Impl(.cur),
    tga: Impl(.tga),
    netpbm: Impl(.netpbm),
    wbmp: Impl(.wbmp),
    qoi: Impl(.qoi),
};

/// Whether this build decodes `format`.
pub fn supports(f: Format) bool {
    switch (f) {
        inline else => |tag| return comptime @hasDecl(image, tag.namespace()),
    }
}

fn Impl(comptime f: Format) type {
    return if (supports(f)) @field(image, f.namespace()).Decoder else Missing;
}

const Missing = struct {
    const Error = error{};
    fn decodeConfig(_: *Missing) error{}!decode.Config {
        unreachable;
    }
    fn decodeFrame(_: *Missing, _: PixelBuffer, _: []u8) error{}!?decode.Frame {
        unreachable;
    }
};

/// A decoder for `format` on `reader`, whose buffer must hold at least
/// `image.min_buffer_len` bytes.
pub fn init(f: Format, reader: *Io.Reader, options: decode.Options) error{Unsupported}!Decoder {
    switch (f) {
        inline else => |tag| {
            if (comptime !supports(tag)) return error.Unsupported;
            const D = Impl(tag);
            var o: D.Options = .{};
            inline for (@typeInfo(decode.Options).@"struct".field_names) |name| {
                if (@hasField(D.Options, name)) @field(o, name) = @field(options, name);
            }
            return .{ .impl = @unionInit(Union, @tagName(tag), D.init(reader, o)) };
        },
    }
}

/// A decoder for whatever format `reader`'s input is, found by
/// `image.detect` from its first bytes, which stay in the reader.
pub fn initDetect(reader: *Io.Reader, options: decode.Options) error{ ReadFailed, UnknownFormat, Unsupported }!Decoder {
    reader.fill(detect.prefix_len) catch |e| switch (e) {
        error.EndOfStream => {},
        error.ReadFailed => return error.ReadFailed,
    };
    const prefix = reader.buffered();
    const found = detect.detect(prefix[0..@min(prefix.len, detect.prefix_len)]) orelse return error.UnknownFormat;
    return init(found, reader, options);
}

pub fn format(d: *const Decoder) Format {
    return d.impl;
}

/// See the format's `decodeConfig`.
pub fn decodeConfig(d: *Decoder) Error!decode.Config {
    switch (d.impl) {
        inline else => |*impl| return impl.decodeConfig(),
    }
}

/// See the format's `decodeFrame`.
pub fn decodeFrame(d: *Decoder, dst: PixelBuffer, work: []u8) Error!?decode.Frame {
    switch (d.impl) {
        inline else => |*impl| {
            const frame = try impl.decodeFrame(dst, work);
            if (frame == null) d.done = true else d.frames += 1;
            return frame;
        },
    }
}

/// The frame the next `decodeFrame` call returns, read before it draws
/// anything, or null where that call returns null; see the format's
/// `decodeFrameConfig`. A format without one has at most one frame, and
/// its frame is the whole canvas, as its `decodeFrame` returns it; a format
/// that may have more frames and lacks one is `Unsupported` here.
pub fn decodeFrameConfig(d: *Decoder) Error!?decode.Frame {
    switch (d.impl) {
        inline else => |*impl| {
            if (comptime @hasDecl(@TypeOf(impl.*), "decodeFrameConfig")) return impl.decodeFrameConfig();
            const config = try impl.decodeConfig();
            const count = config.frame_count orelse return error.Unsupported;
            if (count > 1) return error.Unsupported;
            if (d.frames >= count) return null;
            return .{ .width = config.width, .height = config.height, .is_opaque = config.is_opaque };
        },
    }
}

/// The config `decodeConfig` returned, updated with what the format found
/// after its frames, such as TGA's footer or a PNG's chunks after its image
/// data: null until `decodeFrame` has returned null. A format reports those
/// with an optional `applyTrailer(*const Self, *Config) void`, which sets
/// the fields it found late and leaves the rest; without one this is the
/// config as `decodeConfig` returned it.
pub fn finalConfig(d: *Decoder) ?decode.Config {
    if (!d.done) return null;
    switch (d.impl) {
        inline else => |*impl| return withTrailer(impl),
    }
}

/// `impl`'s config, with its `applyTrailer` applied if it has one.
fn withTrailer(impl: anytype) ?decode.Config {
    // The decode ended without an error, so this repeats the first answer.
    var config = impl.decodeConfig() catch return null;
    if (@hasDecl(@TypeOf(impl.*), "applyTrailer")) impl.applyTrailer(&config);
    return config;
}

test "detect and decode" {
    const file = "qoif\x00\x00\x00\x01\x00\x00\x00\x01\x04\x00\xfe\x01\x02\x03" ++ @as([7]u8, @splat(0)) ++ "\x01";
    var r: Io.Reader = .fixed(file);
    var d: Decoder = try .initDetect(&r, .{});
    try testing.expectEqual(Format.qoi, d.format());
    const config = try d.decodeConfig();
    var out: [3]u8 = undefined;
    _ = (try d.decodeFrame(try PixelBuffer.init(&out, .bgr8, config.width, config.height), &.{})).?;
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, &out);
    try testing.expectEqual(null, try d.decodeFrame(try PixelBuffer.init(&out, .bgr8, 1, 1), &.{}));

    r = .fixed("not an image");
    try testing.expectError(error.UnknownFormat, Decoder.initDetect(&r, .{}));
    r = .fixed("");
    try testing.expectError(error.UnknownFormat, Decoder.initDetect(&r, .{}));
    try testing.expect(supports(.qoi));
    if (!supports(.tga)) {
        r = .fixed(file);
        try testing.expectError(error.Unsupported, Decoder.init(.tga, &r, .{}));
    }
    // Options reach the format's decoder.
    r = .fixed(file);
    d = try .init(.qoi, &r, .{ .limits = .{ .max_pixels = 0 } });
    try testing.expectError(error.ImageTooLarge, d.decodeConfig());
}

test "a seeker reaches the format's decoder" {
    if (comptime !supports(.ico)) return error.SkipZigTest;
    // An ICO of two 1 by 1, 32-bit entries: the directory lists A at 86,
    // then B at 38, behind it. A's pixel is (3, 2, 1, 255), B's (6, 5, 4, 128).
    const info = "\x28\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\x00\x20\x00" ++ @as([24]u8, @splat(0));
    const file = "\x00\x00\x01\x00\x02\x00" ++
        "\x01\x01\x00\x00\x01\x00\x20\x00\x30\x00\x00\x00\x56\x00\x00\x00" ++
        "\x01\x01\x00\x00\x01\x00\x20\x00\x30\x00\x00\x00\x26\x00\x00\x00" ++
        info ++ "\x04\x05\x06\x80" ++ @as([4]u8, @splat(0)) ++
        info ++ "\x01\x02\x03\xff" ++ @as([4]u8, @splat(0));
    var out: [4]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgba8, 1, 1);
    for ([_]bool{ true, false }) |seek| {
        var r: Io.Reader = .fixed(file);
        var d: Decoder = try .initDetect(&r, .{ .seeker = if (seek) .fixed(&r) else null });
        try testing.expectEqual(Format.ico, d.format());
        const config = try d.decodeConfig();
        try testing.expectEqual(2, config.frame_count);
        // Room for a PNG entry, which the directory cannot rule out.
        const work = try testing.allocator.alloc(u8, config.work_len);
        defer testing.allocator.free(work);
        _ = (try d.decodeFrame(dst, work)).?;
        try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255 }, &out);
        if (seek) {
            try testing.expectEqual(1, (try d.decodeFrame(dst, work)).?.index);
            try testing.expectEqualSlices(u8, &.{ 6, 5, 4, 128 }, &out);
            try testing.expectEqual(null, try d.decodeFrame(dst, work));
        } else {
            try testing.expectError(error.EntryBehind, d.decodeFrame(dst, work));
        }
    }
}

test "the final config, with what followed the frames" {
    // QOI has nothing after its pixels: its config, once the frames end.
    const file = "qoif\x00\x00\x00\x01\x00\x00\x00\x01\x04\x00\xfe\x01\x02\x03" ++ @as([7]u8, @splat(0)) ++ "\x01";
    var r: Io.Reader = .fixed(file);
    var d: Decoder = try .initDetect(&r, .{});
    const config = try d.decodeConfig();
    try testing.expectEqual(null, d.finalConfig());
    var out: [3]u8 = undefined;
    const dst = try PixelBuffer.init(&out, .rgb8, 1, 1);
    _ = (try d.decodeFrame(dst, &.{})).?;
    try testing.expectEqual(null, d.finalConfig());
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
    try testing.expectEqual(config, d.finalConfig().?);
    // A decode that fails has none.
    r = .fixed(file[0 .. file.len - 1]);
    d = try .initDetect(&r, .{});
    _ = try d.decodeConfig();
    try testing.expectError(error.Truncated, d.decodeFrame(dst, &.{}));
    try testing.expectError(error.Truncated, d.decodeFrame(dst, &.{}));
    try testing.expectEqual(null, d.finalConfig());

    // A format with a trailer sets what it found late and keeps the rest.
    const Late = struct {
        const Self = @This();
        fn decodeConfig(_: *Self) error{}!decode.Config {
            return .{ .width = 2, .height = 3, .native = .rgba8, .metadata = .{ .gamma = 45455 } };
        }
        pub fn applyTrailer(_: *const Self, c: *decode.Config) void {
            c.background = .{ 1, 2, 3, 255 };
            c.metadata.orientation = .right_top;
        }
    };
    var late: Late = .{};
    const final = withTrailer(&late).?;
    try testing.expectEqual(.{ 2, 3, 45455 }, .{ final.width, final.height, final.metadata.gamma.? });
    try testing.expectEqual(.{ 1, 2, 3, 255 }, final.background.?);
    try testing.expectEqual(.right_top, final.metadata.orientation);
}

test "the next frame's config, before it is drawn" {
    var out: [4]u8 = undefined;
    // QOI has no decodeFrameConfig: its one frame is the canvas.
    const qoi = "qoif\x00\x00\x00\x01\x00\x00\x00\x01\x04\x00\xfe\x01\x02\x03" ++ @as([7]u8, @splat(0)) ++ "\x01";
    var r: Io.Reader = .fixed(qoi);
    var d: Decoder = try .initDetect(&r, .{});
    const dst = try PixelBuffer.init(&out, .rgba8, 1, 1);
    const next = (try d.decodeFrameConfig()).?;
    try testing.expectEqual(next, (try d.decodeFrameConfig()).?);
    try testing.expectEqual(next, (try d.decodeFrame(dst, &.{})).?);
    try testing.expectEqual(null, try d.decodeFrameConfig());
    try testing.expectEqual(null, try d.decodeFrame(dst, &.{}));
    // GIF has its own: a 1 by 1 image, palette index 0.
    if (comptime supports(.gif)) {
        const gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00" ++ "\x0a\x14\x1e\x00\x00\x00" ++
            "\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
        r = .fixed(gif);
        d = try .initDetect(&r, .{});
        const config = try d.decodeConfig();
        var work: [1 << 17]u8 = undefined;
        const g = (try d.decodeFrameConfig()).?;
        try testing.expectEqual(g, (try d.decodeFrame(dst, work[0..config.work_len])).?);
        try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, &out);
        try testing.expectEqual(null, try d.decodeFrameConfig());
    }
    // Netpbm's raw files do not say how many images follow; its own
    // decodeFrameConfig finds out.
    if (comptime supports(.netpbm)) {
        r = .fixed("P5 1 1 255\n\x07");
        d = try .initDetect(&r, .{});
        const p = (try d.decodeFrameConfig()).?;
        try testing.expectEqual(p, (try d.decodeFrame(try PixelBuffer.init(out[0..1], .gray8, 1, 1), &.{})).?);
        try testing.expectEqual(null, try d.decodeFrameConfig());
    }
}
