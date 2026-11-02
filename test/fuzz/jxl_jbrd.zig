//! The JPEG XL JPEG-reconstruction fuzz target, on mutated corpus files
//! and generated `jbrd` boxes. For each input:
//!
//! - `image.jxl.JpegReconstructor` over the whole file gives the same
//!   result through a fixed reader and a trickling one, states work within
//!   the harness limits, and refuses work one byte short.
//! - The file's `jbrd` box (or the input itself, when it is no container)
//!   parses the same through a fixed reader and a trickling one, and into
//!   exactly the memory a counting parse states.
//! - A box that parses writes the same JPEG through a fixed writer and a
//!   dripping one, with coefficients made from `choice`.

const std = @import("std");
const Io = std.Io;
const image = @import("image");
const harness = @import("harness.zig");
const jxl_fuzz = @import("jxl.zig");

const JpegReconstructor = image.jxl.JpegReconstructor;
const jbrd = JpegReconstructor.jbrd;

pub const name = "jxl_jbrd";

/// Seed directories, relative to the repository root (corpus/README.md),
/// and the extensions of the files in them to take.
pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor" };
pub const extensions = [_][]const u8{".jxl"};

pub const Finding = error{
    ChunkedDiffers,
    LimitIgnored,
    UndersizeAccepted,
    CountDiffers,
    ChunkedWriterDiffers,
};

var work_buffer: [harness.limits.max_work]u8 = undefined;
var outs: [2][8 << 20]u8 = undefined;
var parse_buffer: [16 << 20]u8 = undefined;
var payload_buffer: [1 << 20]u8 = undefined;
var scratch: [jbrd.max_correction_bytes]u8 = undefined;
var coefs: [3][max_blocks * 64]i16 = undefined;
var metadata: [1 << 16]u8 = undefined;

/// The most blocks a component of the synthetic image has: 64 by 64
/// pixels in 16 by 16 MCUs of up to four blocks.
const max_blocks = 4 * 4 * 4;

pub fn check(input: []const u8, choice: u64) !void {
    try checkReconstructor(input, choice);
    try checkBox(boxOf(input), choice);
}

fn code(e: anyerror) u16 {
    return @intFromError(e);
}

fn checkReconstructor(input: []const u8, choice: u64) !void {
    const step = 1 + choice % 7;
    var fixed: Io.Reader = .fixed(input);
    var r = JpegReconstructor.init(&fixed, .{ .limits = harness.limits, .seeker = .fixed(&fixed) });
    var trickle: Trickle = undefined;
    trickle.init(input, step);
    var t = JpegReconstructor.init(&trickle.reader, .{ .limits = harness.limits, .seeker = trickle.seeker() });

    const len = r.workLen() catch |e| {
        if (t.workLen()) |_| return error.ChunkedDiffers else |e2| if (code(e) != code(e2)) return error.ChunkedDiffers;
        return;
    };
    if ((t.workLen() catch return error.ChunkedDiffers) != len) return error.ChunkedDiffers;
    if (len > harness.limits.max_work) return error.LimitIgnored;

    var w: Io.Writer = .fixed(&outs[0]);
    const want = r.run(&w, work_buffer[0..len]);
    var drip: harness.Drip = undefined;
    drip.init(&outs[1], step);
    const got = t.run(&drip.writer, work_buffer[0..len]);
    if (want) |_| {
        _ = got catch return error.ChunkedDiffers;
        drip.writer.flush() catch return error.ChunkedDiffers;
        if (!std.mem.eql(u8, w.buffered(), outs[1][0..drip.len])) return error.ChunkedDiffers;
    } else |e| {
        if (got) |_| return error.ChunkedDiffers else |e2| if (code(e) != code(e2)) return error.ChunkedDiffers;
    }

    if (len > 0) {
        fixed = .fixed(input);
        var short = JpegReconstructor.init(&fixed, .{ .limits = harness.limits, .seeker = .fixed(&fixed) });
        var discard: Io.Writer.Discarding = .init(&.{});
        if (short.run(&discard.writer, work_buffer[0 .. len - 1])) |_| return error.UndersizeAccepted else |_| {}
    }
}

/// The payload of the first `jbrd` box of a JPEG XL container, or the
/// whole input when it is not a container.
fn boxOf(input: []const u8) []const u8 {
    const sig = "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a";
    if (!std.mem.startsWith(u8, input, sig)) return input;
    var at: usize = sig.len;
    while (input.len - at >= 8) {
        const size: u64 = std.mem.readInt(u32, input[at..][0..4], .big);
        const kind = input[at + 4 ..][0..4];
        var head: usize = 8;
        var len: u64 = undefined;
        if (size == 1) {
            if (input.len - at < 16) break;
            const big = std.mem.readInt(u64, input[at + 8 ..][0..8], .big);
            if (big < 16) break;
            head = 16;
            len = big - 16;
        } else if (size == 0) {
            len = input.len - at - 8;
        } else {
            if (size < 8) break;
            len = size - 8;
        }
        const rest = input[at + head ..];
        const n: usize = @intCast(@min(len, rest.len));
        if (std.mem.eql(u8, kind, "jbrd")) return rest[0..n];
        if (n < len) break;
        at += head + n;
    }
    return &.{};
}

fn checkBox(box: []const u8, choice: u64) !void {
    // A counting parse, a real one into exactly what it counted, and one
    // through a trickle.
    var count_reader: Io.Reader = .fixed(box);
    var count_bits: jbrd.Bits = .init(&count_reader, box.len);
    var count: jbrd.Mem = .{ .counting = true };
    const counted = jbrd.read(&count_bits, &count);

    var trickle: Trickle = undefined;
    trickle.init(box, 1 + choice % 7);
    var trickle_bits: jbrd.Bits = .init(&trickle.reader, box.len);
    var trickle_count: jbrd.Mem = .{ .counting = true };
    const trickled = jbrd.read(&trickle_bits, &trickle_count);
    if (counted) |_| {
        _ = trickled catch return error.ChunkedDiffers;
        if (trickle_count.used != count.used) return error.ChunkedDiffers;
    } else |e| {
        if (trickled) |_| return error.ChunkedDiffers else |e2| if (code(e) != code(e2)) return error.ChunkedDiffers;
        return;
    }
    const c = counted catch unreachable;
    if (count.used > parse_buffer.len or c.payload_len > payload_buffer.len) return;

    var reader: Io.Reader = .fixed(box);
    var bits: jbrd.Bits = .init(&reader, box.len);
    // Unaligned, so the count's alignment slack is what makes it fit.
    var mem: jbrd.Mem = .{ .buf = parse_buffer[1..][0..count.used] };
    var j = jbrd.read(&bits, &mem) catch |e| {
        // Only the table check is left to a real parse.
        if (e != error.BadJbrd) return error.CountDiffers;
        return;
    };
    if (j.payload_len != c.payload_len) return error.CountDiffers;
    const rest: usize = @intCast(bits.remaining());
    jbrd.split(&j, box[box.len - rest ..], payload_buffer[0..@intCast(j.payload_len)]) catch return;

    // An image of `choice`'s size and sampling, with sparse coefficients.
    var prng: std.Random.DefaultPrng = .init(choice);
    const random = prng.random();
    var img: jbrd.Image = .{
        .width = 1 + random.uintLessThan(u32, 64),
        .height = 1 + random.uintLessThan(u32, 64),
        .h = undefined,
        .v = undefined,
        .quant = undefined,
        .coefs = undefined,
    };
    for (0..3) |i| {
        img.h[i] = 1 + random.uintLessThan(u4, 2);
        img.v[i] = 1 + random.uintLessThan(u4, 2);
        for (&img.quant[i]) |*q| q.* = 1 + random.uintLessThan(u16, if (random.boolean()) 255 else 65535);
        for (&coefs[i]) |*x| x.* = coefficient(random);
        img.coefs[i] = &coefs[i];
    }
    @memset(metadata[0..@min(metadata.len, c.icc_len)], 0x5a);
    if (c.icc_len <= metadata.len) img.icc = metadata[0..@intCast(c.icc_len)];
    if (c.exif_len) |n| if (n + 4 <= metadata.len) {
        img.exif = metadata[0 .. n + 4];
    };
    if (c.xmp_len) |n| if (n <= metadata.len) {
        img.xmp = metadata[0..n];
    };

    var w: Io.Writer = .fixed(&outs[0]);
    const want = jbrd.write(&w, &j, &img, &scratch);
    var drip: harness.Drip = undefined;
    drip.init(&outs[1], 1 + (choice >> 8) % 13);
    const got = jbrd.write(&drip.writer, &j, &img, &scratch);
    // A JPEG larger than the buffers proves nothing either way.
    if (want) |_| {} else |e| if (e == error.WriteFailed) return;
    if (got) |_| {} else |e| if (e == error.WriteFailed) return;
    if (want) |_| {
        _ = got catch return error.ChunkedWriterDiffers;
        drip.writer.flush() catch return;
        if (!std.mem.eql(u8, w.buffered(), outs[1][0..drip.len])) return error.ChunkedWriterDiffers;
    } else |e| {
        const e2 = if (got) |_| return error.ChunkedWriterDiffers else |x| x;
        if (code(e) != code(e2)) return error.ChunkedWriterDiffers;
    }
}

/// Mostly zero, often small, sometimes as large as 8-bit JPEG allows, and
/// rarely any value at all.
fn coefficient(random: std.Random) i16 {
    return switch (random.uintLessThan(u8, 32)) {
        0...19 => 0,
        20...29 => random.intRangeAtMost(i16, -4, 4),
        30 => random.intRangeAtMost(i16, -2047, 2047),
        else => random.int(i16),
    };
}

/// A reader that hands over at most `step` bytes per read and can seek,
/// as the harness's private one.
const Trickle = struct {
    data: []const u8,
    at: usize = 0,
    step: usize,
    buffer: [image.min_buffer_len]u8 = undefined,
    reader: Io.Reader,

    fn init(t: *Trickle, data: []const u8, step: usize) void {
        t.* = .{
            .data = data,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &t.buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("reader", r);
        const rest = t.data[t.at..];
        if (rest.len == 0) return error.EndOfStream;
        const n = try w.write(rest[0..limit.minInt(@min(t.step, rest.len))]);
        t.at += n;
        return n;
    }

    fn seeker(t: *Trickle) image.Seeker {
        return .{ .context = t, .seek = seek };
    }

    fn seek(context: *anyopaque, offset: u64) error{ReadFailed}!void {
        const t: *Trickle = @ptrCast(@alignCast(context));
        t.at = @intCast(@min(offset, t.data.len));
        t.reader.seek = 0;
        t.reader.end = 0;
    }
};

/// Bits, least significant first, as the box stores them.
const BitWriter = struct {
    buf: []u8,
    bit: usize = 0,

    fn put(w: *BitWriter, v: u64, n: u6) void {
        for (0..n) |i| {
            const byte = w.bit / 8;
            if (byte >= w.buf.len) return;
            if (w.bit % 8 == 0) w.buf[byte] = 0;
            if ((v >> @intCast(i)) & 1 == 1) w.buf[byte] |= @as(u8, 1) << @intCast(w.bit % 8);
            w.bit += 1;
        }
    }

    fn pad(w: *BitWriter) void {
        while (w.bit % 8 != 0) w.put(0, 1);
    }

    fn bytes(w: *const BitWriter) usize {
        return @min(w.buf.len, (w.bit + 7) / 8);
    }

    /// A count field (1 to 4) by its selector.
    fn count(w: *BitWriter, n: u32) void {
        w.put(n - 1, 2);
    }

    /// A list length, block, or tail field: 0 by selector 0, or `n` bits
    /// plus `offset` by selector 1, which every small value fits.
    fn small(w: *BitWriter, x: u32, n: u6, offset: u32) void {
        if (x == 0) return w.put(0, 2);
        w.put(1, 2);
        w.put(x - offset, n);
    }
};

/// A Huffman code in the box: the first `short` symbols of `syms` in
/// codes of `len` bits, the rest and the terminal symbol in codes one bit
/// longer.
fn huffman(w: *BitWriter, slot: u8, is_last: bool, syms: []const u16, short: usize, len: u5) void {
    w.put(slot >> 4, 1);
    w.put(slot & 3, 2);
    w.put(@intFromBool(is_last), 1);
    for (0..17) |l| {
        const k: u32 = if (l == len) @intCast(short) else if (l == len + 1) @intCast(syms.len - short + 1) else 0;
        if (k == 0) w.put(0, 2) else if (k == 1) w.put(1, 2) else {
            w.put(3, 2);
            w.put(k, 8);
        }
    }
    for (syms) |s| {
        if (s < 4) {
            w.put(0, 2);
            w.put(s, 2);
        } else {
            w.put(3, 2);
            w.put(s - 1, 8);
        }
    }
    w.put(3, 2);
    w.put(255, 8); // 256, the terminal symbol
}

/// A JPEG XL container of a generated `jbrd` box and, usually, a
/// generated codestream: a plausible baseline or progressive JPEG layout
/// with complete Huffman tables, metadata markers, restarts, padding bits,
/// and zero runs, and an uncompressed Brotli stream of their bytes.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 16384);
    const head = "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a" ++ "\x00\x00\x00\x14ftypjxl \x00\x00\x00\x00jxl ";
    @memcpy(buf[0..head.len], head);
    const box_at = head.len + 8;
    const box_end = buf.len / 2;
    const box_len = generateBox(random, buf[box_at..box_end]);
    std.mem.writeInt(u32, buf[head.len..][0..4], @intCast(box_len + 8), .big);
    @memcpy(buf[head.len + 4 ..][0..4], "jbrd");
    var at = box_at + box_len;
    if (random.uintLessThan(u8, 8) != 0) {
        const cs = jxl_fuzz.generate(random, buf[box_end..]);
        std.mem.writeInt(u32, buf[at..][0..4], @intCast(cs.len + 8), .big);
        @memcpy(buf[at + 4 ..][0..4], "jxlc");
        @memmove(buf[at + 8 ..][0..cs.len], cs);
        at += 8 + cs.len;
    }
    return buf[0..at];
}

fn generateBox(random: std.Random, buf: []u8) usize {
    var w: BitWriter = .{ .buf = buf };
    const gray = random.boolean();
    const nc: u32 = if (gray) 1 else 3;
    const progressive = random.boolean();
    const restarts = random.uintLessThan(u8, 4) == 0;
    const two_tables = !gray and random.boolean();

    // The marker list, and what the payload holds.
    var markers: [64]u8 = undefined;
    var nm: usize = 0;
    var app_sizes: [4]u32 = undefined;
    var napp: usize = 0;
    var com_sizes: [2]u32 = undefined;
    var ncom: usize = 0;
    var inter_sizes: [2]u32 = undefined;
    var ninter: usize = 0;
    // Scans: (ss, se, ah, al, component or 3 for all).
    var scans: [16][5]u8 = undefined;
    var ns: usize = 0;
    for (0..random.uintLessThan(usize, 3)) |_| {
        markers[nm] = 0xe0 + random.uintLessThan(u8, 16);
        nm += 1;
        app_sizes[napp] = 3 + random.uintLessThan(u32, 40);
        napp += 1;
    }
    if (random.uintLessThan(u8, 4) == 0) {
        markers[nm] = 0xfe;
        nm += 1;
        com_sizes[ncom] = 3 + random.uintLessThan(u32, 20);
        ncom += 1;
    }
    markers[nm] = 0xdb;
    nm += 1;
    markers[nm] = if (progressive) 0xc2 else 0xc0 + random.uintLessThan(u8, 2);
    nm += 1;
    markers[nm] = 0xc4;
    nm += 1;
    if (restarts) {
        markers[nm] = 0xdd;
        nm += 1;
    }
    if (progressive) {
        const al = random.uintLessThan(u8, 2);
        scans[ns] = .{ 0, 0, 0, al, 3 };
        ns += 1;
        for (0..nc) |ci| {
            scans[ns] = .{ 1, 5, 0, 1, @intCast(ci) };
            scans[ns + 1] = .{ 6, 63, 0, 1, @intCast(ci) };
            scans[ns + 2] = .{ 1, 63, 1, 0, @intCast(ci) };
            ns += 3;
        }
        if (al == 1) {
            scans[ns] = .{ 0, 0, 1, 0, 3 };
            ns += 1;
        }
    } else {
        scans[ns] = .{ 0, 63, 0, 0, 3 };
        ns += 1;
    }
    for (0..ns) |_| {
        if (ninter < inter_sizes.len and random.uintLessThan(u8, 8) == 0) {
            markers[nm] = 0xff;
            nm += 1;
            inter_sizes[ninter] = random.uintLessThan(u32, 8);
            ninter += 1;
        }
        markers[nm] = 0xda;
        nm += 1;
    }
    markers[nm] = 0xd9;
    nm += 1;

    w.put(@intFromBool(gray), 1);
    for (markers[0..nm]) |m| w.put(m - 0xc0, 6);
    for (app_sizes[0..napp]) |s| {
        w.put(0, 2); // unknown
        w.put(s - 1, 16);
    }
    for (com_sizes[0..ncom]) |s| w.put(s - 1, 16);
    const nq: u32 = if (two_tables) 2 else 1;
    w.count(nq);
    for (0..nq) |i| {
        w.put(0, 1);
        w.put(i, 2);
        w.put(@intFromBool(i == nq - 1), 1);
    }
    w.put(if (gray) 0 else 1, 2);
    for (0..nc) |ci| w.put(if (two_tables and ci > 0) 1 else 0, 2);

    // Complete tables: every DC category, every AC symbol.
    var dc_syms: [12]u16 = undefined;
    for (&dc_syms, 0..) |*s, i| s.* = @intCast(i);
    var ac_syms: [256]u16 = undefined;
    for (&ac_syms, 0..) |*s, i| s.* = @intCast(i);
    const sets: u32 = if (two_tables) 2 else 1;
    w.put(1, 2); // 2 + 3 bits
    w.put(2 * sets - 2, 3);
    for (0..sets) |t| {
        const last = t == sets - 1;
        huffman(&w, @intCast(t), false, &dc_syms, 0, 3);
        huffman(&w, @intCast(0x10 | t), last, &ac_syms, 128, 8);
    }

    for (scans[0..ns]) |s| {
        const all = s[4] == 3;
        const n: u32 = if (all) nc else 1;
        w.count(n);
        w.put(s[0], 6);
        w.put(s[1], 6);
        w.put(s[3], 4);
        w.put(s[2], 4);
        for (0..n) |k| {
            const ci: u32 = if (all) @intCast(k) else s[4];
            const t: u32 = if (two_tables and ci > 0) 1 else 0;
            w.put(ci, 2);
            w.put(t, 2);
            w.put(t, 2);
        }
        w.put(0, 2); // last_pass
    }
    if (restarts) w.put(random.uintLessThan(u32, 5), 16);
    for (scans[0..ns]) |s| {
        // Reset points and zero runs, a few in the first blocks; a zero run
        // only where a band can hold 16 zeros and the scan is no
        // refinement.
        const nr = random.uintLessThan(u32, 3);
        w.small(nr, 2, 1);
        for (0..nr) |_| w.small(random.uintLessThan(u32, 4), 3, 1);
        const runs = s[0] > 0 or !progressive;
        const nz = if (runs and s[1] - s[0] >= 16 and s[2] == 0) random.uintLessThan(u32, 3) else 0;
        w.small(nz, 2, 1);
        for (0..nz) |_| {
            w.put(0, 2); // one ZRL
            w.small(random.uintLessThan(u32, 4), 3, 1);
        }
    }
    for (inter_sizes[0..ninter]) |s| w.put(s, 16);
    const tail = random.uintLessThan(u32, 4);
    w.small(tail, 8, 1);
    if (random.uintLessThan(u8, 4) == 0) {
        // Enough for a 64 by 64 image in 8 by 8 MCUs, a restart after
        // each.
        const nbits: u32 = @intCast(7 * ns * if (restarts) @as(u32, 65) else 1);
        w.put(1, 1);
        w.put(nbits, 24);
        for (0..nbits) |_| w.put(random.int(u1), 1);
    } else w.put(0, 1);
    w.pad();

    // The payload: APP, COM, inter-marker, and tail bytes, in one
    // uncompressed meta-block of a Brotli stream.
    var payload: [4 * 43 + 2 * 23 + 2 * 8 + 4]u8 = undefined;
    var np: usize = 0;
    var app_marker: usize = 0;
    for (app_sizes[0..napp]) |s| {
        while (markers[app_marker] & 0xf0 != 0xe0) app_marker += 1;
        piece(random, payload[np..][0..s], markers[app_marker]);
        app_marker += 1;
        np += s;
    }
    for (com_sizes[0..ncom]) |s| {
        piece(random, payload[np..][0..s], 0xfe);
        np += s;
    }
    for (inter_sizes[0..ninter]) |s| {
        random.bytes(payload[np..][0..s]);
        np += s;
    }
    random.bytes(payload[np..][0..tail]);
    np += tail;
    w.put(0, 1); // WBITS 16
    if (np > 0) {
        w.put(0, 1); // ISLAST
        w.put(0, 2); // four nibbles
        w.put(np - 1, 16);
        w.put(1, 1); // ISUNCOMPRESSED
        w.pad();
        for (payload[0..np]) |b| w.put(b, 8);
    }
    w.put(1, 1); // ISLAST
    w.put(1, 1); // ISLASTEMPTY
    w.pad();
    return w.bytes();
}

/// A marker's bytes after 0xFF: its type, its length, and random contents.
fn piece(random: std.Random, out: []u8, marker: u8) void {
    out[0] = marker;
    out[1] = @intCast((out.len - 1) >> 8);
    out[2] = @truncate(out.len - 1);
    random.bytes(out[3..]);
}

/// Hand-written seeds for the coverage-guided fuzzer: `cjxl
/// --lossless_jpeg=1` of an 8 by 8 grey baseline JPEG.
pub const seeds = [_][]const u8{
    "\x00\x00\x00\x0c\x4a\x58\x4c\x20\x0d\x0a\x87\x0a\x00\x00\x00\x14\x66\x74\x79\x70\x6a\x78\x6c\x20" ++
        "\x00\x00\x00\x00\x6a\x78\x6c\x20\x00\x00\x00\x13\x6a\x78\x6c\x70\x00\x00\x00\x00\xff\x0a\x41\x40" ++
        "\x50\xdc\x08\x00\x00\x00\x3d\x6a\x62\x72\x64\xc1\x0d\x20\x08\x2d\x03\x02\x00\x84\x80\x08\x00\x00" ++
        "\x00\x80\xfe\x4f\x30\x02\x00\x00\x00\x18\x63\xb2\x45\xff\x07\xf8\x01\x00\x00\x0b\x08\x80\xe0\x00" ++
        "\x10\x4a\x46\x49\x46\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\x03\x00\x00\x00\xb3\x6a\x78\x6c\x70" ++
        "\x80\x00\x00\x01\xe0\x5b\x00\x10\x00\x80\x02\x0c\x64\x0c\x64\x0c\x64\xfe\xff\x0e\x80\x60\x00\x50" ++
        "\x68\x48\x52\x00\x00\x00\x0f\x00\x00\xf0\x00\x00\x00\x00\x00\x00\x00\x00\x04\x2c\x49\x14\x19\xc7" ++
        "\x4e\x48\x73\x87\x01\x08\x29\x70\x0a\x11\x28\x22\xe4\xd8\x28\x06\x04\x00\x30\x61\x00\x00\x00\x98" ++
        "\x9c\x00\x62\xc8\x7a\x5d\x00\x80\x00\xa2\x4b\xd8\xfa\x51\xdd\x3d\xee\x7e\x64\x26\xfe\x0c\xe3\xeb" ++
        "\xa1\x01\x4b\x76\x55\x63\x54\x52\xf4\x8d\x08\x78\xc6\xa7\x9a\x7f\x97\xc6\x16\x18\xfb\x8e\x9f\x05" ++
        "\x21\xf5\x56\x2d\xab\x50\x19\xff\xdd\xfe\x49\xd3\xa9\xf1\xb1\x8f\xd4\xe0\xbb\x29\xde\xc4\xcc\x26" ++
        "\xe5\xcb\x2e\x00\x75\x00\x00\x00\x00\x00\x00\x94\x24\x56\x61\x8c\x8b\x31\x00\x18\x00\x70\xde\x81" ++
        "\x15\xa0\x00",
};

test "generated boxes parse and write" {
    var prng: std.Random.DefaultPrng = .init(1);
    var buf: [1 << 16]u8 = undefined;
    var parsed: usize = 0;
    var written: usize = 0;
    for (0..200) |i| {
        const input = generate(prng.random(), &buf);
        try check(input, i);
        const box = boxOf(input);
        var r: Io.Reader = .fixed(box);
        var bits: jbrd.Bits = .init(&r, box.len);
        var mem: jbrd.Mem = .{ .buf = &parse_buffer };
        var j = jbrd.read(&bits, &mem) catch continue;
        parsed += 1;
        const rest: usize = @intCast(bits.remaining());
        try jbrd.split(&j, box[box.len - rest ..], payload_buffer[0..@intCast(j.payload_len)]);
        var img: jbrd.Image = .{
            .width = 16,
            .height = 16,
            .h = @splat(1),
            .v = @splat(1),
            .quant = @splat(@splat(1)),
            .coefs = undefined,
        };
        for (&img.coefs, 0..) |*c, ci| {
            @memset(&coefs[ci], 0);
            c.* = &coefs[ci];
        }
        var w: Io.Writer = .fixed(&outs[0]);
        jbrd.write(&w, &j, &img, &scratch) catch continue;
        written += 1;
    }
    // Most generated boxes are valid JPEGs.
    try std.testing.expect(parsed >= 190);
    try std.testing.expect(written >= 150);
}

test "jxl_jbrd on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
