//! The resizer's fuzz target, and the requests the resize oracles read
//! (test/oracle/resize.zig). A request is a header, then the bytes the
//! source's samples are made from:
//!
//!   u8 filter (image.resize.Filter, modulo its count)
//!   u8 edge (image.resize.Edge, modulo its count) | 0x80 for sRGB
//!   u16 source width, u16 source height,
//!   u16 destination width, u16 destination height (little endian; each
//!       1 + its value modulo `max_side`)
//!
//! Sizes of more than `max_pixels` on either side are refused. The source
//! is in whatever pixel format is asked for, and its samples are taken in
//! order from the bytes after the header, repeated as needed (zero without
//! any): an 8-bit sample is a byte, a 16-bit one two bytes little endian,
//! and a float one a byte over 255. For the straight-alpha oracles, alpha
//! is taken to the upper half of its range (`b / 2 + 128`, and the same for
//! 16-bit samples). test/oracle/resize.h reads the same.
//!
//! On any request and pair of formats, `check` resizes without a crash and
//! checks that:
//!
//! - work memory or a buffer one byte short is refused;
//! - a strided destination gets the same rows;
//! - `Resizer`, pushed and taken in a random rhythm, refuses a push while a
//!   row is ready and writes the same rows as `resize`;
//! - `point` copies the source pixel under each destination pixel's center;
//! - filters without negative lobes keep every sample of a format filtered
//!   as stored within its channel's range in the source (and 0, at a zero
//!   edge);
//! - `orient` puts the source's first pixel in the corner the orientation
//!   names, and its inverse brings the source back.

const std = @import("std");
const image = @import("image");
const resize = image.resize;
const PixelFormat = image.PixelFormat;
const PixelBuffer = image.PixelBuffer;
const harness = @import("harness.zig");

pub const name = "resize";

pub const corpus: [0][]const u8 = .{};
pub const extensions: [0][]const u8 = .{};

pub const header_len = 10;
pub const max_side = 1024;
pub const max_pixels = 1 << 16;

pub const Request = struct {
    options: resize.Options,
    src_width: u32,
    src_height: u32,
    dst_width: u32,
    dst_height: u32,
    samples: []const u8,

    pub fn parse(input: []const u8) ?Request {
        if (input.len < header_len) return null;
        const filters = comptime std.enums.values(resize.Filter);
        const edges = comptime std.enums.values(resize.Edge);
        const side = struct {
            fn at(b: []const u8, i: usize) u32 {
                return 1 + @as(u32, std.mem.readInt(u16, b[i..][0..2], .little)) % max_side;
            }
        }.at;
        const req: Request = .{
            .options = .{
                .filter = filters[input[0] % filters.len],
                .edge = edges[(input[1] & 0x7f) % edges.len],
                .colorspace = if (input[1] & 0x80 != 0) .srgb else .linear,
            },
            .src_width = side(input, 2),
            .src_height = side(input, 4),
            .dst_width = side(input, 6),
            .dst_height = side(input, 8),
            .samples = input[header_len..],
        };
        if (req.src_width * req.src_height > max_pixels or req.dst_width * req.dst_height > max_pixels) return null;
        return req;
    }

    /// Writes the source's samples into `src`, of the request's source
    /// size, packed; with `high_alpha`, alpha in the upper half.
    pub fn source(req: Request, src: PixelBuffer, high_alpha: bool) void {
        const ch = src.format.channelCount();
        const alpha = if (high_alpha) src.format.channels().a else null;
        var at: usize = 0;
        for (0..src.width * src.height * ch) |i| {
            const high = alpha != null and i % ch == alpha.?;
            switch (src.format.sample()) {
                .u8 => {
                    const b = req.byte(&at);
                    src.pixels[i] = if (high) 128 + b / 2 else b;
                },
                .u16 => {
                    const lo = req.byte(&at);
                    var v = @as(u16, req.byte(&at)) << 8 | lo;
                    if (high) v = 32768 + v / 2;
                    std.mem.writeInt(u16, src.pixels[2 * i ..][0..2], v, .native);
                },
                .f32 => {
                    const b = req.byte(&at);
                    const v: f32 = @as(f32, @floatFromInt(if (high) 128 + b / 2 else b)) / 255;
                    std.mem.writeInt(u32, src.pixels[4 * i ..][0..4], @bitCast(v), .native);
                },
            }
        }
    }

    fn byte(req: Request, at: *usize) u8 {
        if (req.samples.len == 0) return 0;
        const b = req.samples[at.* % req.samples.len];
        at.* += 1;
        return b;
    }

    /// The most work memory the request takes in any pair of the same
    /// format.
    pub fn workLen(req: Request) usize {
        var most: usize = 0;
        for (std.enums.values(PixelFormat)) |f| {
            const len = resize.workLen(f, req.dst_width, req.dst_height, f, req.src_width, req.src_height, req.options);
            most = @max(most, len.?);
        }
        return most;
    }
};

/// How a `Decoder` reads requests: as they are, with `resize`'s default
/// options in place of the request's (`stbir_resize_uint8` has none), or
/// with alpha in the upper half.
pub const Mode = enum { plain, defaults, high_alpha };

/// A request read as an image by the oracle harness: its config is the
/// destination's size, and `decodeFrame` resizes a source made in the
/// destination's format into it.
pub fn Decoder(comptime mode: Mode) type {
    return struct {
        const Self = @This();
        input: []const u8,
        max_pixels: u64,
        req: ?Request = null,

        pub fn init(r: *std.Io.Reader, options: image.DecodeOptions) Self {
            return .{ .input = r.buffered(), .max_pixels = options.limits.max_pixels };
        }

        pub fn decodeConfig(d: *Self) image.DecodeError!image.Config {
            var req = Request.parse(d.input) orelse return error.BadHeader;
            if (mode == .defaults) req.options = .{};
            if (@as(u64, req.dst_width) * req.dst_height > d.max_pixels) return error.ImageTooLarge;
            d.req = req;
            return .{ .width = req.dst_width, .height = req.dst_height, .native = .rgba8, .work_len = req.workLen() };
        }

        pub fn decodeFrame(d: *Self, dst: PixelBuffer, work: []u8) !?image.Frame {
            const req = d.req orelse return null;
            d.req = null;
            const gpa = std.heap.smp_allocator;
            const pixels = try gpa.alloc(u8, PixelBuffer.len(dst.format, req.src_width, req.src_height).?);
            defer gpa.free(pixels);
            const src = try PixelBuffer.init(pixels, dst.format, req.src_width, req.src_height);
            req.source(src, mode == .high_alpha);
            try resize.resize(dst, src, work, req.options);
            return .{ .width = dst.width, .height = dst.height };
        }
    };
}

/// `orient` puts the source's first pixel in the corner `o` names, and
/// the inverse orientation brings the source back.
fn checkOrient(src: PixelBuffer, o: image.Orientation) !void {
    const swap = @intFromEnum(o) >= @intFromEnum(image.Orientation.left_top);
    const w = if (swap) src.height else src.width;
    const h = if (swap) src.width else src.height;
    const turned = PixelBuffer.init(dst_buf[1][0..src.pixels.len], src.format, w, h) catch unreachable;
    try resize.orient(turned, src, o);
    const right = switch (o) {
        .top_right, .bottom_right, .right_top, .right_bottom => true,
        else => false,
    };
    const bottom = switch (o) {
        .bottom_right, .bottom_left, .right_bottom, .left_bottom => true,
        else => false,
    };
    const bpp = src.format.bytesPerPixel();
    const corner = turned.row(if (bottom) h - 1 else 0)[(if (right) w - 1 else 0) * bpp ..][0..bpp];
    if (!std.mem.eql(u8, src.row(0)[0..bpp], corner)) return error.OrientDiffers;
    // A quarter turn either way undoes the other; every other orientation
    // undoes itself.
    const inverse: image.Orientation = switch (o) {
        .right_top => .left_bottom,
        .left_bottom => .right_top,
        else => o,
    };
    const back = PixelBuffer.init(dst_buf[2][0..src.pixels.len], src.format, src.width, src.height) catch unreachable;
    try resize.orient(back, turned, inverse);
    if (!std.mem.eql(u8, src.pixels, back.pixels)) return error.OrientDiffers;
}

pub const Finding = error{
    ShortWorkAccepted,
    ShortBufferAccepted,
    StrideDiffers,
    StreamDiffers,
    PushWhileReady,
    PointDiffers,
    OutOfRange,
    OrientDiffers,
};

const max_bytes = max_pixels * 16;
var src_buf: [max_bytes]u8 = undefined;
var dst_buf: [3][max_bytes + 64 * max_side]u8 = undefined;
var work_buf: [1 << 27]u8 = undefined;

pub fn check(input: []const u8, choice: u64) !void {
    const req = Request.parse(input) orelse return;
    const formats = comptime std.enums.values(PixelFormat);
    const sf = formats[choice % formats.len];
    const df = formats[(choice >> 8) % formats.len];
    const opt = req.options;
    const sw = req.src_width;
    const sh = req.src_height;
    const dw = req.dst_width;
    const dh = req.dst_height;
    const src: PixelBuffer = PixelBuffer.init(src_buf[0..PixelBuffer.len(sf, sw, sh).?], sf, sw, sh) catch unreachable;
    req.source(src, choice >> 24 & 1 != 0);
    const need = resize.workLen(df, dw, dh, sf, sw, sh, opt).?;
    if (need > work_buf.len) return;
    const work = work_buf[0..need];
    const len = PixelBuffer.len(df, dw, dh).?;
    const dst = PixelBuffer.init(dst_buf[0][0..len], df, dw, dh) catch unreachable;
    try resize.resize(dst, src, work, opt);

    if (need > 0) {
        if (resize.resize(dst, src, work[0 .. need - 1], opt)) |_| return error.ShortWorkAccepted else |_| {}
    }
    const short: PixelBuffer = .{
        .pixels = dst_buf[1][0 .. len - 1],
        .format = df,
        .width = dw,
        .height = dh,
        .stride = len / dh,
    };
    if (resize.resize(short, src, work, opt)) |_| return error.ShortBufferAccepted else |_| {}

    // A stride with room after each row.
    const row = dw * df.bytesPerPixel();
    const stride = row + 1 + (choice >> 16) % 63;
    const strided_pixels = dst_buf[1][0 .. stride * (dh - 1) + row];
    const strided = PixelBuffer.initStride(strided_pixels, df, dw, dh, stride) catch unreachable;
    try resize.resize(strided, src, work, opt);
    for (0..dh) |y| {
        if (!std.mem.eql(u8, dst.row(@intCast(y)), strided.row(@intCast(y)))) return error.StrideDiffers;
    }

    // Rows streamed, sometimes pushing while a row is ready.
    var rhythm = std.Random.DefaultPrng.init(choice);
    const random = rhythm.random();
    var r = try resize.Resizer.init(df, dw, dh, sf, sw, sh, opt, work);
    const streamed = PixelBuffer.init(dst_buf[2][0..len], df, dw, dh) catch unreachable;
    var y: u32 = 0;
    var sy: u32 = 0;
    while (sy < sh) {
        if (y < dh and random.boolean() and r.take(streamed.row(y))) {
            y += 1;
            continue;
        }
        if (r.push(src.row(sy))) |_| {
            sy += 1;
        } else |e| {
            if (e != error.RowReady) return error.StreamDiffers;
            // Refused only with a row ready.
            if (!r.take(streamed.row(y))) return error.PushWhileReady;
            y += 1;
        }
    }
    while (y < dh and r.take(streamed.row(y))) y += 1;
    if (y != dh or r.take(streamed.row(0))) return error.StreamDiffers;
    if (!std.mem.eql(u8, dst.pixels, streamed.pixels)) return error.StreamDiffers;

    try checkOrient(src, @enumFromInt(@as(u3, @truncate(choice >> 32))));

    if (sf != df) return;
    const bpp = sf.bytesPerPixel();
    if (opt.filter == .point) {
        for (0..dh) |dy| {
            const py = (2 * dy + 1) * sh / (2 * dh);
            for (0..dw) |dx| {
                const px = (2 * dx + 1) * sw / (2 * dw);
                const want = src.row(@intCast(py))[px * bpp ..][0..bpp];
                if (!std.mem.eql(u8, want, dst.row(@intCast(dy))[dx * bpp ..][0..bpp])) return error.PointDiffers;
            }
        }
    }
    const positive = switch (opt.filter) {
        .point, .box, .triangle, .b_spline => true,
        .default, .catmull_rom, .mitchell, .lanczos3 => false,
    };
    const stored = opt.colorspace == .linear and !(sf.hasAlpha() and !sf.isPremultiplied());
    if (!positive or !stored or sf.sample() == .f32) return;
    // Each channel's range in the source, then every destination sample.
    const ch = sf.channelCount();
    var lo: [4]u32 = @splat(std.math.maxInt(u32));
    var hi: [4]u32 = @splat(0);
    for (0..sw * sh * ch) |i| {
        const v = sample(sf, src.pixels, i);
        lo[i % ch] = @min(lo[i % ch], v);
        hi[i % ch] = @max(hi[i % ch], v);
    }
    if (opt.edge == .zero) lo = @splat(0);
    for (0..dw * dh * ch) |i| {
        const v = sample(sf, dst.pixels, i);
        if (v < lo[i % ch] or v > hi[i % ch]) return error.OutOfRange;
    }
}

fn sample(f: PixelFormat, bytes: []const u8, i: usize) u32 {
    return switch (f.sample()) {
        .u8 => bytes[i],
        .u16 => std.mem.readInt(u16, bytes[2 * i ..][0..2], .native),
        .f32 => unreachable,
    };
}

/// A request: sizes from icons to strips, often an extreme ratio, and
/// samples in runs, ramps, and noise.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    const sizes = struct {
        fn side(rand: std.Random) u16 {
            return switch (rand.uintLessThan(u8, 8)) {
                0 => 0,
                1, 2 => rand.uintLessThan(u16, 8),
                3, 4, 5 => rand.uintLessThan(u16, 64),
                6 => rand.uintLessThan(u16, 300),
                else => rand.uintLessThan(u16, max_side),
            };
        }
    };
    buf[0] = random.int(u8);
    buf[1] = random.int(u8);
    for (0..4) |k| {
        var v = sizes.side(random);
        // Keep most requests within the pixel limit: a long side's
        // partner is short.
        const partner = @as(u32, std.mem.readInt(u16, buf[2 * k ..][0..2], .little) % max_side + 1);
        if (k % 2 == 1 and partner * (@as(u32, v) + 1) > max_pixels) {
            v = random.uintLessThan(u16, 16);
        }
        std.mem.writeInt(u16, buf[2 + 2 * k ..][0..2], v, .little);
    }
    const len = header_len + random.uintLessThan(usize, @min(buf.len - header_len, 2048));
    var i: usize = header_len;
    while (i < len) {
        const n = @min(len - i, 1 + random.uintLessThan(usize, 64));
        switch (random.uintLessThan(u8, 4)) {
            0 => @memset(buf[i..][0..n], random.int(u8)),
            1 => {
                const start = random.int(u8);
                const step = random.int(u8);
                for (buf[i..][0..n], 0..) |*b, k| b.* = start +% step *% @as(u8, @truncate(k));
            },
            2 => for (buf[i..][0..n]) |*b| {
                b.* = if (random.boolean()) 0 else 255;
            },
            else => random.bytes(buf[i..][0..n]),
        }
        i += n;
    }
    return buf[0..len];
}

pub const seeds = [_][]const u8{
    // Default options, 16x16 to 4x4, a ramp.
    "\x00\x00\x0f\x00\x0f\x00\x03\x00\x03\x00" ++ "\x00\x10\x20\x30\x40\x50\x60\x70\x80\x90\xa0\xb0\xc0\xd0\xe0\xf0",
    // Lanczos, wrapping, 1x300 to 7x1.
    "\x07\x02\x00\x00\x2b\x01\x06\x00\x00\x00" ++ "\xff\x00\x80",
    // Point, reflect, sRGB, 3x2 to 40x9.
    "\x01\x81\x02\x00\x01\x00\x27\x00\x08\x00" ++ "\x10\xf0\x33\x99\x00\xff\x7f",
};

test "resize on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
