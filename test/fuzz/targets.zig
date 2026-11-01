//! The fuzz targets, one line per target. Each is a file with `name`,
//! `corpus` (seed directories), `extensions`, `seeds`, `check(input,
//! choice)`, and `generate(random, buf)`; test/fuzz/qoi.zig is the model.

const std = @import("std");

pub const harness = @import("harness.zig");

pub const bmp = @import("bmp.zig");
pub const bmp_encode = @import("bmp_encode.zig");
pub const ico = @import("ico.zig");
pub const ico_encode = @import("ico_encode.zig");
pub const png = @import("png.zig");
pub const qoi = @import("qoi.zig");
pub const tga = @import("tga.zig");
pub const tga_encode = @import("tga_encode.zig");
pub const netpbm = @import("netpbm.zig");
pub const netpbm_encode = @import("netpbm_encode.zig");

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
