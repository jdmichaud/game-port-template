//! The test kit: the fixture contract as code. It contains typed lossless
//! values, observation files, case files with provenance and trust status, exact ordered
//! comparison with first-difference reporting, verdicts, report lines, digests, and in-process
//! case execution against a driver registry. It depends only on std.
pub const value = @import("value.zig");
pub const observation = @import("observation.zig");
pub const case = @import("case.zig");
pub const verdict = @import("verdict.zig");
pub const report = @import("report.zig");
pub const digest = @import("digest.zig");
pub const exec = @import("exec.zig");

pub const Value = value.Value;
pub const Observation = observation.Observation;
pub const Sink = observation.Sink;
pub const Case = case.Case;
pub const Verdict = verdict.Verdict;
pub const Driver = exec.Driver;
pub const DriverContext = exec.DriverContext;

test {
    @import("std").testing.refAllDecls(@This());
}
