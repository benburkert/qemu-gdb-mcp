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
    const tools = [_]mcp.tools.Tool{
        .{
            .name = "read_registers",
            .description = "Read all CPU register values",
            .handler = readRegisters,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "step",
            .description = "Single-step one instruction",
            .handler = step,
            .user_data = self,
        },
        .{
            .name = "continue",
            .description = "Resume execution until breakpoint or stop",
            .handler = cont,
            .user_data = self,
        },
        .{
            .name = "stop",
            .description = "Halt execution",
            .handler = stop,
            .annotations = .{ .idempotentHint = true },
            .user_data = self,
        },
        .{
            .name = "read_memory",
            .description = "Read N bytes at an address. Args: address (hex string), count (integer)",
            .handler = readMemory,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "write_memory",
            .description = "Write hex bytes to an address. Args: address (hex string), data (hex string)",
            .handler = writeMemory,
            .annotations = .{ .idempotentHint = true },
            .user_data = self,
        },
        .{
            .name = "set_breakpoint",
            .description = "Set a breakpoint. Args: location (address or symbol, required), temporary (bool), hardware (bool), condition (string)",
            .handler = setBreakpoint,
            .user_data = self,
        },
        .{
            .name = "remove_breakpoint",
            .description = "Remove a breakpoint. Args: number (integer)",
            .handler = removeBreakpoint,
            .annotations = .{ .idempotentHint = true },
            .user_data = self,
        },
        .{
            .name = "list_breakpoints",
            .description = "List all breakpoints",
            .handler = listBreakpoints,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "backtrace",
            .description = "Get a stack backtrace",
            .handler = backtrace,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "disassemble",
            .description = "Disassemble instructions. Args: address (hex string, required), count (integer, default 16)",
            .handler = disassemble,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "write_register",
            .description = "Write a register value. Args: register (string), value (string)",
            .handler = writeRegister,
            .annotations = .{ .idempotentHint = true },
            .user_data = self,
        },
        .{
            .name = "eval_expression",
            .description = "Evaluate a GDB expression. Args: expression (string)",
            .handler = evalExpression,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "lookup_symbol",
            .description = "Look up a symbol address. Args: name (string)",
            .handler = lookupSymbol,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "info",
            .description = "Get current execution state: PC, frame, privilege level",
            .handler = info,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "monitor",
            .description = "Send a command to the QEMU monitor. Args: command (string). Examples: info tlb, info mem, info mtree, xp /16xg 0x80000000, system_reset",
            .handler = monitor,
            .user_data = self,
        },
        .{
            .name = "stepi_no_irq",
            .description = "Single-step one instruction with IRQ/timer suppression. Prevents timer interrupts from disrupting stepping during kernel debugging.",
            .handler = stepiNoIrq,
            .user_data = self,
        },
        .{
            .name = "set_physical_memory_mode",
            .description = "Toggle QEMU physical memory mode. When enabled, read_memory/write_memory bypass the MMU. Args: enabled (bool)",
            .handler = setPhysicalMemoryMode,
            .annotations = .{ .idempotentHint = true },
            .user_data = self,
        },
        .{
            .name = "read_page_table",
            .description = "Walk RISC-V page table. Args: address (physical address of root page table, optional - defaults to satp), depth (max levels to walk, default 3)",
            .handler = readPageTable,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
    };

    for (tools) |tool| {
        try server.addTool(tool);
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

fn stepiNoIrq(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    // Save current sstep mask
    var save_resp = ts.client.cliCommand(allocator, "maintenance packet qqemu.sstep") catch
        return try mcp.tools.errorResult(allocator, "Failed to query sstep mask");
    defer save_resp.deinit();

    // Set sstep mask to suppress IRQs and timers (ENABLE=0x1 | NOTIMER=0x4 = 0x5)
    var set_resp = ts.client.cliCommand(allocator, "maintenance packet Qqemu.sstep=0x5") catch
        return try mcp.tools.errorResult(allocator, "Failed to set sstep mask");
    defer set_resp.deinit();

    // Step one instruction
    var step_resp = ts.client.commandExpectStop(allocator, "exec-step-instruction") catch
        return try mcp.tools.errorResult(allocator, "Failed to step");
    defer step_resp.deinit();

    // Restore original sstep mask
    const saved = save_resp.consoleOutput();
    if (std.mem.indexOf(u8, saved, "0x")) |start| {
        const hex_start = start;
        var hex_end = hex_start + 2;
        while (hex_end < saved.len and std.ascii.isHex(saved[hex_end])) : (hex_end += 1) {}
        const restore_cmd = std.fmt.allocPrint(allocator, "maintenance packet Qqemu.sstep={s}", .{saved[hex_start..hex_end]}) catch return error.OutOfMemory;
        defer allocator.free(restore_cmd);
        if (ts.client.cliCommand(allocator, restore_cmd)) |resp_val| {
            var resp = resp_val;
            resp.deinit();
        } else |_| {}
    }

    if (step_resp.isError())
        return try mcp.tools.errorResult(allocator, step_resp.errorMessage() orelse "Unknown error");

    const text = formatStopReason(allocator, step_resp.stop) catch return error.OutOfMemory;
    return try mcp.tools.textResult(allocator, text);
}

fn setPhysicalMemoryMode(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const enabled = mcp.tools.getBoolean(arguments, "enabled") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: enabled (bool)");

    const cmd = if (enabled)
        "maintenance packet Qqemu.PhyMemMode:1"
    else
        "maintenance packet Qqemu.PhyMemMode:0";

    var resp = ts.client.cliCommand(allocator, cmd) catch
        return try mcp.tools.errorResult(allocator, "Failed to set physical memory mode");
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    return try mcp.tools.textResult(allocator, if (enabled)
        "Physical memory mode enabled (MMU bypassed)"
    else
        "Physical memory mode disabled (virtual addresses)");
}

fn readPageTable(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const max_depth: usize = @intCast(mcp.tools.getInteger(arguments, "depth") orelse 3);

    // Determine page table root and mode
    var root_ppn: u64 = undefined;
    var mode: u4 = undefined;

    if (mcp.tools.getString(arguments, "address")) |addr_str| {
        root_ppn = std.fmt.parseInt(u64, stripHexPrefix(addr_str), 16) catch
            return try mcp.tools.errorResult(allocator, "Invalid address");
        root_ppn >>= 12; // convert physical address to PPN
        mode = 8; // assume Sv39
    } else {
        // Read satp CSR
        var resp = ts.client.command(allocator, "data-evaluate-expression $satp") catch
            return try mcp.tools.errorResult(allocator, "Failed to read satp");
        defer resp.deinit();

        if (resp.isError())
            return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Failed to read satp");

        const satp_str = resp.result.results.getString("value") orelse
            return try mcp.tools.errorResult(allocator, "Could not read satp value");

        const satp = std.fmt.parseInt(u64, stripHexPrefix(satp_str), 16) catch
            return try mcp.tools.errorResult(allocator, "Could not parse satp value");

        mode = @truncate(satp >> 60);
        root_ppn = satp & ((1 << 44) - 1);
    }

    const page_mode: PageMode = switch (mode) {
        0 => return try mcp.tools.textResult(allocator, "MMU disabled (satp mode = Bare)"),
        1 => .sv32,
        8 => .sv39,
        9 => .sv48,
        10 => .sv57,
        else => return try mcp.tools.errorResult(
            allocator,
            std.fmt.allocPrint(allocator, "Unknown satp mode: {d}", .{mode}) catch return error.OutOfMemory,
        ),
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;
    try output.appendSlice(allocator, page_mode.name());
    try output.appendSlice(allocator, " page table at 0x");

    const root_addr = root_ppn << 12;
    {
        var buf: [16]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "{x}", .{root_addr}) catch "?";
        try output.appendSlice(allocator, hex);
    }
    try output.appendSlice(allocator, "\n\n");

    // Walk the page table
    const walk_depth = @min(page_mode.levels(), max_depth);
    try walkPageTable(ts.client, allocator, &output, root_ppn, page_mode, walk_depth, 0, 0);

    if (output.items.len == 0)
        return try mcp.tools.textResult(allocator, "Empty page table");

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

const PageMode = enum {
    sv32,
    sv39,
    sv48,
    sv57,

    fn name(self: PageMode) []const u8 {
        return switch (self) {
            .sv32 => "Sv32",
            .sv39 => "Sv39",
            .sv48 => "Sv48",
            .sv57 => "Sv57",
        };
    }

    fn levels(self: PageMode) usize {
        return switch (self) {
            .sv32 => 2,
            .sv39 => 3,
            .sv48 => 4,
            .sv57 => 5,
        };
    }

    fn vpnBits(self: PageMode) u6 {
        return switch (self) {
            .sv32 => 10,
            .sv39, .sv48, .sv57 => 9,
        };
    }

    fn pteBytes(self: PageMode) usize {
        return switch (self) {
            .sv32 => 4,
            .sv39, .sv48, .sv57 => 8,
        };
    }

    fn entriesPerTable(self: PageMode) usize {
        return switch (self) {
            .sv32 => 1024,
            .sv39, .sv48, .sv57 => 512,
        };
    }

    fn tableSize(self: PageMode) usize {
        return self.entriesPerTable() * self.pteBytes();
    }

    fn ppnMask(self: PageMode) u64 {
        return switch (self) {
            .sv32 => (1 << 22) - 1,
            .sv39, .sv48, .sv57 => (1 << 44) - 1,
        };
    }

    fn vpnShift(self: PageMode, current_level: usize) u6 {
        return @intCast(12 + (self.levels() - 1 - current_level) * self.vpnBits());
    }

    fn signExtendVa(self: PageMode, va: u64) u64 {
        if (self == .sv32) return @as(u32, @truncate(va));
        const va_bits: u6 = @intCast(12 + self.levels() * @as(usize, self.vpnBits()));
        if (va >> (va_bits - 1) & 1 == 1) {
            return va | ~((@as(u64, 1) << va_bits) - 1);
        }
        return va;
    }

    fn readPte(self: PageMode, hex: []const u8, index: usize) ?u64 {
        const hex_chars = self.pteBytes() * 2;
        const offset = index * hex_chars;
        if (offset + hex_chars > hex.len) return null;

        const pte_hex = hex[offset..][0..hex_chars];
        var pte: u64 = 0;
        for (0..self.pteBytes()) |byte_idx| {
            const hi = std.fmt.charToDigit(pte_hex[byte_idx * 2], 16) catch return null;
            const lo = std.fmt.charToDigit(pte_hex[byte_idx * 2 + 1], 16) catch return null;
            const byte: u64 = (@as(u64, hi) << 4) | lo;
            pte |= byte << @intCast(byte_idx * 8);
        }
        return pte;
    }
};

fn walkPageTable(
    client: *Client,
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(u8),
    ppn: u64,
    mode: PageMode,
    remaining_depth: usize,
    current_level: usize,
    va_prefix: u64,
) !void {
    if (remaining_depth == 0) return;

    const page_addr = ppn << 12;
    const table_size = mode.tableSize();

    const cmd = std.fmt.allocPrint(allocator, "data-read-memory-bytes 0x{x} {d}", .{ page_addr, table_size }) catch return;
    defer allocator.free(cmd);

    // Enable physical memory mode
    _ = client.cliCommand(allocator, "maintenance packet Qqemu.PhyMemMode:1") catch return;
    defer {
        _ = client.cliCommand(allocator, "maintenance packet Qqemu.PhyMemMode:0") catch {};
    }

    var resp = client.command(allocator, cmd) catch return;
    defer resp.deinit();

    if (resp.isError()) return;

    const memory_val = resp.result.get("memory") orelse return;
    const memory = switch (memory_val) {
        .list => |l| switch (l) {
            .values => |vs| vs,
            else => return,
        },
        else => return,
    };

    if (memory.len == 0) return;
    const hex_data = memory[0].tuple.getString("contents") orelse return;

    for (0..mode.entriesPerTable()) |i| {
        const pte = mode.readPte(hex_data, i) orelse continue;
        if (pte & 1 == 0) continue; // V bit not set

        const pte_ppn = (pte >> 10) & mode.ppnMask();
        const flags = pte & 0xFF;
        const is_leaf = (flags & 0b1110) != 0;
        const va = va_prefix | (@as(u64, i) << mode.vpnShift(current_level));

        for (0..current_level) |_| try output.appendSlice(allocator, "  ");

        {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "[{d:>4}] 0x{x:0>16} -> 0x{x:0>16} {s}{s}{s}{s}{s}{s}{s}{s}\n", .{
                i,
                mode.signExtendVa(va),
                pte_ppn << 12,
                if (flags & 0x80 != 0) "D" else "-",
                if (flags & 0x40 != 0) "A" else "-",
                if (flags & 0x20 != 0) "G" else "-",
                if (flags & 0x10 != 0) "U" else "-",
                if (flags & 0x08 != 0) "X" else "-",
                if (flags & 0x04 != 0) "W" else "-",
                if (flags & 0x02 != 0) "R" else "-",
                if (is_leaf) " (leaf)" else " (table)",
            }) catch continue;
            try output.appendSlice(allocator, line);
        }

        if (!is_leaf and remaining_depth > 1) {
            try walkPageTable(client, allocator, output, pte_ppn, mode, remaining_depth - 1, current_level + 1, va);
        }
    }
}

fn stripHexPrefix(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))
        return s[2..];
    return s;
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
