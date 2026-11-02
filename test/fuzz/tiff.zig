//! The TIFF fuzz target: the decoder properties in harness.zig, on mutated
//! corpus files and generated files, both reading forward only and with a
//! seeker over the input, and generated files of every layout,
//! compression, and sample format the decoder reads.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "tiff";

pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor", "bench/corpus-gen/tiff" };
pub const extensions = [_][]const u8{ ".tif", ".tiff" };

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkDecoder(image.tiff.Decoder, input, choice);
}

/// Writes TIFF structures into a buffer, in either byte order.
const Out = struct {
    buf: []u8,
    len: usize = 0,
    endian: std.builtin.Endian,
    big: bool,
    full: bool = false,

    fn room(o: *const Out, n: usize) bool {
        return o.len + n <= o.buf.len;
    }

    fn bytes(o: *Out, b: []const u8) void {
        if (!o.room(b.len)) {
            o.full = true;
            return;
        }
        @memcpy(o.buf[o.len..][0..b.len], b);
        o.len += b.len;
    }

    fn int(o: *Out, comptime T: type, v: T) void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, o.endian);
        o.bytes(&b);
    }

    fn word(o: *Out, v: u64) void {
        if (o.big) o.int(u64, v) else o.int(u32, @truncate(v));
    }

    fn putAt(o: *Out, at: usize, v: u64) void {
        if (o.big) {
            if (at + 8 <= o.buf.len) std.mem.writeInt(u64, o.buf[at..][0..8], v, o.endian);
        } else if (at + 4 <= o.buf.len) std.mem.writeInt(u32, o.buf[at..][0..4], @truncate(v), o.endian);
    }
};

const Entry = struct {
    tag: u16,
    type: u16,
    count: u32,
    /// The values, as u64s, for integer and rational types (a rational
    /// takes two).
    values: []const u64,
};

fn typeSize(t: u16) usize {
    return switch (t) {
        1, 2, 6, 7 => 1,
        3, 8 => 2,
        4, 9, 11, 13 => 4,
        else => 8,
    };
}

fn putValue(o: *Out, t: u16, v: u64) void {
    switch (t) {
        1, 2, 6, 7 => o.bytes(&.{@truncate(v)}),
        3, 8 => o.int(u16, @truncate(v)),
        4, 9, 11, 13 => o.int(u32, @truncate(v)),
        5, 10 => o.int(u32, @truncate(v)),
        else => o.int(u64, v),
    }
}

/// The values' bytes in an entry or stored elsewhere.
fn valueLen(e: Entry) usize {
    return typeSize(e.type) * e.count;
}

/// Bytes an IFD with `entries` takes, its stored values included.
fn ifdLen(o: *const Out, entries: []const Entry) usize {
    const inline_len: usize = if (o.big) 8 else 4;
    var n: usize = (if (o.big) @as(usize, 8 + 20 * entries.len + 8) else 2 + 12 * entries.len + 4);
    for (entries) |e| {
        const l = valueLen(e);
        if (l > inline_len) n += l + (l & 1);
    }
    return n;
}

/// Writes an IFD at the end of `o` and returns where its next-IFD offset
/// is.
fn writeIfd(o: *Out, entries: []const Entry) usize {
    const inline_len: usize = if (o.big) 8 else 4;
    var ext = o.len + (if (o.big) @as(usize, 8 + 20 * entries.len + 8) else 2 + 12 * entries.len + 4);
    if (o.big) o.int(u64, entries.len) else o.int(u16, @intCast(entries.len));
    for (entries) |e| {
        o.int(u16, e.tag);
        o.int(u16, e.type);
        if (o.big) o.int(u64, e.count) else o.int(u32, e.count);
        const l = valueLen(e);
        if (l <= inline_len) {
            for (e.values) |v| putValue(o, e.type, v);
            for (l..inline_len) |_| o.bytes(&.{0});
        } else {
            o.word(ext);
            ext += l + (l & 1);
        }
    }
    const next_at = o.len;
    o.word(0);
    for (entries) |e| {
        const l = valueLen(e);
        if (l <= inline_len) continue;
        for (e.values) |v| putValue(o, e.type, v);
        if (l & 1 != 0) o.bytes(&.{0});
    }
    return next_at;
}

const Compression = enum(u16) { none = 1, lzw = 5, deflate = 8, packbits = 32773, mh = 2, g3 = 3, g4 = 4, _ };

/// PackBits: literal runs, and repeats where bytes repeat.
fn packBits(random: std.Random, src: []const u8, o: *Out) void {
    var i: usize = 0;
    while (i < src.len) {
        var run: usize = 1;
        while (i + run < src.len and run < 128 and src[i + run] == src[i]) run += 1;
        if (run >= 2 and random.boolean()) {
            o.bytes(&.{@bitCast(@as(i8, @intCast(1 - @as(i16, @intCast(run)))))});
            o.bytes(&.{src[i]});
            i += run;
        } else {
            const n = @min(src.len - i, 1 + random.uintLessThan(usize, 128));
            o.bytes(&.{@intCast(n - 1)});
            o.bytes(src[i..][0..n]);
            i += n;
        }
    }
}

/// zlib with stored blocks.
fn zlibStored(src: []const u8, o: *Out) void {
    o.bytes(&.{ 0x78, 0x01 });
    var i: usize = 0;
    while (true) {
        const n = @min(src.len - i, 65535);
        const last = i + n == src.len;
        o.bytes(&.{@intFromBool(last)});
        var h: [4]u8 = undefined;
        std.mem.writeInt(u16, h[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, h[2..4], ~@as(u16, @intCast(n)), .little);
        o.bytes(&h);
        o.bytes(src[i..][0..n]);
        i += n;
        if (last) break;
    }
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, std.hash.Adler32.hash(src), .big);
    o.bytes(&b);
}

var lzw_keys: [8192]u32 = undefined;
var lzw_codes: [8192]u16 = undefined;

/// TIFF LZW, new style.
fn lzwEncode(src: []const u8, o: *Out) void {
    var bits: u64 = 0;
    var nbits: u6 = 0;
    var width: u4 = 9;
    const put = struct {
        fn f(out: *Out, b: *u64, n: *u6, w: u4, c: u16) void {
            b.* = b.* << w | c;
            n.* += w;
            while (n.* >= 8) {
                n.* -= 8;
                out.bytes(&.{@truncate(b.* >> n.*)});
            }
        }
    }.f;
    @memset(&lzw_keys, 0);
    var next: u16 = 258;
    put(o, &bits, &nbits, width, 256);
    var cur: ?u16 = null;
    for (src) |b| {
        if (cur) |c| {
            const key = (@as(u32, c) << 8 | b) + 1;
            var h = (key *% 2654435761) >> 19;
            while (lzw_keys[h] != 0 and lzw_keys[h] != key) h = (h + 1) & 8191;
            if (lzw_keys[h] == key) {
                cur = lzw_codes[h];
                continue;
            }
            put(o, &bits, &nbits, width, c);
            lzw_keys[h] = key;
            lzw_codes[h] = next;
            next += 1;
            if (next >= @as(u16, 1) << width and width < 12) width += 1;
            if (next == 4094) {
                put(o, &bits, &nbits, width, 256);
                @memset(&lzw_keys, 0);
                next = 258;
                width = 9;
            }
        }
        cur = b;
    }
    if (cur) |c| {
        put(o, &bits, &nbits, width, c);
        next += 1;
        if (next >= @as(u16, 1) << width and width < 12) width += 1;
    }
    put(o, &bits, &nbits, width, 257);
    if (nbits > 0) o.bytes(&.{@truncate(bits << (8 - nbits))});
}

var scratch: [1 << 15]u8 = undefined;
var data_buf: [1 << 16]u8 = undefined;

/// A TIFF file of one to three pages, usually valid: random byte order,
/// classic or BigTIFF, sizes, photometric interpretations, sample widths
/// and formats, extra samples, strips or tiles, planar or chunky,
/// compressions, predictors, and the IFDs before or after the data.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 1 << 12);
    var o: Out = .{
        .buf = buf,
        .endian = if (random.boolean()) .little else .big,
        .big = random.uintLessThan(u8, 4) == 0,
    };
    o.bytes(if (o.endian == .little) "II" else "MM");
    o.int(u16, if (o.big) 43 else 42);
    if (o.big) {
        o.int(u16, 8);
        o.int(u16, 0);
    }
    var next_at = o.len;
    o.word(0);
    const pages = 1 + @as(usize, if (random.uintLessThan(u8, 4) == 0) random.uintLessThan(u8, 3) else 0);
    for (0..pages) |_| {
        const at = page(random, &o) orelse break;
        o.putAt(next_at, at[0]);
        next_at = at[1];
    }
    return buf[0..o.len];
}

/// Writes one page, returning its IFD's offset and where its next-IFD
/// offset goes.
fn page(random: std.Random, o: *Out) ?[2]usize {
    const Model = enum { gray, white, rgb, palette, cmyk, ycbcr };
    const model = random.enumValue(Model);
    var bits: u16 = 8;
    var fmt: u16 = 1;
    switch (model) {
        .gray, .white => {
            const choices = [_]u16{ 1, 1, 2, 4, 8, 8, 16, 3, 5, 12, 24, 32 };
            bits = choices[random.uintLessThan(usize, choices.len)];
            if (bits >= 8 and random.uintLessThan(u8, 4) == 0) fmt = 2;
            if (model == .gray and random.uintLessThan(u8, 6) == 0) {
                const f = [_]u16{ 16, 24, 32, 64 };
                bits = f[random.uintLessThan(usize, 4)];
                fmt = 3;
            }
        },
        .rgb => {
            const choices = [_]u16{ 8, 8, 16, 4, 2, 10 };
            bits = choices[random.uintLessThan(usize, choices.len)];
            if (random.uintLessThan(u8, 8) == 0) {
                bits = 32;
                fmt = 3;
            }
        },
        .palette => bits = @as(u16, 1) << random.uintLessThan(u4, 4),
        .cmyk => bits = if (random.boolean()) 8 else 16,
        .ycbcr => bits = 8,
    }
    const cc: u16 = switch (model) {
        .gray, .white, .palette => 1,
        .rgb, .ycbcr => 3,
        .cmyk => 4,
    };
    var extra: u16 = 0;
    var extra_type: u16 = 0;
    if (model != .palette and model != .ycbcr and random.uintLessThan(u8, 3) == 0) {
        extra = 1 + @as(u16, random.uintLessThan(u8, 4) / 3);
        extra_type = random.uintLessThan(u16, 3);
    }
    const spp = cc + extra;
    var w: u32 = 1 + random.uintLessThan(u32, if (random.uintLessThan(u8, 8) == 0) 200 else 40);
    var h: u32 = 1 + random.uintLessThan(u32, 24);
    while (@as(u64, w) * h * spp * bits / 8 > 8000) {
        w = (w + 1) / 2;
        h = (h + 1) / 2;
    }
    var sub: [2]u16 = .{ 1, 1 };
    if (model == .ycbcr) {
        const s = [_][2]u16{ .{ 1, 1 }, .{ 2, 1 }, .{ 2, 2 }, .{ 4, 2 }, .{ 4, 1 } };
        sub = s[random.uintLessThan(usize, s.len)];
    }
    const subsampled = sub[0] != 1 or sub[1] != 1;
    const planar = spp > 1 and !subsampled and random.uintLessThan(u8, 4) == 0;
    const bilevel = (model == .gray or model == .white) and bits == 1 and spp == 1;
    const comps = [_]Compression{ .none, .none, .lzw, .lzw, .deflate, .packbits, .mh, .g3, .g4 };
    var comp = comps[random.uintLessThan(usize, if (bilevel) comps.len else 6)];
    if (random.uintLessThan(u8, 64) == 0) comp = @enumFromInt(random.uintLessThan(u16, 10));
    var predictor: u16 = 1;
    if ((comp == .lzw or comp == .deflate) and random.boolean()) {
        if (fmt == 3) predictor = if (random.boolean()) 3 else 2;
        if (bits == 8 or bits == 16 or bits == 32) predictor = if (fmt == 3) predictor else 2;
    }
    const tiled = random.uintLessThan(u8, 4) == 0;
    const v = sub[1];
    var cw: u32 = w;
    var ch: u32 = h;
    if (tiled) {
        const sizes = [_]u32{ 16, 16, 32, 8, 3 };
        cw = sizes[random.uintLessThan(usize, sizes.len)];
        ch = sizes[random.uintLessThan(usize, sizes.len)];
        if (subsampled) {
            cw = 16;
            ch = 16;
        }
    } else {
        ch = 1 + random.uintLessThan(u32, h);
        if (subsampled) ch = (ch + v - 1) / v * v;
        if (ch > h) ch = h;
    }
    const across = (w + cw - 1) / cw;
    const down = (h + ch - 1) / ch;
    const nplanes: u32 = if (planar) spp else 1;
    const chunks = across * down * nplanes;
    if (chunks > 512) return null;

    // The data: every chunk compressed into data_buf.
    var d: Out = .{ .buf = &data_buf, .endian = o.endian, .big = o.big };
    var offsets: [512]u64 = undefined;
    var counts: [512]u64 = undefined;
    const line: usize = if (subsampled)
        (cw + sub[0] - 1) / sub[0] * (sub[0] * sub[1] + 2)
    else
        (cw * (if (planar) 1 else spp) * bits + 7) / 8;
    for (0..chunks) |i| {
        const row = i % (across * down) / across;
        const rows = if (tiled) ch else @min(ch, h - @as(u32, @intCast(row)) * ch);
        const lines = if (subsampled) (rows + v - 1) / v else rows;
        const n = @min(line * lines, scratch.len);
        random.bytes(scratch[0..n]);
        offsets[i] = d.len;
        switch (comp) {
            .none => d.bytes(scratch[0..n]),
            .packbits => packBits(random, scratch[0..n], &d),
            .lzw => lzwEncode(scratch[0..n], &d),
            .deflate => zlibStored(scratch[0..n], &d),
            else => d.bytes(scratch[0 .. n / 4]),
        }
        counts[i] = d.len - offsets[i];
        if (random.uintLessThan(u8, 32) == 0) counts[i] = random.uintLessThan(u64, counts[i] + 2);
    }
    if (d.full) return null;

    // The IFD's entries, in tag order.
    var entries: [32]Entry = undefined;
    var ne: usize = 0;
    var vals: [8]u64 = undefined;
    const S = struct {
        var bits_v: [8]u64 = undefined;
        var fmt_v: [8]u64 = undefined;
        var extra_v: [4]u64 = undefined;
        var cmap: [768]u64 = undefined;
        var offs: [512]u64 = undefined;
        var cnts: [512]u64 = undefined;
        var res: [4]u64 = .{ 72, 1, 300, 2 };
    };
    _ = &vals;
    const add = struct {
        fn f(list: []Entry, n: *usize, tag: u16, t: u16, values: []const u64) void {
            const count = if (t == 5) values.len / 2 else values.len;
            list[n.*] = .{ .tag = tag, .type = t, .count = @intCast(count), .values = values };
            n.* += 1;
        }
    }.f;
    const photometric: u64 = switch (model) {
        .white => 0,
        .gray => 1,
        .rgb => 2,
        .palette => 3,
        .cmyk => 5,
        .ycbcr => 6,
    };
    const one = struct {
        var slots: [16][1]u64 = undefined;
        var i: usize = 0;
        fn of(x: u64) []const u64 {
            i = (i + 1) % 16;
            slots[i][0] = x;
            return &slots[i];
        }
    };
    const big_ints: u16 = if (o.big and random.boolean()) 16 else 4;
    add(&entries, &ne, 256, if (random.boolean()) 3 else 4, one.of(w));
    add(&entries, &ne, 257, 4, one.of(h));
    for (S.bits_v[0..spp]) |*b| b.* = bits;
    add(&entries, &ne, 258, 3, S.bits_v[0..spp]);
    add(&entries, &ne, 259, 3, one.of(@intFromEnum(comp)));
    add(&entries, &ne, 262, 3, one.of(photometric));
    if (random.uintLessThan(u8, 8) == 0) add(&entries, &ne, 266, 3, one.of(2));
    if (!tiled) {
        for (S.offs[0..chunks], offsets[0..chunks]) |*a, b| a.* = b;
        add(&entries, &ne, 273, big_ints, S.offs[0..chunks]);
    }
    if (random.uintLessThan(u8, 8) == 0) add(&entries, &ne, 274, 3, one.of(1 + random.uintLessThan(u64, 8)));
    add(&entries, &ne, 277, 3, one.of(spp));
    if (!tiled) add(&entries, &ne, 278, 4, one.of(ch));
    if (!tiled) {
        for (S.cnts[0..chunks], counts[0..chunks]) |*a, b| a.* = b;
        add(&entries, &ne, 279, big_ints, S.cnts[0..chunks]);
    }
    if (random.uintLessThan(u8, 4) == 0) {
        add(&entries, &ne, 282, 5, S.res[0..2]);
        add(&entries, &ne, 283, 5, S.res[2..4]);
    }
    if (planar) add(&entries, &ne, 284, 3, one.of(2));
    if (comp == .g3) add(&entries, &ne, 292, 4, one.of(random.uintLessThan(u64, 8)));
    if (predictor != 1) add(&entries, &ne, 317, 3, one.of(predictor));
    if (model == .palette) {
        const entries_n = @as(usize, 1) << @intCast(bits);
        const wide = random.boolean();
        for (S.cmap[0 .. 3 * entries_n]) |*c| {
            const x = random.int(u16);
            c.* = if (wide) x else (x >> 8) * 257;
        }
        add(&entries, &ne, 320, 3, S.cmap[0 .. 3 * entries_n]);
    }
    if (tiled) {
        add(&entries, &ne, 322, 3, one.of(cw));
        add(&entries, &ne, 323, 3, one.of(ch));
        for (S.offs[0..chunks], offsets[0..chunks]) |*a, b| a.* = b;
        add(&entries, &ne, 324, big_ints, S.offs[0..chunks]);
        for (S.cnts[0..chunks], counts[0..chunks]) |*a, b| a.* = b;
        add(&entries, &ne, 325, big_ints, S.cnts[0..chunks]);
    }
    if (extra > 0) {
        for (S.extra_v[0..extra]) |*e| e.* = extra_type;
        add(&entries, &ne, 338, 3, S.extra_v[0..extra]);
    }
    if (fmt != 1 or random.uintLessThan(u8, 8) == 0) {
        for (S.fmt_v[0..spp]) |*f| f.* = fmt;
        add(&entries, &ne, 339, 3, S.fmt_v[0..spp]);
    }
    if (model == .ycbcr) {
        const sv = struct {
            var pair: [2]u64 = undefined;
        };
        sv.pair = .{ sub[0], sub[1] };
        add(&entries, &ne, 530, 3, &sv.pair);
    }

    // The IFD before or after the data; the offsets point into the data.
    const ifd_first = random.uintLessThan(u8, 3) == 0;
    if (o.len & 1 != 0) o.bytes(&.{0});
    const ilen = ifdLen(o, entries[0..ne]);
    const data_at = if (ifd_first) o.len + ilen else o.len;
    for (S.offs[0..chunks]) |*a| a.* += data_at;
    if (!ifd_first) {
        o.bytes(d.buf[0..d.len]);
        if (o.len & 1 != 0) o.bytes(&.{0});
    }
    const ifd_at = o.len;
    const next_at = writeIfd(o, entries[0..ne]);
    if (ifd_first) o.bytes(d.buf[0..d.len]);
    if (o.full) return null;
    return .{ ifd_at, next_at };
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk: a 2 by 2 8-bit gray image with the IFD first, and the same
/// with its data first.
pub const seeds = [_][]const u8{
    "II*\x00\x08\x00\x00\x00" ++ "\x06\x00" ++
        "\x00\x01\x03\x00\x01\x00\x00\x00\x02\x00\x00\x00" ++
        "\x01\x01\x03\x00\x01\x00\x00\x00\x02\x00\x00\x00" ++
        "\x06\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
        "\x11\x01\x04\x00\x01\x00\x00\x00\x56\x00\x00\x00" ++
        "\x16\x01\x04\x00\x01\x00\x00\x00\x02\x00\x00\x00" ++
        "\x17\x01\x04\x00\x01\x00\x00\x00\x04\x00\x00\x00" ++
        "\x00\x00\x00\x00" ++ "\x10\x20\x30\x40",
    "MM\x00*\x00\x00\x00\x0c" ++ "\x10\x20\x30\x40" ++ "\x00\x05" ++
        "\x01\x00\x00\x03\x00\x00\x00\x01\x00\x02\x00\x00" ++
        "\x01\x01\x00\x03\x00\x00\x00\x01\x00\x02\x00\x00" ++
        "\x01\x06\x00\x03\x00\x00\x00\x01\x00\x01\x00\x00" ++
        "\x01\x11\x00\x04\x00\x00\x00\x01\x00\x00\x00\x08" ++
        "\x01\x17\x00\x04\x00\x00\x00\x01\x00\x00\x00\x04" ++
        "\x00\x00\x00\x00",
};

test "tiff on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
