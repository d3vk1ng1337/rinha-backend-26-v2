const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const api = b.addExecutable(.{
        .name = "api",
        .root_source_file = b.path("cmd/api/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    api.linkLibC();
    b.installArtifact(api);

    const builder = b.addExecutable(.{
        .name = "builder",
        .root_source_file = b.path("cmd/builder/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    builder.linkLibC();
    b.installArtifact(builder);

    const run_api = b.addRunArtifact(api);
    if (b.args) |args| run_api.addArgs(args);
    b.step("run-api", "Run the API binary").dependOn(&run_api.step);

    const run_builder = b.addRunArtifact(builder);
    if (b.args) |args| run_builder.addArgs(args);
    b.step("run-builder", "Run the builder binary").dependOn(&run_builder.step);

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/vec.zig",
        "src/mcc.zig",
        "src/json_io.zig",
        "src/http_io.zig",
        "src/index_format.zig",
        "src/search.zig",
        "src/time_parse.zig",
    };
    for (test_files) |file| {
        const t = b.addTest(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        });
        t.linkLibC();
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
