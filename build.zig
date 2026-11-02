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
    const compress = b.dependency("compress", .{ .target = target, .optimize = optimize }).module("compress");
    mod.addImport("compress", compress);

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
    const test_step = b.step("test", "Run the unit tests and each fuzz target once over its seeds");
    test_step.dependOn(&run_mod_tests.step);
    b.step("test-unit", "Run the unit tests alone").dependOn(&run_mod_tests.step);

    // The fuzz targets import `image`, and `compress` to build inputs (zlib
    // streams for PNG, say).
    const fuzz_imports: []const std.Build.Module.Import = &.{
        .{ .name = "image", .module = mod },
        .{ .name = "compress", .module = compress },
    };

    // The fuzz targets on Zig's coverage-guided fuzzer
    // (test/fuzz/zig_fuzz.zig). It needs the default test runner, which
    // speaks the build system's fuzzing protocol. Without --fuzz it runs
    // each target once over its seeds, as part of `test`.
    const zig_fuzz = b.addTest(.{
        .name = "fuzz-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz/zig_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = fuzz_imports,
        }),
    });
    const run_zig_fuzz = b.addRunArtifact(zig_fuzz);
    test_step.dependOn(&run_zig_fuzz.step);
    b.step("fuzz-zig", "Run the fuzz targets on Zig's fuzzer (with --fuzz)").dependOn(&run_zig_fuzz.step);

    // The fuzz driver `just fuzz` runs (test/fuzz/main.zig).
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = fuzz_imports,
        }),
    });
    b.step("fuzz", "Build the fuzz driver").dependOn(&b.addInstallArtifact(fuzz, .{}).step);

    // The differential harness `just oracle` runs (test/oracle/compare.zig)
    // against the C oracle the justfile builds. It takes its corpora and
    // fuzzed inputs from the fuzz targets.
    const fuzz_targets = b.createModule(.{
        .root_source_file = b.path("test/fuzz/targets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = fuzz_imports,
    });
    const compare = b.addExecutable(.{
        .name = "oracle-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/oracle/compare.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "image", .module = mod },
                .{ .name = "fuzz", .module = fuzz_targets },
            },
        }),
    });
    b.step("oracle", "Build the oracle comparison").dependOn(&b.addInstallArtifact(compare, .{}).step);
    // Its own tests (the tolerance comparison) need no oracle.
    const compare_tests = b.addTest(.{
        .name = "oracle-compare",
        .root_module = compare.root_module,
        .test_runner = runner,
    });
    test_step.dependOn(&b.addRunArtifact(compare_tests).step);

    // The benchmark's Zig arm, bench-image: bench/zig's operations under
    // the C arms' harness (bench/c/arm.c). Built with -Dbench-optimize,
    // ReleaseFast unless set, whatever -Doptimize says.
    const bench_optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "The Zig arm's mode") orelse
        .ReleaseFast;
    const bench_image = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{.{ .name = "compress", .module = compress }},
    });
    const bench_ops = b.addObject(.{
        .name = "bench-image-ops",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/zig/root.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{.{ .name = "image", .module = bench_image }},
        }),
    });
    const bench = b.addExecutable(.{
        .name = "bench-image",
        .root_module = b.createModule(.{ .target = target, .optimize = bench_optimize, .link_libc = true }),
    });
    bench.root_module.addCSourceFile(.{
        .file = b.path("bench/c/arm.c"),
        .flags = &.{ "-std=gnu11", "-O2", "-DBENCH_EXTERNAL_INIT" },
    });
    bench.root_module.addObject(bench_ops);
    b.step("bench", "Build the benchmark's Zig arm").dependOn(&b.addInstallArtifact(bench, .{}).step);
}
