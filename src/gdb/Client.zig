const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const mi = @import("mi.zig");

const Client = @This();

child: std.process.Child,
reader: Io.File.Reader,
writer: Io.File.Writer,
next_token: u32 = 1,
read_buf: [64 * 1024]u8 = undefined,

pub const Error = error{
    GdbError,
    UnexpectedRecord,
    UnexpectedEof,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
    StreamTooLong,
};

pub const Response = struct {
    token: ?u32,
    result: mi.ResultRecord,
    console: std.ArrayListUnmanaged(u8),
    stop: ?mi.AsyncRecord,
    allocator: Allocator,

    pub fn deinit(self: *@This()) void {
        self.result.deinit(self.allocator);
        self.console.deinit(self.allocator);
        if (self.stop) |s| s.deinit(self.allocator);
    }

    pub fn consoleOutput(self: @This()) []const u8 {
        return self.console.items;
    }

    pub fn isError(self: @This()) bool {
        return self.result.class == .@"error";
    }

    pub fn errorMessage(self: @This()) ?[]const u8 {
        return self.result.results.getString("msg");
    }
};

pub const Config = struct {
    gdb: []const u8 = "gdb",
    image: ?[]const u8 = null,
    target_remote: ?[]const u8 = null,

    pub fn arguments(self: @This(), allocator: Allocator) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(allocator, self.gdb);
        if (self.image) |image| try argv.append(allocator, image);
        try argv.append(allocator, "--interpreter=mi3");
        return argv.toOwnedSlice(allocator);
    }

    test "arguments defaults" {
        const config: Config = .{};
        const argv = try config.arguments(std.testing.allocator);
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqual(@as(usize, 2), argv.len);
        try std.testing.expectEqualStrings("gdb", argv[0]);
        try std.testing.expectEqualStrings("--interpreter=mi3", argv[1]);
    }

    test "arguments with image" {
        const config: Config = .{ .image = "kernel.elf" };
        const argv = try config.arguments(std.testing.allocator);
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqual(@as(usize, 3), argv.len);
        try std.testing.expectEqualStrings("gdb", argv[0]);
        try std.testing.expectEqualStrings("kernel.elf", argv[1]);
        try std.testing.expectEqualStrings("--interpreter=mi3", argv[2]);
    }

    test "arguments with custom gdb" {
        const config: Config = .{ .gdb = "riscv64-elf-gdb", .image = "kernel.elf" };
        const argv = try config.arguments(std.testing.allocator);
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqualStrings("riscv64-elf-gdb", argv[0]);
        try std.testing.expectEqualStrings("kernel.elf", argv[1]);
        try std.testing.expectEqualStrings("--interpreter=mi3", argv[2]);
    }
};

/// Spawn GDB and consume startup output.
pub fn init(io: Io, allocator: Allocator, config: Config) Error!@This() {
    const argv = try config.arguments(allocator);
    defer allocator.free(argv);

    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.debug.print("Failed to spawn GDB ({s}): {s}\n", .{ config.gdb, @errorName(err) });
        return Error.ReadFailed;
    };

    var client: Client = .{
        .child = child,
        .reader = undefined,
        .writer = undefined,
    };
    client.reader = Io.File.Reader.initStreaming(child.stdout.?, io, &client.read_buf);
    client.writer = Io.File.Writer.initStreaming(child.stdin.?, io, &.{});
    client.consumeUntilPrompt(allocator) catch |err| {
        std.debug.print("GDB failed during startup: {s}\n", .{@errorName(err)});
        return err;
    };

    if (config.target_remote) |target| {
        var resp = try client.connect(allocator, target);
        resp.deinit();
    }

    return client;
}

pub fn deinit(self: *Client, io: Io) void {
    self.sendRaw("-gdb-exit\n") catch {};
    self.flush() catch {};
    self.child.kill(io);
    self.* = undefined;
}

pub fn connect(self: *Client, allocator: Allocator, target: []const u8) Error!Response {
    const cmd = try std.fmt.allocPrint(allocator, "target-select remote {s}", .{target});
    defer allocator.free(cmd);
    return self.command(allocator, cmd);
}

pub fn disconnect(self: *Client, allocator: Allocator) Error!Response {
    return self.command(allocator, "target-disconnect");
}

pub fn command(self: *Client, allocator: Allocator, cmd: []const u8) Error!Response {
    const token = self.nextToken();
    try self.sendCommand(token, cmd);
    return self.readResponse(allocator, token, false);
}

/// Send an execution command (step, continue) and block until *stopped.
pub fn commandExpectStop(self: *Client, allocator: Allocator, cmd: []const u8) Error!Response {
    const token = self.nextToken();
    try self.sendCommand(token, cmd);
    return self.readResponse(allocator, token, true);
}

/// Send a raw GDB CLI command (not MI) and return console output.
pub fn cliCommand(self: *Client, allocator: Allocator, cmd: []const u8) Error!Response {
    const token = self.nextToken();

    self.writer.interface.print("{d}-interpreter-exec console \"{s}\"\n", .{ token, cmd }) catch return Error.WriteFailed;
    try self.flush();

    return self.readResponse(allocator, token, false);
}

fn readResponse(self: *Client, allocator: Allocator, token: u32, expect_stop: bool) Error!Response {
    var console: std.ArrayListUnmanaged(u8) = .empty;
    errdefer console.deinit(allocator);
    var stop: ?mi.AsyncRecord = null;
    errdefer if (stop) |s| s.deinit(allocator);
    var result: ?mi.ResultRecord = null;
    errdefer if (result) |r| r.deinit(allocator);

    while (true) {
        const line = try self.readLine();
        const record: mi.Record = mi.Record.parse(allocator, line) catch return Error.UnexpectedRecord;

        switch (record) {
            .prompt => continue,
            .console => |s| {
                try console.appendSlice(allocator, s);
                allocator.free(s);
            },
            .log, .target => |s| allocator.free(s),
            .notify_async, .status_async => |r| r.deinit(allocator),
            .exec_async => |r| {
                if (std.mem.eql(u8, r.class, "stopped")) {
                    if (expect_stop) {
                        return .{
                            .token = token,
                            .result = result orelse .{
                                .token = token,
                                .class = .running,
                                .results = .empty,
                            },
                            .console = console,
                            .stop = r,
                            .allocator = allocator,
                        };
                    }
                    stop = r;
                } else {
                    r.deinit(allocator);
                }
            },
            .result => |r| {
                if (r.token != null and r.token.? == token) {
                    if (expect_stop and r.class != .@"error") {
                        // For execution commands, stash the result and wait for *stopped
                        result = r;
                    } else {
                        return .{
                            .token = token,
                            .result = r,
                            .console = console,
                            .stop = stop,
                            .allocator = allocator,
                        };
                    }
                } else {
                    r.deinit(allocator);
                }
            },
        }
    }
}

fn nextToken(self: *Client) u32 {
    const token = self.next_token;
    self.next_token += 1;
    return token;
}

fn sendCommand(self: *Client, token: u32, cmd: []const u8) Error!void {
    self.writer.interface.print("{d}-{s}\n", .{ token, cmd }) catch return Error.WriteFailed;
    try self.flush();
}

fn sendRaw(self: *Client, data: []const u8) Error!void {
    self.writer.interface.writeAll(data) catch return Error.WriteFailed;
}

fn flush(self: *Client) Error!void {
    self.writer.interface.flush() catch return Error.WriteFailed;
}

fn readLine(self: *Client) Error![]const u8 {
    return self.reader.interface.takeDelimiterExclusive('\n') catch return Error.ReadFailed;
}

fn consumeUntilPrompt(self: *Client, allocator: Allocator) Error!void {
    while (true) {
        const line = try self.readLine();
        const record: mi.Record = mi.Record.parse(allocator, line) catch continue;
        switch (record) {
            .prompt => return,
            .console, .target, .log => |s| allocator.free(s),
            .result => |r| r.deinit(allocator),
            .exec_async, .status_async, .notify_async => |r| r.deinit(allocator),
        }
    }
}
