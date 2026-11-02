//! JPEG against libjpeg-turbo, the bar, and Wuffs (test/oracle/jpeg.c), in
//! RGB, for grayscale and two-component images gray and gray with alpha,
//! and for CMYK and YCCK images their inks (`cmyk8`, `cmyk16`), each 8- and
//! 16-bit. libjpeg-turbo's decoding choices
//! are its defaults, which this package matches bit for bit (owner
//! decision 2), so any pixel it writes differently is a mismatch.
//!
//! libjpeg-turbo runs strict, every warning an error but three that leave
//! the pixels alone (jpeg.c), and with two settings changed:
//!
//! - No SIMD. Its SIMD IDCT dequantizes in 16 bits and saturates its
//!   results, where its C IDCT computes in 64 bits and wraps them; they
//!   agree on every file an encoder writes, and this package follows the C
//!   code on the corrupt rest.
//! - No block smoothing. For a progressive image whose scans leave any of
//!   the first nine AC coefficients unrefined, libjpeg-turbo estimates
//!   them from the neighboring blocks' DC (T.81 K.8's suggestion, with its
//!   own 5×5 filter); this package does not, so it writes what the scans
//!   coded. A complete progression, as every encoder writes, is unaffected.
//!
//! The references disagree, and the expected splits are:
//!
//! - Wuffs's pixels differ from libjpeg-turbo's on some images (its own
//!   upsampling at the image edges and for other sampling layouts), and it
//!   accepts or rejects some damaged files differently.
//!
//! Wuffs decodes only 8-bit Huffman-coded DCT images, and its 16-bit
//! output only widens them, so `comparable` leaves out its answer for the
//! other processes and for 16-bit formats.

const std = @import("std");
const image = @import("image");

pub const name = "jpeg";
pub const fuzz = @import("fuzz").jpeg;
pub const oracles = [_][]const u8{ "jpeg-turbo", "jpeg-wuffs" };
pub const formats = [_]image.PixelFormat{
    .rgb8, .gray8, .rgb16, .gray16, .cmyk8, .cmyk16, .gray_alpha8, .gray_alpha16,
};

/// This package's decoder with its default options, but asked for a CMYK
/// format, with `cmyk = .raw`: the inks as stored, which libjpeg-turbo
/// writes as JCS_CMYK. (The default reads a CMYK image as RGB, so its
/// `cmyk8` would be the naive conversion inverted.) Raw only for CMYK
/// formats, as a 12-bit image's raw `cmyk16` narrows to RGB at 16 bits,
/// not at the image's precision as the default and libjpeg-turbo do.
///
/// compare.zig reads each input from a fixed reader, which buffers all of
/// it, so the raw decoder reads the same bytes afresh.
pub const Decoder = struct {
    d: image.jpeg.Decoder,
    input: []const u8,
    options: Options,

    pub const Options = image.jpeg.Decoder.Options;
    pub const Error = image.jpeg.Decoder.Error;

    pub fn init(reader: *std.Io.Reader, options: Options) Decoder {
        return .{ .d = .init(reader, options), .input = reader.buffered(), .options = options };
    }

    /// The default decoder's configuration, with work memory for both:
    /// raw needs less at 8 bits, where it writes the inks without a row to
    /// convert them from, and more past them, where its native row has
    /// four channels to the default's three.
    pub fn decodeConfig(c: *Decoder) Error!image.Config {
        var config = try c.d.decodeConfig();
        var r: std.Io.Reader = .fixed(c.input);
        var d = c.rawDecoder(&r);
        config.work_len = @max(config.work_len, (try d.decodeConfig()).work_len);
        return config;
    }

    pub fn decodeFrame(c: *Decoder, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        if (!dst.format.isCmyk()) return c.d.decodeFrame(dst, work);
        var r: std.Io.Reader = .fixed(c.input);
        var d = c.rawDecoder(&r);
        _ = try d.decodeConfig();
        return d.decodeFrame(dst, work);
    }

    fn rawDecoder(c: *const Decoder, r: *std.Io.Reader) image.jpeg.Decoder {
        var options = c.options;
        options.cmyk = .raw;
        return .init(r, options);
    }
};

/// Whether `op`'s answer counts: Wuffs's only for 8-bit Huffman-coded DCT
/// images in 8-bit formats.
pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
    if (!std.mem.eql(u8, op, "jpeg-wuffs")) return true;
    if (format != .rgb8 and format != .gray8) return false;
    const sof = firstSof(input) orelse return true;
    return switch (sof.marker) {
        0xc0, 0xc1, 0xc2 => sof.precision == 8,
        else => false,
    };
}

const Sof = struct { marker: u8, precision: u8 };

/// The first SOF marker and its precision, walking the segments from SOI.
fn firstSof(input: []const u8) ?Sof {
    if (input.len < 4 or input[0] != 0xff or input[1] != 0xd8) return null;
    var at: usize = 2;
    while (at + 4 < input.len) {
        if (input[at] != 0xff) {
            at += 1;
            continue;
        }
        const m = input[at + 1];
        if (m == 0xff or m == 0 or m == 0x01 or (m >= 0xd0 and m <= 0xd8)) {
            at += if (m == 0xff) 1 else 2;
            continue;
        }
        if (m == 0xda or m == 0xd9) return null;
        if (m >= 0xc0 and m <= 0xcf and m != 0xc4 and m != 0xc8 and m != 0xcc) {
            return .{ .marker = m, .precision = input[at + 4] };
        }
        at += @as(usize, 2) + std.mem.readInt(u16, input[at + 2 ..][0..2], .big);
    }
    return null;
}

pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = op;
    _ = arena;
    return input;
}

/// `jpeg_gain_map`: `Metadata.gain_map` against libultrahdr's
/// `is_uhdr_image` (plan.md decision 64), as a one-byte gray8 image
/// (test/oracle/jpeg.c). Only the flag is compared: an input counts only
/// when this package reads its header.
///
/// The two read different images. This package reads the base image's
/// APPn segments and stops at its EOI: MPF, and the gain map XMP namespace
/// or ISO 21496-1's segment. libultrahdr ignores those: it finds the gain
/// map as the second JPEG in the file and parses that image's gain map
/// metadata (XMP or ISO 21496-1), and it rejects most damage to either
/// image's entropy-coded data or ICC profile. So on a damaged file the
/// answers part whenever the damage falls in one image and not the other,
/// as often as not on mutations of corpus/vendor/generated/jpeg/
/// ultrahdr-iso.jpg, and the expected splits are:
///
/// - A base image that declares a gain map with no second image after it,
///   or a broken one: this package sets the flag, libultrahdr does not.
/// - A second image with gain map metadata after a base image that does
///   not declare it (no MPF, or no XMP namespace or ISO segment): the
///   reverse.
///
/// So the comparison takes whole files only (`fuzz.mutates`): the corpus,
/// and files built as writers build them, where the base image declares a
/// gain map exactly when a gain map image follows.
pub const gain_map = struct {
    pub const name = "jpeg_gain_map";
    pub const Decoder = GainMapDecoder;
    pub const oracles = [_][]const u8{"jpeg-uhdr"};
    pub const formats = [_]image.PixelFormat{.gray8};

    pub fn comparable(op: []const u8, format: image.PixelFormat, input: []const u8) bool {
        _ = op;
        _ = format;
        var r: std.Io.Reader = .fixed(input);
        var d: GainMapDecoder = .init(&r, .{});
        _ = d.decodeConfig() catch return false;
        return true;
    }

    pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
        _ = op;
        _ = arena;
        return input;
    }

    /// The JPEG corpus, and two-image files: a base image and, but for a
    /// plain JPEG, a second one after it that MPF locates. The base image
    /// declares a gain map, by the XMP namespace, ISO 21496-1's segment, or
    /// both, exactly when the second image carries gain map metadata in
    /// the same forms; otherwise the second image is a plain preview, as
    /// cameras write, and the base image may carry unrelated XMP.
    /// `generate` runs under the comparison's lock, one input at a time,
    /// so its buffers are shared.
    pub const fuzz = struct {
        pub const corpus = jpeg_fuzz.corpus;
        pub const extensions = jpeg_fuzz.extensions;
        pub const mutates = false;
        var pixels: [32 * 32 * 3]u8 = undefined;
        var work: [1 << 16]u8 = undefined;
        var base: [1 << 14]u8 = undefined;
        var second: [1 << 14]u8 = undefined;

        const xmp = "http://ns.adobe.com/xap/1.0/\x00";
        const iso = "urn:iso:std:iso:ts:21496:-1\x00";
        const gm_ns = "http://ns.adobe.com/hdr-gain-map/1.0/";
        const rdf = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF " ++
            "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description ";
        const rdf_end = "/></rdf:RDF></x:xmpmeta>";
        /// The ISO 21496-1 gain map metadata libultrahdr 1.4 wrote for
        /// ultrahdr-iso.jpg, after its URN.
        const iso_metadata = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x24\xce" ++
            "\xa3\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x24\xce\xa3\x00\x10\x00" ++
            "\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00" ++
            "\x00\x00\x00\x00\x01";

        pub fn generate(random: std.Random, buf: []u8) []u8 {
            var out: std.Io.Writer = .fixed(buf);
            build(random, &out) catch unreachable;
            return out.buffered();
        }

        fn build(random: std.Random, out: *std.Io.Writer) !void {
            const be = std.builtin.Endian.big;
            const b = encodeRandom(random, &base);
            // 0: a plain JPEG; 1 and 2: a plain second image, after a base
            // image with no XMP or with unrelated XMP; 3 to 5: a gain map
            // in XMP, ISO 21496-1, or both.
            const kind = random.uintLessThan(u8, 6);
            if (kind == 0) return out.writeAll(b);
            const in_xmp = kind == 3 or kind == 5;
            const in_iso = kind == 4 or kind == 5;
            const s = encodeRandom(random, &second);
            // The base image's XMP and ISO segment bodies, in a random
            // order, with MPF at a random place among them.
            var segs: [2][]const u8 = undefined;
            var n: usize = 0;
            var xmp_buf: [512]u8 = undefined;
            const prefix = if (random.boolean()) "hdrgm" else "gm";
            if (in_xmp or kind == 2) {
                var w: std.Io.Writer = .fixed(&xmp_buf);
                try w.writeAll(xmp ++ rdf);
                if (in_xmp) {
                    try w.print("xmlns:{s}=\"{s}\" {s}:Version=\"1.0\"", .{ prefix, gm_ns, prefix });
                } else {
                    try w.writeAll("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"5\"");
                }
                try w.writeAll(rdf_end);
                segs[n] = w.buffered();
                n += 1;
            }
            if (in_iso) {
                segs[n] = iso ++ "\x00\x00\x00\x00";
                n += 1;
            }
            random.shuffle([]const u8, segs[0..n]);
            const mpf_at = random.uintAtMost(usize, n);
            // The second image's gain map metadata, which goes after its
            // SOI. libultrahdr reads its XMP only under the prefix hdrgm;
            // the base image's may be any.
            var meta_buf: [512]u8 = undefined;
            var meta: std.Io.Writer = .fixed(&meta_buf);
            if (in_xmp) {
                const body = xmp ++ rdf ++ "xmlns:hdrgm=\"" ++ gm_ns ++ "\" hdrgm:Version=\"1.0\" " ++
                    "hdrgm:GainMapMax=\"2.0\" hdrgm:HDRCapacityMax=\"2.0\"" ++ rdf_end;
                try meta.writeAll("\xff\xe1");
                try meta.writeInt(u16, 2 + body.len, be);
                try meta.writeAll(body);
            }
            if (in_iso) {
                const body = iso ++ iso_metadata;
                try meta.writeAll("\xff\xe2");
                try meta.writeInt(u16, 2 + body.len, be);
                try meta.writeAll(body);
            }
            const second_len = s.len + meta.buffered().len;
            // MPF (CIPA DC-007): a big-endian TIFF header, an IFD of the
            // version, the image count, and the MP entries, then the two
            // entries, whose offsets count from the TIFF header.
            const mpf_len = 4 + 8 + 2 + 3 * 12 + 4 + 2 * 16;
            var base_len = b.len + 4 + mpf_len;
            for (segs[0..n]) |x| base_len += 4 + x.len;
            var tiff_at: usize = 2 + 4 + 4;
            for (segs[0..mpf_at]) |x| tiff_at += 4 + x.len;

            try out.writeAll(b[0..2]);
            for (0..n + 1) |i| {
                if (i == mpf_at) {
                    try out.writeAll("\xff\xe2");
                    try out.writeInt(u16, 2 + mpf_len, be);
                    try out.writeAll("MPF\x00MM\x00\x2a\x00\x00\x00\x08\x00\x03");
                    try out.writeAll("\xb0\x00\x00\x07\x00\x00\x00\x040100");
                    try out.writeAll("\xb0\x01\x00\x04\x00\x00\x00\x01\x00\x00\x00\x02");
                    try out.writeAll("\xb0\x02\x00\x07\x00\x00\x00\x20");
                    try out.writeInt(u32, 8 + 2 + 3 * 12 + 4, be);
                    try out.writeInt(u32, 0, be);
                    try out.writeAll("\x00\x03\x00\x00");
                    try out.writeInt(u32, @intCast(base_len), be);
                    try out.writeAll(&@as([12]u8, @splat(0)));
                    try out.writeInt(u32, @intCast(second_len), be);
                    try out.writeInt(u32, @intCast(base_len - tiff_at), be);
                    try out.writeInt(u32, 0, be);
                }
                if (i == n) break;
                const marker: u8 = if (std.mem.startsWith(u8, segs[i], iso)) 0xe2 else 0xe1;
                try out.writeAll(&.{ 0xff, marker });
                try out.writeInt(u16, @intCast(2 + segs[i].len), be);
                try out.writeAll(segs[i]);
            }
            try out.writeAll(b[2..]);
            std.debug.assert(out.buffered().len == base_len);
            try out.writeAll(s[0..2]);
            try out.writeAll(meta.buffered());
            try out.writeAll(s[2..]);
        }

        /// A JPEG of random size, color, and pixels from this package's
        /// encoder.
        fn encodeRandom(random: std.Random, dst: []u8) []u8 {
            const w = 1 + random.uintLessThan(u32, 32);
            const h = 1 + random.uintLessThan(u32, 32);
            const format: image.PixelFormat = if (random.boolean()) .rgb8 else .gray8;
            const len = w * h * format.bytesPerPixel();
            random.bytes(pixels[0..len]);
            const src = image.PixelBuffer.init(pixels[0..len], format, w, h) catch unreachable;
            const options: image.jpeg.EncodeOptions = .{ .progressive = random.boolean() };
            var out: std.Io.Writer = .fixed(dst);
            image.jpeg.encode(&out, src, options, work[0..image.jpeg.workLen(options, w, h).?]) catch |e|
                std.debug.panic("jpeg_gain_map oracle: encode failed: {t}", .{e});
            return out.buffered();
        }
    };
};

const jpeg_fuzz = @import("fuzz").jpeg;

/// The JPEG `Decoder` whose one frame is `Metadata.gain_map`: one gray8
/// byte, 1 or 0.
const GainMapDecoder = struct {
    d: image.jpeg.Decoder,

    pub const Options = image.jpeg.Decoder.Options;
    pub const Error = image.jpeg.Decoder.Error;

    /// Without the caller's size limits: the flag comes from the header,
    /// and the frame is one byte, so an image past the harness's pixel
    /// limit is compared too, where libultrahdr has none.
    pub fn init(reader: *std.Io.Reader, options: Options) GainMapDecoder {
        var o = options;
        o.limits = .none;
        return .{ .d = .init(reader, o) };
    }

    pub fn decodeConfig(g: *GainMapDecoder) Error!image.Config {
        const c = try g.d.decodeConfig();
        return .{ .width = 1, .height = 1, .native = .gray8, .metadata = c.metadata };
    }

    pub fn decodeFrame(g: *GainMapDecoder, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        _ = work;
        dst.pixels[0] = @intFromBool((try g.decodeConfig()).metadata.gain_map);
        return .{ .width = 1, .height = 1 };
    }
};
