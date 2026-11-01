//! The Zig client for `image-oracle` (test/oracle/oracle.c), which decodes
//! inputs with the reference libraries: hand it a batch of requests and get
//! each library's verdict and pixels. compare.zig holds this package's
//! decoders against it, and `just oracle` runs that.
//!
//! Each `run` spawns the oracle once, so batch thousands of requests per
//! call.

const Oracle = @This();

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const PixelFormat = @import("image").PixelFormat;

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
    input: []const u8,
};

pub const Response = struct {
    status: Status,
    width: u32,
    height: u32,
    /// Tightly packed in the requested format, on success. It points into
    /// the batch's memory, which `free` releases.
    pixels: []const u8,
};

pub const RunError = error{ OracleFailed, BadResponse } || mem.Allocator.Error ||
    std.process.SpawnError || Io.File.Writer.Error || Io.Reader.LimitedAllocError || std.process.Child.WaitError;

/// Runs one batch through the oracle and returns a response per request,
/// in order. Free the result with `free`.
pub fn run(oracle: Oracle, requests: []const Request) RunError![]Response {
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(oracle.gpa);
    var last: ?[]const u8 = null;
    for (requests) |req| {
        try batch.append(oracle.gpa, @intCast(req.op.len));
        try batch.appendSlice(oracle.gpa, req.op);
        try batch.append(oracle.gpa, @intFromEnum(req.format));
        var nums: [12]u8 = undefined;
        mem.writeInt(u64, nums[0..8], req.max_pixels, .little);
        // The same input as the last request's goes once (oracle.c).
        const again = if (last) |l| l.ptr == req.input.ptr and l.len == req.input.len else false;
        mem.writeInt(u32, nums[8..12], if (again) same_input else @intCast(req.input.len), .little);
        try batch.appendSlice(oracle.gpa, &nums);
        if (!again) try batch.appendSlice(oracle.gpa, req.input);
        last = req.input;
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
    errdefer oracle.gpa.free(bytes);
    const term = try child.wait(oracle.io);
    if (term != .exited or term.exited != 0) return error.OracleFailed;

    // The extra last element remembers the raw bytes for `free`.
    const responses = try oracle.gpa.alloc(Response, requests.len + 1);
    errdefer oracle.gpa.free(responses);
    var at: usize = 0;
    for (responses[0..requests.len]) |*resp| {
        if (bytes.len - at < 13) return error.BadResponse;
        const len = mem.readInt(u32, bytes[at + 9 ..][0..4], .little);
        if (bytes.len - at - 13 < len) return error.BadResponse;
        resp.* = .{
            .status = @enumFromInt(bytes[at]),
            .width = mem.readInt(u32, bytes[at + 1 ..][0..4], .little),
            .height = mem.readInt(u32, bytes[at + 5 ..][0..4], .little),
            .pixels = bytes[at + 13 ..][0..len],
        };
        at += 13 + len;
    }
    if (at != bytes.len) return error.BadResponse;
    responses[requests.len] = .{ .status = .ok, .width = 0, .height = 0, .pixels = bytes };
    return responses[0..requests.len];
}

/// Frees what `run` returned.
pub fn free(oracle: Oracle, responses: []Response) void {
    const all = responses.ptr[0 .. responses.len + 1];
    oracle.gpa.free(all[responses.len].pixels);
    oracle.gpa.free(all);
}
