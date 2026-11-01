//! ICO and CUR, Windows icons and cursors: decode every entry, with BMP or
//! PNG data, and encode BMP entries. PNG entries decode through
//! `image.png` when the build has it; writing them waits for the PNG
//! encoder.

const image = @import("../root.zig");
const decoder = @import("Decoder.zig");

pub const Decoder = decoder.Generic(if (@hasDecl(image, "png")) image.png.Decoder else void);
pub const Entry = decoder.Entry;
pub const max_entries = decoder.max_entries;

const encoder = @import("encode.zig");
pub const EncodeOptions = encoder.Options;
pub const EncodeError = encoder.Error;
pub const Image = encoder.Image;
pub const encode = encoder.encode;
pub const encodeAll = encoder.encodeAll;
pub const workLen = encoder.workLen;

test {
    _ = decoder;
    _ = encoder;
}
