//! Image decoders and encoders in Zig with no C. Each format is a namespace;
//! none exists yet. docs/slop/plan.md is the scope and the order of work.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
