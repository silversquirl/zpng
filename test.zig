const std = @import("std");
const zpng = @import("zpng");

test "red/blue" {
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

test "green/alpha" {
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
