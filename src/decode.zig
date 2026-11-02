//! What every decoder shares: the options and limits a caller sets, the
//! image and frame descriptions a decoder reports, the metadata it finds,
//! and the errors common to every format.
//!
//! Each format's `Decoder` has the same shape:
//!
//!     var d = image.qoi.Decoder.init(&reader, .{});
//!     const config = try d.decodeConfig();
//!     // Allocate PixelBuffer.len(format, config.width, config.height)
//!     // bytes of pixels and config.work_len bytes of work memory.
//!     while (try d.decodeFrame(pixels, work)) |frame| { ... }
//!
//! `decodeFrameConfig` returns the next frame before `decodeFrame` draws
//! it, for a caller that must save the region a `previous` disposal
//! restores; formats with at most one frame may leave it out, and
//! `image.Decoder` serves it for them.
//!
//! Nothing allocates: the caller owns every buffer.

const std = @import("std");
const testing = std.testing;

const PixelFormat = @import("pixel.zig").PixelFormat;

/// The smallest reader buffer a decoder accepts. Decoders peek at most
/// this many bytes at once, so `std.Io.Reader.peek` can serve them.
pub const min_buffer_len = 64;

/// Limits the caller sets before any work. A file over a limit fails with
/// an error before the decoder writes pixels or uses work memory, so a
/// caller that sizes buffers from `Config` never allocates more than these
/// allow.
pub const Limits = struct {
    max_width: u32 = 0xFF_FFFF,
    max_height: u32 = 0xFF_FFFF,
    /// The most pixels in one frame (and in the canvas).
    max_pixels: u64 = 1 << 28,
    /// The most frames an animated or multi-page file may have.
    max_frames: u32 = 1 << 16,
    /// The most work memory a decoder may ask for in `Config.work_len`.
    max_work: usize = 1 << 30,

    /// No limits beyond what the format and `usize` impose.
    pub const none: Limits = .{
        .max_width = std.math.maxInt(u32),
        .max_height = std.math.maxInt(u32),
        .max_pixels = std.math.maxInt(u64),
        .max_frames = std.math.maxInt(u32),
        .max_work = std.math.maxInt(usize),
    };

    /// Fails if a `width` by `height` image is over a limit.
    pub fn checkSize(l: Limits, width: u32, height: u32) error{ImageTooLarge}!void {
        if (width > l.max_width or height > l.max_height) return error.ImageTooLarge;
        if (@as(u64, width) * height > l.max_pixels) return error.ImageTooLarge;
    }

    /// Fails if a file with `count` frames is over the frame limit.
    pub fn checkFrames(l: Limits, count: u64) error{TooManyFrames}!void {
        if (count > l.max_frames) return error.TooManyFrames;
    }

    /// Fails if `len` bytes of work memory is over the work limit.
    pub fn checkWork(l: Limits, len: u64) error{WorkTooLarge}!void {
        if (len > l.max_work) return error.WorkTooLarge;
    }
};

/// Options every decoder takes. A format with more options has its own
/// `Options` with `limits` and `blob_sink`, `seeker` if it can move back,
/// and its own after them; `image.Decoder` passes on the fields it has.
pub const Options = struct {
    limits: Limits = .{},
    /// Receives the bytes of each metadata blob (ICC profile, EXIF, XMP) as
    /// the decoder reads past it; see `BlobSink`.
    blob_sink: ?BlobSink = null,
    /// Lets a format whose offsets can point behind the reader (ICO's
    /// directory, TIFF's IFDs) move back; see `Seeker`. Formats read
    /// forward without one, and those that never move back ignore it or
    /// lack the field.
    seeker: ?Seeker = null,
};

/// A caller's way to move the input reader to any byte of the input, for
/// formats that store offsets. The decoder still reads forward wherever it
/// can, skipping gaps with `discard`, and calls `seek` only for data behind
/// its position; without a seeker that data is the format's error.
///
/// `seek(offset)` must leave the reader the decoder was given so that its
/// next byte is the input's byte `offset`, and drop whatever it had
/// buffered. `offset` counts from the input's first byte: the reader's
/// next byte when the decoder was made, before the decoder read anything.
/// An offset past the input's end is not an error here: the reader then
/// reports end of stream and the decoder `Truncated`. `seek` fails with
/// `ReadFailed` only when the source cannot move.
pub const Seeker = struct {
    context: *anyopaque,
    seek: *const fn (context: *anyopaque, offset: u64) error{ReadFailed}!void,

    /// For a reader made by `std.Io.Reader.fixed` over the whole input,
    /// before any of it was consumed. A caller holding the file in memory
    /// gets seeking without a copy.
    pub fn fixed(r: *std.Io.Reader) Seeker {
        return .{ .context = r, .seek = seekFixed };
    }

    /// For a file reader whose byte 0 is the input's first byte.
    pub fn file(r: *std.Io.File.Reader) Seeker {
        return .{ .context = r, .seek = seekFile };
    }

    fn seekFixed(context: *anyopaque, offset: u64) error{ReadFailed}!void {
        const r: *std.Io.Reader = @ptrCast(@alignCast(context));
        r.seek = @intCast(@min(offset, r.end));
    }

    fn seekFile(context: *anyopaque, offset: u64) error{ReadFailed}!void {
        const r: *std.Io.File.Reader = @ptrCast(@alignCast(context));
        r.seekTo(offset) catch return error.ReadFailed;
    }
};

/// The errors every decoder can return. Each format's error set is these
/// plus its own specific causes.
pub const Error = error{
    /// The input reader failed. Its own error is in the reader.
    ReadFailed,
    /// The input ended before the image did.
    Truncated,
    /// The input does not start with this format's signature.
    BadSignature,
    /// A header field has a value the format does not allow.
    BadHeader,
    /// A feature the format allows that this decoder does not support.
    Unsupported,
    /// The image is wider, taller, or larger than `Limits` allow.
    ImageTooLarge,
    /// The file has more frames than `Limits.max_frames`.
    TooManyFrames,
    /// The decode needs more work memory than `Limits.max_work`.
    WorkTooLarge,
    /// The work buffer is shorter than `Config.work_len`.
    WorkTooSmall,
    /// The pixel buffer is smaller than its dimensions need.
    BufferTooSmall,
    /// The pixel buffer's dimensions are not the canvas's.
    SizeMismatch,
};

/// The image as its header describes it, from `decodeConfig`.
pub const Config = struct {
    /// The canvas: the size of the pixel buffer `decodeFrame` writes.
    width: u32,
    height: u32,
    /// The format that holds the source's pixels without loss and is
    /// cheapest to write: ask for it to skip conversion.
    native: PixelFormat,
    /// The number of frames, or null when the header does not say, or says
    /// more than `Limits.max_frames`, which then counts frames as they are
    /// reached.
    frame_count: ?u32 = null,
    /// How many times an animation plays (0: forever), or null for a
    /// still image.
    loop_count: ?u32 = null,
    /// Bytes of work memory `decodeFrame` needs.
    work_len: usize = 0,
    /// Whether the header promises every pixel is opaque.
    is_opaque: bool = false,
    /// The background color the file names, straight RGBA, if any.
    background: ?[4]u8 = null,
    /// What the decoder found before the first frame. What follows the
    /// frames updates this and `background` in `image.Decoder.finalConfig`.
    metadata: Metadata = .{},
};

/// The flick, 1 / 705,600,000 of a second, divides every common frame
/// rate and media timebase exactly. `Frame.duration` counts them.
pub const flicks_per_second = 705_600_000;

/// One frame, from `decodeFrame`.
pub const Frame = struct {
    /// 0 for the first frame.
    index: u32 = 0,
    /// The region of the canvas this frame wrote.
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
    /// How long to show this frame, in flicks; 0 for a still image.
    duration: u64 = 0,
    /// What to do with this frame's region before the next frame.
    disposal: Disposal = .none,
    /// How this frame was combined with the canvas.
    blend: Blend = .src,
    /// Whether every pixel in the region is opaque.
    is_opaque: bool = false,

    pub const Disposal = enum {
        /// Leave the frame on the canvas.
        none,
        /// Clear the region to transparent (or the background color).
        background,
        /// Restore the region to what it was before this frame.
        previous,
    };

    pub const Blend = enum {
        /// The frame replaced the region's pixels.
        src,
        /// The frame was composited over the region with its alpha.
        src_over,
    };
};

/// Metadata a decoder reports and never applies.
pub const Metadata = struct {
    /// From EXIF (see `exif.orientation`) or the format's own field.
    orientation: Orientation = .top_left,
    /// The transfer function the file names, if any. A plain power law is
    /// `gamma` instead.
    transfer: ?Transfer = null,
    /// The file's gamma times 100,000, if any: the exponent that encoded
    /// linear light, so 45455 is 1/2.2 (PNG gAMA, a JPEG XL gamma, TGA's
    /// extension area). PNG may state it beside an sRGB `transfer`.
    gamma: ?u32 = null,
    /// CIE 1931 xy chromaticities of the red, green, and blue primaries
    /// and the white point, in that order (PNG cHRM, JPEG XL's color
    /// encoding).
    primaries: ?[8]f32 = null,
    /// The luminance in nits (cd/m²) that a sample of 1.0 stands for, as
    /// JPEG XL states it for HDR images.
    intensity_target: ?f32 = null,
    /// The ITU-T H.273 code points the file states (PNG cICP), as stored.
    /// They take precedence over an ICC profile, `gamma`, and the other
    /// color chunks: `transfer`, `gamma`, and `primaries` then come from
    /// them alone, and are null for code points they cannot name.
    cicp: ?Cicp = null,
    /// The display the image was mastered on (PNG mDCV).
    mastering_display: ?MasteringDisplay = null,
    /// The brightest pixel and brightest frame average (PNG cLLI).
    content_light_level: ?ContentLightLevel = null,
    /// The file carries a JPEG XL `jbrd` box: the original JPEG can be
    /// rebuilt with `image.jxl.JpegReconstructor`.
    jpeg_reconstruction: bool = false,
    density: ?Density = null,
    icc: ?Blob = null,
    exif: ?Blob = null,
    xmp: ?Blob = null,

    /// ITU-T H.273's video signal type code points.
    pub const Cicp = struct {
        /// ColourPrimaries: 1 is BT.709 and sRGB, 9 BT.2020, 12 Display P3.
        primaries: u8,
        /// TransferCharacteristics: 13 is sRGB, 16 PQ, 18 HLG.
        transfer: u8,
        /// MatrixCoefficients: 0, RGB, in PNG.
        matrix: u8,
        /// Whether samples use their full range; false is narrow (video)
        /// range, such as 16 to 235 at 8 bits, which is not rescaled.
        full_range: bool,
    };

    pub const MasteringDisplay = struct {
        /// CIE 1931 xy of its red, green, and blue primaries and white
        /// point, in that order, as `Metadata.primaries`.
        primaries: [8]f32,
        /// Its luminance range, in nits (cd/m²).
        min_luminance: f32,
        max_luminance: f32,
    };

    /// In nits (cd/m²); 0 when unknown.
    pub const ContentLightLevel = struct {
        /// MaxCLL: the brightest pixel's light level.
        max_cll: f32,
        /// MaxFALL: the brightest frame's average light level.
        max_fall: f32,
    };
};

/// How to rotate or flip the stored pixels for display: EXIF orientation
/// 1 to 8, named by where the stored first row and column belong.
pub const Orientation = enum(u3) {
    top_left = 0,
    top_right,
    bottom_right,
    bottom_left,
    left_top,
    right_top,
    right_bottom,
    left_bottom,

    /// From an EXIF or TIFF orientation value, 1 to 8.
    pub fn fromExif(v: u16) ?Orientation {
        if (v < 1 or v > 8) return null;
        return @enumFromInt(v - 1);
    }

    pub fn toExif(o: Orientation) u16 {
        return @as(u16, @intFromEnum(o)) + 1;
    }
};

/// A named transfer function, from encoded samples to linear light.
pub const Transfer = enum {
    /// IEC 61966-2-1.
    srgb,
    linear,
    /// ITU-R BT.709 (and BT.601 and BT.2020's SDR curve).
    bt709,
    /// DCI-P3's power law, 1/2.6.
    dci,
    /// SMPTE ST 2084's perceptual quantizer (BT.2100 PQ).
    pq,
    /// BT.2100's hybrid log-gamma.
    hlg,
};

pub const Density = struct {
    x: u32,
    y: u32,
    unit: Unit,

    pub const Unit = enum {
        /// Only the aspect ratio is known.
        none,
        per_inch,
        per_meter,
    };
};

/// A metadata blob: where it starts in the input, counted in bytes from
/// the first byte the decoder read, and its length.
///
/// Most formats store a blob as one span of the input, and `offset` and
/// `len` give that span (compressed if `encoding` says so). A format that
/// splits it into pieces with other bytes between them, as GIF's
/// sub-blocks do, reports the payload: `len` counts the payload bytes the
/// blob sink receives, and `offset` is where the first of them is in the
/// input, so the blob cannot be read back as one span from there.
pub const Blob = struct {
    kind: Kind,
    offset: u64,
    /// The length, or null while a format that learns it only at the
    /// blob's end is still passing the blob to the sink. A `Blob` in
    /// `Metadata` always has it.
    len: ?u64,
    encoding: Encoding = .raw,

    pub const Kind = enum { icc, exif, xmp };
    pub const Encoding = enum { raw, zlib, brotli };

    /// Whether a piece of `n` bytes at `at`, passed with this blob, is the
    /// blob's last.
    pub fn endsAt(b: Blob, at: u64, n: usize) bool {
        return if (b.len) |len| at + n == len else false;
    }
};

/// A caller's receiver for metadata blobs. The decoder calls `write` with
/// each blob's bytes in order, in as many pieces as it reads them: `at` is
/// the piece's offset in the blob, so a piece with `at == 0` starts a blob
/// and one for which `blob.endsAt(at, bytes.len)` ends it. A format that
/// knows the length passes it with every piece; one that learns it only at
/// the end passes `blob.len` null until the last piece, which may be empty.
/// The sink copies what it wants; the bytes are gone after it returns.
pub const BlobSink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, blob: Blob, at: u64, bytes: []const u8) void,

    pub fn put(s: BlobSink, blob: Blob, at: u64, bytes: []const u8) void {
        s.write(s.context, blob, at, bytes);
    }
};

test "limits" {
    const l: Limits = .{ .max_width = 10, .max_height = 20, .max_pixels = 100 };
    try l.checkSize(10, 10);
    try testing.expectError(error.ImageTooLarge, l.checkSize(11, 1));
    try testing.expectError(error.ImageTooLarge, l.checkSize(1, 21));
    try testing.expectError(error.ImageTooLarge, l.checkSize(10, 11));
    try Limits.none.checkSize(std.math.maxInt(u32), std.math.maxInt(u32));
    try testing.expectError(error.TooManyFrames, (Limits{ .max_frames = 2 }).checkFrames(3));
    try testing.expectError(error.WorkTooLarge, (Limits{ .max_work = 2 }).checkWork(3));
}

test "a blob ends on its last piece, known only there or all along" {
    const known: Blob = .{ .kind = .icc, .offset = 10, .len = 5 };
    try testing.expect(!known.endsAt(0, 3));
    try testing.expect(known.endsAt(3, 2));
    try testing.expect(known.endsAt(5, 0));
    var late: Blob = .{ .kind = .xmp, .offset = 10, .len = null };
    try testing.expect(!late.endsAt(0, 5));
    late.len = 5;
    try testing.expect(late.endsAt(5, 0));
}

test "orientation" {
    try testing.expectEqual(Orientation.top_left, Orientation.fromExif(1).?);
    try testing.expectEqual(Orientation.left_bottom, Orientation.fromExif(8).?);
    try testing.expectEqual(null, Orientation.fromExif(0));
    try testing.expectEqual(null, Orientation.fromExif(9));
    for (1..9) |v| try testing.expectEqual(v, Orientation.fromExif(@intCast(v)).?.toExif());
}
