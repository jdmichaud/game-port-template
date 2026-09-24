//! Verdicts and the exact, ordered comparison that produces them.
const std = @import("std");
const Observation = @import("observation.zig").Observation;

pub const Verdict = enum {
    pass,
    mismatch,
    missing_observation,
    extra_observation,
    timeout,
    crash,
    missing_input,
    reference_error,
    unsupported,
    infrastructure,
};

/// The first index where the observations differ. Values are printed in their typed form.
pub const Difference = struct {
    index: usize,
    /// The expected name at that index, or the actual name for an extra observation.
    name: []const u8,
    expected: ?[]const u8,
    actual: ?[]const u8,
    /// The actual name, set when the names differ at the index.
    actual_name: ?[]const u8 = null,
};

pub const Comparison = struct {
    verdict: Verdict,
    /// The number of observations that matched before the verdict.
    compared: usize,
    difference: ?Difference,
};

/// Compares in order and stops at the first difference. It never reorders or renames: a
/// shifted trace is a mismatch at the first shifted index.
pub fn compare(arena: std.mem.Allocator, expected: []const Observation, actual: []const Observation) error{OutOfMemory}!Comparison {
    const n = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = expected[i];
        const a = actual[i];
        const same_name = std.mem.eql(u8, e.name, a.name);
        if (!same_name or !e.value.eql(a.value)) {
            return .{
                .verdict = .mismatch,
                .compared = i,
                .difference = .{
                    .index = i,
                    .name = e.name,
                    .expected = try std.fmt.allocPrint(arena, "{f}", .{e.value}),
                    .actual = try std.fmt.allocPrint(arena, "{f}", .{a.value}),
                    .actual_name = if (same_name) null else a.name,
                },
            };
        }
    }
    if (actual.len < expected.len) {
        return .{
            .verdict = .missing_observation,
            .compared = n,
            .difference = .{
                .index = n,
                .name = expected[n].name,
                .expected = try std.fmt.allocPrint(arena, "{f}", .{expected[n].value}),
                .actual = null,
            },
        };
    }
    if (actual.len > expected.len) {
        return .{
            .verdict = .extra_observation,
            .compared = n,
            .difference = .{
                .index = n,
                .name = actual[n].name,
                .expected = null,
                .actual = try std.fmt.allocPrint(arena, "{f}", .{actual[n].value}),
            },
        };
    }
    return .{ .verdict = .pass, .compared = n, .difference = null };
}

const Value = @import("value.zig").Value;

fn obs(name: []const u8, v: []const u8) Observation {
    return .{ .name = name, .value = Value.parse(v) catch unreachable };
}

test "comparison reports the first difference" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expected = [_]Observation{ obs("a", "u:1"), obs("b", "u:2"), obs("c", "u:3") };

    const same = try compare(arena, &expected, &expected);
    try std.testing.expectEqual(Verdict.pass, same.verdict);
    try std.testing.expectEqual(@as(usize, 3), same.compared);

    const wrong = [_]Observation{ obs("a", "u:1"), obs("b", "u:9"), obs("c", "u:3") };
    const m = try compare(arena, &expected, &wrong);
    try std.testing.expectEqual(Verdict.mismatch, m.verdict);
    try std.testing.expectEqual(@as(usize, 1), m.difference.?.index);
    try std.testing.expectEqualStrings("u:2", m.difference.?.expected.?);
    try std.testing.expectEqualStrings("u:9", m.difference.?.actual.?);

    const renamed = [_]Observation{ obs("a", "u:1"), obs("z", "u:2"), obs("c", "u:3") };
    const r = try compare(arena, &expected, &renamed);
    try std.testing.expectEqual(Verdict.mismatch, r.verdict);
    try std.testing.expectEqualStrings("z", r.difference.?.actual_name.?);

    const short = expected[0..2];
    const s = try compare(arena, &expected, short);
    try std.testing.expectEqual(Verdict.missing_observation, s.verdict);
    try std.testing.expectEqual(@as(usize, 2), s.difference.?.index);
    try std.testing.expectEqualStrings("c", s.difference.?.name);

    const long = [_]Observation{ obs("a", "u:1"), obs("b", "u:2"), obs("c", "u:3"), obs("d", "u:4") };
    const l = try compare(arena, &expected, &long);
    try std.testing.expectEqual(Verdict.extra_observation, l.verdict);
    try std.testing.expectEqualStrings("d", l.difference.?.name);

    const typed = [_]Observation{ obs("a", "i:1"), obs("b", "u:2"), obs("c", "u:3") };
    try std.testing.expectEqual(Verdict.mismatch, (try compare(arena, &expected, &typed)).verdict);
}
