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
        .{
            "set_breakpoint",
            "Set a breakpoint. Args: location (address or symbol, required), temporary (bool), hardware (bool), condition (string)",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = false, .destructiveHint = false, .openWorldHint = false }),
            &setBreakpoint,
        },
        .{
            "remove_breakpoint",
            "Remove a breakpoint. Args: number (integer)",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &removeBreakpoint,
        },
        .{
            "list_breakpoints",
            "List all breakpoints",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &listBreakpoints,
        },
        .{
            "backtrace",
            "Get a stack backtrace",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &backtrace,
        },
        .{
            "disassemble",
            "Disassemble instructions. Args: address (hex string, required), count (integer, default 16)",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &disassemble,
        },
        .{
            "write_register",
            "Write a register value. Args: register (string), value (string)",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = true, .destructiveHint = true, .openWorldHint = false }),
            &writeRegister,
        },
        .{
            "eval_expression",
            "Evaluate a GDB expression. Args: expression (string)",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &evalExpression,
        },
        .{
            "lookup_symbol",
            "Look up a symbol address. Args: name (string)",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &lookupSymbol,
        },
        .{
            "info",
            "Get current execution state: PC, frame, privilege level",
            @as(ToolAnnotations, .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false }),
            &info,
        },
        .{
            "monitor",
            "Send a command to the QEMU monitor. Args: command (string). Examples: info tlb, info mem, info mtree, xp /16xg 0x80000000, system_reset",
            @as(ToolAnnotations, .{ .readOnlyHint = false, .idempotentHint = false, .destructiveHint = true, .openWorldHint = false }),
            &monitor,
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

fn setBreakpoint(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const location = mcp.tools.getString(arguments, "location") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: location");

    var cmd_buf: std.ArrayListUnmanaged(u8) = .empty;
    try cmd_buf.appendSlice(allocator, "break-insert");

    if (mcp.tools.getBoolean(arguments, "temporary") orelse false)
        try cmd_buf.appendSlice(allocator, " -t");
    if (mcp.tools.getBoolean(arguments, "hardware") orelse false)
        try cmd_buf.appendSlice(allocator, " -h");
    if (mcp.tools.getString(arguments, "condition")) |cond| {
        try cmd_buf.appendSlice(allocator, " -c \"");
        try cmd_buf.appendSlice(allocator, cond);
        try cmd_buf.append(allocator, '"');
    }

    try cmd_buf.append(allocator, ' ');
    try cmd_buf.appendSlice(allocator, location);

    const cmd = try cmd_buf.toOwnedSlice(allocator);
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to set breakpoint");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    // Format breakpoint info
    var output: std.ArrayListUnmanaged(u8) = .empty;
    if (resp.result.get("bkpt")) |bkpt_val| {
        const bkpt = bkpt_val.tuple;
        try output.appendSlice(allocator, "Breakpoint ");
        try output.appendSlice(allocator, bkpt.getString("number") orelse "?");
        try output.appendSlice(allocator, " at ");
        try output.appendSlice(allocator, bkpt.getString("addr") orelse "?");
        if (bkpt.getString("func")) |func| {
            try output.appendSlice(allocator, " in ");
            try output.appendSlice(allocator, func);
        }
        try output.append(allocator, '\n');
    } else {
        try output.appendSlice(allocator, "Breakpoint set\n");
    }

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn removeBreakpoint(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const number = mcp.tools.getInteger(arguments, "number") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: number");

    const cmd = std.fmt.allocPrint(allocator, "break-delete {d}", .{number}) catch return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to remove breakpoint");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const msg = std.fmt.allocPrint(allocator, "Breakpoint {d} removed", .{number}) catch return error.OutOfMemory;
    return try mcp.tools.textResult(allocator, msg);
}

fn listBreakpoints(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var resp = ts.client.command(allocator, "break-list") catch
        return try mcp.tools.errorResult(allocator, "Failed to list breakpoints");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    // break-list returns BreakpointTable={...body=[bkpt={...},bkpt={...}]}
    const table_val = resp.result.get("BreakpointTable") orelse
        return try mcp.tools.textResult(allocator, "No breakpoints");

    const body_val = table_val.tuple.get("body") orelse
        return try mcp.tools.textResult(allocator, "No breakpoints");

    const bkpts = switch (body_val) {
        .list => |l| switch (l) {
            .results => |rs| rs,
            .empty => return try mcp.tools.textResult(allocator, "No breakpoints"),
            else => return try mcp.tools.textResult(allocator, "No breakpoints"),
        },
        else => return try mcp.tools.textResult(allocator, "No breakpoints"),
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;

    for (bkpts) |entry| {
        const bkpt = entry.value.tuple;
        try output.appendSlice(allocator, bkpt.getString("number") orelse "?");
        try output.appendSlice(allocator, ": ");
        try output.appendSlice(allocator, bkpt.getString("type") orelse "breakpoint");
        try output.appendSlice(allocator, " at ");
        try output.appendSlice(allocator, bkpt.getString("addr") orelse "?");
        if (bkpt.getString("func")) |func| {
            try output.appendSlice(allocator, " in ");
            try output.appendSlice(allocator, func);
        }
        if (bkpt.getString("enabled")) |en| {
            if (std.mem.eql(u8, en, "n"))
                try output.appendSlice(allocator, " [disabled]");
        }
        try output.append(allocator, '\n');
    }

    if (output.items.len == 0)
        return try mcp.tools.textResult(allocator, "No breakpoints");

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn backtrace(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var resp = ts.client.command(allocator, "stack-list-frames") catch
        return try mcp.tools.errorResult(allocator, "Failed to get backtrace");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const stack_val = resp.result.get("stack") orelse
        return try mcp.tools.errorResult(allocator, "Missing stack in response");

    const frames = switch (stack_val) {
        .list => |l| switch (l) {
            .results => |rs| rs,
            .empty => return try mcp.tools.textResult(allocator, "Empty stack"),
            else => return try mcp.tools.errorResult(allocator, "Unexpected stack format"),
        },
        else => return try mcp.tools.errorResult(allocator, "Unexpected stack format"),
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;

    for (frames) |entry| {
        const frame = entry.value.tuple;
        try output.appendSlice(allocator, "#");
        try output.appendSlice(allocator, frame.getString("level") orelse "?");
        try output.appendSlice(allocator, "  ");
        try output.appendSlice(allocator, frame.getString("addr") orelse "?");
        if (frame.getString("func")) |func| {
            try output.appendSlice(allocator, " in ");
            try output.appendSlice(allocator, func);
        }
        if (frame.getString("file")) |file| {
            try output.appendSlice(allocator, " at ");
            try output.appendSlice(allocator, file);
            if (frame.getString("line")) |line| {
                try output.append(allocator, ':');
                try output.appendSlice(allocator, line);
            }
        }
        try output.append(allocator, '\n');
    }

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn disassemble(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const address = mcp.tools.getString(arguments, "address") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: address");

    const count = mcp.tools.getInteger(arguments, "count") orelse 16;

    // Use -data-disassemble with line count mode
    const cmd = std.fmt.allocPrint(allocator, "data-disassemble -s {s} -e {s}+{d} -- 0", .{ address, address, count * 4 }) catch
        return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to disassemble");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const asm_val = resp.result.get("asm_insns") orelse
        return try mcp.tools.errorResult(allocator, "Missing asm_insns in response");

    const insns = switch (asm_val) {
        .list => |l| switch (l) {
            .values => |vs| vs,
            .results => |rs| blk: {
                // Sometimes returned as results list
                var vals: std.ArrayListUnmanaged(mi.Value) = .empty;
                for (rs) |r| try vals.append(allocator, r.value);
                break :blk try vals.toOwnedSlice(allocator);
            },
            .empty => return try mcp.tools.textResult(allocator, "No instructions"),
        },
        else => return try mcp.tools.errorResult(allocator, "Unexpected asm_insns format"),
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;

    for (insns) |insn_val| {
        const insn = insn_val.tuple;
        try output.appendSlice(allocator, insn.getString("address") orelse "?");
        try output.appendSlice(allocator, "  ");
        try output.appendSlice(allocator, insn.getString("inst") orelse "?");
        if (insn.getString("func-name")) |func| {
            try output.appendSlice(allocator, "  <");
            try output.appendSlice(allocator, func);
            if (insn.getString("offset")) |off| {
                try output.append(allocator, '+');
                try output.appendSlice(allocator, off);
            }
            try output.append(allocator, '>');
        }
        try output.append(allocator, '\n');
    }

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn writeRegister(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const reg_name = mcp.tools.getString(arguments, "register") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: register");

    const value = mcp.tools.getString(arguments, "value") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: value");

    const cmd = std.fmt.allocPrint(allocator, "data-evaluate-expression ${s}={s}", .{ reg_name, value }) catch
        return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to write register");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const msg = std.fmt.allocPrint(allocator, "${s} = {s}", .{ reg_name, value }) catch return error.OutOfMemory;
    return try mcp.tools.textResult(allocator, msg);
}

fn evalExpression(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const expression = mcp.tools.getString(arguments, "expression") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: expression");

    const cmd = std.fmt.allocPrint(allocator, "data-evaluate-expression {s}", .{expression}) catch
        return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to evaluate expression");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const result_val = resp.result.results.getString("value") orelse "void";
    return try mcp.tools.textResult(allocator, result_val);
}

fn lookupSymbol(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const name = mcp.tools.getString(arguments, "name") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: name");

    const cmd = std.fmt.allocPrint(allocator, "data-evaluate-expression &{s}", .{name}) catch
        return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.command(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to lookup symbol");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const result_val = resp.result.results.getString("value") orelse "not found";
    const msg = std.fmt.allocPrint(allocator, "{s} = {s}", .{ name, result_val }) catch return error.OutOfMemory;
    return try mcp.tools.textResult(allocator, msg);
}

fn info(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    var output: std.ArrayListUnmanaged(u8) = .empty;

    // Current frame
    if (ts.client.command(allocator, "stack-info-frame")) |resp_val| {
        var resp = resp_val;
        defer resp.deinit();
        if (!resp.isError()) {
            if (resp.result.get("frame")) |frame_val| {
                const frame = frame_val.tuple;
                try output.appendSlice(allocator, "Frame: ");
                try output.appendSlice(allocator, frame.getString("addr") orelse "?");
                if (frame.getString("func")) |func| {
                    try output.appendSlice(allocator, " in ");
                    try output.appendSlice(allocator, func);
                }
                try output.append(allocator, '\n');
            }
        }
    } else |_| {}

    // Privilege level (RISC-V virtual register)
    if (ts.client.command(allocator, "data-evaluate-expression $priv")) |resp_val| {
        var resp = resp_val;
        defer resp.deinit();
        if (!resp.isError()) {
            if (resp.result.results.getString("value")) |val| {
                try output.appendSlice(allocator, "Privilege: ");
                try output.appendSlice(allocator, val);
                try output.append(allocator, '\n');
            }
        }
    } else |_| {}

    if (output.items.len == 0)
        return try mcp.tools.textResult(allocator, "No info available");

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn monitor(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const command = mcp.tools.getString(arguments, "command") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: command");

    const cmd = std.fmt.allocPrint(allocator, "monitor {s}", .{command}) catch return error.OutOfMemory;
    defer allocator.free(cmd);

    var resp = ts.client.cliCommand(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to execute monitor command");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const console_out = resp.consoleOutput();
    if (console_out.len == 0)
        return try mcp.tools.textResult(allocator, "OK");

    return try mcp.tools.textResult(allocator, console_out);
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
