//! VarDCT's dequantization matrices (ISO/IEC 18181-1, the HF global
//! section's dequantization tables): the 17 tables' encodings, read from
//! the stream or the defaults, and the weights computed from them. A
//! coefficient dequantizes as `quantized * multiplier`, the multiplier
//! being the reciprocal of the table's weight at that position.

const std = @import("std");
const testing = std.testing;

const BitReader = @import("BitReader.zig");
const Arena = @import("Arena.zig");
const modular = @import("modular.zig");

pub const Error = modular.Error;

pub const num_tables = 17;
/// Each table's size in 8 by 8 blocks: rows of the stored layout.
pub const size_x = [num_tables]u8{ 1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16 };
/// Columns of the stored layout.
pub const size_y = [num_tables]u8{ 1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32 };

const max_bands = 17;
const almost_zero: f32 = 1e-8;

pub const DctParams = struct {
    n: u32,
    bands: [3][max_bands]f32,
};

fn b(comptime v: anytype) [max_bands]f32 {
    var out: [max_bands]f32 = @splat(0);
    inline for (v, 0..) |x, i| out[i] = x;
    return out;
}

pub const Encoding = union(enum) {
    identity: [3][3]f32,
    dct2: [3][6]f32,
    dct4: struct { params: DctParams, mul: [3][2]f32 },
    dct4x8: struct { params: DctParams, mul: [3]f32 },
    afv: struct { p4x8: DctParams, p4x4: DctParams, w: [3][9]f32 },
    dct: DctParams,
    /// Weights `1 / (den * table[i])`, the table in work memory.
    raw: struct { den: f32, table: []const i32 },
};

/// The default LF (DC) quantization steps.
pub const default_dc_quant = [3]f32{ 1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0 };

fn readDctParams(br: *BitReader) Error!DctParams {
    var p: DctParams = .{ .n = try br.bits(4) + 1, .bands = @splat(@splat(0)) };
    for (&p.bands) |*c| {
        for (c[0..p.n]) |*v| v.* = try br.f16Field();
        if (c[0] < almost_zero) return error.BadImage;
        c[0] *= 64;
    }
    return p;
}

pub const Context = struct {
    /// The frame's modular tree, for raw tables.
    tree: ?*const modular.Tree,
    /// Stream ID of table 0's raw encoding.
    first_stream: u32,
};

/// Reads the 17 encodings (the all-default flag first).
pub fn read(br: *BitReader, arena: *Arena, ctx: Context, out: *[num_tables]Encoding) Error!void {
    if (try br.boolean()) {
        out.* = defaults;
        return;
    }
    for (out, 0..) |*e, i| {
        const one = size_x[i] == 1 and size_y[i] == 1;
        const mode = try br.bits(3);
        e.* = switch (mode) {
            0 => defaults[i],
            1 => blk: {
                if (!one) return error.BadImage;
                var w: [3][3]f32 = undefined;
                for (&w) |*c| for (c) |*v| {
                    v.* = try br.f16Field();
                    if (@abs(v.*) < almost_zero) return error.BadImage;
                    v.* *= 64;
                };
                break :blk .{ .identity = w };
            },
            2 => blk: {
                if (!one) return error.BadImage;
                var w: [3][6]f32 = undefined;
                for (&w) |*c| for (c) |*v| {
                    v.* = try br.f16Field();
                    if (@abs(v.*) < almost_zero) return error.BadImage;
                    v.* *= 64;
                };
                break :blk .{ .dct2 = w };
            },
            3 => blk: {
                if (!one) return error.BadImage;
                var m: [3][2]f32 = undefined;
                for (&m) |*c| for (c) |*v| {
                    v.* = try br.f16Field();
                    if (@abs(v.*) < almost_zero) return error.BadImage;
                };
                break :blk .{ .dct4 = .{ .params = try readDctParams(br), .mul = m } };
            },
            4 => blk: {
                if (!one) return error.BadImage;
                var m: [3]f32 = undefined;
                for (&m) |*v| {
                    v.* = try br.f16Field();
                    if (@abs(v.*) < almost_zero) return error.BadImage;
                }
                break :blk .{ .dct4x8 = .{ .params = try readDctParams(br), .mul = m } };
            },
            5 => blk: {
                if (!one) return error.BadImage;
                var w: [3][9]f32 = undefined;
                for (&w) |*c| {
                    for (c) |*v| v.* = try br.f16Field();
                    for (c[0..6]) |*v| v.* *= 64;
                }
                const p4x8 = try readDctParams(br);
                const p4x4 = try readDctParams(br);
                break :blk .{ .afv = .{ .p4x8 = p4x8, .p4x4 = p4x4, .w = w } };
            },
            6 => .{ .dct = try readDctParams(br) },
            7 => blk: {
                const den = try br.f16Field();
                if (den < almost_zero) return error.BadImage;
                const w = @as(u32, size_x[i]) * 8;
                const h = @as(u32, size_y[i]) * 8;
                var img: modular.Image = try .init(arena, 3, w, h, 8);
                try modular.decodeStream(
                    br,
                    arena,
                    &img,
                    ctx.first_stream + @as(u32, @intCast(i)),
                    .{ .global = ctx.tree },
                );
                if (img.len != 3) return error.BadImage;
                const table = try arena.alloc(i32, 3 * @as(usize, w) * h);
                for (img.channels(), 0..) |c, k| {
                    if (c.w != w or c.h != h) return error.BadImage;
                    for (c.data[0 .. @as(usize, w) * h], table[k * w * h ..][0 .. @as(usize, w) * h]) |v, *t| {
                        if (v <= 0) return error.BadImage;
                        t.* = v;
                    }
                }
                break :blk .{ .raw = .{ .den = den, .table = table } };
            },
            else => unreachable,
        };
    }
}

fn mult(v: f32) f32 {
    return if (v > 0) 1 + v else 1 / (1 - v);
}

fn interpolate(pos: f32, max: f32, bands: []const f32) f32 {
    const scaled = pos * @as(f32, @floatFromInt(bands.len - 1)) / max;
    const idx: usize = @intFromFloat(scaled);
    const a = bands[idx];
    const c = bands[@min(idx + 1, bands.len - 1)];
    return a * std.math.pow(f32, c / a, scaled - @as(f32, @floatFromInt(idx)));
}

/// The weights of a `rows` by `cols` matrix from distance bands, into
/// `out[c * rows * cols ..]`.
fn bandWeights(rows: usize, cols: usize, p: *const DctParams, out: []f32) Error!void {
    for (0..3) |c| {
        var bands: [max_bands]f32 = undefined;
        bands[0] = p.bands[c][0];
        if (bands[0] < almost_zero) return error.BadImage;
        for (1..p.n) |i| {
            bands[i] = bands[i - 1] * mult(p.bands[c][i]);
            if (bands[i] < almost_zero) return error.BadImage;
        }
        const scale = @as(f32, @floatFromInt(p.n - 1)) / (std.math.sqrt2 + 1e-6);
        const rcpcol = scale / @as(f32, @floatFromInt(cols - 1));
        const rcprow = scale / @as(f32, @floatFromInt(rows - 1));
        for (0..rows) |y| {
            const dy = @as(f32, @floatFromInt(y)) * rcprow;
            for (0..cols) |x| {
                const dx = @as(f32, @floatFromInt(x)) * rcpcol;
                const d = @sqrt(dx * dx + dy * dy);
                out[c * rows * cols + y * cols + x] = if (p.n == 1) bands[0] else interpolate(
                    d,
                    @floatFromInt(p.n - 1),
                    bands[0..p.n],
                );
            }
        }
    }
}

/// Writes table `t`'s dequantization multipliers, `3 * 64 * size_x[t] *
/// size_y[t]` floats, channel by channel in stored layout.
pub fn multipliers(e: *const Encoding, t: usize, out: []f32) Error!void {
    const rows = @as(usize, size_x[t]) * 8;
    const cols = @as(usize, size_y[t]) * 8;
    const num = rows * cols;
    const w = out[0 .. 3 * num];
    switch (e.*) {
        .identity => |id| for (0..3) |c| {
            @memset(w[c * 64 ..][0..64], id[c][0]);
            w[c * 64 + 1] = id[c][1];
            w[c * 64 + 8] = id[c][1];
            w[c * 64 + 9] = id[c][2];
        },
        .dct2 => |d| for (0..3) |c| {
            const s = w[c * 64 ..][0..64];
            s[0] = 0xBAD;
            s[1] = d[c][0];
            s[8] = d[c][0];
            s[9] = d[c][1];
            for (0..2) |y| for (0..2) |x| {
                s[y * 8 + x + 2] = d[c][2];
                s[(y + 2) * 8 + x] = d[c][2];
                s[(y + 2) * 8 + x + 2] = d[c][3];
            };
            for (0..4) |y| for (0..4) |x| {
                s[y * 8 + x + 4] = d[c][4];
                s[(y + 4) * 8 + x] = d[c][4];
                s[(y + 4) * 8 + x + 4] = d[c][5];
            };
        },
        .dct4 => |d| {
            var w4: [3 * 16]f32 = undefined;
            try bandWeights(4, 4, &d.params, &w4);
            for (0..3) |c| {
                const s = w[c * 64 ..][0..64];
                for (0..8) |y| for (0..8) |x| {
                    s[y * 8 + x] = w4[c * 16 + (y / 2) * 4 + x / 2];
                };
                s[1] /= d.mul[c][0];
                s[8] /= d.mul[c][0];
                s[9] /= d.mul[c][1];
            }
        },
        .dct4x8 => |d| {
            var w48: [3 * 32]f32 = undefined;
            try bandWeights(4, 8, &d.params, &w48);
            for (0..3) |c| {
                const s = w[c * 64 ..][0..64];
                for (0..8) |y| for (0..8) |x| {
                    s[y * 8 + x] = w48[c * 32 + (y / 2) * 8 + x];
                };
                s[8] /= d.mul[c];
            }
        },
        .dct => |*p| try bandWeights(rows, cols, p, w),
        .raw => |r| for (w, r.table[0..w.len]) |*v, q| {
            v.* = 1 / (r.den * @as(f32, @floatFromInt(q)));
        },
        .afv => |*a| try afvWeights(a.p4x8, a.p4x4, a.w, w),
    }
    for (w) |*v| {
        if (!(v.* >= almost_zero and v.* < 1 / almost_zero)) return error.BadImage;
        v.* = 1 / v.*;
    }
}

fn afvWeights(p4x8: DctParams, p4x4: DctParams, aw: [3][9]f32, w: []f32) Error!void {
    const freqs = [16]f32{
        0xBAD,              0xBAD,             0.8517778890324296, 5.37778436506804,
        0xBAD,              0xBAD,             4.734747904497923,  5.449245381693219,
        1.6598270267479331, 4,                 7.275749096817861,  10.423227632456525,
        2.662932286148962,  7.630657783650829, 8.962388608184032,  12.97166202570235,
    };
    var w48: [3 * 32]f32 = undefined;
    try bandWeights(4, 8, &p4x8, &w48);
    var w44: [3 * 16]f32 = undefined;
    try bandWeights(4, 4, &p4x4, &w44);
    const lo: f32 = 0.8517778890324296;
    const hi: f32 = 12.97166202570235 - lo + 1e-6;
    for (0..3) |c| {
        var bands: [4]f32 = undefined;
        bands[0] = aw[c][5];
        if (bands[0] < almost_zero) return error.BadImage;
        for (1..4) |i| {
            bands[i] = bands[i - 1] * mult(aw[c][i + 5]);
            if (bands[i] < almost_zero) return error.BadImage;
        }
        const s = w[c * 64 ..][0..64];
        s[0] = 1;
        s[8] = aw[c][0];
        s[1] = aw[c][1];
        s[16] = aw[c][2];
        s[2] = aw[c][3];
        s[18] = aw[c][4];
        for (0..4) |y| for (0..4) |x| {
            if (x < 2 and y < 2) continue;
            s[2 * y * 8 + 2 * x] = interpolate(freqs[y * 4 + x] - lo, hi, &bands);
        };
        for (0..4) |y| for (0..8) |x| {
            if (x == 0 and y == 0) continue;
            s[(2 * y + 1) * 8 + x] = w48[c * 32 + y * 8 + x];
        };
        for (0..4) |y| for (0..4) |x| {
            if (x == 0 and y == 0) continue;
            s[2 * y * 8 + 2 * x + 1] = w44[c * 16 + y * 4 + x];
        };
    }
}

const dct4x4_params: DctParams = .{
    .n = 4,
    .bands = .{ b(.{ 2200.0, 0.0, 0.0, 0.0 }), b(.{ 392.0, 0.0, 0.0, 0.0 }), b(.{ 112.0, -0.25, -0.25, -0.5 }) },
};
const dct4x8_params: DctParams = .{
    .n = 4,
    .bands = .{
        b(.{ 2198.050556016380522, -0.96269623020744692, -0.76194253026666783, -0.6551140670773547 }),
        b(.{ 764.3655248643528689, -0.92630200888366945, -0.9675229603596517, -0.27845290869168118 }),
        b(.{ 527.107573587542228, -1.4594385811273854, -1.450082094097871593, -1.5843722511996204 }),
    },
};

pub const defaults = [num_tables]Encoding{
    .{ .dct = .{
        .n = 6,
        .bands = .{
            b(.{ 3150.0, 0.0, -0.4, -0.4, -0.4, -2.0 }),
            b(.{ 560.0, 0.0, -0.3, -0.3, -0.3, -0.3 }),
            b(.{ 512.0, -2.0, -1.0, 0.0, -1.0, -2.0 }),
        },
    } },
    .{ .identity = .{ .{ 280.0, 3160.0, 3160.0 }, .{ 60.0, 864.0, 864.0 }, .{ 18.0, 200.0, 200.0 } } },
    .{ .dct2 = .{
        .{ 3840.0, 2560.0, 1280.0, 640.0, 480.0, 300.0 },
        .{ 960.0, 640.0, 320.0, 180.0, 140.0, 120.0 },
        .{ 640.0, 320.0, 128.0, 64.0, 32.0, 16.0 },
    } },
    .{ .dct4 = .{
        .params = .{
            .n = 4,
            .bands = .{
                b(.{ 2200.0, 0.0, 0.0, 0.0 }),
                b(.{ 392.0, 0.0, 0.0, 0.0 }),
                b(.{ 112.0, -0.25, -0.25, -0.5 }),
            },
        },
        .mul = .{ .{ 1.0, 1.0 }, .{ 1.0, 1.0 }, .{ 1.0, 1.0 } },
    } },
    .{ .dct = .{
        .n = 7,
        .bands = .{
            b(.{
                8996.8725711814115328, -1.3000777393353804,  -0.49424529824571225, -0.439093774457103443,
                -0.6350101832695744,   -0.90177264050827612, -1.6162099239887414,
            }),
            b(.{
                3191.48366296844234752, -0.67424582104194355, -0.80745813428471001, -0.44925837484843441,
                -0.35865440981033403,   -0.31322389111877305, -0.37615025315725483,
            }),
            b(.{
                1157.50408145487200256, -2.0531423165804414, -1.4, -0.50687130033378396, -0.42708730624733904,
                -1.4856834539296244,    -4.9209142884401604,
            }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{ 15718.40830982518931456, -1.025, -0.98, -0.9012, -0.4, -0.48819395464, -0.421064, -0.27 }),
            b(.{
                7305.7636810695983104, -0.8041958212306401,  -0.7633036457487539,  -0.55660379990111464,
                -0.49785304658857626,  -0.43699592683512467, -0.40180866526242109, -0.27321683125358037,
            }),
            b(.{
                3803.53173721215041536, -3.060733579805728, -2.0413270132490346, -2.0235650159727417,
                -0.5495389509954993,    -0.4,               -0.4,                -0.3,
            }),
        },
    } },
    .{ .dct = .{
        .n = 7,
        .bands = .{
            b(.{ 7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5 }),
            b(.{ 1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2 }),
            b(.{ 506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6 }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{
                16283.2494710648897, -1.7812845336559429, -1.6309059012653515, -1.0382179034313539, -0.85, -0.7, -0.9,
                -1.2360638576849587,
            }),
            b(.{
                5089.15750884921511936, -0.320049391452786891, -0.35362849922161446, -0.30340000000000003, -0.61, -0.5,
                -0.5,                   -0.6,
            }),
            b(.{
                3397.77603275308720128, -0.321327362693153371, -0.34507619223117997, -0.70340000000000003, -0.9, -1.0,
                -1.0,                   -1.1754605576265209,
            }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{ 13844.97076442300573, -0.97113799999999995, -0.658, -0.42026, -0.22712, -0.2206, -0.226, -0.6 }),
            b(.{
                4798.964084220744293, -0.61125308982767057, -0.83770786552491361, -0.79014862079498627,
                -0.2692727459704829,  -0.38272769465388551, -0.22924222653091453, -0.20719098826199578,
            }),
            b(.{ 1807.236946760964614, -1.2, -1.2, -0.7, -0.7, -0.7, -0.4, -0.5 }),
        },
    } },
    .{ .dct4x8 = .{
        .params = .{
            .n = 4,
            .bands = .{
                b(.{ 2198.050556016380522, -0.96269623020744692, -0.76194253026666783, -0.6551140670773547 }),
                b(.{ 764.3655248643528689, -0.92630200888366945, -0.9675229603596517, -0.27845290869168118 }),
                b(.{ 527.107573587542228, -1.4594385811273854, -1.450082094097871593, -1.5843722511996204 }),
            },
        },
        .mul = .{ 1.0, 1.0, 1.0 },
    } },
    .{ .afv = .{
        .p4x8 = dct4x8_params,
        .p4x4 = dct4x4_params,
        .w = .{
            .{ 3072.0, 3072.0, 256.0, 256.0, 256.0, 414.0, 0.0, 0.0, 0.0 },
            .{ 1024.0, 1024.0, 50, 50, 50, 58.0, 0.0, 0.0, 0.0 },
            .{ 384.0, 384.0, 12.0, 12.0, 12.0, 22.0, -0.25, -0.25, -0.25 },
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{
                0.9 * 26629.073922049845,
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
            }),
            b(.{
                0.9 * 9311.3238710010046,
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
            }),
            b(.{ 0.9 * 4992.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5 }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{
                0.65 * 23629.073922049845,
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
            }),
            b(.{
                0.65 * 8611.3238710010046,
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
            }),
            b(.{ 0.65 * 4492.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5 }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{
                1.8 * 26629.073922049845,
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
            }),
            b(.{
                1.8 * 9311.3238710010046,
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
            }),
            b(.{ 1.8 * 4992.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5 }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{
                1.3 * 23629.073922049845,
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
            }),
            b(.{
                1.3 * 8611.3238710010046,
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
            }),
            b(.{ 1.3 * 4492.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5 }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{
                3.6 * 26629.073922049845,
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
            }),
            b(.{
                3.6 * 9311.3238710010046,
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
            }),
            b(.{ 3.6 * 4992.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5 }),
        },
    } },
    .{ .dct = .{
        .n = 8,
        .bands = .{
            b(.{
                2.6 * 23629.073922049845,
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
            }),
            b(.{
                2.6 * 8611.3238710010046,
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
            }),
            b(.{ 2.6 * 4492.2486445538634, -1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5 }),
        },
    } },
};

test "default DCT8 multipliers" {
    var m: [3 * 64]f32 = undefined;
    try multipliers(&defaults[0], 0, &m);
    // The first band at distance 0: 1 / 3150, 1 / 560, 1 / 512.
    try testing.expectApproxEqRel(@as(f32, 1.0 / 3150.0), m[0], 1e-6);
    try testing.expectApproxEqRel(@as(f32, 1.0 / 560.0), m[64], 1e-6);
    try testing.expectApproxEqRel(@as(f32, 1.0 / 512.0), m[128], 1e-6);
    // The far corner is the last band's weight.
    try testing.expect(m[63] > m[1]);
}

test "every default table computes" {
    var m: [3 * 256 * 256]f32 = undefined;
    for (&defaults, 0..) |*e, t| try multipliers(e, t, &m);
}
