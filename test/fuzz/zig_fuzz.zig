//! Every target on Zig's coverage-guided fuzzer: each target file's test
//! calls `harness.zigFuzz`. `zig build fuzz-zig` runs each once over its
//! seeds, as a test; `just fuzz-zig N` fuzzes each for N inputs.

const targets = @import("targets.zig");

test {
    _ = targets.harness;
    inline for (targets.all) |T| _ = T;
}
