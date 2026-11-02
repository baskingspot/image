//! TIFF and BigTIFF: decode every page, with strips or tiles, uncompressed
//! or compressed with PackBits, LZW, Deflate, or CCITT Group 3 or 4. Data
//! stored behind the reader, which most writers produce, needs an `image.Seeker`.

const decoder = @import("Decoder.zig");

pub const Decoder = decoder;

test {
    _ = decoder;
    _ = @import("ifd.zig");
    _ = @import("lzw.zig");
    _ = @import("packbits.zig");
    _ = @import("fax.zig");
    _ = @import("samples.zig");
}
