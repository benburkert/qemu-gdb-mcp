const std = @import("std");

const mcp = @import("mcp");

const Client = @import("gdb/Client.zig");
const mi = @import("gdb/mi.zig");

const ToolSet = @This();

client: *Client,

pub fn tools(self: *ToolSet) [1]mcp.tools.Tool {
    return .{
        .{
            .name = "read_registers",
            .description = "Read all CPU register values",
            .annotations = .{
                .readOnlyHint = true,
                .idempotentHint = true,
                .destructiveHint = false,
                .openWorldHint = false,
            },
            .handler = readRegisters,
            .user_data = self,
        },
    };
}

fn readRegisters(
    user_data: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = io;
    const self: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var names_resp = self.client.command(allocator, "data-list-register-names") catch
        return try mcp.tools.errorResult(allocator, "Failed to list register names");
    defer names_resp.deinit();

    if (names_resp.isError())
        return try mcp.tools.errorResult(allocator, names_resp.errorMessage() orelse "Unknown error");

    var values_resp = self.client.command(allocator, "data-list-register-values x") catch
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

pub fn register(self: *ToolSet, server: *mcp.Server) !void {
    for (&self.tools()) |*tool| {
        try server.addTool(tool.*);
    }
}
