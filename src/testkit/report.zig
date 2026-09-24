//! Report lines (`testkit-report/1`) and the run summary.
const std = @import("std");
const builtin = @import("builtin");
const Verdict = @import("verdict.zig").Verdict;
const Difference = @import("verdict.zig").Difference;
const case = @import("case.zig");

pub const schema = "testkit-report/1";

/// The relation between the raw verdict, the expected verdict of the case and its trust status.
pub const Outcome = enum {
    /// The verdict is the expected one.
    ok,
    /// A verified expectation gave a different verdict. The run fails.
    failed,
    /// A provisional or disputed expectation gave a different verdict. It is only reported.
    diagnostic,
};

pub fn outcomeOf(verdict: Verdict, expected: Verdict, status: case.TrustStatus) Outcome {
    if (verdict == expected) return .ok;
    return if (status == .verified) .failed else .diagnostic;
}

pub const Candidate = struct {
    zig: []const u8 = builtin.zig_version_string,
    optimize: []const u8 = @tagName(builtin.mode),
    target: []const u8 = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag),
};

pub const Entry = struct {
    case_id: []const u8,
    case_path: []const u8,
    driver: []const u8,
    class: case.ReferenceClass,
    status: case.TrustStatus,
    verdict: Verdict,
    expected_verdict: Verdict,
    outcome: Outcome,
    /// A limit name, an error text, a signal or another short explanation.
    detail: ?[]const u8,
    difference: ?Difference,
    compared: usize,
    elapsed_ms: u64,
    replay: []const u8,
    inputs: []const case.InputFile,
    candidate: Candidate = .{},

    /// Writes one JSON line.
    pub fn write(e: *const Entry, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("schema");
        try js.write(schema);
        try js.objectField("case");
        try js.write(e.case_id);
        try js.objectField("path");
        try js.write(e.case_path);
        try js.objectField("driver");
        try js.write(e.driver);
        try js.objectField("class");
        try js.write(@tagName(e.class));
        try js.objectField("status");
        try js.write(@tagName(e.status));
        try js.objectField("verdict");
        try js.write(@tagName(e.verdict));
        try js.objectField("expected_verdict");
        try js.write(@tagName(e.expected_verdict));
        try js.objectField("outcome");
        try js.write(@tagName(e.outcome));
        try js.objectField("detail");
        try js.write(e.detail);
        try js.objectField("difference");
        if (e.difference) |d| {
            try js.beginObject();
            try js.objectField("index");
            try js.write(d.index);
            try js.objectField("name");
            try js.write(d.name);
            try js.objectField("actual_name");
            try js.write(d.actual_name);
            try js.objectField("expected");
            try js.write(d.expected);
            try js.objectField("actual");
            try js.write(d.actual);
            try js.endObject();
        } else {
            try js.write(null);
        }
        try js.objectField("compared");
        try js.write(e.compared);
        try js.objectField("elapsed_ms");
        try js.write(e.elapsed_ms);
        try js.objectField("replay");
        try js.write(e.replay);
        try js.objectField("inputs");
        try js.beginArray();
        for (e.inputs) |input| {
            try js.beginObject();
            try js.objectField("path");
            try js.write(input.path);
            try js.objectField("sha256");
            try js.write(input.sha256);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("candidate");
        try js.beginObject();
        try js.objectField("zig");
        try js.write(e.candidate.zig);
        try js.objectField("optimize");
        try js.write(e.candidate.optimize);
        try js.objectField("target");
        try js.write(e.candidate.target);
        try js.endObject();
        try js.endObject();
        try w.writeByte('\n');
    }
};

pub const Summary = struct {
    total: usize = 0,
    ok: usize = 0,
    failed: usize = 0,
    diagnostic: usize = 0,
    by_verdict: [std.enums.values(Verdict).len]usize = @splat(0),

    pub fn add(s: *Summary, verdict: Verdict, outcome: Outcome) void {
        s.total += 1;
        switch (outcome) {
            .ok => s.ok += 1,
            .failed => s.failed += 1,
            .diagnostic => s.diagnostic += 1,
        }
        s.by_verdict[@backingInt(verdict)] += 1;
    }

    pub fn write(s: *const Summary, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} cases: {d} ok, {d} failed, {d} diagnostic (verdicts:", .{ s.total, s.ok, s.failed, s.diagnostic });
        for (std.enums.values(Verdict), 0..) |v, i| {
            if (s.by_verdict[i] != 0) try w.print(" {s} {d}", .{ @tagName(v), s.by_verdict[i] });
        }
        try w.writeAll(")\n");
    }
};

test "report lines are single-line JSON" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const entry = Entry{
        .case_id = "a",
        .case_path = "tests/public/a.case.json",
        .driver = "synthetic.echo",
        .class = .@"specified-contract",
        .status = .verified,
        .verdict = .mismatch,
        .expected_verdict = .pass,
        .outcome = .failed,
        .detail = null,
        .difference = .{ .index = 1, .name = "b", .expected = "u:2", .actual = "u:3" },
        .compared = 1,
        .elapsed_ms = 4,
        .replay = "gameport-test case tests/public/a.case.json",
        .inputs = &.{},
    };
    try entry.write(&w);
    const line = w.buffered();
    try std.testing.expect(std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"verdict\":\"mismatch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"outcome\":\"failed\"") != null);
    try std.testing.expectEqual(Outcome.diagnostic, outcomeOf(.mismatch, .pass, .provisional));
    try std.testing.expectEqual(Outcome.ok, outcomeOf(.timeout, .timeout, .verified));
}
