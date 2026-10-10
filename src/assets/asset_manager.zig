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
const Material = @import("../graphics/material.zig");
const Project = @import("../project/project.zig");
const SamplerCache = @import("sampler_cache.zig");
const Mesh = @import("../graphics/mesh.zig");
const source_mod = @import("source.zig");
const log = @import("../core/log.zig");

pub const AssetError = source_mod.AssetError;
const AssetStore = source_mod.AssetStore;
const AssetKind = zimp.AssetKind;
const AssetId = zimp.AssetId;

const AssetState = enum {
    /// Submitted to a loader thread.
    queued,
    loading,
    /// Loaded and in `AssetManager.ready`, waiting for the main thread's `pump`.
    ready_for_finalize,
    /// A material whose shaders or textures weren't loaded at its last
    /// finalize; in `AssetManager.waiting`.
    waiting,
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
    /// Cooked shader bytes plus the `ZShader` view into them; sources are
    /// read when pipelines are created, so the bytes stay alive.
    shader_stage: *zimp.runtime.Asset,
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
    /// The asset's entry in `AssetManager.source`.
    index: AssetStore.Index,
    state: AssetState,
    asset: ?Asset = null,
    cooked: ?zimp.runtime.Asset = null,
    /// A mesh's streams, decoded on the loader thread for `finalizeMesh` to upload.
    decoded_mesh: ?Mesh.Decoded = null,
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
        self.freeLoaded(allocator);
    }

    /// Frees what the loader thread produced for finalization.
    fn freeLoaded(self: *AssetRecord, allocator: std.mem.Allocator) void {
        if (self.cooked) |*cooked| {
            cooked.deinit(allocator);
            self.cooked = null;
        }
        if (self.decoded_mesh) |*decoded| {
            decoded.deinit(allocator);
            self.decoded_mesh = null;
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

/// Graphics pipelines are shared by every material with the same stages,
/// variants, and fixed-function state.
const PipelineKey = struct {
    vertex_shader: AssetId,
    vertex_variant: zimp.VariantKey,
    fragment_shader: AssetId,
    fragment_variant: zimp.VariantKey,
    fixed_state: render_state.FixedState,
};

/// Loads cooked assets on loader threads and finalizes them (GPU uploads,
/// pipeline creation) on the main thread in `pump`.
///
/// A loader thread reads an asset, immediately requests everything it
/// references (so a mesh's materials, shaders, and textures load in
/// parallel with it), and does the asset's CPU-side preparation, such as
/// decoding mesh streams. The main thread only creates GPU objects.
pub const AssetManager = struct {
    allocator: std.mem.Allocator,
    device: *Device,
    io: std.Io,
    /// Cooked assets by id, from the loose cooked directory or the project's
    /// pack (`Project.asset_source`). Every asset id the runtime hands out is
    /// the durable id the cook assigned.
    source: AssetStore,
    sampler_cache: SamplerCache,

    scheduler: zob.Scheduler,
    mutex: std.Io.Mutex = .init,
    /// Broadcast whenever `generation` changes.
    cond: std.Io.Condition = .init,

    // Guarded by `mutex`:
    assets: std.AutoHashMap(AssetId, *AssetRecord),
    /// Records loaded since the last `pump`.
    ready: std.ArrayList(*AssetRecord) = .empty,
    /// Bumped whenever a record finishes loading, loads, or fails: anything
    /// that can let a waiting material finish, or should wake `wait`.
    generation: u64 = 0,
    /// Load jobs submitted and not yet finished.
    pending_jobs: usize = 0,
    /// Set by `deinit`, after which no new loads start.
    shutting_down: bool = false,

    // Main thread only:
    graphics_pipelines: std.AutoHashMap(PipelineKey, GraphicsPipeline),
    /// Swapped with `ready` by `pump`, so neither list reallocates per frame.
    ready_spare: std.ArrayList(*AssetRecord) = .empty,
    /// Materials whose dependencies weren't loaded at their last finalize.
    waiting: std.ArrayList(*AssetRecord) = .empty,
    /// `generation` when `waiting` was last retried.
    waiting_generation: u64 = 0,

    /// `allocator` must be safe for concurrent use: zob jobs load cooked
    /// assets while the main thread finalizes them.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        project: *const Project,
        device: *Device,
    ) !AssetManager {
        var source = AssetStore.openProject(allocator, io, project.root_dir, &project.manifest, project.asset_source) catch |err| {
            switch (project.asset_source) {
                .loose => log.err("failed to open cooked assets through '{s}': {s}. Cook the project (zimp cook --project) first", .{ project.manifest.assetManifestPath(), @errorName(err) }),
                .pack => log.err("failed to open asset pack '{s}': {s}. Build it with zimp pack --project", .{ project.manifest.assetPackPath(), @errorName(err) }),
            }
            return err;
        };
        errdefer source.deinit(io);

        return .{
            .allocator = allocator,
            .device = device,
            .io = io,
            .source = source,
            .sampler_cache = SamplerCache{ .allocator = allocator },
            .scheduler = zob.Scheduler.initWithOptions(io, allocator, .{
                .max_concurrency = defaultLoadConcurrency(),
            }),
            .assets = std.AutoHashMap(AssetId, *AssetRecord).init(allocator),
            .graphics_pipelines = std.AutoHashMap(PipelineKey, GraphicsPipeline).init(allocator),
        };
    }

    /// Callers must have stopped using the manager; only its own loader
    /// threads may still be running, and those are drained here.
    pub fn deinit(self: *AssetManager) void {
        // In-flight loads may still request their dependencies; stop new
        // loads and let those settle before tearing anything down.
        self.lock();
        self.shutting_down = true;
        while (self.pending_jobs > 0) self.cond.waitUncancelable(self.io, &self.mutex);
        self.unlock();

        var assets_it = self.assets.valueIterator();
        while (assets_it.next()) |record_ptr| {
            const record = record_ptr.*;
            // Every job has finished, so this doesn't block.
            if (record.load_future) |*future| future.await(self.io);
            record.deinit(self.allocator);
            self.allocator.destroy(record);
        }
        self.scheduler.deinit();
        self.assets.deinit();
        self.ready.deinit(self.allocator);
        self.ready_spare.deinit(self.allocator);
        self.waiting.deinit(self.allocator);

        self.sampler_cache.deinit(self.device);

        var pipeline_it = self.graphics_pipelines.valueIterator();
        while (pipeline_it.next()) |pipeline| self.device.destroyGraphicsPipeline(pipeline);
        self.graphics_pipelines.deinit();

        // Last: loaded assets may borrow the pack's mapping.
        self.source.deinit(self.io);
    }

    /// Starts loading `id`, and as soon as it has been read, everything it
    /// references.
    pub fn registerId(self: *AssetManager, comptime T: type, id: AssetId) !AssetId {
        const expected = comptime kindFor(T);
        return self.requestKindById(expected, id, .normal);
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

    /// Returns `id` once it has a record, creating the record and submitting
    /// its load if needed. Safe to call from any thread: loader threads call
    /// it for the dependencies they discover.
    fn requestKindById(self: *AssetManager, expected: AssetKind, id: AssetId, priority: zob.Priority) !AssetId {
        {
            self.lock();
            defer self.unlock();
            if (self.assets.get(id)) |record| {
                if (record.kind != expected) return AssetError.WrongAssetKind;
                return id;
            }
        }

        const index = self.source.findKind(expected, id) orelse {
            return if (self.source.find(id) != null) AssetError.WrongAssetKind else AssetError.AssetNotFound;
        };

        const record = created: {
            self.lock();
            defer self.unlock();

            if (self.shutting_down) return AssetError.LoadFailed;
            const entry = try self.assets.getOrPut(id);
            if (entry.found_existing) {
                if (entry.value_ptr.*.kind != expected) return AssetError.WrongAssetKind;
                return id;
            }
            errdefer _ = self.assets.remove(id);
            const new_record = try self.allocator.create(AssetRecord);
            new_record.* = .{ .id = id, .kind = expected, .index = index, .state = .queued };
            entry.value_ptr.* = new_record;
            self.pending_jobs += 1;
            break :created new_record;
        };

        // Submit outside the lock: the scheduler may run the job inline, and
        // the job takes the lock.
        const future = self.scheduler.trySubmit(LoadJob, .{
            .manager = self,
            .record = record,
        }, priority) catch |err| {
            self.lock();
            defer self.unlock();
            self.failRecordLocked(record, err);
            self.pending_jobs -= 1;
            return err;
        };
        // `deinit` awaits the future once `pending_jobs` drains. A loader
        // thread publishes here before its own job ends, so every future is
        // published by then.
        self.lock();
        defer self.unlock();
        record.load_future = future;
        return id;
    }

    /// Pumps until `id` is loaded or has failed, sleeping while only loader
    /// threads have work. Main thread only.
    pub fn wait(self: *AssetManager, id: AssetId) !void {
        while (true) {
            try self.pump();

            self.lock();
            defer self.unlock();
            const record = self.assets.get(id) orelse return AssetError.AssetNotFound;
            switch (record.state) {
                .loaded => return,
                .failed => return record.failure orelse AssetError.LoadFailed,
                .queued, .loading, .ready_for_finalize, .waiting => {
                    if (!self.hasMainThreadWorkLocked()) self.cond.waitUncancelable(self.io, &self.mutex);
                },
            }
        }
    }

    /// Finalizes every asset loaded since the last call, then retries the
    /// materials still waiting on dependencies if anything has finished
    /// since their last try. Cheap when there's nothing to do. Main thread only.
    pub fn pump(self: *AssetManager) !void {
        {
            self.lock();
            defer self.unlock();
            std.mem.swap(std.ArrayList(*AssetRecord), &self.ready, &self.ready_spare);
        }
        for (self.ready_spare.items) |record| self.finalize(record);
        self.ready_spare.clearRetainingCapacity();

        if (self.waiting.items.len == 0) return;
        const generation = blk: {
            self.lock();
            defer self.unlock();
            break :blk self.generation;
        };
        if (generation == self.waiting_generation) return;
        self.waiting_generation = generation;
        // `ready_spare` is empty here; borrow it so `finalize` can requeue
        // into `waiting`.
        std.mem.swap(std.ArrayList(*AssetRecord), &self.waiting, &self.ready_spare);
        for (self.ready_spare.items) |record| self.finalize(record);
        self.ready_spare.clearRetainingCapacity();
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

    /// True when `pump` has something to do. `wait` sleeps otherwise, and
    /// any change that creates such work bumps `generation` and wakes it.
    fn hasMainThreadWorkLocked(self: *const AssetManager) bool {
        return self.ready.items.len > 0 or
            (self.waiting.items.len > 0 and self.generation != self.waiting_generation);
    }

    fn processLoad(self: *AssetManager, record: *AssetRecord) void {
        self.lock();
        record.state = .loading;
        self.unlock();

        const prepared = self.prepare(record) catch |err| {
            log.err("failed to load {s} asset '{s}': {}", .{
                @tagName(record.kind),
                self.source.nameAt(record.index),
                err,
            });
            self.lock();
            defer self.unlock();
            self.failRecordLocked(record, err);
            self.pending_jobs -= 1;
            return;
        };

        self.lock();
        defer self.unlock();
        record.cooked = prepared.cooked;
        record.decoded_mesh = prepared.decoded_mesh;
        if (self.ready.append(self.allocator, record)) |_| {
            record.state = .ready_for_finalize;
            self.bumpLocked();
        } else |err| {
            self.failRecordLocked(record, err);
        }
        self.pending_jobs -= 1;
    }

    const Prepared = struct {
        cooked: zimp.runtime.Asset,
        decoded_mesh: ?Mesh.Decoded = null,
    };

    /// Loader-thread work: read and validate the asset, request what it
    /// references, and decode meshes so the main thread only uploads them.
    fn prepare(self: *AssetManager, record: *AssetRecord) !Prepared {
        var cooked = try self.loadCookedAsset(record);
        errdefer cooked.deinit(self.allocator);
        // Before decoding, so dependencies load while this thread decodes.
        try self.requestDependencies(&cooked.view);
        return .{
            .cooked = cooked,
            .decoded_mesh = switch (cooked.view) {
                .mesh => |*model| try Mesh.Decoded.init(self.allocator, model),
                else => null,
            },
        };
    }

    /// Requests everything `view` references, at high priority: work already
    /// started finishes before new top-level requests, so whole meshes
    /// become drawable sooner.
    fn requestDependencies(self: *AssetManager, view: *const zimp.runtime.AssetView) !void {
        switch (view.*) {
            .mesh => |*model| for (0..model.materialSlotCount()) |i| {
                _ = try self.requestKindById(.material, model.materialSlot(i), .high);
            },
            .material => |*material| {
                _ = try self.requestKindById(.shader_stage, material.vertex_shader, .high);
                _ = try self.requestKindById(.shader_stage, material.fragment_shader, .high);
                for (0..material.texture_slots.len) |i| {
                    _ = try self.requestKindById(.texture, material.textureSlot(i).texture, .high);
                }
            },
            .texture, .shader => {},
        }
    }

    fn loadCookedAsset(self: *AssetManager, record: *AssetRecord) !zimp.runtime.Asset {
        return self.source.load(self.allocator, self.io, record.index) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => AssetError.AssetNotFound,
            error.OutOfMemory => AssetError.OutOfMemory,
            else => err,
        };
    }

    /// Main thread: turns a loaded record into a finished asset, or parks it
    /// in `waiting` until its dependencies are loaded.
    fn finalize(self: *AssetManager, record: *AssetRecord) void {
        const result = self.finalizeRecord(record) catch |err| {
            log.err("failed to finalize {s} asset '{s}': {}", .{
                @tagName(record.kind),
                self.source.nameAt(record.index),
                err,
            });
            self.lock();
            defer self.unlock();
            self.failRecordLocked(record, err);
            return;
        };

        switch (result) {
            .loaded => |asset| {
                self.lock();
                defer self.unlock();
                record.asset = asset;
                record.state = .loaded;
                record.failure = null;
                self.bumpLocked();
            },
            .waiting => {
                self.waiting.append(self.allocator, record) catch |err| {
                    self.lock();
                    defer self.unlock();
                    self.failRecordLocked(record, err);
                    return;
                };
                self.lock();
                defer self.unlock();
                record.state = .waiting;
            },
        }
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
        var decoded = record.decoded_mesh orelse return AssetError.LoadFailed;
        record.decoded_mesh = null;
        defer decoded.deinit(self.allocator);

        const cooked_mesh = switch (cooked_asset.view) {
            .mesh => |mesh| mesh,
            else => return AssetError.WrongAssetKind,
        };

        const mesh = try self.allocator.create(Mesh);
        errdefer self.allocator.destroy(mesh);

        const material_ids = try self.requestMeshMaterials(&cooked_mesh);
        errdefer self.allocator.free(material_ids);

        mesh.* = try Mesh.upload(self.allocator, self.device, &cooked_mesh, &decoded, material_ids);
        errdefer mesh.deinit();

        return mesh;
    }

    fn finalizeTexture(self: *AssetManager, record: *AssetRecord) !*TextureAsset {
        var cooked_asset = try takeCooked(record);
        defer cooked_asset.deinit(self.allocator);

        const cooked_texture = switch (cooked_asset.view) {
            .texture => |texture| texture,
            else => return AssetError.WrongAssetKind,
        };
        if (cooked_texture.texture_type != .texture_2d) return AssetError.UnsupportedTextureType;

        var mips: std.ArrayList(RhiTexture.MipData) = .empty;
        defer mips.deinit(self.allocator);
        try mips.ensureTotalCapacityPrecise(self.allocator, cooked_texture.mips.len);
        for (0..cooked_texture.mips.len) |level| {
            const extent = cooked_texture.mipExtent(level);
            mips.appendAssumeCapacity(.{ .extent = .{ .width = extent.width, .height = extent.height }, .bytes = cooked_texture.mipData(level) });
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

    fn finalizeShaderStage(self: *AssetManager, record: *AssetRecord) !*zimp.runtime.Asset {
        var cooked_asset = try takeCooked(record);
        errdefer cooked_asset.deinit(self.allocator);

        if (cooked_asset.view != .shader) return AssetError.WrongAssetKind;

        const shader_ptr = try self.allocator.create(zimp.runtime.Asset);
        shader_ptr.* = cooked_asset;
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

        var cooked_asset = record.cooked orelse return AssetError.LoadFailed;
        record.cooked = null;

        if (cooked_asset.view != .material) {
            cooked_asset.deinit(self.allocator);
            return AssetError.WrongAssetKind;
        }
        var source_owned = true;
        errdefer if (source_owned) cooked_asset.deinit(self.allocator);

        const texture_slice = try texture_bindings.toOwnedSlice(self.allocator);
        var texture_slice_owned = true;
        errdefer if (texture_slice_owned) self.allocator.free(texture_slice);

        const material = try self.allocator.create(Material);
        errdefer self.allocator.destroy(material);
        material.* = try Material.init(
            self.allocator,
            cooked_asset,
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
        return self.loadGraphicsPipelineReady(
            material_source.vertex_shader,
            material_source.fragment_shader,
            material_source.variant_hashes,
            render_state.FixedState.generate(material_source.render_state),
        );
    }

    fn materialTexturesReady(
        self: *AssetManager,
        material_source: *const zimp.Zamat,
        out_bindings: *std.ArrayList(Material.TextureBinding),
    ) !bool {
        try out_bindings.ensureTotalCapacityPrecise(self.allocator, material_source.texture_slots.len);
        for (0..material_source.texture_slots.len) |texture_unit| {
            const slot = material_source.textureSlot(texture_unit);
            const texture_id = try self.requestKindById(.texture, slot.texture, .high);
            const texture_asset = try self.loadedAsset(texture_id, .texture) orelse return false;
            const texture = texture_asset.texture;
            out_bindings.appendAssumeCapacity(.{
                .unit = @intCast(texture_unit),
                .view = texture.view,
                .sampler = try self.sampler_cache.get(self.device, Sampler.Desc.fromSamplerDesc(slot.sampler)),
                .name_hash = slot.name_hash,
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
            source.materialSlotCount(),
        );
        errdefer self.allocator.free(ids);

        for (ids, 0..) |*id, i| {
            id.* = try self.requestKindById(.material, source.materialSlot(i), .high);
        }

        return ids;
    }

    fn loadGraphicsPipelineReady(
        self: *AssetManager,
        vertex_shader: AssetId,
        fragment_shader: AssetId,
        /// Sorted `zimp.nameHash`es of the variants to enable, as a material stores them.
        variant_hashes: []const u64,
        fixed_state: render_state.FixedState,
    ) !?GraphicsPipeline {
        const vertex_id = try self.requestKindById(.shader_stage, vertex_shader, .high);
        const fragment_id = try self.requestKindById(.shader_stage, fragment_shader, .high);
        const vertex_asset = try self.loadedAsset(vertex_id, .shader_stage) orelse return null;
        const fragment_asset = try self.loadedAsset(fragment_id, .shader_stage) orelse return null;
        const vertex_stage = &vertex_asset.shader_stage.view.shader;
        const fragment_stage = &fragment_asset.shader_stage.view.shader;

        if (vertex_stage.stage != .vertex or fragment_stage.stage != .fragment) {
            return AssetError.WrongAssetKind;
        }

        const vertex_variant = vertex_stage.variantKeyFromHashes(variant_hashes);
        const fragment_variant = fragment_stage.variantKeyFromHashes(variant_hashes);

        const key: PipelineKey = .{
            .vertex_shader = vertex_id,
            .vertex_variant = vertex_variant,
            .fragment_shader = fragment_id,
            .fragment_variant = fragment_variant,
            .fixed_state = fixed_state,
        };
        const entry = try self.graphics_pipelines.getOrPut(key);
        if (entry.found_existing) return entry.value_ptr.*;
        errdefer _ = self.graphics_pipelines.remove(key);
        entry.value_ptr.* = try createGraphicsPipeline(
            self.device,
            vertex_stage,
            vertex_variant,
            fragment_stage,
            fragment_variant,
            fixed_state,
        );
        return entry.value_ptr.*;
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
        record.freeLoaded(self.allocator);
        record.failure = err;
        record.state = .failed;
        self.bumpLocked();
    }

    fn bumpLocked(self: *AssetManager) void {
        self.generation +%= 1;
        self.cond.broadcast(self.io);
    }

    fn lock(self: *AssetManager) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *AssetManager) void {
        self.mutex.unlock(self.io);
    }
};

fn cookedMaterialSource(record: *AssetRecord) !*const zimp.Zamat {
    const cooked = if (record.cooked) |*cooked| cooked else return AssetError.LoadFailed;
    return switch (cooked.view) {
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
        .rgb9e5 => .rgb9e5_ufloat,
        .bc1 => if (color_space == .srgb) .bc1_srgb else .bc1_unorm,
        .bc3 => if (color_space == .srgb) .bc3_srgb else .bc3_unorm,
        .bc4 => .bc4_unorm,
        .bc5 => .bc5_unorm,
        .bc6h => .bc6h_ufloat,
        .bc7 => if (color_space == .srgb) .bc7_srgb else .bc7_unorm,
    };
}

/// Leaves a core for the main thread. Loading all of example-game's default
/// (zstd) pack on an 8-core M2 took 43 ms on 4 threads, 34 ms on 6, and no
/// less beyond; an uncompressed pack is page-fault bound and peaks at 4
/// (1.4 ms vs 2.5 ms on 6). Packs compress by default, so the cap is 6.
fn defaultLoadConcurrency() usize {
    const cpu_count = std.Thread.getCpuCount() catch 2;
    if (cpu_count <= 1) return 1;
    return @min(cpu_count - 1, 6);
}

fn createGraphicsPipeline(
    device: *Device,
    vertex_stage: *const zimp.ZShader,
    vertex_variant: zimp.VariantKey,
    fragment_stage: *const zimp.ZShader,
    fragment_variant: zimp.VariantKey,
    fixed_state: render_state.FixedState,
) !GraphicsPipeline {
    var vertex_parts: zimp.ZShader.SourceParts = undefined;
    var fragment_parts: zimp.ZShader.SourceParts = undefined;
    return device.createGraphicsPipeline(.{
        .vertex = .{ .glsl = try vertex_stage.sourceParts(vertex_variant, &vertex_parts) },
        .fragment = .{ .glsl = try fragment_stage.sourceParts(fragment_variant, &fragment_parts) },
        .fixed_state = fixed_state,
    });
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

const test_vertex_id = AssetId.parseComptime("8c1d6602-b3f4-4910-9c44-4b7e9b1a2f6c");
const test_fragment_id = AssetId.parseComptime("12345678-9abc-4def-8012-3456789abcde");

const test_fixed_state: render_state.FixedState = .{
    .depth_test = true,
    .depth_write = true,
    .cull_mode = .back,
    .blend_mode = .disabled,
};

test "PipelineKey tells stages, variants, and fixed state apart" {
    var pipelines = std.AutoHashMap(PipelineKey, u32).init(std.testing.allocator);
    defer pipelines.deinit();

    const base: PipelineKey = .{
        .vertex_shader = test_vertex_id,
        .vertex_variant = .base,
        .fragment_shader = test_fragment_id,
        .fragment_variant = .base,
        .fixed_state = test_fixed_state,
    };
    try pipelines.put(base, 0);

    var variant = base;
    variant.fragment_variant = .fromBits(1);
    try pipelines.put(variant, 1);

    var fixed_state = base;
    fixed_state.fixed_state.depth_write = false;
    try pipelines.put(fixed_state, 2);

    var stages = base;
    stages.vertex_shader = test_fragment_id;
    stages.fragment_shader = test_vertex_id;
    try pipelines.put(stages, 3);

    try std.testing.expectEqual(@as(u32, 4), pipelines.count());
    var same = base;
    same.fixed_state = test_fixed_state;
    try std.testing.expectEqual(@as(?u32, 0), pipelines.get(same));
}

fn writeTestShader(buf: []align(16) u8, stage: zimp.ShaderStage, variant_names: []const []const u8) ![]align(16) const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try zimp.formats.zshdr.write(&writer, .{
        .stage = stage,
        .variant_names = variant_names,
        .prologue = "#version 330 core\n",
        .body = "void main(){}\n",
    });
    return buf[0..writer.end];
}

test "material variant hashes select only variants declared by each stage" {
    var vertex_buf: [512]u8 align(16) = undefined;
    var fragment_buf: [512]u8 align(16) = undefined;
    const vertex_stage = try zimp.ZShader.view(try writeTestShader(&vertex_buf, .vertex, &.{"SKINNED"}));
    const fragment_stage = try zimp.ZShader.view(try writeTestShader(&fragment_buf, .fragment, &.{ "HAS_ALBEDO_MAP", "ALPHA_TEST" }));
    var required = [_]u64{ zimp.nameHash("SKINNED"), zimp.nameHash("ALPHA_TEST") };
    std.mem.sort(u64, &required, {}, std.sort.asc(u64));

    try std.testing.expectEqual(zimp.VariantKey.fromBits(1), vertex_stage.variantKeyFromHashes(&required));
    try std.testing.expectEqual(zimp.VariantKey.fromBits(2), fragment_stage.variantKeyFromHashes(&required));
}

const testing = std.testing;

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

    try testing.expectEqual(source_mod.AssetSource.loose, std.meta.activeTag(manager.source));
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

const PackItem = struct { id: AssetId, kind: AssetKind, bytes: []const u8 };

/// Items must be in (kind, id) order.
fn writeTestPack(dir: std.Io.Dir, sub_path: []const u8, items: []const PackItem) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer = try zimp.formats.zpak.Writer.init(testing.allocator, &out.writer);
    defer writer.deinit();
    for (items, 0..) |item, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "assets/{d}", .{i});
        try writer.add(.{ .id = item.id, .kind = item.kind, .name = name, .payload = .{ .none = item.bytes } });
    }
    const header = try writer.finish();
    const written = out.written();
    @memcpy(written[0..@sizeOf(zimp.formats.zpak.Header)], std.mem.asBytes(&header));
    try dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = written });
}

fn writeTestMaterial(buf: []align(16) u8, vertex_shader: AssetId, fragment_shader: AssetId) ![]align(16) const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try zimp.formats.zamat.write(&writer, .{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .render_state = .{},
        .texture_slots = &.{},
        .params = &.{},
        .variant_hashes = &.{},
    });
    return buf[0..writer.end];
}

fn writeTestMesh(buf: []align(16) u8, material: AssetId) ![]align(16) const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try zimp.formats.zmesh.writeTestZmeshFileWithMaterial(&writer, material);
    return buf[0..writer.end];
}

fn waitForLoads(manager: *AssetManager) void {
    manager.lock();
    defer manager.unlock();
    while (manager.pending_jobs > 0) manager.cond.waitUncancelable(manager.io, &manager.mutex);
}

const test_material_id = AssetId.parseComptime("c0ffee00-0000-4000-8000-000000000001");
const test_mesh_id = AssetId.parseComptime("c0ffee00-0000-4000-8000-000000000002");

/// A pack holding a mesh, its material, and the material's two shaders.
const MeshPack = struct {
    tmp: std.testing.TmpDir,
    project: Project,
    device: Device,

    fn init(mesh_material: AssetId) !MeshPack {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var project = try testProject(&tmp);
        errdefer project.deinit(testing.allocator, testing.io);
        project.asset_source = .pack;

        var mesh_buf: [4096]u8 align(16) = undefined;
        var vertex_buf: [512]u8 align(16) = undefined;
        var fragment_buf: [512]u8 align(16) = undefined;
        var material_buf: [512]u8 align(16) = undefined;
        // (kind, id) order: mesh, then shader stages by id, then the material.
        try writeTestPack(tmp.dir, project.manifest.assetPackPath(), &.{
            .{ .id = test_mesh_id, .kind = .mesh, .bytes = try writeTestMesh(&mesh_buf, mesh_material) },
            .{ .id = test_fragment_id, .kind = .shader_stage, .bytes = try writeTestShader(&fragment_buf, .fragment, &.{}) },
            .{ .id = test_vertex_id, .kind = .shader_stage, .bytes = try writeTestShader(&vertex_buf, .vertex, &.{}) },
            .{ .id = test_material_id, .kind = .material, .bytes = try writeTestMaterial(&material_buf, test_vertex_id, test_fragment_id) },
        });
        return .{ .tmp = tmp, .project = project, .device = try device_factory.init(testing.allocator, .opengl) };
    }

    fn deinit(self: *MeshPack) void {
        self.device.deinit();
        self.project.deinit(testing.allocator, testing.io);
        self.tmp.cleanup();
    }
};

test "loader threads request a mesh's whole dependency tree without the main thread" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture = try MeshPack.init(test_material_id);
    defer fixture.deinit();
    var manager = try AssetManager.init(testing.allocator, testing.io, &fixture.project, &fixture.device);
    defer manager.deinit();

    _ = try manager.registerId(Mesh, test_mesh_id);
    waitForLoads(&manager);

    // No `pump` has run, yet the material and both shaders were loaded.
    for ([_]AssetId{ test_material_id, test_vertex_id, test_fragment_id }) |id| {
        try testing.expectEqual(Availability.pending, manager.availability(id));
    }
    manager.lock();
    defer manager.unlock();
    try testing.expectEqual(@as(usize, 4), manager.ready.items.len);
    for (manager.ready.items) |record| {
        try testing.expectEqual(AssetState.ready_for_finalize, record.state);
        // Mesh streams were decoded on the loader thread.
        try testing.expectEqual(record.kind == .mesh, record.decoded_mesh != null);
    }
}

test "a mesh whose material is missing fails on the loader thread" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture = try MeshPack.init(AssetId.parseComptime("deadbeef-0000-4000-8000-000000000000"));
    defer fixture.deinit();
    var manager = try AssetManager.init(testing.allocator, testing.io, &fixture.project, &fixture.device);
    defer manager.deinit();

    const id = try manager.registerId(Mesh, test_mesh_id);
    try testing.expectError(AssetError.AssetNotFound, manager.wait(id));
}

test "deinit waits for loads that are still requesting dependencies" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture = try MeshPack.init(test_material_id);
    defer fixture.deinit();
    for (0..20) |_| {
        var manager = try AssetManager.init(testing.allocator, testing.io, &fixture.project, &fixture.device);
        _ = try manager.registerId(Mesh, test_mesh_id);
        manager.deinit();
    }
}

test "pack mode loads assets from the project's pack" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProject(&tmp);
    defer project.deinit(testing.allocator, testing.io);
    project.asset_source = .pack;

    var shader_buf: [512]u8 align(16) = undefined;
    const shader = try writeTestShader(&shader_buf, .vertex, &.{});
    try writeTestPack(tmp.dir, project.manifest.assetPackPath(), &.{.{ .id = test_vertex_id, .kind = .shader_stage, .bytes = shader }});

    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();
    var manager = try AssetManager.init(testing.allocator, testing.io, &project, &device);
    defer manager.deinit();
    try testing.expectEqual(source_mod.AssetSource.pack, std.meta.activeTag(manager.source));

    const id = try manager.registerId(zimp.ZShader, test_vertex_id);
    try manager.wait(id);
    try testing.expectEqual(Availability.loaded, manager.availability(id));

    // The loose manifest isn't consulted in pack mode.
    try testing.expectError(AssetError.AssetNotFound, manager.registerId(Mesh, mesh_manifest_id));
    try testing.expectError(AssetError.WrongAssetKind, manager.registerId(Mesh, test_vertex_id));
}

test "pack mode fails to init without a pack" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProject(&tmp);
    defer project.deinit(testing.allocator, testing.io);
    project.asset_source = .pack;
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();

    try testing.expectError(error.FileNotFound, AssetManager.init(testing.allocator, testing.io, &project, &device));
}
