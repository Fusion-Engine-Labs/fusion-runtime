const std = @import("std");

const id_types = @import("zimp").id.types;
const scene = @import("zimp").scene;

const math = @import("../core/math.zig");

const AssetId = id_types.AssetId;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Vec3 = math.Vec3;

pub const TransformComponent = struct {
    rotation: Quat = Quat.identity,
    position: Vec3 = Vec3.zero,
    scale: Vec3 = Vec3.one,

    pub const schema_meta = scene.SchemaMeta{
        .id = "7fb84f38-52b6-4fd9-8c2f-fbd08c7a9001",
        .name = "fusion.runtime.transform",
        .display_name = "Transform",
        .version = 1,
        .fields = &.{
            .{ .name = "position", .number = 1, .display_name = "Position" },
            .{ .name = "rotation", .number = 2, .display_name = "Rotation" },
            .{ .name = "scale", .number = 3, .display_name = "Scale" },
        },
    };

    pub fn modelMatrix(self: *const TransformComponent) Mat4 {
        const r = self.rotation.toMat4().fields;
        return .{ .fields = .{
            .{ r[0][0] * self.scale.x, r[0][1] * self.scale.x, r[0][2] * self.scale.x, 0 },
            .{ r[1][0] * self.scale.y, r[1][1] * self.scale.y, r[1][2] * self.scale.y, 0 },
            .{ r[2][0] * self.scale.z, r[2][1] * self.scale.z, r[2][2] * self.scale.z, 0 },
            .{ self.position.x, self.position.y, self.position.z, 1 },
        } };
    }

    pub fn forward(self: *const TransformComponent) Vec3 {
        return self.rotation.rotateVec3(Vec3.new(0, 0, -1));
    }

    pub fn right(self: *const TransformComponent) Vec3 {
        return self.rotation.rotateVec3(Vec3.new(1, 0, 0));
    }

    pub fn up(self: *const TransformComponent) Vec3 {
        return self.rotation.rotateVec3(Vec3.new(0, 1, 0));
    }
};

pub const MeshRenderComponent = struct {
    mesh: AssetId,

    pub const schema_meta = scene.SchemaMeta{
        .id = "7fb84f38-52b6-4fd9-8c2f-fbd08c7a9002",
        .name = "fusion.runtime.mesh.render",
        .display_name = "Mesh",
        .version = 1,
        .fields = &.{
            .{
                .name = "mesh",
                .number = 1,
                .display_name = "Mesh",
                .kind_override = .{ .asset_ref = .mesh },
                .default_override = .{ .asset_ref = AssetId.zero },
            },
        },
    };
};

pub const CameraComponent = struct {
    fov: f32 = std.math.pi / 4.0,
    far: f32 = 1000.0,
    near: f32 = 0.1,

    pub const schema_meta = scene.SchemaMeta{
        .id = "7fb84f38-52b6-4fd9-8c2f-fbd08c7a9003",
        .name = "fusion.runtime.camera",
        .display_name = "Camera",
        .version = 1,
        .fields = &.{
            .{ .name = "fov", .number = 1, .display_name = "Field Of View", .editor = .{ .min = 0.01, .max = 3.1, .slider = true } },
            .{ .name = "near", .number = 2, .display_name = "Near Plane", .editor = .{ .min = 0.001 } },
            .{ .name = "far", .number = 3, .display_name = "Far Plane", .editor = .{ .min = 0.01 } },
        },
    };

    pub fn projectionMatrix(self: *const CameraComponent, aspect: f32) Mat4 {
        return Mat4.createPerspective(self.fov, aspect, self.near, self.far);
    }

    pub fn viewMatrix(_: *const CameraComponent, transform: *const TransformComponent) Mat4 {
        return Mat4.createLookAt(
            transform.position,
            transform.position.add(transform.forward()),
            transform.up(),
        );
    }

    pub fn calculateDepth(_: *const CameraComponent, model: Mat4, view: Mat4, bounds_min: [3]f32, bounds_max: [3]f32) f32 {
        const local_center = boundsCenter(bounds_min, bounds_max);

        const world_center = local_center.transformPosition(model);
        const view_center = world_center.transformPosition(view);

        return -view_center.z;
    }
};

/// Marks the camera entity currently selected for rendering.
pub const ActiveCamera = struct {
    pub const schema_meta = scene.SchemaMeta{
        .id = "32ccdb02-85b1-4a9e-9db4-4034dc5679bf",
        .name = "fusion.runtime.active_camera",
        .display_name = "Active Camera",
        .version = 1,
        .fields = &.{},
    };
};

fn boundsCenter(min: [3]f32, max: [3]f32) Vec3 {
    return Vec3.new(
        (min[0] + max[0]) * 0.5,
        (min[1] + max[1]) * 0.5,
        (min[2] + max[2]) * 0.5,
    );
}

const expectApproxEq = std.testing.expectApproxEqAbs;
const tolerance: f32 = 1e-5;

fn expectVec3(expected: Vec3, actual: Vec3) !void {
    try expectApproxEq(expected.x, actual.x, tolerance);
    try expectApproxEq(expected.y, actual.y, tolerance);
    try expectApproxEq(expected.z, actual.z, tolerance);
}

test "TransformComponent defaults to an identity transform" {
    const t = TransformComponent{};
    try expectVec3(Vec3.zero, t.position);
    try expectVec3(Vec3.one, t.scale);
    try std.testing.expectEqual(Quat.identity, t.rotation);
}

test "TransformComponent basis vectors with identity rotation" {
    const t = TransformComponent{};
    try expectVec3(Vec3.new(0, 0, -1), t.forward());
    try expectVec3(Vec3.new(1, 0, 0), t.right());
    try expectVec3(Vec3.new(0, 1, 0), t.up());
}

test "TransformComponent basis vectors follow rotation" {
    // 90° right-handed rotation about +Y: forward(-Z) -> -X, right(+X) -> -Z, up unchanged.
    const t = TransformComponent{
        .rotation = Quat.fromAxisAngle(Vec3.new(0, 1, 0), std.math.pi / 2.0),
    };
    try expectVec3(Vec3.new(-1, 0, 0), t.forward());
    try expectVec3(Vec3.new(0, 0, -1), t.right());
    try expectVec3(Vec3.new(0, 1, 0), t.up());
}

test "modelMatrix maps the local origin to the world position" {
    // Regression guard for the S·R·T composition order: rotation and scale must
    // leave the origin fixed so it lands exactly on `position`.
    const t = TransformComponent{
        .position = Vec3.new(10, -3, 5),
        .rotation = Quat.fromAxisAngle(Vec3.new(0, 0, 1), std.math.pi / 2.0),
        .scale = Vec3.new(2, 2, 2),
    };
    try expectVec3(t.position, Vec3.zero.transformPosition(t.modelMatrix()));
}

test "modelMatrix applies scale then rotation then translation" {
    const t = TransformComponent{
        .position = Vec3.new(10, 0, 0),
        .rotation = Quat.fromAxisAngle(Vec3.new(0, 0, 1), std.math.pi / 2.0),
        .scale = Vec3.new(2, 3, 4),
    };
    // (1,0,0) -> scale -> (2,0,0) -> rotate 90° about Z -> (0,2,0) -> translate -> (10,2,0).
    const transformed = Vec3.new(1, 0, 0).transformPosition(t.modelMatrix());
    try expectVec3(Vec3.new(10, 2, 0), transformed);
}

test "modelMatrix with identity transform is the identity matrix" {
    const t = TransformComponent{};
    const v = Vec3.new(3, -7, 2);
    try expectVec3(v, v.transformPosition(t.modelMatrix()));
}

test "CameraComponent defaults match a standard perspective setup" {
    const camera = CameraComponent{};
    try expectApproxEq(@as(f32, std.math.pi / 4.0), camera.fov, tolerance);
    try expectApproxEq(@as(f32, 0.1), camera.near, tolerance);
    try expectApproxEq(@as(f32, 1000.0), camera.far, tolerance);
}

test "CameraComponent projectionMatrix matches createPerspective for its aspect" {
    const camera = CameraComponent{ .fov = 1.0, .near = 0.5, .far = 100.0 };
    const projection = camera.projectionMatrix(1.5);
    const expected = Mat4.createPerspective(1.0, 1.5, 0.5, 100.0);
    for (0..4) |row| {
        for (0..4) |col| {
            try expectApproxEq(expected.fields[row][col], projection.fields[row][col], tolerance);
        }
    }
}

test "CameraComponent viewMatrix looks along the transform forward axis" {
    const camera = CameraComponent{};
    const transform = TransformComponent{ .position = Vec3.new(0, 0, 5) };
    const view = camera.viewMatrix(&transform);
    const expected = Mat4.createLookAt(
        transform.position,
        transform.position.add(transform.forward()),
        transform.up(),
    );
    for (0..4) |row| {
        for (0..4) |col| {
            try expectApproxEq(expected.fields[row][col], view.fields[row][col], tolerance);
        }
    }
}
