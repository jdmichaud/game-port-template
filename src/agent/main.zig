//! gameport-agent: the headless host. It runs the game on the agent backend for a number of frames,
//! at a fixed 60 Hz clock, presses keys at the frames it is told, and prints one JSON line with the
//! counts and the hashes of the state and of the last frame. Two runs with the same arguments print
//! the same line on every machine; a port builds its scripted tests and its debugging on this.
//!
//! With an asset path, the game reads that directory; with `--saves`, it saves there. Without them,
//! it runs on in-memory providers, so the run touches no file.
const std = @import("std");
const gameport = @import("gameport");
const agent = @import("agent");
const native = @import("native");

const usage =
    \\usage: gameport-agent [--frames N] [--key FRAME:NAME]... [ASSET_PATH] [--saves DIR]
    \\  --frames N       run N frames (default 120)
    \\  --key FRAME:NAME press and release the key NAME (a platform.Key, as `f2` or `left`) at
    \\                   frame FRAME; the option repeats
    \\  ASSET_PATH       the directory of the original's files
    \\  --saves DIR      where saves are kept
    \\
;

const frame_ns: u64 = std.time.ns_per_s / 60;
const Press = struct { frame: u64, key: gameport.platform.Key };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var frames: u64 = 120;
    var presses: std.ArrayList(Press) = .empty;
    defer presses.deinit(gpa);
    var options: native.cli.Options = .{};
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    while (args.next()) |arg| {
        if (options.take(arg, &args) catch return fail(io)) continue;
        if (std.mem.eql(u8, arg, "--frames")) {
            frames = std.fmt.parseInt(u64, args.next() orelse return fail(io), 10) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--key")) {
            try presses.append(gpa, parsePress(args.next() orelse return fail(io)) orelse return fail(io));
        } else {
            return fail(io);
        }
    }

    // Real providers when the options name them, else in-memory ones. They outlive the game.
    var providers: native.cli.Providers = .empty;
    defer providers.deinit();
    var memory_assets = gameport.memory.MemoryAssetSource.init(gpa);
    defer memory_assets.deinit();
    var memory_storage = gameport.memory.MemoryStorage.init(gpa);
    defer memory_storage.deinit();
    var assets: ?gameport.platform.AssetSource = memory_assets.assetSource();
    var storage = memory_storage.storage();
    if (options.assets != null or options.saves != null) {
        providers.open(gpa, io, init.environ_map, options) catch |err| {
            std.log.err("cannot open the providers: {s}", .{@errorName(err)});
            std.process.exit(2);
        };
        assets = providers.assetSource() orelse assets;
        storage = providers.storage();
    }

    var backend = agent.AgentBackend.init(gpa, .{});
    defer backend.deinit();
    var game = try gameport.Game.init(gpa, assets, storage);
    defer game.deinit();
    var p = backend.asPlatform();
    var frame: u64 = 0;
    while (frame < frames) : (frame += 1) {
        for (presses.items) |press| if (press.frame == frame) {
            try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_down = .{ .key = press.key } } });
            try backend.inject(.{ .time_ns = backend.clock_ns, .payload = .{ .key_up = .{ .key = press.key } } });
        };
        if (try game.update(&p) == .finished) break;
        backend.advance(frame_ns);
    }

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.print("{{\"updates\":{d},\"frames_presented\":{d},\"events_consumed\":{d},\"saves\":{d},\"loads\":{d},\"state_hash\":\"{x:0>16}\",\"frame_hash\":\"{x:0>16}\"}}\n", .{
        game.update_count, game.frames_presented, game.events_consumed, game.saves_written, game.loads_done, game.state.hash(), game.last_frame_hash,
    });
    try w.interface.flush();
}

/// `FRAME:NAME`, as `30:f2`.
fn parsePress(text: []const u8) ?Press {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const frame = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;
    const key = std.meta.stringToEnum(gameport.platform.Key, text[colon + 1 ..]) orelse return null;
    return .{ .frame = frame, .key = key };
}

fn fail(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(usage);
    try w.interface.flush();
    std.process.exit(2);
}

test "every option the agent host parses is in its usage" {
    try native.cli.expectUsageNames(@embedFile("main.zig"), usage);
}
