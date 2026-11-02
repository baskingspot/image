//! PNG and APNG (the PNG specification, third edition): decode, and encode
//! with filter selection, palette and gray reduction, and APNG frames.

pub const Decoder = @import("Decoder.zig");

const encoder = @import("encode.zig");
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.EncodeError;
pub const encode = encoder.encode;
pub const encodeAnimation = encoder.encodeAnimation;
pub const AnimationFrame = encoder.AnimationFrame;
pub const workLen = encoder.workLen;

test {
    _ = Decoder;
    _ = @import("filter.zig");
    _ = @import("crc32.zig");
    _ = encoder;
}
