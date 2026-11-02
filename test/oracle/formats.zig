//! The formats with oracles, one line each: the Zig side of each format's
//! oracles (test/oracle/qoi.zig is the model).

pub const bmp = @import("bmp.zig");
pub const ico = @import("ico.zig");
pub const gif = @import("gif.zig");
pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");
pub const qoi = @import("qoi.zig");
pub const qoi_encode = @import("qoi_encode.zig");
pub const tga = @import("tga.zig");
pub const netpbm = @import("netpbm.zig");
pub const wbmp = @import("wbmp.zig");
pub const webp = @import("webp.zig");
