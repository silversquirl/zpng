const std = @import("std");
const zpng = @import("zpng");

test "decode red/blue" {
    var dir = try std.fs.cwd().openDir("test/red_blue", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const f = try dir.openFile(entry.name, .{});
        defer f.close();
        var buf = std.io.bufferedReader(f.reader());
        const img = try zpng.Image.read(std.testing.allocator, buf.reader());
        defer img.deinit(std.testing.allocator);

        for (img.pixels, 0..) |pix, i| {
            const r: u16 = if (img.x(i) < 32) 0 else 65535;
            const b: u16 = if (img.y(i) < 32) 0 else 65535;
            try std.testing.expectEqual([4]u16{ r, 0, b, 65535 }, pix);
        }
    }
}

test "decode green/alpha" {
    var dir = try std.fs.cwd().openDir("test/green_alpha", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const f = try dir.openFile(entry.name, .{});
        defer f.close();
        var buf = std.io.bufferedReader(f.reader());
        const img = try zpng.Image.read(std.testing.allocator, buf.reader());
        defer img.deinit(std.testing.allocator);

        for (img.pixels, 0..) |pix, i| {
            const g: u16 = if (img.x(i) < 32) 0 else 65535;
            const a: u16 = if (img.y(i) < 32) 0 else 65535;
            try std.testing.expectEqual([4]u16{ 0, g, 0, a }, pix);
        }
    }
}

test "encode black, 0 alpha" {
    const img = try zpng.Image.init(std.testing.allocator, 128, 128);
    defer img.deinit(std.testing.allocator);

    try testRoundtrip(img, .{ .color_type = .grayscale_alpha });
    try testRoundtrip(img, .{ .color_type = .truecolor_alpha });

    try testRoundtrip(img, .{ .bit_depth = 8, .color_type = .grayscale_alpha });
    try testRoundtrip(img, .{ .bit_depth = 8, .color_type = .truecolor_alpha });
}
test "encode black, full alpha" {
    const img = try zpng.Image.init(std.testing.allocator, 128, 128);
    defer img.deinit(std.testing.allocator);
    for (img.pixels) |*pix| {
        pix[3] = 0xffff;
    }

    try testRoundtrip(img, .{ .color_type = .grayscale });
    try testRoundtrip(img, .{ .color_type = .truecolor });
    try testRoundtrip(img, .{ .color_type = .grayscale_alpha });
    try testRoundtrip(img, .{ .color_type = .truecolor_alpha });

    try testRoundtrip(img, .{ .bit_depth = 8, .color_type = .grayscale });
    try testRoundtrip(img, .{ .bit_depth = 8, .color_type = .truecolor });
    try testRoundtrip(img, .{ .bit_depth = 8, .color_type = .grayscale_alpha });
    try testRoundtrip(img, .{ .bit_depth = 8, .color_type = .truecolor_alpha });
}

test "encode random noise" {
    const img = try zpng.Image.init(std.testing.allocator, 128, 128);
    defer img.deinit(std.testing.allocator);

    var rng = std.rand.DefaultPrng.init(0);
    const rand = rng.random();
    for (img.pixels) |*pix| {
        for (pix) |*c| {
            c.* = rand.int(u16);
        }
    }

    try testRoundtrip(img, .{});
}

test "decoder crashes found by fuzzing" {
    var dir = try std.fs.cwd().openDir("fuzz/crashes", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const f = try dir.openFile(entry.name, .{});
        defer f.close();
        var buf = std.io.bufferedReader(f.reader());

        const img = zpng.Image.read(std.testing.allocator, buf.reader()) catch {
            // Errors are expected from fuzz cases (but not required, so we continue either way)
            continue;
        };
        defer img.deinit(std.testing.allocator);
        std.mem.doNotOptimizeAway(img);
    }
}

fn testRoundtrip(img: zpng.Image, opts: zpng.EncodeOptions) !void {
    // Encode image
    var array = std.ArrayList(u8).init(std.testing.allocator);
    defer array.deinit();
    try img.write(std.testing.allocator, array.writer(), opts);

    // Decode image
    var buf = std.io.fixedBufferStream(array.items);
    const decoded = try zpng.Image.read(std.testing.allocator, buf.reader());
    defer decoded.deinit(std.testing.allocator);

    // Verify
    try std.testing.expectEqual(img.width, decoded.width);
    try std.testing.expectEqual(img.height, decoded.height);
    try std.testing.expectEqualSlices([4]u16, img.pixels, decoded.pixels);
}
