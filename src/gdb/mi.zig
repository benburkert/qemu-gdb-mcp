const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    tuple: Tuple,
    list: List,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .tuple => |t| t.deinit(allocator),
            .list => |l| l.deinit(allocator),
        }
    }

    pub fn parse(allocator: Allocator, input: []const u8, pos: *usize) ParseError!@This() {
        if (pos.* >= input.len) return error.UnexpectedEnd;

        return switch (input[pos.*]) {
            '"' => .{ .string = try parseCString(allocator, input, pos) },
            '{' => .{ .tuple = try .parse(allocator, input, pos) },
            '[' => .{ .list = try .parse(allocator, input, pos) },
            else => error.UnexpectedChar,
        };
    }

    test "parse string" {
        var pos: usize = 0;
        const val: Value = try .parse(std.testing.allocator, "\"hello\"", &pos);
        defer val.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("hello", val.string);
        try std.testing.expectEqual(@as(usize, 7), pos);
    }

    test "parse tuple" {
        var pos: usize = 0;
        const val: Value = try .parse(std.testing.allocator, "{a=\"1\"}", &pos);
        defer val.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("1", val.tuple.getString("a").?);
    }

    test "parse list" {
        var pos: usize = 0;
        const val: Value = try .parse(std.testing.allocator, "[\"a\",\"b\"]", &pos);
        defer val.deinit(std.testing.allocator);
        try std.testing.expect(val.list.values.len == 2);
    }

    test "parse error on empty input" {
        var pos: usize = 0;
        try std.testing.expectError(error.UnexpectedEnd, Value.parse(std.testing.allocator, "", &pos));
    }

    test "parse error on unexpected char" {
        var pos: usize = 0;
        try std.testing.expectError(error.UnexpectedChar, Value.parse(std.testing.allocator, "abc", &pos));
    }
};

pub const Tuple = struct {
    results: []const Result,

    pub const empty: @This() = .{ .results = &.{} };

    pub fn deinit(self: @This(), allocator: Allocator) void {
        for (self.results) |r| r.deinit(allocator);
        // empty.results points to comptime memory, not heap — skip free
        if (self.results.ptr != empty.results.ptr) allocator.free(self.results);
    }

    fn parse(allocator: Allocator, input: []const u8, pos: *usize) ParseError!@This() {
        if (pos.* >= input.len or input[pos.*] != '{') return error.UnexpectedChar;
        pos.* += 1; // skip '{'

        if (pos.* < input.len and input[pos.*] == '}') {
            pos.* += 1;
            return .empty;
        }

        var results: std.ArrayListUnmanaged(Result) = .empty;

        const first: Result = try .parse(allocator, input, pos);
        try results.append(allocator, first);

        while (pos.* < input.len and input[pos.*] == ',') {
            pos.* += 1; // skip comma
            const r: Result = try .parse(allocator, input, pos);
            try results.append(allocator, r);
        }

        if (pos.* >= input.len or input[pos.*] != '}') return error.UnexpectedChar;
        pos.* += 1; // skip '}'

        return .{
            .results = try results.toOwnedSlice(allocator),
        };
    }

    // Parse a comma-separated list of key=value results at the top level of a record.
    fn parseResultList(allocator: Allocator, input: []const u8, pos: *usize) ParseError!@This() {
        var results: std.ArrayListUnmanaged(Result) = .empty;

        while (pos.* < input.len and input[pos.*] == ',') {
            pos.* += 1; // skip comma
            const r: Result = try .parse(allocator, input, pos);
            try results.append(allocator, r);
        }

        return .{
            .results = try results.toOwnedSlice(allocator),
        };
    }

    pub fn get(self: @This(), key: []const u8) ?Value {
        for (self.results) |r| {
            if (std.mem.eql(u8, r.variable, key)) return r.value;
        }
        return null;
    }

    pub fn getString(self: @This(), key: []const u8) ?[]const u8 {
        if (self.get(key)) |v| {
            switch (v) {
                .string => |s| return s,
                else => return null,
            }
        }
        return null;
    }

    test "parse empty" {
        var pos: usize = 0;
        const t: Tuple = try .parse(std.testing.allocator, "{}", &pos);
        try std.testing.expect(t.results.len == 0);
        try std.testing.expectEqual(@as(usize, 2), pos);
    }

    test "parse single result" {
        var pos: usize = 0;
        const t: Tuple = try .parse(std.testing.allocator, "{key=\"val\"}", &pos);
        defer t.deinit(std.testing.allocator);
        try std.testing.expect(t.results.len == 1);
        try std.testing.expectEqualStrings("val", t.getString("key").?);
    }

    test "parse multiple results" {
        var pos: usize = 0;
        const t: Tuple = try .parse(std.testing.allocator, "{a=\"1\",b=\"2\",c=\"3\"}", &pos);
        defer t.deinit(std.testing.allocator);
        try std.testing.expect(t.results.len == 3);
        try std.testing.expectEqualStrings("1", t.getString("a").?);
        try std.testing.expectEqualStrings("3", t.getString("c").?);
    }

    test "parse nested tuple" {
        var pos: usize = 0;
        const t: Tuple = try .parse(std.testing.allocator, "{inner={x=\"1\"}}", &pos);
        defer t.deinit(std.testing.allocator);
        const inner = t.get("inner").?.tuple;
        try std.testing.expectEqualStrings("1", inner.getString("x").?);
    }

    test "get missing key" {
        const t: Tuple = .empty;
        try std.testing.expect(t.get("missing") == null);
    }

    test "getString non-string value" {
        var pos: usize = 0;
        const t: Tuple = try .parse(std.testing.allocator, "{x={}}", &pos);
        defer t.deinit(std.testing.allocator);
        try std.testing.expect(t.getString("x") == null);
    }
};

pub const List = union(enum) {
    values: []const Value,
    results: []const Result,
    empty,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        switch (self) {
            .values => |vs| {
                for (vs) |v| v.deinit(allocator);
                allocator.free(vs);
            },
            .results => |rs| {
                for (rs) |r| r.deinit(allocator);
                allocator.free(rs);
            },
            .empty => {},
        }
    }

    pub fn parse(allocator: Allocator, input: []const u8, pos: *usize) ParseError!@This() {
        if (pos.* >= input.len or input[pos.*] != '[') return error.UnexpectedChar;
        pos.* += 1; // skip '['

        if (pos.* < input.len and input[pos.*] == ']') {
            pos.* += 1;
            return .empty;
        }

        // Peek to determine if this is a list of values or a list of results.
        // Results start with a word followed by '='. Values start with '"', '{', or '['.
        if (pos.* < input.len and (input[pos.*] == '"' or input[pos.*] == '{' or input[pos.*] == '[')) {
            // List of values
            var values: std.ArrayListUnmanaged(Value) = .empty;
            const first: Value = try .parse(allocator, input, pos);
            try values.append(allocator, first);

            while (pos.* < input.len and input[pos.*] == ',') {
                pos.* += 1;
                const v: Value = try .parse(allocator, input, pos);
                try values.append(allocator, v);
            }

            if (pos.* >= input.len or input[pos.*] != ']') return error.UnexpectedChar;
            pos.* += 1;
            return .{ .values = try values.toOwnedSlice(allocator) };
        } else {
            // List of results (key=value pairs)
            var results: std.ArrayListUnmanaged(Result) = .empty;
            const first: Result = try .parse(allocator, input, pos);
            try results.append(allocator, first);

            while (pos.* < input.len and input[pos.*] == ',') {
                pos.* += 1;
                const r: Result = try .parse(allocator, input, pos);
                try results.append(allocator, r);
            }

            if (pos.* >= input.len or input[pos.*] != ']') return error.UnexpectedChar;
            pos.* += 1;
            return .{ .results = try results.toOwnedSlice(allocator) };
        }
    }

    test "parse empty" {
        var pos: usize = 0;
        const l: List = try .parse(std.testing.allocator, "[]", &pos);
        try std.testing.expect(l == .empty);
    }

    test "parse values" {
        var pos: usize = 0;
        const l: List = try .parse(std.testing.allocator, "[\"a\",\"b\",\"c\"]", &pos);
        defer l.deinit(std.testing.allocator);
        try std.testing.expect(l.values.len == 3);
        try std.testing.expectEqualStrings("b", l.values[1].string);
    }

    test "parse results" {
        var pos: usize = 0;
        const l: List = try .parse(std.testing.allocator, "[x=\"1\",y=\"2\"]", &pos);
        defer l.deinit(std.testing.allocator);
        try std.testing.expect(l.results.len == 2);
        try std.testing.expectEqualStrings("x", l.results[0].variable);
    }

    test "parse list of tuples" {
        var pos: usize = 0;
        const l: List = try .parse(std.testing.allocator, "[{a=\"1\"},{a=\"2\"}]", &pos);
        defer l.deinit(std.testing.allocator);
        try std.testing.expect(l.values.len == 2);
        try std.testing.expectEqualStrings("1", l.values[0].tuple.getString("a").?);
        try std.testing.expectEqualStrings("2", l.values[1].tuple.getString("a").?);
    }
};

pub const Result = struct {
    variable: []const u8,
    value: Value,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.variable);
        self.value.deinit(allocator);
    }

    pub fn parse(allocator: Allocator, input: []const u8, pos: *usize) ParseError!@This() {
        const variable = parseWord(input, pos);
        if (variable.len == 0) return error.UnexpectedChar;

        if (pos.* >= input.len or input[pos.*] != '=') return error.UnexpectedChar;
        pos.* += 1; // skip '='

        const value: Value = try .parse(allocator, input, pos);
        return .{ .variable = try allocator.dupe(u8, variable), .value = value };
    }

    test "parse simple" {
        var pos: usize = 0;
        const r: Result = try .parse(std.testing.allocator, "key=\"value\"", &pos);
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("key", r.variable);
        try std.testing.expectEqualStrings("value", r.value.string);
    }

    test "parse with tuple value" {
        var pos: usize = 0;
        const r: Result = try .parse(std.testing.allocator, "obj={a=\"1\"}", &pos);
        defer r.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("obj", r.variable);
        try std.testing.expectEqualStrings("1", r.value.tuple.getString("a").?);
    }

    test "parse error missing equals" {
        var pos: usize = 0;
        try std.testing.expectError(error.UnexpectedChar, Result.parse(std.testing.allocator, "key\"value\"", &pos));
    }
};

pub const ResultRecord = struct {
    token: ?u32,
    class: Class,
    results: Tuple,

    pub const Class = enum {
        done,
        running,
        connected,
        @"error",
        exit,
    };

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.results.deinit(allocator);
    }

    pub fn parse(allocator: Allocator, token: ?u32, input: []const u8, pos: *usize) ParseError!@This() {
        const class_str = parseWord(input, pos);
        const class = std.meta.stringToEnum(Class, class_str) orelse return error.InvalidClass;
        const results: Tuple = try .parseResultList(allocator, input, pos);
        return .{ .token = token, .class = class, .results = results };
    }

    pub fn get(self: @This(), key: []const u8) ?Value {
        return self.results.get(key);
    }
};

pub const AsyncRecord = struct {
    token: ?u32,
    class: []const u8,
    results: Tuple,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.class);
        self.results.deinit(allocator);
    }

    pub fn parse(allocator: Allocator, token: ?u32, input: []const u8, pos: *usize) ParseError!@This() {
        const class = try allocator.dupe(u8, parseWord(input, pos));
        const results: Tuple = try .parseResultList(allocator, input, pos);
        return .{ .token = token, .class = class, .results = results };
    }

    pub fn get(self: @This(), key: []const u8) ?Value {
        return self.results.get(key);
    }
};

pub const Record = union(enum) {
    result: ResultRecord,
    exec_async: AsyncRecord,
    status_async: AsyncRecord,
    notify_async: AsyncRecord,
    console: []const u8,
    target: []const u8,
    log: []const u8,
    prompt,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        switch (self) {
            .result => |r| r.deinit(allocator),
            .exec_async, .status_async, .notify_async => |r| r.deinit(allocator),
            .console, .target, .log => |s| allocator.free(s),
            .prompt => {},
        }
    }

    pub fn parse(allocator: Allocator, line: []const u8) ParseError!@This() {
        if (line.len == 0) return error.UnexpectedEnd;

        // Check for (gdb) prompt
        if (std.mem.startsWith(u8, line, "(gdb)")) return .prompt;

        // Stream records: ~, @, &
        switch (line[0]) {
            '~' => return .{ .console = try parseStreamBody(allocator, line[1..]) },
            '@' => return .{ .target = try parseStreamBody(allocator, line[1..]) },
            '&' => return .{ .log = try parseStreamBody(allocator, line[1..]) },
            else => {},
        }

        // Result and async records may start with a token
        var pos: usize = 0;
        const token = parseToken(line, &pos);

        if (pos >= line.len) return error.UnexpectedEnd;

        const kind = line[pos];
        pos += 1;

        return switch (kind) {
            '^' => .{ .result = try .parse(allocator, token, line, &pos) },
            '*' => .{ .exec_async = try .parse(allocator, token, line, &pos) },
            '+' => .{ .status_async = try .parse(allocator, token, line, &pos) },
            '=' => .{ .notify_async = try .parse(allocator, token, line, &pos) },
            else => error.UnexpectedChar,
        };
    }

    fn parseToken(input: []const u8, pos: *usize) ?u32 {
        const start = pos.*;
        while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') {
            pos.* += 1;
        }
        if (pos.* == start) return null;
        return std.fmt.parseInt(u32, input[start..pos.*], 10) catch null;
    }

    test "parse prompt" {
        const record: Record = try .parse(std.testing.allocator, "(gdb)");
        try std.testing.expect(record == .prompt);
    }

    test "parse prompt with trailing space" {
        const record: Record = try .parse(std.testing.allocator, "(gdb) ");
        try std.testing.expect(record == .prompt);
    }

    test "parse console stream" {
        const record: Record = try .parse(std.testing.allocator, "~\"Hello, world!\\n\"");
        defer record.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("Hello, world!\n", record.console);
    }

    test "parse log stream" {
        const record: Record = try .parse(std.testing.allocator, "&\"warning: no loadable sections\\n\"");
        defer record.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("warning: no loadable sections\n", record.log);
    }

    test "parse result done with no results" {
        const record: Record = try .parse(std.testing.allocator, "^done");
        defer record.deinit(std.testing.allocator);
        try std.testing.expect(record.result.token == null);
        try std.testing.expect(record.result.class == .done);
        try std.testing.expect(record.result.results.results.len == 0);
    }

    test "parse result done with token" {
        const record: Record = try .parse(std.testing.allocator, "42^done");
        defer record.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 42), record.result.token.?);
        try std.testing.expect(record.result.class == .done);
    }

    test "parse result error" {
        const record: Record = try .parse(std.testing.allocator, "^error,msg=\"Command failed\"");
        defer record.deinit(std.testing.allocator);
        try std.testing.expect(record.result.class == .@"error");
        try std.testing.expectEqualStrings("Command failed", record.result.results.getString("msg").?);
    }

    test "parse result with simple value" {
        const record: Record = try .parse(std.testing.allocator, "^done,value=\"42\"");
        defer record.deinit(std.testing.allocator);
        const r = record.result;
        try std.testing.expect(r.results.results.len == 1);
        try std.testing.expectEqualStrings("value", r.results.results[0].variable);
        try std.testing.expectEqualStrings("42", r.results.results[0].value.string);
    }

    test "parse result with tuple" {
        const record: Record = try .parse(std.testing.allocator, "^done,bkpt={number=\"1\",type=\"breakpoint\",enabled=\"y\"}");
        defer record.deinit(std.testing.allocator);
        const bkpt = record.result.results.results[0].value.tuple;
        try std.testing.expectEqualStrings("1", bkpt.getString("number").?);
        try std.testing.expectEqualStrings("breakpoint", bkpt.getString("type").?);
        try std.testing.expectEqualStrings("y", bkpt.getString("enabled").?);
    }

    test "parse exec async stopped" {
        const record: Record = try .parse(std.testing.allocator, "*stopped,reason=\"breakpoint-hit\",thread-id=\"1\"");
        defer record.deinit(std.testing.allocator);
        const r = record.exec_async;
        try std.testing.expectEqualStrings("stopped", r.class);
        try std.testing.expectEqualStrings("breakpoint-hit", r.results.getString("reason").?);
        try std.testing.expectEqualStrings("1", r.results.getString("thread-id").?);
    }

    test "parse notify async" {
        const record: Record = try .parse(std.testing.allocator, "=thread-created,id=\"1\",group-id=\"i1\"");
        defer record.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("thread-created", record.notify_async.class);
        try std.testing.expectEqualStrings("1", record.notify_async.results.getString("id").?);
    }

    test "parse register values" {
        const input = "^done,register-values=[{number=\"0\",value=\"0xfffbf7c0\"},{number=\"1\",value=\"0x13\"}]";
        const record: Record = try .parse(std.testing.allocator, input);
        defer record.deinit(std.testing.allocator);
        const reg_values = record.result.results.results[0].value.list.values;
        try std.testing.expect(reg_values.len == 2);
        const first = reg_values[0].tuple;
        try std.testing.expectEqualStrings("0", first.getString("number").?);
        try std.testing.expectEqualStrings("0xfffbf7c0", first.getString("value").?);
    }

    test "parse stack frames" {
        const input = "^done,stack=[frame={level=\"0\",addr=\"0x08048384\",func=\"main\"},frame={level=\"1\",addr=\"0x08048480\",func=\"foo\"}]";
        const record: Record = try .parse(std.testing.allocator, input);
        defer record.deinit(std.testing.allocator);
        const stack = record.result.results.results[0].value.list.results;
        try std.testing.expect(stack.len == 2);
        try std.testing.expectEqualStrings("frame", stack[0].variable);
        const frame0 = stack[0].value.tuple;
        try std.testing.expectEqualStrings("0", frame0.getString("level").?);
        try std.testing.expectEqualStrings("main", frame0.getString("func").?);
    }

    test "parse empty tuple" {
        const record: Record = try .parse(std.testing.allocator, "^done,args={}");
        defer record.deinit(std.testing.allocator);
        const args = record.result.results.results[0].value.tuple;
        try std.testing.expect(args.results.len == 0);
    }

    test "parse empty list" {
        const record: Record = try .parse(std.testing.allocator, "^done,register-names=[]");
        defer record.deinit(std.testing.allocator);
        try std.testing.expect(record.result.results.results[0].value.list == .empty);
    }

    test "parse string with escapes" {
        const record: Record = try .parse(std.testing.allocator, "~\"tab:\\there\\n\"");
        defer record.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("tab:\there\n", record.console);
    }

    test "parse token with exec async" {
        const record: Record = try .parse(std.testing.allocator, "5*running,thread-id=\"all\"");
        defer record.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 5), record.exec_async.token.?);
        try std.testing.expectEqualStrings("running", record.exec_async.class);
    }

    test "parse memory read response" {
        const input = "^done,memory=[{begin=\"0x00001000\",offset=\"0x00000000\",end=\"0x00001004\",contents=\"deadbeef\"}]";
        const record: Record = try .parse(std.testing.allocator, input);
        defer record.deinit(std.testing.allocator);
        const mem = record.result.results.results[0].value.list.values;
        try std.testing.expect(mem.len == 1);
        const entry = mem[0].tuple;
        try std.testing.expectEqualStrings("deadbeef", entry.getString("contents").?);
    }
};

pub const ParseError = error{
    UnexpectedChar,
    UnexpectedEnd,
    InvalidEscape,
    InvalidToken,
    InvalidClass,
    OutOfMemory,
};

fn parseWord(input: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    while (pos.* < input.len and input[pos.*] != ',' and input[pos.*] != '=' and
        input[pos.*] != '{' and input[pos.*] != '}' and
        input[pos.*] != '[' and input[pos.*] != ']' and
        input[pos.*] != '"')
    {
        pos.* += 1;
    }
    return input[start..pos.*];
}

fn parseCString(allocator: Allocator, input: []const u8, pos: *usize) ParseError![]const u8 {
    if (pos.* >= input.len or input[pos.*] != '"') return error.UnexpectedChar;
    pos.* += 1; // skip opening quote

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    while (pos.* < input.len) {
        const c = input[pos.*];
        if (c == '"') {
            pos.* += 1; // skip closing quote
            return try buf.toOwnedSlice(allocator);
        }
        if (c == '\\') {
            pos.* += 1;
            if (pos.* >= input.len) return error.InvalidEscape;
            const escaped = input[pos.*];
            const replacement: u8 = switch (escaped) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                'a' => 0x07, // bell
                'b' => 0x08, // backspace
                'f' => 0x0c, // form feed
                '0'...'3' => blk: {
                    // Octal escape: 1-3 digits
                    const oct_start = pos.*;
                    pos.* += 1;
                    while (pos.* < input.len and pos.* < oct_start + 3 and
                        input[pos.*] >= '0' and input[pos.*] <= '7')
                    {
                        pos.* += 1;
                    }
                    const oct_str = input[oct_start..pos.*];
                    break :blk std.fmt.parseInt(u8, oct_str, 8) catch return error.InvalidEscape;
                },
                else => return error.InvalidEscape,
            };
            if (escaped < '0' or escaped > '3') {
                // Non-octal escapes: already advanced past the escape char indicator,
                // now advance past the escaped char
                pos.* += 1;
            }
            try buf.append(allocator, replacement);
        } else {
            try buf.append(allocator, c);
            pos.* += 1;
        }
    }

    return error.UnexpectedEnd; // unterminated string
}

test "parseCString simple" {
    var pos: usize = 0;
    const s = try parseCString(std.testing.allocator, "\"hello\"", &pos);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello", s);
}

test "parseCString all escapes" {
    var pos: usize = 0;
    const s = try parseCString(std.testing.allocator, "\"\\n\\t\\r\\\\\\\"\\a\\b\\f\"", &pos);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("\n\t\r\\\"\x07\x08\x0c", s);
}

test "parseCString octal escape" {
    var pos: usize = 0;
    const s = try parseCString(std.testing.allocator, "\"\\101\"", &pos);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("A", s); // 0o101 = 65 = 'A'
}

test "parseCString empty" {
    var pos: usize = 0;
    const s = try parseCString(std.testing.allocator, "\"\"", &pos);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("", s);
}

test "parseCString unterminated" {
    var pos: usize = 0;
    try std.testing.expectError(error.UnexpectedEnd, parseCString(std.testing.allocator, "\"hello", &pos));
}

test "parseCString invalid escape" {
    var pos: usize = 0;
    try std.testing.expectError(error.InvalidEscape, parseCString(std.testing.allocator, "\"\\z\"", &pos));
}

fn parseStreamBody(allocator: Allocator, input: []const u8) ParseError![]const u8 {
    var pos: usize = 0;
    return parseCString(allocator, input, &pos);
}
