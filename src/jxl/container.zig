//! The JPEG XL container (ISO/IEC 18181-2): an ISO BMFF box sequence
//! around the codestream. `Source` hands the codestream's bytes to the bit
//! reader, whether the file is a bare codestream or a container whose
//! codestream is one `jxlc` box or split across `jxlp` boxes, and passes
//! the metadata boxes it meets on the way (`Exif`, `xml `, and either
//! inside `brob`) to the caller's blob sink.
//!
//! Strict where the specification is: the signature box comes first and
//! `ftyp` (brand `jxl `) second, `jxlp` indices count up from 0 and the last
//! one carries the high bit, and `jxlc` and `jxlp` do not mix. Boxes this
//! decoder does not use (`jxll`, `jxli`, `jumb`, unknown types) are skipped.
//! `jbrd`, the JPEG reconstruction data, is noted and skipped until JPEG
//! reconstruction lands (docs/slop/jxl.md).

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const decode = @import("../decode.zig");

pub const Error = error{
    ReadFailed,
    Truncated,
    BadSignature,
    /// A container box breaks ISO/IEC 18181-2: a size smaller than its
    /// header, a missing or misplaced `ftyp`, out-of-order `jxlp` indices,
    /// `jxlc` beside `jxlp`, or no codestream box at all.
    BadBox,
};

const signature_box = "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a";

/// The codestream's bytes, through the container if there is one.
pub const Source = struct {
    r: *Io.Reader,
    sink: ?decode.BlobSink,
    /// Bytes consumed from `r`, for blob offsets.
    pos: u64 = 0,
    state: State = .start,
    /// Codestream bytes left in the current box; `unbounded` for a bare
    /// codestream or a box that runs to the end of the file.
    left: u64 = 0,
    /// The next `jxlp` index, and whether the last part has been seen.
    next_part: u32 = 0,
    last_part: bool = false,
    saw_jxlc: bool = false,
    /// Whether a `jbrd` box (JPEG reconstruction data) was seen.
    saw_jbrd: bool = false,
    /// The metadata boxes seen so far, for `Config.metadata`.
    exif: ?decode.Blob = null,
    xmp: ?decode.Blob = null,

    pub const unbounded = std.math.maxInt(u64);

    const State = enum {
        start,
        /// A bare codestream: every byte of `r` is codestream.
        bare,
        /// Inside a container, between or in codestream boxes.
        boxes,
        /// The codestream has ended.
        done,
    };

    pub fn init(r: *Io.Reader, sink: ?decode.BlobSink) Source {
        return .{ .r = r, .sink = sink };
    }

    /// Whether the input is a container (known once `more` has run).
    pub fn isContainer(s: *const Source) bool {
        return s.state == .boxes or (s.state == .done and s.next_part + @intFromBool(s.saw_jxlc) > 0);
    }

    /// The next codestream bytes available without blocking on more than
    /// one read: at least one byte, or none at the end of the codestream.
    pub fn more(s: *Source) Error![]const u8 {
        while (true) {
            switch (s.state) {
                .start => try s.begin(),
                .done => return &.{},
                .bare, .boxes => {
                    if (s.left == 0) {
                        if (s.state == .bare or !try s.nextCodestreamBox()) {
                            s.state = .done;
                            return &.{};
                        }
                        continue;
                    }
                    const buf = s.r.peekGreedy(1) catch |e| switch (e) {
                        error.EndOfStream => {
                            if (s.left != unbounded) return error.Truncated;
                            s.left = 0;
                            s.state = .done;
                            return &.{};
                        },
                        error.ReadFailed => return error.ReadFailed,
                    };
                    return buf[0..@intCast(@min(buf.len, s.left))];
                },
            }
        }
    }

    /// Consumes `n` bytes of what `more` returned.
    pub fn toss(s: *Source, n: usize) void {
        s.adv(n);
        if (s.left != unbounded) s.left -= n;
    }

    /// Consumes `n` container bytes.
    fn adv(s: *Source, n: usize) void {
        s.r.toss(n);
        s.pos += n;
    }

    /// Skips `n` codestream bytes.
    pub fn discard(s: *Source, n_in: u64) Error!void {
        var n = n_in;
        while (n > 0) {
            const buf = try s.more();
            if (buf.len == 0) return error.Truncated;
            const k: usize = @intCast(@min(buf.len, n));
            s.toss(k);
            n -= k;
        }
    }

    fn begin(s: *Source) Error!void {
        const head = s.r.peek(2) catch |e| return mapRead(e);
        if (head[0] == 0xff and head[1] == 0x0a) {
            s.state = .bare;
            s.left = unbounded;
            return;
        }
        const sig = s.r.peek(signature_box.len) catch |e| switch (e) {
            error.EndOfStream => return error.BadSignature,
            error.ReadFailed => return error.ReadFailed,
        };
        if (!std.mem.eql(u8, sig, signature_box)) return error.BadSignature;
        s.adv(signature_box.len);
        // ftyp must come next, with the major brand "jxl ".
        const box = try s.boxHeader() orelse return error.Truncated;
        if (!std.mem.eql(u8, &box.kind, "ftyp") or box.len < 8 or box.len == unbounded) return error.BadBox;
        const brand = s.r.peek(8) catch |e| return mapRead(e);
        if (!std.mem.eql(u8, brand[0..4], "jxl ")) return error.BadBox;
        try s.skip(box.len);
        s.state = .boxes;
        s.left = 0;
    }

    const Box = struct {
        kind: [4]u8,
        /// The payload's length, or `unbounded` to the end of the file.
        len: u64,
    };

    /// Reads a box header, or returns null at the end of the input.
    fn boxHeader(s: *Source) Error!?Box {
        const head = s.r.peek(8) catch |e| switch (e) {
            error.EndOfStream => {
                if (s.r.bufferedLen() == 0) return null;
                return error.Truncated;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        const size = std.mem.readInt(u32, head[0..4], .big);
        const kind = head[4..8].*;
        s.adv(8);
        if (size == 0) return .{ .kind = kind, .len = unbounded };
        if (size == 1) {
            const big = s.r.takeArray(8) catch |e| return mapRead(e);
            s.pos += 8;
            const n = std.mem.readInt(u64, big, .big);
            if (n < 16) return error.BadBox;
            return .{ .kind = kind, .len = n - 16 };
        }
        if (size < 8) return error.BadBox;
        return .{ .kind = kind, .len = size - 8 };
    }

    fn skip(s: *Source, len: u64) Error!void {
        if (len == unbounded) {
            const n = s.r.discardRemaining() catch return error.ReadFailed;
            s.pos += n;
            return;
        }
        s.r.discardAll64(len) catch |e| return mapRead(e);
        s.pos += len;
    }

    /// Reads boxes up to the next codestream box and starts it; false when
    /// the codestream has ended and no box follows.
    fn nextCodestreamBox(s: *Source) Error!bool {
        while (true) {
            if (s.last_part) return false;
            const box = try s.boxHeader() orelse {
                if (s.next_part == 0 and !s.saw_jxlc) return error.BadBox;
                // jxlp parts without the last flag: the codestream ends early.
                return error.Truncated;
            };
            if (std.mem.eql(u8, &box.kind, "jxlc")) {
                if (s.saw_jxlc or s.next_part != 0) return error.BadBox;
                s.saw_jxlc = true;
                s.last_part = true;
                s.left = box.len;
                if (box.len != 0) return true;
                continue;
            }
            if (std.mem.eql(u8, &box.kind, "jxlp")) {
                if (s.saw_jxlc or box.len < 4) return error.BadBox;
                const idx = std.mem.readInt(u32, s.r.takeArray(4) catch |e| return mapRead(e), .big);
                s.pos += 4;
                if (idx & 0x7fff_ffff != s.next_part) return error.BadBox;
                s.next_part +%= 1;
                s.last_part = idx >> 31 == 1;
                s.left = if (box.len == unbounded) unbounded else box.len - 4;
                if (s.left != 0) return true;
                continue;
            }
            try s.metadataBox(box);
        }
    }

    /// Passes a metadata box to the blob sink, or skips it.
    fn metadataBox(s: *Source, box: Box) Error!void {
        if (std.mem.eql(u8, &box.kind, "ftyp") or std.mem.eql(u8, &box.kind, "JXL ")) return error.BadBox;
        if (std.mem.eql(u8, &box.kind, "jbrd")) s.saw_jbrd = true;
        var kind: ?decode.Blob.Kind = null;
        var encoding: decode.Blob.Encoding = .raw;
        var len = box.len;
        if (std.mem.eql(u8, &box.kind, "Exif")) {
            kind = .exif;
        } else if (std.mem.eql(u8, &box.kind, "xml ")) {
            kind = .xmp;
        } else if (std.mem.eql(u8, &box.kind, "brob") and len >= 4 and len != unbounded) {
            const inner = s.r.takeArray(4) catch |e| return mapRead(e);
            s.pos += 4;
            len -= 4;
            encoding = .brotli;
            if (std.mem.eql(u8, inner, "Exif")) kind = .exif;
            if (std.mem.eql(u8, inner, "xml ")) kind = .xmp;
        }
        const k = kind orelse return s.skip(len);
        if (len == unbounded) return s.skip(len);
        // An Exif box starts with the offset of the TIFF header; the blob is
        // the bytes after that field, as other formats report EXIF.
        if (k == .exif and encoding == .raw) {
            if (len < 4) return s.skip(len);
            s.r.discardAll(4) catch |e| return mapRead(e);
            s.pos += 4;
            len -= 4;
        }
        const blob: decode.Blob = .{ .kind = k, .offset = s.pos, .len = len, .encoding = encoding };
        switch (k) {
            .exif => if (s.exif == null) {
                s.exif = blob;
            },
            .xmp => if (s.xmp == null) {
                s.xmp = blob;
            },
            .icc => {},
        }
        var at: u64 = 0;
        while (at < len) {
            const buf = s.r.peekGreedy(1) catch |e| return mapRead(e);
            const n: usize = @intCast(@min(buf.len, len - at));
            if (s.sink) |sink| sink.put(blob, at, buf[0..n]);
            s.adv(n);
            at += n;
        }
    }

    /// After the codestream: reads the boxes that follow, passing metadata
    /// to the sink, to the end of the input.
    pub fn finish(s: *Source) Error!void {
        if (!s.isContainer()) return;
        while (try s.boxHeader()) |box| {
            if (std.mem.eql(u8, &box.kind, "jxlc") or std.mem.eql(u8, &box.kind, "jxlp")) return error.BadBox;
            try s.metadataBox(box);
        }
    }
};

fn mapRead(e: Io.Reader.Error) Error {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.ReadFailed,
    };
}

fn readAll(s: *Source, out: []u8) Error![]u8 {
    var n: usize = 0;
    while (true) {
        const b = try s.more();
        if (b.len == 0) return out[0..n];
        const k = @min(b.len, out.len - n);
        @memcpy(out[n..][0..k], b[0..k]);
        s.toss(k);
        n += k;
    }
}

fn testBox(comptime kind: []const u8, comptime body: []const u8) []const u8 {
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, body.len + 8, .big);
    return size ++ kind ++ body;
}

test "bare codestream" {
    var r: Io.Reader = .fixed("\xff\x0a\x01\x02");
    var s: Source = .init(&r, null);
    var out: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, "\xff\x0a\x01\x02", try readAll(&s, &out));
}

test "container parts and metadata" {
    const Sink = struct {
        const Self = @This();
        exif: [16]u8 = undefined,
        len: usize = 0,
        fn write(ctx: *anyopaque, blob: decode.Blob, at: u64, bytes: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (blob.kind != .exif) return;
            @memcpy(self.exif[@intCast(at)..][0..bytes.len], bytes);
            self.len = @intCast(at + bytes.len);
        }
    };
    const file = comptime signature_box ++ testBox("ftyp", "jxl \x00\x00\x00\x00jxl ") ++
        testBox("jxlp", "\x00\x00\x00\x00\xff\x0a") ++ testBox("Exif", "\x00\x00\x00\x00MM\x00*") ++
        testBox("jxlp", "\x80\x00\x00\x01\x05\x06");
    var r: Io.Reader = .fixed(file);
    var sink: Sink = .{};
    var s: Source = .init(&r, .{ .context = &sink, .write = Sink.write });
    var out: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, "\xff\x0a\x05\x06", try readAll(&s, &out));
    try testing.expectEqualSlices(u8, "MM\x00*", sink.exif[0..sink.len]);
    try testing.expect(s.isContainer());

    // Out-of-order parts.
    const bad = comptime signature_box ++ testBox("ftyp", "jxl \x00\x00\x00\x00jxl ") ++
        testBox("jxlp", "\x00\x00\x00\x01\xff\x0a");
    r = .fixed(bad);
    s = .init(&r, null);
    try testing.expectError(error.BadBox, readAll(&s, &out));
    // No ftyp.
    r = .fixed(comptime signature_box ++ testBox("jxlc", "\xff\x0a"));
    s = .init(&r, null);
    try testing.expectError(error.BadBox, readAll(&s, &out));
    // A jxlc box.
    r = .fixed(comptime signature_box ++ testBox("ftyp", "jxl \x00\x00\x00\x00jxl ") ++
        testBox("jxlc", "\xff\x0a\x07"));
    s = .init(&r, null);
    try testing.expectEqualSlices(u8, "\xff\x0a\x07", try readAll(&s, &out));
}
