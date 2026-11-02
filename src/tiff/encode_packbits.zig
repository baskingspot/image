//! PackBits (TIFF 6.0, section 9), encoding a row at a time, as the
//! specification asks: packets do not cross rows. A run of three or more
//! equal bytes is a repeat packet, and a single byte joins a literal
//! packet, which holds at most 128. A run of two joins the literal packet
//! before it when a single byte follows and the packet has room, where it
//! costs no more than a literal does, and is otherwise a repeat packet:
//! with no literal bytes before it in the packet, in a packet one byte from
//! full, before another run, and at the row's end. Where these choices tie,
//! they are libtiff's, found by encoding every short row and thousands of
//! long ones with it, so the bytes match the bar's
//! (test/oracle/tiff_encode.zig).

const std = @import("std");
const testing = std.testing;

/// The most bytes `encodeRow` writes for a row of `n` bytes. Repeat
/// packets cost at most their bytes, and each literal packet one byte
/// more; literal packets are at most one more than the repeats between
/// them, each repeat taking two bytes and each literal one, plus one for
/// every 128 literal bytes, so at most (n + 2) / 3 + n / 128 of them, and
/// never more than n.
pub fn bound(n: usize) usize {
    return n + @min(n, (n + 2) / 3 + n / 128);
}

/// Writes `row` as packets to `dst`, which holds at least `bound(row.len)`
/// bytes, and returns their length.
pub fn encodeRow(row: []const u8, dst: []u8) usize {
    std.debug.assert(dst.len >= bound(row.len));
    var at: usize = 0;
    var lit: usize = 0;
    var i: usize = 0;
    while (i < row.len) {
        const run = runAt(row, i);
        // The bytes in the literal packet being filled.
        const filled = (i - lit) % 128;
        const room = filled != 0 and filled != 127;
        const repeat = run >= 3 or run == 2 and (!room or i + 2 == row.len or runAt(row, i + 2) >= 2);
        if (!repeat) {
            i += run;
            continue;
        }
        at = literal(row[lit..i], dst, at);
        dst[at] = @bitCast(@as(i8, @intCast(1 - @as(i16, @intCast(run)))));
        dst[at + 1] = row[i];
        at += 2;
        i += run;
        lit = i;
    }
    return literal(row[lit..], dst, at);
}

/// The length of the run of equal bytes at `i`, at most 128.
fn runAt(row: []const u8, i: usize) usize {
    const end = @min(row.len, i + 128);
    var j = i + 1;
    while (j < end and row[j] == row[i]) j += 1;
    return j - i;
}

/// Writes `bytes` as literal packets of at most 128 bytes at `dst[at..]`.
fn literal(bytes: []const u8, dst: []u8, at_in: usize) usize {
    var at = at_in;
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, 128);
        dst[at] = @intCast(n - 1);
        @memcpy(dst[at + 1 ..][0..n], rest[0..n]);
        at += 1 + n;
        rest = rest[n..];
    }
    return at;
}

const packbits = @import("packbits.zig");

fn roundTrip(row: []const u8) !usize {
    var z: [bound(1000)]u8 = undefined;
    const n = encodeRow(row, &z);
    try testing.expect(n <= bound(row.len));
    var r: std.Io.Reader = .fixed(z[0..n]);
    var d: packbits.Decoder = .init(&r);
    var out: [1000]u8 = undefined;
    try d.read(out[0..row.len]);
    try testing.expectEqualSlices(u8, row, out[0..row.len]);
    try testing.expectEqual(0, r.bufferedLen());
    return n;
}

test "packets" {
    // A literal, a repeat, and runs of two inside and outside literals.
    try testing.expectEqual(4, try roundTrip("abc"));
    try testing.expectEqual(2, try roundTrip("aaaa"));
    try testing.expectEqual(2, try roundTrip("aa"));
    try testing.expectEqual(4, try roundTrip("aabbb"));
    try testing.expectEqual(6, try roundTrip("abccd"));
    try testing.expectEqual(6, try roundTrip("abbaa"));
    try testing.expectEqual(4, try roundTrip("aab"));
    try testing.expectEqual(0, try roundTrip(""));
    // Runs and literals longer than a packet.
    try testing.expectEqual(4, try roundTrip("x" ** 256));
    try testing.expectEqual(8, try roundTrip("x" ** 257 ++ "yy"));
    // A run of two that would overfill a literal packet repeats.
    var long: [127 + 3]u8 = undefined;
    for (long[0..127], 0..) |*b, i| b.* = @intCast(i);
    long[127..].* = .{ 200, 200, 201 };
    try testing.expectEqual(128 + 2 + 2, try roundTrip(&long));
    var noise: [300]u8 = undefined;
    for (&noise, 0..) |*b, i| b.* = @truncate(i);
    try testing.expectEqual(303, try roundTrip(&noise));
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    var row: [1000]u8 = undefined;
    for (0..200) |_| {
        for (&row) |*b| b.* = prng.random().uintLessThan(u8, 3);
        _ = try roundTrip(row[0 .. 1 + prng.random().uintLessThan(usize, 1000)]);
    }
}
