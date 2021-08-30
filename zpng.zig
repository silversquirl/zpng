const std = @import("std");

const debug_enabled = std.meta.globalOption("zpng_debug", bool) orelse (std.builtin.mode == .Debug);
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
    pub fn read(allocator: *std.mem.Allocator, r: anytype) !Image {
        var dec = Decoder(@TypeOf(r)){ .allocator = allocator, .r = r };
        return dec.decode();
    }

    pub fn deinit(self: Image, allocator: *std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// Return the X coordinate of the pixel at index
    pub fn x(self: Image, index: usize) u32 {
        return @intCast(u32, index % self.width);
    }
    /// Return the Y coordinate of the pixel at index
    pub fn y(self: Image, index: usize) u32 {
        return @intCast(u32, index / self.height);
    }

    /// Return the pixel at the given X and Y coordinates
    pub fn pix(self: Image, px: u32, py: u32) [4]u16 {
        return self.pixels[px + py * self.width];
    }
};

fn Decoder(comptime Reader: type) type {
    return struct {
        allocator: *std.mem.Allocator,
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
            // TODO: indexed colour
            if (ihdr.colour_type == .indexed_colour) {
                return error.UnsupportedPng;
            }
            // TODO: interlacing
            if (ihdr.interlace_method != .none) {
                return error.UnsupportedPng;
            }

            // Read data chunks
            var data = std.ArrayList(u8).init(self.allocator);
            defer data.deinit();
            while (true) {
                const chunk = try self.readChunk();
                defer self.allocator.free(chunk.data);
                switch (chunk.ctype) {
                    .iend => break,

                    // TODO: don't copy first idat
                    .idat => try data.appendSlice(chunk.data),

                    else => {
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
            const pixels = try readPixels(self.allocator, ihdr, data.items);

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
            const width = try r.readIntBig(u32);
            const height = try r.readIntBig(u32);
            if (width == 0 or height == 0) {
                return error.InvalidPng;
            }

            // Read and validate colour type and bit depth
            const bit_depth = try r.readIntBig(u8);
            const colour_type = try std.meta.intToEnum(ColourType, try r.readIntBig(u8));
            const allowed_bit_depths: []const u5 = switch (colour_type) {
                .greyscale => &.{ 1, 2, 4, 8, 16 },
                .truecolour, .greyscale_alpha, .truecolour_alpha => &.{ 8, 16 },
                .indexed_colour => &.{ 1, 2, 4, 8 },
            };
            for (allowed_bit_depths) |depth| {
                if (depth == bit_depth) break;
            } else {
                return error.InvalidPng;
            }

            // Read and validate compression method and filter method
            const compression_method = try r.readIntBig(u8);
            const filter_method = try r.readIntBig(u8);
            if (compression_method != 0 or filter_method != 0) {
                return error.InvalidPng;
            }

            // Read and validate interlace method
            const interlace_method = try std.meta.intToEnum(InterlaceMethod, try r.readIntBig(u8));

            return Ihdr{
                .width = width,
                .height = height,
                .bit_depth = @intCast(u5, bit_depth),
                .colour_type = colour_type,
                .compression_method = compression_method,
                .filter_method = filter_method,
                .interlace_method = interlace_method,
            };
        }

        fn readChunk(self: *Self) !Chunk {
            var crc = std.hash.Crc32.init();

            const len = try self.r.readIntBig(u32);
            var ctype = try self.r.readBytesNoEof(4);
            crc.update(&ctype);

            const data = try self.allocator.alloc(u8, len);
            errdefer self.allocator.free(data);
            try self.r.readNoEof(data);
            crc.update(data);

            if (crc.final() != try self.r.readIntBig(u32)) {
                return error.InvalidPng;
            }

            return Chunk{
                .ctype = chunkType(ctype),
                .data = data,
            };
        }
    };
}

fn readPixels(allocator: *std.mem.Allocator, ihdr: Ihdr, data: []const u8) ![][4]u16 {
    var compressed_stream = std.io.fixedBufferStream(data);
    var data_stream = try std.compress.zlib.zlibStream(allocator, compressed_stream.reader());
    defer data_stream.deinit();
    const datar = data_stream.reader();

    // TODO: interlacing
    var pixels = try allocator.alloc([4]u16, ihdr.width * ihdr.height);
    errdefer allocator.free(pixels);

    const components: u3 = switch (ihdr.colour_type) {
        .indexed_colour => 1,
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
    std.mem.set(u8, prev_line, 0); // Zero prev_line

    // Component coefficient - multiply by this to produce a normalized u16
    const ccoef = @divExact(
        std.math.maxInt(u16), // Max 16-bit value
        @intCast(u16, (@as(u17, 1) << ihdr.bit_depth) - 1), // Max bit_depth-bit value
    );

    var y: u32 = 0;
    while (y < ihdr.height) : (y += 1) {
        const filter = std.meta.intToEnum(FilterType, try datar.readByte()) catch {
            return error.InvalidPng;
        };
        try datar.readNoEof(line);
        filterScanline(filter, ihdr.bit_depth, prev_line, line);

        var line_stream = std.io.fixedBufferStream(line);
        var bits = std.io.bitReader(.Big, line_stream.reader());

        var x: u32 = 0;
        while (x < ihdr.width) : (x += 1) {
            pixels[y * ihdr.width + x] = switch (ihdr.colour_type) {
                .greyscale => blk: {
                    const v = ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    break :blk [4]u16{ v, v, v, std.math.maxInt(u16) };
                },
                .greyscale_alpha => blk: {
                    const v = ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    const a = ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    break :blk [4]u16{ v, v, v, a };
                },

                .truecolour => .{
                    ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    std.math.maxInt(u16),
                },
                .truecolour_alpha => .{
                    ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    ccoef * try bits.readBitsNoEof(u16, ihdr.bit_depth),
                },

                .indexed_colour => unreachable, // TODO
            };
        }

        std.mem.swap([]u8, &line, &prev_line);
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
    indexed_colour = 3,
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
    data: []const u8,
};
const ChunkType = blk: {
    const types = [_]*const [4]u8{
        "IHDR",
        "PLTE",
        "IDAT",
        "IEND",
    };

    var fields: [types.len]std.builtin.TypeInfo.EnumField = undefined;
    for (types) |name, i| {
        var field_name: [4]u8 = undefined;
        fields[i] = .{
            .name = std.ascii.lowerString(&field_name, name),
            .value = std.mem.readIntNative(u32, name),
        };
    }

    break :blk @Type(.{ .Enum = .{
        .layout = .Auto,
        .tag_type = u32,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = false,
    } });
};
fn chunkType(name: [4]u8) ChunkType {
    return @intToEnum(ChunkType, std.mem.readIntNative(u32, &name));
}
fn chunkName(ctype: ChunkType) [4]u8 {
    var name: [4]u8 = undefined;
    std.mem.writeIntNative(u32, &name, @enumToInt(ctype));
    return name;
}

// TODO: use optional prev_line, so we can avoid zeroing
fn filterScanline(filter: FilterType, bit_depth: u5, prev_line: []const u8, line: []u8) void {
    if (filter == .none) return;

    const byte_rewind: u3 = switch (bit_depth) {
        1, 2, 4 => 1,
        8 => 3,
        16 => 6,
        else => unreachable,
    };

    for (line) |*x, i| {
        const a = if (i < byte_rewind) 0 else line[i - byte_rewind];
        const b = prev_line[i];
        const c = if (i < byte_rewind) 0 else prev_line[i - byte_rewind];

        x.* +%= switch (filter) {
            .none => unreachable,
            .sub => a,
            .up => b,
            .average => @intCast(u8, (@as(u9, a) + b) / 2),
            .paeth => paeth(a, b, c),
        };
    }
}
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i10, a) + b - c;
    const pa = std.math.absInt(p - a) catch unreachable;
    const pb = std.math.absInt(p - b) catch unreachable;
    const pc = std.math.absInt(p - c) catch unreachable;
    return if (pa <= pb and pa <= pc)
        a
    else if (pb <= pc)
        b
    else
        c;
}

test "read png" {
    const f = try std.fs.cwd().openFile("test.png", .{});
    defer f.close();
    var buf = std.io.bufferedReader(f.reader());
    const img = try Image.read(std.testing.allocator, buf.reader());
    defer img.deinit(std.testing.allocator);

    for (img.pixels) |pix, i| {
        const r: u16 = if (img.x(i) < 32) 0 else 65535;
        const b: u16 = if (img.y(i) < 32) 0 else 65535;
        try std.testing.expectEqual([4]u16{ r, 0, b, 65535 }, pix);
    }
}
