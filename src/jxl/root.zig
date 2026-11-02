//! JPEG XL (ISO/IEC 18181-1 and -2): decode. Encoding comes later.

pub const Decoder = @import("Decoder.zig");

test {
    _ = Decoder;
    _ = @import("BitReader.zig");
    _ = @import("container.zig");
    _ = @import("headers.zig");
    _ = @import("entropy.zig");
    _ = @import("Arena.zig");
    _ = @import("modular.zig");
    _ = @import("frame.zig");
    _ = @import("icc.zig");
}
