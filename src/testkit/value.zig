//! Typed observation values: strings with the prefix `u:`, `i:`, `x:`, `s:`, `b:` or `h:`.
//! The parser is strict and accepts only the canonical form, so equal values
//! have equal text: no leading zeros, lower-case hex, no `-0`. Values compare by kind and text.
const std = @import("std");

pub const Kind = enum(u8) {
    unsigned,
    signed,
    bytes,
    text,
    boolean,
    hash,

    pub fn prefix(kind: Kind) u8 {
        return switch (kind) {
            .unsigned => 'u',
            .signed => 'i',
            .bytes => 'x',
            .text => 's',
            .boolean => 'b',
            .hash => 'h',
        };
    }
};

pub const Value = struct {
    kind: Kind,
    /// The text after the prefix. The value does not own it; it is in the arena of the fixture.
    body: []const u8,

    pub const ParseError = error{InvalidValue};

    pub fn parse(typed: []const u8) ParseError!Value {
        if (typed.len < 2 or typed[1] != ':') return error.InvalidValue;
        const body = typed[2..];
        const kind: Kind = switch (typed[0]) {
            'u' => .unsigned,
            'i' => .signed,
            'x' => .bytes,
            's' => .text,
            'b' => .boolean,
            'h' => .hash,
            else => return error.InvalidValue,
        };
        switch (kind) {
            .unsigned => {
                _ = std.fmt.parseInt(u64, body, 10) catch return error.InvalidValue;
                if (!canonicalDecimal(body)) return error.InvalidValue;
            },
            .signed => {
                _ = std.fmt.parseInt(i64, body, 10) catch return error.InvalidValue;
                const digits = if (body.len > 0 and body[0] == '-') body[1..] else body;
                if (!canonicalDecimal(digits)) return error.InvalidValue;
                if (std.mem.eql(u8, body, "-0")) return error.InvalidValue;
            },
            .bytes => if (body.len % 2 != 0 or !isLowerHex(body)) return error.InvalidValue,
            .hash => if (body.len != 64 or !isLowerHex(body)) return error.InvalidValue,
            .boolean => if (!std.mem.eql(u8, body, "true") and !std.mem.eql(u8, body, "false")) return error.InvalidValue,
            .text => {},
        }
        return .{ .kind = kind, .body = body };
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.body, b.body);
    }

    /// Prints the typed form, for example `u:42`.
    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte(v.kind.prefix());
        try w.writeByte(':');
        try w.writeAll(v.body);
    }

    pub fn asUnsigned(v: Value) ?u64 {
        if (v.kind != .unsigned) return null;
        return std.fmt.parseInt(u64, v.body, 10) catch null;
    }

    pub fn asSigned(v: Value) ?i64 {
        if (v.kind != .signed) return null;
        return std.fmt.parseInt(i64, v.body, 10) catch null;
    }

    pub fn asBool(v: Value) ?bool {
        if (v.kind != .boolean) return null;
        return std.mem.eql(u8, v.body, "true");
    }

    /// The constructors that take `arena` allocate the body in it.
    pub fn unsigned(arena: std.mem.Allocator, n: u64) error{OutOfMemory}!Value {
        return .{ .kind = .unsigned, .body = try std.fmt.allocPrint(arena, "{d}", .{n}) };
    }

    pub fn signed(arena: std.mem.Allocator, n: i64) error{OutOfMemory}!Value {
        return .{ .kind = .signed, .body = try std.fmt.allocPrint(arena, "{d}", .{n}) };
    }

    pub fn boolean(b: bool) Value {
        return .{ .kind = .boolean, .body = if (b) "true" else "false" };
    }

    pub fn text(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}!Value {
        return .{ .kind = .text, .body = try arena.dupe(u8, s) };
    }

    pub fn bytes(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!Value {
        const hex = try arena.alloc(u8, raw.len * 2);
        for (raw, 0..) |byte, i| {
            hex[i * 2] = hexDigit(byte >> 4);
            hex[i * 2 + 1] = hexDigit(byte & 0xf);
        }
        return .{ .kind = .bytes, .body = hex };
    }

    pub fn hash(arena: std.mem.Allocator, digest: [32]u8) error{OutOfMemory}!Value {
        const v = try bytes(arena, &digest);
        return .{ .kind = .hash, .body = v.body };
    }
};

fn hexDigit(n: u8) u8 {
    return if (n < 10) '0' + n else 'a' + (n - 10);
}

fn canonicalDecimal(d: []const u8) bool {
    if (d.len == 0) return false;
    if (d.len > 1 and d[0] == '0') return false;
    for (d) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isLowerHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

test "typed values parse strictly" {
    try std.testing.expectEqual(@as(u64, 18446744073709551615), (try Value.parse("u:18446744073709551615")).asUnsigned().?);
    try std.testing.expectEqual(@as(i64, -5), (try Value.parse("i:-5")).asSigned().?);
    try std.testing.expect((try Value.parse("b:true")).asBool().?);
    try std.testing.expectEqual(Kind.bytes, (try Value.parse("x:")).kind);
    try std.testing.expectEqual(Kind.text, (try Value.parse("s:")).kind);
    try std.testing.expectEqual(Kind.hash, (try Value.parse("h:abababababababababababababababababababababababababababababababab")).kind);
    for ([_][]const u8{ "", "u", "u:", "u:007", "u:18446744073709551616", "i:-0", "i:+3", "x:abc", "x:AB", "h:ab", "b:yes", "q:1", "5" }) |bad| {
        try std.testing.expectError(error.InvalidValue, Value.parse(bad));
    }
}

test "values compare by kind and text" {
    try std.testing.expect(!(try Value.parse("u:5")).eql(try Value.parse("i:5")));
    try std.testing.expect((try Value.parse("u:5")).eql(try Value.parse("u:5")));
    var buf: [64]u8 = undefined;
    const v = try Value.unsigned(std.testing.allocator, 42);
    defer std.testing.allocator.free(v.body);
    try std.testing.expectEqualStrings("u:42", try std.fmt.bufPrint(&buf, "{f}", .{v}));
    const b = try Value.bytes(std.testing.allocator, &.{ 0x00, 0xab, 0xff });
    defer std.testing.allocator.free(b.body);
    try std.testing.expectEqualStrings("00abff", b.body);
}
