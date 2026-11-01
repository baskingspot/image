//! Image decoders and encoders in Zig with no C. Nothing allocates: callers
//! own every buffer. Each format is a namespace with a `Decoder`, and an
//! `encode` once it has an encoder (see `EncodeError`); `Decoder` here
//! decodes any of them, and `detect` names a file's format.

const std = @import("std");

pub const pixel = @import("pixel.zig");
pub const PixelFormat = pixel.PixelFormat;
pub const PixelBuffer = pixel.PixelBuffer;
pub const convert = @import("convert.zig");

const decode = @import("decode.zig");
pub const Config = decode.Config;
pub const Frame = decode.Frame;
pub const Limits = decode.Limits;
pub const DecodeOptions = decode.Options;
pub const DecodeError = decode.Error;
pub const Metadata = decode.Metadata;
pub const Orientation = decode.Orientation;
pub const Transfer = decode.Transfer;
pub const Chromaticities = decode.Chromaticities;
pub const Density = decode.Density;
pub const Blob = decode.Blob;
pub const BlobSink = decode.BlobSink;
pub const flicks_per_second = decode.flicks_per_second;
pub const min_buffer_len = decode.min_buffer_len;
pub const exif = @import("exif.zig");
pub const EncodeError = @import("encode.zig").Error;

const detection = @import("detect.zig");
pub const Format = detection.Format;
pub const detect = detection.detect;
pub const detect_prefix_len = detection.prefix_len;

pub const Decoder = @import("Decoder.zig");

// The formats, one line each.
pub const qoi = @import("qoi/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = decode;
    _ = detection;
    _ = @import("compress");
}
