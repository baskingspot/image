//! GIF (GIF87a and GIF89a, with the NETSCAPE2.0 loop count): decode, still
//! and animated. Encoding comes later.

pub const Decoder = @import("Decoder.zig");

test {
    _ = Decoder;
    _ = @import("lzw.zig");
}
