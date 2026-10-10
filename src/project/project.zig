const std = @import("std");
const zimp = @import("zimp");

const scene = zimp.scene;

const Project = @This();

manifest: zimp.ProjectManifest,
root_dir: std.Io.Dir,
/// Where the asset manager loads cooked assets from: the loose cooked
/// directory (editor and dev) or the project's `asset_pack` (shipping).
asset_source: zimp.runtime.AssetStore.Source = .loose,

pub fn watchAssets(self: *const Project, allocator: std.mem.Allocator, io: std.Io) !*zimp.WatchHandle {
    return zimp.WatchHandle.start(
        allocator,
        io,
        &self.manifest,
        self.root_dir,
        .{},
        .{},
    );
}

pub fn stopWatchingAssets(_: *Project, handle: *zimp.WatchHandle) void {
    handle.stop();
}

pub fn deinit(self: *Project, allocator: std.mem.Allocator, io: std.Io) void {
    self.manifest.deinit(allocator);
    self.root_dir.close(io);
}

pub fn loadScene(self: *const Project, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !zimp.scene.SceneDocument {
    return try zimp.scene.SceneDocument.load(allocator, io, self.root_dir, path, .{
        .expected_project_id = self.manifest.project_id,
    });
}

pub fn saveScene(self: *const Project, allocator: std.mem.Allocator, io: std.Io, path: []const u8, document: *const zimp.scene.SceneDocument) !void {
    try document.write(allocator, io, self.root_dir, path, .{
        .project_id = self.manifest.project_id,
        .format = .json,
    });
}

pub fn loadDefaultScene(self: *const Project, allocator: std.mem.Allocator, io: std.Io) !zimp.scene.SceneDocument {
    const path = self.manifest.default_scene orelse return error.DefaultSceneNotFound;
    return self.loadScene(allocator, io, path);
}

const testing = std.testing;

fn testManifest(default_scene: ?[]const u8) zimp.ProjectManifest {
    return .{
        .name = "Test Project",
        .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
        .default_scene = default_scene,
    };
}

test "loadScene decodes a JSON-encoded scene document from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var document = try scene.SceneDocument.init(
        testing.allocator,
        .parseComptime("11111111-1111-4111-8111-111111111111"),
        .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
        "Test Scene",
    );
    defer document.deinit();

    const bytes = try scene.json_codec.encodeAlloc(testing.allocator, &document);
    defer testing.allocator.free(bytes);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "scene.json", .data = bytes });

    var project = Project{ .manifest = testManifest("scene.json"), .root_dir = tmp.dir };

    var loaded = try project.loadScene(testing.allocator, testing.io, "scene.json");
    defer loaded.deinit();

    try testing.expectEqualStrings("Test Scene", loaded.name);
    try testing.expect(loaded.scene_id.eql(.parseComptime("11111111-1111-4111-8111-111111111111")));
}

test "loadDefaultScene loads the manifest's configured default scene" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var document = try scene.SceneDocument.init(
        testing.allocator,
        .parseComptime("22222222-2222-4222-8222-222222222222"),
        .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
        "Default Scene",
    );
    defer document.deinit();

    const bytes = try scene.json_codec.encodeAlloc(testing.allocator, &document);
    defer testing.allocator.free(bytes);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "default.json", .data = bytes });

    var project = Project{ .manifest = testManifest("default.json"), .root_dir = tmp.dir };

    var loaded = try project.loadDefaultScene(testing.allocator, testing.io);
    defer loaded.deinit();

    try testing.expectEqualStrings("Default Scene", loaded.name);
}

test "loadDefaultScene fails when the manifest has no default scene" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var project = Project{ .manifest = testManifest(null), .root_dir = tmp.dir };

    try testing.expectError(
        error.DefaultSceneNotFound,
        project.loadDefaultScene(testing.allocator, testing.io),
    );
}
