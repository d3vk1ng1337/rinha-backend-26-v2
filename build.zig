const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_path = b.path("src/api_lib.zig");

    const api_module = b.createModule(.{
        .root_source_file = b.path("cmd/api/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    api_module.addAnonymousImport("lib", .{
        .root_source_file = lib_path,
        .target = target,
        .optimize = optimize,
    });
    const api = b.addExecutable(.{
        .name = "api",
        .root_module = api_module,
    });
    b.installArtifact(api);

    const builder_module = b.createModule(.{
        .root_source_file = b.path("cmd/builder/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    builder_module.addAnonymousImport("lib", .{
        .root_source_file = lib_path,
        .target = target,
        .optimize = optimize,
    });
    const builder = b.addExecutable(.{
        .name = "builder",
        .root_module = builder_module,
    });
    b.installArtifact(builder);

    const lb_module = b.createModule(.{
        .root_source_file = b.path("cmd/lb/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lb_module.addAnonymousImport("fdpass", .{
        .root_source_file = b.path("src/fdpass.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lb = b.addExecutable(.{
        .name = "lb",
        .root_module = lb_module,
    });
    b.installArtifact(lb);

    const check_module = b.createModule(.{
        .root_source_file = b.path("cmd/check/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_module.addAnonymousImport("lib", .{
        .root_source_file = lib_path,
        .target = target,
        .optimize = optimize,
    });
    const check = b.addExecutable(.{
        .name = "check",
        .root_module = check_module,
    });
    b.installArtifact(check);

    const eval_module = b.createModule(.{
        .root_source_file = b.path("cmd/eval/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    eval_module.addAnonymousImport("lib", .{
        .root_source_file = lib_path,
        .target = target,
        .optimize = optimize,
    });
    const eval = b.addExecutable(.{
        .name = "eval",
        .root_module = eval_module,
    });
    b.installArtifact(eval);

    const eval_block_module = b.createModule(.{
        .root_source_file = b.path("cmd/eval_block/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    eval_block_module.addAnonymousImport("lib", .{
        .root_source_file = lib_path,
        .target = target,
        .optimize = optimize,
    });
    const eval_block = b.addExecutable(.{
        .name = "eval_block",
        .root_module = eval_block_module,
    });
    b.installArtifact(eval_block);

    const dump_module = b.createModule(.{
        .root_source_file = b.path("cmd/dump_worst_dist/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dump_module.addAnonymousImport("lib", .{
        .root_source_file = lib_path,
        .target = target,
        .optimize = optimize,
    });
    const dump_worst_dist = b.addExecutable(.{
        .name = "dump_worst_dist",
        .root_module = dump_module,
    });
    b.installArtifact(dump_worst_dist);

    const run_dump = b.addRunArtifact(dump_worst_dist);
    if (b.args) |args| run_dump.addArgs(args);
    b.step("run-dump-worst-dist", "Dump fast-tier worst_dist per query").dependOn(&run_dump.step);

    const run_api = b.addRunArtifact(api);
    if (b.args) |args| run_api.addArgs(args);
    b.step("run-api", "Run the API binary").dependOn(&run_api.step);

    const run_builder = b.addRunArtifact(builder);
    if (b.args) |args| run_builder.addArgs(args);
    b.step("run-builder", "Run the builder binary").dependOn(&run_builder.step);

    const run_lb = b.addRunArtifact(lb);
    if (b.args) |args| run_lb.addArgs(args);
    b.step("run-lb", "Run the LB binary").dependOn(&run_lb.step);

    const run_check = b.addRunArtifact(check);
    if (b.args) |args| run_check.addArgs(args);
    b.step("run-check", "Run the ground-truth check binary").dependOn(&run_check.step);

    const run_eval = b.addRunArtifact(eval);
    if (b.args) |args| run_eval.addArgs(args);
    b.step("run-eval", "Run official test-data quality eval").dependOn(&run_eval.step);

    const run_eval_block = b.addRunArtifact(eval_block);
    if (b.args) |args| run_eval_block.addArgs(args);
    b.step("run-eval-block", "Run block-layout q16 quality eval").dependOn(&run_eval_block.step);

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/vec.zig",
        "src/mcc.zig",
        "src/json_io.zig",
        "src/http_io.zig",
        "src/index_format.zig",
        "src/search.zig",
        "src/time_parse.zig",
        "src/quant.zig",
        "src/kmeans.zig",
        "src/fast_parser.zig",
        "src/block_index.zig",
    };
    for (test_files) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    const api_test_module = b.createModule(.{
        .root_source_file = b.path("cmd/api/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    api_test_module.addAnonymousImport("lib", .{
        .root_source_file = lib_path,
        .target = target,
        .optimize = optimize,
    });
    const api_test = b.addTest(.{
        .root_module = api_test_module,
    });
    const run_api_test = b.addRunArtifact(api_test);
    test_step.dependOn(&run_api_test.step);

    const lb_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/lb/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_lb_test = b.addRunArtifact(lb_test);
    test_step.dependOn(&run_lb_test.step);
}
