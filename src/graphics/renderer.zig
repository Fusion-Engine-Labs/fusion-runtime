const zimp = @import("zimp");
const std = @import("std");
const zcs = @import("zcs");

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const GraphicsPipeline = @import("rhi/graphics_pipeline.zig");
const render_submission = @import("render_submission.zig");
const camera_system = @import("../scene/camera.zig");
const device_factory = @import("device_factory.zig");
const components = @import("../ecs/components.zig");
const render_state = @import("render_state.zig");
const Collector = @import("stats_collector.zig");
const DebugStats = @import("debug_stats.zig");
const Device = @import("rhi/device.zig");
const Material = @import("material.zig");
const math = @import("../core/math.zig");
const ecs = @import("../ecs/world.zig");
const log = @import("../core/log.zig");
const Mesh = @import("mesh.zig");

const DrawItem = render_submission.DrawItem;

const Renderer = @This();

pub const RenderViewport = Device.RenderViewport;
pub const RenderTarget = Device.RenderTarget;

device: Device,
submissions: std.ArrayList(DrawItem) = .empty,
stats: Collector = .{},
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, backend: device_factory.Backend) !Renderer {
    return .{
        .allocator = allocator,
        .device = try device_factory.init(allocator, backend),
    };
}

pub fn render(self: *Renderer, world: *zcs.World, assets: *AssetManager, target: RenderTarget) !void {
    const viewport = target.viewport();
    self.stats.beginGpuTimer(&self.device);
    defer self.stats.endGpuTimer(&self.device);

    self.submissions.clearRetainingCapacity();
    try self.renderWorld(world, assets, target, viewport);
}

fn renderWorld(self: *Renderer, world: *zcs.World, assets: *AssetManager, target: RenderTarget, viewport: RenderViewport) !void {
    try self.device.beginRenderPass(.{
        .target = target,
        .color = .{ .clear = .{ 0.4, 0.4, 0.4, 1 } },
        .depth = .{ .clear = 1 },
    });
    defer self.device.endRenderPass();

    const camera_entity = camera_system.active(world) orelse {
        log.warn("Skipping scene render: no active camera", .{});
        return;
    };

    try self.renderFromCamera(world, assets, viewport, camera_entity);
}

pub fn setDebugStatsEnabled(self: *Renderer, enabled: bool) void {
    self.stats.setEnabled(enabled);
}

pub fn debugStats(self: *const Renderer) ?DebugStats {
    return self.stats.snapshot();
}

pub fn recordCpuFrame(self: *Renderer, delta_time: f32, elapsed_ms: f32) void {
    self.stats.recordCpuFrame(delta_time, elapsed_ms);
}

pub fn deinit(self: *Renderer) void {
    self.submissions.deinit(self.allocator);
    self.device.deinit();

    self.* = undefined;
}

fn gatherDrawItems(self: *Renderer, world: *zcs.World, assets: *AssetManager, camera: *const components.CameraComponent, view: math.Mat4) !void {
    var iter = world.query(.{
        .read = &.{ components.TransformComponent, components.MeshRenderComponent },
    });

    var cached_material_id: ?zimp.AssetId = null;
    var cached_material: *const Material = undefined;

    while (iter.each()) |row| {
        const transform = row.read(components.TransformComponent);
        const target = row.read(components.MeshRenderComponent);

        const model = transform.modelMatrix();
        const mesh = assets.get(Mesh, target.mesh) orelse {
            switch (assets.availability(target.mesh)) {
                .pending => {},
                .missing, .failed => {
                    log.err("mesh asset {f} is missing or failed to load", .{target.mesh});
                },
                .loaded => unreachable,
            }
            continue;
        };

        for (mesh.parts) |*part| {
            const final_model = part.transform.mul(model);

            for (part.submeshes) |*submesh| {
                const material_id = mesh.materialIdForSlot(submesh.material_index) orelse {
                    log.err("mesh submesh references invalid material slot {d}", .{submesh.material_index});
                    continue;
                };

                const material = blk: {
                    if (cached_material_id) |cached_id| {
                        if (cached_id.eql(material_id)) {
                            break :blk cached_material;
                        }
                    }

                    const looked_up = assets.get(Material, material_id) orelse {
                        switch (assets.availability(material_id)) {
                            .pending => {},
                            .missing, .failed => {
                                log.err("material asset {f} is missing or failed to load", .{material_id});
                            },
                            .loaded => unreachable,
                        }
                        continue;
                    };
                    cached_material_id = material_id;
                    cached_material = looked_up;
                    break :blk looked_up;
                };

                const state = material.source.render_state;

                try self.submissions.append(self.allocator, .{
                    .part = part,
                    .submesh = submesh,
                    .material_id = material_id,
                    .material = material,
                    .model = final_model,
                    .depth_key = camera.calculateDepth(
                        final_model,
                        view,
                        part.bounds_min,
                        part.bounds_max,
                    ),
                    .phase = state.alpha_mode,
                    .pipeline_key = material.pipeline.sort_key,
                });
            }
        }
    }
}

fn renderFromCamera(self: *Renderer, world: *zcs.World, assets: *AssetManager, viewport: RenderViewport, camera_entity: ecs.EntityID) !void {
    const camera = world.getComponent(camera_entity, components.CameraComponent) orelse {
        return error.InvalidCamera;
    };

    const camera_transform = world.getComponent(camera_entity, components.TransformComponent) orelse {
        return error.InvalidCamera;
    };

    const view = camera.viewMatrix(camera_transform);
    const projection = camera.projectionMatrix(viewport.aspect());

    try self.gatherDrawItems(world, assets, camera, view);
    // Items that compare equal share pipeline, material and depth, so their
    // relative order does not matter; pdq beats a stable sort on items this wide.
    std.sort.pdq(DrawItem, self.submissions.items, {}, DrawItem.lessThan);

    self.renderQueue(view, projection, camera_transform.position);
}

fn renderQueue(self: *Renderer, view: math.Mat4, projection: math.Mat4, camera_pos: math.Vec3) void {
    var bound_pipeline: ?u64 = null;
    var bound_material: ?*const Material = null;
    var model_location: ?GraphicsPipeline.UniformLocation = null;
    var normal_matrix_location: ?GraphicsPipeline.UniformLocation = null;
    var uv_min_location: ?GraphicsPipeline.UniformLocation = null;
    var uv_scale_location: ?GraphicsPipeline.UniformLocation = null;
    var pos_min_location: ?GraphicsPipeline.UniformLocation = null;
    var pos_scale_location: ?GraphicsPipeline.UniformLocation = null;

    // Uniform values are per-program state, so these caches are only valid while
    // the same pipeline stays bound and are cleared on every pipeline switch.
    var uploaded_model: ?math.Mat4 = null;
    var uploaded_part: ?*const Mesh.Part = null;

    for (self.submissions.items) |draw_item| {
        const pipeline = draw_item.material.pipeline;

        if (bound_pipeline != pipeline.sort_key) {
            self.device.bindGraphicsPipeline(pipeline);
            bound_pipeline = pipeline.sort_key;

            // Lookups are by name hash. zimp's material cooker checks these
            // names for hash collisions (`runtime_uniform_names`), so keep the
            // two lists in sync.
            model_location = self.device.graphicsPipelineUniformLocation(pipeline, "u_model");
            normal_matrix_location = self.device.graphicsPipelineUniformLocation(pipeline, "u_normal_matrix");
            uv_min_location = self.device.graphicsPipelineUniformLocation(pipeline, "u_uv0_min");
            uv_scale_location = self.device.graphicsPipelineUniformLocation(pipeline, "u_uv0_scale");
            pos_min_location = self.device.graphicsPipelineUniformLocation(pipeline, "u_pos_min");
            pos_scale_location = self.device.graphicsPipelineUniformLocation(pipeline, "u_pos_scale");

            self.device.setGraphicsPipelineUniformByName(pipeline, "u_view", .{ .mat4 = view.fields });
            self.device.setGraphicsPipelineUniformByName(pipeline, "u_projection", .{ .mat4 = projection.fields });
            self.device.setGraphicsPipelineUniformByName(pipeline, "u_camera_pos", .{
                .vec3 = .{ camera_pos.x, camera_pos.y, camera_pos.z },
            });

            bound_material = null;
            uploaded_model = null;
            uploaded_part = null;
        }

        if (bound_material != draw_item.material) {
            draw_item.material.bindResources();
            bound_material = draw_item.material;
        }

        // A part's submeshes share one model matrix, so the inverse-transpose
        // behind `normalMatrix` only has to run when the transform changes.
        if (uploaded_model == null or !std.meta.eql(uploaded_model.?.fields, draw_item.model.fields)) {
            if (model_location) |location| {
                self.device.setGraphicsPipelineUniform(pipeline, location, .{ .mat4 = draw_item.model.fields });
            }

            if (normal_matrix_location) |location| {
                self.device.setGraphicsPipelineUniform(pipeline, location, .{ .mat3 = math.normalMatrix(draw_item.model).fields });
            }

            uploaded_model = draw_item.model;
        }

        // Position and UV dequantization are properties of the part, shared
        // by its submeshes. They stay out of `u_model`: the position scale is
        // non-uniform and would skew `u_normal_matrix`.
        if (uploaded_part != draw_item.part) {
            if (pos_min_location) |location| {
                self.device.setGraphicsPipelineUniform(pipeline, location, .{ .vec3 = draw_item.part.bounds_min });
            }

            if (pos_scale_location) |location| {
                self.device.setGraphicsPipelineUniform(pipeline, location, .{ .vec3 = draw_item.part.pos_scale });
            }

            if (uv_min_location) |location| {
                self.device.setGraphicsPipelineUniform(pipeline, location, .{ .vec2 = draw_item.part.uv_min });
            }

            if (uv_scale_location) |location| {
                self.device.setGraphicsPipelineUniform(pipeline, location, .{ .vec2 = draw_item.part.uv_scale });
            }

            uploaded_part = draw_item.part;
        }

        self.device.drawIndexed(draw_item.part.geometry, draw_item.submesh.index_offset, draw_item.submesh.index_count, draw_item.part.base_vertex);
    }
}

test "render viewport aspect guards against zero height" {
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), (Renderer.RenderViewport{ .width = 1920, .height = 1080 }).aspect(), 0.0001);
    try std.testing.expectEqual(@as(f32, 640.0), (Renderer.RenderViewport{ .width = 640, .height = 0 }).aspect());
}
