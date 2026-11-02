//! WebP (RFC 9649): decode. Lossless images now; lossy, alpha, and
//! animation come next, and encoding later.

pub const Decoder = @import("Decoder.zig");

test {
    _ = Decoder;
    _ = @import("lossless.zig");
}
