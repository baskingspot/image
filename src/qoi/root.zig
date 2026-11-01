//! QOI, the Quite OK Image format (qoiformat.org): decode and encode.

pub const Decoder = @import("Decoder.zig");

const encoder = @import("encode.zig");
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.EncodeError;
pub const workLen = encoder.workLen;
pub const encode = encoder.encode;

test {
    _ = Decoder;
    _ = encoder;
}
