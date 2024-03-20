const std = @import("std");
const common = @import("common.zig");
const zpng = @import("zpng.zig");

// TODO: reduce allocations using streaming

pub fn Decoder(comptime Reader: type) type {
    return struct {
        allocator: std.mem.Allocator,
        r: Reader,

        const Self = @This();

        pub fn decode(self: *Self) !zpng.Image {
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
            var transparent_color: ?[3]u16 = null; // Not normalized. If grayscale, only first value is used

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
                        if (ihdr.color_type != .indexed) {
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
                        switch (ihdr.color_type) {
                            .grayscale_alpha, .truecolor_alpha => {
                                return error.InvalidPng; // tRNS invalid with alpha channel
                            },

                            .grayscale => {
                                if (chunk.data.len != 2) {
                                    return error.InvalidPng; // tRNS data of incorrect length
                                }
                                transparent_color = .{ std.mem.readInt(u16, chunk.data[0..2], .big), 0, 0 };
                            },

                            .truecolor => {
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
                        const cname = common.chunkName(chunk.ctype);
                        common.debug(.warn, "Unsupported chunk: {s}", .{cname});
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

            return zpng.Image{
                .width = ihdr.width,
                .height = ihdr.height,
                .pixels = pixels,
            };
        }

        fn readIhdr(self: *Self) !common.Ihdr {
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

            // Read and validate color type and bit depth
            const bit_depth = try r.readInt(u8, .big);
            const color_type = try std.meta.intToEnum(zpng.ColorType, try r.readInt(u8, .big));
            const allowed_bit_depths: []const u5 = switch (color_type) {
                .grayscale => &.{ 1, 2, 4, 8, 16 },
                .truecolor, .grayscale_alpha, .truecolor_alpha => &.{ 8, 16 },
                .indexed => &.{ 1, 2, 4, 8 },
            };
            for (allowed_bit_depths) |depth| {
                if (depth == bit_depth) break;
            } else {
                return error.InvalidPng;
            }

            // Read and validate compression method and filter method
            const compression_method = try std.meta.intToEnum(common.CompressionMethod, try r.readInt(u8, .big));
            const filter_method = try std.meta.intToEnum(common.FilterMethod, try r.readInt(u8, .big));

            // Read and validate interlace method
            const interlace_method = try std.meta.intToEnum(zpng.InterlaceMethod, try r.readInt(u8, .big));

            return common.Ihdr{
                .width = width,
                .height = height,
                .bit_depth = @intCast(bit_depth),
                .color_type = color_type,
                .compression_method = compression_method,
                .filter_method = filter_method,
                .interlace_method = interlace_method,
            };
        }

        fn readChunk(self: *Self) !common.Chunk {
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

            return common.Chunk{
                .ctype = common.chunkType(ctype),
                .data = data,
            };
        }
    };
}

fn readPixels(
    allocator: std.mem.Allocator,
    ihdr: common.Ihdr,
    palette: ?[]const [4]u16,
    transparent_color: ?[3]u16, // Not normalized. If grayscale, only first value is used
    data: []const u8,
) ![][4]u16 {
    var compressed_stream = std.io.fixedBufferStream(data);
    var data_stream = std.compress.zlib.decompressor(compressed_stream.reader());
    const datar = data_stream.reader();

    // TODO: interlacing
    var pixels = try allocator.alloc([4]u16, ihdr.width * ihdr.height);
    errdefer allocator.free(pixels);

    const line_bytes = ihdr.lineBytes();
    var line = try allocator.alloc(u8, line_bytes);
    defer allocator.free(line);
    var prev_line = try allocator.alloc(u8, line_bytes);
    defer allocator.free(prev_line);
    @memset(prev_line, 0); // Zero prev_line

    // Number of bits in actual color components
    const component_bits = switch (ihdr.color_type) {
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
    // Multiply each color component by this to produce a normalized u16
    const component_coef = @divExact(
        std.math.maxInt(u16),
        component_max,
    );

    var y: u32 = 0;
    while (y < ihdr.height) : (y += 1) {
        const filter = std.meta.intToEnum(common.FilterType, try datar.readByte()) catch {
            return error.InvalidPng;
        };
        try datar.readNoEof(line);
        filterScanline(filter, ihdr.bit_depth, common.components(ihdr.color_type), prev_line, line);

        var line_stream = std.io.fixedBufferStream(line);
        var bits = std.io.bitReader(.big, line_stream.reader());

        var x: u32 = 0;
        while (x < ihdr.width) : (x += 1) {
            var pix: [4]u16 = switch (ihdr.color_type) {
                .grayscale => blk: {
                    const v = try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    break :blk .{ v, v, v, component_max };
                },
                .grayscale_alpha => blk: {
                    const v = try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    const a = try bits.readBitsNoEof(u16, ihdr.bit_depth);
                    break :blk .{ v, v, v, a };
                },

                .truecolor => .{
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    component_max,
                },
                .truecolor_alpha => .{
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                    try bits.readBitsNoEof(u16, ihdr.bit_depth),
                },

                .indexed => palette.?[try bits.readBitsNoEof(u8, ihdr.bit_depth)],
            };

            if (transparent_color) |trns| {
                const n: u2 = switch (ihdr.color_type) {
                    .grayscale => 1,
                    .truecolor => 3,
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

// TODO: use optional prev_line, so we can avoid zeroing
fn filterScanline(filter: common.FilterType, bit_depth: u5, components: u4, prev_line: []const u8, line: []u8) void {
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
