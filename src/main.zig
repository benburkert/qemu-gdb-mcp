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

    var tool_set: ToolSet = .{
        .config = config.client,
        .timeout_ns = config.timeout_s * std.time.ns_per_s,
        .io = io,
        .allocator = allocator,
    };
    defer tool_set.deinit();

    var server: mcp.Server = .init(allocator, .{
        .name = "qemu-gdb-mcp",
        .version = "0.0.1",
        .description = "GDB debugger for QEMU virtual machines",
    });
    defer server.deinit();

    try tool_set.register(&server);

    try server.run(io, allocator, .stdio);
}

const AppConfig = struct {
    client: Client.Config = .{},
    timeout_s: u64 = 10,
};

fn parseArgs(args: *std.process.Args.Iterator) AppConfig {
    var config: AppConfig = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--gdb")) {
            config.client.gdb = args.next() orelse config.client.gdb;
        } else if (std.mem.eql(u8, arg, "--target-remote")) {
            config.client.target_remote = args.next() orelse config.client.target_remote;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (args.next()) |t| {
                config.timeout_s = std.fmt.parseInt(u64, t, 10) catch 10;
            }
        } else {
            config.client.image = arg;
        }
    }

    return config;
}

test {
    _ = @import("gdb/Client.zig");
    _ = @import("gdb/mi.zig");
    _ = @import("ToolSet.zig");
}
