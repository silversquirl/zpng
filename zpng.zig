const std = @import("std");

const debug_enabled = std.meta.globalOption("zpng_debug", bool) orelse
    (@import("builtin").mode == .Debug);

fn debug(comptime level: @TypeOf(.x), comptime format: []const u8, args: anytype) void {
    if (debug_enabled) {
        @field(std.log.scoped(.zpng), @tagName(level))(format, args);
    }
}

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: [][4]u16,

    // If the PNG is invalid or corrupt, error.InvalidPng is returned.
    // If the PNG may be valid, but uses features not supported by this implementation, error.UnsupportedPng is returned.
    pub fn read(allocator: std.mem.Allocator, r: anytype) !Image {
        var dec = Decoder(@TypeOf(r)){ .allocator = allocator, .r = r };
        return dec.decode();
    }

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// Return the X coordinate of the pixel at index
    pub fn x(self: Image, index: usize) u32 {
        return @intCast(index % self.width);
    }
    /// Return the Y coordinate of the pixel at index
    pub fn y(self: Image, index: usize) u32 {
        return @intCast(index / self.height);
    }

    /// Return the pixel at the given X and Y coordinates
    pub fn pix(self: Image, px: u32, py: u32) [4]u16 {
        return self.pixels[px + py * self.width];
    }
};

fn Decoder(comptime Reader: type) type {
    return struct {
        allocator: std.mem.Allocator,
        r: Reader,

        const Self = @This();

        fn decode(self: *Self) !Image {
            // Read magic bytes
            if (!try self.r.isBytes("\x89PNG\r\n\x1a\n")) {
                return error.InvalidPng;
            }

            // Read IHDR chunk
            const ihdr = self.readIhdr() catch |err| return switch (err) {
                error.InvalidEnumTag => error.InvalidPng,
                else => |e| e,
            };
            // TODO: interlacing
            if (ihdr.interlace_method != .none) {
                return error.UnsupportedPng;
            }

            // Read data chunks
            var data: ?std.ArrayList(u8) = null;
            defer if (data) |l| l.deinit();
            var palette: ?[][4]u16 = null;
            defer if (palette) |p| self.allocator.free(p);
            var transparent_color: ?[3]u16 = null; // Not normalized. If greyscale, only first value is used

            while (true) {
                const chunk = try self.readChunk();
                var free = true;
                defer if (free) self.allocator.free(chunk.data);

                switch (chunk.ctype) {
                    .ihdr => return error.InvalidPng, // Duplicate IHDR
                    .iend => {
                        if (chunk.data.len != 0) {
                            return error.InvalidPng; // Non-empty IEND
                        }
                        break;
                    },

                    .plte => {
                        if (ihdr.colour_type != .indexed) {
                            return error.InvalidPng; // Unexpected PLTE
                        }
                        if (palette != null) {
                            return error.InvalidPng; // Duplicate PLTE
                        }
                        if (chunk.data.len % 3 != 0) {
                            return error.InvalidPng; // PLTE length not a multiple of three
                        }

                        const rgb_palette = std.mem.bytesAsSlice([3]u8, chunk.data);
                        const rgba_palette = try self.allocator.alloc([4]u16, rgb_palette.len);
                        for (rgb_palette, 0..) |entry, i| {
                            for (entry, 0..) |c, j| {
                                rgba_palette[i][j] = @as(u16, 257) * c;
                            }
                            rgba_palette[i][3] = std.math.maxInt(u16);
                        }
                        palette = rgba_palette;
                    },

                    // TODO: streaming
                    .idat => if (data) |*l| {
                        try l.appendSlice(chunk.data);
                    } else {
                        data = std.ArrayList(u8).fromOwnedSlice(self.allocator, chunk.data);
                        free = false;
                    },

                    .trns => {
                        switch (ihdr.colour_type) {
                            .greyscale_alpha, .truecolour_alpha => {
                                return error.InvalidPng; // tRNS invalid with alpha channel
                            },

                            .greyscale => {
                                if (chunk.data.len != 2) {
                                    return error.InvalidPng; // tRNS data of incorrect length
                                }
                                transparent_color = .{ std.mem.readInt(u16, chunk.data[0..2], .big), 0, 0 };
                            },

                            .truecolour => {
                                if (chunk.data.len != 6) {
                                    return error.InvalidPng; // tRNS data of incorrect length
                                }
                                transparent_color = .{
                                    std.mem.readInt(u16, chunk.data[0..][0..2], .big),
                                    std.mem.readInt(u16, chunk.data[2..][0..2], .big),
                                    std.mem.readInt(u16, chunk.data[4..][0..2], .big),
                                };
                            },

                            .indexed => {
                                const plte = palette orelse {
                                    return error.InvalidPng; // tRNS before PLTE
                                };
                                for (chunk.data, 0..) |trns, i| {
                                    plte[i][3] = trns;
                                }
                            },
                        }
                    },

                    _ => {
                        const cname = chunkName(chunk.ctype);
                        debug(.warn, "Unsupported chunk: {s}", .{cname});
                        if (cname[0] & 32 == 0) {
                            // Ancillary bit is unset, this chunk is critical
                            return error.UnsupportedPng;
                        }
                    },
                }
            }

            // Read pixel data
            if (data == null) {
                return error.InvalidPng; // Missing IDAT
            }
            const pixels = try readPixels(
                self.allocator,
                ihdr,
                palette orelse null, // ziglang/zig#4907
                transparent_color,
                data.?.items,
            );

            return Image{
                .width = ihdr.width,
                .height = ihdr.height,
                .pixels = pixels,
            };
        }

        fn readIhdr(self: *Self) !Ihdr {
            // Read chunk
            const chunk = try self.readChunk();
            defer self.allocator.free(chunk.data);
            if (chunk.ctype != .ihdr) {
                return error.InvalidPng;
            }
            var stream = std.io.fixedBufferStream(chunk.data);
            const r = stream.reader();

            // Read and validate width and height
            const width = try r.readInt(u32, .big);
            const height = try r.readInt(u32, .big);
            if (width == 0 or height == 0) {
                return error.InvalidPng;
            }

            // Read and validate colour type and bit depth
            const bit_depth = try r.readInt(u8, .big);
            const colour_type = try std.meta.intToEnum(ColourType, try r.readInt(u8, .big));
            const allowed_bit_depths: []const u5 = switch (colour_type) {
                .greyscale => &.{ 1, 2, 4, 8, 16 },
                .truecolour, .greyscale_alpha, .truecolour_alpha => &.{ 8, 16 },
                .indexed => &.{ 1, 2, 4, 8 },
            };
            for (allowed_bit_depths) |depth| {
                if (depth == bit_depth) break;
            } else {
                return error.InvalidPng;
            }

            // Read and validate compression method and filter method
            const compression_method = try r.readInt(u8, .big);
            const filter_method = try r.readInt(u8, .big);
            if (compression_method != 0 or filter_method != 0) {
                return error.InvalidPng;
            }

            // Read and validate interlace method
            const interlace_method = try std.meta.intToEnum(InterlaceMethod, try r.readInt(u8, .big));

            return Ihdr{
                .width = width,
                .height = height,
                .bit_depth = @intCast(bit_depth),
                .colour_type = colour_type,
                .compression_method = compression_method,
                .filter_method = filter_method,
                .interlace_method = interlace_method,
            };
        }

        fn readChunk(self: *Self) !Chunk {
            var crc = std.hash.Crc32.init();

            const len = try self.r.readInt(u32, .big);
            var ctype = try self.r.readBytesNoEof(4);
            crc.update(&ctype);

            const data = try self.allocator.alloc(u8, len);
            errdefer self.allocator.free(data);
            try self.r.readNoEof(data);
            crc.update(data);

            if (crc.final() != try self.r.readInt(u32, .big)) {
                return error.InvalidPng;
            }

            return Chunk{
                .ctype = chunkType(ctype),
                .data = data,
            };
        }
    };
}

fn readPixels(
    allocator: std.mem.Allocator,
    ihdr: Ihdr,
    palette: ?[]const [4]u16,
    transparent_color: ?[3]u16, // Not normalized. If greyscale, only first value is used
    data: []const u8,
) ![][4]u16 {
    var compressed_stream = std.io.fixedBufferStream(data);
    var data_stream = try std.compress.zlib.decompressStream(allocator, compressed_stream.reader());
    defer data_stream.deinit();
    const datar = data_stream.reader();

    // TODO: interlacing
    var pixels = try allocator.alloc([4]u16, ihdr.width * ihdr.height);
    errdefer allocator.free(pixels);

    const components: u3 = switch (ihdr.colour_type) {
        .indexed => 1,
        .greyscale => 1,
        .greyscale_alpha => 2,
        .truecolour => 3,
        .truecolour_alpha => 4,
    };
    const line_bytes = (ihdr.width * ihdr.bit_depth * components - 1) / 8 + 1;

    var line = try allocator.alloc(u8, line_bytes);
    defer allocator.free(line);
    var prev_line = try allocator.alloc(u8, line_bytes);
    defer allocator.free(prev_line);
    @memset(prev_line, 0); // Zero prev_line

    // Number of bits in actual colour components
    const component_bits = switch (ihdr.colour_type) {
        .indexed => blk: {
            if (palette == null) {
                return error.InvalidPng; // Missing PLTE
            }
            break :blk 16;
        },
        else => ihdr.bit_depth,
    };
    // Max component_bits-bit value
    const component_max: u16 = @intCast((@as(u17, 1) << component_bits) - 1);
    // Multiply each colour component by this to produce a normalized u16
    const component_coef = @divExact(
        std.math.maxInt(u16),
        component_max,
    );

    var y: u32 = 0;
    while (y < ihdr.height) : (y += 1) {
        const filter = std.meta.intToEnum(FilterType, try datar.readByte()) catch {
            return error.InvalidPng;
        };
        try datar.readNoEof(line);
        filterScanline(filter, ihdr.bit_depth, components, prev_line, line);

        var line_stream = std.io.fixedBufferStream(line);
        var bits = std.io.bitReader(.big, line_stream.reader());

        var x: u32 = 0;
        while (x < ihdr.width) : (x += 1) {
            var pix: [4]u16 = switch (ihdr.colour_type) {
                .greyscale => blk: {
                    const v = try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    break :blk .{ v, v, v, component_max };
                },
                .greyscale_alpha => blk: {
                    const v = try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    const a = try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    break :blk .{ v, v, v, a };
                },

                .truecolour => .{
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    component_max,
                },
                .truecolour_alpha => .{
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                },

                .indexed => palette.?[try bits.readBitsNoEof(u8, ihdr.bit_depth)],
            };

            if (transparent_color) |trns| {
                const n: u2 = switch (ihdr.colour_type) {
                    .greyscale => 1,
                    .truecolour => 3,
                    else => unreachable,
                };
                if (std.mem.eql(u16, pix[0..n], &trns)) {
                    pix[3] = 0;
                }
            }

            const idx = x + y * ihdr.width;
            for (pix, 0..) |c, i| {
                pixels[idx][i] = component_coef * c;
            }
        }

        std.debug.assert(line_stream.pos == line_stream.buffer.len);

        std.mem.swap([]u8, &line, &prev_line);
    }

    var buf: [1]u8 = undefined;
    if (0 != try datar.readAll(&buf)) {
        return error.InvalidPng; // Excess IDAT data
    }

    return pixels;
}

const Ihdr = struct {
    width: u32,
    height: u32,
    bit_depth: u5,
    colour_type: ColourType,
    compression_method: u8,
    filter_method: u8,
    interlace_method: InterlaceMethod,
};
const ColourType = enum(u8) {
    greyscale = 0,
    truecolour = 2,
    indexed = 3,
    greyscale_alpha = 4,
    truecolour_alpha = 6,
};
const InterlaceMethod = enum(u8) {
    none = 0,
    adam7 = 1,
};
const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};

const Chunk = struct {
    ctype: ChunkType,
    data: []u8,
};
const ChunkType = blk: {
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
fn chunkType(name: [4]u8) ChunkType {
    const x: u32 = @bitCast(name);
    return @enumFromInt(x);
}
fn chunkName(ctype: ChunkType) [4]u8 {
    return @bitCast(@intFromEnum(ctype));
}

// TODO: use optional prev_line, so we can avoid zeroing
fn filterScanline(filter: FilterType, bit_depth: u5, components: u4, prev_line: []const u8, line: []u8) void {
    if (filter == .none) return;

    const byte_rewind = switch (bit_depth) {
        1, 2, 4 => 1,
        8 => components,
        16 => components * 2,
        else => unreachable,
    };

    for (line, 0..) |*x, i| {
        const a = if (i < byte_rewind) 0 else line[i - byte_rewind];
        const b = prev_line[i];
        const c = if (i < byte_rewind) 0 else prev_line[i - byte_rewind];

        x.* +%= switch (filter) {
            .none => unreachable,
            .sub => a,
            .up => b,
            .average => @intCast((@as(u9, a) + b) / 2),
            .paeth => paeth(a, b, c),
        };
    }
}
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i10, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc)
        a
    else if (pb <= pc)
        b
    else
        c;
}
