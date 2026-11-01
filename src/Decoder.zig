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
            inline for (@typeInfo(decode.Options).@"struct".fields) |field| {
                @field(o, field.name) = @field(options, field.name);
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
        inline else => |*impl| return impl.decodeFrame(dst, work),
    }
}

test "detect and decode" {
    const file = "qoif\x00\x00\x00\x01\x00\x00\x00\x01\x04\x00\xfe\x01\x02\x03" ++ "\x00" ** 7 ++ "\x01";
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
