const Texture = @import("../rhi/texture.zig");
const diagnostics = @import("diagnostics.zig");
const log = @import("../../core/log.zig");
const gl = @import("../../c.zig").glad;

const OpenGLTexture = @This();

// EXT_texture_compression_s3tc and its sRGB variants (EXT_texture_sRGB). Not
// core in any GL version, so glad's core header doesn't define them.
const GL_COMPRESSED_RGB_S3TC_DXT1_EXT = 0x83F0;
const GL_COMPRESSED_RGBA_S3TC_DXT5_EXT = 0x83F3;
const GL_COMPRESSED_SRGB_S3TC_DXT1_EXT = 0x8C4C;
const GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT = 0x8C4F;

id: u32,

pub fn init(desc: Texture.Desc) !OpenGLTexture {
    if (desc.mips.len == 0) {
        return error.InvalidMipChain;
    }

    diagnostics.clearPendingErrors("before creating texture");
    if (!supports(desc.format)) {
        return error.UnsupportedTextureFormat;
    }

    var id: u32 = 0;
    gl.glGenTextures(1, &id);
    if (id == 0) {
        return error.TextureCreationFailed;
    }
    errdefer gl.glDeleteTextures(1, &id);

    gl.glBindTexture(gl.GL_TEXTURE_2D, id);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_BASE_LEVEL, 0);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAX_LEVEL, @intCast(desc.mips.len - 1));
    for (desc.mips, 0..) |mip, level| {
        if (compressedInternalFormat(desc.format)) |internal| {
            gl.glCompressedTexImage2D(gl.GL_TEXTURE_2D, @intCast(level), internal, @intCast(mip.extent.width), @intCast(mip.extent.height), 0, @intCast(mip.bytes.len), mip.bytes.ptr);
        } else if (uploadFormat(desc.format)) |fmt| {
            gl.glTexImage2D(gl.GL_TEXTURE_2D, @intCast(level), @intCast(fmt.internal), @intCast(mip.extent.width), @intCast(mip.extent.height), 0, fmt.external, fmt.ty, mip.bytes.ptr);
        } else return error.UnsupportedTextureFormat;

        if (!diagnostics.checkError("uploading texture mip")) {
            return error.OpenGLError;
        }
    }
    return .{ .id = id };
}

pub fn deinit(self: *OpenGLTexture) void {
    gl.glDeleteTextures(1, &self.id);
    self.id = 0;
}

fn supports(format: Texture.Format) bool {
    if (isCoreFormat(format)) {
        return true;
    }

    const extension: ?[:0]const u8 = switch (format) {
        .bc1_unorm, .bc1_srgb, .bc3_unorm, .bc3_srgb => "GL_EXT_texture_compression_s3tc",
        .bc4_unorm, .bc5_unorm => "GL_ARB_texture_compression_rgtc",
        .bc6h_ufloat, .bc7_unorm, .bc7_srgb => "GL_ARB_texture_compression_bptc",
        else => null,
    };

    if (extension == null or diagnostics.hasExtension(extension.?)) {
        return true;
    }
    log.err("texture format '{s}' requires {s}", .{ @tagName(format), extension.? });
    return false;
}

fn isCoreFormat(format: Texture.Format) bool {
    return switch (format) {
        .bc4_unorm, .bc5_unorm => gl.GLAD_GL_VERSION_3_0 != 0,
        .bc6h_ufloat, .bc7_unorm, .bc7_srgb => gl.GLAD_GL_VERSION_4_2 != 0,
        .bc1_unorm, .bc1_srgb, .bc3_unorm, .bc3_srgb => false,
        else => true,
    };
}

pub const UploadFormat = struct {
    internal: u32,
    external: u32,
    ty: u32,
};

pub fn uploadFormat(format: Texture.Format) ?UploadFormat {
    return switch (format) {
        .r8_unorm => .{ .internal = gl.GL_R8, .external = gl.GL_RED, .ty = gl.GL_UNSIGNED_BYTE },
        .rg8_unorm => .{ .internal = gl.GL_RG8, .external = gl.GL_RG, .ty = gl.GL_UNSIGNED_BYTE },
        .rgba8_unorm => .{ .internal = gl.GL_RGBA8, .external = gl.GL_RGBA, .ty = gl.GL_UNSIGNED_BYTE },
        .rgba8_srgb => .{ .internal = gl.GL_SRGB8_ALPHA8, .external = gl.GL_RGBA, .ty = gl.GL_UNSIGNED_BYTE },
        .rgb16_float => .{ .internal = gl.GL_RGB16F, .external = gl.GL_RGB, .ty = gl.GL_HALF_FLOAT },
        .rgba16_float => .{ .internal = gl.GL_RGBA16F, .external = gl.GL_RGBA, .ty = gl.GL_HALF_FLOAT },
        .rgb9e5_ufloat => .{ .internal = gl.GL_RGB9_E5, .external = gl.GL_RGB, .ty = gl.GL_UNSIGNED_INT_5_9_9_9_REV },
        else => null,
    };
}

fn compressedInternalFormat(format: Texture.Format) ?u32 {
    return switch (format) {
        .bc1_unorm => GL_COMPRESSED_RGB_S3TC_DXT1_EXT,
        .bc1_srgb => GL_COMPRESSED_SRGB_S3TC_DXT1_EXT,
        .bc3_unorm => GL_COMPRESSED_RGBA_S3TC_DXT5_EXT,
        .bc3_srgb => GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT,
        .bc4_unorm => gl.GL_COMPRESSED_RED_RGTC1,
        .bc5_unorm => gl.GL_COMPRESSED_RG_RGTC2,
        .bc6h_ufloat => gl.GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT,
        .bc7_unorm => gl.GL_COMPRESSED_RGBA_BPTC_UNORM,
        .bc7_srgb => gl.GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM,
        else => null,
    };
}
