const std = @import("std");
const zimp = @import("zimp");

pub const addProjectCookStep = zimp.addProjectCookStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlm_dep = b.dependency("zlm", .{
        .target = target,
        .optimize = optimize,
    });

    const zimp_dep = b.dependency("zimp", .{
        .target = target,
        .optimize = optimize,
    });
    b.modules.put(b.graph.arena, b.dupe("zimp"), zimp_dep.module("zimp")) catch @panic("OOM");

    const zob_dep = b.dependency("zob", .{
        .target = target,
        .optimize = optimize,
    });

    const zcs_dep = b.dependency("zcs", .{
        .target = target,
        .optimize = optimize,
    });

    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const glad_dep = b.dependency("zig_glad", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("fusion_runtime", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const deps: Deps = .{
        .glfw = glfw_dep.artifact("glfw"),
        .glad = glad_dep.artifact("glad"),
        .zlm = zlm_dep.module("zlm"),
        .zimp = zimp_dep.module("zimp"),
        .zob = zob_dep.module("zob"),
        .zcs = zcs_dep.module("zcs"),
    };

    deps.wire(mod);

    const check = b.step("check", "Check if library compiles");
    const lib_check = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    deps.wire(lib_check);

    const check_compile = b.addObject(.{
        .name = "fusion_runtime_check",
        .root_module = lib_check,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    deps.wire(lib_unit_tests.root_module);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    check.dependOn(&check_compile.step);
}

const Deps = struct {
    glfw: *std.Build.Step.Compile,
    glad: *std.Build.Step.Compile,
    zlm: *std.Build.Module,
    zimp: *std.Build.Module,
    zob: *std.Build.Module,
    zcs: *std.Build.Module,

    fn wire(deps: Deps, mod: *std.Build.Module) void {
        mod.linkLibrary(deps.glfw);
        mod.linkLibrary(deps.glad);
        mod.addImport("zlm", deps.zlm);
        mod.addImport("zimp", deps.zimp);
        mod.addImport("zob", deps.zob);
        mod.addImport("zcs", deps.zcs);
    }
};
