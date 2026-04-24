const std = @import("std");

const mcp = @import("mcp");
const ToolError = mcp.tools.ToolError;
const ToolResult = mcp.tools.ToolResult;
const ToolAnnotations = mcp.tools.ToolAnnotations;

const Client = @import("gdb/Client.zig");
const mi = @import("gdb/mi.zig");

const ToolSet = @This();

client: *Client,

pub fn register(self: *ToolSet, server: *mcp.Server) !void {
    const tool_defs = .{
        .{
            "read_registers",
            "Read all CPU register values",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &readRegisters,
        },
        .{
            "step",
            "Single-step one instruction",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = false, .destructiveHint = false, .openWorldHint = false }),
            &step,
        },
        .{
            "continue",
            "Resume execution until breakpoint or stop",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = false, .destructiveHint = false, .openWorldHint = false }),
            &cont,
        },
        .{
            "stop",
            "Halt execution",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &stop,
        },
        .{
            "read_memory",
            "Read N bytes at an address. Args: address (hex string), count (integer)",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &readMemory,
        },
        .{
            "write_memory",
            "Write hex bytes to an address. Args: address (hex string), data (hex string)",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = true, .destructiveHint = true, .openWorldHint = false }),
            &writeMemory,
        },
    };

    inline for (tool_defs) |def| {
        try server.addTool(.{
            .name = def[0],
            .description = def[1],
            .annotations = def[2],
            .handler = def[3],
            .user_data = self,
        });
    }
}

fn formatStopReason(allocator: std.mem.Allocator, stop_record: ?mi.AsyncRecord) ![]const u8 {
    const r = stop_record orelse return try std.fmt.allocPrint(allocator, "stopped", .{});
    const reason = r.results.getString("reason") orelse "unknown";

    var output: std.ArrayListUnmanaged(u8) = .empty;
    try output.appendSlice(allocator, "stopped: ");
    try output.appendSlice(allocator, reason);

    if (r.results.get("frame")) |frame_val| {
        const frame = frame_val.tuple;
        if (frame.getString("addr")) |addr| {
            try output.appendSlice(allocator, " at ");
            try output.appendSlice(allocator, addr);
        }
        if (frame.getString("func")) |func| {
            try output.appendSlice(allocator, " in ");
            try output.appendSlice(allocator, func);
        }
    }
    try output.append(allocator, '\n');
    return try output.toOwnedSlice(allocator);
}

fn readRegisters(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var names_resp = ts.client.command(allocator, "data-list-register-names") catch
        return try mcp.tools.errorResult(allocator, "Failed to list register names");
    defer names_resp.deinit();

    if (names_resp.isError())
        return try mcp.tools.errorResult(allocator, names_resp.errorMessage() orelse "Unknown error");

    var values_resp = ts.client.command(allocator, "data-list-register-values x") catch
        return try mcp.tools.errorResult(allocator, "Failed to read register values");
    defer values_resp.deinit();

    if (values_resp.isError())
        return try mcp.tools.errorResult(allocator, values_resp.errorMessage() orelse "Unknown error");

    const names = extractValuesList(names_resp.result.get("register-names")) orelse
        return try mcp.tools.errorResult(allocator, "Missing register-names in response");

    const values = extractValuesList(values_resp.result.get("register-values")) orelse
        return try mcp.tools.errorResult(allocator, "Missing register-values in response");

    var output: std.ArrayListUnmanaged(u8) = .empty;

    for (values) |entry| {
        const reg = entry.tuple;
        const number_str = reg.getString("number") orelse continue;
        const value_str = reg.getString("value") orelse continue;

        const number = std.fmt.parseInt(usize, number_str, 10) catch continue;
        if (number >= names.len) continue;

        const name = switch (names[number]) {
            .string => |s| s,
            else => continue,
        };

        if (name.len == 0) continue;

        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, " = ");
        try output.appendSlice(allocator, value_str);
        try output.append(allocator, '\n');
    }

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn step(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var resp = ts.client.commandExpectStop(allocator, "exec-step-instruction") catch
        return try mcp.tools.errorResult(allocator, "Failed to step");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const text = formatStopReason(allocator, resp.stop) catch return error.OutOfMemory;
    return try mcp.tools.textResult(allocator, text);
}

fn cont(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var resp = ts.client.commandExpectStop(allocator, "exec-continue") catch
        return try mcp.tools.errorResult(allocator, "Failed to continue");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const text = formatStopReason(allocator, resp.stop) catch return error.OutOfMemory;
    return try mcp.tools.textResult(allocator, text);
}

fn stop(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var resp = ts.client.command(allocator, "exec-interrupt") catch
        return try mcp.tools.errorResult(allocator, "Failed to interrupt");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    return try mcp.tools.textResult(allocator, "Execution interrupted");
}

fn readMemory(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const address = mcp.tools.getString(arguments, "address") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: address");

    const count = mcp.tools.getInteger(arguments, "count") orelse 64;

    const cmd = std.fmt.allocPrint(allocator, "data-read-memory-bytes {s} {d}", .{ address, count }) catch
        return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to read memory");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    // Extract memory contents from response
    const memory_val = resp.result.get("memory") orelse
        return try mcp.tools.errorResult(allocator, "Missing memory in response");

    const memory = switch (memory_val) {
        .list => |l| switch (l) {
            .values => |vs| vs,
            else => return try mcp.tools.errorResult(allocator, "Unexpected memory format"),
        },
        else => return try mcp.tools.errorResult(allocator, "Unexpected memory format"),
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;

    for (memory) |entry| {
        const block = entry.tuple;
        const begin = block.getString("begin") orelse continue;
        const contents = block.getString("contents") orelse continue;

        try output.appendSlice(allocator, begin);
        try output.appendSlice(allocator, ": ");
        try output.appendSlice(allocator, contents);
        try output.append(allocator, '\n');
    }

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn writeMemory(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const address = mcp.tools.getString(arguments, "address") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: address");

    const data = mcp.tools.getString(arguments, "data") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: data");

    const cmd = std.fmt.allocPrint(allocator, "data-write-memory-bytes {s} {s}", .{ address, data }) catch
        return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to write memory");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const msg = std.fmt.allocPrint(allocator, "Wrote to {s}", .{address}) catch return error.OutOfMemory;
    return try mcp.tools.textResult(allocator, msg);
}

fn extractValuesList(val: ?mi.Value) ?[]const mi.Value {
    const v = val orelse return null;
    return switch (v) {
        .list => |l| switch (l) {
            .values => |vs| vs,
            else => null,
        },
        else => null,
    };
}
