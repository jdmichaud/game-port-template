//! gameport-agent: the headless debugging host. It reads JSON commands, one per line, from standard
//! input or from a script file, executes them on the agent backend and the shared game, and writes
//! one JSON response for each command to standard output. Diagnostics go to standard error.
//! src/agent/host.zig describes the commands.
//!
//! With an asset path, the host reads a real asset source (a game directory or a CD image), not its
//! in-memory table. With an asset path or `--saves`, it writes saves to a directory, not to its
//! in-memory store: the `--saves` directory, or else the per-user application data directory.
const std = @import("std");
const agent = @import("agent");
const native = @import("native");

const usage =
    \\usage: gameport-agent [--script FILE] [--strict] [ASSET_PATH] [--saves DIR]
    \\  --script FILE  read commands from FILE instead of standard input
    \\  --strict       exit with status 1 if any command failed
    \\  ASSET_PATH     a game directory or a CD image (an ISO is recognised by its signature)
    \\  --saves DIR    where saves are kept (default: the per-user application data directory)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var script_path: ?[]const u8 = null;
    var strict = false;
    var options: native.cli.Options = .{};
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    while (args.next()) |arg| {
        if (options.take(arg, &args) catch return fail(io, usage)) continue;
        if (std.mem.eql(u8, arg, "--script")) {
            script_path = args.next() orelse return fail(io, usage);
        } else if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
        } else {
            return fail(io, usage);
        }
    }

    // The providers outlive the host, which only borrows them. The host is released first.
    var providers: native.cli.Providers = .empty;
    defer providers.deinit();
    var bound = false;
    if (options.assets != null or options.saves != null) {
        providers.open(gpa, io, init.environ_map, options) catch |err| {
            std.log.err("cannot open the providers: {s}", .{@errorName(err)});
            std.process.exit(2);
        };
        bound = true;
    }

    var host = agent.Host.init(gpa, io);
    defer host.deinit();
    if (bound) {
        host.assets_override = providers.assetSource();
        host.storage_override = providers.storage();
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    var failures: usize = 0;
    if (script_path) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.log.err("cannot read script {s}: {s}", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        defer gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!try executeCounting(&host, gpa, line, out, &failures)) break;
        }
    } else {
        var in_buf: [1024 * 1024]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
        while (try reader.interface.takeDelimiter('\n')) |line| {
            if (!try executeCounting(&host, gpa, line, out, &failures)) break;
        }
    }
    try out.flush();
    if (strict and failures > 0) {
        std.log.err("{d} command(s) failed", .{failures});
        std.process.exit(1);
    }
}

/// Executes one line, counts error responses, and flushes so the driving process sees each one.
fn executeCounting(host: *agent.Host, gpa: std.mem.Allocator, line: []const u8, out: *std.Io.Writer, failures: *usize) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const before = out.end;
    const keep_going = try host.executeLine(arena_state.allocator(), line, out);
    // An error response starts with `{"ok":false`. The host writes each response in one piece.
    if (out.end > before and std.mem.startsWith(u8, out.buffered()[before - 0 ..], "{\"ok\":false")) failures.* += 1;
    try out.flush();
    return keep_going;
}

fn fail(io: std.Io, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
    std.process.exit(2);
}
