//! Scratch: `encdev enc in.png q effort out.webp` encodes with
//! image.webp.lossy and prints size and time; `encdev cmp orig.png x.webp`
//! decodes x.webp (ours, bit-exact with libwebp) and prints size, PSNR over
//! RGB, and SSIM over BT.601 luma (11x11 Gaussian, sigma 1.5).
const std = @import("std");
const image = @import("image");

const gpa = std.heap.smp_allocator;

fn load(io: std.Io, path: []const u8, fmt_hint: ?image.PixelFormat) !image.PixelBuffer {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    var r: std.Io.Reader = .fixed(data);
    var d = try image.Decoder.initDetect(&r, .{ .limits = .none });
    const config = try d.decodeConfig();
    const fmt: image.PixelFormat = fmt_hint orelse if (config.native.hasAlpha()) .rgba8 else .rgb8;
    const len = image.PixelBuffer.len(fmt, config.width, config.height).?;
    const px = try gpa.alloc(u8, len);
    const src = try image.PixelBuffer.init(px, fmt, config.width, config.height);
    const dwork = try gpa.alloc(u8, config.work_len);
    _ = try d.decodeFrame(src, dwork);
    return src;
}

fn lumaPlane(p: image.PixelBuffer) ![]f64 {
    const n = @as(usize, p.width) * p.height;
    const out = try gpa.alloc(f64, n);
    const bpp = p.format.bytesPerPixel();
    for (0..n) |i| {
        const r: f64 = @floatFromInt(p.pixels[i * bpp]);
        const g: f64 = @floatFromInt(p.pixels[i * bpp + 1]);
        const b: f64 = @floatFromInt(p.pixels[i * bpp + 2]);
        out[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    }
    return out;
}

fn ssim(a: []const f64, b: []const f64, w: usize, h: usize) f64 {
    var k: [11]f64 = undefined;
    var ks: f64 = 0;
    for (&k, 0..) |*v, i| {
        const x = @as(f64, @floatFromInt(i)) - 5;
        v.* = @exp(-x * x / (2 * 1.5 * 1.5));
        ks += v.*;
    }
    for (&k) |*v| v.* /= ks;
    const c1 = (0.01 * 255) * (0.01 * 255);
    const c2 = (0.03 * 255) * (0.03 * 255);
    if (w < 11 or h < 11) return 1;
    // Separable blur of a, b, a2, b2, ab, horizontally then vertically.
    const planes = 5;
    const tmp = gpa.alloc(f64, planes * w * h) catch unreachable;
    defer gpa.free(tmp);
    for (0..h) |y| for (0..w - 10) |x| {
        var s: [planes]f64 = @splat(0);
        for (0..11) |i| {
            const pa = a[y * w + x + i];
            const pb = b[y * w + x + i];
            s[0] += k[i] * pa;
            s[1] += k[i] * pb;
            s[2] += k[i] * pa * pa;
            s[3] += k[i] * pb * pb;
            s[4] += k[i] * pa * pb;
        }
        for (0..planes) |p| tmp[p * w * h + y * w + x] = s[p];
    };
    var total: f64 = 0;
    var count: f64 = 0;
    for (0..h - 10) |y| for (0..w - 10) |x| {
        var s: [planes]f64 = @splat(0);
        for (0..11) |i| for (0..planes) |p| {
            s[p] += k[i] * tmp[p * w * h + (y + i) * w + x];
        };
        const ma = s[0];
        const mb = s[1];
        const va = s[2] - ma * ma;
        const vb = s[3] - mb * mb;
        const cov = s[4] - ma * mb;
        total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2));
        count += 1;
    };
    return total / count;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var it = try init.minimal.args.iterateAllocator(gpa);
    _ = it.skip();
    const cmd = it.next().?;
    var buf: [512]u8 = undefined;
    if (std.mem.eql(u8, cmd, "enc")) {
        const path = it.next().?;
        const q = try std.fmt.parseInt(u8, it.next().?, 10);
        const eff_s = it.next().?;
        const effort = std.meta.stringToEnum(image.webp.lossy.Effort, eff_s).?;
        const out_path = it.next().?;
        const src = try load(io, path, null);
        const opts: image.webp.lossy.EncodeOptions = .{ .quality = q, .effort = effort };
        const work = try gpa.alloc(u8, image.webp.lossy.workLen(opts, src.width, src.height).?);
        var out: std.Io.Writer.Allocating = .init(gpa);
        const t0 = std.Io.Timestamp.now(io, .awake);
        try image.webp.lossy.encode(&out.writer, src, opts, work);
        const ns = t0.untilNow(io, .awake).toNanoseconds();
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.written() });
        const mp = @as(f64, @floatFromInt(src.width * src.height)) / 1e6;
        const line = try std.fmt.bufPrint(&buf, "{d} {d:.3}\n", .{ out.written().len, mp / (@as(f64, @floatFromInt(ns)) / 1e9) });
        try std.Io.File.stdout().writeStreamingAll(io, line);
    } else {
        const orig = try load(io, it.next().?, .rgb8);
        const test_path = it.next().?;
        const got = try load(io, test_path, .rgb8);
        const st = try std.Io.Dir.cwd().statFile(io, test_path, .{});
        var sum: f64 = 0;
        for (orig.pixels, got.pixels) |x, y| {
            const d = @as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(y));
            sum += d * d;
        }
        const mse = sum / @as(f64, @floatFromInt(orig.pixels.len));
        const la = try lumaPlane(orig);
        const lb = try lumaPlane(got);
        const s = ssim(la, lb, orig.width, orig.height);
        const line = try std.fmt.bufPrint(&buf, "{d} {d:.4} {d:.6}\n", .{ st.size, 10 * @log10(255.0 * 255.0 / @max(mse, 1e-10)), s });
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }
}
