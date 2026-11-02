//! WebP (RFC 9649): decode. Lossless and lossy still images with alpha
//! now; animation comes next, and encoding later.

pub const Decoder = @import("Decoder.zig");
pub const lossy = @import("vp8_encode.zig");

const encoder = @import("encode.zig");
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.EncodeError;
pub const workLen = encoder.workLen;
pub const encode = encoder.encode;
pub const encodeAlpha = encoder.encodeAlpha;

test {
    _ = Decoder;
    _ = encoder;
    _ = @import("encode_codes.zig");
    _ = @import("encode_lz77.zig");
    _ = @import("encode_transform.zig");
    _ = @import("encode_entropy.zig");
    _ = @import("lossless.zig");
    _ = @import("vp8.zig");
    _ = @import("alpha.zig");
    _ = @import("yuv.zig");
    _ = lossy;
}
