//! The drivers of the runner. Each converts the configuration of a case into actual observations.
const std = @import("std");
const testkit = @import("testkit");
const DriverContext = testkit.DriverContext;
const DriverError = testkit.exec.DriverError;
const scenario = @import("scenario.zig");
const zigfn = @import("zigfn.zig");

pub const drivers = [_]testkit.Driver{
    .{ .name = "synthetic.echo", .run = echo },
    .{ .name = "synthetic.stall", .run = stall },
    .{ .name = "synthetic.crash", .run = crash },
    .{ .name = "recorded", .run = recorded },
    .{ .name = "agent.scenario", .run = scenario.run },
    .{ .name = "zig.function", .run = zigfn.run },
    // A port adds its own drivers here: the vectors of the original's routines replayed through
    // their reimplementations, trace replays of its simulation, and so on.
};

/// Observes exactly `config.values`, in order.
fn echo(ctx: *DriverContext) DriverError!void {
    const obj = ctx.case.configObject() orelse return ctx.fail(error.InvalidConfig, "config is missing");
    const values = obj.get("values") orelse return ctx.fail(error.InvalidConfig, "config.values is missing");
    if (values != .array) return ctx.fail(error.InvalidConfig, "config.values is not an array");
    const list = testkit.observation.parseArray(ctx.arena, values.array) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail(error.InvalidConfig, "config.values holds an invalid observation"),
    };
    for (list) |o| try ctx.sink.observe(o.name, o.value);
}

/// Does not return: the wall-clock watchdog of the runner must end it.
fn stall(ctx: *DriverContext) DriverError!void {
    while (true) {
        ctx.io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
}

/// Panics: the runner must classify the signal as a crash.
fn crash(ctx: *DriverContext) DriverError!void {
    _ = ctx;
    @panic("synthetic.crash: deliberate panic");
}

/// Observes the contents of another observation file, `config.candidate`.
fn recorded(ctx: *DriverContext) DriverError!void {
    const path = ctx.case.configString("candidate") orelse return ctx.fail(error.InvalidConfig, "config.candidate is missing");
    const list = try ctx.readObservations(path);
    for (list) |o| try ctx.sink.observe(o.name, o.value);
}
