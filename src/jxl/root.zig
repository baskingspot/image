//! JPEG XL (ISO/IEC 18181-1 and -2): decode. Encoding comes later.

pub const Decoder = @import("Decoder.zig");
pub const JpegReconstructor = @import("JpegReconstructor.zig");
pub const encode = @import("encode.zig").encode;
pub const workLen = @import("encode.zig").workLen;
pub const EncodeOptions = @import("encode.zig").EncodeOptions;
pub const EncodeError = @import("encode.zig").EncodeError;
pub const Effort = @import("encode.zig").Effort;

test {
    _ = Decoder;
    _ = JpegReconstructor;
    _ = @import("BitReader.zig");
    _ = @import("container.zig");
    _ = @import("headers.zig");
    _ = @import("entropy.zig");
    _ = @import("Arena.zig");
    _ = @import("modular.zig");
    _ = @import("frame.zig");
    _ = @import("icc.zig");
    _ = @import("dct.zig");
    _ = @import("quant.zig");
    _ = @import("filters.zig");
    _ = @import("vardct.zig");
    _ = @import("color.zig");
    _ = @import("upsample.zig");
    _ = @import("noise.zig");
    _ = @import("patches.zig");
    _ = @import("splines.zig");
    _ = @import("jbrd.zig");
    _ = @import("encode_bits.zig");
    _ = @import("encode_entropy.zig");
    _ = @import("encode_modular.zig");
    _ = @import("encode.zig");
}
