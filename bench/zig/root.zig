//! The Zig arm: this package's operations, run by the C arms' harness
//! (bench/c/arm.c) so that every arm times its calls and places its buffers
//! alike. Each file here lists one format's or family's operations as
//! `ops`, pairs of an operation name from bench/ops.tsv and a function
//! that writes `out` from `in` and returns the bytes written, or null.
//! One line per file below.

pub const bmp = @import("bmp.zig");
pub const convert = @import("convert.zig");
pub const ico = @import("ico.zig");
pub const gif = @import("gif.zig");
pub const jpeg = @import("jpeg.zig");
pub const png = @import("png.zig");
pub const png_encode = @import("png_encode.zig");
pub const qoi = @import("qoi.zig");
pub const tga = @import("tga.zig");
pub const netpbm = @import("netpbm.zig");
pub const wbmp = @import("wbmp.zig");
pub const webp = @import("webp.zig");
pub const webp_lossy_encode = @import("webp_lossy_encode.zig");
pub const tiff = @import("tiff.zig");
pub const jxl = @import("jxl.zig");
pub const jxl_jbrd = @import("jxl_jbrd.zig");
pub const webp_encode = @import("webp_encode.zig");
pub const tiff_encode = @import("tiff_encode.zig");
pub const jxl_encode = @import("jxl_encode.zig");
pub const resize = @import("resize.zig");

const Self = @This();

const Fn = *const fn (in: [*]const u8, len: usize, out: [*]u8, cap: usize) callconv(.c) usize;
extern fn bench_register(op: [*:0]const u8, f: Fn) void;

fn benchInit() callconv(.c) void {
    inline for (@typeInfo(Self).@"struct".decl_names) |name| {
        const table = @field(Self, name);
        if (@TypeOf(table) == type and @hasDecl(table, "ops")) {
            inline for (table.ops) |op| bench_register(op[0], wrap(op[1]));
        }
    }
}

comptime {
    @export(&benchInit, .{ .name = "bench_init" });
}

fn wrap(comptime f: fn (in: []const u8, out: []u8) ?usize) Fn {
    return struct {
        fn call(in: [*]const u8, len: usize, out: [*]u8, cap: usize) callconv(.c) usize {
            return f(in[0..len], out[0..cap]) orelse 0;
        }
    }.call;
}
