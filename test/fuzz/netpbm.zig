//! The Netpbm fuzz target: the decoder properties in harness.zig, on
//! mutated corpus files and generated files of every kind (PBM, PGM, and
//! PPM, plain and raw; PAM; PFM), with odd maxvals, comments, every PAM
//! tuple type, and sequences of images.

const std = @import("std");
const image = @import("image");
const harness = @import("harness.zig");

pub const name = "netpbm";

/// Not bench/corpus-gen/netpbm: its 2 GB of mostly large raw files would
/// add little the generator does not reach, and the oracle reads the corpus
/// whole.
pub const corpus = [_][]const u8{ "corpus/fetched", "corpus/vendor" };
pub const extensions = [_][]const u8{ ".pbm", ".pgm", ".ppm", ".pnm", ".pam", ".pfm" };

pub fn check(input: []const u8, choice: u64) !void {
    try harness.checkDecoder(image.netpbm.Decoder, input, choice);
}

/// A Netpbm file, usually valid: a header with random separators and
/// comments and a raster that fits it, sometimes followed by more images,
/// and sometimes broken. A raster that overflows `buf` is cut short.
pub fn generate(random: std.Random, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 64);
    var w: std.Io.Writer = .fixed(buf);
    // A full buffer cuts the file short, which is one of its cases.
    file(random, &w) catch |e| switch (e) {
        error.WriteFailed => {},
    };
    return w.buffered();
}

const kinds = "1234567Ff";
const spaces = " \t\n\r\x0b\x0c";

fn chance(random: std.Random, n: u8) bool {
    return random.uintLessThan(u8, n) == 0;
}

const Image = struct {
    kind: u8,
    width: u32,
    height: u32,
    maxval: u32,
    depth: u32,
};

fn file(random: std.Random, w: *std.Io.Writer) !void {
    var img: Image = .{
        .kind = kinds[random.uintLessThan(usize, kinds.len)],
        .width = if (chance(random, 8)) random.uintAtMost(u32, 300) else 1 + random.uintLessThan(u32, 24),
        .height = 1 + random.uintLessThan(u32, 24),
        .maxval = switch (random.uintLessThan(u8, 8)) {
            0 => 1,
            1 => 255,
            2 => 65535,
            3 => 2 + random.uintLessThan(u32, 253),
            4 => 256 + random.uintLessThan(u32, 65279),
            5 => if (chance(random, 4)) random.int(u32) else 255,
            else => if (chance(random, 2)) 255 else 65535,
        },
        .depth = 1 + random.uintLessThan(u32, if (chance(random, 8)) 6 else 4),
    };
    if (chance(random, 32)) img.height = 0;
    const raw = img.kind >= '4' and img.kind <= '7';
    const count: usize = if (raw and chance(random, 6)) 2 + random.uintLessThan(usize, 3) else 1;
    for (0..count) |i| {
        if (i > 0) {
            // Usually the same image again; sometimes another kind or size.
            if (chance(random, 3)) try separator(random, w, false);
            if (chance(random, 8)) img.maxval = if (img.maxval > 255) 65535 else 1 + random.uintLessThan(u32, 255);
            if (chance(random, 16)) img.kind = kinds[random.uintLessThan(usize, kinds.len)];
            if (chance(random, 16)) img.width += 1;
        }
        try header(random, w, img);
        try raster(random, w, img);
    }
    if (chance(random, 8)) try w.writeAll(if (chance(random, 2)) "\n" else "junk");
}

fn separator(random: std.Random, w: *std.Io.Writer, comments: bool) !void {
    const n = 1 + random.uintLessThan(usize, if (chance(random, 4)) 4 else 1);
    for (0..n) |_| {
        if (comments and chance(random, 6)) {
            try w.writeAll(if (chance(random, 2)) "# a comment" else "#");
        }
        try w.writeByte(spaces[random.uintLessThan(usize, if (chance(random, 4)) spaces.len else 2)]);
    }
}

fn header(random: std.Random, w: *std.Io.Writer, img: Image) !void {
    try w.writeByte('P');
    try w.writeByte(img.kind);
    switch (img.kind) {
        '7' => return pamHeader(random, w, img),
        'F', 'f' => {
            try separator(random, w, false);
            try w.print("{d}", .{img.width});
            try separator(random, w, false);
            try w.print("{d}", .{img.height});
            try separator(random, w, false);
            const scales = [_][]const u8{ "-1.0", "1.0", "-1", "0.5", "-2.5e1", "1e-3", "0", "-0.0", "1.0.0", "x" };
            const most: usize = if (chance(random, 8)) scales.len else 6;
            try w.writeAll(scales[random.uintLessThan(usize, most)]);
            try w.writeByte(if (chance(random, 16)) 'x' else '\n');
        },
        else => {
            try separator(random, w, true);
            try w.print("{d}", .{img.width});
            try separator(random, w, true);
            try w.print("{d}", .{img.height});
            if (img.kind != '1' and img.kind != '4') {
                try separator(random, w, true);
                try w.print("{d}", .{img.maxval});
            }
            if (chance(random, 8)) try w.writeAll("#c");
            try w.writeByte(if (chance(random, 32)) 'x' else spaces[random.uintLessThan(usize, spaces.len)]);
        },
    }
}

fn pamHeader(random: std.Random, w: *std.Io.Writer, img: Image) !void {
    try w.writeByte(if (chance(random, 32)) ' ' else '\n');
    const tuples = [_][]const u8{
        "GRAYSCALE", "BLACKANDWHITE", "RGB", "GRAYSCALE_ALPHA", "BLACKANDWHITE_ALPHA", "RGB_ALPHA", "CMYK", "",
    };
    var lines = [_]u8{ 0, 1, 2, 3, 4 };
    if (chance(random, 2)) random.shuffle(u8, &lines);
    for (lines) |line| {
        if (chance(random, 8)) try w.writeAll(if (chance(random, 2)) "# comment\n" else "\n");
        if (chance(random, 8)) try w.writeAll(" \t");
        switch (line) {
            0 => try w.print("WIDTH {d}\n", .{img.width}),
            1 => try w.print("HEIGHT {d}\n", .{img.height}),
            2 => try w.print("DEPTH {d}\n", .{img.depth}),
            3 => try w.print("MAXVAL {d}\n", .{img.maxval}),
            else => {
                const t = tuples[random.uintLessThan(usize, tuples.len)];
                if (t.len > 0) try w.print("TUPLTYPE {s}{s}\n", .{ t, if (chance(random, 8)) " " else "" });
            },
        }
        if (chance(random, 64)) try w.writeAll("DEPTH 2\n");
    }
    try w.writeAll(if (chance(random, 32)) "ENDHDR x\n" else "ENDHDR\n");
}

fn raster(random: std.Random, w: *std.Io.Writer, img: Image) !void {
    const pixels = @as(usize, img.width) * img.height;
    // Samples within maxval, mostly.
    const top: u32 = @max(1, @min(img.maxval, 65535));
    switch (img.kind) {
        '1' => for (0..pixels) |_| {
            try w.writeByte(if (random.boolean()) '1' else '0');
            if (chance(random, 3)) try separator(random, w, true);
        },
        '2', '3' => for (0..pixels * (if (img.kind == '3') @as(usize, 3) else 1)) |_| {
            const v = if (chance(random, 64)) top + 1 else random.uintAtMost(u32, top);
            try w.print("{d}", .{v});
            try separator(random, w, true);
        },
        '4' => for (0..(img.width + 7) / 8 * img.height) |_| try w.writeByte(random.int(u8)),
        'F', 'f' => for (0..pixels * (if (img.kind == 'F') @as(usize, 3) else 1)) |_| {
            const v: f32 = if (chance(random, 16)) @bitCast(random.int(u32)) else random.float(f32);
            try w.writeAll(&std.mem.toBytes(v));
        },
        else => {
            const channels: usize = switch (img.kind) {
                '5' => 1,
                '6' => 3,
                else => img.depth,
            };
            for (0..pixels * channels) |_| {
                const v = if (chance(random, 128)) random.int(u16) else random.uintAtMost(u32, top);
                if (top > 255) try w.writeByte(@intCast(v >> 8 & 0xff));
                try w.writeByte(@truncate(v));
            }
        },
    }
}

/// Hand-written seeds for the coverage-guided fuzzer, which has no corpus
/// on disk.
pub const seeds = [_][]const u8{
    "P4\n3 2\n\xa0\x40",
    "P1 3 2 101 #c\n010",
    "P5 2 1 255\n\x00\xfe" ++ "P5 2 1 7\n\x01\x07",
    "P2 2 1 1000\n0 999",
    "P6 1 1 65535\n\x00\x80\x01\x00\xff\xff",
    "P3 1 1 15 1 2 3",
    "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n\x01\x02\x03\x04\x05\x06\x07\x08",
    "P7\n# c\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 300\nTUPLTYPE GRAYSCALE\nENDHDR\n\x00\x01\x00\x02\x00\x03",
    "PF\n1 1\n-1.0\n\x00\x00\x00\x3f\x00\x00\x80\x3e\x00\x00\x00\x40",
    "Pf 2 1 1\n\x3f\x00\x00\x00\xc0\x00\x00\x00",
};

test "netpbm on the coverage-guided fuzzer" {
    try harness.zigFuzz(@This());
}
