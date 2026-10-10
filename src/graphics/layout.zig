const std = @import("std");

pub const StreamAttribute = struct {
    location: u32,
    data_type: DataType,
    normalized: bool,
};

pub const DataType = enum {
    Float,
    Float2,
    Float3,
    Float4,
    Mat3,
    Mat4,
    Int,
    Int2,
    Int3,
    Int4,
    Bool,
    Short2,
    UShort2,
    UShort4,
    /// `UShort4` read as floats (bind with `normalized`).
    UShort4Norm,
    Half4,
    Byte4,
    UByte4,
    /// `UByte4` read as floats (bind with `normalized`).
    UByte4Norm,

    const Info = struct { size: u32, components: u32, integer: bool };

    const info = std.EnumArray(DataType, Info).init(.{
        .Float = .{ .size = 4, .components = 1, .integer = false },
        .Float2 = .{ .size = 8, .components = 2, .integer = false },
        .Float3 = .{ .size = 12, .components = 3, .integer = false },
        .Float4 = .{ .size = 16, .components = 4, .integer = false },
        .Mat3 = .{ .size = 36, .components = 9, .integer = false },
        .Mat4 = .{ .size = 64, .components = 16, .integer = false },
        .Int = .{ .size = 4, .components = 1, .integer = true },
        .Int2 = .{ .size = 8, .components = 2, .integer = true },
        .Int3 = .{ .size = 12, .components = 3, .integer = true },
        .Int4 = .{ .size = 16, .components = 4, .integer = true },
        .Bool = .{ .size = 1, .components = 1, .integer = false },
        .Short2 = .{ .size = 4, .components = 2, .integer = false },
        .UShort2 = .{ .size = 4, .components = 2, .integer = false },
        .UShort4 = .{ .size = 8, .components = 4, .integer = true },
        .UShort4Norm = .{ .size = 8, .components = 4, .integer = false },
        .Half4 = .{ .size = 8, .components = 4, .integer = false },
        .Byte4 = .{ .size = 4, .components = 4, .integer = false },
        .UByte4 = .{ .size = 4, .components = 4, .integer = true },
        .UByte4Norm = .{ .size = 4, .components = 4, .integer = false },
    });

    pub fn size(dt: DataType) u32 {
        return info.get(dt).size;
    }

    pub fn componentCount(dt: DataType) u32 {
        return info.get(dt).components;
    }

    pub fn isIntegerType(dt: DataType) bool {
        return info.get(dt).integer;
    }
};

test "DataType reports upload metadata" {
    const Case = struct {
        data_type: DataType,
        size: u32,
        components: u32,
        is_integer: bool,
    };
    const cases = [_]Case{
        .{ .data_type = .Float, .size = 4, .components = 1, .is_integer = false },
        .{ .data_type = .Float2, .size = 8, .components = 2, .is_integer = false },
        .{ .data_type = .Float3, .size = 12, .components = 3, .is_integer = false },
        .{ .data_type = .Float4, .size = 16, .components = 4, .is_integer = false },
        .{ .data_type = .Mat3, .size = 36, .components = 9, .is_integer = false },
        .{ .data_type = .Mat4, .size = 64, .components = 16, .is_integer = false },
        .{ .data_type = .Int, .size = 4, .components = 1, .is_integer = true },
        .{ .data_type = .Int2, .size = 8, .components = 2, .is_integer = true },
        .{ .data_type = .Int3, .size = 12, .components = 3, .is_integer = true },
        .{ .data_type = .Int4, .size = 16, .components = 4, .is_integer = true },
        .{ .data_type = .Bool, .size = 1, .components = 1, .is_integer = false },
        .{ .data_type = .Short2, .size = 4, .components = 2, .is_integer = false },
        .{ .data_type = .UShort2, .size = 4, .components = 2, .is_integer = false },
        .{ .data_type = .UShort4, .size = 8, .components = 4, .is_integer = true },
        .{ .data_type = .UShort4Norm, .size = 8, .components = 4, .is_integer = false },
        .{ .data_type = .Half4, .size = 8, .components = 4, .is_integer = false },
        .{ .data_type = .Byte4, .size = 4, .components = 4, .is_integer = false },
        .{ .data_type = .UByte4, .size = 4, .components = 4, .is_integer = true },
        .{ .data_type = .UByte4Norm, .size = 4, .components = 4, .is_integer = false },
    };

    try std.testing.expectEqual(@typeInfo(DataType).@"enum".fields.len, cases.len);

    for (cases) |case| {
        try std.testing.expectEqual(case.size, case.data_type.size());
        try std.testing.expectEqual(case.components, case.data_type.componentCount());
        try std.testing.expectEqual(case.is_integer, case.data_type.isIntegerType());
    }
}
