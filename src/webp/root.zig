//! WebP (RFC 9649): decode. Lossless and lossy still images with alpha
//! now; animation comes next, and encoding later.

pub const Decoder = @import("Decoder.zig");

test {
    _ = Decoder;
    _ = @import("lossless.zig");
    _ = @import("vp8.zig");
    _ = @import("alpha.zig");
    _ = @import("yuv.zig");
}
