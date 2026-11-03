//! A fill for where `@memset` costs time. A `@memset` of a runtime length
//! becomes a call to `memset`, and Zig 0.16 links compiler_rt's, which
//! stores a byte at a time, even into a program that links libc
//! (docs/slop/results/memset-20261103.md).

const std = @import("std");

/// Sets every element of `dst` to `value`, a vector at a time. Keep
/// `@memset` for fills of a few hundred bytes at most: LLVM writes a
/// comptime length that short as stores, and a call costs little there.
pub fn fill(comptime T: type, dst: []T, value: T) void {
    // At most 256 bits: 512-bit stores were slower on WebP's icons from
    // 64x64 up, as kernels here keep to 256 bits.
    const lanes = comptime @min(std.simd.suggestVectorLength(T) orelse 1, 32 / @sizeOf(T));
    if (lanes == 1 or dst.len < lanes) return @memset(dst, value);
    const V = @Vector(lanes, T);
    comptime std.debug.assert(@sizeOf(V) == @sizeOf([lanes]T));
    const v: V = @splat(value);
    var i: usize = 0;
    while (i + lanes <= dst.len) : (i += lanes) store(V, dst[i..][0..lanes], v);
    // The tail, as one store that overlaps the last full one.
    if (i < dst.len) store(V, dst[dst.len - lanes ..][0..lanes], v);
}

/// Stores `v` over `to`, the same size, as one vector. Volatile, or LLVM
/// turns a loop of these back into a call to `memset`; through a vector
/// pointer, since a volatile array store is split into its elements.
inline fn store(comptime V: type, to: *[@typeInfo(V).vector.len]@typeInfo(V).vector.child, v: V) void {
    const p: *align(@alignOf(@typeInfo(V).vector.child)) volatile V = @ptrCast(to);
    p.* = v;
}

test fill {
    // Every length around the vector width and its multiples, at every
    // offset in a vector, leaves the bytes around the slice alone.
    inline for (.{ u8, u16, u32, f32 }) |T| {
        const lanes = @min(std.simd.suggestVectorLength(T) orelse 1, 32 / @sizeOf(T));
        var buf: [4 * lanes + 8]T = undefined;
        const value: T = if (T == f32) 0.5 else 0x5a;
        const guard: T = if (T == f32) -1 else 0x33;
        for (0..lanes) |start| {
            for (0..buf.len - start - 1) |len| {
                @memset(&buf, guard);
                fill(T, buf[start + 1 ..][0..len], value);
                for (buf, 0..) |b, i| {
                    const inside = i > start and i <= start + len;
                    try std.testing.expectEqual(if (inside) value else guard, b);
                }
            }
        }
    }
}
