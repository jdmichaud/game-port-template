//! The `agent.scenario` driver: runs `config.script`, a list of agent host commands, through an
//! in-process `Host`, and observes each response in order. Two runs of the same script on any
//! machine must give the same observations.
//!
//! Observation names are `<index>.<cmd>.<field>`. An error response gives `<index>.<cmd>.error`
//! with the message. The `bounds.max_updates` and `bounds.max_virtual_ns` of the case limit the
//! full script.
const std = @import("std");
const testkit = @import("testkit");
const agent = @import("agent");
const DriverContext = testkit.DriverContext;
const DriverError = testkit.exec.DriverError;
const Sink = testkit.Sink;

pub fn run(ctx: *DriverContext) DriverError!void {
    const obj = ctx.case.configObject() orelse return ctx.fail(error.InvalidConfig, "config is missing");
    const script = obj.get("script") orelse return ctx.fail(error.InvalidConfig, "config.script is missing");
    if (script != .array) return ctx.fail(error.InvalidConfig, "config.script is not an array");

    var host = agent.Host.init(ctx.gpa, ctx.io);
    defer host.deinit();
    const bounds = ctx.case.bounds;
    var total_updates: u64 = 0;

    for (script.array.items, 0..) |command, index| {
        var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const name = agent.Host.commandName(command) orelse "?";
        const response = try host.execute(arena, command);
        try observe(ctx.sink, arena, index, name, response);
        if (response == .ok) switch (response.ok) {
            .step, .run_until => |r| {
                total_updates += r.ran;
                if (bounds.max_updates != 0 and total_updates > bounds.max_updates) return ctx.exceeded("max_updates");
                if (bounds.max_virtual_ns != 0 and r.clock_ns > bounds.max_virtual_ns) return ctx.exceeded("max_virtual_ns");
            },
            .quit => break,
            else => {},
        };
    }
}

fn observe(sink: *Sink, arena: std.mem.Allocator, index: usize, name: []const u8, response: agent.host.Response) error{OutOfMemory}!void {
    const prefix = try std.fmt.allocPrint(arena, "{d}.{s}", .{ index, name });
    switch (response) {
        .err => |message| try sink.text(try std.fmt.allocPrint(arena, "{s}.error", .{prefix}), message),
        .ok => |outcome| switch (outcome) {
            .reset => |r| try sink.unsigned(try field(arena, prefix, "instance"), r.instance),
            .inject => |r| {
                try sink.unsigned(try field(arena, prefix, "accepted"), r.accepted);
                try sink.unsigned(try field(arena, prefix, "clock_ns"), r.clock_ns);
            },
            .advance => |r| try sink.unsigned(try field(arena, prefix, "clock_ns"), r.clock_ns),
            .step, .run_until => |r| {
                try sink.unsigned(try field(arena, prefix, "ran"), r.ran);
                try sink.text(try field(arena, prefix, "result"), r.result);
                try sink.text(try field(arena, prefix, "stopped_by"), r.stopped_by);
                try sink.unsigned(try field(arena, prefix, "clock_ns"), r.clock_ns);
                try observeSnapshot(sink, arena, prefix, r.game);
            },
            .inspect => |r| {
                try sink.unsigned(try field(arena, prefix, "instance"), r.instance);
                if (r.game) |g| try observeSnapshot(sink, arena, prefix, g);
                try sink.unsigned(try field(arena, prefix, "backend.clock_ns"), r.backend.clock_ns);
                try sink.unsigned(try field(arena, prefix, "backend.frames_presented"), r.backend.frames_presented);
                try sink.text(try field(arena, prefix, "backend.last_frame_hash"), r.backend.last_frame_hash);
                try sink.unsigned(try field(arena, prefix, "backend.events_pending"), r.backend.events_pending);
                try sink.unsigned(try field(arena, prefix, "backend.audio.queued_frames"), r.backend.audio.queued_frames);
                try sink.unsigned(try field(arena, prefix, "backend.audio.played_frames"), r.backend.audio.played_frames);
            },
            .capture => |r| {
                try sink.text(try field(arena, prefix, "what"), r.what);
                try sink.unsigned(try field(arena, prefix, "width"), r.width);
                try sink.unsigned(try field(arena, prefix, "height"), r.height);
                try sink.unsigned(try field(arena, prefix, "bytes"), r.bytes);
                try sink.observe(try field(arena, prefix, "sha256"), .{ .kind = .hash, .body = r.sha256 });
            },
            .save_recording => |r| try sink.unsigned(try field(arena, prefix, "commands"), r.commands),
            .assets_list => |r| {
                try sink.unsigned(try field(arena, prefix, "count"), r.count);
                for (r.names, 0..) |n, i| try sink.text(try std.fmt.allocPrint(arena, "{s}.names[{d}]", .{ prefix, i }), n);
            },
            .save_list => |r| {
                try sink.unsigned(try field(arena, prefix, "count"), r.count);
                for (r.names, 0..) |n, i| try sink.text(try std.fmt.allocPrint(arena, "{s}.names[{d}]", .{ prefix, i }), n);
            },
            .quit => |r| try sink.unsigned(try field(arena, prefix, "instance"), r.instance),
        },
    }
}

/// The game's part of a response. A port observes its own snapshot fields here.
fn observeSnapshot(sink: *Sink, arena: std.mem.Allocator, prefix: []const u8, g: agent.host.SnapshotOut) error{OutOfMemory}!void {
    try sink.text(try field(arena, prefix, "game.phase"), g.phase);
    try sink.unsigned(try field(arena, prefix, "game.update_count"), g.update_count);
    try sink.unsigned(try field(arena, prefix, "game.events_consumed"), g.events_consumed);
    try sink.unsigned(try field(arena, prefix, "game.frames_presented"), g.frames_presented);
    try sink.text(try field(arena, prefix, "game.last_frame_hash"), g.last_frame_hash);
    try sink.text(try field(arena, prefix, "game.state_hash"), g.state_hash);
    try sink.text(try field(arena, prefix, "game.title"), g.title);
    try sink.unsigned(try field(arena, prefix, "game.bounces"), g.bounces);
    try sink.unsigned(try field(arena, prefix, "game.saves_written"), g.saves_written);
    try sink.unsigned(try field(arena, prefix, "game.loads_done"), g.loads_done);
}

fn field(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, name });
}
