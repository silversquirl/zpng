const std = @import("std");
const zpng = @import("zpng");

fn fuzzDecoder() !void {
    var bufr = std.io.bufferedReader(std.io.getStdIn().reader());
    const img = try zpng.Image.read(std.heap.c_allocator, bufr.reader());
    defer img.deinit(std.heap.c_allocator);
    std.mem.doNotOptimizeAway(img);
}

pub fn main() !void {
    switch (@import("builtin").mode) {
        .Debug => std.log.warn("Running fuzzing binary in debug mode. This will be slow.", .{}),
        .ReleaseSafe => {},
        else => std.log.warn("Running fuzzing binary in unsafe optimizatio mode. ReleaseSafe is recommended in order for assertions to be checked.", .{}),
    }
    try fuzzDecoder();
}
