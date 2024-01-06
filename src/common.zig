const std = @import("std");
const zpng = @import("zpng.zig");

const debug_enabled = std.meta.globalOption("zpng_debug", bool) orelse
    (@import("builtin").mode == .Debug);

pub fn debug(comptime level: @TypeOf(.x), comptime format: []const u8, args: anytype) void {
    if (debug_enabled) {
        @field(std.log.scoped(.zpng), @tagName(level))(format, args);
    }
}

pub const Ihdr = struct {
    width: u32,
    height: u32,
    bit_depth: u5,
    color_type: zpng.ColorType,
    compression_method: CompressionMethod = .deflate,
    filter_method: FilterMethod = .default,
    interlace_method: zpng.InterlaceMethod,

    pub const byte_size = 13;
    comptime {
        var total: usize = 0;
        for (@typeInfo(Ihdr).Struct.fields) |field| {
            total += @sizeOf(field.type);
        }
        std.debug.assert(total == byte_size);
    }

    pub fn lineBytes(ihdr: Ihdr) u32 {
        return (ihdr.width * ihdr.bit_depth * components(ihdr.color_type) - 1) / 8 + 1;
    }
};

pub fn components(ty: zpng.ColorType) u3 {
    return switch (ty) {
        .indexed => 1,
        .grayscale => 1,
        .grayscale_alpha => 2,
        .truecolor => 3,
        .truecolor_alpha => 4,
    };
}

pub const CompressionMethod = enum(u8) { deflate = 0 };
pub const FilterMethod = enum(u8) { default = 0 };
pub const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};

pub const Chunk = struct {
    ctype: ChunkType,
    data: []u8,
};
pub const ChunkType = blk: {
    const types = [_]*const [4]u8{
        "IHDR",
        "PLTE",
        "IDAT",
        "IEND",
        "tRNS",
    };

    var fields: [types.len]std.builtin.Type.EnumField = undefined;
    for (types, 0..) |name, i| {
        var field_name: [4]u8 = undefined;
        fields[i] = .{
            .name = std.ascii.lowerString(&field_name, name),
            .value = @as(u32, @bitCast(name.*)),
        };
    }

    break :blk @Type(.{ .Enum = .{
        .tag_type = u32,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = false,
    } });
};
pub fn chunkType(name: [4]u8) ChunkType {
    const x: u32 = @bitCast(name);
    return @enumFromInt(x);
}
pub fn chunkName(ctype: ChunkType) [4]u8 {
    return @bitCast(@intFromEnum(ctype));
}
