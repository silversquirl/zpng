const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpng = b.addModule("zpng", .{
        .root_source_file = .{ .path = "zpng.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "test.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("zpng", zpng);
    b.default_step.dependOn(&tests.step);

    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run library tests").dependOn(&run_tests.step);
}
