//! Named observations, the sink that drivers write them to, and the `testkit-observations/1` file.
const std = @import("std");
const Value = @import("value.zig").Value;

pub const Observation = struct {
    name: []const u8,
    value: Value,
    /// The `in` object of the producer (the inputs of the observation), when the file has one.
    /// Only reimplementation drivers read it; the comparison ignores it.
    inputs: ?std.json.ObjectMap = null,
};

/// Collects the actual observations of a driver, with names and bodies copied into the arena.
pub const Sink = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList(Observation) = .empty,

    pub fn init(arena: std.mem.Allocator) Sink {
        return .{ .arena = arena };
    }

    /// Copies the name and the value body, so a caller can give temporary memory.
    pub fn observe(self: *Sink, name: []const u8, value: Value) error{OutOfMemory}!void {
        const copy = try self.arena.dupe(u8, name);
        const body = try self.arena.dupe(u8, value.body);
        try self.items.append(self.arena, .{ .name = copy, .value = .{ .kind = value.kind, .body = body } });
    }

    pub fn unsigned(self: *Sink, name: []const u8, n: u64) error{OutOfMemory}!void {
        try self.observe(name, try Value.unsigned(self.arena, n));
    }

    pub fn signed(self: *Sink, name: []const u8, n: i64) error{OutOfMemory}!void {
        try self.observe(name, try Value.signed(self.arena, n));
    }

    pub fn boolean(self: *Sink, name: []const u8, b: bool) error{OutOfMemory}!void {
        try self.observe(name, Value.boolean(b));
    }

    pub fn text(self: *Sink, name: []const u8, s: []const u8) error{OutOfMemory}!void {
        try self.observe(name, try Value.text(self.arena, s));
    }

    pub fn bytes(self: *Sink, name: []const u8, raw: []const u8) error{OutOfMemory}!void {
        try self.observe(name, try Value.bytes(self.arena, raw));
    }

    pub fn hash(self: *Sink, name: []const u8, digest: [32]u8) error{OutOfMemory}!void {
        try self.observe(name, try Value.hash(self.arena, digest));
    }

    /// A 64-bit hash reported as an unsigned value.
    pub fn hash64(self: *Sink, name: []const u8, h: u64) error{OutOfMemory}!void {
        try self.unsigned(name, h);
    }

    pub fn slice(self: *const Sink) []const Observation {
        return self.items.items;
    }
};

pub const schema = "testkit-observations/1";

pub const ParsedObservations = struct {
    observations: []Observation,
    producer: ?std.json.Value,
};

pub const ParseError = error{ InvalidObservationFile, OutOfMemory };

/// Parses an observation file. Everything is allocated in `arena`.
pub fn parseFile(arena: std.mem.Allocator, bytes: []const u8) ParseError!ParsedObservations {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidObservationFile,
    };
    if (root != .object) return error.InvalidObservationFile;
    const schema_value = root.object.get("schema") orelse return error.InvalidObservationFile;
    if (schema_value != .string or !std.mem.eql(u8, schema_value.string, schema)) return error.InvalidObservationFile;
    const list = root.object.get("observations") orelse return error.InvalidObservationFile;
    if (list != .array) return error.InvalidObservationFile;
    return .{
        .observations = try parseArray(arena, list.array),
        .producer = root.object.get("producer"),
    };
}

/// Parses a JSON array of `{ "n": name, "v": typed value, "in"?: object }` objects.
pub fn parseArray(arena: std.mem.Allocator, array: std.json.Array) ParseError![]Observation {
    const out = try arena.alloc(Observation, array.items.len);
    for (array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidObservationFile;
        const n = item.object.get("n") orelse return error.InvalidObservationFile;
        const v = item.object.get("v") orelse return error.InvalidObservationFile;
        if (n != .string or v != .string) return error.InvalidObservationFile;
        const value = Value.parse(v.string) catch return error.InvalidObservationFile;
        var inputs: ?std.json.ObjectMap = null;
        if (item.object.get("in")) |in| {
            if (in != .object) return error.InvalidObservationFile;
            inputs = in.object;
        }
        out[i] = .{ .name = n.string, .value = value, .inputs = inputs };
    }
    return out;
}

test "observation files parse and reject the wrong schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good =
        \\{"schema":"testkit-observations/1","producer":{"tool":"t"},
        \\ "observations":[{"n":"a","in":{"x":"u:1"},"v":"u:2"},{"n":"b","v":"h:0000000000000000000000000000000000000000000000000000000000000000"}]}
    ;
    const parsed = try parseFile(arena, good);
    try std.testing.expectEqual(@as(usize, 2), parsed.observations.len);
    try std.testing.expectEqualStrings("a", parsed.observations[0].name);
    try std.testing.expectEqual(@as(u64, 2), parsed.observations[0].value.asUnsigned().?);
    try std.testing.expectEqualStrings("u:1", parsed.observations[0].inputs.?.get("x").?.string);
    try std.testing.expect(parsed.observations[1].inputs == null);
    try std.testing.expect(parsed.producer != null);
    try std.testing.expectError(error.InvalidObservationFile, parseFile(arena, "{\"schema\":\"testkit-observations/1\",\"observations\":[{\"n\":\"a\",\"in\":5,\"v\":\"u:1\"}]}"));
    try std.testing.expectError(error.InvalidObservationFile, parseFile(arena, "{\"schema\":\"testkit-observations/2\",\"observations\":[]}"));
    try std.testing.expectError(error.InvalidObservationFile, parseFile(arena, "{\"schema\":\"testkit-observations/1\",\"observations\":[{\"n\":\"a\",\"v\":\"u:x\"}]}"));
    try std.testing.expectError(error.InvalidObservationFile, parseFile(arena, "not json"));
}

test "sink copies names and formats values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sink = Sink.init(arena_state.allocator());
    var name_buf = "temp".*;
    try sink.unsigned(&name_buf, 7);
    name_buf[0] = 'X';
    try sink.hash("h", @splat(0xab));
    try std.testing.expectEqualStrings("temp", sink.slice()[0].name);
    try std.testing.expectEqualStrings("7", sink.slice()[0].value.body);
    try std.testing.expectEqual(@as(usize, 64), sink.slice()[1].value.body.len);
}
