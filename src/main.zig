const std = @import("std");

const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server: mcp.Server = .init(allocator, .{
        .name = "qemu-gdb-mcp",
        .version = "0.0.1",
    });
    defer server.deinit();

    try server.run(io, allocator, .stdio);
}
