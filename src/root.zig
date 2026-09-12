pub const Application = @import("core/application.zig").Application;
pub const Runtime = @import("core/runtime.zig").Runtime;
pub const GraphicsPipeline = @import("graphics/rhi/graphics_pipeline.zig");
pub const TextureView = @import("graphics/rhi/texture_view.zig");
pub const Framebuffer = @import("graphics/rhi/framebuffer.zig");
pub const MouseButton = @import("core/event.zig").MouseButton;
pub const CursorKind = @import("core/window.zig").CursorKind;
pub const Geometry = @import("graphics/rhi/geometry.zig");
pub const Texture = @import("graphics/rhi/texture.zig");
pub const Sampler = @import("graphics/rhi/sampler.zig");
pub const Buffer = @import("graphics/rhi/buffer.zig");
pub const Device = @import("graphics/rhi/device.zig");
pub const Material = @import("graphics/material.zig");
pub const ZEvent = @import("core/event.zig").ZEvent;
pub const Key = @import("core/event.zig").Key;
pub const Window = @import("core/window.zig");
pub const Mesh = @import("graphics/mesh.zig");
pub const Input = @import("core/input.zig");
pub const Time = @import("core/time.zig");
pub const SimulationTime = Time.SimulationClock;

pub const AssetManager = @import("assets/asset_manager.zig").AssetManager;
pub const RuntimeAssetManifest = @import("assets/manifest.zig");
pub const AssetError = @import("assets/source.zig").AssetError;
pub const ComponentTypeId = zimp.ComponentTypeId;
pub const SceneEntityId = zimp.SceneEntityId;
pub const WatchHandle = zimp.WatchHandle;
pub const ProjectId = zimp.ProjectId;
pub const SchemaId = zimp.SchemaId;
pub const AssetId = zimp.AssetId;
pub const SceneId = zimp.SceneId;
pub const Uuid = zimp.Uuid;

const math = @import("core/math.zig");
pub const Vec3 = math.Vec3;
pub const Vec2 = math.Vec2;
pub const Mat4 = math.Mat4;
pub const Mat3 = math.Mat3;
pub const Mat2 = math.Mat2;
pub const Quat = math.Quat;

pub const scene_schema = struct {
    pub const ComponentCodec = @import("scene/component_codec.zig").ComponentCodec;
    pub const CodecError = @import("scene/component_codec.zig").CodecError;
    pub const SceneRuntimeInstance = @import("scene/runtime_instance.zig");
    pub const SchemaRegistry = @import("scene/schema_registry.zig");
    pub const LoadedScene = @import("scene/loaded_scene.zig");
    pub const SchemaMeta = zimp.scene.SchemaMeta;

    const derive_schema = @import("scene/derive_schema.zig");
    pub const deriveCodec = derive_schema.deriveCodec;
    pub const deriveSchema = derive_schema.deriveSchema;
};

const camera = @import("scene/camera.zig");

pub const setActiveCamera = camera.setActive;
pub const activeCamera = camera.active;
pub const ActiveCamera = @import("ecs/components.zig").ActiveCamera;

pub const ProjectManifest = zimp.ProjectManifest;
pub const Project = @import("project/project.zig");
pub const openProject = @import("project/open.zig").open;

pub const Renderer = @import("graphics/renderer.zig");
pub const RenderQueue = @import("graphics/render_submission.zig");
pub const RenderState = @import("graphics/render_state.zig");
pub const RenderViewport = Renderer.RenderViewport;
pub const RenderTarget = Renderer.RenderTarget;
pub const DebugStats = @import("graphics/debug_stats.zig");
pub const Game = @import("core/game.zig");

pub const components = @import("ecs/components.zig");
pub const World = @import("ecs/world.zig");

const zimp = @import("zimp");
const zcs = @import("zcs");

pub const EcsWorld = zcs.World;
pub const EntityID = zcs.EntityID;
pub const FrameCount = zcs.FrameCount;
pub const DeltaTime = zcs.DeltaTime;
pub const CommandBuffer = zcs.CommandBuffer;
pub const Schedule = zcs.Schedule;
pub const ZShader = zimp.ZShader;
pub const ZMesh = zimp.ZMesh;
pub const Zatex = zimp.Zatex;
pub const Zamat = zimp.Zamat;
pub const RawTexture = zimp.assets.raw.texture.RawTexture;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ecs/world.zig");
    _ = @import("core/time.zig");
    _ = @import("core/math.zig");
    _ = @import("core/event.zig");
    _ = @import("core/input.zig");
    _ = @import("scene/camera.zig");
    _ = @import("scene/component_codec.zig");
    _ = @import("scene/derive_schema.zig");
    _ = @import("scene/schema_registry.zig");
    _ = @import("assets/source.zig");
    _ = @import("assets/manifest.zig");
    _ = @import("ecs/components.zig");
    _ = @import("assets/asset_manager.zig");
    _ = @import("core/runtime.zig");
    _ = @import("graphics/opengl/framebuffer.zig");
    _ = @import("graphics/opengl/buffer.zig");
    _ = @import("graphics/opengl/diagnostics.zig");
    _ = @import("graphics/opengl/graphics_pipeline.zig");
    _ = @import("graphics/rhi/device.zig");
    _ = @import("graphics/device_factory.zig");
    _ = @import("graphics/rhi/resource_pool.zig");
    _ = @import("graphics/rhi/resource_handle.zig");
    _ = @import("graphics/rhi/texture.zig");
    _ = @import("graphics/rhi/texture_view.zig");
    _ = @import("graphics/rhi/sampler.zig");
    _ = @import("graphics/rhi/buffer.zig");
    _ = @import("graphics/rhi/geometry.zig");
    _ = @import("graphics/opengl/texture.zig");
    _ = @import("graphics/opengl/sampler.zig");
    _ = @import("graphics/opengl/geometry.zig");
    _ = @import("graphics/stats_collector.zig");
    _ = @import("graphics/debug_stats.zig");
    _ = @import("graphics/layout.zig");
    _ = @import("project/project.zig");
    _ = @import("project/open.zig");
}
