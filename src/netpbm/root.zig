//! Netpbm (netpbm.sourceforge.net/doc): PBM, PGM, and PPM, plain and raw;
//! PAM; and PFM, decode and encode. A raw file holding several images
//! decodes them as frames.

const enc = @import("encode.zig");

pub const Decoder = @import("Decoder.zig");
pub const Kind = enc.Kind;
pub const EncodeOptions = enc.EncodeOptions;
pub const EncodeError = enc.EncodeError;
pub const workLen = enc.workLen;
pub const encode = enc.encode;

test {
    _ = Decoder;
    _ = enc;
}
