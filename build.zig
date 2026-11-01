const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("image", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // compress: zlib and DEFLATE for PNG, TIFF, and ICO's PNG entries, and
    // Brotli for JPEG XL's brob boxes. Unused until those formats land; Zig
    // compiles only what is referenced.
    const compress = b.dependency("compress", .{ .target = target, .optimize = optimize });
    mod.addImport("compress", compress.module("compress"));

    if (b.pkg_hash.len != 0) return;

    // Every step below needs testingx, which is lazy so a consumer never
    // fetches it. On the first configure pass it is not fetched yet, and the
    // build runner fetches it and reruns this script.
    const testingx = b.lazyDependency("testingx", .{ .target = target }) orelse return;
    const runner: std.Build.Step.Compile.TestRunner = .{
        .path = testingx.path("src/runner.zig"),
        .mode = .simple,
    };

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    b.step("test", "Run the unit tests").dependOn(&run_mod_tests.step);
}
