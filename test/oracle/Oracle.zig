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
    std.debug.assert(@backingInt(PixelFormat.cmyk16) == 23 and std.enums.values(PixelFormat).len == 24);
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
    /// Return the pixels too, for a comparison within a tolerance.
    pixels: bool = false,
};

/// How far two answers for one input may differ, from a format module's
/// `toleranceFor` (compare.zig): every sample by at most `peak`, and, when
/// `rms` is set, the root mean square of the differences over all the
/// image's samples by at most `rms`. Both are in the compared format's
/// sample units, and for floats in 16-bit steps (a unit is 1/65535); a
/// bound as a fraction of full scale is that fraction times 255, 65535, or
/// 65535 for floats.
pub const Tolerance = struct {
    peak: u16,
    rms: ?f32 = null,
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
    /// The pixels themselves, when the request asked for them and the op
    /// succeeded; freed by `free`.
    pixels: []const u8 = &.{},
};

pub const RunError = error{ OracleFailed, BadResponse } || mem.Allocator.Error ||
    std.process.SpawnError || Io.File.Writer.Error || Io.File.Reader.Error || Io.Reader.LimitedAllocError ||
    std.process.Child.WaitError;

/// Runs one batch through the oracle and returns a response per request,
/// in order. Free the result with `free`.
pub fn run(oracle: Oracle, requests: []const Request) RunError![]Response {
    // The batch streams to the oracle behind its length, so neither side
    // holds a copy that grows by doubling: the oracle allocates it once.
    var count_buf: [256]u8 = undefined;
    var counter: Io.Writer.Discarding = .init(&count_buf);
    writeRequests(&counter.writer, requests) catch unreachable;
    const total = counter.fullCount();

    var child = try std.process.spawn(oracle.io, .{
        .argv = &.{oracle.path},
        .stdin = .pipe,
        .stdout = .pipe,
    });
    defer if (child.id != null) child.kill(oracle.io);
    // The oracle reads to EOF before it writes, so the whole batch goes in
    // first.
    var write_buf: [64 * 1024]u8 = undefined;
    var stdin = child.stdin.?.writerStreaming(oracle.io, &write_buf);
    stdin.interface.writeInt(u64, total, .little) catch return stdin.err.?;
    writeRequests(&stdin.interface, requests) catch return stdin.err.?;
    stdin.interface.flush() catch return stdin.err.?;
    child.stdin.?.close(oracle.io);
    child.stdin = null;
    // Each response is read into its own allocation, so pixels asked for
    // are held once, at their size.
    var buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(oracle.io, &buf);
    const responses = try oracle.gpa.alloc(Response, requests.len);
    var read: usize = 0;
    errdefer {
        for (responses[0..read]) |resp| oracle.gpa.free(resp.pixels);
        oracle.gpa.free(responses);
    }
    for (responses, requests) |*resp, req| {
        const b = reader.interface.takeArray(21) catch return readError(&reader);
        resp.* = .{
            .status = @fromBackingInt(@intCast(b[0])),
            .width = mem.readInt(u32, b[1..5], .little),
            .height = mem.readInt(u32, b[5..9], .little),
            .len = mem.readInt(u32, b[9..13], .little),
            .hash = mem.readInt(u64, b[13..21], .little),
        };
        if (req.pixels and resp.status == .ok) {
            const pixels = try oracle.gpa.alloc(u8, resp.len);
            reader.interface.readSliceAll(pixels) catch {
                oracle.gpa.free(pixels);
                return readError(&reader);
            };
            resp.pixels = pixels;
        }
        read += 1;
    }
    if (reader.interface.takeByte()) |_| return error.BadResponse else |e| switch (e) {
        error.EndOfStream => {},
        error.ReadFailed => return readError(&reader),
    }
    const term = try child.wait(oracle.io);
    if (term != .exited or term.exited != 0) return error.OracleFailed;
    return responses;
}

/// A short response is the oracle failing, or the pipe's error.
fn readError(reader: *Io.File.Reader) RunError {
    return reader.err orelse error.OracleFailed;
}

/// The batch as oracle.c reads it, after its length.
fn writeRequests(w: *Io.Writer, requests: []const Request) Io.Writer.Error!void {
    var last: ?Request = null;
    for (requests) |req| {
        try w.writeByte(@intCast(req.op.len));
        try w.writeAll(req.op);
        // The high bit asks for the pixels.
        try w.writeByte(@backingInt(req.format) | @as(u8, if (req.pixels) 0x80 else 0));
        try w.writeInt(u64, req.max_pixels, .little);
        // The same input as the last request's goes once (oracle.c). An
        // encode op's input is the source's width and height, then its
        // pixels.
        const again = if (last) |l| l.input.ptr == req.input.ptr and l.input.len == req.input.len and
            std.meta.eql(l.size, req.size) else false;
        const len = req.input.len + @as(usize, if (req.size != null) 8 else 0);
        try w.writeInt(u32, if (again) same_input else @intCast(len), .little);
        if (!again) {
            if (req.size) |size| {
                try w.writeInt(u32, size[0], .little);
                try w.writeInt(u32, size[1], .little);
            }
            try w.writeAll(req.input);
        }
        last = req;
    }
}

/// Frees what `run` returned.
pub fn free(oracle: Oracle, responses: []Response) void {
    for (responses) |resp| oracle.gpa.free(resp.pixels);
    oracle.gpa.free(responses);
}
