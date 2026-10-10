const std = @import("std");
const zimp = @import("zimp");

pub const AssetError = error{
    InvalidPath,
    UnsupportedAssetKind,
    AssetNotFound,
    WrongAssetKind,
    /// Cube, array, and 3D textures are valid `.ztex` files but the renderer
    /// only uploads 2D textures.
    UnsupportedTextureType,
    LoadFailed,
    OutOfMemory,
};

/// Cooked assets by id: the loose cooked directory (editor and dev) or the
/// project's `.zpak` (shipping). Assets loaded from a pack may borrow its
/// mapping, so they must be freed before the store.
pub const AssetStore = zimp.runtime.AssetStore;
pub const AssetSource = AssetStore.Source;

const testing = std.testing;

const mesh_id = zimp.AssetId.parseComptime("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01");
const test_project: zimp.ProjectManifest = .{
    .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
};

fn writeTestMesh(dir: std.Io.Dir, sub_path: []const u8) !void {
    const file = try dir.createFile(testing.io, sub_path, .{});
    defer file.close(testing.io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try zimp.formats.zmesh.writeTestZmeshFile(&writer.interface);
    try writer.interface.flush();
}

test "AssetStore loads loose cooked files by id through the asset manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fusion/cooked/meshes");
    var fixture = try zimp.manifest.model.testManifest(testing.allocator, &.{
        .{ .id = "3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01", .source_path = "meshes/monkey.glb", .cooked_path = "meshes/monkey.zmesh" },
        .{ .id = "8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c", .source_path = "tex/missing.png", .kind = .texture, .cooked_path = "tex/missing.ztex" },
    });
    defer fixture.deinit();
    try zimp.manifest.codec.writeToDir(testing.allocator, testing.io, tmp.dir, test_project.asset_manifest, &fixture);
    try writeTestMesh(tmp.dir, ".fusion/cooked/meshes/monkey.zmesh");

    var store = try AssetStore.openProject(testing.allocator, testing.io, tmp.dir, &test_project, .loose);
    defer store.deinit(testing.io);

    const index = store.findKind(.mesh, mesh_id).?;
    try testing.expectEqualStrings("meshes/monkey.zmesh", store.nameAt(index));
    var asset = try store.load(testing.allocator, testing.io, index);
    defer asset.deinit(testing.allocator);
    try testing.expect(asset.view == .mesh);

    const missing = store.find(.parseComptime("8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c")).?;
    try testing.expectError(error.FileNotFound, store.load(testing.allocator, testing.io, missing));
}

test "AssetStore views packed assets inside the mapping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fusion");

    var mesh_buf: [4096]u8 align(16) = undefined;
    var mesh_writer = std.Io.Writer.fixed(&mesh_buf);
    try zimp.formats.zmesh.writeTestZmeshFile(&mesh_writer);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer = try zimp.formats.zpak.Writer.init(testing.allocator, &out.writer);
    defer writer.deinit();
    try writer.add(.{ .id = mesh_id, .kind = .mesh, .name = "meshes/monkey.zmesh", .payload = .{ .none = mesh_writer.buffered() } });
    const header = try writer.finish();
    const bytes = out.written();
    @memcpy(bytes[0..@sizeOf(zimp.formats.zpak.Header)], std.mem.asBytes(&header));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = test_project.asset_pack, .data = bytes });

    var store = try AssetStore.openProject(testing.allocator, testing.io, tmp.dir, &test_project, .pack);
    defer store.deinit(testing.io);
    var asset = try store.load(testing.allocator, testing.io, store.findKind(.mesh, mesh_id).?);
    defer asset.deinit(testing.allocator);
    try testing.expect(asset.view == .mesh);
    try testing.expect(asset.owned == null);
}

test "AssetStore reports a missing pack" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.FileNotFound, AssetStore.openProject(testing.allocator, testing.io, tmp.dir, &test_project, .pack));
}
