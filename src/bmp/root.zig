//! BMP, the Windows and OS/2 bitmap: decode, and encode as 24-bit, 32-bit
//! with alpha, or 8-bit with a color table.

pub const Decoder = @import("Decoder.zig");

const encoder = @import("encode.zig");
pub const EncodeOptions = encoder.Options;
pub const EncodeError = encoder.Error;
pub const encode = encoder.encode;
pub const workLen = encoder.workLen;

test {
    _ = Decoder;
    _ = encoder;
    _ = @import("dib.zig");
}
