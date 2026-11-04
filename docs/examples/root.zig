//! Every example the guide shows. `zig build test` compiles and runs these
//! against the public module, so the guide cannot show code that does not
//! build.

const std = @import("std");

pub const decode = @import("decode.zig");
pub const detect = @import("detect.zig");
pub const pixels = @import("pixels.zig");
pub const encode = @import("encode.zig");
pub const metadata = @import("metadata.zig");

test {
    std.testing.refAllDecls(@This());
}
