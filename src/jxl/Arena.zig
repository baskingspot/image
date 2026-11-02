//! A bump allocator over the caller's work memory: the decoder's only
//! source of memory. `mark` and `release` free everything allocated after
//! a point, so per-group state reuses the same bytes.

const std = @import("std");
const testing = std.testing;

const Arena = @This();

pub const Error = error{
    /// The file needs more work memory than its header's bound reserves
    /// (docs/slop/jxl.md, work memory).
    TooComplex,
};

buf: []u8,
used: usize = 0,
/// The most ever used, for measuring the bound.
peak: usize = 0,

pub fn init(buf: []u8) Arena {
    return .{ .buf = buf };
}

pub fn alloc(a: *Arena, comptime T: type, n: usize) Error![]T {
    // Aligned in memory: the caller's buffer may start anywhere.
    const base = @intFromPtr(a.buf.ptr);
    const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.TooComplex;
    // Arrays of a page or more start on a cache line, so vector loads of
    // their rows do not straddle two.
    const al: usize = if (bytes >= 4096) @max(64, @alignOf(T)) else @alignOf(T);
    const start = std.mem.alignForward(usize, base + a.used, al) - base;
    const end = std.math.add(usize, start, bytes) catch return error.TooComplex;
    if (end > a.buf.len) return error.TooComplex;
    a.used = end;
    a.peak = @max(a.peak, end);
    const p: [*]T = @ptrCast(@alignCast(a.buf.ptr + start));
    return p[0..n];
}

pub fn create(a: *Arena, comptime T: type) Error!*T {
    return &(try a.alloc(T, 1))[0];
}

pub fn mark(a: *const Arena) usize {
    return a.used;
}

pub fn release(a: *Arena, m: usize) void {
    std.debug.assert(m <= a.used);
    a.used = m;
}

test Arena {
    var mem: [64]u8 align(8) = undefined;
    var a: Arena = .init(&mem);
    const x = try a.alloc(u8, 3);
    const y = try a.alloc(u32, 2);
    try testing.expectEqual(@as(usize, 3), x.len);
    try testing.expect(@intFromPtr(y.ptr) % 4 == 0);
    const m = a.mark();
    _ = try a.alloc(u8, 40);
    try testing.expectError(error.TooComplex, a.alloc(u8, 40));
    a.release(m);
    _ = try a.alloc(u8, 40);
    // A page or more starts on a cache line, wherever the buffer does.
    var big: [8192]u8 align(64) = undefined;
    var b: Arena = .init(big[4..]);
    _ = try b.alloc(u8, 1);
    try testing.expect(@intFromPtr((try b.alloc(f32, 1024)).ptr) % 64 == 0);
}
