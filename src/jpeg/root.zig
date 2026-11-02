//! JPEG (ITU T.81, with T.871's JFIF and Adobe's APP14): decode, and
//! encode baseline or progressive.

const encoder = @import("encode.zig");

pub const Decoder = @import("Decoder.zig");
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.EncodeError;
pub const Subsampling = encoder.Subsampling;
pub const workLen = encoder.workLen;
pub const encode = encoder.encode;

test {
    _ = Decoder;
    _ = encoder;
    _ = @import("arith.zig");
    _ = @import("fdct.zig");
    _ = @import("huffman.zig");
    _ = @import("huffman_encode.zig");
    _ = @import("idct.zig");
    _ = @import("sample.zig");
    _ = @import("simd.zig");
}
