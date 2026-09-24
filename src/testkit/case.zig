//! The `testkit-case/1` file: identity, driver, provenance and trust status, inputs with digests,
//! driver configuration, expected observations, expected verdict and bounds.
const std = @import("std");
const observation = @import("observation.zig");
const Observation = observation.Observation;
const Verdict = @import("verdict.zig").Verdict;

pub const schema = "testkit-case/1";

pub const ReferenceClass = enum { @"original-derived", @"specified-contract", @"regression-baseline" };
pub const TrustStatus = enum { verified, provisional, disputed };
pub const Redistribution = enum { redistributable, restricted };

pub const InputFile = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Bounds = struct {
    max_updates: u64 = 0,
    max_events: u64 = 0,
    max_virtual_ns: u64 = 0,
    wall_clock_ms: u64 = 0,

    pub const default_wall_clock_ms: u64 = 30_000;

    pub fn wallClockMs(b: Bounds) u64 {
        return if (b.wall_clock_ms == 0) default_wall_clock_ms else b.wall_clock_ms;
    }
};

pub const Case = struct {
    /// The path of the case file, for replay commands.
    path: []const u8,
    id: []const u8,
    driver: []const u8,
    class: ReferenceClass,
    status: TrustStatus,
    evidence: []const u8,
    redistribution: Redistribution,
    source: ?std.json.Value,
    inputs: []InputFile,
    config: ?std.json.Value,
    expected: []Observation,
    expected_file: ?[]const u8,
    expected_verdict: Verdict,
    bounds: Bounds,

    pub const ParseError = error{ InvalidCase, OutOfMemory };

    /// Parses a case file. The result is in `arena`. On `InvalidCase`, `diag` names the incorrect
    /// field or describes the error.
    pub fn parse(arena: std.mem.Allocator, path: []const u8, bytes: []const u8, diag: *[]const u8) ParseError!Case {
        diag.* = "";
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                diag.* = "not valid JSON";
                return error.InvalidCase;
            },
        };
        if (root != .object) return invalid(diag, "root is not an object");
        const obj = root.object;

        const schema_value = try requireString(obj, "schema", diag);
        if (!std.mem.eql(u8, schema_value, schema)) return invalid(diag, "schema is not testkit-case/1");

        const id = try requireString(obj, "id", diag);
        if (id.len == 0) return invalid(diag, "id is empty");
        const driver = try requireString(obj, "driver", diag);

        const reference = obj.get("reference") orelse return invalid(diag, "reference is missing");
        if (reference != .object) return invalid(diag, "reference is not an object");
        const class = try requireEnum(ReferenceClass, reference.object, "class", diag);
        const status = try requireEnum(TrustStatus, reference.object, "status", diag);
        const evidence = try requireString(reference.object, "evidence", diag);
        const redistribution = try requireEnum(Redistribution, reference.object, "redistribution", diag);

        var inputs: []InputFile = &.{};
        if (obj.get("inputs")) |inputs_value| {
            if (inputs_value != .object) return invalid(diag, "inputs is not an object");
            if (inputs_value.object.get("files")) |files| {
                if (files != .array) return invalid(diag, "inputs.files is not an array");
                inputs = try arena.alloc(InputFile, files.array.items.len);
                for (files.array.items, 0..) |f, i| {
                    if (f != .object) return invalid(diag, "inputs.files entry is not an object");
                    const p = try requireString(f.object, "path", diag);
                    const h = try requireString(f.object, "sha256", diag);
                    if (h.len != 64) return invalid(diag, "inputs.files sha256 is not 64 hex digits");
                    inputs[i] = .{ .path = p, .sha256 = h };
                }
            }
        }

        var expected: []Observation = &.{};
        if (obj.get("expected")) |e| {
            if (e != .array) return invalid(diag, "expected is not an array");
            expected = observation.parseArray(arena, e.array) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(diag, "expected holds an invalid observation"),
            };
        }

        var expected_file: ?[]const u8 = null;
        if (obj.get("expected_file")) |ef| {
            if (ef != .string) return invalid(diag, "expected_file is not a string");
            expected_file = ef.string;
        }

        var expected_verdict: Verdict = .pass;
        if (obj.get("expected_verdict")) |ev| {
            if (ev != .string) return invalid(diag, "expected_verdict is not a string");
            expected_verdict = std.meta.stringToEnum(Verdict, ev.string) orelse return invalid(diag, "expected_verdict is not a verdict");
        }

        var bounds: Bounds = .{};
        if (obj.get("bounds")) |b| {
            if (b != .object) return invalid(diag, "bounds is not an object");
            bounds.max_updates = try optionalUnsigned(b.object, "max_updates", diag);
            bounds.max_events = try optionalUnsigned(b.object, "max_events", diag);
            bounds.max_virtual_ns = try optionalUnsigned(b.object, "max_virtual_ns", diag);
            bounds.wall_clock_ms = try optionalUnsigned(b.object, "wall_clock_ms", diag);
        }

        return .{
            .path = path,
            .id = id,
            .driver = driver,
            .class = class,
            .status = status,
            .evidence = evidence,
            .redistribution = redistribution,
            .source = reference.object.get("source"),
            .inputs = inputs,
            .config = obj.get("config"),
            .expected = expected,
            .expected_file = expected_file,
            .expected_verdict = expected_verdict,
            .bounds = bounds,
        };
    }

    /// The driver configuration as an object, or null.
    pub fn configObject(c: *const Case) ?std.json.ObjectMap {
        const cfg = c.config orelse return null;
        return if (cfg == .object) cfg.object else null;
    }

    /// A string field of the driver configuration.
    pub fn configString(c: *const Case, key: []const u8) ?[]const u8 {
        const obj = c.configObject() orelse return null;
        const v = obj.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }
};

fn invalid(diag: *[]const u8, message: []const u8) error{InvalidCase} {
    diag.* = message;
    return error.InvalidCase;
}

fn requireString(obj: std.json.ObjectMap, key: []const u8, diag: *[]const u8) error{InvalidCase}![]const u8 {
    const v = obj.get(key) orelse {
        diag.* = key;
        return error.InvalidCase;
    };
    if (v != .string) {
        diag.* = key;
        return error.InvalidCase;
    }
    return v.string;
}

fn requireEnum(comptime E: type, obj: std.json.ObjectMap, key: []const u8, diag: *[]const u8) error{InvalidCase}!E {
    const s = try requireString(obj, key, diag);
    return std.meta.stringToEnum(E, s) orelse {
        diag.* = key;
        return error.InvalidCase;
    };
}

fn optionalUnsigned(obj: std.json.ObjectMap, key: []const u8, diag: *[]const u8) error{InvalidCase}!u64 {
    const v = obj.get(key) orelse return 0;
    if (v != .integer or v.integer < 0) {
        diag.* = key;
        return error.InvalidCase;
    }
    return @intCast(v.integer);
}

test "case files parse with defaults and report the offending field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: []const u8 = "";
    const text =
        \\{"schema":"testkit-case/1","id":"x.y","driver":"synthetic.echo",
        \\ "reference":{"class":"specified-contract","status":"verified","evidence":"by construction","redistribution":"redistributable"},
        \\ "config":{"values":[{"n":"a","v":"u:1"}]},
        \\ "expected":[{"n":"a","v":"u:1"}],
        \\ "bounds":{"wall_clock_ms":500}}
    ;
    const c = try Case.parse(arena, "x.case.json", text, &diag);
    try std.testing.expectEqualStrings("x.y", c.id);
    try std.testing.expectEqual(Verdict.pass, c.expected_verdict);
    try std.testing.expectEqual(@as(u64, 500), c.bounds.wall_clock_ms);
    try std.testing.expectEqual(@as(u64, Bounds.default_wall_clock_ms), (Bounds{}).wallClockMs());
    try std.testing.expectEqual(@as(usize, 1), c.expected.len);
    try std.testing.expect(c.configObject() != null);

    const missing_status =
        \\{"schema":"testkit-case/1","id":"x","driver":"d","reference":{"class":"specified-contract","evidence":"e","redistribution":"restricted"}}
    ;
    try std.testing.expectError(error.InvalidCase, Case.parse(arena, "p", missing_status, &diag));
    try std.testing.expectEqualStrings("status", diag);
    try std.testing.expectError(error.InvalidCase, Case.parse(arena, "p", "[]", &diag));
    try std.testing.expectError(error.InvalidCase, Case.parse(arena, "p", "{\"schema\":\"testkit-case/0\"}", &diag));
}
