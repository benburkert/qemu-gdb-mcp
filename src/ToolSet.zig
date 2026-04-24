const std = @import("std");

const mcp = @import("mcp");
const ToolError = mcp.tools.ToolError;
const ToolResult = mcp.tools.ToolResult;
const ToolAnnotations = mcp.tools.ToolAnnotations;

const Client = @import("gdb/Client.zig");
const mi = @import("gdb/mi.zig");

const ToolSet = @This();

client: ?*Client = null,
config: Client.Config,
timeout_ns: u64 = 10 * std.time.ns_per_s,
io: std.Io,
allocator: std.mem.Allocator,

fn ensureClient(self: *ToolSet) !*Client {
    if (self.client) |c| return c;

    const c = try self.allocator.create(Client);
    c.* = try Client.init(self.io, self.allocator, self.config);
    c.timeout_ns = self.timeout_ns;
    try c.start(self.io, self.allocator);
    self.client = c;
    return c;
}

pub fn deinit(self: *ToolSet) void {
    if (self.client) |c| {
        c.deinit(self.io);
        self.allocator.destroy(c);
        self.client = null;
    }
}

pub fn register(self: *ToolSet, server: *mcp.Server) !void {
    const tools = [_]mcp.tools.Tool{
        .{
            .name = "target_connect",
            .description = "Connect GDB to a remote target. Args: target (string, e.g. ':1234' or 'localhost:1234'), image (string, optional path to ELF binary to load symbols from)",
            .handler = targetConnect,
            .user_data = self,
        },
        .{
            .name = "target_disconnect",
            .description = "Disconnect GDB from the remote target. QEMU stays paused and can be reconnected.",
            .handler = targetDisconnect,
            .annotations = .{ .idempotentHint = true },
            .user_data = self,
        },
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
            .name = "list_threads",
            .description = "List all threads (harts). Shows thread ID, target ID, name, and current frame.",
            .handler = listThreads,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "select_thread",
            .description = "Switch to a specific thread (hart). Args: thread (integer, thread ID)",
            .handler = selectThread,
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
            .name = "read_csr",
            .description = "Read and decode a RISC-V CSR. Args: name (string, e.g. 'mstatus', 'satp', 'scause', 'sstatus', 'sie', 'sip', 'stvec', 'sepc', 'stval'). Returns the raw value and decoded bit fields.",
            .handler = readCsr,
            .annotations = .{ .readOnlyHint = true, .idempotentHint = true, .destructiveHint = false, .openWorldHint = false },
            .user_data = self,
        },
        .{
            .name = "watchpoint",
            .description = "Set a hardware watchpoint. Args: address (hex string, required), type (string: 'write', 'read', or 'access', default 'write')",
            .handler = watchpoint,
            .user_data = self,
        },
        .{
            .name = "next",
            .description = "Step over: execute one source line or instruction, stepping over function calls",
            .handler = next,
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

fn errResult(allocator: std.mem.Allocator, msg: []const u8, err: anyerror) ToolError!ToolResult {
    const text = std.fmt.allocPrint(allocator, "{s}: {s}", .{ msg, @errorName(err) }) catch
        return try mcp.tools.errorResult(allocator, msg);
    return try mcp.tools.errorResult(allocator, text);
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

fn targetConnect(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));

    const target = mcp.tools.getString(arguments, "target") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: target (e.g. ':1234')");

    const client = ts.ensureClient() catch
        return try mcp.tools.errorResult(allocator, "Failed to start GDB");

    // Optionally load symbol file first
    if (mcp.tools.getString(arguments, "image")) |image| {
        const file_cmd = try std.fmt.allocPrint(allocator, "file-exec-and-symbols {s}", .{image});
        defer allocator.free(file_cmd);
        var file_resp = client.command(allocator, file_cmd) catch |err| return errResult(allocator, "Failed to load symbols", err);
        defer file_resp.deinit();
    }

    var resp = client.connect(allocator, target) catch |err| return errResult(allocator, "Failed to connect", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Connection failed");

    var output: std.ArrayListUnmanaged(u8) = .empty;
    try output.appendSlice(allocator, "Connected to ");
    try output.appendSlice(allocator, target);
    try output.append(allocator, '\n');

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn targetDisconnect(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.disconnect(allocator) catch |err| return errResult(allocator, "Failed to disconnect", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Disconnect failed");

    return try mcp.tools.textResult(allocator, "Disconnected (QEMU stays paused)");
}

fn readRegisters(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var names_resp = client.command(allocator, "data-list-register-names") catch |err|
        return errResult(allocator, "Failed to list register names", err);
    defer names_resp.deinit();

    if (names_resp.isError())
        return try mcp.tools.errorResult(allocator, names_resp.errorMessage() orelse "Unknown error");

    var values_resp = client.command(allocator, "data-list-register-values x") catch |err|
        return errResult(allocator, "Failed to read register values", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.commandExpectStop(allocator, "exec-step-instruction") catch |err|
        return errResult(allocator, "Failed to step", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    return try mcp.tools.textResult(allocator, try formatStopReason(allocator, resp.stop));
}

fn cont(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.commandExpectStop(allocator, "exec-continue") catch |err|
        return errResult(allocator, "Failed to continue", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    return try mcp.tools.textResult(allocator, try formatStopReason(allocator, resp.stop));
}

fn stop(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.command(allocator, "exec-interrupt") catch |err|
        return errResult(allocator, "Failed to interrupt", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const address = mcp.tools.getString(arguments, "address") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: address");

    const count = mcp.tools.getInteger(arguments, "count") orelse 64;

    const cmd = try std.fmt.allocPrint(allocator, "data-read-memory-bytes {s} {d}", .{ address, count });
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to read memory", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const address = mcp.tools.getString(arguments, "address") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: address");

    const data = mcp.tools.getString(arguments, "data") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: data");

    const cmd = try std.fmt.allocPrint(allocator, "data-write-memory-bytes {s} {s}", .{ address, data });
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to write memory", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const msg = try std.fmt.allocPrint(allocator, "Wrote to {s}", .{address});
    return try mcp.tools.textResult(allocator, msg);
}

fn setBreakpoint(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

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

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to set breakpoint", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const number = mcp.tools.getInteger(arguments, "number") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: number");

    const cmd = try std.fmt.allocPrint(allocator, "break-delete {d}", .{number});
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to remove breakpoint", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const msg = try std.fmt.allocPrint(allocator, "Breakpoint {d} removed", .{number});
    return try mcp.tools.textResult(allocator, msg);
}

fn listBreakpoints(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.command(allocator, "break-list") catch |err|
        return errResult(allocator, "Failed to list breakpoints", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.command(allocator, "stack-list-frames") catch |err|
        return errResult(allocator, "Failed to get backtrace", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const address = mcp.tools.getString(arguments, "address") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: address");

    const count = mcp.tools.getInteger(arguments, "count") orelse 16;

    // Use -data-disassemble with line count mode
    const cmd = try std.fmt.allocPrint(allocator, "data-disassemble -s {s} -e {s}+{d} -- 0", .{ address, address, count * 4 });
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to disassemble", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const reg_name = mcp.tools.getString(arguments, "register") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: register");

    const value = mcp.tools.getString(arguments, "value") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: value");

    const cmd = try std.fmt.allocPrint(allocator, "data-evaluate-expression ${s}={s}", .{ reg_name, value });
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to write register", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const msg = try std.fmt.allocPrint(allocator, "${s} = {s}", .{ reg_name, value });
    return try mcp.tools.textResult(allocator, msg);
}

fn evalExpression(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const expression = mcp.tools.getString(arguments, "expression") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: expression");

    const cmd = try std.fmt.allocPrint(allocator, "data-evaluate-expression {s}", .{expression});
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to evaluate expression", err);
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const name = mcp.tools.getString(arguments, "name") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: name");

    const cmd = try std.fmt.allocPrint(allocator, "data-evaluate-expression &{s}", .{name});
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to lookup symbol", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const result_val = resp.result.results.getString("value") orelse "not found";
    const msg = try std.fmt.allocPrint(allocator, "{s} = {s}", .{ name, result_val });
    return try mcp.tools.textResult(allocator, msg);
}

fn info(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var output: std.ArrayListUnmanaged(u8) = .empty;

    // Current frame
    if (client.command(allocator, "stack-info-frame")) |resp_val| {
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
    if (client.command(allocator, "data-evaluate-expression $priv")) |resp_val| {
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
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const command = mcp.tools.getString(arguments, "command") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: command");

    const cmd = try std.fmt.allocPrint(allocator, "monitor {s}", .{command});
    defer allocator.free(cmd);

    var resp = client.cliCommand(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to execute monitor command", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const console_out = resp.consoleOutput();
    if (console_out.len == 0)
        return try mcp.tools.textResult(allocator, "OK");

    return try mcp.tools.textResult(allocator, console_out);
}

fn listThreads(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.command(allocator, "thread-info") catch |err| return errResult(allocator, "Failed to list threads", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const threads_val = resp.result.get("threads") orelse
        return try mcp.tools.errorResult(allocator, "Missing threads in response");

    const threads = switch (threads_val) {
        .list => |l| switch (l) {
            .values => |vs| vs,
            .empty => return try mcp.tools.textResult(allocator, "No threads"),
            else => return try mcp.tools.errorResult(allocator, "Unexpected threads format"),
        },
        else => return try mcp.tools.errorResult(allocator, "Unexpected threads format"),
    };

    var output: std.ArrayListUnmanaged(u8) = .empty;

    // Show current thread ID if available
    if (resp.result.results.getString("current-thread-id")) |current| {
        try output.appendSlice(allocator, "Current thread: ");
        try output.appendSlice(allocator, current);
        try output.append(allocator, '\n');
    }

    for (threads) |entry| {
        const thread = entry.tuple;
        const thread_id = thread.getString("id") orelse "?";
        try output.appendSlice(allocator, "Thread ");
        try output.appendSlice(allocator, thread_id);

        // Read mhartid for this thread to show the actual hart number
        {
            const sel_cmd = try std.fmt.allocPrint(allocator, "thread-select {s}", .{thread_id});
            defer allocator.free(sel_cmd);
            if (client.command(allocator, sel_cmd)) |sel_val| {
                var sel = sel_val;
                defer sel.deinit();
            } else |_| {}

            if (client.command(allocator, "data-evaluate-expression $mhartid")) |hartid_val| {
                var hartid_resp = hartid_val;
                defer hartid_resp.deinit();
                if (!hartid_resp.isError()) {
                    if (hartid_resp.result.results.getString("value")) |hartid| {
                        try output.appendSlice(allocator, " (hart ");
                        try output.appendSlice(allocator, hartid);
                        try output.append(allocator, ')');
                    }
                }
            } else |_| {}
        }

        if (thread.getString("target-id")) |tid| {
            try output.appendSlice(allocator, "  ");
            try output.appendSlice(allocator, tid);
        }
        if (thread.getString("name")) |name| {
            try output.appendSlice(allocator, "  ");
            try output.appendSlice(allocator, name);
        }
        if (thread.getString("state")) |state| {
            try output.appendSlice(allocator, "  (");
            try output.appendSlice(allocator, state);
            try output.appendSlice(allocator, ")");
        }
        if (thread.get("frame")) |frame_val| {
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
    }

    // Restore the original thread
    if (resp.result.results.getString("current-thread-id")) |current| {
        const restore_cmd = try std.fmt.allocPrint(allocator, "thread-select {s}", .{current});
        defer allocator.free(restore_cmd);
        if (client.command(allocator, restore_cmd)) |restore_val| {
            var restore = restore_val;
            restore.deinit();
        } else |_| {}
    }

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn selectThread(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const thread_id = mcp.tools.getInteger(arguments, "thread") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: thread (integer)");

    const cmd = try std.fmt.allocPrint(allocator, "thread-select {d}", .{thread_id});
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err| return errResult(allocator, "Failed to select thread", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    var output: std.ArrayListUnmanaged(u8) = .empty;
    try output.appendSlice(allocator, try std.fmt.allocPrint(allocator, "Switched to thread {d}", .{thread_id}));

    if (resp.result.get("frame")) |frame_val| {
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

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn stepiNoIrq(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    // Save current sstep mask
    var save_resp = client.cliCommand(allocator, "maintenance packet qqemu.sstep") catch |err|
        return errResult(allocator, "Failed to query sstep mask", err);
    defer save_resp.deinit();

    // Set sstep mask to suppress IRQs and timers (ENABLE=0x1 | NOTIMER=0x4 = 0x5)
    var set_resp = client.cliCommand(allocator, "maintenance packet Qqemu.sstep=0x5") catch |err|
        return errResult(allocator, "Failed to set sstep mask", err);
    defer set_resp.deinit();

    // Step one instruction
    var step_resp = client.commandExpectStop(allocator, "exec-step-instruction") catch |err|
        return errResult(allocator, "Failed to step", err);
    defer step_resp.deinit();

    // Restore original sstep mask by extracting it from the save response
    // The response contains the hex value in the console output
    const saved = save_resp.consoleOutput();
    if (std.mem.indexOf(u8, saved, "0x")) |start| {
        const hex_start = start;
        var hex_end = hex_start + 2;
        while (hex_end < saved.len and std.ascii.isHex(saved[hex_end])) : (hex_end += 1) {}
        const restore_cmd = try std.fmt.allocPrint(allocator, "maintenance packet Qqemu.sstep={s}", .{saved[hex_start..hex_end]});
        defer allocator.free(restore_cmd);
        if (client.cliCommand(allocator, restore_cmd)) |resp_val| {
            var resp = resp_val;
            resp.deinit();
        } else |_| {}
    }

    if (step_resp.isError())
        return try mcp.tools.errorResult(allocator, step_resp.errorMessage() orelse "Unknown error");

    return try mcp.tools.textResult(allocator, try formatStopReason(allocator, step_resp.stop));
}

fn setPhysicalMemoryMode(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const enabled = mcp.tools.getBoolean(arguments, "enabled") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: enabled (bool)");

    const cmd = if (enabled)
        "maintenance packet Qqemu.PhyMemMode:1"
    else
        "maintenance packet Qqemu.PhyMemMode:0";

    var resp = client.cliCommand(allocator, cmd) catch |err|
        return errResult(allocator, "Failed to set physical memory mode", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    return try mcp.tools.textResult(allocator, if (enabled)
        "Physical memory mode enabled (MMU bypassed)"
    else
        "Physical memory mode disabled (virtual addresses)");
}

fn readCsr(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const name = mcp.tools.getString(arguments, "name") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: name (e.g. 'mstatus', 'satp', 'scause')");

    const cmd = try std.fmt.allocPrint(allocator, "data-evaluate-expression ${s}", .{name});
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err| return errResult(allocator, "Failed to read CSR", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    const val_str = resp.result.results.getString("value") orelse
        return try mcp.tools.errorResult(allocator, "Could not read CSR value");

    // Parse as hex, unsigned decimal, or signed decimal (rv32 returns negative for high-bit CSRs)
    const val = std.fmt.parseInt(u64, stripHexPrefix(val_str), 16) catch
        std.fmt.parseInt(u64, val_str, 10) catch
            @as(u64, @bitCast(@as(i64, std.fmt.parseInt(i64, val_str, 10) catch
                return try mcp.tools.textResult(allocator, try std.fmt.allocPrint(allocator, "{s} = {s}", .{ name, val_str })))));

    var output: std.ArrayListUnmanaged(u8) = .empty;
    try output.appendSlice(allocator, name);
    try output.appendSlice(allocator, " = ");
    {
        var buf: [20]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "0x{x}", .{val}) catch "?";
        try output.appendSlice(allocator, hex);
    }
    try output.append(allocator, '\n');

    // Decode known CSRs
    if (std.mem.eql(u8, name, "mstatus") or std.mem.eql(u8, name, "sstatus")) {
        try decodeMstatus(&output, allocator, val, std.mem.eql(u8, name, "sstatus"));
    } else if (std.mem.eql(u8, name, "scause") or std.mem.eql(u8, name, "mcause")) {
        try decodeScause(&output, allocator, val);
    } else if (std.mem.eql(u8, name, "satp")) {
        try decodeSatp(&output, allocator, val);
    } else if (std.mem.eql(u8, name, "sie") or std.mem.eql(u8, name, "sip") or
        std.mem.eql(u8, name, "mie") or std.mem.eql(u8, name, "mip"))
    {
        try decodeInterruptBits(&output, allocator, val);
    } else if (std.mem.eql(u8, name, "stvec") or std.mem.eql(u8, name, "mtvec")) {
        try decodeTvec(&output, allocator, val);
    }

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn decodeMstatus(output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u64, is_sstatus: bool) !void {
    const fields = .{
        .{ "SIE", 1 },
        .{ "MIE", 3 },
        .{ "SPIE", 5 },
        .{ "UBE", 6 },
        .{ "MPIE", 7 },
        .{ "SPP", 8 },
        .{ "MPP", 11 },  // 2-bit field
        .{ "FS", 13 },   // 2-bit field
        .{ "XS", 15 },   // 2-bit field
        .{ "MPRV", 17 },
        .{ "SUM", 18 },
        .{ "MXR", 19 },
        .{ "TVM", 20 },
        .{ "TW", 21 },
        .{ "TSR", 22 },
    };

    try output.appendSlice(allocator, "  ");
    var first = true;
    inline for (fields) |field| {
        const is_m_only = comptime (std.mem.eql(u8, field[0], "MIE") or
            std.mem.eql(u8, field[0], "MPIE") or
            std.mem.eql(u8, field[0], "MPP") or
            std.mem.eql(u8, field[0], "MPRV"));

        if (!is_m_only or !is_sstatus) {
            const bit: u6 = field[1];
            const is_two_bit = comptime (std.mem.eql(u8, field[0], "MPP") or
                std.mem.eql(u8, field[0], "FS") or
                std.mem.eql(u8, field[0], "XS"));
            const field_val = if (is_two_bit) (val >> bit) & 0x3 else (val >> bit) & 0x1;

            if (field_val != 0) {
                if (!first) try output.appendSlice(allocator, " ");
                first = false;
                try output.appendSlice(allocator, field[0]);
                try output.append(allocator, '=');
                var buf: [4]u8 = undefined;
                const num = std.fmt.bufPrint(&buf, "{d}", .{field_val}) catch "?";
                try output.appendSlice(allocator, num);
            }
        }
    }
    try output.append(allocator, '\n');
}

fn decodeScause(output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u64) !void {
    const interrupt = (val >> 63) & 1 == 1;
    const code: u6 = @truncate(val & 0x3F);

    try output.appendSlice(allocator, "  ");
    try output.appendSlice(allocator, if (interrupt) "Interrupt: " else "Exception: ");

    const name = if (interrupt) switch (code) {
        1 => "Supervisor software interrupt",
        3 => "Machine software interrupt",
        5 => "Supervisor timer interrupt",
        7 => "Machine timer interrupt",
        9 => "Supervisor external interrupt",
        11 => "Machine external interrupt",
        else => "Unknown interrupt",
    } else switch (code) {
        0 => "Instruction address misaligned",
        1 => "Instruction access fault",
        2 => "Illegal instruction",
        3 => "Breakpoint",
        4 => "Load address misaligned",
        5 => "Load access fault",
        6 => "Store/AMO address misaligned",
        7 => "Store/AMO access fault",
        8 => "Environment call from U-mode",
        9 => "Environment call from S-mode",
        11 => "Environment call from M-mode",
        12 => "Instruction page fault",
        13 => "Load page fault",
        15 => "Store/AMO page fault",
        else => "Unknown exception",
    };
    try output.appendSlice(allocator, name);
    try output.append(allocator, '\n');
}

fn decodeSatp(output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u64) !void {
    const mode: u4 = @truncate(val >> 60);
    const asid: u16 = @truncate((val >> 44) & 0xFFFF);
    const ppn = val & ((1 << 44) - 1);

    const mode_name: []const u8 = switch (mode) {
        0 => "Bare (no translation)",
        1 => "Sv32",
        8 => "Sv39",
        9 => "Sv48",
        10 => "Sv57",
        else => "Unknown",
    };

    try output.appendSlice(allocator, "  Mode=");
    try output.appendSlice(allocator, mode_name);
    {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " ASID={d} PPN=0x{x} (root=0x{x})", .{ asid, ppn, ppn << 12 }) catch "?";
        try output.appendSlice(allocator, s);
    }
    try output.append(allocator, '\n');
}

fn decodeInterruptBits(output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u64) !void {
    const bits = .{
        .{ "SSI", 1 },
        .{ "MSI", 3 },
        .{ "STI", 5 },
        .{ "MTI", 7 },
        .{ "SEI", 9 },
        .{ "MEI", 11 },
    };

    try output.appendSlice(allocator, "  ");
    var first = true;
    inline for (bits) |bit| {
        if ((val >> bit[1]) & 1 == 1) {
            if (!first) try output.appendSlice(allocator, " ");
            first = false;
            try output.appendSlice(allocator, bit[0]);
        }
    }
    if (first) try output.appendSlice(allocator, "(none)");
    try output.append(allocator, '\n');
}

fn decodeTvec(output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u64) !void {
    const mode: u2 = @truncate(val & 0x3);
    const base = val & ~@as(u64, 0x3);

    try output.appendSlice(allocator, "  Mode=");
    try output.appendSlice(allocator, switch (mode) {
        0 => "Direct",
        1 => "Vectored",
        else => "Reserved",
    });
    {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " Base=0x{x}", .{base}) catch "?";
        try output.appendSlice(allocator, s);
    }
    try output.append(allocator, '\n');
}

fn watchpoint(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const address = mcp.tools.getString(arguments, "address") orelse
        return try mcp.tools.errorResult(allocator, "Missing required argument: address");

    const wp_type = mcp.tools.getString(arguments, "type") orelse "write";

    const flag = if (std.mem.eql(u8, wp_type, "read"))
        " -r"
    else if (std.mem.eql(u8, wp_type, "access"))
        " -a"
    else
        "";

    // Format as memory dereference for GDB: *(int *)0xaddr
    const expr = try std.fmt.allocPrint(allocator, "*(int *){s}", .{address});
    defer allocator.free(expr);

    const cmd = try std.fmt.allocPrint(allocator, "break-watch{s} \"{s}\"", .{ flag, expr });
    defer allocator.free(cmd);

    var resp = client.command(allocator, cmd) catch |err| return errResult(allocator, "Failed to set watchpoint", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    var output: std.ArrayListUnmanaged(u8) = .empty;
    // Response may contain wpt={number="N",exp="addr"}
    if (resp.result.get("wpt")) |wpt_val| {
        const wpt = wpt_val.tuple;
        try output.appendSlice(allocator, "Watchpoint ");
        try output.appendSlice(allocator, wpt.getString("number") orelse "?");
        try output.appendSlice(allocator, ": ");
        try output.appendSlice(allocator, wp_type);
        try output.appendSlice(allocator, " on ");
        try output.appendSlice(allocator, wpt.getString("exp") orelse address);
    } else {
        try output.appendSlice(allocator, "Watchpoint set on ");
        try output.appendSlice(allocator, address);
    }
    try output.append(allocator, '\n');

    return try mcp.tools.textResult(allocator, try output.toOwnedSlice(allocator));
}

fn next(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    var resp = client.commandExpectStop(allocator, "exec-next-instruction") catch |err|
        return errResult(allocator, "Failed to next", err);
    defer resp.deinit();

    if (resp.isError())
        return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Unknown error");

    return try mcp.tools.textResult(allocator, try formatStopReason(allocator, resp.stop));
}

fn readPageTable(
    user_data: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) ToolError!ToolResult {
    const ts: *ToolSet = @ptrCast(@alignCast(user_data.?));
    const client = ts.client orelse return try mcp.tools.errorResult(allocator, "Not connected. Use target_connect first.");

    const max_depth: usize = @intCast(mcp.tools.getInteger(arguments, "depth") orelse 3);

    // Determine page table root and mode
    var root_ppn: u64 = undefined;
    var mode: u4 = undefined;

    if (mcp.tools.getString(arguments, "address")) |addr_str| {
        root_ppn = std.fmt.parseInt(u64, stripHexPrefix(addr_str), 16) catch |err|
            return errResult(allocator, "Invalid address", err);
        root_ppn >>= 12; // convert physical address to PPN
        mode = 8; // assume Sv39
    } else {
        // Read satp CSR
        var resp = client.command(allocator, "data-evaluate-expression $satp") catch |err|
            return errResult(allocator, "Failed to read satp", err);
        defer resp.deinit();

        if (resp.isError())
            return try mcp.tools.errorResult(allocator, resp.errorMessage() orelse "Failed to read satp");

        const satp_str = resp.result.results.getString("value") orelse
            return try mcp.tools.errorResult(allocator, "Could not read satp value");

        const satp = std.fmt.parseInt(u64, stripHexPrefix(satp_str), 16) catch |err|
            return errResult(allocator, "Could not parse satp value", err);

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
            try std.fmt.allocPrint(allocator, "Unknown satp mode: {d}", .{mode}),
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
    try walkPageTable(client, allocator, &output, root_ppn, page_mode, walk_depth, 0, 0);

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
