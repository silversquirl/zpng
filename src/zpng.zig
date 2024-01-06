const std = @import("std");

const decoder = @import("decoder.zig");
const encoder = @import("encoder.zig");
pub const EncodeOptions = encoder.EncodeOptions;

pub const ColorType = enum(u8) {
    grayscale = 0,
    truecolor = 2,
    indexed = 3,
    grayscale_alpha = 4,
    truecolor_alpha = 6,
};

pub const InterlaceMethod = enum(u8) {
    none = 0,
    adam7 = 1,
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: [][4]u16,

    // If the PNG is invalid or corrupt, error.InvalidPng is returned.
    // If the PNG may be valid, but uses features not supported by this implementation, error.UnsupportedPng is returned.
    pub fn read(allocator: std.mem.Allocator, r: anytype) !Image {
        var dec = decoder.Decoder(@TypeOf(r)){ .allocator = allocator, .r = r };
        return dec.decode();
    }

    /// Write the image to a writer as a PNG.
    /// The allocator is only used for temporary allocations during encoding.
    pub fn write(self: Image, allocator: std.mem.Allocator, w: anytype, opts: EncodeOptions) !void {
        var enc = encoder.Encoder(@TypeOf(w)){ .w = w, .allocator = allocator };
        try enc.encode(self, opts);
    }

    /// Create a black, fully transparent image
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        const pixels = try allocator.alloc([4]u16, width * height);
        @memset(pixels, .{ 0, 0, 0, 0 });
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
        };
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
