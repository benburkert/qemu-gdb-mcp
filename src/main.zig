const std = @import("std");

const mcp = @import("mcp");

const Client = @import("gdb/Client.zig");
const ToolSet = @import("ToolSet.zig");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        mcp.reportError(err);
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args.skip(); // skip argv[0]

    const config = parseArgs(&args);

    var client: Client = Client.init(io, allocator, config) catch |err| {
        std.debug.print("Failed to start GDB: {}\n", .{err});
        return err;
    };
    defer client.deinit(io);

    var tool_set: ToolSet = .{ .client = &client };

    var server: mcp.Server = .init(allocator, .{
        .name = "qemu-gdb-mcp",
        .version = "0.0.1",
        .description = "GDB debugger for QEMU virtual machines",
    });
    defer server.deinit();

    try tool_set.register(&server);

    try server.run(io, allocator, .stdio);
}

fn parseArgs(args: *std.process.Args.Iterator) Client.Config {
    var config: Client.Config = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--gdb")) {
            config.gdb = args.next() orelse config.gdb;
        } else if (std.mem.eql(u8, arg, "--target-remote")) {
            config.target_remote = args.next() orelse config.target_remote;
        } else {
            config.image = arg;
        }
    }

    return config;
}

test {
    _ = @import("gdb/Client.zig");
    _ = @import("gdb/mi.zig");
    _ = @import("ToolSet.zig");
}
