//! JPEG (ITU T.81, with T.871's JFIF and Adobe's APP14): decode.
//! Encoding comes later.

pub const Decoder = @import("Decoder.zig");

test {
    _ = Decoder;
    _ = @import("huffman.zig");
    _ = @import("idct.zig");
    _ = @import("sample.zig");
    _ = @import("simd.zig");
}
