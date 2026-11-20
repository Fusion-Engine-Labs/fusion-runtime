const std = @import("std");

pub const addProjectCookStep = @import("fusion_sdk").addProjectCookStep;

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});

    const sdk_dep = b.dependency("fusion_sdk", .{ .target = target, .optimize = optimize });

    // zimp comes from the SDK so the host and games share one pin and one set of types.
    const zimp_mod = sdk_dep.module("zimp");
    b.modules.put(b.graph.arena, b.dupe("zimp"), zimp_mod) catch @panic("OOM");

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

    const headers = b.addWriteFiles();
    const glfw_c: Translator = .init(translate_c, .{
        .name = "glfw",
        .c_source_file = headers.add("glfw.h", "#include <GLFW/glfw3.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    glfw_c.addIncludePath(glfw_dep.path("glfw/include"));
    glfw_c.defineCMacro("GLFW_INCLUDE_NONE", null);

    const glad_c: Translator = .init(translate_c, .{
        .name = "glad",
        .c_source_file = headers.add("glad.h", "#include <glad/glad.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    glad_c.addIncludePath(glad_dep.path("glad/include"));

    const macos_c: ?*std.Build.Module = if (target.result.os.tag == .macos) blk: {
        const objc_c: Translator = .init(translate_c, .{
            .name = "macos_objc",
            .c_source_file = headers.add("macos_objc.h", "#include <objc/message.h>\n#include <objc/runtime.h>\n"),
            .target = target,
            .optimize = optimize,
            .link_system_libs = &.{.{ .name = "objc" }},
        });
        break :blk objc_c.mod;
    } else null;

    const mod = b.addModule("fusion_runtime", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const deps: Deps = .{
        .sdk = sdk_dep.module("fusion_sdk"),
        .glfw = glfw_dep.artifact("glfw"),
        .glad = glad_dep.artifact("glad"),
        .glfw_c = glfw_c.mod,
        .glad_c = glad_c.mod,
        .macos_c = macos_c,
        .zimp = zimp_mod,
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

    // A static library rather than an object: COFF can't merge the linked glfw/glad
    // libraries and zimp's C sources into a single relocatable object on Windows.
    const check_compile = b.addLibrary(.{
        .name = "fusion_runtime_check",
        .linkage = .static,
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

    if (b.option([]const u8, "game-library", "Path to a separately built sandbox-game library")) |path| {
        const options = b.addOptions();
        options.addOption([]const u8, "library_path", b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path, path }));
        const integration = b.createModule(.{
            .root_source_file = b.path("tests/game_library.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "fusion_runtime", .module = mod }, .{ .name = "fusion_sdk", .module = deps.sdk } },
        });
        integration.addOptions("test_options", options);
        const run = b.addRunArtifact(b.addTest(.{ .root_module = integration }));
        b.step("test-game", "Exercise a real game DLL against this host build mode").dependOn(&run.step);
    }

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    check.dependOn(&check_compile.step);
}

const Deps = struct {
    sdk: *std.Build.Module,
    glfw: *std.Build.Step.Compile,
    glad: *std.Build.Step.Compile,
    glfw_c: *std.Build.Module,
    glad_c: *std.Build.Module,
    macos_c: ?*std.Build.Module,
    zimp: *std.Build.Module,
    zob: *std.Build.Module,
    zcs: *std.Build.Module,

    fn wire(deps: Deps, mod: *std.Build.Module) void {
        mod.addImport("fusion_sdk", deps.sdk);
        mod.linkLibrary(deps.glfw);
        mod.linkLibrary(deps.glad);
        mod.addImport("glfw", deps.glfw_c);
        mod.addImport("glad", deps.glad_c);
        if (deps.macos_c) |macos_c| mod.addImport("macos_objc", macos_c);
        mod.addImport("zimp", deps.zimp);
        mod.addImport("zob", deps.zob);
        mod.addImport("zcs", deps.zcs);
    }
};
