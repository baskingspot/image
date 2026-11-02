//! The Zig client for `image-oracle` (test/oracle/oracle.c), which decodes
//! inputs with the reference libraries: hand it a batch of requests and get
//! each library's verdict, and its pixels' length and hash. compare.zig holds this package's
//! decoders against it, and `just oracle` runs that.
//!
//! Each `run` spawns the oracle once, so batch thousands of requests per
//! call.

const Oracle = @This();

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const PixelFormat = @import("image").PixelFormat;

comptime {
    // oracle.h's `enum pixel_format` lists these, in order, and oracle.c's
    // `pixel_bytes` and `known` cover them: add a new format there too.
    std.debug.assert(@intFromEnum(PixelFormat.cmyk16) == 21 and std.enums.values(PixelFormat).len == 22);
}

io: Io,
/// Allocates the batch and the responses, which the caller frees with
/// `free`.
gpa: mem.Allocator,
/// The oracle executable, `zig-out/bin/image-oracle` from the repository
/// root.
path: []const u8,

pub const Status = enum(u8) {
    ok = 0,
    rejected = 1,
    /// The library cannot write the requested pixel format.
    skipped = 2,
    too_large = 3,
    _,
};

/// A request's input length that means the previous request's input.
const same_input = std.math.maxInt(u32);

pub const Request = struct {
    /// An op from a format's table in test/oracle/<format>.c.
    op: []const u8,
    format: PixelFormat,
    max_pixels: u64,
    /// The file to decode, or for an encode op the source's pixels, tightly
    /// packed in `format`.
    input: []const u8,
    /// For an encode op, the source's width and height.
    size: ?[2]u32 = null,
};

pub const Response = struct {
    status: Status,
    width: u32,
    height: u32,
    /// The pixels' length, tightly packed in the requested format, on
    /// success: or an encode op's file's.
    len: u32,
    /// XXH64, seed 0, of those pixels: `std.hash.XxHash64.hash(0, pixels)`.
    hash: u64,
};

pub const RunError = error{ OracleFailed, BadResponse } || mem.Allocator.Error ||
    std.process.SpawnError || Io.File.Writer.Error || Io.Reader.LimitedAllocError || std.process.Child.WaitError;

/// Runs one batch through the oracle and returns a response per request,
/// in order. Free the result with `free`.
pub fn run(oracle: Oracle, requests: []const Request) RunError![]Response {
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(oracle.gpa);
    var last: ?Request = null;
    for (requests) |req| {
        try batch.append(oracle.gpa, @intCast(req.op.len));
        try batch.appendSlice(oracle.gpa, req.op);
        try batch.append(oracle.gpa, @intFromEnum(req.format));
        var nums: [12]u8 = undefined;
        mem.writeInt(u64, nums[0..8], req.max_pixels, .little);
        // The same input as the last request's goes once (oracle.c). An
        // encode op's input is the source's width and height, then its
        // pixels.
        const again = if (last) |l| l.input.ptr == req.input.ptr and l.input.len == req.input.len and
            std.meta.eql(l.size, req.size) else false;
        const len = req.input.len + @as(usize, if (req.size != null) 8 else 0);
        mem.writeInt(u32, nums[8..12], if (again) same_input else @intCast(len), .little);
        try batch.appendSlice(oracle.gpa, &nums);
        if (!again) {
            if (req.size) |size| {
                var dims: [8]u8 = undefined;
                mem.writeInt(u32, dims[0..4], size[0], .little);
                mem.writeInt(u32, dims[4..8], size[1], .little);
                try batch.appendSlice(oracle.gpa, &dims);
            }
            try batch.appendSlice(oracle.gpa, req.input);
        }
        last = req;
    }

    var child = try std.process.spawn(oracle.io, .{
        .argv = &.{oracle.path},
        .stdin = .pipe,
        .stdout = .pipe,
    });
    defer if (child.id != null) child.kill(oracle.io);
    // The oracle reads to EOF before it writes, so the whole batch goes in
    // first.
    try child.stdin.?.writeStreamingAll(oracle.io, batch.items);
    child.stdin.?.close(oracle.io);
    child.stdin = null;
    var buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(oracle.io, &buf);
    const bytes = try reader.interface.allocRemaining(oracle.gpa, .unlimited);
    defer oracle.gpa.free(bytes);
    const term = try child.wait(oracle.io);
    if (term != .exited or term.exited != 0) return error.OracleFailed;

    const size = 21;
    if (bytes.len != requests.len * size) return error.BadResponse;
    const responses = try oracle.gpa.alloc(Response, requests.len);
    for (responses, 0..) |*resp, i| {
        const b = bytes[i * size ..][0..size];
        resp.* = .{
            .status = @enumFromInt(b[0]),
            .width = mem.readInt(u32, b[1..5], .little),
            .height = mem.readInt(u32, b[5..9], .little),
            .len = mem.readInt(u32, b[9..13], .little),
            .hash = mem.readInt(u64, b[13..21], .little),
        };
    }
    return responses;
}

/// Frees what `run` returned.
pub fn free(oracle: Oracle, responses: []Response) void {
    oracle.gpa.free(responses);
}
