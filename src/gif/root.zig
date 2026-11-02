//! GIF (GIF87a and GIF89a, with the NETSCAPE2.0 loop count): decode, still
//! and animated; encode GIF89a stills and animations from any pixel
//! format, quantizing frames with more than 256 colors.

const encoder = @import("encode.zig");

pub const Decoder = @import("Decoder.zig");
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.EncodeError;
pub const AnimationFrame = encoder.AnimationFrame;
pub const Quantizer = encoder.Quantizer;
pub const Dither = encoder.Dither;
pub const workLen = encoder.workLen;
pub const encode = encoder.encode;
pub const encodeAnimation = encoder.encodeAnimation;

test {
    _ = Decoder;
    _ = encoder;
    _ = @import("lzw.zig");
    _ = @import("lzw_encode.zig");
    _ = @import("quantize.zig");
}
