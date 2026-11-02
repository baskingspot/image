//! The fuzz targets, one line per target. Each is a file with `name`,
//! `corpus` (seed directories), `extensions`, `seeds`, `check(input,
//! choice)`, and `generate(random, buf)`; test/fuzz/qoi.zig is the model.

const std = @import("std");

pub const harness = @import("harness.zig");

pub const bmp = @import("bmp.zig");
pub const bmp_encode = @import("bmp_encode.zig");
pub const ico = @import("ico.zig");
pub const ico_encode = @import("ico_encode.zig");
pub const gif = @import("gif.zig");
pub const gif_encode = @import("gif_encode.zig");
pub const png = @import("png.zig");
pub const png_encode = @import("png_encode.zig");
pub const jpeg = @import("jpeg.zig");
pub const jpeg_encode = @import("jpeg_encode.zig");
pub const qoi = @import("qoi.zig");
pub const qoi_encode = @import("qoi_encode.zig");
pub const tiff = @import("tiff.zig");
pub const tiff_encode = @import("tiff_encode.zig");
pub const tga = @import("tga.zig");
pub const tga_encode = @import("tga_encode.zig");
pub const netpbm = @import("netpbm.zig");
pub const netpbm_encode = @import("netpbm_encode.zig");
pub const wbmp = @import("wbmp.zig");
pub const wbmp_encode = @import("wbmp_encode.zig");
pub const webp = @import("webp.zig");
pub const jxl = @import("jxl.zig");
pub const jxl_jbrd = @import("jxl_jbrd.zig");
pub const webp_encode = @import("webp_encode.zig");
pub const jxl_encode = @import("jxl_encode.zig");

const Self = @This();

/// Every target: the declarations above with a `check`.
pub const all: []const type = blk: {
    const decls = @typeInfo(Self).@"struct".decls;
    var list: [decls.len]type = undefined;
    var n: usize = 0;
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, "all")) continue;
        const target = @field(Self, d.name);
        if (@TypeOf(target) == type and @hasDecl(target, "check")) {
            list[n] = target;
            n += 1;
        }
    }
    const final = list[0..n].*;
    break :blk &final;
};
