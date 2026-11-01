//! PNG and APNG (the PNG specification, third edition): decode. Encoding
//! comes later.

pub const Decoder = @import("Decoder.zig");

test {
    _ = Decoder;
    _ = @import("filter.zig");
    _ = @import("crc32.zig");
}
