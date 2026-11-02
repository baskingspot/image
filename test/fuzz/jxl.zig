//! The JPEG XL fuzz target: the decoder properties in harness.zig, on
//! mutated corpus files and generated Modular codestreams.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "jxl";

/// Seed directories, relative to the repository root (corpus/README.md),
/// and the extensions of the files in them to take.
pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/jxl" };
pub const extensions = [_][]const u8{".jxl"};

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkDecoder(image.jxl.Decoder, input, choice);
    if (choice % 4 == 0) try checkSink(input);
    if (choice % 4 == 1) try checkFloat(input);
    if (choice % 4 == 2) try checkStream(input);
    if (choice % 4 == 3) try checkJpeg(input);
}

var float_pixels: [harness.limits.max_pixels * 16]u8 align(4) = undefined;
var int_pixels: [harness.limits.max_pixels * 8]u8 align(2) = undefined;
var float_work: [harness.limits.max_work]u8 = undefined;
var int_work: [harness.limits.max_work]u8 = undefined;

/// A float destination, written from the decoder's floats (plan.md
/// decision 24), is within half a native step of the 16-bit destination,
/// which goes through the native format (8-bit when the first frame is
/// lossless 8-bit, though a later one may not be): clamped to [0, 1],
/// frame by frame, with the same frames and errors.
fn checkFloat(input: []const u8) !void {
    var rf: std.Io.Reader = .fixed(input);
    var ri: std.Io.Reader = .fixed(input);
    var df: image.jxl.Decoder = .init(&rf, .{ .limits = harness.limits });
    var di: image.jxl.Decoder = .init(&ri, .{ .limits = harness.limits });
    const c = df.decodeConfig() catch return;
    _ = di.decodeConfig() catch return error.FloatDiffers;
    const premul = c.native.isPremultiplied();
    const ff: image.PixelFormat = if (premul) .rgba_f32_premul else .rgba_f32;
    const fi: image.PixelFormat = if (premul) .rgba16_premul else .rgba16;
    const bf = image.PixelBuffer.init(&float_pixels, ff, c.width, c.height) catch return;
    const bi = image.PixelBuffer.init(&int_pixels, fi, c.width, c.height) catch return;
    const step: f32 = if (c.native.sample() == .u8) 1.0 / 255.0 else 1.0 / 65535.0;
    for (0..harness.limits.max_frames + 1) |_| {
        const a = df.decodeFrame(bf, float_work[0..c.work_len]);
        const b = di.decodeFrame(bi, int_work[0..c.work_len]);
        const fa = a catch |e| {
            if (b) |_| return error.FloatDiffers else |e2| if (e2 != e) return error.FloatDiffers;
            return;
        };
        const fb = b catch return error.FloatDiffers;
        if (!std.meta.eql(fa, fb)) return error.FloatDiffers;
        if (fa == null) return;
        const n = @as(usize, c.width) * c.height * 4;
        const fl = std.mem.bytesAsSlice(f32, float_pixels[0 .. n * 4]);
        const in = std.mem.bytesAsSlice(u16, int_pixels[0 .. n * 2]);
        for (fl, in) |v, u| {
            const want = @as(f32, @floatFromInt(u)) / 65535;
            if (!(@abs(std.math.clamp(v, 0, 1) - want) <= step / 2 + 1e-6)) return error.FloatDiffers;
        }
    }
}

/// A frame streamed a group row at a time has the pixels, frames, and
/// errors it has decoded whole.
fn checkStream(input: []const u8) !void {
    var whole: [harness.limits.max_frames + 1]Outcome = undefined;
    const n = decodeAll(input, null, false, &whole);
    var streamed: [harness.limits.max_frames + 1]Outcome = undefined;
    const m = decodeAll(input, null, true, &streamed);
    if (n != m) return error.StreamDiffers;
    for (whole[0..n], streamed[0..m]) |a, b| if (!std.meta.eql(a, b)) return error.StreamDiffers;
}

const Sink = @typeInfo(@FieldType(image.jxl.Decoder, "coeff_sink")).optional.child;
const SharedPtr = SinkParam("lf", 1);
const QuantLf = SinkParam("lf", 2);
const QuantBlock = SinkParam("block", 2);
const SinkReturn = SinkParam("lf", 3);

/// Parameter `i` of the sink's `field` callback, or its return type at 3.
fn SinkParam(comptime field: []const u8, comptime i: usize) type {
    const f = @typeInfo(@typeInfo(@FieldType(Sink, field)).pointer.child).@"fn";
    return if (i < f.params.len) f.params[i].type.? else f.return_type.?;
}

var sink_pixels: [harness.limits.max_pixels * 8]u8 = undefined;
var sink_work: [harness.limits.max_work]u8 = undefined;

/// A frame's outcome: its frame and pixels' hash, or its error.
const Outcome = union(enum) { frame: struct { f: image.Frame, hash: u64 }, end, err: anyerror };

/// Decoding with a coefficient sink gives the same frames, pixels, and
/// errors as without one, and what the sink sees lies inside the frame.
fn checkSink(input: []const u8) !void {
    var plain: [harness.limits.max_frames + 1]Outcome = undefined;
    const n = decodeAll(input, null, true, &plain);
    var seen: Seen = .{};
    var with: [harness.limits.max_frames + 1]Outcome = undefined;
    const m = decodeAll(input, .{ .ctx = &seen, .lf = Seen.onLf, .block = Seen.onBlock }, true, &with);
    if (seen.bad) return error.SinkOutOfBounds;
    if (n != m) return error.SinkDiffers;
    for (plain[0..n], with[0..m]) |a, b| if (!std.meta.eql(a, b)) return error.SinkDiffers;
}

var jpeg_coefs: [1 << 22]i16 = undefined;

/// `decodeJpeg` lays out whole MCUs inside the buffer it was given, and
/// reads only files whose frame the frame decoder reads too.
fn checkJpeg(input: []const u8) !void {
    const Decoder = image.jxl.Decoder;
    var r: std.Io.Reader = .fixed(input);
    var d: Decoder = .init(&r, .{ .limits = harness.limits });
    const c = d.decodeConfig() catch return;
    const len = d.jpegWorkLen() catch return;
    const n = Decoder.Jpeg.maxCoefs(c.width, c.height);
    if (len > sink_work.len or n > jpeg_coefs.len) return;
    const j = d.decodeJpeg(jpeg_coefs[0..n], sink_work[0..len]) catch return;
    const mcus_x = j.blocks_x[0] / j.h[0];
    const mcus_y = j.blocks_y[0] / j.v[0];
    var total: usize = 0;
    for (0..3) |k| {
        if (j.h[k] -% 1 > 1 or j.v[k] -% 1 > 1) return error.JpegLayout;
        if (j.blocks_x[k] != mcus_x * j.h[k] or j.blocks_y[k] != mcus_y * j.v[k]) return error.JpegLayout;
        if (j.coefs[k].len != @as(usize, j.blocks_x[k]) * j.blocks_y[k] * 64) return error.JpegLayout;
        total += j.coefs[k].len;
    }
    if (total > n) return error.JpegLayout;
    var frames: [harness.limits.max_frames + 1]Outcome = undefined;
    const m = decodeAll(input, null, false, &frames);
    // The frame decodes; the boxes after the codestream, which the call
    // after it reads, are not the coefficients' concern.
    if (m == 0 or frames[0] != .frame) return error.JpegDiffers;
}

fn decodeAll(input: []const u8, sink: ?Sink, stream: bool, out: []Outcome) usize {
    var r: std.Io.Reader = .fixed(input);
    var d: image.jxl.Decoder = .init(&r, .{ .limits = harness.limits });
    d.coeff_sink = sink;
    d.stream = stream;
    const c = d.decodeConfig() catch |e| {
        out[0] = .{ .err = e };
        return 1;
    };
    const dst = image.PixelBuffer.init(&sink_pixels, .rgba16, c.width, c.height) catch return 0;
    for (out, 1..) |*o, i| {
        const got = d.decodeFrame(dst, sink_work[0..c.work_len]) catch |e| {
            o.* = .{ .err = e };
            return i;
        };
        const f = got orelse {
            o.* = .end;
            return i;
        };
        o.* = .{ .frame = .{ .f = f, .hash = std.hash.XxHash64.hash(0, dst.pixels) } };
    }
    return out.len;
}

const Seen = struct {
    bad: bool = false,

    fn onLf(ctx: *anyopaque, s: SharedPtr, q: QuantLf) SinkReturn {
        const self: *Seen = @ptrCast(@alignCast(ctx));
        const r = q.rect;
        if (r.x0 + r.w > s.bw or r.y0 + r.h > s.bh) self.bad = true;
        for (q.channels, 0..) |ch, c| {
            const short = ch.data.len < @as(usize, ch.w) * ch.h;
            if (ch.w != r.w >> s.hs[c] or ch.h != r.h >> s.vs[c] or short) self.bad = true;
        }
    }

    fn onBlock(ctx: *anyopaque, s: SharedPtr, b: QuantBlock) SinkReturn {
        const self: *Seen = @ptrCast(@alignCast(ctx));
        if (b.bx + b.strategy.bx() > s.bw or b.by + b.strategy.by() > s.bh) self.bad = true;
        for (b.coeffs) |co| if (co) |v| if (v.len != 64 * @as(usize, b.strategy.covered())) {
            self.bad = true;
        };
    }
};

/// Bits, least significant first, as the codestream stores them.
const BitWriter = struct {
    buf: []u8,
    bit: usize = 0,

    fn put(w: *BitWriter, v: u64, n: u6) void {
        for (0..n) |i| {
            const byte = w.bit / 8;
            if (byte >= w.buf.len) return;
            if (w.bit % 8 == 0) w.buf[byte] = 0;
            if ((v >> @intCast(i)) & 1 == 1) w.buf[byte] |= @as(u8, 1) << @intCast(w.bit % 8);
            w.bit += 1;
        }
    }

    fn pad(w: *BitWriter) void {
        while (w.bit % 8 != 0) w.put(0, 1);
    }

    fn bytes(w: *const BitWriter) usize {
        return @min(w.buf.len, (w.bit + 7) / 8);
    }
};

/// A prefix code's alphabet size, as `Code.read` reads it.
fn alphabetSize(w: *BitWriter, size: u32) void {
    if (size == 1) return w.put(0, 1);
    w.put(1, 1);
    const nbits: u6 = @intCast(std.math.log2_int(u32, size - 1));
    w.put(nbits, 4);
    if (nbits > 0) w.put(size - 1 - (@as(u32, 1) << @intCast(nbits)), nbits);
}

fn maxBits(alphabet: u32) u6 {
    return if (alphabet > 1) @intCast(32 - @clz(alphabet - 1)) else 0;
}

/// A JPEG XL codestream of one Modular frame in one group: a valid
/// header, a one-leaf tree with a random predictor, and random residuals
/// from a four-symbol prefix code; sometimes a transform, extra channels,
/// or grey; and sometimes a random body instead.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 4096);
    var w: BitWriter = .{ .buf = buf };
    w.put(0x0aff, 16);
    // Size: small, a multiple of 8 up to 64.
    const h8 = random.uintLessThan(u32, 8);
    const w8 = random.uintLessThan(u32, 8);
    w.put(1, 1);
    w.put(h8, 5);
    w.put(0, 3);
    w.put(w8, 5);
    const width = (w8 + 1) * 8;
    const height = (h8 + 1) * 8;
    // Image metadata.
    w.put(0, 1); // all_default
    w.put(0, 1); // extra_fields
    w.put(0, 1); // integer samples
    const depth_sel = random.uintLessThan(u32, 3);
    w.put(depth_sel, 2); // 8, 10, or 12 bits
    w.put(1, 1); // modular_16_bit
    const num_ec = random.uintLessThan(u32, 2);
    w.put(num_ec, 2);
    for (0..num_ec) |_| w.put(1, 1); // an 8-bit alpha channel
    w.put(0, 1); // not XYB
    const grey = random.uintLessThan(u8, 4) == 0;
    if (grey) {
        w.put(0, 1); // colour_encoding.all_default
        w.put(0, 1); // want_icc
        w.put(1, 2); // grey
        w.put(1, 2); // D65
        w.put(0, 1); // no gamma
        w.put(2, 2);
        w.put(13 - 2, 4); // sRGB transfer
        w.put(0, 2); // perceptual
    } else {
        w.put(1, 1); // sRGB
    }
    w.put(0, 2); // extensions
    w.put(1, 1); // default transform data
    w.pad();
    // Frame header.
    w.put(0, 1);
    w.put(0, 2); // regular
    w.put(1, 1); // modular
    w.put(0, 2); // flags
    w.put(0, 1); // not YCbCr
    w.put(0, 2); // upsampling 1
    for (0..num_ec) |_| w.put(0, 2);
    w.put(random.uintLessThan(u32, 4), 2); // group size shift
    w.put(0, 2); // one pass
    w.put(0, 1); // no crop
    w.put(0, 2); // replace
    for (0..num_ec) |_| w.put(0, 2);
    w.put(1, 1); // is_last
    w.put(0, 2); // no name
    w.put(0, 1); // restoration filter not default
    w.put(0, 1); // no gaborish
    w.put(0, 2); // no EPF
    w.put(0, 2); // extensions
    w.put(0, 2); // extensions
    // The body goes in the second half first, so the TOC can give its
    // size.
    const half = buf.len / 2;
    var b: BitWriter = .{ .buf = buf[half..] };
    if (random.uintLessThan(u8, 8) == 0) {
        const n = random.uintLessThan(usize, 512);
        random.bytes(b.buf[0..n]);
        b.bit = n * 8;
    } else {
        body(random, &b, width, height, (if (grey) @as(u32, 1) else 3) + num_ec);
    }
    b.pad();
    const size = b.bytes();
    // TOC of one section.
    w.put(0, 1);
    w.pad();
    if (size < 1024) {
        w.put(0, 2);
        w.put(size, 10);
    } else {
        w.put(1, 2);
        w.put(size - 1024, 14);
    }
    w.pad();
    const at = w.bytes();
    if (at + size > half) return buf[0..at];
    @memcpy(buf[at..][0..size], b.buf[0..size]);
    return buf[0 .. at + size];
}

fn body(random: std.Random, w: *BitWriter, width: u32, height: u32, channels: u32) void {
    w.put(1, 1); // default LF dequantization
    w.put(1, 1); // a global tree
    // The tree's code: six contexts, the predictor's in cluster 1.
    const pred = random.uintLessThan(u32, 14);
    w.put(0, 1); // no LZ77
    w.put(1, 1); // simple context map
    w.put(1, 2); // one bit per entry
    for (0..6) |ctx| w.put(@intFromBool(ctx == 2), 1);
    w.put(1, 1); // prefix codes
    w.put(15, 4);
    w.put(15, 4); // configs: every token literal
    alphabetSize(w, 1);
    alphabetSize(w, pred + 1);
    if (pred > 0) {
        w.put(1, 2); // simple code
        w.put(0, 2); // one symbol
        w.put(pred, maxBits(pred + 1));
    }
    // The tree's histograms: one context, four symbols under 16.
    w.put(0, 1); // no LZ77
    w.put(1, 1); // prefix codes
    w.put(15, 4);
    alphabetSize(w, 16);
    w.put(1, 2);
    w.put(3, 2); // four symbols
    var syms: [4]u32 = undefined;
    var used: u16 = 0;
    for (&syms) |*s| {
        var v = random.uintLessThan(u32, 16);
        while (used & (@as(u16, 1) << @intCast(v)) != 0) v = (v + 1) % 16;
        used |= @as(u16, 1) << @intCast(v);
        s.* = v;
        w.put(v, 4);
    }
    w.put(0, 1); // tree_select
    // The global stream's group header.
    w.put(1, 1); // the global tree
    w.put(1, 1); // default weighted predictor
    switch (random.uintLessThan(u8, 4)) {
        0 => if (channels >= 3) {
            w.put(1, 2); // one transform
            w.put(0, 2); // RCT
            w.put(0, 2);
            w.put(0, 3); // from channel 0
            w.put(2, 2);
            w.put(random.uintLessThan(u32, 32), 4); // type 2..33
        } else w.put(0, 2),
        else => w.put(0, 2),
    }
    // Residuals: two bits each.
    const n = @as(usize, width) * height * channels;
    for (0..n) |_| w.put(random.uintLessThan(u32, 4), 2);
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk: an 8 by 8 grey Modular image of zeros.
pub const seeds = [_][]const u8{
    "\xff\x0a\x00\x00\x00\x00",
};

test "jxl on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}

test "generated files decode" {
    var prng: std.Random.DefaultPrng = .init(1);
    var buf: [1 << 16]u8 = undefined;
    var ok: usize = 0;
    for (0..64) |_| {
        const file = generate(prng.random(), &buf);
        var r: std.Io.Reader = .fixed(file);
        var d = image.jxl.Decoder.init(&r, .{});
        const c = d.decodeConfig() catch continue;
        var px: [64 * 64 * 8]u8 = undefined;
        const dst = try image.PixelBuffer.init(&px, .rgba16, c.width, c.height);
        const work = try std.testing.allocator.alloc(u8, c.work_len);
        defer std.testing.allocator.free(work);
        if (d.decodeFrame(dst, work)) |_| ok += 1 else |_| {}
    }
    try std.testing.expect(ok > 32);
}
