const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpng = b.addModule("zpng", .{
        .root_source_file = .{ .path = "src/zpng.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "test/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("zpng", zpng);
    b.default_step.dependOn(&tests.step);
    b.step("test", "Run library tests").dependOn(&b.addRunArtifact(tests).step);

    fuzzing(b, target, optimize, zpng);
}

fn fuzzing(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpng: *std.Build.Module,
) void {
    const lib = b.addStaticLibrary(.{
        .name = "zpng_fuzz",
        .root_source_file = .{ .path = "fuzz/fuzz.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.want_lto = true;
    lib.bundle_compiler_rt = true;
    lib.root_module.addImport("zpng", zpng);
    lib.linkLibC();

    const bare_bin = b.addExecutable(.{
        .name = "zpng_fuzz",
        .target = target,
        .optimize = optimize,
    });
    bare_bin.linkLibrary(lib);
    const run_bare = b.addRunArtifact(bare_bin);
    b.step("fuzz-bin", "Run un-instrumented fuzzing binary").dependOn(&run_bare.step);

    const build_cmd = b.addSystemCommand(&.{ "afl-clang-lto", "-o" });
    const fuzz_target = build_cmd.addOutputFileArg("fuzz");
    build_cmd.addFileArg(lib.getEmittedBin());

    const dedup = b.addSystemCommand(&.{ "afl-cmin", "-i", "fuzz/corpus", "-o", "fuzz/corpus_unique", "--" });
    dedup.addFileArg(fuzz_target);

    const fuzz_continue = b.option(bool, "fuzz_continue", "Continue fuzzing from saved state") orelse false;
    const fuzz = b.addSystemCommand(&.{"afl-fuzz"});
    fuzz.addArgs(&.{ "-i", if (fuzz_continue) "-" else "fuzz/corpus_unique" });
    fuzz.addArgs(&.{ "-o", "fuzz/out" });
    fuzz.addArgs(&.{
        // Use a dictionary
        "-x", "fuzz/png.dict",
        // 100MB memory limit
        "-m", "100",
        "--",
    });
    fuzz.addFileArg(fuzz_target);
    fuzz.step.dependOn(&dedup.step);
    b.step("fuzz", "Run fuzz tests").dependOn(&fuzz.step);
}
