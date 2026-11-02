//! The ICC profile's codestream encoding (ISO/IEC 18181-1, Annex on ICC
//! profiles): bytes entropy-coded in 41 contexts, then a command stream
//! that rebuilds the profile from a predicted header, a tag table, and
//! predicted data.

const std = @import("std");
const testing = std.testing;

const BitReader = @import("BitReader.zig");
const entropy = @import("entropy.zig");
const Arena = @import("Arena.zig");

pub const Error = entropy.Error || error{
    /// The profile's encoding is malformed.
    BadIcc,
};

/// The largest encoded profile, and the largest decoded one.
pub const max_size = 1 << 28;
const header_size = 128;

/// The most bytes a profile of `enc_size` encoded bytes decodes to: the
/// header, the tag count, at most 36 bytes per command byte, and the data.
pub fn maxOutput(enc_size: u64) u64 {
    return @min(max_size, header_size + 4 + 37 * enc_size);
}

/// The work memory `read` uses beyond its entropy code: the encoded
/// bytes, the decoded ones, and room to shuffle.
pub fn workLen(enc_size: u64) u64 {
    return 3 * enc_size + maxOutput(enc_size);
}

fn byteKind1(b: u8) u32 {
    if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')) return 0;
    if ((b >= '0' and b <= '9') or b == '.' or b == ',') return 1;
    if (b == 0) return 2;
    if (b == 1) return 3;
    if (b < 16) return 4;
    if (b == 255) return 6;
    if (b > 240) return 5;
    return 7;
}

fn byteKind2(b: u8) u32 {
    if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')) return 0;
    if ((b >= '0' and b <= '9') or b == '.' or b == ',') return 1;
    if (b < 16) return 2;
    if (b > 240) return 3;
    return 4;
}

fn context(i: usize, b1: u8, b2: u8) usize {
    if (i <= 128) return 0;
    return 1 + byteKind1(b1) + byteKind2(b2) * 8;
}

/// Reads the encoded profile of `enc_size` bytes (its size field already
/// read) and returns the decoded profile, in `arena`.
pub fn read(br: *BitReader, arena: *Arena, enc_size: u64) Error![]u8 {
    if (enc_size > max_size) return error.BadIcc;
    const start_bits = br.pos;
    const code = try entropy.Code.read(br, arena, 41);
    var r: entropy.Reader = try .init(&code, br, arena, 0, @intCast(@min(enc_size, entropy.window_size)));
    const n: usize = @intCast(enc_size);
    const enc = try arena.alloc(u8, n);
    for (0..n) |i| {
        if (i > 0 and i % 0x10000 == 0) {
            const used: f32 = @as(f32, @floatFromInt(br.pos - start_bits)) / 8;
            if (@as(f32, @floatFromInt(i)) > used * 256) return error.BadIcc;
        }
        const b1 = if (i > 0) enc[i - 1] else 0;
        const b2 = if (i > 1) enc[i - 2] else 0;
        enc[i] = @truncate(try r.read(br, context(i, b1, b2)));
        if (i + 1 == preamble_size and n > preamble_size) try checkPreamble(enc[0..preamble_size], enc_size);
    }
    if (!r.finalOk()) return error.BadEntropy;
    var p: usize = 0;
    const osize = try varint(enc, &p);
    if (osize > maxOutput(enc_size)) return error.BadIcc;
    const out = try arena.alloc(u8, @intCast(osize + 2 * enc_size));
    const len = try unpredict(enc, out);
    if (len == 0) return error.BadIcc;
    return out[0..len];
}

const preamble_size = 20;

fn checkPreamble(enc: []const u8, enc_size: u64) Error!void {
    var p: usize = 0;
    const osize = try varint(enc, &p);
    if (osize >> 32 != 0) return error.BadIcc;
    const csize = try varint(enc, &p);
    if (csize >> 32 != 0) return error.BadIcc;
    // The reference checks against its buffer, then this long.
    try inBounds(p, csize, @min(1024, enc_size));
    if (osize + 65536 < enc_size) return error.BadIcc;
    if (osize > max_size) return error.BadIcc;
}

fn varint(in: []const u8, pos: *usize) Error!u64 {
    var ret: u64 = 0;
    for (0..9) |i| {
        if (pos.* >= in.len) return error.BadIcc;
        const b = in[pos.*];
        pos.* += 1;
        ret |= @as(u64, b & 0x7f) << @intCast(7 * i);
        if (b & 0x80 == 0) return ret;
    }
    if (pos.* >= in.len) return error.BadIcc;
    const b = in[pos.*];
    pos.* += 1;
    if (b & 0x80 != 0 or b & 0x7e != 0) return error.BadIcc;
    return ret | @as(u64, b & 1) << 63;
}

fn inBounds(a: u64, b: u64, size: u64) Error!void {
    const s = std.math.add(u64, a, b) catch return error.BadIcc;
    if (s > size) return error.BadIcc;
}

fn check32(v: u64) Error!u32 {
    if (v >> 32 != 0) return error.BadIcc;
    return @intCast(v);
}

const initial_header = [header_size]u8{
    0,   0,   0,   0,   0,   0,   0,   0,   4, 0, 0, 0, 'm', 'n', 't', 'r',
    'R', 'G', 'B', ' ', 'X', 'Y', 'Z', ' ', 0, 0, 0, 0, 0,   0,   0,   0,
    0,   0,   0,   0,   'a', 'c', 's', 'p', 0, 0, 0, 0, 0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   246, 214, 0, 1, 0, 0, 0,   0,   211, 45,
    0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0, 0, 0, 0, 0,   0,   0,   0,
};

const tag_strings = [17]*const [4]u8{
    "cprt", "wtpt", "bkpt", "rXYZ", "gXYZ", "bXYZ", "kXYZ", "rTRC", "gTRC",
    "bTRC", "kTRC", "chad", "desc", "chrm", "dmnd", "dmdd", "lumi",
};
const type_strings = [8]*const [4]u8{ "XYZ ", "desc", "text", "mluc", "para", "curv", "sf32", "gbd " };

/// The output being built, which may not grow past `limit`; the buffer
/// past it is scratch.
const Out = struct {
    buf: []u8,
    limit: usize,
    len: usize = 0,

    fn push(o: *Out, b: u8) Error!void {
        if (o.len >= o.limit) return error.BadIcc;
        o.buf[o.len] = b;
        o.len += 1;
    }

    fn append(o: *Out, bytes: []const u8) Error!void {
        for (bytes) |b| try o.push(b);
    }

    fn u32be(o: *Out, v: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try o.append(&b);
    }

    fn be32At(o: *const Out, size: usize, pos: usize) u32 {
        if (pos + 4 > size) return 0;
        return std.mem.readInt(u32, o.buf[pos..][0..4], .big);
    }
};

/// Shuffles `data` in place as the specification's transpose of `width`
/// columns.
fn shuffle(data: []u8, width: usize, tmp: []u8) void {
    const size = data.len;
    const height = (size + width - 1) / width;
    var s: usize = 0;
    var j: usize = 0;
    for (0..size) |i| {
        tmp[i] = data[j];
        j += height;
        if (j >= size) {
            s += 1;
            j = s;
        }
    }
    @memcpy(data, tmp[0..size]);
}

/// Rebuilds the profile from the decoded bytes `enc` into `out`, which
/// is the size `enc` declares plus twice `enc.len`; returns that size.
fn unpredict(enc: []u8, out_buf: []u8) Error!usize {
    const size = enc.len;
    var pos: usize = 0;
    const osize = try check32(try varint(enc, &pos));
    const csize = try check32(try varint(enc, &pos));
    var cpos = pos;
    try inBounds(pos, csize, size);
    const cend = cpos + csize;
    pos = cend;
    if (@as(u64, osize) + 2 * size > out_buf.len) return error.BadIcc;
    var o: Out = .{ .buf = out_buf, .limit = osize };
    var header = initial_header;
    std.mem.writeInt(u32, header[0..4], osize, .big);
    var i: usize = 0;
    while (i <= header_size) : (i += 1) {
        if (o.len == osize) {
            if (cpos != cend) return error.BadIcc;
            if (pos != size) return error.BadIcc;
            return o.len;
        }
        if (i == header_size) break;
        predictHeader(o.buf[0..o.len], &header, i);
        if (pos >= size) return error.BadIcc;
        try o.push(enc[pos] +% header[i]);
        pos += 1;
    }
    if (cpos >= cend) return error.BadIcc;
    var numtags = try varint(enc[0..cend], &cpos);
    if (numtags != 0) {
        numtags -= 1;
        try o.u32be(try check32(numtags));
        var prev_start: u64 = header_size + numtags * 12;
        var prev_size: u64 = 0;
        while (true) {
            if (o.len > osize) return error.BadIcc;
            if (cpos > cend) return error.BadIcc;
            if (cpos == cend) break;
            const command = enc[cpos];
            cpos += 1;
            const code = command & 63;
            var tag: [4]u8 = undefined;
            if (code == 0) {
                break;
            } else if (code == 1) {
                try inBounds(pos, 4, size);
                tag = enc[pos..][0..4].*;
                pos += 4;
            } else if (code == 2) {
                tag = "rTRC".*;
            } else if (code == 3) {
                tag = "rXYZ".*;
            } else {
                if (code - 4 >= tag_strings.len) return error.BadIcc;
                tag = tag_strings[code - 4].*;
            }
            try o.append(&tag);
            var tag_size = prev_size;
            const fixed = [_]*const [4]u8{ "rXYZ", "gXYZ", "bXYZ", "kXYZ", "wtpt", "bkpt", "lumi" };
            for (fixed) |f| {
                if (std.mem.eql(u8, &tag, f)) tag_size = 20;
            }
            var tag_start: u64 = undefined;
            if (command & 64 != 0) {
                tag_start = try varint(enc[0..cend], &cpos);
            } else {
                _ = try check32(prev_start);
                tag_start = prev_start + prev_size;
            }
            try o.u32be(try check32(tag_start));
            if (command & 128 != 0) tag_size = try varint(enc[0..cend], &cpos);
            try o.u32be(try check32(tag_size));
            prev_start = tag_start;
            prev_size = tag_size;
            if (code == 2) {
                try o.append("gTRC");
                try o.u32be(@intCast(tag_start));
                try o.u32be(@intCast(tag_size));
                try o.append("bTRC");
                try o.u32be(@intCast(tag_start));
                try o.u32be(@intCast(tag_size));
            }
            if (code == 3) {
                _ = try check32(tag_start + tag_size * 2);
                try o.append("gXYZ");
                try o.u32be(@intCast(tag_start + tag_size));
                try o.u32be(@intCast(tag_size));
                try o.append("bXYZ");
                try o.u32be(@intCast(tag_start + tag_size * 2));
                try o.u32be(@intCast(tag_size));
            }
        }
    }
    while (true) {
        if (o.len > osize) return error.BadIcc;
        if (cpos > cend) return error.BadIcc;
        if (cpos == cend) break;
        const command = enc[cpos];
        cpos += 1;
        switch (command) {
            1 => {
                const num = try varint(enc[0..cend], &cpos);
                try inBounds(pos, num, size);
                try o.append(enc[pos..][0..@intCast(num)]);
                pos += @intCast(num);
            },
            2, 3 => {
                const num = try varint(enc[0..cend], &cpos);
                try inBounds(pos, num, size);
                const n: usize = @intCast(num);
                const data = enc[pos..][0..n];
                // Shuffle in place, with the scratch past it.
                if (o.limit - o.len < n) return error.BadIcc;
                const dst = o.buf[o.len..][0..n];
                @memcpy(dst, data);
                shuffle(dst, if (command == 2) 2 else 4, o.buf[o.len + n ..][0..n]);
                o.len += n;
                pos += n;
            },
            4 => {
                try inBounds(cpos, 2, cend);
                const flags = enc[cpos];
                cpos += 1;
                const width: usize = (flags & 3) + 1;
                if (width == 3) return error.BadIcc;
                const order: u32 = (flags & 12) >> 2;
                if (order == 3) return error.BadIcc;
                var stride: u64 = width;
                if (flags & 16 != 0) {
                    stride = try varint(enc[0..cend], &cpos);
                    if (stride < width) return error.BadIcc;
                }
                if (o.len == 0 or ((o.len - 1) >> 2) < stride) return error.BadIcc;
                const num = try varint(enc[0..cend], &cpos);
                try inBounds(pos, num, size);
                const n: usize = @intCast(num);
                const st: usize = @intCast(stride);
                if (o.limit - o.len < n) return error.BadIcc;
                // The shuffled residuals sit past where the output goes.
                const res = o.buf[o.len + n ..][0..n];
                @memcpy(res, enc[pos..][0..n]);
                if (width > 1) {
                    shuffle(res, width, o.buf[o.len + 2 * n ..][0..n]);
                }
                const start = o.len;
                for (0..n) |k| {
                    const pred = linearPredict(&o, start, k, st, width, order);
                    o.buf[o.len] = pred +% res[k];
                    o.len += 1;
                }
                pos += n;
            },
            10 => {
                try o.append("XYZ ");
                try o.append(&.{ 0, 0, 0, 0 });
                try inBounds(pos, 12, size);
                try o.append(enc[pos..][0..12]);
                pos += 12;
            },
            16...16 + type_strings.len - 1 => {
                try o.append(type_strings[command - 16]);
                try o.append(&.{ 0, 0, 0, 0 });
            },
            else => return error.BadIcc,
        }
    }
    if (pos != size) return error.BadIcc;
    if (o.len != osize) return error.BadIcc;
    return o.len;
}

fn predictHeader(icc: []const u8, header: *[header_size]u8, pos: usize) void {
    if (pos == 8 and icc.len >= 8) @memcpy(header[80..84], icc[4..8]);
    if (pos == 41 and icc.len >= 41) {
        if (icc[40] == 'A') @memcpy(header[41..44], "PPL");
        if (icc[40] == 'M') @memcpy(header[41..44], "SFT");
    }
    if (pos == 42 and icc.len >= 42) {
        if (icc[40] == 'S' and icc[41] == 'G') @memcpy(header[42..44], "I ");
        if (icc[40] == 'S' and icc[41] == 'U') @memcpy(header[42..44], "NW");
    }
}

fn predictValue(comptime T: type, p1: T, p2: T, p3: T, order: u32) T {
    return switch (order) {
        0 => p1,
        1 => 2 *% p1 -% p2,
        2 => 3 *% p1 -% 3 *% p2 +% p3,
        else => 0,
    };
}

fn linearPredict(o: *const Out, start: usize, i: usize, stride: usize, width: usize, order: u32) u8 {
    const d = o.buf;
    const pos = start + i;
    if (width == 1) {
        return predictValue(u8, d[pos - stride], d[pos - stride * 2], d[pos - stride * 3], order);
    } else if (width == 2) {
        const p = start + (i & ~@as(usize, 1));
        const p1 = std.mem.readInt(u16, d[p - stride ..][0..2], .big);
        const p2 = std.mem.readInt(u16, d[p - stride * 2 ..][0..2], .big);
        const p3 = std.mem.readInt(u16, d[p - stride * 3 ..][0..2], .big);
        const pred = predictValue(u16, p1, p2, p3, order);
        return if (i & 1 == 1) @truncate(pred) else @truncate(pred >> 8);
    } else {
        const p = start + (i & ~@as(usize, 3));
        const p1 = o.be32At(pos, p - stride);
        const p2 = o.be32At(pos, p - stride * 2);
        const p3 = o.be32At(pos, p - stride * 3);
        const pred = predictValue(u32, p1, p2, p3, order);
        const shift: u5 = @intCast(3 - (i & 3));
        return @truncate(pred >> (shift * 8));
    }
}

test "shuffle" {
    var d = [_]u8{ 1, 2, 3, 4, 5, 6 };
    var tmp: [6]u8 = undefined;
    shuffle(&d, 2, &tmp);
    // Height 3: reads columns 0, 3, 1, 4, 2, 5.
    try testing.expectEqualSlices(u8, &.{ 1, 4, 2, 5, 3, 6 }, &d);
}

test "varint" {
    var p: usize = 0;
    try testing.expectEqual(@as(u64, 300), try varint(&.{ 0xac, 0x02 }, &p));
    try testing.expectEqual(@as(usize, 2), p);
}
