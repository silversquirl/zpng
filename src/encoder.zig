const std = @import("std");
const common = @import("common.zig");
const zpng = @import("zpng.zig");

// TODO: allow autodetecting defaults
pub const EncodeOptions = struct {
    bit_depth: u5 = 16,
    color_type: zpng.ColorType = .truecolor_alpha,
};

// TODO: idk if this struct is useful, should maybe just be a namespace
pub fn Encoder(comptime Writer: type) type {
    return struct {
        w: Writer,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn encode(self: *Self, img: zpng.Image, opts: EncodeOptions) !void {
            // Write magic bytes
            try self.w.writeAll("\x89PNG\r\n\x1a\n");

            // Write IHDR chunk
            const ihdr: common.Ihdr = .{
                .width = img.width,
                .height = img.height,
                .bit_depth = opts.bit_depth,
                .color_type = opts.color_type,
                // TODO: support interlacing
                .interlace_method = .none,
            };
            try self.writeIhdr(ihdr);

            // Write and compress pixel data into buffer
            var data = std.ArrayList(u8).init(self.allocator);
            defer data.deinit();
            {
                // TODO: add option for compression level
                var compressor = try std.compress.zlib.compressor(data.writer(), .{});
                try writePixels(self.allocator, ihdr, img.pixels, compressor.writer());
                try compressor.finish();
            }

            // Write buffer
            var idat = try self.beginChunk(.idat, @intCast(data.items.len));
            try idat.writeAll(data.items);
            try idat.finish();

            // Write IEND chunk
            var iend = try self.beginChunk(.iend, 0);
            try iend.finish();
        }

        fn writeIhdr(self: *Self, ihdr: common.Ihdr) !void {
            var w = try self.beginChunk(.ihdr, common.Ihdr.byte_size);

            try w.writeInt(u32, ihdr.width, .big);
            try w.writeInt(u32, ihdr.height, .big);
            try w.writeInt(u8, ihdr.bit_depth, .big);

            try w.writeInt(u8, @intFromEnum(ihdr.color_type), .big);
            try w.writeInt(u8, @intFromEnum(ihdr.compression_method), .big);
            try w.writeInt(u8, @intFromEnum(ihdr.filter_method), .big);
            try w.writeInt(u8, @intFromEnum(ihdr.interlace_method), .big);

            try w.finish();
        }

        fn beginChunk(self: *Self, ctype: common.ChunkType, size: u32) !ChunkWriter {
            try self.w.writeInt(u32, size, .big);
            const name = common.chunkName(ctype);
            try self.w.writeAll(&name);

            var w = ChunkWriter{
                .w = self.w,
                .remaining = if (std.debug.runtime_safety) size else {},
            };
            w.crc.update(&name);

            return w;
        }

        const ChunkWriter = struct {
            w: Writer,
            remaining: if (std.debug.runtime_safety) usize else void,
            crc: std.hash.Crc32 = std.hash.Crc32.init(),

            fn write(self: *ChunkWriter, data: []const u8) !usize {
                const n = try self.w.write(data);
                self.crc.update(data[0..n]);

                if (std.debug.runtime_safety) {
                    self.remaining -= n; // Check bounds
                }

                return n;
            }

            fn writer(self: *ChunkWriter) std.io.Writer(*ChunkWriter, Writer.Error, write) {
                return .{ .context = self };
            }

            fn writeAll(self: *ChunkWriter, data: []const u8) !void {
                try self.writer().writeAll(data);
            }
            fn writeInt(self: *ChunkWriter, comptime T: type, data: T, endian: std.builtin.Endian) !void {
                try self.writer().writeInt(T, data, endian);
            }

            fn finish(self: *ChunkWriter) !void {
                try self.w.writeInt(u32, self.crc.final(), .big);
                if (std.debug.runtime_safety) {
                    std.debug.assert(self.remaining == 0); // Ensure chunk is full
                }
            }
        };
    };
}

fn writePixels(
    allocator: std.mem.Allocator,
    ihdr: common.Ihdr,
    pixels: []const [4]u16,
    w: anytype,
) !void {
    const line = try allocator.alloc(u8, ihdr.lineBytes());
    defer allocator.free(line);

    // Number of bits in actual color components
    const component_bits = switch (ihdr.color_type) {
        .indexed => blk: {
            if (true) unreachable; // TODO: indexed color encoding
            break :blk 16;
        },
        else => ihdr.bit_depth,
    };
    // Max component_bits-bit value
    const component_max: u16 = @intCast((@as(u17, 1) << component_bits) - 1);
    // Divide each color component by this to produce the correct number of bits
    const component_coef = @divExact(
        std.math.maxInt(u16),
        component_max,
    );

    std.debug.assert(ihdr.width * ihdr.height == pixels.len);
    var y: u32 = 0;
    while (y < ihdr.height) : (y += 1) {
        var line_stream = std.io.fixedBufferStream(line);
        var bits = std.io.bitWriter(.big, line_stream.writer());

        var x: u32 = 0;
        while (x < ihdr.width) : (x += 1) {
            var rgba: [4]u16 = pixels[y * ihdr.width + x];
            for (&rgba) |*c| {
                c.* /= component_coef;
            }

            switch (ihdr.color_type) {
                .grayscale => {
                    try bits.writeBits(rgba[0], ihdr.bit_depth);
                },
                .grayscale_alpha => {
                    try bits.writeBits(rgba[0], ihdr.bit_depth);
                    try bits.writeBits(rgba[3], ihdr.bit_depth);
                },

                .truecolor => {
                    try bits.writeBits(rgba[0], ihdr.bit_depth);
                    try bits.writeBits(rgba[1], ihdr.bit_depth);
                    try bits.writeBits(rgba[2], ihdr.bit_depth);
                },
                .truecolor_alpha => {
                    try bits.writeBits(rgba[0], ihdr.bit_depth);
                    try bits.writeBits(rgba[1], ihdr.bit_depth);
                    try bits.writeBits(rgba[2], ihdr.bit_depth);
                    try bits.writeBits(rgba[3], ihdr.bit_depth);
                },

                .indexed => unreachable, // TODO: indexed color encoding
            }
        }

        // TODO: filtering
        try w.writeByte(@intFromEnum(common.FilterType.none));
        try w.writeAll(line);
    }
}
