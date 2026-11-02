//! TIFF and BigTIFF: decode every page, with strips or tiles, uncompressed
//! or compressed with PackBits, LZW, Deflate, or CCITT Group 3 or 4. Data
//! stored behind the reader, which most writers produce, needs an `image.Seeker`.

const decoder = @import("Decoder.zig");
const encoder = @import("encode.zig");

pub const Decoder = decoder;
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.EncodeError;
pub const Compression = encoder.Compression;
pub const Effort = encoder.Effort;
pub const workLen = encoder.workLen;
pub const encode = encoder.encode;
pub const encodePages = encoder.encodePages;

test {
    _ = decoder;
    _ = encoder;
    _ = @import("encode_lzw.zig");
    _ = @import("encode_packbits.zig");
    _ = @import("ifd.zig");
    _ = @import("lzw.zig");
    _ = @import("packbits.zig");
    _ = @import("fax.zig");
    _ = @import("samples.zig");
}
