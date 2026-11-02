//! Netpbm against Wuffs, the bar, stb_image, and MagickWand
//! (test/oracle/netpbm.c). Wuffs reads raw PGM and PPM with maxval 255 or
//! 65535, stb_image raw PGM and PPM, and MagickWand every kind; each skips
//! the kinds it does not read, so MagickWand alone checks plain files, PBM,
//! PAM, PFM, and other maxvals.
//!
//! The libraries read what no specification allows, and read some valid
//! files their own way. `comparable` leaves out an answer in these cases,
//! so that one library's quirk does not hide another's on the same input:
//!
//! - Gray from color: every library has its own luma, so no gray answer
//!   counts for a color file.
//! - Wuffs reads neither comments nor VT and FF as whitespace in headers
//!   and accepts a zero width or height; it does not widen 8-bit samples to
//!   16 bits, and writes 16-bit color only as `bgra16`. Its answers count
//!   only for headers without those, and not for 8-bit files in 16-bit
//!   formats or 16-bit color in 16-bit formats but `bgra16`. It narrows
//!   16-bit samples by taking the high byte, as `image.convert` does, so
//!   16-bit files in 8-bit formats count.
//! - stb_image neither scales maxvals other than 255 nor swaps 16-bit
//!   samples to the machine's order, so it counts only for maxval 255; and
//!   it takes whatever character follows the maxval as the end of the
//!   header, even a `#` starting a comment or a non-space, so it counts
//!   only where whitespace follows the maxval.
//! - MagickWand checks little: it reads any byte after the magic number as
//!   its separator (so a `#` there starts its width), ends header numbers
//!   at any non-digit, reads maxvals to 2^32 - 1, takes PAM keywords in any
//!   form, ignores unknown ones and DEPTH, and finds ENDHDR anywhere in a
//!   line, reads a plain raster's non-digits as separators or zeros and any
//!   P1 character but `0` as black, pads a short plain raster (P1 with
//!   white, P2 and P3 with zeros), clamps samples above maxval, and does not
//!   take VT and FF as whitespace between header numbers, and narrows
//!   16-bit samples to 8 bits by rounding, where `image.convert` takes the
//!   high byte, so its 8-bit answers for 16-bit files do not count. So where ours
//!   rejects a header or a plain raster as malformed (`BadHeader`,
//!   `BadRaster`), a sample above maxval (`SampleOutOfRange`), a PAM tuple
//!   type it does not know (`Unsupported`), or a short plain raster
//!   (`Truncated`), and where a header has VT or FF, a `#` right after the
//!   magic number, or (PAM) no ENDHDR line, its answer does not count. The
//!   PFM and PAM specifications end the header at one whitespace character
//!   after the scale and at the newline ending the ENDHDR line, which may
//!   hold blanks such as a CR before it; MagickWand reads the scale's line
//!   to its LF and takes the one character after ENDHDR as the end, so PFM
//!   headers whose scale is not followed by an LF and PAM headers with
//!   anything between ENDHDR and its newline do not count either. It
//!   reads raw samples whose maxval has as many bits as 255 or 65535
//!   (128 to 254, 32768 to 65534) as if it were 255 or 65535, so those do
//!   not count. It reads PAM planes by tuple type alone, RGB without one,
//!   so PAM files without a tuple type or with more planes than theirs are
//!   left out too. It reads `PH` and `Ph` as its own half-float PFM, which
//!   no Netpbm specification has, so its answers for those do not count.
//! - MagickWand holds samples as single-precision floats scaled to 65535.
//!   A sample `v` of another maxval `m` becomes `v * 65535 / m` rounded to
//!   single precision and then to an integer, which differs from the exact
//!   quotient rounded where that is within a float's precision of a half;
//!   a PFM sample `f` comes back as `f * 65535 / 65535` in single precision,
//!   which is not always `f`, and magnitudes over 3.4e38 / 65535,
//!   infinities, and NaNs are clamped. `inexact` repeats that arithmetic on
//!   our pixels, and where it changes a sample, its answers of that sample
//!   size do not count. For other maxvals our samples are rounded to 8 or 16
//!   bits before converting to the other size, and it scales to each size
//!   directly, so those answers do not count either. It multiplies PFM
//!   samples by the scale's magnitude, which the PFM specification says
//!   only names units, so `adapt` hands it scale 1 with the same sign.
//!
//! With these left out, the oracles split on nothing: every answer that
//! counts is the same as ours (10000 fuzzed inputs, seeds 2 and 3).

const std = @import("std");
const image = @import("image");
const PixelFormat = image.PixelFormat;

pub const name = "netpbm";
pub const Decoder = image.netpbm.Decoder;
pub const fuzz = @import("fuzz").netpbm;
pub const oracles = [_][]const u8{ "netpbm-wuffs", "netpbm-stb", "netpbm-magick" };
/// The native formats, and two that convert.
pub const formats = [_]PixelFormat{ .gray8, .gray16, .rgb8, .rgb16, .rgba8, .rgba16, .bgra8, .bgra16, .rgba_f32 };

/// What a header says, read loosely.
const Sniff = struct {
    kind: u8 = 0,
    maxval: ?u64 = null,
    /// A comment anywhere in a PNM header.
    comment: bool = false,
    /// A comment right after a PNM header's last number.
    comment_last: bool = false,
    /// Whether whitespace follows a PNM header's last number.
    space_last: bool = false,
    /// VT or FF in a PNM or PFM header.
    odd_space: bool = false,
    /// The byte after the magic number.
    after_magic: u8 = 0,
    /// A zero width or height in a PNM header.
    zero: bool = false,
    /// PAM: whether it names a tuple type, and how many planes the type has
    /// and the header says.
    tuple_planes: ?u64 = null,
    depth: u64 = 0,
    /// PAM: whether a line holds the ENDHDR keyword.
    endhdr: bool = false,
    /// PAM: whether the newline comes right after ENDHDR.
    endhdr_bare: bool = false,
    /// PFM: whether an LF follows the scale.
    pfm_lf: bool = false,
};

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn sniff(input: []const u8) Sniff {
    var s: Sniff = .{};
    if (input.len < 3 or input[0] != 'P') return s;
    s.kind = input[1];
    s.after_magic = input[2];
    if (s.kind == '7') return sniffPam(input, s);
    const numbers: usize = switch (s.kind) {
        '1', '4' => 2,
        else => 3,
    };
    var i: usize = 2;
    for (0..numbers) |t| {
        while (i < input.len) {
            const c = input[i];
            if (c == '#') {
                s.comment = true;
                while (i < input.len and input[i] != '\n' and input[i] != '\r') i += 1;
            } else if (isSpace(c)) {
                if (c == 0x0b or c == 0x0c) s.odd_space = true;
                i += 1;
            } else break;
        }
        var v: u64 = 0;
        while (i < input.len and std.ascii.isDigit(input[i])) : (i += 1) v = @min(v * 10 + (input[i] - '0'), 1 << 33);
        if (t < 2 and v == 0) s.zero = true;
        if (t == 2 and s.kind != 'F' and s.kind != 'f') s.maxval = v;
        if (t == numbers - 1 and i < input.len) {
            s.space_last = isSpace(input[i]);
            switch (input[i]) {
                '#' => s.comment_last = true,
                0x0b, 0x0c => s.odd_space = true,
                else => {},
            }
        }
        // PFM's scale is not a number this reads; skip it.
        if (t == 2) while (i < input.len and !isSpace(input[i])) : (i += 1) {};
        if (t == 2 and (s.kind == 'F' or s.kind == 'f') and i < input.len) s.pfm_lf = input[i] == '\n';
    }
    // A plain raster is text, read like the header.
    if (s.kind >= '1' and s.kind <= '3' and std.mem.findAny(u8, input, "\x0b\x0c") != null) s.odd_space = true;
    if (s.kind == '1' or s.kind == '4') s.maxval = 1;
    return s;
}

fn sniffPam(input: []const u8, s_in: Sniff) Sniff {
    var s = s_in;
    var lines = std.mem.splitScalar(u8, input[3..], '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r\x0b\x0c");
        const key = tokens.next() orelse continue;
        const value = tokens.next() orelse "";
        if (std.mem.eql(u8, key, "ENDHDR")) {
            s.endhdr = true;
            s.endhdr_bare = std.mem.endsWith(u8, line, "ENDHDR");
            break;
        }
        if (std.mem.eql(u8, key, "MAXVAL")) s.maxval = std.fmt.parseInt(u64, value, 10) catch null;
        if (std.mem.eql(u8, key, "DEPTH")) s.depth = std.fmt.parseInt(u64, value, 10) catch 0;
        if (std.mem.eql(u8, key, "TUPLTYPE")) {
            const planes: u64 = if (std.mem.startsWith(u8, value, "RGB")) 3 else 1;
            s.tuple_planes = planes + @intFromBool(std.mem.endsWith(u8, value, "_ALPHA"));
        }
    }
    return s;
}

/// Our answer, as far as `comparable` needs it: the native format, or the
/// error, and whether MagickWand's single-precision arithmetic changes a
/// sample: a float it clamps or does not give back exactly, or a 16-bit
/// sample it rounds the other way.
const Ours = struct {
    native: ?PixelFormat = null,
    err: ?anyerror = null,
    inexact: bool = false,
};

// One per thread: compare.zig calls `comparable` from a worker per core.
threadlocal var cache_hash: ?u64 = null;
threadlocal var cache: Ours = .{};

/// Our answer for `input`, kept for this thread's next call, which is
/// usually for the same input.
fn ours(input: []const u8, maxval: ?u64) Ours {
    const hash = std.hash.Wyhash.hash(input.len, input);
    if (cache_hash != hash) {
        cache = decodeOurs(input, maxval);
        cache_hash = hash;
    }
    return cache;
}

fn decodeOurs(input: []const u8, maxval: ?u64) Ours {
    var r: std.Io.Reader = .fixed(input);
    var d = Decoder.init(&r, .{ .limits = .{ .max_pixels = 1 << 22 } });
    const c = d.decodeConfig() catch |e| return .{ .err = e };
    const gpa = std.heap.smp_allocator;
    const len = image.PixelBuffer.len(c.native, c.width, c.height).?;
    const pixels = gpa.alloc(u8, len) catch return .{ .native = c.native };
    defer gpa.free(pixels);
    const dst = image.PixelBuffer.init(pixels, c.native, c.width, c.height) catch unreachable;
    _ = d.decodeFrame(dst, &.{}) catch |e| return .{ .native = c.native, .err = e };
    return .{ .native = c.native, .inexact = inexact(c.native, pixels, maxval) };
}

/// Whether MagickWand, which holds samples as floats scaled to 65535,
/// gives back other values than ours for these native pixels.
fn inexact(native: PixelFormat, pixels: []const u8, maxval: ?u64) bool {
    if (native == .rgba_f32) {
        // It multiplies by 65535 and divides again, in single precision.
        const floats: []align(1) const f32 = @ptrCast(pixels);
        for (floats) |f| {
            if (!(@abs(f) <= std.math.floatMax(f32) / 65535)) return true;
            const q: f32 = @floatCast(@as(f64, f) * 65535);
            const back: f32 = @floatCast(@as(f64, q) * (1.0 / 65535.0));
            if (back != f) return true;
        }
        return false;
    }
    const m = maxval orelse return false;
    if (native.sample() != .u16 or m == 0 or m >= 65535) return false;
    // It scales a sample v to v * 65535 / m rounded to single precision,
    // then to the nearest integer; ours rounds the exact quotient. Each of
    // our samples q comes from v = round(q * m / 65535).
    const samples: []align(1) const u16 = @ptrCast(pixels);
    for (samples) |q| {
        const v = (@as(u64, q) * m * 2 + 65535) / (2 * 65535);
        const f: f32 = @floatCast(@as(f64, @floatFromInt(v)) * 65535 / @as(f64, @floatFromInt(m)));
        if (@floor(f + 0.5) != @as(f32, @floatFromInt(q))) return true;
    }
    return false;
}

/// Whether `op`'s answer in `format` counts.
pub fn comparable(op: []const u8, format: PixelFormat, input: []const u8) bool {
    const s = sniff(input);
    const o = ours(input, s.maxval);
    if (format.isGray()) if (o.native) |n| if (!n.isGray()) return false;
    if (std.mem.eql(u8, op, "netpbm-wuffs")) {
        if (s.comment or s.comment_last or s.odd_space or s.zero) return false;
        // Wuffs does not widen 8-bit samples to some 16-bit formats, and
        // writes 16-bit color only as BGRA. It narrows 16-bit samples by
        // taking the high byte, as `image.convert` does.
        if (o.native) |n| {
            if (n.sample() == .u8 and format.sample() == .u16) return false;
            if (n == .rgb16 and format.sample() == .u16 and format != .bgra16) return false;
        }
    }
    if (std.mem.eql(u8, op, "netpbm-stb")) {
        if (s.maxval != 255 or !s.space_last) return false;
    }
    if (std.mem.eql(u8, op, "netpbm-magick")) {
        if (o.err) |e| switch (e) {
            error.BadHeader, error.BadRaster, error.SampleOutOfRange, error.Unsupported => return false,
            else => {},
        };
        if (s.odd_space or s.after_magic == '#') return false;
        // `PH` and `Ph` are ImageMagick's own half-float PFM.
        if (s.kind == 'H' or s.kind == 'h') return false;
        if ((s.kind == 'F' or s.kind == 'f') and !s.pfm_lf) return false;
        // It pads a short plain raster: P1 with white, P2 and P3 with zeros.
        if (s.kind >= '1' and s.kind <= '3') if (o.err) |e| if (e == error.Truncated) return false;
        // Raw samples whose maxval has as many bits as 255 or 65535 are
        // read as if it were 255 or 65535.
        if (s.kind >= '5' and s.kind <= '7') if (s.maxval) |m| {
            if ((m >= 128 and m < 255) or (m >= 32768 and m < 65535)) return false;
        };
        if (s.kind == '7') {
            if (!s.endhdr or !s.endhdr_bare) return false;
            const planes = s.tuple_planes orelse return false;
            if (s.depth != planes) return false;
        }
        if (o.inexact and format.sample() == o.native.?.sample()) return false;
        // It narrows 16-bit samples by rounding, where `image.convert`
        // takes the high byte as Wuffs does.
        if (o.native) |n| if (n.sample() == .u16 and format.sample() == .u8) return false;
        // Other maxvals: our native samples are rounded to 8 or 16 bits,
        // and other depths convert from them; it scales to each depth
        // directly.
        if (s.maxval) |m| if (m != 1 and m != 255 and m != 65535) {
            if (o.native) |n| if (n.sample() != format.sample()) return false;
        };
    }
    return true;
}

/// The input `op` sees: for MagickWand, a PFM header as `P? W H\n` and
/// scale 1 or -1, since it reads the scale only after exactly one
/// whitespace character and multiplies samples by its magnitude.
pub fn adapt(op: []const u8, input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (!std.mem.eql(u8, op, "netpbm-magick")) return input;
    if (input.len < 3 or input[0] != 'P' or (input[1] != 'F' and input[1] != 'f')) return input;
    var tokens: [3][]const u8 = undefined;
    var i: usize = 2;
    for (&tokens) |*t| {
        while (i < input.len and isSpace(input[i])) i += 1;
        const start = i;
        while (i < input.len and !isSpace(input[i])) i += 1;
        if (i == start) return input;
        t.* = input[start..i];
    }
    const one: []const u8 = if (tokens[2][0] == '-') "-1" else "1";
    return std.fmt.allocPrint(arena, "{s} {s} {s}\n{s}{s}", .{ input[0..2], tokens[0], tokens[1], one, input[i..] });
}
