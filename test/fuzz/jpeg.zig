//! The JPEG fuzz target: the decoder properties in harness.zig, at full
//! size and, chosen by the input, at a reduced scale and with CMYK as its
//! inks, on mutated corpus files and generated ones. The generator writes
//! a JPEG the way the decoder reads one: it walks the decoder's states, sequential,
//! progressive, or lossless, chooses each symbol at random from those the
//! decoder can read next, and writes its Huffman code and bits, so the
//! files reach every marker, sampling layout, scan type, precision, and
//! restart interval. Arithmetic-coded scans get random bytes, which that
//! decoder reads as some sequence of decisions.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "jpeg";

pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/jpeg" };
pub const extensions = [_][]const u8{ ".jpg", ".jpeg", ".jpe", ".jfif" };

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkDecoder(image.jpeg.Decoder, input, choice);
    // The same properties at a reduced scale, which takes its own IDCTs
    // and upsampling paths.
    switch ((choice >> 32) % 3) {
        0 => try harness.checkDecoder(With(.half, .rgb), input, choice),
        1 => try harness.checkDecoder(With(.quarter, .rgb), input, choice),
        else => try harness.checkDecoder(With(.eighth, .rgb), input, choice),
    }
    // CMYK and YCCK as their inks, native `cmyk8` or `cmyk16`.
    if (choice >> 40 & 1 == 1) try harness.checkDecoder(With(.full, .raw), input, choice);
    try checkContainer(input, choice);
}

var whole_pixels: [harness.limits.max_pixels * 8]u8 = undefined;
var cropped_pixels: [harness.limits.max_pixels * 8]u8 = undefined;
var container_work: [harness.limits.max_work]u8 = undefined;

/// The API TIFF uses: `workLen` from the frame header's fields gives what
/// `decodeConfig` states, and a decode cropped by `Options.crop` writes
/// the top-left of the full decode, or fails as it does.
fn checkContainer(input: []const u8, choice: u64) !void {
    const D = image.jpeg.Decoder;
    var r: std.Io.Reader = .fixed(input);
    var d: D = .init(&r, .{ .limits = harness.limits });
    const config = d.decodeConfig() catch return;
    var frame = d.frameParams();
    frame.multi_scan = true;
    const multi = D.workLen(frame, .{ .limits = .none }) catch return error.WorkLenDiffers;
    frame.multi_scan = false;
    const single = D.workLen(frame, .{ .limits = .none }) catch return error.WorkLenDiffers;
    if (single > multi or (config.work_len != multi and config.work_len != single)) return error.WorkLenDiffers;

    if (choice >> 41 & 1 == 0 or config.work_len > container_work.len) return;
    const w: u32 = @intCast(1 + (choice >> 8) % config.width);
    const h: u32 = @intCast(1 + (choice >> 24) % config.height);
    const whole = try image.PixelBuffer.init(&whole_pixels, config.native, config.width, config.height);
    r = .fixed(input);
    var a: D = .init(&r, .{ .limits = harness.limits });
    const want = a.decodeFrame(whole, container_work[0..config.work_len]);
    const cropped = try image.PixelBuffer.init(&cropped_pixels, config.native, w, h);
    r = .fixed(input);
    var b: D = .init(&r, .{ .limits = harness.limits, .crop = true });
    const got = b.decodeFrame(cropped, container_work[0..config.work_len]);
    if (want) |_| {
        const frame_got = got catch return error.CropDiffers;
        if (frame_got.?.width != w or frame_got.?.height != h) return error.CropDiffers;
        const bytes = image.PixelBuffer.len(config.native, w, 1).?;
        for (0..h) |y| {
            const row: u32 = @intCast(y);
            if (!std.mem.eql(u8, whole.row(row)[0..bytes], cropped.row(row)[0..bytes])) return error.CropDiffers;
        }
    } else |e| {
        // Rows past the destination are decoded too, so it fails the same.
        if (got) |_| return error.CropDiffers else |e2| if (e2 != e) return error.CropDiffers;
    }
}

/// `image.jpeg.Decoder` with `Options.scale` and `Options.cmyk` set.
fn With(comptime scale: image.jpeg.Decoder.Scale, comptime cmyk: image.jpeg.Decoder.Cmyk) type {
    return struct {
        d: image.jpeg.Decoder,

        const Self = @This();
        const D = image.jpeg.Decoder;
        pub fn init(reader: *std.Io.Reader, options: image.DecodeOptions) Self {
            const o: D.Options = .{
                .limits = options.limits,
                .blob_sink = options.blob_sink,
                .scale = scale,
                .cmyk = cmyk,
            };
            return .{ .d = .init(reader, o) };
        }
        pub fn decodeConfig(s: *Self) D.Error!image.Config {
            return s.d.decodeConfig();
        }
        pub fn decodeFrame(s: *Self, dst: image.PixelBuffer, work: []u8) D.Error!?image.Frame {
            return s.d.decodeFrame(dst, work);
        }
    };
}

/// Writes into a buffer, dropping what does not fit.
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn put(o: *Out, bytes: []const u8) void {
        const n = @min(bytes.len, o.buf.len - o.len);
        @memcpy(o.buf[o.len..][0..n], bytes[0..n]);
        o.len += n;
    }

    fn byte(o: *Out, b: u8) void {
        o.put(&.{b});
    }

    fn int(o: *Out, v: u16) void {
        o.put(&.{ @intCast(v >> 8), @truncate(v) });
    }

    fn marker(o: *Out, m: u8) void {
        o.put(&.{ 0xff, m });
    }

    fn full(o: *const Out) bool {
        return o.len + 16 >= o.buf.len;
    }
};

/// Entropy-coded bits, most significant first, with 0xFF stuffed.
const Bits = struct {
    out: *Out,
    acc: u32 = 0,
    n: u5 = 0,

    fn put(b: *Bits, v: u32, n: u5) void {
        var i: u5 = n;
        while (i > 0) {
            i -= 1;
            b.acc = b.acc << 1 | (v >> i & 1);
            b.n += 1;
            if (b.n == 8) {
                const c: u8 = @truncate(b.acc);
                b.out.byte(c);
                if (c == 0xff) b.out.byte(0);
                b.acc = 0;
                b.n = 0;
            }
        }
    }

    /// Pads the last byte with ones.
    fn flush(b: *Bits) void {
        if (b.n != 0) b.put(0x7f, 8 - b.n);
    }
};

/// A Huffman table: DHT's counts and symbols, and each symbol's code.
const Table = struct {
    counts: [16]u8 = @splat(0),
    values: [256]u8 = undefined,
    n: usize = 0,
    code: [256]u16 = undefined,
    len: [256]u5 = @splat(0),

    fn build(t: *Table) void {
        var code: u16 = 0;
        var k: usize = 0;
        for (t.counts, 1..) |c, l| {
            for (0..c) |_| {
                t.code[t.values[k]] = code;
                t.len[t.values[k]] = @intCast(l);
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
    }

    fn has(t: *const Table, sym: u8) bool {
        return t.len[sym] != 0;
    }

    fn write(t: *const Table, b: *Bits, sym: u8) void {
        b.put(t.code[sym], t.len[sym]);
    }

    /// Every symbol in `syms` at one length, in a shuffled order.
    fn flat(random: std.Random, syms: []const u8, length: u5) Table {
        var t: Table = .{};
        @memcpy(t.values[0..syms.len], syms);
        random.shuffle(u8, t.values[0..syms.len]);
        t.n = syms.len;
        t.counts[length - 1] = @intCast(syms.len);
        t.build();
        return t;
    }

    fn fromSpec(counts: [16]u8, values: []const u8) Table {
        var t: Table = .{ .counts = counts, .n = values.len };
        @memcpy(t.values[0..values.len], values);
        t.build();
        return t;
    }
};

// T.81 K.3's tables, which a sequential scan gets for table 0 or 1 when no
// DHT defines it.
const std_dc_luma_counts = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const std_dc_chroma_counts = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const std_dc_values = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const std_ac_luma_counts = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const std_ac_luma_values = [_]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

const max_side = 64;
const max_blocks = 2048;

/// The generator's state: the frame, its tables, and each block's
/// nonzero coefficients so far, which a refinement scan reads.
const Gen = struct {
    random: std.Random,
    o: *Out,
    width: u16,
    height: u16,
    ncomp: u8,
    h: [4]u8,
    v: [4]u8,
    ids: [4]u8,
    progressive: bool,
    restart: u16,
    precision: u8 = 8,
    coding: enum { huffman, arithmetic, lossless } = .huffman,
    dc: [4]Table = undefined,
    ac: [4]Table = undefined,
    hmax: u8 = 1,
    vmax: u8 = 1,
    nonzero: [4][max_blocks]u64 = undefined,
    bw: [4]u32 = undefined,
    wb: [4]u32 = undefined,
    hb: [4]u32 = undefined,

    fn chance(g: *Gen, n: u8) bool {
        return g.random.uintLessThan(u8, n) == 0;
    }

    fn segment(g: *Gen, m: u8, body: []const u8) void {
        g.o.marker(m);
        g.o.int(@intCast(body.len + 2));
        g.o.put(body);
    }

    fn header(g: *Gen) void {
        const o = g.o;
        o.marker(0xd8);
        // Metadata segments in a random order and mix.
        for (0..g.random.uintAtMost(u8, 3)) |_| switch (g.random.uintLessThan(u8, 9)) {
            0 => g.segment(0xe0, "JFIF\x00\x01\x02\x01\x00\x48\x00\x48\x00\x00"),
            1 => g.segment(0xee, "Adobe\x00\x64\x00\x00\x00\x00" ++ [_]u8{g.random.uintLessThan(u8, 3)}),
            2 => g.segment(0xe1, "Exif\x00\x00MM\x00*\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01" ++
                [_]u8{ 0, g.random.uintAtMost(u8, 9) } ++ "\x00\x00"),
            3 => {
                // An ICC profile of 20 bytes in one or two pieces.
                const profile = "\x00\x00\x00\x14" ++ "acspprofile-data";
                if (g.chance(2)) {
                    g.segment(0xe2, "ICC_PROFILE\x00\x01\x01" ++ profile);
                } else {
                    g.segment(0xe2, "ICC_PROFILE\x00\x01\x02" ++ profile[0..9]);
                    g.segment(0xe2, "ICC_PROFILE\x00\x02\x02" ++ profile[9..]);
                }
            },
            4 => g.segment(0xfe, "a comment"),
            // What flags a gain map: MPF, and the gain map's XMP namespace or
            // ISO 21496-1's segment.
            5 => g.segment(0xe2, "MPF\x00MM\x00\x2a\x00\x00\x00\x08"),
            6 => g.segment(0xe1, "http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta xmlns:hdrgm=\"" ++
                "http://ns.adobe.com/hdr-gain-map/1.0/\" hdrgm:Version=\"1.0\"/>"),
            7 => g.segment(0xe2, "urn:iso:std:iso:ts:21496:-1\x00\x00\x00\x00\x00"),
            else => g.segment(0xe1, "http://ns.adobe.com/xap/1.0/\x00<x/>"),
        };
        // Quantization tables, 8- or 16-bit.
        for (0..4) |t| {
            if (t > 0 and g.chance(3)) continue;
            const wide = g.chance(8);
            var body: [129]u8 = undefined;
            body[0] = @as(u8, @intFromBool(wide)) << 4 | @as(u8, @intCast(t));
            const top: u16 = if (g.chance(16)) 0xffff else if (g.chance(4)) 255 else 40;
            if (wide) {
                for (0..64) |i| std.mem.writeInt(u16, body[1 + 2 * i ..][0..2], g.random.uintAtMost(u16, top), .big);
                g.segment(0xdb, body[0..129]);
            } else {
                for (body[1..65]) |*q| q.* = @intCast(@max(1, g.random.uintAtMost(u16, @min(top, 255))));
                g.segment(0xdb, body[0..65]);
            }
        }
        if (g.restart != 0) g.segment(0xdd, &.{ @intCast(g.restart >> 8), @truncate(g.restart) });
        if (g.coding == .arithmetic and g.chance(2)) {
            // Conditioning: L and U for a DC table, Kx for an AC one.
            var dac: [8]u8 = undefined;
            const n = 1 + g.random.uintLessThan(usize, 4);
            for (0..n) |i| {
                const t = g.random.uintLessThan(u8, 2);
                if (g.chance(2)) {
                    const l = g.random.uintAtMost(u8, 4);
                    dac[2 * i ..][0..2].* = .{ t, (l + g.random.uintAtMost(u8, 4)) << 4 | l };
                } else dac[2 * i ..][0..2].* = .{ 0x10 | t, 1 + g.random.uintLessThan(u8, 63) };
            }
            g.segment(0xcc, dac[0 .. 2 * n]);
        }
        // The frame.
        var sof: [6 + 12]u8 = undefined;
        sof[0] = g.precision;
        std.mem.writeInt(u16, sof[1..3], g.height, .big);
        std.mem.writeInt(u16, sof[3..5], g.width, .big);
        sof[5] = g.ncomp;
        for (0..g.ncomp) |i| {
            const tq = if (i == 0) 0 else g.random.uintLessThan(u8, 2);
            sof[6 + 3 * i ..][0..3].* = .{ g.ids[i], g.h[i] << 4 | g.v[i], tq };
        }
        const kind: u8 = switch (g.coding) {
            .huffman => if (g.progressive) 0xc2 else if (g.chance(2) or g.precision != 8) 0xc1 else 0xc0,
            .arithmetic => if (g.progressive) 0xca else 0xc9,
            .lossless => 0xc3,
        };
        g.segment(kind, sof[0 .. 6 + 3 * @as(usize, g.ncomp)]);
    }

    fn defineTables(g: *Gen) void {
        if (g.coding == .arithmetic) return;
        if (g.coding == .lossless) {
            // Difference categories 0 to 16.
            var syms: [17]u8 = undefined;
            for (&syms, 0..) |*v, i| v.* = @intCast(i);
            for (0..2) |t| {
                g.dc[t] = Table.flat(g.random, &syms, 5);
                g.writeDht(@intCast(t), &g.dc[t]);
            }
            return;
        }
        // DC: categories 0 to 11; AC: every run and size, the end-of-band
        // runs, and ZRL.
        var ac_syms: [176]u8 = undefined;
        var n: usize = 0;
        for (0..16) |r| {
            for (1..11) |s| {
                ac_syms[n] = @intCast(r << 4 | s);
                n += 1;
            }
        }
        for (0..15) |r| {
            ac_syms[n] = @intCast(r << 4);
            n += 1;
        }
        ac_syms[n] = 0xf0;
        n += 1;
        for (0..2) |t| {
            // A sequential image may leave tables 0 and 1 out and use the
            // standard ones.
            const standard = !g.progressive and g.chance(3);
            if (standard) {
                g.dc[t] = Table.fromSpec(if (t == 0) std_dc_luma_counts else std_dc_chroma_counts, &std_dc_values);
                g.ac[t] = Table.fromSpec(std_ac_luma_counts, &std_ac_luma_values);
                if (g.chance(2)) {
                    g.writeDht(@intCast(t), &g.dc[t]);
                    g.writeDht(@intCast(0x10 + t), &g.ac[t]);
                } else if (t == 1) {
                    // Without a DHT, table 1 is the chroma one; use luma's
                    // DHT to keep the generator simple.
                    g.writeDht(@intCast(0x10 + t), &g.ac[t]);
                }
                continue;
            }
            g.dc[t] = Table.flat(g.random, &std_dc_values, 4);
            g.ac[t] = Table.flat(g.random, ac_syms[0..n], 8);
            g.writeDht(@intCast(t), &g.dc[t]);
            g.writeDht(@intCast(0x10 + t), &g.ac[t]);
        }
    }

    fn writeDht(g: *Gen, index: u8, t: *const Table) void {
        g.o.marker(0xc4);
        g.o.int(@intCast(2 + 17 + t.n));
        g.o.byte(index);
        g.o.put(&t.counts);
        g.o.put(t.values[0..t.n]);
    }

    fn sos(g: *Gen, comps: []const u8, ss: u8, se: u8, ah: u8, al: u8) void {
        g.o.marker(0xda);
        g.o.int(@intCast(6 + 2 * comps.len));
        g.o.byte(@intCast(comps.len));
        for (comps) |ci| g.o.put(&.{ g.ids[ci], tableOf(ci) << 4 | tableOf(ci) });
        g.o.put(&.{ ss, se, ah << 4 | al });
    }

    fn tableOf(ci: u8) u8 {
        return if (ci == 0) 0 else 1;
    }

    /// A random magnitude of `size` bits and its sign.
    fn magnitude(g: *Gen, b: *Bits, size: u5) void {
        if (size != 0) b.put(g.random.int(u32) & ((@as(u32, 1) << size) - 1), size);
    }

    /// One scan's blocks: interleaved MCUs when it has several
    /// components, else the component's blocks in order, with restart
    /// markers.
    fn scan(g: *Gen, comps: []const u8, kind: Kind, ss: u8, se: u8, al: u8) void {
        g.sos(comps, ss, se, if (kind == .dc_refine or kind == .ac_refine) al + 1 else 0, al);
        if (g.coding == .arithmetic) return g.randomData(comps);
        var b: Bits = .{ .out = g.o };
        var eobrun: u32 = 0;
        var mcus: u32 = 0;
        var next_rst: u8 = 0;
        const mcus_x = (g.width + 8 * @as(u32, g.hmax) - 1) / (8 * @as(u32, g.hmax));
        const mcus_y = (g.height + 8 * @as(u32, g.vmax) - 1) / (8 * @as(u32, g.vmax));
        const single = comps.len == 1;
        const total = if (single) g.wb[comps[0]] * g.hb[comps[0]] else mcus_x * mcus_y;
        for (0..total) |m| {
            if (g.o.full()) return;
            if (g.restart != 0 and mcus == g.restart) {
                b.flush();
                g.o.marker(0xd0 + next_rst);
                next_rst = (next_rst + 1) & 7;
                mcus = 0;
                eobrun = 0;
            }
            mcus += 1;
            if (single) {
                const ci = comps[0];
                const bx = @as(u32, @intCast(m)) % g.wb[ci];
                const by = @as(u32, @intCast(m)) / g.wb[ci];
                g.block(&b, ci, by * g.bw[ci] + bx, kind, ss, se, &eobrun);
            } else {
                const mx = @as(u32, @intCast(m)) % mcus_x;
                const my = @as(u32, @intCast(m)) / mcus_x;
                for (comps) |ci| {
                    for (0..g.v[ci]) |j| {
                        for (0..g.h[ci]) |i| {
                            const bx = mx * g.h[ci] + @as(u32, @intCast(i));
                            const by = my * g.v[ci] + @as(u32, @intCast(j));
                            g.block(&b, ci, by * g.bw[ci] + bx, kind, ss, se, &eobrun);
                        }
                    }
                }
            }
        }
        // An end-of-band run still open is written before the scan ends.
        b.flush();
    }

    /// The number of MCUs in a scan of `comps`.
    fn mcuCount(g: *const Gen, comps: []const u8, du: u32) u32 {
        if (comps.len == 1) {
            const ci = comps[0];
            if (du == 8) return g.wb[ci] * g.hb[ci];
            const w = (g.width * @as(u32, g.h[ci]) + g.hmax - 1) / g.hmax;
            return w * ((g.height * @as(u32, g.v[ci]) + g.vmax - 1) / g.vmax);
        }
        const mcus_x = (g.width + du * @as(u32, g.hmax) - 1) / (du * @as(u32, g.hmax));
        const mcus_y = (g.height + du * @as(u32, g.vmax) - 1) / (du * @as(u32, g.vmax));
        return mcus_x * mcus_y;
    }

    /// An arithmetic-coded scan's data: random bytes for each restart
    /// interval, more or fewer than the decoder reads.
    fn randomData(g: *Gen, comps: []const u8) void {
        const total = g.mcuCount(comps, 8);
        const per = if (g.restart == 0) total else g.restart;
        var done: u32 = 0;
        var next_rst: u8 = 0;
        while (done < total) : (done += per) {
            if (done > 0) {
                g.o.marker(0xd0 + next_rst);
                next_rst = (next_rst + 1) & 7;
            }
            const n = g.random.uintAtMost(u32, 2 + 12 * @min(per, total - done));
            for (0..n) |_| {
                if (g.o.full()) return;
                const c = g.random.int(u8);
                g.o.byte(c);
                if (c == 0xff) g.o.byte(0);
            }
        }
    }

    /// A lossless scan: each sample's difference category and bits, in
    /// MCU order.
    fn losslessScan(g: *Gen, comps: []const u8, psv: u8, pt: u8) void {
        g.sos(comps, psv, 0, 0, pt);
        var b: Bits = .{ .out = g.o };
        var mcus: u32 = 0;
        var next_rst: u8 = 0;
        for (0..g.mcuCount(comps, 1)) |_| {
            if (g.o.full()) return;
            if (g.restart != 0 and mcus == g.restart) {
                b.flush();
                g.o.marker(0xd0 + next_rst);
                next_rst = (next_rst + 1) & 7;
                mcus = 0;
            }
            mcus += 1;
            for (comps) |ci| {
                const n: u32 = if (comps.len == 1) 1 else @as(u32, g.h[ci]) * g.v[ci];
                for (0..n) |_| {
                    const t = &g.dc[tableOf(ci)];
                    const top: u5 = if (g.chance(8)) 15 else 4;
                    const cat: u5 = if (g.chance(3)) 0 else if (g.chance(16)) 16 else g.random.uintAtMost(u5, top);
                    t.write(&b, cat);
                    if (cat != 16) g.magnitude(&b, cat);
                }
            }
        }
        b.flush();
    }

    const Kind = enum { sequential, dc_first, dc_refine, ac_first, ac_refine };

    fn block(g: *Gen, b: *Bits, ci: u8, index: u32, kind: Kind, ss: u8, se: u8, eobrun: *u32) void {
        const dc = &g.dc[tableOf(ci)];
        const ac = &g.ac[tableOf(ci)];
        const nz = &g.nonzero[ci][index % max_blocks];
        switch (kind) {
            .sequential, .dc_first => {
                const cat: u5 = if (g.chance(3)) 0 else g.random.uintAtMost(u5, if (g.chance(8)) 11 else 4);
                dc.write(b, cat);
                g.magnitude(b, cat);
                if (kind == .dc_first) return;
                var k: u32 = 1;
                while (k < 64) {
                    if (g.chance(3)) {
                        ac.write(b, 0); // EOB
                        return;
                    }
                    if (g.chance(12) and k + 16 < 64) {
                        ac.write(b, 0xf0);
                        k += 16;
                        continue;
                    }
                    const run = g.random.uintAtMost(u32, @min(15, 63 - k));
                    const size: u5 = 1 + g.random.uintLessThan(u5, if (g.chance(8)) 10 else 3);
                    ac.write(b, @intCast(run << 4 | size));
                    g.magnitude(b, size);
                    k += run + 1;
                }
            },
            .dc_refine => b.put(g.random.int(u1), 1),
            .ac_first => {
                if (eobrun.* > 0) {
                    eobrun.* -= 1;
                    return;
                }
                var k: u32 = ss;
                while (k <= se) {
                    if (g.chance(3)) {
                        // An end-of-band run of 2^r plus r bits.
                        const r: u5 = if (g.chance(2)) 0 else g.random.uintAtMost(u5, 3);
                        ac.write(b, @as(u8, r) << 4);
                        const extra = g.random.uintLessThan(u32, @as(u32, 1) << r);
                        if (r != 0) b.put(extra, r);
                        eobrun.* = (@as(u32, 1) << r) + extra - 1;
                        return;
                    }
                    const run = g.random.uintAtMost(u32, @min(15, se - k));
                    const size: u5 = 1 + g.random.uintLessThan(u5, 3);
                    ac.write(b, @intCast(run << 4 | size));
                    g.magnitude(b, size);
                    k += run;
                    nz.* |= @as(u64, 1) << @intCast(k);
                    k += 1;
                }
            },
            .ac_refine => {
                var k: u32 = ss;
                if (eobrun.* == 0) {
                    while (k <= se) {
                        // Zero coefficients left in the band.
                        var zeros: u32 = 0;
                        for (k..@as(usize, se) + 1) |i| zeros += @intFromBool(nz.* >> @intCast(i) & 1 == 0);
                        if (zeros == 0 or g.chance(3)) {
                            const r: u5 = if (g.chance(2)) 0 else g.random.uintAtMost(u5, 2);
                            ac.write(b, @as(u8, r) << 4);
                            const extra = g.random.uintLessThan(u32, @as(u32, 1) << r);
                            if (r != 0) b.put(extra, r);
                            eobrun.* = (@as(u32, 1) << r) + extra;
                            break;
                        }
                        // A new coefficient after `run` zeros, correcting
                        // the nonzero ones passed.
                        const run = g.random.uintLessThan(u32, @min(zeros, 15));
                        ac.write(b, @intCast(run << 4 | 1));
                        b.put(g.random.int(u1), 1);
                        var left = run;
                        while (k <= se) : (k += 1) {
                            if (nz.* >> @intCast(k) & 1 != 0) {
                                b.put(g.random.int(u1), 1);
                            } else {
                                if (left == 0) break;
                                left -= 1;
                            }
                        }
                        nz.* |= @as(u64, 1) << @intCast(@min(k, 63));
                        k += 1;
                    }
                }
                if (eobrun.* > 0) {
                    while (k <= se) : (k += 1) {
                        if (nz.* >> @intCast(k) & 1 != 0) b.put(g.random.int(u1), 1);
                    }
                    eobrun.* -= 1;
                }
            },
        }
    }

    fn scans(g: *Gen) void {
        var all: [4]u8 = .{ 0, 1, 2, 3 };
        if (g.coding == .lossless) {
            const psv = 1 + g.random.uintLessThan(u8, 7);
            const pt = if (g.chance(4)) g.random.uintLessThan(u8, g.precision) else 0;
            if (g.ncomp > 1 and g.restart == 0 and g.chance(4)) {
                for (0..g.ncomp) |ci| g.losslessScan(&.{@intCast(ci)}, psv, pt);
            } else g.losslessScan(all[0..g.ncomp], psv, pt);
            return;
        }
        if (!g.progressive) {
            if (g.ncomp > 1 and g.chance(4)) {
                // One scan per component.
                for (0..g.ncomp) |ci| g.scan(&.{@intCast(ci)}, .sequential, 0, 63, 0);
            } else g.scan(all[0..g.ncomp], .sequential, 0, 63, 0);
            return;
        }
        // DC with successive approximation, then each component's AC
        // bands, each refined down to bit 0.
        const dc_al = g.random.uintAtMost(u8, 2);
        g.scan(all[0..g.ncomp], .dc_first, 0, 0, dc_al);
        var al = dc_al;
        while (al > 0) : (al -= 1) g.scan(all[0..g.ncomp], .dc_refine, 0, 0, al - 1);
        for (0..g.ncomp) |ci| {
            var ss: u8 = 1;
            while (ss <= 63) {
                const se: u8 = if (g.chance(2)) 63 else @min(63, ss + g.random.uintAtMost(u8, 20));
                const band_al = g.random.uintAtMost(u8, 2);
                g.scan(&.{@intCast(ci)}, .ac_first, ss, se, band_al);
                var a = band_al;
                while (a > 0) : (a -= 1) g.scan(&.{@intCast(ci)}, .ac_refine, ss, se, a - 1);
                ss = se + 1;
            }
        }
    }
};

/// A JPEG walked through the decoder's states, usually complete and
/// valid, with a damaged byte or a missing end now and then.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    var o: Out = .{ .buf = buf };
    const ncomp: u8 = switch (random.uintLessThan(u8, 8)) {
        0, 1 => 1,
        2 => 4,
        // Gray and alpha, as TIFF writes them.
        3 => 2,
        else => 3,
    };
    var g: Gen = .{
        .random = random,
        .o = &o,
        .width = 1 + random.uintLessThan(u16, if (random.uintLessThan(u8, 8) == 0) 300 else max_side),
        .height = 1 + random.uintLessThan(u16, max_side),
        .ncomp = ncomp,
        .h = @splat(1),
        .v = @splat(1),
        .ids = .{ 1, 2, 3, 4 },
        .progressive = random.boolean(),
        .restart = if (random.uintLessThan(u8, 4) == 0) 1 + random.uintLessThan(u16, 6) else 0,
    };
    if (random.uintLessThan(u8, 8) == 0) g.ids = .{ 'R', 'G', 'B', 'A' };
    switch (random.uintLessThan(u8, 8)) {
        0 => g.coding = .arithmetic,
        1 => {
            g.coding = .lossless;
            g.progressive = false;
            g.precision = 2 + random.uintLessThan(u8, 15);
        },
        else => {},
    }
    if (g.coding != .lossless and random.uintLessThan(u8, 6) == 0) g.precision = 12;
    // Sampling: usually a common chroma layout, sometimes any factors up
    // to 4 with at most 10 blocks per MCU.
    switch (random.uintLessThan(u8, 6)) {
        0 => {},
        1 => g.h[0] = 2,
        2 => {
            g.h[0] = 2;
            g.v[0] = 2;
        },
        3 => g.v[0] = 2,
        else => {
            var blocks: u32 = 0;
            for (0..ncomp) |i| {
                g.h[i] = 1 + random.uintLessThan(u8, 4);
                g.v[i] = 1 + random.uintLessThan(u8, 4);
                if (blocks + @as(u32, g.h[i]) * g.v[i] > 10) {
                    g.h[i] = 1;
                    g.v[i] = 1;
                }
                blocks += @as(u32, g.h[i]) * g.v[i];
            }
        },
    }
    for (0..ncomp) |i| {
        g.hmax = @max(g.hmax, g.h[i]);
        g.vmax = @max(g.vmax, g.v[i]);
    }
    // A lossless restart interval is whole MCU rows.
    if (g.coding == .lossless and g.restart != 0) {
        g.restart = @intCast(random.uintAtMost(u32, 2) * ((g.width + @as(u32, g.hmax) - 1) / g.hmax));
    }
    const mcus_x = (g.width + 8 * @as(u32, g.hmax) - 1) / (8 * @as(u32, g.hmax));
    for (0..ncomp) |i| {
        g.bw[i] = mcus_x * g.h[i];
        g.wb[i] = ((g.width * @as(u32, g.h[i]) + g.hmax - 1) / g.hmax + 7) / 8;
        g.hb[i] = ((g.height * @as(u32, g.v[i]) + g.vmax - 1) / g.vmax + 7) / 8;
        @memset(&g.nonzero[i], 0);
    }
    g.header();
    g.defineTables();
    g.scans();
    if (random.uintLessThan(u8, 16) != 0) o.marker(0xd9);
    return buf[0..o.len];
}

/// Hand-written seeds for the coverage-guided fuzzer: an 8×8 gray
/// baseline image of one flat block.
pub const seeds = [_][]const u8{
    "\xff\xd8" ++
        "\xff\xdb\x00\x43\x00" ++ @as([64]u8, @splat(0x01)) ++
        "\xff\xc0\x00\x0b\x08\x00\x08\x00\x08\x01\x01\x11\x00" ++
        "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00" ++
        "\x28\xff\xd9",
};

test "fuzz" {
    try harness.zigFuzz(@This());
}
