//! The PNG fuzz target: the decoder properties in harness.zig, on mutated
//! corpus files and generated files that reach every chunk the decoder
//! reads, still and animated. Mutation breaks CRCs, so `check` sometimes
//! rewrites every chunk's CRC first, letting a mutated file get past the
//! chunk layer. The properties run with `ignore_checksums` off or on, and
//! the two settings must agree wherever the strict decode got without a
//! checksum error.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "png";

pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/png" };
pub const extensions = [_][]const u8{ ".png", ".apng" };

var fixed: [1 << 20]u8 = undefined;

pub fn check(input: []const u8, choice: u64) !void {
    var file = input;
    if (choice >> 63 == 1 and input.len <= fixed.len) {
        @memcpy(fixed[0..input.len], input);
        fixCrcs(fixed[0..input.len]);
        file = fixed[0..input.len];
    }
    try compareLax(file);
    if (choice >> 62 & 1 == 1) return harness.checkDecoder(Lax, file, choice);
    return harness.checkDecoder(image.png.Decoder, file, choice);
}

/// `image.png.Decoder` with `ignore_checksums` set.
const Lax = struct {
    d: image.png.Decoder,

    pub const Options = image.png.Decoder.Options;
    pub const Error = image.png.Decoder.Error;

    pub fn init(reader: *std.Io.Reader, options: Options) Lax {
        var o = options;
        o.ignore_checksums = true;
        return .{ .d = .init(reader, o) };
    }

    pub fn decodeConfig(l: *Lax) Error!image.Config {
        return l.d.decodeConfig();
    }

    pub fn decodeFrame(l: *Lax, dst: image.PixelBuffer, work: []u8) Error!?image.Frame {
        return l.d.decodeFrame(dst, work);
    }
};

const Run = struct {
    err: ?image.png.Decoder.Error = null,
    count: usize = 0,
    frames: [harness.limits.max_frames]image.Frame = undefined,
    hashes: [harness.limits.max_frames]u64 = undefined,

    fn same(a: *const Run, b: *const Run, n: usize) bool {
        for (0..n) |i| {
            if (!std.meta.eql(a.frames[i], b.frames[i]) or a.hashes[i] != b.hashes[i]) return false;
        }
        return true;
    }
};

var canvas: [harness.limits.max_pixels * 8]u8 = undefined;
var work_memory: [1 << 20]u8 = undefined;

/// Decodes every frame of `input` in its native format.
fn run(input: []const u8, ignore_checksums: bool) Run {
    var result: Run = .{};
    var r: std.Io.Reader = .fixed(input);
    var d: image.png.Decoder = .init(&r, .{ .limits = harness.limits, .ignore_checksums = ignore_checksums });
    const config = d.decodeConfig() catch |e| {
        result.err = e;
        return result;
    };
    if (config.work_len > work_memory.len) return result;
    const dst = image.PixelBuffer.init(&canvas, config.native, config.width, config.height) catch return result;
    const len = image.PixelBuffer.len(config.native, config.width, config.height).?;
    @memset(canvas[0..len], 0);
    while (result.count < result.frames.len) : (result.count += 1) {
        const frame = d.decodeFrame(dst, work_memory[0..config.work_len]) catch |e| {
            result.err = e;
            return result;
        } orelse return result;
        result.frames[result.count] = frame;
        result.hashes[result.count] = std.hash.Wyhash.hash(0, canvas[0..len]);
    }
    return result;
}

/// With checksums ignored, a decode matches the strict one up to its first
/// checksum error, and entirely when it has none.
fn compareLax(input: []const u8) !void {
    const strict = run(input, false);
    const lax = run(input, true);
    if (strict.err) |e| if (e == error.BadCrc or e == error.BadChecksum) {
        if (lax.count < strict.count or !strict.same(&lax, strict.count)) return error.LaxDiffers;
        return;
    };
    if (errorCode(lax.err) != errorCode(strict.err) or lax.count != strict.count or !strict.same(&lax, strict.count))
        return error.LaxDiffers;
}

/// An optional error as an integer, 0 for none: Zig 0.16's x86_64 backend
/// (Debug's default) miscompiles `==` on two optional errors, reading a
/// flag byte they do not have, so equal errors can compare unequal
/// (harness.zig's `errorCode` has the same workaround).
fn errorCode(err: ?image.png.Decoder.Error) u16 {
    return if (err) |e| @intFromError(e) else 0;
}

/// Rewrites the CRC of every whole chunk after the signature.
fn fixCrcs(file: []u8) void {
    var at: usize = 8;
    while (file.len >= at + 12) {
        const len = std.mem.readInt(u32, file[at..][0..4], .big);
        if (len > file.len - at - 12) return;
        const crc = std.hash.Crc32.hash(file[at + 4 ..][0 .. 4 + len]);
        std.mem.writeInt(u32, file[at + 8 + len ..][0..4], crc, .big);
        at += 12 + len;
    }
}

/// Writes into a buffer, dropping what does not fit: a file that runs out
/// of room comes out truncated.
const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn put(o: *Out, bytes: []const u8) void {
        const n = @min(bytes.len, o.buf.len - o.len);
        @memcpy(o.buf[o.len..][0..n], bytes[0..n]);
        o.len += n;
    }

    fn int(o: *Out, comptime T: type, v: T) void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .big);
        o.put(&b);
    }

    fn chunk(o: *Out, random: std.Random, kind: *const [4]u8, data: []const u8) void {
        o.int(u32, @intCast(data.len));
        o.put(kind);
        o.put(data);
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        // Now and then a bad CRC.
        o.int(u32, if (random.uintLessThan(u16, 200) == 0) random.int(u32) else crc.final());
    }
};

const passes = [7][4]u32{
    .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 },
    .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
};

var raw_buf: [1 << 16]u8 = undefined;
var z_buf: [(1 << 16) * 9 / 8 + 64]u8 = undefined;

/// A zlib stream of `data`: stored blocks, or one fixed-Huffman block of
/// literals and matches at distance 1 and `far` (the row above, say),
/// written here because fuzz targets import only the package.
fn zlibStream(data: []const u8, out: []u8, stored: bool, far: usize) usize {
    out[0] = 0x78;
    out[1] = 0x01;
    var bw: Bits = .{ .out = out, .len = 2 };
    if (stored) {
        var at: usize = 0;
        while (true) {
            const n = @min(data.len - at, 65535);
            const last = at + n == data.len;
            bw.put(@intFromBool(last), 3);
            bw.flush();
            std.mem.writeInt(u16, out[bw.len..][0..2], @intCast(n), .little);
            std.mem.writeInt(u16, out[bw.len + 2 ..][0..2], ~@as(u16, @intCast(n)), .little);
            @memcpy(out[bw.len + 4 ..][0..n], data[at..][0..n]);
            bw.len += 4 + n;
            at += n;
            if (last) break;
        }
    } else {
        bw.put(0b011, 3);
        var i: usize = 0;
        while (i < data.len) {
            var best: usize = 0;
            var dist: usize = 0;
            for ([_]usize{ 1, far }) |dd| {
                if (dd == 0 or dd > i) continue;
                var n: usize = 0;
                while (n < 258 and i + n < data.len and data[i + n] == data[i + n - dd]) n += 1;
                if (n > best) {
                    best = n;
                    dist = dd;
                }
            }
            if (best >= 3) {
                bw.length(best);
                bw.distance(dist);
                i += best;
            } else {
                bw.literal(data[i]);
                i += 1;
            }
        }
        bw.literal(256);
        bw.flush();
    }
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    std.mem.writeInt(u32, out[bw.len..][0..4], b << 16 | a, .big);
    return bw.len + 4;
}

/// DEFLATE's bit order: values least significant bit first, Huffman codes
/// most significant first.
const Bits = struct {
    out: []u8,
    len: usize,
    acc: u64 = 0,
    count: u6 = 0,

    fn put(b: *Bits, v: u64, n: u6) void {
        b.acc |= v << b.count;
        b.count += n;
        while (b.count >= 8) {
            b.out[b.len] = @truncate(b.acc);
            b.len += 1;
            b.acc >>= 8;
            b.count -= 8;
        }
    }

    fn code(b: *Bits, c: u16, n: u4) void {
        const shift: u4 = @intCast(16 - @as(u5, n));
        b.put(@bitReverse(c) >> shift, n);
    }

    fn flush(b: *Bits) void {
        if (b.count > 0) b.put(0, 8 - b.count);
    }

    /// Fixed-Huffman literal/length symbols (RFC 1951, section 3.2.6).
    fn literal(b: *Bits, sym: u16) void {
        if (sym < 144) {
            b.code(0x30 + sym, 8);
        } else if (sym < 256) {
            b.code(0x190 + sym - 144, 9);
        } else if (sym < 280) {
            b.code(sym - 256, 7);
        } else b.code(0xc0 + sym - 280, 8);
    }

    fn length(b: *Bits, len: usize) void {
        const base = [_]u16{
            3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23,  27,
            31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
        };
        var i: usize = base.len - 1;
        while (base[i] > len) i -= 1;
        b.literal(@intCast(257 + i));
        const extra: u6 = if (i < 8 or i == 28) 0 else @intCast((i - 4) / 4);
        b.put(len - base[i], extra);
    }

    fn distance(b: *Bits, dist: usize) void {
        var i: u16 = 0;
        var base: usize = 1;
        while (true) : (i += 1) {
            const extra: u6 = if (i < 4) 0 else @intCast((i - 2) / 2);
            if (dist < base + (@as(usize, 1) << extra)) {
                b.code(i, 5);
                b.put(dist - base, extra);
                return;
            }
            base += @as(usize, 1) << extra;
        }
    }
};

/// Image data for a `w` by `h` frame: random filtered rows (filter types
/// mostly valid) with sometimes a row too many or too few, compressed and
/// split into chunks of `kind`, numbered from `seq` for fdAT.
fn imageData(
    o: *Out,
    random: std.Random,
    kind: *const [4]u8,
    w: u32,
    h: u32,
    bits: u32,
    interlaced: bool,
    seq: *u32,
) void {
    var len: usize = 0;
    const list: []const [4]u32 = if (interlaced) &passes else &.{.{ 0, 0, 1, 1 }};
    for (list) |p| {
        if (w <= p[0] or h <= p[1]) continue;
        const pw = (w - p[0] + p[2] - 1) / p[2];
        const ph = (h - p[1] + p[3] - 1) / p[3];
        const n = (pw * bits + 7) / 8;
        for (0..ph) |_| {
            if (len + n + 1 > raw_buf.len) break;
            raw_buf[len] = if (random.uintLessThan(u8, 64) == 0) random.int(u8) else random.uintLessThan(u8, 5);
            // Smooth rows compress and exercise matches; random ones literals.
            if (random.boolean()) {
                random.bytes(raw_buf[len + 1 ..][0..n]);
            } else {
                const v = random.int(u8);
                @memset(raw_buf[len + 1 ..][0..n], v);
            }
            len += n + 1;
        }
    }
    switch (random.uintLessThan(u8, 32)) {
        0 => len -= @min(len, random.uintAtMost(usize, 8)),
        1 => len = @min(raw_buf.len, len + random.uintAtMost(usize, 8)),
        else => {},
    }
    const row = (w * bits + 7) / 8 + 1;
    const zn = zlibStream(raw_buf[0..len], &z_buf, random.uintLessThan(u8, 4) == 0, row);
    // Rarely, a wrong Adler-32.
    if (random.uintLessThan(u8, 64) == 0) z_buf[zn - 1] ^= 1;
    const split = 1 + random.uintAtMost(usize, if (random.boolean()) 64 else zn);
    var at: usize = 0;
    var chunk_buf: [1 << 16]u8 = undefined;
    while (true) {
        const k = @min(split, zn - at, chunk_buf.len - 4);
        if (std.mem.eql(u8, kind, "fdAT")) {
            std.mem.writeInt(u32, chunk_buf[0..4], seq.*, .big);
            seq.* += 1;
            @memcpy(chunk_buf[4..][0..k], z_buf[at..][0..k]);
            o.chunk(random, kind, chunk_buf[0 .. 4 + k]);
        } else o.chunk(random, kind, z_buf[at..][0..k]);
        at += k;
        if (at == zn) break;
    }
}

/// A PNG of random chunks: usually a valid still or animated file, every
/// color type and depth, sometimes broken.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    var o: Out = .{ .buf = buf };
    const kinds = [_][2]u8{
        .{ 0, 1 }, .{ 0, 2 },  .{ 0, 4 },  .{ 0, 8 }, .{ 0, 16 },
        .{ 2, 8 }, .{ 2, 16 }, .{ 3, 1 },  .{ 3, 2 }, .{ 3, 4 },
        .{ 3, 8 }, .{ 4, 8 },  .{ 4, 16 }, .{ 6, 8 }, .{ 6, 16 },
    };
    const kind = kinds[random.uintLessThan(usize, kinds.len)];
    var color = kind[0];
    var depth = kind[1];
    if (random.uintLessThan(u8, 64) == 0) color = random.int(u8);
    if (random.uintLessThan(u8, 64) == 0) depth = random.int(u8);
    const w = 1 + random.uintLessThan(u32, if (random.uintLessThan(u8, 8) == 0) 300 else 24);
    const h = 1 + random.uintLessThan(u32, 24);
    const interlaced = random.uintLessThan(u8, 3) == 0;
    const channels: u32 = switch (color) {
        2 => 3,
        4 => 2,
        6 => 4,
        else => 1,
    };
    const bits = channels * @min(depth, 16);
    o.put("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ depth, color, 0, 0, @intFromBool(interlaced) };
    o.chunk(random, "IHDR", &ihdr);

    var scratch: [1024]u8 = undefined;
    const palette_len: usize = 1 + random.uintLessThan(usize, if (depth < 8) @as(usize, 1) << @intCast(depth) else 256);
    const animated = random.uintLessThan(u8, 4) == 0;
    const frames: u32 = 1 + random.uintLessThan(u32, 4);
    const default_is_frame = random.boolean();
    var seq: u32 = 0;

    // Ancillary chunks before IDAT, in a random order.
    var order: [12]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    random.shuffle(u8, &order);
    var plte_done = false;
    for (order) |which| {
        if (random.uintLessThan(u8, 3) == 0) continue;
        switch (which) {
            0 => if (color == 3 or random.uintLessThan(u8, 8) == 0) {
                random.bytes(scratch[0 .. palette_len * 3]);
                o.chunk(random, "PLTE", scratch[0 .. palette_len * 3]);
                plte_done = true;
            },
            1 => {
                const n: usize = switch (color) {
                    0 => 2,
                    2 => 6,
                    3 => random.uintAtMost(usize, palette_len),
                    else => random.uintLessThan(usize, 8),
                };
                random.bytes(scratch[0..n]);
                // Keys usually small, so pixels match them.
                if (color == 0 or color == 2) for (0..n / 2) |i| {
                    scratch[i * 2] = 0;
                    scratch[i * 2 + 1] &= 3;
                };
                if (color != 3 or plte_done or random.uintLessThan(u8, 8) == 0) o.chunk(random, "tRNS", scratch[0..n]);
            },
            2 => {
                o.int(u32, 4);
                o.put("gAMA");
                o.int(u32, 45455);
                o.int(u32, std.hash.Crc32.hash("gAMA\x00\x00\xb1\x8f"));
            },
            3 => {
                random.bytes(scratch[0..32]);
                o.chunk(random, "cHRM", scratch[0..32]);
            },
            4 => o.chunk(random, "sRGB", &.{random.uintLessThan(u8, 5)}),
            5 => {
                const n = random.uintLessThan(usize, 100);
                @memcpy(scratch[0..5], "icc\x00\x00");
                random.bytes(scratch[5..][0..n]);
                o.chunk(random, "iCCP", scratch[0 .. 5 + n]);
            },
            6 => {
                const exif = "MM\x00*\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00";
                o.chunk(random, "eXIf", exif);
            },
            7 => {
                random.bytes(scratch[0..9]);
                scratch[8] &= 1;
                o.chunk(random, "pHYs", scratch[0..9]);
            },
            8 => {
                const n: usize = switch (color) {
                    3 => 1,
                    0, 4 => 2,
                    else => 6,
                };
                random.bytes(scratch[0..n]);
                o.chunk(random, "bKGD", scratch[0..n]);
            },
            9 => o.chunk(random, "tEXt", "Comment\x00fuzz"),
            10 => if (animated) {
                std.mem.writeInt(u32, scratch[0..4], if (random.uintLessThan(u8, 32) == 0) 0 else frames, .big);
                std.mem.writeInt(u32, scratch[4..8], random.uintLessThan(u32, 3), .big);
                o.chunk(random, "acTL", scratch[0..8]);
            },
            else => o.chunk(random, "prVt", "private"),
        }
    }
    const fctl = struct {
        fn write(out: *Out, r: std.Random, s: *u32, cw: u32, ch: u32, whole: bool) [2]u32 {
            var b: [26]u8 = undefined;
            const fw = if (whole) cw else 1 + r.uintLessThan(u32, cw);
            const fh = if (whole) ch else 1 + r.uintLessThan(u32, ch);
            const x = if (whole) 0 else r.uintAtMost(u32, cw - fw);
            const y = if (whole) 0 else r.uintAtMost(u32, ch - fh);
            std.mem.writeInt(u32, b[0..4], s.*, .big);
            s.* += 1;
            for ([_]u32{ fw, fh, x, y }, 0..) |v, i| std.mem.writeInt(u32, b[4 + i * 4 ..][0..4], v, .big);
            std.mem.writeInt(u16, b[20..22], r.uintLessThan(u16, 10), .big);
            std.mem.writeInt(u16, b[22..24], r.uintLessThan(u16, 3) * 50, .big);
            b[24] = r.uintLessThan(u8, 3);
            b[25] = r.uintLessThan(u8, 2);
            // Now and then a broken field.
            if (r.uintLessThan(u8, 32) == 0) b[r.uintLessThan(usize, 26)] = r.int(u8);
            out.chunk(r, "fcTL", &b);
            return .{ fw, fh };
        }
    };
    if (animated and default_is_frame) _ = fctl.write(&o, random, &seq, w, h, true);
    imageData(&o, random, "IDAT", w, h, bits, interlaced, &seq);
    if (animated) {
        const rest = if (default_is_frame) frames - 1 else frames;
        for (0..rest) |_| {
            const size = fctl.write(&o, random, &seq, w, h, random.uintLessThan(u8, 4) == 0);
            imageData(&o, random, "fdAT", size[0], size[1], bits, interlaced, &seq);
        }
    }
    if (random.uintLessThan(u8, 4) == 0) o.chunk(random, "tIME", "\x07\xea\x0b\x01\x00\x00\x00");
    if (random.uintLessThan(u8, 32) != 0) o.chunk(random, "IEND", "");
    return buf[0..o.len];
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk: a 1x1 gray image, a 2x2 interlaced palette image with tRNS,
/// and a two-frame APNG whose second frame blends.
pub const seeds = [_][]const u8{
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x00\x00\x00\x00\x3a\x7e\x9b\x55\x00\x00\x00\x0a\x49\x44\x41\x54\x78\x9c\x63\x68\x00\x00\x00" ++
        "\x82\x00\x81\x77\xcd\x72\xb6\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82",
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x02" ++
        "\x02\x03\x00\x00\x01\x78\xdf\xd5\x21\x00\x00\x00\x09\x50\x4c\x54\x45\xff\x00\x00\x00\xff\x00\x00" ++
        "\x00\xff\x2d\x4a\xcd\x8a\x00\x00\x00\x01\x74\x52\x4e\x53\x80\xad\x5e\x5b\x46\x00\x00\x00\x0e\x49" ++
        "\x44\x41\x54\x78\x9c\x63\x70\x60\x68\x60\xb8\x00\x00\x03\x96\x01\x91\xf9\x32\x07\x00\x00\x00\x00" ++
        "\x00\x49\x45\x4e\x44\xae\x42\x60\x82",
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x02" ++
        "\x08\x06\x00\x00\x00\x72\xb6\x0d\x24\x00\x00\x00\x08\x61\x63\x54\x4c\x00\x00\x00\x02\x00\x00\x00" ++
        "\x00\xf3\x8d\x93\x70\x00\x00\x00\x1a\x66\x63\x54\x4c\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00" ++
        "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x0a\x00\x00\xe8\x54\xdc\x00\x00\x00\x00\x15\x49" ++
        "\x44\x41\x54\x78\x9c\x63\x10\x50\x30\xf8\x0f\xc2\x0c\x0e\x01\x09\x0d\x20\x0c\x00\x2e\x5a\x05\x9f" ++
        "\x9a\x4a\xaa\x4f\x00\x00\x00\x1a\x66\x63\x54\x4c\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x00\x01\x00\x0a\x01\x01\xc8\xe9\x0f\xa7\x00\x00\x00\x11\x66\x64" ++
        "\x41\x54\x00\x00\x00\x02\x78\x9c\x63\xf8\xcf\xc0\xd0\x00\x00\x04\x81\x01\x80\x3f\x59\x60\xc9\x00" ++
        "\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82",
};

test "png on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}

test "compareLax holds on the seeds whatever the stack holds" {
    // A miscompiled comparison of optional errors read stale stack bytes;
    // these patterns made it fail.
    for (0..8) |i| {
        dirtyStack(@truncate(i * 37));
        for (seeds) |s| try compareLax(s);
    }
}

/// Fills the stack below the caller with alternating `v` and `~v` pairs.
noinline fn dirtyStack(v: u8) void {
    var junk: [8192]u8 = undefined;
    for (&junk, 0..) |*b, i| b.* = if (i & 2 == 0) v else ~v;
    std.mem.doNotOptimizeAway(&junk);
}
