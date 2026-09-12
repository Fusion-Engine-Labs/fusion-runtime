const zimp = @import("zimp");
const std = @import("std");
const zob = @import("zob");

const GraphicsPipeline = @import("../graphics/rhi/graphics_pipeline.zig");
const device_factory = @import("../graphics/device_factory.zig");
const TextureAsset = @import("../graphics/texture_asset.zig");
const render_state = @import("../graphics/render_state.zig");
const RhiTexture = @import("../graphics/rhi/texture.zig");
const Sampler = @import("../graphics/rhi/sampler.zig");
const Device = @import("../graphics/rhi/device.zig");
const RuntimeAssetManifest = @import("manifest.zig");
const Material = @import("../graphics/material.zig");
const Project = @import("../project/project.zig");
const SamplerCache = @import("sampler_cache.zig");
const Mesh = @import("../graphics/mesh.zig");
const source_mod = @import("source.zig");
const log = @import("../core/log.zig");

pub const AssetError = source_mod.AssetError;
const CookedStore = source_mod.CookedStore;
const AssetKind = zimp.AssetKind;
const AssetId = zimp.AssetId;

fn detectKind(path: []const u8) ?AssetKind {
    return zimp.runtime.detectKind(path);
}

const AssetState = enum {
    queued,
    loading,
    ready_for_finalize,
    finalizing,
    loaded,
    failed,
};

const Availability = enum {
    missing,
    pending,
    loaded,
    failed,
};

const Asset = union(AssetKind) {
    mesh: *Mesh,
    texture: *TextureAsset,
    shader_stage: *zimp.ZShader,
    material: *Material,

    fn deinit(self: Asset, allocator: std.mem.Allocator) void {
        switch (self) {
            .mesh => |mesh| {
                mesh.deinit();
                allocator.destroy(mesh);
            },
            .material => |material| {
                material.deinit();
                allocator.destroy(material);
            },
            .texture => |texture| {
                texture.deinit();
                allocator.destroy(texture);
            },
            .shader_stage => |shader| {
                shader.deinit(allocator);
                allocator.destroy(shader);
            },
        }
    }
};

const AssetRecord = struct {
    id: AssetId,
    kind: AssetKind,
    path: ?[]u8,
    state: AssetState,
    asset: ?Asset = null,
    cooked: ?zimp.runtime.Asset = null,
    failure: ?anyerror = null,
    load_future: ?zob.Future(void) = null,

    fn deinit(
        self: *AssetRecord,
        allocator: std.mem.Allocator,
    ) void {
        if (self.asset) |asset| {
            asset.deinit(allocator);
            self.asset = null;
        }
        if (self.cooked) |*cooked| {
            cooked.deinit(allocator);
            self.cooked = null;
        }
        if (self.path) |path| {
            allocator.free(path);
            self.path = null;
        }
    }
};

const LoadJob = struct {
    manager: *AssetManager,
    record: *AssetRecord,
    pub fn execute(self: LoadJob) void {
        self.manager.processLoad(self.record);
    }
};

pub const AssetManager = struct {
    allocator: std.mem.Allocator,
    device: *Device,
    io: std.Io,
    source: CookedStore,
    sampler_cache: SamplerCache,

    scheduler: zob.Scheduler,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    assets: std.AutoHashMap(AssetId, *AssetRecord),
    asset_keys: std.StringHashMap(AssetId),
    graphics_pipelines: std.StringHashMap(GraphicsPipeline),
    /// Durable id <-> cooked path mapping from `assets.zmanifest`. The
    /// manifest is required: every asset id the runtime hands out is the
    /// durable id the cook assigned.
    manifest: RuntimeAssetManifest,

    /// `allocator` must be safe for concurrent use: zob jobs load cooked
    /// assets while the main thread finalizes them.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        project: *const Project,
        device: *Device,
    ) !AssetManager {
        const cooked_root = try zimp.path.normalizeVirtual(allocator, project.manifest.cookedAssetsPath());
        defer allocator.free(cooked_root);

        const cooked_dir = try std.Io.Dir.openDir(project.root_dir, io, cooked_root, .{});
        errdefer cooked_dir.close(io);

        var manifest = RuntimeAssetManifest.loadFromDir(
            allocator,
            io,
            project.root_dir,
            project.manifest.assetManifestPath(),
        ) catch |err| {
            log.err("failed to load asset manifest '{s}': {s}. Cook the project (zimp cook --project) first", .{ project.manifest.assetManifestPath(), @errorName(err) });
            return err;
        };
        errdefer manifest.deinit();

        const source = try CookedStore.initFromDir(
            allocator,
            cooked_root,
            cooked_dir,
        );
        var owned_source = source;
        errdefer owned_source.deinit(allocator, io);

        return .{
            .allocator = allocator,
            .device = device,
            .io = io,
            .source = owned_source,
            .sampler_cache = SamplerCache{ .allocator = allocator },
            .scheduler = zob.Scheduler.initWithOptions(io, allocator, .{
                .max_concurrency = defaultLoadConcurrency(),
            }),
            .assets = std.AutoHashMap(AssetId, *AssetRecord).init(allocator),
            .asset_keys = std.StringHashMap(AssetId).init(allocator),
            .graphics_pipelines = std.StringHashMap(GraphicsPipeline).init(allocator),
            .manifest = manifest,
        };
    }

    pub fn deinit(self: *AssetManager) void {
        var assets_it = self.assets.valueIterator();
        while (assets_it.next()) |record_ptr| {
            const record = record_ptr.*;
            if (record.load_future) |*future| {
                future.await(self.io);
            }
            record.deinit(self.allocator);
            self.allocator.destroy(record);
        }
        self.scheduler.deinit();
        self.assets.deinit();

        self.sampler_cache.deinit(self.device);

        var key_it = self.asset_keys.keyIterator();
        while (key_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.asset_keys.deinit();

        var pipeline_it = self.graphics_pipelines.iterator();
        while (pipeline_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.device.destroyGraphicsPipeline(entry.value_ptr);
        }
        self.graphics_pipelines.deinit();

        self.source.deinit(self.allocator, self.io);
        self.manifest.deinit();
    }

    pub fn registerId(self: *AssetManager, comptime T: type, id: AssetId) !AssetId {
        const expected = comptime kindFor(T);
        return self.requestKindById(expected, id);
    }

    pub fn availability(self: *AssetManager, id: AssetId) Availability {
        self.lock();
        defer self.unlock();
        const record = self.assets.get(id) orelse return .missing;

        return switch (record.state) {
            .loaded => .loaded,
            .failed => .failed,
            else => .pending,
        };
    }

    pub fn preloadBuiltins(self: *AssetManager) !void {
        const id = try self.registerId(
            Material,
            zimp.builtin.error_meterial_id,
        );
        try self.wait(id);
    }

    pub fn errorMaterial(self: *AssetManager) *Material {
        return self.get(Material, zimp.builtin.error_meterial_id).?;
    }

    fn requestKindById(self: *AssetManager, expected: AssetKind, id: AssetId) !AssetId {
        const entry = self.manifest.byId(id) orelse return AssetError.AssetNotFound;
        if (entry.kind != expected) {
            return AssetError.WrongAssetKind;
        }

        return self.requestKind(expected, entry.cooked_path);
    }

    pub fn wait(self: *AssetManager, id: AssetId) !void {
        while (true) {
            try self.pump();

            self.lock();
            const record = self.assets.get(id) orelse {
                self.unlock();
                return AssetError.AssetNotFound;
            };
            switch (record.state) {
                .loaded => {
                    self.unlock();
                    return;
                },
                .failed => {
                    const err = record.failure orelse AssetError.LoadFailed;
                    self.unlock();
                    return err;
                },
                .ready_for_finalize, .finalizing => {
                    self.unlock();
                },
                .queued, .loading => {
                    self.cond.waitUncancelable(self.io, &self.mutex);
                    self.unlock();
                },
            }
        }
    }

    pub fn pump(self: *AssetManager) !void {
        var ready: std.ArrayList(*AssetRecord) = .empty;
        defer ready.deinit(self.allocator);

        {
            self.lock();
            defer self.unlock();
            var it = self.assets.valueIterator();
            while (it.next()) |record_ptr| {
                const record = record_ptr.*;
                switch (record.state) {
                    .ready_for_finalize => {
                        self.reapLoadFutureLocked(record);
                        try ready.append(self.allocator, record);
                        record.state = .finalizing;
                    },
                    .failed => self.reapLoadFutureLocked(record),
                    else => {},
                }
            }
        }

        for (ready.items) |record| {
            const result = self.finalizeRecord(record) catch |err| {
                log.err("failed to finalize {s} asset '{s}': {}", .{
                    @tagName(record.kind),
                    assetPath(record),
                    err,
                });
                self.lock();
                self.failRecordLocked(record, err);
                self.unlock();
                continue;
            };

            self.lock();
            switch (result) {
                .loaded => |asset| {
                    record.asset = asset;
                    record.state = .loaded;
                    record.failure = null;
                },
                .waiting => {
                    record.state = .ready_for_finalize;
                },
            }
            self.cond.broadcast(self.io);
            self.unlock();
        }
    }

    pub fn get(self: *AssetManager, comptime T: type, id: AssetId) ?*T {
        const expected = comptime kindFor(T);
        self.lock();
        defer self.unlock();

        const record = self.assets.get(id) orelse return null;
        if (record.state != .loaded) return null;
        const asset = record.asset orelse return null;
        return switch (expected) {
            .mesh => switch (asset) {
                .mesh => |mesh| mesh,
                else => null,
            },
            .material => switch (asset) {
                .material => |material| material,
                else => null,
            },
            .texture => switch (asset) {
                .texture => |texture| texture,
                else => null,
            },
            .shader_stage => null,
        };
    }

    fn requestKind(self: *AssetManager, expected: AssetKind, path: []const u8) !AssetId {
        const normalized_path = try self.normalizeExpected(path, expected);
        var path_owned = true;
        errdefer if (path_owned) self.allocator.free(normalized_path);

        const lookup_key = try makePathAssetKey(self.allocator, normalized_path);
        var key_owned = true;
        errdefer if (key_owned) self.allocator.free(lookup_key);

        const record = created: {
            self.lock();
            defer self.unlock();

            if (self.asset_keys.get(lookup_key)) |cached| {
                self.allocator.free(normalized_path);
                self.allocator.free(lookup_key);
                return cached;
            }

            const id = try self.resolveIdLocked(expected, normalized_path);
            const new_record = try self.allocator.create(AssetRecord);
            new_record.* = .{
                .id = id,
                .kind = expected,
                .path = normalized_path,
                .state = .queued,
            };
            path_owned = false;
            var record_owned = true;
            errdefer if (record_owned) {
                new_record.deinit(self.allocator);
                self.allocator.destroy(new_record);
            };
            try self.assets.put(id, new_record);
            errdefer _ = self.assets.remove(id);
            try self.asset_keys.put(lookup_key, id);
            key_owned = false;
            record_owned = false;

            break :created new_record;
        };

        record.load_future = self.scheduler.submit(LoadJob, .{
            .manager = self,
            .record = record,
        }, .low);
        return record.id;
    }

    fn processLoad(self: *AssetManager, record: *AssetRecord) void {
        self.lock();
        if (record.state != .queued) {
            self.unlock();
            return;
        }
        record.state = .loading;
        self.cond.broadcast(self.io);
        self.unlock();

        const loaded = self.loadCookedAsset(record) catch |err| {
            log.err("failed to load {s} asset '{s}': {}", .{
                @tagName(record.kind),
                assetPath(record),
                err,
            });
            self.lock();
            record.failure = err;
            record.state = .failed;
            self.cond.broadcast(self.io);
            self.unlock();
            return;
        };

        self.lock();
        record.cooked = loaded;
        record.state = .ready_for_finalize;
        self.cond.broadcast(self.io);
        self.unlock();
    }

    /// `processLoad` publishes its terminal state before returning. Reaping a
    /// future after that state is visible is therefore non-blocking in normal
    /// operation and releases the scheduler's completed-task resources.
    fn reapLoadFutureLocked(self: *AssetManager, record: *AssetRecord) void {
        if (record.load_future) |*future| {
            future.await(self.io);
            record.load_future = null;
        }
    }

    fn loadCookedAsset(self: *AssetManager, record: *AssetRecord) !zimp.runtime.Asset {
        const normalized_path = record.path orelse return AssetError.AssetNotFound;
        const bytes = self.source.readAlloc(self.allocator, self.io, normalized_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => return AssetError.AssetNotFound,
            error.OutOfMemory => return AssetError.OutOfMemory,
            zimp.path.Error.AbsolutePathNotAllowed,
            zimp.path.Error.ParentTraversalNotAllowed,
            zimp.path.Error.EmptyPath,
            zimp.path.Error.PathTooLong,
            => return AssetError.InvalidPath,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        return zimp.runtime.loadFromReader(
            self.allocator,
            &reader,
            zimp.runtime.detectKind(normalized_path) orelse return AssetError.UnsupportedAssetKind,
        );
    }

    const FinalizeResult = union(enum) {
        loaded: Asset,
        waiting,
    };

    fn finalizeRecord(self: *AssetManager, record: *AssetRecord) !FinalizeResult {
        return switch (record.kind) {
            .mesh => .{ .loaded = .{ .mesh = try self.finalizeMesh(record) } },
            .material => try self.finalizeMaterial(record),
            .texture => .{ .loaded = .{ .texture = try self.finalizeTexture(record) } },
            .shader_stage => .{ .loaded = .{ .shader_stage = try self.finalizeShaderStage(record) } },
        };
    }

    fn finalizeMesh(self: *AssetManager, record: *AssetRecord) !*Mesh {
        var cooked_asset = try takeCooked(record);
        defer cooked_asset.deinit(self.allocator);

        const cooked_mesh = switch (cooked_asset) {
            .mesh => |mesh| mesh,
            else => return AssetError.WrongAssetKind,
        };

        const mesh = try self.allocator.create(Mesh);
        errdefer self.allocator.destroy(mesh);

        const material_ids = try self.requestMeshMaterials(&cooked_mesh);
        errdefer self.allocator.free(material_ids);

        mesh.* = try Mesh.loadFromZMesh(self.allocator, self.device, &cooked_mesh, material_ids);
        errdefer mesh.deinit();

        return mesh;
    }

    fn finalizeTexture(self: *AssetManager, record: *AssetRecord) !*TextureAsset {
        var cooked_asset = try takeCooked(record);
        defer cooked_asset.deinit(self.allocator);

        const cooked_texture = switch (cooked_asset) {
            .texture => |texture| texture,
            else => return AssetError.WrongAssetKind,
        };

        var mips: std.ArrayList(RhiTexture.MipData) = .empty;
        defer mips.deinit(self.allocator);
        try mips.ensureTotalCapacityPrecise(self.allocator, cooked_texture.mips.len);
        for (cooked_texture.mips) |mip| {
            mips.appendAssumeCapacity(.{ .extent = .{ .width = mip.width, .height = mip.height }, .bytes = mip.data });
        }

        const texture = try self.allocator.create(TextureAsset);
        errdefer self.allocator.destroy(texture);
        var gpu_texture = try self.device.createTexture(.{
            .extent = .{ .width = cooked_texture.width, .height = cooked_texture.height },
            .format = try rhiTextureFormat(cooked_texture.format, cooked_texture.color_space),
            .usage = .{ .sampled = true },
            .mips = mips.items,
        });
        errdefer self.device.destroyTexture(&gpu_texture);
        texture.* = .{
            .texture = gpu_texture,
            .view = self.device.textureView(gpu_texture),
            .device = self.device,
        };

        return texture;
    }

    fn finalizeShaderStage(self: *AssetManager, record: *AssetRecord) !*zimp.ZShader {
        var cooked_asset = try takeCooked(record);
        errdefer cooked_asset.deinit(self.allocator);

        // `cooked_asset` is zimp.runtime.Asset (the cooked-file union), whose
        // shader variant is named `.shader`.
        const shader = switch (cooked_asset) {
            .shader => |stage| stage,
            else => return AssetError.WrongAssetKind,
        };

        const shader_ptr = try self.allocator.create(zimp.ZShader);
        shader_ptr.* = shader;
        return shader_ptr;
    }

    fn finalizeMaterial(self: *AssetManager, record: *AssetRecord) !FinalizeResult {
        const material_source_ptr = try cookedMaterialSource(record);

        const pipeline = try self.materialPipelineReady(material_source_ptr) orelse return .waiting;

        var texture_bindings: std.ArrayList(Material.TextureBinding) = .empty;
        defer texture_bindings.deinit(self.allocator);
        if (!try self.materialTexturesReady(material_source_ptr, &texture_bindings)) {
            return .waiting;
        }

        const cooked_asset = record.cooked orelse return AssetError.LoadFailed;
        record.cooked = null;

        var material_source = switch (cooked_asset) {
            .material => |source| source,
            else => return AssetError.WrongAssetKind,
        };
        var source_owned = true;
        errdefer if (source_owned) material_source.deinit(self.allocator);

        const texture_slice = try texture_bindings.toOwnedSlice(self.allocator);
        var texture_slice_owned = true;
        errdefer if (texture_slice_owned) self.allocator.free(texture_slice);

        const material = try self.allocator.create(Material);
        errdefer self.allocator.destroy(material);
        material.* = try Material.init(
            self.allocator,
            material_source,
            pipeline,
            texture_slice,
            self.device,
        );
        source_owned = false;
        texture_slice_owned = false;
        errdefer material.deinit();

        return .{ .loaded = .{ .material = material } };
    }

    fn materialPipelineReady(
        self: *AssetManager,
        material_source: *const zimp.Zamat,
    ) !?GraphicsPipeline {
        const vertex_path = try materialDependencyPath(self.allocator, material_source.vertex_shader_path);
        defer self.allocator.free(vertex_path);

        const fragment_path = try materialDependencyPath(self.allocator, material_source.fragment_shader_path);
        defer self.allocator.free(fragment_path);

        return self.loadGraphicsPipelineReady(
            vertex_path,
            fragment_path,
            material_source.required_variants,
            render_state.FixedState.generate(material_source.render_state),
        );
    }

    fn materialTexturesReady(
        self: *AssetManager,
        material_source: *const zimp.Zamat,
        out_bindings: *std.ArrayList(Material.TextureBinding),
    ) !bool {
        try out_bindings.ensureTotalCapacityPrecise(self.allocator, material_source.texture_slots.len);
        for (material_source.texture_slots, 0..) |slot, texture_unit| {
            if (slot.cooked_path.len == 0) continue;

            const texture_path = try materialDependencyPath(self.allocator, slot.cooked_path);
            defer self.allocator.free(texture_path);

            const texture_id = try self.requestKind(.texture, texture_path);
            const texture_asset = try self.loadedAsset(texture_id, .texture) orelse return false;
            const texture = texture_asset.texture;
            out_bindings.appendAssumeCapacity(.{
                .unit = @intCast(texture_unit),
                .view = texture.view,
                .sampler = try self.sampler_cache.get(self.device, Sampler.Desc.fromTextureSlotEntry(slot)),
                .sampler_name = slot.sampler_name,
                .uv_set = slot.uv_set,
                .uv_offset = slot.uv_offset,
                .uv_scale = slot.uv_scale,
                .uv_rotation = slot.uv_rotation,
                .normal_scale = slot.normal_scale,
                .occlusion_strength = slot.occlusion_strength,
            });
        }
        return true;
    }

    fn requestMeshMaterials(self: *AssetManager, source: *const zimp.ZMesh) ![]AssetId {
        const ids = try self.allocator.alloc(
            AssetId,
            source.material_slots.len,
        );
        errdefer self.allocator.free(ids);

        for (source.material_slots, ids) |cooked_path, *id| {
            id.* = try self.requestKind(
                .material,
                cooked_path,
            );
        }

        return ids;
    }

    fn loadGraphicsPipelineReady(
        self: *AssetManager,
        vertex_path: []const u8,
        fragment_path: []const u8,
        required_variants: []const []const u8,
        fixed_state: render_state.FixedState,
    ) !?GraphicsPipeline {
        const normalized_vertex = try self.normalizeExpected(vertex_path, .shader_stage);
        defer self.allocator.free(normalized_vertex);
        const normalized_fragment = try self.normalizeExpected(fragment_path, .shader_stage);
        defer self.allocator.free(normalized_fragment);

        const vertex_id = try self.requestKind(.shader_stage, normalized_vertex);
        const fragment_id = try self.requestKind(.shader_stage, normalized_fragment);
        const vertex_asset = try self.loadedAsset(vertex_id, .shader_stage) orelse return null;
        const fragment_asset = try self.loadedAsset(fragment_id, .shader_stage) orelse return null;
        const vertex_stage = vertex_asset.shader_stage;
        const fragment_stage = fragment_asset.shader_stage;

        if (vertex_stage.stage != .vertex or fragment_stage.stage != .fragment) {
            return AssetError.WrongAssetKind;
        }

        const vertex_variant = try stageVariantKey(vertex_stage, required_variants);
        const fragment_variant = try stageVariantKey(fragment_stage, required_variants);

        const lookup_key = try makeGraphicsPipelineKey(
            self.allocator,
            normalized_vertex,
            vertex_variant,
            normalized_fragment,
            fragment_variant,
            fixed_state,
        );
        var key_owned = true;
        defer if (key_owned) self.allocator.free(lookup_key);

        self.lock();
        if (self.graphics_pipelines.get(lookup_key)) |pipeline| {
            self.unlock();
            return pipeline;
        }
        self.unlock();

        var pipeline = try createGraphicsPipeline(
            self.device,
            vertex_stage,
            vertex_variant,
            fragment_stage,
            fragment_variant,
            fixed_state,
        );
        errdefer self.device.destroyGraphicsPipeline(&pipeline);

        self.lock();
        defer self.unlock();

        if (self.graphics_pipelines.get(lookup_key)) |cached| {
            self.device.destroyGraphicsPipeline(&pipeline);
            return cached;
        }

        try self.graphics_pipelines.put(lookup_key, pipeline);
        key_owned = false;

        return pipeline;
    }

    fn loadedAsset(self: *AssetManager, id: AssetId, expected: AssetKind) !?Asset {
        self.lock();
        defer self.unlock();
        const record = self.assets.get(id) orelse return AssetError.AssetNotFound;
        if (record.state == .failed) {
            return record.failure orelse AssetError.LoadFailed;
        }
        if (record.state != .loaded) {
            return null;
        }
        const asset = record.asset orelse return AssetError.LoadFailed;
        if (std.meta.activeTag(asset) != expected) return AssetError.WrongAssetKind;
        return asset;
    }

    fn failRecordLocked(self: *AssetManager, record: *AssetRecord, err: anyerror) void {
        if (record.cooked) |*cooked| {
            cooked.deinit(self.allocator);
            record.cooked = null;
        }
        record.failure = err;
        record.state = .failed;
        self.cond.broadcast(self.io);
    }

    fn normalizeExpected(self: *AssetManager, raw_path: []const u8, expected: AssetKind) ![]u8 {
        const normalized = zimp.path.normalizeVirtual(self.allocator, raw_path) catch return AssetError.InvalidPath;
        errdefer self.allocator.free(normalized);
        const actual = detectKind(normalized) orelse return AssetError.UnsupportedAssetKind;
        if (actual != expected) {
            return AssetError.WrongAssetKind;
        }
        return normalized;
    }

    /// Resolve the durable id for a (kind, normalized cooked path)
    /// registration. Every registrable asset must be in the manifest —
    /// there are no ephemeral ids.
    fn resolveIdLocked(self: *AssetManager, expected: AssetKind, normalized_path: []const u8) !AssetId {
        const entry = self.manifest.byCookedPath(normalized_path) orelse {
            log.err("asset '{s}' is not in the asset manifest; recook the project (zimp cook --project)", .{normalized_path});
            return AssetError.AssetNotFound;
        };
        if (entry.kind != expected) return AssetError.WrongAssetKind;
        return entry.id;
    }

    fn lock(self: *AssetManager) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *AssetManager) void {
        self.mutex.unlock(self.io);
    }
};

fn assetPath(record: *const AssetRecord) []const u8 {
    return record.path orelse "<generated graphics pipeline>";
}

/// Dependencies serialized in a cooked material are virtual paths rooted at
/// the cooked asset directory, not paths relative to the material itself.
fn materialDependencyPath(allocator: std.mem.Allocator, serialized_path: []const u8) ![]u8 {
    return zimp.path.normalizeVirtual(allocator, serialized_path);
}

fn cookedMaterialSource(record: *AssetRecord) !*zimp.Zamat {
    const cooked_ptr = &(record.cooked orelse return AssetError.LoadFailed);
    return switch (cooked_ptr.*) {
        .material => |*source| source,
        else => AssetError.WrongAssetKind,
    };
}

fn takeCooked(record: *AssetRecord) !zimp.runtime.Asset {
    const cooked_asset = record.cooked orelse return AssetError.LoadFailed;
    record.cooked = null;
    return cooked_asset;
}

fn rhiTextureFormat(format: zimp.TexelFormat, color_space: zimp.ColorSpace) !RhiTexture.Format {
    return switch (format) {
        .r8 => .r8_unorm,
        .rg8 => .rg8_unorm,
        .rgba8 => if (color_space == .srgb) .rgba8_srgb else .rgba8_unorm,
        .rgb16f => .rgb16_float,
        .bc4 => .bc4_unorm,
        .bc5 => .bc5_unorm,
        .bc6h => .bc6h_ufloat,
        .bc7 => if (color_space == .srgb) .bc7_srgb else .bc7_unorm,
    };
}

fn defaultLoadConcurrency() usize {
    const cpu_count = std.Thread.getCpuCount() catch 2;
    if (cpu_count <= 1) return 1;
    return @min(cpu_count - 1, 4);
}

fn createGraphicsPipeline(
    device: *Device,
    vertex_stage: *const zimp.ZShader,
    vertex_variant: zimp.VariantKey,
    fragment_stage: *const zimp.ZShader,
    fragment_variant: zimp.VariantKey,
    fixed_state: render_state.FixedState,
) !GraphicsPipeline {
    const vertex_source = try vertex_stage.sourceFor(vertex_variant);
    const fragment_source = try fragment_stage.sourceFor(fragment_variant);
    return device.createGraphicsPipeline(.{
        .vertex = .{ .glsl = vertex_source },
        .fragment = .{ .glsl = fragment_source },
        .fixed_state = fixed_state,
    });
}

fn stageVariantKey(
    stage: *const zimp.ZShader,
    required_variants: []const []const u8,
) !zimp.VariantKey {
    var selected: [32][]const u8 = undefined;
    var selected_len: usize = 0;

    for (stage.variant_names) |declared| {
        if (!containsString(required_variants, declared)) continue;
        selected[selected_len] = declared;
        selected_len += 1;
    }

    return stage.variantKey(selected[0..selected_len]);
}

fn containsString(
    strings: []const []const u8,
    needle: []const u8,
) bool {
    for (strings) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn kindFor(comptime T: type) AssetKind {
    return switch (T) {
        Mesh => .mesh,
        Material => .material,
        TextureAsset => .texture,
        zimp.ZShader => .shader_stage,
        else => @compileError("unsupported asset type: " ++ @typeName(T)),
    };
}

fn makePathAssetKey(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "path:{s}", .{path});
}

fn makeGraphicsPipelineKey(
    allocator: std.mem.Allocator,
    vertex_path: []const u8,
    vertex_variant: zimp.VariantKey,
    fragment_path: []const u8,
    fragment_variant: zimp.VariantKey,
    fixed_state: render_state.FixedState,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "pipeline:{s}\x00{d}\x00{s}\x00{d}\x00{}\x00{}\x00{s}\x00{s}",
        .{
            vertex_path,
            vertex_variant.bits,
            fragment_path,
            fragment_variant.bits,
            fixed_state.depth_test,
            fixed_state.depth_write,
            @tagName(fixed_state.cull_mode),
            @tagName(fixed_state.blend_mode),
        },
    );
}

const test_fixed_state: render_state.FixedState = .{
    .depth_test = true,
    .depth_write = true,
    .cull_mode = .back,
    .blend_mode = .disabled,
};

test "makeGraphicsPipelineKey includes stages, variants, and fixed state" {
    const key = try makeGraphicsPipelineKey(
        std.testing.allocator,
        "basic.vert.zshdr",
        .fromBits(1),
        "basic.frag.zshdr",
        .fromBits(2),
        test_fixed_state,
    );
    defer std.testing.allocator.free(key);

    try std.testing.expectEqualStrings(
        "pipeline:basic.vert.zshdr\x001\x00basic.frag.zshdr\x002\x00true\x00true\x00back\x00disabled",
        key,
    );
}

test "makeGraphicsPipelineKey distinguishes shader variants" {
    const base = try makeGraphicsPipelineKey(
        std.testing.allocator,
        "basic.vert.zshdr",
        .base,
        "basic.frag.zshdr",
        .base,
        test_fixed_state,
    );
    defer std.testing.allocator.free(base);

    const alpha_test = try makeGraphicsPipelineKey(
        std.testing.allocator,
        "basic.vert.zshdr",
        .base,
        "basic.frag.zshdr",
        .fromBits(1),
        test_fixed_state,
    );
    defer std.testing.allocator.free(alpha_test);

    try std.testing.expect(!std.mem.eql(u8, base, alpha_test));
}

test "makeGraphicsPipelineKey distinguishes fixed state" {
    const base = try makeGraphicsPipelineKey(
        std.testing.allocator,
        "basic.vert.zshdr",
        .base,
        "basic.frag.zshdr",
        .base,
        test_fixed_state,
    );
    defer std.testing.allocator.free(base);

    var no_depth_write = test_fixed_state;
    no_depth_write.depth_write = false;
    const alternate = try makeGraphicsPipelineKey(
        std.testing.allocator,
        "basic.vert.zshdr",
        .base,
        "basic.frag.zshdr",
        .base,
        no_depth_write,
    );
    defer std.testing.allocator.free(alternate);

    try std.testing.expect(!std.mem.eql(u8, base, alternate));
}

test "stageVariantKey selects only variants declared by that stage" {
    const vertex_stage = zimp.ZShader{
        .stage = .vertex,
        .variant_names = &.{"SKINNED"},
        .includes = &.{},
        .permutations = &.{},
    };
    const fragment_stage = zimp.ZShader{
        .stage = .fragment,
        .variant_names = &.{ "HAS_ALBEDO_MAP", "ALPHA_TEST" },
        .includes = &.{},
        .permutations = &.{},
    };
    const required = &.{ "SKINNED", "ALPHA_TEST" };

    try std.testing.expectEqual(
        zimp.VariantKey.fromBits(1),
        try stageVariantKey(&vertex_stage, required),
    );
    try std.testing.expectEqual(
        zimp.VariantKey.fromBits(2),
        try stageVariantKey(&fragment_stage, required),
    );
}

const testing = std.testing;

test "cooked material dependencies remain project-root paths" {
    const shader_path = try materialDependencyPath(testing.allocator, "shaders/basic.vert.zshdr");
    defer testing.allocator.free(shader_path);
    try testing.expectEqualStrings("shaders/basic.vert.zshdr", shader_path);

    const texture_path = try materialDependencyPath(testing.allocator, "textures/brick.ztex");
    defer testing.allocator.free(texture_path);
    try testing.expectEqualStrings("textures/brick.ztex", texture_path);
}

const mesh_manifest_id = AssetId.parseComptime("3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01");

fn testProjectManifest() !zimp.ProjectManifest {
    const source: zimp.ProjectManifest = .{
        .project_id = .parseComptime("bf5a424f-e93e-4977-9a7a-0c522318dfdc"),
    };
    return source.cloneOwned(testing.allocator);
}

/// Test project with a manifest covering the cooked assets the tests load.
fn testProject(tmp: *std.testing.TmpDir) !Project {
    try tmp.dir.createDirPath(testing.io, ".fusion/cooked");

    var fixture = try zimp.manifest.model.testManifest(testing.allocator, &.{
        .{ .id = "3f2a77f1-9c44-4b7e-9b1a-2f6c1d8e5a01", .source_path = "meshes/asset.glb", .cooked_path = "asset.zmesh" },
        .{ .id = "b7e9b1a2-f6c1-4d8e-9a01-3f2a77f19c44", .source_path = "meshes/missing.glb", .cooked_path = "missing.zmesh" },
    });
    defer fixture.deinit();
    try zimp.manifest.codec.writeToDir(testing.allocator, testing.io, tmp.dir, ".fusion/assets.zmanifest", &fixture);

    return .{
        .manifest = try testProjectManifest(),
        .root_dir = try std.Io.Dir.openDir(tmp.dir, testing.io, ".", .{}),
    };
}

test "init opens cooked assets from project root" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, ".fusion/cooked");

    var project = try testProject(&tmp);
    defer project.deinit(testing.allocator, testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();

    var manager = try AssetManager.init(
        testing.allocator,
        testing.io,
        &project,
        &device,
    );
    defer manager.deinit();

    try testing.expectEqualStrings(".fusion/cooked", manager.source.root);
}

test "registerId deduplicates requests before background load finishes" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProject(&tmp);
    defer project.deinit(testing.allocator, testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();

    var manager = try AssetManager.init(
        std.testing.allocator,
        std.testing.io,
        &project,
        &device,
    );
    defer manager.deinit();

    const first = try manager.registerId(Mesh, mesh_manifest_id);
    const second = try manager.registerId(Mesh, mesh_manifest_id);

    try std.testing.expectEqual(first, second);

    manager.wait(first) catch {};
}

test "background load failures are observable through wait and state" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var project = try testProject(&tmp);
    defer project.deinit(testing.allocator, testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();

    var manager = try AssetManager.init(
        std.testing.allocator,
        std.testing.io,
        &project,
        &device,
    );
    defer manager.deinit();

    const id = try manager.registerId(Mesh, AssetId.parseComptime("b7e9b1a2-f6c1-4d8e-9a01-3f2a77f19c44"));
    try std.testing.expectError(AssetError.AssetNotFound, manager.wait(id));
}

test "registerId resolves the durable id from the asset manifest" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProject(&tmp);
    defer project.deinit(testing.allocator, testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();

    var manager = try AssetManager.init(testing.allocator, testing.io, &project, &device);
    defer manager.deinit();

    const id = try manager.registerId(Mesh, mesh_manifest_id);
    try testing.expect(id.eql(mesh_manifest_id));

    // Repeated id registration dedupes to the same record.
    const by_id = try manager.registerId(Mesh, mesh_manifest_id);
    try testing.expect(by_id.eql(id));

    // Kind mismatches and unknown ids are rejected.
    try testing.expectError(AssetError.WrongAssetKind, manager.registerId(TextureAsset, mesh_manifest_id));
    try testing.expectError(AssetError.AssetNotFound, manager.registerId(Mesh, AssetId.parseComptime("8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c")));

    manager.wait(id) catch {};
}

test "init fails without an asset manifest" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fusion/cooked");

    var project: Project = .{
        .manifest = try testProjectManifest(),
        .root_dir = try std.Io.Dir.openDir(tmp.dir, testing.io, ".", .{}),
    };
    defer project.deinit(testing.allocator, testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();

    try testing.expectError(error.FileNotFound, AssetManager.init(testing.allocator, testing.io, &project, &device));
}

test "detectKind maps supported cooked extensions" {
    try testing.expectEqual(AssetKind.mesh, detectKind("monkey.zmesh").?);
    try testing.expectEqual(AssetKind.material, detectKind("monkey.zamat").?);
    try testing.expectEqual(AssetKind.texture, detectKind("brick_albedo.ztex").?);
    try testing.expectEqual(AssetKind.shader_stage, detectKind("basic.vert.zshdr").?);
}

test "detectKind requires lowercase cooked extensions" {
    try testing.expect(detectKind("MONKEY.ZMESH") == null);
}
