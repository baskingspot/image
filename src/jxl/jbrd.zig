//! The JPEG bitstream reconstruction data (`jbrd` box, ISO/IEC 18181-2):
//! everything of the original JPEG but its quantized coefficients and
//! quantization tables, which the codestream holds. The box is a bundle of
//! bit-packed fields, LSB first like the codestream's headers, then a
//! Brotli stream with the bytes no field describes: the APP markers of no
//! known type, the COM markers, the bytes between markers, and the bytes
//! after EOI. `JpegReconstructor.zig` writes the JPEG from it.
//!
//! The final text of the jbrd syntax is not public; the field order and
//! the constraints here follow the bundle as libjxl 0.12 reads it
//! (docs/slop/jxl-jbrd.md), and the semantics follow ISO/IEC 18181-1's
//! committee draft (Annex M, lossless JPEG recompression) and ISO/IEC
//! 10918-1.
//!
//! `read` parses the bundle twice over: once with a counting `Mem` to size
//! the work memory, and once into it.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const brotli = @import("compress").brotli;

/// The Brotli one-shot decoder's state, 2.7 MB, in the caller's memory.
pub const BrotliBuffer = brotli.decode.Buffer;

pub const Error = error{
    ReadFailed,
    /// The box ends inside the bundle.
    Truncated,
    /// The box breaks the bundle's constraints: a marker list without EOI
    /// or scans, an APP or COM marker shorter than its length field, a
    /// component or table index out of range, a Huffman code without its
    /// terminal symbol or with a symbol twice, a table used before a DHT
    /// defines it, nonzero padding before the Brotli stream, or a Brotli
    /// stream that is malformed or does not hold exactly the declared bytes.
    BadJbrd,
    /// More APP markers holding EXIF or XMP than one each, as libjxl.
    Unsupported,
};

/// Where an APP marker's bytes come from: the Brotli stream, or the
/// codestream's ICC profile, the `Exif` box, or the `xml ` box.
pub const AppType = enum(u2) { unknown, icc, exif, xmp };

pub const App = struct {
    type: AppType,
    /// The marker's bytes after 0xFF: its type, length, and contents.
    size: u32,
    data: []u8 = &.{},
};

/// A run of bytes from the Brotli stream: a COM marker after 0xFF, bytes
/// between markers, or the bytes after EOI.
pub const Piece = struct {
    size: u32,
    data: []u8 = &.{},
};

pub const Quant = struct {
    /// Pq: 0 for 8-bit values, 1 for 16-bit.
    precision: u1,
    /// Tq, the table's slot.
    index: u2,
    /// The last table of its DQT marker.
    is_last: bool,
};

pub const Component = struct {
    id: u8,
    quant: u2,
};

pub const Huffman = struct {
    /// Tc << 4 | Th.
    slot: u8,
    is_last: bool,
    /// Codes of each length 1 to 16, counting the terminal symbol (256)
    /// that ends `values` at the longest length; all zero for an empty
    /// table.
    counts: [17]u16,
    /// The symbols in code order, without the terminal one.
    values: []const u8,
};

pub const ScanComponent = struct {
    index: u2,
    dc: u2,
    ac: u2,
};

pub const ZeroRun = struct {
    /// The block, counted from the scan's first.
    block: u32,
    /// ZRL symbols the original wrote before the block's EOB, 1 to 4.
    count: u8,
};

pub const Scan = struct {
    components: [3]ScanComponent,
    num_components: u2,
    ss: u6,
    se: u6,
    ah: u4,
    al: u4,
    /// Blocks before which the original ended an EOB run early.
    reset_points: []const u32,
    zero_runs: []const ZeroRun,
};

pub const max_markers = 16384;
pub const max_block = 3 << 26;
pub const max_huffman = 26 + 63;

/// The parsed box. Slices point into work memory.
pub const Jbrd = struct {
    /// Every marker after SOI, in file order, by its second byte; 0xFF
    /// stands for bytes between markers. The last is EOI (0xD9).
    markers: []const u8,
    apps: []App,
    coms: []Piece,
    quant: [4]Quant,
    num_quant: u3,
    components: [3]Component,
    num_components: u2,
    huffman: []const Huffman,
    scans: []const Scan,
    restart_interval: u16,
    inter_marker: []Piece,
    tail: Piece,
    /// The bits that pad each entropy-coded segment to a byte, in order,
    /// packed LSB first; null when every padding bit is 1.
    padding: ?[]const u8,
    padding_bits: u32,
    /// Bytes of the Brotli stream's contents.
    payload_len: u64,
    /// Whether a scan refines AC coefficients, which needs
    /// `max_correction_bytes` of scratch to write.
    refines: bool,
    /// The bytes ICC, EXIF, and XMP markers take from elsewhere.
    icc_len: u64,
    exif_len: ?u32,
    xmp_len: ?u32,
};

/// Work memory for parsing, or a count of what parsing needs when `buf`
/// is empty. Each allocation counts its worst alignment, so a count holds
/// for any base address.
pub const Mem = struct {
    buf: []u8 = &.{},
    counting: bool = false,
    used: usize = 0,

    pub fn alloc(m: *Mem, comptime T: type, n: usize) Error![]T {
        const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.BadJbrd;
        if (m.counting) {
            m.used = std.math.add(usize, m.used, bytes + @alignOf(T) - 1) catch return error.BadJbrd;
            return &.{};
        }
        const base = @intFromPtr(m.buf.ptr);
        const start = std.mem.alignForward(usize, base + m.used, @alignOf(T)) - base;
        if (start > m.buf.len or bytes > m.buf.len - start) return error.BadJbrd;
        m.used = start + bytes;
        const p: [*]T = @ptrCast(@alignCast(m.buf.ptr + start));
        return p[0..n];
    }
};

/// LSB-first bits from at most `left` bytes of a reader.
pub const Bits = struct {
    r: *Io.Reader,
    left: u64,
    buf: u64 = 0,
    n: u7 = 0,
    /// Bits consumed.
    pos: u64 = 0,

    pub fn init(r: *Io.Reader, len: u64) Bits {
        return .{ .r = r, .left = len };
    }

    fn fill(b: *Bits) Error!void {
        // Eight bytes in one load when the reader holds them; the whole
        // ones that fit go in.
        const buffered = b.r.buffered();
        if (b.left >= 8 and buffered.len >= 8) {
            const k: u7 = (64 - b.n) / 8;
            var word = std.mem.readInt(u64, buffered[0..8], .little);
            if (k < 8) word &= (@as(u64, 1) << @intCast(8 * k)) - 1;
            b.buf |= word << @intCast(b.n);
            b.n += 8 * k;
            b.left -= k;
            b.r.toss(k);
            return;
        }
        while (b.n <= 56 and b.left > 0) {
            const byte = b.r.takeByte() catch |e| return switch (e) {
                error.EndOfStream => error.Truncated,
                error.ReadFailed => error.ReadFailed,
            };
            b.left -= 1;
            b.buf |= @as(u64, byte) << @intCast(b.n);
            b.n += 8;
        }
    }

    pub fn bits(b: *Bits, n: u6) Error!u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        if (b.n < n) {
            try b.fill();
            if (b.n < n) return error.Truncated;
        }
        const x: u32 = @truncate(b.buf & ((@as(u64, 1) << n) - 1));
        b.buf >>= n;
        b.n -= n;
        b.pos += n;
        return x;
    }

    pub fn boolean(b: *Bits) Error!bool {
        return try b.bits(1) == 1;
    }

    /// A `U32` field: a constant, or `n` bits plus an offset, by a 2-bit
    /// selector.
    inline fn u32Field(b: *Bits, comptime d: [4]Dist) Error!u32 {
        return switch (try b.bits(2)) {
            inline 0...3 => |i| switch (d[i]) {
                .val => |x| x,
                .bits => |x| try b.bits(x.n) +% x.offset,
            },
            else => unreachable,
        };
    }

    /// Skips to a byte boundary; the bits skipped are zero.
    pub fn alignToByte(b: *Bits) Error!void {
        const k: u6 = @intCast((8 - b.pos % 8) % 8);
        if (try b.bits(k) != 0) return error.BadJbrd;
    }

    /// Bytes of the box left after the bits read, at a byte boundary.
    pub fn remaining(b: *const Bits) u64 {
        return b.left + b.n / 8;
    }
};

const Dist = union(enum) {
    val: u32,
    bits: struct { n: u6, offset: u32 = 0 },
};

fn v(x: u32) Dist {
    return .{ .val = x };
}
fn bo(n: u6, offset: u32) Dist {
    return .{ .bits = .{ .n = n, .offset = offset } };
}

const app_type_dist = [4]Dist{ v(0), v(1), bo(1, 2), bo(2, 4) };
const count_dist = [4]Dist{ v(1), v(2), v(3), v(4) };
const huffman_count_dist = [4]Dist{ v(4), bo(3, 2), bo(4, 10), bo(6, 26) };
const code_count_dist = [4]Dist{ v(0), v(1), bo(3, 2), bo(8, 0) };
const symbol_dist = [4]Dist{ bo(2, 0), bo(2, 4), bo(4, 8), bo(8, 1) };
const last_pass_dist = [4]Dist{ v(0), v(1), v(2), bo(3, 3) };
const list_len_dist = [4]Dist{ v(0), bo(2, 1), bo(4, 4), bo(16, 20) };
const block_dist = [4]Dist{ v(0), bo(3, 1), bo(5, 9), bo(28, 41) };
const zero_run_dist = [4]Dist{ v(1), bo(2, 2), bo(4, 5), bo(8, 20) };
const tail_dist = [4]Dist{ v(0), bo(8, 1), bo(16, 257), bo(22, 65793) };

pub const icc_tag = "ICC_PROFILE\x00";
pub const exif_tag = "Exif\x00\x00";
pub const xmp_tag = "http://ns.adobe.com/xap/1.0/\x00";
/// Bytes before an ICC marker's share of the profile: type, length, tag,
/// sequence number, and count.
pub const icc_head = 3 + icc_tag.len + 2;

/// Reads the bundle and the Brotli stream's length from `b`, positioned at
/// the box's first byte. With a counting `mem`, nothing is stored and the
/// slices are empty; `mem.used` is then what a real parse needs, beside
/// `payload_len` bytes for the Brotli stream's contents.
pub fn read(b: *Bits, mem: *Mem) Error!Jbrd {
    var j: Jbrd = undefined;
    _ = try b.boolean(); // is_gray: the component type below decides.

    // The markers, and what they imply.
    var markers_buf: [max_markers]u8 = undefined;
    var nm: usize = 0;
    var napp: usize = 0;
    var ncom: usize = 0;
    var nscan: usize = 0;
    var ninter: usize = 0;
    var has_dri = false;
    while (true) {
        if (nm == max_markers) return error.BadJbrd;
        const m: u8 = 0xc0 + @as(u8, @intCast(try b.bits(6)));
        markers_buf[nm] = m;
        nm += 1;
        if (m & 0xf0 == 0xe0) napp += 1;
        if (m == 0xfe) ncom += 1;
        if (m == 0xda) nscan += 1;
        if (m == 0xff) ninter += 1;
        if (m == 0xdd) has_dri = true;
        if (m == 0xd9) break;
    }
    if (nscan == 0) return error.BadJbrd;
    const markers = try mem.alloc(u8, nm);
    if (!mem.counting) @memcpy(markers, markers_buf[0..nm]);
    j.markers = markers;

    var payload: u64 = 0;
    j.icc_len = 0;
    j.exif_len = null;
    j.xmp_len = null;
    j.apps = try mem.alloc(App, napp);
    for (0..napp) |i| {
        const t = try b.u32Field(app_type_dist);
        if (t > 3) return error.BadJbrd;
        const size = try b.bits(16) + 1;
        if (size < 3) return error.BadJbrd;
        var app: App = .{ .type = @fromBackingInt(@intCast(t)), .size = size };
        // The contents of the known types are built here, at write time.
        if (app.type != .unknown) app.data = try mem.alloc(u8, size);
        switch (app.type) {
            .unknown => payload += size,
            .icc => {
                if (size < icc_head) return error.BadJbrd;
                j.icc_len += size - icc_head;
            },
            .exif => {
                if (j.exif_len != null) return error.Unsupported;
                if (size < 3 + exif_tag.len) return error.BadJbrd;
                j.exif_len = size - 3 - @as(u32, exif_tag.len);
            },
            .xmp => {
                if (j.xmp_len != null) return error.Unsupported;
                if (size < 3 + xmp_tag.len) return error.BadJbrd;
                j.xmp_len = size - 3 - @as(u32, xmp_tag.len);
            },
        }
        if (!mem.counting) j.apps[i] = app;
    }
    j.coms = try mem.alloc(Piece, ncom);
    for (0..ncom) |i| {
        const size = try b.bits(16) + 1;
        if (size < 3) return error.BadJbrd;
        if (!mem.counting) j.coms[i] = .{ .size = size };
        payload += size;
    }

    const nq = try b.u32Field(count_dist);
    if (nq == 4) return error.BadJbrd;
    j.num_quant = @intCast(nq);
    for (j.quant[0..nq]) |*q| q.* = .{
        .precision = @intCast(try b.bits(1)),
        .index = @intCast(try b.bits(2)),
        .is_last = try b.boolean(),
    };

    const ctype = try b.bits(2);
    const nc: u32 = switch (ctype) {
        0 => 1,
        3 => try b.u32Field(count_dist),
        else => 3,
    };
    if (nc != 1 and nc != 3) return error.BadJbrd;
    j.num_components = @intCast(nc);
    switch (ctype) {
        0 => j.components[0].id = 1,
        1 => for (0..3) |i| {
            j.components[i].id = @intCast(i + 1);
        },
        2 => for ("RGB", 0..) |c, i| {
            j.components[i].id = c;
        },
        else => for (j.components[0..nc]) |*c| {
            c.id = @intCast(try b.bits(8));
        },
    }
    var used_tables: u4 = 0;
    for (j.components[0..nc]) |*c| {
        const q = try b.bits(2);
        if (q >= nq) return error.BadJbrd;
        c.quant = @intCast(q);
        used_tables |= @as(u4, 1) << @intCast(q);
    }
    if (used_tables & 1 == 0) return error.BadJbrd;

    const nh = try b.u32Field(huffman_count_dist);
    const huffman = try mem.alloc(Huffman, nh);
    for (0..nh) |i| {
        const is_ac = try b.boolean();
        const id = try b.bits(2);
        var h: Huffman = .{
            .slot = @intCast(@as(u32, @intFromBool(is_ac)) << 4 | id),
            .is_last = try b.boolean(),
            .counts = undefined,
            .values = &.{},
        };
        var nsym: u32 = 0;
        for (&h.counts) |*c| {
            const k = try b.u32Field(code_count_dist);
            c.* = @intCast(k);
            nsym += k;
        }
        if (nsym != 0) {
            // Code lengths are 1 to 16, and the 256 values plus the
            // terminal symbol bound the count.
            if (h.counts[0] != 0 or nsym > 257) return error.BadJbrd;
            const values = try mem.alloc(u8, nsym - 1);
            var seen: [4]u64 = @splat(0);
            for (0..nsym) |k| {
                const s = try b.u32Field(symbol_dist);
                if (k == nsym - 1) {
                    if (s != 256) return error.BadJbrd;
                    break;
                }
                if (s >= 256) return error.BadJbrd;
                const bit = @as(u64, 1) << @intCast(s & 63);
                if (seen[s >> 6] & bit != 0) return error.BadJbrd;
                seen[s >> 6] |= bit;
                if (!is_ac and s >= 12) return error.BadJbrd;
                if (!mem.counting) values[k] = @intCast(s);
            }
            h.values = values;
        }
        if (!mem.counting) huffman[i] = h;
    }
    j.huffman = huffman;

    const scans = try mem.alloc(Scan, nscan);
    j.refines = false;
    for (0..nscan) |i| {
        const n = try b.u32Field(count_dist);
        if (n >= 4) return error.BadJbrd;
        var s: Scan = .{
            .components = undefined,
            .num_components = @intCast(n),
            .ss = @intCast(try b.bits(6)),
            .se = @intCast(try b.bits(6)),
            .al = @intCast(try b.bits(4)),
            .ah = @intCast(try b.bits(4)),
            .reset_points = &.{},
            .zero_runs = &.{},
        };
        for (s.components[0..n]) |*c| {
            const idx = try b.bits(2);
            if (idx >= nc) return error.BadJbrd;
            c.index = @intCast(idx);
            c.ac = @intCast(try b.bits(2));
            c.dc = @intCast(try b.bits(2));
        }
        _ = try b.u32Field(last_pass_dist); // Unused, as in libjxl.
        if (s.ah != 0 and s.se != 0) j.refines = true;
        if (!mem.counting) scans[i] = s;
    }

    j.restart_interval = if (has_dri) @intCast(try b.bits(16)) else 0;

    for (0..nscan) |i| {
        const nr = try b.u32Field(list_len_dist);
        const resets = try mem.alloc(u32, nr);
        var last: u32 = std.math.maxInt(u32);
        for (0..nr) |k| {
            const block = (try b.u32Field(block_dist)) +% last +% 1;
            if (block >= max_block) return error.BadJbrd;
            if (!mem.counting) resets[k] = block;
            last = block;
        }
        const nz = try b.u32Field(list_len_dist);
        const runs = try mem.alloc(ZeroRun, nz);
        last = std.math.maxInt(u32);
        for (0..nz) |k| {
            const count = try b.u32Field(zero_run_dist);
            const block = (try b.u32Field(block_dist)) +% last +% 1;
            if (count > 4 or block > max_block) return error.BadJbrd;
            if (!mem.counting) runs[k] = .{ .block = block, .count = @intCast(count) };
            last = block;
        }
        if (!mem.counting) {
            scans[i].reset_points = resets;
            scans[i].zero_runs = runs;
        }
    }
    j.scans = scans;

    j.inter_marker = try mem.alloc(Piece, ninter);
    for (0..ninter) |i| {
        const size = try b.bits(16);
        if (!mem.counting) j.inter_marker[i] = .{ .size = size };
        payload += size;
    }
    j.tail = .{ .size = try b.u32Field(tail_dist) };
    payload += j.tail.size;

    j.padding = null;
    j.padding_bits = 0;
    if (try b.boolean()) {
        const nbits = try b.bits(24);
        if (nbits > b.left * 8 + b.n) return error.Truncated;
        const packed_bits = try mem.alloc(u8, (nbits + 7) / 8);
        if (!mem.counting) @memset(packed_bits, 0);
        for (0..nbits) |k| {
            const bit = try b.bits(1);
            if (!mem.counting) packed_bits[k / 8] |= @as(u8, @intCast(bit)) << @intCast(k % 8);
        }
        j.padding = packed_bits;
        j.padding_bits = nbits;
    }

    if (!mem.counting) try checkTables(&j);
    try b.alignToByte();
    j.payload_len = payload;
    return j;
}

/// Each scan's Huffman tables are defined by a DHT marker before it.
fn checkTables(j: *const Jbrd) Error!void {
    var dht: usize = 0;
    var scan: usize = 0;
    var progressive = false;
    var dc_ok: [4]bool = @splat(false);
    var ac_ok: [4]bool = @splat(false);
    for (j.markers) |m| switch (m) {
        0xc2 => progressive = true,
        0xc4 => while (dht < j.huffman.len) {
            const h = j.huffman[dht];
            dht += 1;
            if (h.slot & 0x10 != 0) ac_ok[h.slot & 3] = true else dc_ok[h.slot & 3] = true;
            if (h.is_last) break;
        },
        0xda => {
            const s = j.scans[scan];
            scan += 1;
            for (s.components[0..s.num_components]) |c| {
                if ((!progressive or s.ss == 0) and !dc_ok[c.dc]) return error.BadJbrd;
                if ((!progressive or s.ss != 0 or s.se != 0) and !ac_ok[c.ac]) return error.BadJbrd;
            }
        },
        else => {},
    };
}

/// Decompresses the Brotli stream `compressed` (the box's bytes after the
/// bundle) into `out`, exactly `j.payload_len` bytes, and points the APP
/// markers of no known type, the COM markers, the inter-marker data, and
/// the tail at their bytes. The stream must end at the box's last byte.
pub fn split(j: *Jbrd, compressed: []const u8, out: []u8, buffer: *BrotliBuffer) Error!void {
    std.debug.assert(out.len == j.payload_len);
    try decompressExact(compressed, out, buffer);
    var at: usize = 0;
    for (j.apps) |*a| if (a.type == .unknown) {
        a.data = out[at..][0..a.size];
        at += a.size;
        if (!lengthMatches(a.data)) return error.BadJbrd;
    };
    for (j.coms) |*c| {
        c.data = out[at..][0..c.size];
        at += c.size;
        if (!lengthMatches(c.data)) return error.BadJbrd;
    }
    for (j.inter_marker) |*d| {
        d.data = out[at..][0..d.size];
        at += d.size;
    }
    j.tail.data = out[at..][0..j.tail.size];
}

/// Decompresses the Brotli stream `compressed` into exactly `out.len`
/// bytes. The stream must end at its last byte: libjxl rejects bytes after
/// it.
pub fn decompressExact(compressed: []const u8, out: []u8, buffer: *BrotliBuffer) Error!void {
    const got = brotli.decode.decompressCounted(compressed, out, buffer) catch return error.BadJbrd;
    if (got.target_len != out.len or got.source_len != compressed.len) return error.BadJbrd;
}

/// A marker's length field (its second and third bytes) counts the bytes
/// after its type byte.
fn lengthMatches(m: []const u8) bool {
    return @as(usize, m[1]) << 8 | m[2] == m.len - 1;
}

// The JPEG (ISO/IEC 10918-1) the box describes.

/// The image data the box leaves to the codestream, per JPEG component in
/// the box's order.
pub const Image = struct {
    width: u32,
    height: u32,
    /// Sampling factors, 1 or 2.
    h: [3]u4,
    v: [3]u4,
    /// Each component's quantization table, in natural order.
    quant: [3][64]u16,
    /// Each component's quantized coefficients, 64 a block in zigzag
    /// order (`zigzagged`), `blocks_x(c)` by `blocks_y(c)` blocks (whole
    /// MCUs).
    coefs: [3][]const i16,
    /// The codestream's ICC profile, the `Exif` box's contents (with its
    /// 4-byte TIFF header offset), and the `xml ` box's.
    icc: []const u8 = &.{},
    exif: ?[]const u8 = null,
    xmp: ?[]const u8 = null,

    fn maxH(img: *const Image, n: usize) u32 {
        var m: u32 = 1;
        for (img.h[0..n]) |x| m = @max(m, x);
        return m;
    }

    fn maxV(img: *const Image, n: usize) u32 {
        var m: u32 = 1;
        for (img.v[0..n]) |x| m = @max(m, x);
        return m;
    }

    pub fn mcusX(img: *const Image, n: usize) u32 {
        return (img.width + 8 * img.maxH(n) - 1) / (8 * img.maxH(n));
    }

    pub fn mcusY(img: *const Image, n: usize) u32 {
        return (img.height + 8 * img.maxV(n) - 1) / (8 * img.maxV(n));
    }

    pub fn blocksX(img: *const Image, n: usize, c: usize) u32 {
        return img.mcusX(n) * img.h[c];
    }

    pub fn blocksY(img: *const Image, n: usize, c: usize) u32 {
        return img.mcusY(n) * img.v[c];
    }
};

/// The zigzag sequence's positions in natural order.
pub const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// A 64-lane comparison as bits, lane 0 the lowest.
fn laneBits(lanes: @Vector(64, bool)) u64 {
    return @bitCast(lanes);
}

/// A block's coefficients in zigzag order, in one shuffle.
pub fn zigzagged(blk: @Vector(64, i16)) @Vector(64, i16) {
    const mask: @Vector(64, i32) = comptime blk: {
        var m: [64]i32 = undefined;
        for (zigzag, 0..) |z, i| m[i] = z;
        break :blk m;
    };
    return @shuffle(i16, blk, undefined, mask);
}

/// The bytes an AC refinement scan's held correction bits take: 0x7FFF
/// blocks of up to 63, packed.
pub const max_correction_bytes = (0x7fff * 63 + 7) / 8 + 8;

pub const WriteError = Error || Io.Writer.Error;

/// Writes the JPEG: SOI, then each marker the box lists, with the scans'
/// entropy-coded data from `img`. `scratch` holds at least
/// `max_correction_bytes` when a scan refines AC coefficients.
pub fn write(w: *Io.Writer, j: *Jbrd, img: *const Image, scratch: []u8) WriteError!void {
    try fillKnownApps(j, img);
    // Each table holds the last component's that uses it (components that
    // share a table hold the same one in any file cjxl writes; libjxl
    // takes the last), and a table no component uses repeats the one
    // before it.
    var q_values: [4][64]u16 = undefined;
    for (0..j.num_quant) |i| {
        var found = false;
        for (j.components[0..j.num_components], 0..) |c, ci| {
            if (c.quant == i) {
                q_values[i] = img.quant[ci];
                found = true;
            }
        }
        if (!found) {
            if (i == 0) return error.BadJbrd;
            q_values[i] = q_values[i - 1];
        }
    }

    var st: State = .{ .w = w, .j = j, .img = img, .scratch = scratch };
    try w.writeAll("\xff\xd8");
    var app: usize = 0;
    var com: usize = 0;
    var inter: usize = 0;
    var quant: usize = 0;
    var dht: usize = 0;
    var scan: usize = 0;
    for (j.markers) |m| switch (m) {
        // 0xc9 and 0xca name arithmetic coding, yet the scans are written
        // with the Huffman codes all the same, as libjxl does; those
        // leave the scans' mode as it was.
        0xc0, 0xc1, 0xc2, 0xc9, 0xca => {
            if (m <= 0xc2) st.progressive = m == 0xc2;
            const n = j.num_components;
            try w.writeAll(&.{ 0xff, m });
            try writeU16(w, 8 + 3 * @as(u16, n));
            try w.writeByte(8);
            if (img.height > 0xffff or img.width > 0xffff) return error.BadJbrd;
            try writeU16(w, @intCast(img.height));
            try writeU16(w, @intCast(img.width));
            try w.writeByte(n);
            for (j.components[0..n], 0..) |c, ci| {
                try w.writeAll(&.{ c.id, @as(u8, img.h[ci]) << 4 | img.v[ci], j.quant[c.quant].index });
            }
        },
        0xc4 => {
            var len: usize = 2;
            var k = dht;
            while (k < j.huffman.len) : (k += 1) {
                const h = &j.huffman[k];
                if (nonEmpty(h)) len += 17 + h.values.len;
                if (h.is_last) break;
            }
            if (k == j.huffman.len) return error.BadJbrd;
            try w.writeAll("\xff\xc4");
            try writeU16(w, @intCast(len));
            while (dht <= k) : (dht += 1) {
                const h = &j.huffman[dht];
                if (!nonEmpty(h)) continue;
                var counts: [16]u8 = undefined;
                var last: usize = 0;
                for (1..17) |l| if (h.counts[l] != 0) {
                    last = l;
                };
                for (1..17) |l| {
                    const c = h.counts[l] - @intFromBool(l == last);
                    if (c > 255) return error.BadJbrd;
                    counts[l - 1] = @intCast(c);
                }
                try w.writeByte(h.slot);
                try w.writeAll(&counts);
                try w.writeAll(h.values);
                const table = try Code.build(h);
                if (h.slot & 0x10 != 0) st.ac[h.slot & 3] = table else st.dc[h.slot & 3] = table;
            }
        },
        0xd0...0xd7 => try w.writeAll(&.{ 0xff, m }),
        0xd9 => {
            try w.writeAll("\xff\xd9");
            try w.writeAll(j.tail.data);
        },
        0xda => {
            const s = &j.scans[scan];
            const n = s.num_components;
            try w.writeAll("\xff\xda");
            try writeU16(w, 6 + 2 * @as(u16, n));
            try w.writeByte(n);
            for (s.components[0..n]) |c| {
                try w.writeAll(&.{ j.components[c.index].id, @as(u8, c.dc) << 4 | c.ac });
            }
            try w.writeAll(&.{ s.ss, s.se, @as(u8, s.ah) << 4 | s.al });
            try st.scan(s);
            scan += 1;
        },
        0xdb => {
            var len: usize = 2;
            var k = quant;
            while (k < j.num_quant) : (k += 1) {
                len += 1 + 64 * (1 + @as(usize, j.quant[k].precision));
                if (j.quant[k].is_last) break;
            }
            if (k == j.num_quant) return error.BadJbrd;
            try w.writeAll("\xff\xdb");
            try writeU16(w, @intCast(len));
            while (quant <= k) : (quant += 1) {
                const q = j.quant[quant];
                try w.writeByte(@as(u8, q.precision) << 4 | q.index);
                for (zigzag) |z| {
                    const x = q_values[quant][z];
                    if (q.precision == 0) {
                        if (x > 255) return error.BadJbrd;
                        try w.writeByte(@intCast(x));
                    } else try writeU16(w, x);
                }
            }
        },
        0xdd => {
            st.dri = true;
            try w.writeAll("\xff\xdd\x00\x04");
            try writeU16(w, j.restart_interval);
        },
        0xe0...0xef => {
            const a = &j.apps[app];
            app += 1;
            // The marker's type is its stored first byte, whatever the
            // marker list says: libjxl writes it so.
            try w.writeByte(0xff);
            try w.writeAll(a.data);
        },
        0xfe => {
            const c = j.coms[com];
            com += 1;
            try w.writeByte(0xff);
            try w.writeAll(c.data);
        },
        0xff => {
            try w.writeAll(j.inter_marker[inter].data);
            inter += 1;
        },
        else => return error.BadJbrd,
    };
    // A padding list holds exactly the bits the segments end with.
    if (j.padding != null and st.pad_at != j.padding_bits) return error.BadJbrd;
}

fn nonEmpty(h: *const Huffman) bool {
    for (h.counts) |c| if (c != 0) return true;
    return false;
}

fn writeU16(w: *Io.Writer, x: u16) Io.Writer.Error!void {
    try w.writeAll(&.{ @intCast(x >> 8), @truncate(x) });
}

/// Builds the APP markers whose contents come from the ICC profile, the
/// `Exif` box, and the `xml ` box. Their data slices must already hold
/// `size` bytes each.
fn fillKnownApps(j: *Jbrd, img: *const Image) Error!void {
    var icc_at: usize = 0;
    var icc_count: u8 = 0;
    var icc_total: u8 = 0;
    for (j.apps) |a| if (a.type == .icc) {
        icc_total +%= 1;
    };
    for (j.apps) |*a| {
        if (a.type == .unknown) continue;
        const d = a.data;
        d[1] = @intCast((a.size - 1) >> 8);
        d[2] = @truncate(a.size - 1);
        switch (a.type) {
            .unknown => unreachable,
            .icc => {
                const n = a.size - icc_head;
                if (n > img.icc.len - icc_at) return error.BadJbrd;
                icc_count +%= 1;
                d[0] = 0xe2;
                @memcpy(d[3..][0..icc_tag.len], icc_tag);
                d[15] = icc_count;
                d[16] = icc_total;
                @memcpy(d[icc_head..], img.icc[icc_at..][0..n]);
                icc_at += n;
            },
            .exif => {
                const box = img.exif orelse return error.BadJbrd;
                if (box.len < 4 or box.len - 4 != a.size - 3 - exif_tag.len) return error.BadJbrd;
                d[0] = 0xe1;
                @memcpy(d[3..][0..exif_tag.len], exif_tag);
                @memcpy(d[3 + exif_tag.len ..], box[4..]);
            },
            .xmp => {
                const box = img.xmp orelse return error.BadJbrd;
                if (box.len != a.size - 3 - xmp_tag.len) return error.BadJbrd;
                d[0] = 0xe1;
                @memcpy(d[3..][0..xmp_tag.len], xmp_tag);
                @memcpy(d[3 + xmp_tag.len ..], box);
            },
        }
    }
    if (icc_at != 0 and icc_at != img.icc.len) return error.BadJbrd;
}

/// A Huffman code for encoding: each symbol's code and length (0 for a
/// symbol the code lacks).
const Code = struct {
    code: [256]u16 = @splat(0),
    len: [256]u5 = @splat(0),

    /// The canonical code (ISO/IEC 10918-1, C.2) of the box's table,
    /// whose terminal symbol takes the last code of the longest length.
    fn build(h: *const Huffman) Error!Code {
        var c: Code = .{};
        var code: u32 = 0;
        var k: usize = 0;
        for (1..17) |l| {
            for (0..h.counts[l]) |_| {
                if (code >= @as(u32, 1) << @intCast(l)) return error.BadJbrd;
                if (k < h.values.len) {
                    c.code[h.values[k]] = @intCast(code);
                    c.len[h.values[k]] = @intCast(l);
                }
                k += 1;
                code += 1;
            }
            code <<= 1;
        }
        return c;
    }
};

/// Entropy-coded bits, most significant first, with a 0 stuffed after
/// each 0xFF byte. Up to 31 bits wait in `acc` between calls, written 32
/// at a time.
const BitOut = struct {
    w: *Io.Writer,
    acc: u64 = 0,
    n: u6 = 0,

    /// Appends the low `len` bits of `bits`, `len` at most 32.
    inline fn put(o: *BitOut, bits: u32, len: u6) Io.Writer.Error!void {
        const mask = (@as(u64, 1) << len) - 1;
        o.acc = o.acc << len | (bits & mask);
        o.n += len;
        if (o.n >= 32) {
            o.n -= 32;
            try o.word(@truncate(o.acc >> o.n));
            o.acc &= (@as(u64, 1) << o.n) - 1;
        }
    }

    /// Writes four bytes, straight into the writer's buffer when it has
    /// room and none of them is 0xFF.
    fn word(o: *BitOut, x: u32) Io.Writer.Error!void {
        const w = o.w;
        // A byte of `x` is 0xFF where one of `~x` is zero.
        const y = ~x;
        const has_ff = (y -% 0x01010101) & ~y & 0x80808080 != 0;
        if (!has_ff and w.buffer.len - w.end >= 4) {
            std.mem.writeInt(u32, w.buffer[w.end..][0..4], x, .big);
            w.end += 4;
            return;
        }
        for (0..4) |i| try o.byte(@truncate(x >> @intCast(24 - 8 * i)));
    }

    fn byte(o: *BitOut, b: u8) Io.Writer.Error!void {
        try o.w.writeByte(b);
        if (b == 0xff) try o.w.writeByte(0);
    }

    /// Writes the whole bytes waiting, leaving fewer than 8 bits.
    fn flushBytes(o: *BitOut) Io.Writer.Error!void {
        while (o.n >= 8) {
            o.n -= 8;
            try o.byte(@truncate(o.acc >> o.n));
        }
        o.acc &= (@as(u64, 1) << o.n) - 1;
    }
};

const State = struct {
    w: *Io.Writer,
    j: *Jbrd,
    img: *const Image,
    scratch: []u8,
    progressive: bool = false,
    /// Whether a DRI marker came before: only then do scans restart.
    dri: bool = false,
    dc: [4]?Code = @splat(null),
    ac: [4]?Code = @splat(null),
    /// The next padding bit of `j.padding`.
    pad_at: u32 = 0,
    /// The AC code of the block that began the EOB run.
    ac_code: *const Code = undefined,

    out: BitOut = undefined,
    pred: [3]i32 = @splat(0),
    eobrun: u32 = 0,
    /// Correction bits held for the EOB run in `scratch`, packed most
    /// significant first.
    nbe: usize = 0,
    /// Within the current scan: the next block, and the next reset point
    /// and zero run.
    block: u32 = 0,
    reset_at: usize = 0,
    run_at: usize = 0,

    inline fn symbol(st: *State, code: *const Code, s: u8) WriteError!void {
        return st.symbolBits(code, s, 0, 0);
    }

    /// Symbol `s`, then the low `n` bits of `bits`, in one write: a code
    /// is at most 16 bits and `n` at most 15.
    inline fn symbolBits(st: *State, code: *const Code, s: u8, bits: u32, n: u5) WriteError!void {
        const len = code.len[s];
        if (len == 0) return error.BadJbrd;
        const extra = bits & ((@as(u32, 1) << n) - 1);
        try st.out.put(@as(u32, code.code[s]) << n | extra, @as(u6, len) + n);
    }

    /// Pads the entropy-coded segment to a byte with the box's padding
    /// bits, or ones, and writes out every bit held.
    fn pad(st: *State) WriteError!void {
        const k: u6 = @intCast((8 - @as(u32, st.out.n % 8)) % 8);
        var bits: u32 = 0;
        for (0..k) |_| {
            var bit: u32 = 1;
            if (st.j.padding) |p| {
                if (st.pad_at >= st.j.padding_bits) return error.BadJbrd;
                bit = p[st.pad_at / 8] >> @intCast(st.pad_at % 8) & 1;
                st.pad_at += 1;
            }
            bits = bits << 1 | bit;
        }
        try st.out.put(bits, k);
        try st.out.flushBytes();
    }

    fn scan(st: *State, s: *const Scan) WriteError!void {
        const j = st.j;
        const img = st.img;
        const nc = j.num_components;
        st.out = .{ .w = st.w };
        st.pred = @splat(0);
        st.eobrun = 0;
        st.nbe = 0;
        st.block = 0;
        st.reset_at = 0;
        st.run_at = 0;
        const n = s.num_components;
        // A sequential frame's scans code the whole block whatever band
        // and approximation they store, and a progressive scan of the
        // whole block at full precision is coded as a sequential one.
        // Past T.81, a first or refining scan whose band starts at 0 and
        // runs on codes the DC, then the rest of the band without EOB
        // runs, and a band that ends before it starts codes nothing.
        // libjxl reconstructs them all so.
        const ss: u6 = if (st.progressive) s.ss else 0;
        const se: u6 = if (st.progressive) s.se else 63;
        const ah: u4 = if (st.progressive) s.ah else 0;
        const al: u4 = if (st.progressive) s.al else 0;
        const mode: enum { sequential, first, refine } =
            if (ah == 0 and al == 0 and ss == 0 and se == 63) .sequential else if (ah == 0) .first else .refine;
        for (s.components[0..n]) |c| {
            if (ss == 0 and st.dc[c.dc] == null) return error.BadJbrd;
            if ((ss != 0 or se != 0) and st.ac[c.ac] == null) return error.BadJbrd;
        }

        var mcus_x: u32 = undefined;
        var mcus_y: u32 = undefined;
        if (n == 1) {
            // A component alone: its own blocks, not whole MCUs.
            const ci = s.components[0].index;
            const hmax = img.maxH(nc);
            const vmax = img.maxV(nc);
            const w = (@as(u64, img.width) * img.h[ci] + hmax - 1) / hmax;
            const h = (@as(u64, img.height) * img.v[ci] + vmax - 1) / vmax;
            mcus_x = @intCast((w + 7) / 8);
            mcus_y = @intCast((h + 7) / 8);
        } else {
            mcus_x = img.mcusX(nc);
            mcus_y = img.mcusY(nc);
        }
        // Each component's blocks a row and in an MCU, once a scan.
        var layout: [3]struct { bw: usize, hb: u32, vb: u32 } = undefined;
        for (s.components[0..n], layout[0..n]) |c, *l| l.* = .{
            .bw = img.blocksX(nc, c.index),
            .hb = if (n == 1) 1 else img.h[c.index],
            .vb = if (n == 1) 1 else img.v[c.index],
        };
        const ri: u32 = if (st.dri) j.restart_interval else 0;
        var togo: u32 = ri;
        var rst: u8 = 0;
        for (0..mcus_y) |my_| for (0..mcus_x) |mx_| {
            const mx: u32 = @intCast(mx_);
            const my: u32 = @intCast(my_);
            if (ri != 0) {
                if (togo == 0) {
                    try st.flushEobrun();
                    try st.pad();
                    try st.w.writeAll(&.{ 0xff, 0xd0 + rst });
                    rst = (rst + 1) & 7;
                    st.pred = @splat(0);
                    togo = ri;
                }
                togo -= 1;
            }
            for (s.components[0..n], layout[0..n]) |c, l| {
                const ci = c.index;
                const bw = l.bw;
                const hb = l.hb;
                const vb = l.vb;
                for (0..vb) |iy| for (0..hb) |ix| {
                    const bx = mx * hb + @as(u32, @intCast(ix));
                    const by = my * vb + @as(u32, @intCast(iy));
                    const at = (@as(usize, by) * bw + bx) * 64;
                    const coefs = img.coefs[ci];
                    if (at + 64 > coefs.len) return error.BadJbrd;
                    const blk = coefs[at..][0..64];
                    if (st.reset_at < s.reset_points.len and s.reset_points[st.reset_at] == st.block) {
                        try st.flushEobrun();
                        st.reset_at += 1;
                    }
                    var zeros: u32 = 0;
                    if (st.run_at < s.zero_runs.len and s.zero_runs[st.run_at].block == st.block) {
                        zeros = s.zero_runs[st.run_at].count;
                        st.run_at += 1;
                    }
                    var lo = ss;
                    switch (mode) {
                        .sequential => try st.sequential(blk, ci, &st.dc[c.dc].?, &st.ac[c.ac].?, zeros),
                        .first => {
                            if (ss == 0) {
                                const x: i32 = @as(i32, blk[0]) >> al;
                                try st.dcDiff(&st.dc[c.dc].?, x - st.pred[ci]);
                                st.pred[ci] = x;
                            }
                            if (ss == 0) lo = 1;
                            if (lo <= se) try st.acFirst(blk, lo, se, al, &st.ac[c.ac].?, zeros, ss != 0);
                        },
                        .refine => {
                            if (ss == 0) try st.out.put(@intCast(@as(i32, blk[0]) >> al & 1), 1);
                            if (ss == 0) lo = 1;
                            if (lo <= se) try st.acRefine(blk, lo, se, al, &st.ac[c.ac].?, ss != 0);
                        },
                    }
                    st.block +%= 1;
                };
            }
        };
        try st.flushEobrun();
        try st.pad();
    }

    /// Bits `lo` to `hi` of a block's zigzag positions.
    fn band(lo: u6, hi: u6) u64 {
        return (~@as(u64, 0) >> (63 - hi)) & (~@as(u64, 0) << lo);
    }

    fn magnitude(x: i32) u5 {
        return @intCast(32 - @clz(@as(u32, @abs(x))));
    }

    fn dcDiff(st: *State, code: *const Code, diff: i32) WriteError!void {
        const s = magnitude(diff);
        // A DC code has no symbol above 11 (`read`), so a larger
        // difference cannot be written.
        if (s > 11) return error.BadJbrd;
        try st.symbolBits(code, s, @bitCast(if (diff < 0) diff - 1 else diff), s);
    }

    fn sequential(
        st: *State,
        blk: *const [64]i16,
        ci: usize,
        dc: *const Code,
        ac: *const Code,
        zeros: u32,
    ) WriteError!void {
        const x: i32 = blk[0];
        try st.dcDiff(dc, x - st.pred[ci]);
        st.pred[ci] = x;
        // The block's nonzero AC coefficients as bits, walked from the
        // lowest.
        const zv: @Vector(64, i16) = blk.*;
        const zz: [64]i16 = zv;
        var nonzero = laneBits(zv != @as(@Vector(64, i16), @splat(0)));
        nonzero &= ~@as(u64, 1);
        var last: u32 = 0;
        while (nonzero != 0) : (nonzero &= nonzero - 1) {
            const k: u32 = @ctz(nonzero);
            var r = k - last - 1;
            while (r > 15) : (r -= 16) try st.symbol(ac, 0xf0);
            const z: i32 = zz[k];
            const s = magnitude(z);
            // 8-bit JPEG's AC magnitudes stop at 10 bits, but libjxl writes
            // any its code has a symbol for; the symbol's low nibble
            // bounds it.
            if (s > 15) return error.BadJbrd;
            try st.symbolBits(ac, @intCast(r << 4 | s), @bitCast(if (z < 0) z - 1 else z), s);
            last = k;
        }
        try st.endBlock(ac, 63 - last, zeros, false);
    }

    /// The end of a block's band after `r` zeros: the original's extra ZRL
    /// symbols, then EOB if zeros remain.
    fn endBlock(st: *State, ac: *const Code, r_in: u32, zeros: u32, run: bool) WriteError!void {
        var r = r_in;
        for (0..zeros) |_| {
            if (r < 16) return error.BadJbrd;
            try st.flushEobrun();
            try st.symbol(ac, 0xf0);
            r -= 16;
        }
        if (r == 0) return;
        if (!run) return st.symbol(ac, 0x00);
        if (st.eobrun == 0) st.ac_code = ac;
        st.eobrun += 1;
        if (st.eobrun == 0x7fff) try st.flushEobrun();
    }

    /// The first scan of band `lo`..`hi`; `run` allows EOB runs.
    fn acFirst(
        st: *State,
        blk: *const [64]i16,
        lo: u6,
        hi: u6,
        al: u4,
        ac: *const Code,
        zeros: u32,
        run: bool,
    ) WriteError!void {
        const zv: @Vector(64, i16) = blk.*;
        const zz: [64]i16 = zv;
        const tv = @abs(zv) >> @as(@Vector(64, u4), @splat(al));
        const tt: [64]u16 = tv;
        var nonzero = laneBits(tv != @as(@Vector(64, u16), @splat(0))) & band(lo, hi);
        if (nonzero != 0) try st.flushEobrun();
        // `lo` is at least 1: the DC is coded apart.
        var last: u32 = @as(u32, lo) - 1;
        while (nonzero != 0) : (nonzero &= nonzero - 1) {
            const k: u32 = @ctz(nonzero);
            var r = k - last - 1;
            while (r > 15) : (r -= 16) try st.symbol(ac, 0xf0);
            const t: i32 = tt[k];
            const m = magnitude(t);
            if (m > 15) return error.BadJbrd;
            try st.symbolBits(ac, @intCast(r << 4 | m), @bitCast(if (zz[k] < 0) -t - 1 else t), m);
            last = k;
        }
        try st.endBlock(ac, hi - last, zeros, run);
    }

    /// A refining scan of band `lo`..`hi`; `run` allows EOB runs.
    fn acRefine(
        st: *State,
        blk: *const [64]i16,
        lo: u6,
        hi: u6,
        al: u4,
        ac: *const Code,
        run: bool,
    ) WriteError!void {
        const zv: @Vector(64, i16) = blk.*;
        const zz: [64]i16 = zv;
        const av = @abs(zv) >> @as(@Vector(64, u4), @splat(al));
        const abs: [64]u16 = av;
        const in_band = band(lo, hi);
        var nonzero = laneBits(av != @as(@Vector(64, u16), @splat(0))) & in_band;
        const ones = laneBits(av == @as(@Vector(64, u16), @splat(1))) & in_band;
        // The last coefficient that becomes nonzero in this scan.
        const eob: u32 = if (ones == 0) 0 else 63 - @clz(ones);
        // The zeros since the last symbol.
        var r: u32 = 0;
        // Correction bits since the last symbol, the first the highest of
        // the low `br`: at most 63, one a coefficient of the band.
        var bits: u64 = 0;
        var br: u6 = 0;
        // `lo` is at least 1: the DC is coded apart.
        var last: u32 = @as(u32, lo) - 1;
        while (nonzero != 0) : (nonzero &= nonzero - 1) {
            const k: u32 = @ctz(nonzero);
            r += k - last - 1;
            last = k;
            const t = abs[k];
            while (r > 15 and k <= eob) : (r -= 16) {
                try st.flushEobrun();
                try st.symbol(ac, 0xf0);
                try st.putBits(bits, br);
                br = 0;
            }
            if (t > 1) {
                bits = bits << 1 | (t & 1);
                br += 1;
                continue;
            }
            try st.flushEobrun();
            try st.symbolBits(ac, @intCast(r << 4 | 1), @intFromBool(zz[k] >= 0), 1);
            try st.putBits(bits, br);
            br = 0;
            r = 0;
        }
        r += hi - last;
        if (r > 0 or br > 0) {
            try st.holdBits(bits, br);
            if (st.eobrun == 0) st.ac_code = ac;
            st.eobrun += 1;
            if (st.eobrun == 0x7fff or !run) try st.flushEobrun();
        }
    }

    /// Writes the low `n` bits of `bits`, `n` at most 63.
    fn putBits(st: *State, bits: u64, n: u6) WriteError!void {
        if (n > 32) try st.out.put(@truncate(bits >> 32), n - 32);
        try st.out.put(@truncate(bits), @min(n, 32));
    }

    /// Holds the low `n` bits of `bits` for the EOB run, after its others
    /// in `scratch`.
    fn holdBits(st: *State, bits: u64, n: u6) WriteError!void {
        var at = st.nbe;
        if (n > st.scratch.len * 8 - at) return error.BadJbrd;
        var left: u7 = n;
        while (left > 0) {
            const free: u4 = @intCast(8 - at % 8);
            const take: u4 = @intCast(@min(free, left));
            const part: u8 = @truncate(bits >> @intCast(left - take) & ((@as(u64, 1) << take) - 1));
            const b = &st.scratch[at / 8];
            // A byte's first bit clears it; later ones go below.
            const placed = part << @intCast(free - take);
            b.* = if (free == 8) placed else b.* | placed;
            at += take;
            left -= take;
        }
        st.nbe = at;
    }

    /// Writes the pending EOB run and its correction bits.
    fn flushEobrun(st: *State) WriteError!void {
        if (st.eobrun == 0) return;
        const r: u5 = @intCast(31 - @clz(st.eobrun));
        try st.symbolBits(st.ac_code, @as(u8, r) << 4, st.eobrun, r);
        // The held bits, packed most significant first, a byte at a time.
        const full = st.nbe / 8;
        for (st.scratch[0..full]) |b| try st.out.put(b, 8);
        const rest: u3 = @intCast(st.nbe % 8);
        if (rest != 0) try st.out.put(st.scratch[full] >> @intCast(8 - @as(u4, rest)), rest);
        st.eobrun = 0;
        st.nbe = 0;
    }
};

var test_brotli: BrotliBuffer = undefined;

test "a Brotli stream must fill the box and the payload exactly" {
    // An uncompressed meta-block of "ab", then the empty last one.
    const stream = "\x10\x00\x10ab\x03";
    const b = &test_brotli;
    var out: [2]u8 = undefined;
    try decompressExact(stream, &out, b);
    try testing.expectEqualStrings("ab", &out);
    try testing.expectError(error.BadJbrd, decompressExact(stream ++ "\x00", &out, b));
    try testing.expectError(error.BadJbrd, decompressExact(stream, out[0..1], b));
    var more: [3]u8 = undefined;
    try testing.expectError(error.BadJbrd, decompressExact(stream, &more, b));
}

test "bits and fields" {
    // LSB first: selector 1, then 3 bits holding 6 (block_dist adds 1),
    // then 2 bits holding 1, then a set padding bit.
    var r: Io.Reader = .fixed(&.{ 0b1011_1001, 0xff });
    var b: Bits = .init(&r, 2);
    try testing.expectEqual(@as(u32, 1 + 6), try b.u32Field(block_dist));
    try testing.expectEqual(@as(u32, 1), try b.bits(2));
    try testing.expectError(error.BadJbrd, b.alignToByte());
    r = .fixed(&.{0x01});
    b = .init(&r, 1);
    try testing.expectEqual(@as(u32, 1), try b.bits(1));
    try b.alignToByte();
    try testing.expectError(error.Truncated, b.bits(1));
}

/// A gray baseline JPEG's bundle: SOI-less markers DQT, SOF0, DHT, SOS,
/// EOI; one quant table; two Huffman codes of one symbol each; the scan's
/// band `ss` to `se` and approximation `al`.
fn grayBundle(w: *BitWriter, ss: u6, se: u6, al: u4) void {
    w.put(1, 1); // is_gray
    for ([_]u8{ 0xdb, 0xc0, 0xc4, 0xda, 0xd9 }) |m| w.put(6, m - 0xc0);
    w.put(2, 0); // one quant table
    w.put(1, 0);
    w.put(2, 0);
    w.put(1, 1);
    w.put(2, 0); // gray
    w.put(2, 0); // quant index
    w.put(2, 1); // huffman count: BitsOffset(3, 2)
    w.put(3, 0); // 2 codes
    for ([_]bool{ false, true }) |ac| {
        w.put(1, @intFromBool(ac));
        w.put(2, 0);
        w.put(1, @intFromBool(ac));
        // Two codes of length 1: BitsOffset(3, 2) with 0.
        for (0..17) |len| if (len == 1) {
            w.put(2, 2);
            w.put(3, 0);
        } else w.put(2, 0);
        // Symbols: 0 then the terminal 256.
        w.put(2, 0);
        w.put(2, 0);
        w.put(2, 3);
        w.put(8, 255);
    }
    w.put(2, 0); // scan: one component
    w.put(6, ss);
    w.put(6, se);
    w.put(4, al);
    w.put(4, 0);
    w.put(2, 0);
    w.put(2, 0);
    w.put(2, 0);
    w.put(2, 0); // last pass
    w.put(2, 0); // no reset points
    w.put(2, 0); // no zero runs
    w.put(2, 0); // no tail
    w.put(1, 0); // standard padding
}

test "counting matches parsing" {
    var w: BitWriter = .{};
    grayBundle(&w, 0, 63, 0);
    const bytes = w.bytes();

    var r: Io.Reader = .fixed(bytes);
    var b: Bits = .init(&r, bytes.len);
    var count: Mem = .{ .counting = true };
    const c = try read(&b, &count);
    try testing.expectEqual(@as(u64, 0), c.payload_len);

    var mem_buf: [4096]u8 = undefined;
    r = .fixed(bytes);
    b = .init(&r, bytes.len);
    var mem: Mem = .{ .buf = &mem_buf };
    const j = try read(&b, &mem);
    try testing.expect(mem.used <= count.used);
    try testing.expectEqualSlices(u8, &.{ 0xdb, 0xc0, 0xc4, 0xda, 0xd9 }, j.markers);
    try testing.expectEqual(@as(u2, 1), j.num_components);
    try testing.expectEqual(@as(u8, 1), j.components[0].id);
    try testing.expectEqual(@as(usize, 2), j.huffman.len);
    try testing.expectEqual(@as(u8, 0x10), j.huffman[1].slot);
    try testing.expectEqualSlices(u8, &.{0}, j.huffman[0].values);
    try testing.expectEqual(@as(u16, 2), j.huffman[0].counts[1]);
    try testing.expectEqual(@as(u6, 63), j.scans[0].se);
    try testing.expectEqual(@as(?[]const u8, null), j.padding);
}

test "a sequential scan codes the whole block whatever band it stores" {
    var outs: [2][256]u8 = undefined;
    var lens: [2]usize = undefined;
    for ([_][3]u8{ .{ 0, 63, 0 }, .{ 20, 50, 1 } }, 0..) |p, i| {
        var bw: BitWriter = .{};
        grayBundle(&bw, @intCast(p[0]), @intCast(p[1]), @intCast(p[2]));
        var r: Io.Reader = .fixed(bw.bytes());
        var b: Bits = .init(&r, bw.bytes().len);
        var mem_buf: [4096]u8 = undefined;
        var mem: Mem = .{ .buf = &mem_buf };
        var j = try read(&b, &mem);
        const coefs: [64]i16 = @splat(0);
        const img: Image = .{
            .width = 8,
            .height = 8,
            .h = .{ 1, 1, 1 },
            .v = .{ 1, 1, 1 },
            .quant = @splat(@splat(1)),
            .coefs = .{ &coefs, &.{}, &.{} },
        };
        var w: Io.Writer = .fixed(&outs[i]);
        try write(&w, &j, &img, &.{});
        lens[i] = w.end;
    }
    // The same bytes but the scan header's stored band and approximation.
    try testing.expectEqual(lens[0], lens[1]);
    const sos = std.mem.find(u8, outs[0][0..lens[0]], "\xff\xda").? + 7;
    try testing.expectEqualSlices(u8, &.{ 0, 63, 0x00 }, outs[0][sos..][0..3]);
    try testing.expectEqualSlices(u8, &.{ 20, 50, 0x01 }, outs[1][sos..][0..3]);
    try testing.expectEqualSlices(u8, outs[0][0..sos], outs[1][0..sos]);
    try testing.expectEqualSlices(u8, outs[0][sos + 3 .. lens[0]], outs[1][sos + 3 .. lens[1]]);
}

/// LSB-first bits, for building test bundles.
const BitWriter = struct {
    buf: [256]u8 = @splat(0),
    pos: usize = 0,

    fn put(w: *BitWriter, n: u6, x: u32) void {
        for (0..n) |i| {
            const bit: u8 = @intCast(x >> @intCast(i) & 1);
            w.buf[w.pos / 8] |= bit << @intCast(w.pos % 8);
            w.pos += 1;
        }
    }

    fn bytes(w: *const BitWriter) []const u8 {
        return w.buf[0 .. (w.pos + 7) / 8];
    }
};
