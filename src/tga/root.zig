//! TGA (Truevision TGA, Targa), version 2.0 and the original format:
//! decode every image type, encode true-color and gray, uncompressed or
//! run-length encoded.

const encoder = @import("encode.zig");

pub const Decoder = @import("Decoder.zig");
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.EncodeError;
pub const workLen = encoder.workLen;
pub const encode = encoder.encode;

test {
    _ = Decoder;
    _ = encoder;
}
