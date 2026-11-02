//! A bump allocator over the encoder's work memory. `encode.zig`'s `Sizes`
//! states each part's bound; `Bump.alloc` checks every allocation against
//! what is left.

const std = @import("std");

/// Allocates from `buf`, aligning each slice by address.
pub const Bump = struct {
    buf: []u8,
    used: usize = 0,

    pub fn init(buf: []u8) Bump {
        return .{ .buf = buf };
    }

    pub fn alloc(b: *Bump, comptime T: type, n: usize) error{WorkTooSmall}![]T {
        const base = @intFromPtr(b.buf.ptr);
        const at = std.mem.alignForward(usize, base + b.used, @alignOf(T)) - base;
        const size = std.math.mul(usize, n, @sizeOf(T)) catch return error.WorkTooSmall;
        if (at > b.buf.len or size > b.buf.len - at) return error.WorkTooSmall;
        b.used = at + size;
        const p: [*]T = @ptrCast(@alignCast(b.buf.ptr + at));
        return p[0..n];
    }

    pub fn mark(b: *const Bump) usize {
        return b.used;
    }

    pub fn release(b: *Bump, m: usize) void {
        b.used = m;
    }
};
