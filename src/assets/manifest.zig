const std = @import("std");
const zimp = @import("zimp");

const AssetId = zimp.AssetId;
const log = @import("../core/log.zig");

const RuntimeAssetManifest = @This();

arena: std.heap.ArenaAllocator,
entries: []Entry,
by_id: std.AutoHashMapUnmanaged(AssetId, u32),
by_cooked_path: std.StringHashMapUnmanaged(u32),

pub const Entry = struct {
    id: AssetId,
    kind: zimp.AssetKind,
    /// Relative to the project cooked dir, normalized.
    cooked_path: []const u8,
    content_hash: u64,
};

/// Load `<manifest_path>` relative to `root_dir` (the project root).
pub fn loadFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    manifest_path: []const u8,
) !RuntimeAssetManifest {
    var full = try zimp.manifest.codec.loadFromDir(allocator, io, root_dir, manifest_path);
    defer full.deinit();

    var self = RuntimeAssetManifest{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .entries = &.{},
        .by_id = .empty,
        .by_cooked_path = .empty,
    };
    errdefer self.deinit();
    const a = self.arena.allocator();

    const entries = try a.alloc(Entry, full.entries.len);
    for (full.entries, entries, 0..) |src, *entry, i| {
        const cooked_path = try zimp.path.normalizeVirtual(a, src.cooked_path);
        entry.* = .{
            .id = src.id,
            .kind = src.kind,
            .cooked_path = cooked_path,
            .content_hash = src.content_hash,
        };

        // The codec already rejects duplicate ids; cooked paths are not
        // covered by its uniqueness rules, so defend here.
        const id_gop = try self.by_id.getOrPut(a, src.id);
        if (id_gop.found_existing) {
            return error.DuplicateAssetId;
        }
        id_gop.value_ptr.* = @intCast(i);

        const path_gop = try self.by_cooked_path.getOrPut(a, cooked_path);
        if (path_gop.found_existing) {
            log.err("asset manifest maps two assets to cooked path '{s}'", .{cooked_path});
            return error.DuplicateCookedPath;
        }
        path_gop.value_ptr.* = @intCast(i);
    }
    self.entries = entries;
    return self;
}

pub fn deinit(self: *RuntimeAssetManifest) void {
    self.arena.deinit();
}

pub fn byId(self: *const RuntimeAssetManifest, id: AssetId) ?*const Entry {
    const idx = self.by_id.get(id) orelse return null;
    return &self.entries[idx];
}

/// `cooked_path` must already be normalized (the asset manager
/// normalizes every registration path before lookup).
pub fn byCookedPath(self: *const RuntimeAssetManifest, cooked_path: []const u8) ?*const Entry {
    const idx = self.by_cooked_path.get(cooked_path) orelse return null;
    return &self.entries[idx];
}

const testing = std.testing;

test "loadFromDir indexes entries by id and cooked path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fusion");

    var fixture = try zimp.manifest.model.testManifest(testing.allocator, &.{
        .{ .id = "3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01", .source_path = "meshes/monkey.glb", .cooked_path = "meshes/monkey.zmesh", .content_hash = 42 },
        .{ .id = "8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c", .source_path = "tex/brick.png", .kind = .texture, .cooked_path = "tex/brick.ztex" },
    });
    defer fixture.deinit();
    try zimp.manifest.codec.writeToDir(testing.allocator, testing.io, tmp.dir, ".fusion/assets.zmanifest", &fixture);

    var manifest = try RuntimeAssetManifest.loadFromDir(testing.allocator, testing.io, tmp.dir, ".fusion/assets.zmanifest");
    defer manifest.deinit();

    const mesh_id = AssetId.parseComptime("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01");
    const by_path = manifest.byCookedPath("meshes/monkey.zmesh").?;
    try testing.expect(by_path.id.eql(mesh_id));
    try testing.expectEqual(zimp.AssetKind.mesh, by_path.kind);
    try testing.expectEqual(@as(u64, 42), by_path.content_hash);

    const by_id = manifest.byId(mesh_id).?;
    try testing.expectEqualStrings("meshes/monkey.zmesh", by_id.cooked_path);

    try testing.expect(manifest.byCookedPath("missing.zmesh") == null);
    try testing.expect(manifest.byId(AssetId.zero) == null);
}

test "loadFromDir propagates missing and corrupt manifests" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.FileNotFound, RuntimeAssetManifest.loadFromDir(testing.allocator, testing.io, tmp.dir, "assets.zmanifest"));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets.zmanifest", .data = "garbage" });
    try testing.expectError(error.CorruptManifest, RuntimeAssetManifest.loadFromDir(testing.allocator, testing.io, tmp.dir, "assets.zmanifest"));
}
