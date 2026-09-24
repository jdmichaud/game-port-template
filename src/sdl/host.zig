//! The interactive host: the outer loop of the SDL targets, Linux and Windows (DESIGN.md).
//!
//! It owns the backend, the asset and storage providers and the game. It decides when the next
//! update runs; the game decides what happens in an update. The display paces the presentation when
//! the renderer presents in step with it; else a sleep at `fallback_hz` paces it.
//!
//! Information goes to standard error. Standard output carries only the `--event-log` lines.
const std = @import("std");
const gameport = @import("gameport");
const native = @import("native");
const c = @import("sdl.zig");
const version = @import("root.zig");
const SdlBackend = @import("backend.zig").SdlBackend;

/// The rate of the fallback pacer, when the display does not pace the presentation.
pub const fallback_hz: u32 = 60;

/// Whether the standard executable refuses to start without an asset path. The placeholder game
/// runs without files; a port whose game needs the original's files sets this to true.
pub const assets_required = false;

pub const Content = union(enum) {
    external,
    embedded: []const gameport.memory.AssetEntry,

    pub fn programName(self: Content) []const u8 {
        return if (self == .embedded) "gameport-sdl-standalone" else "gameport-sdl";
    }

    pub fn usage(self: Content) []const u8 {
        return if (self == .embedded) standalone_usage else external_usage;
    }
};

const external_usage =
    \\usage: gameport-sdl [OPTIONS] [ASSET_PATH]
    \\  ASSET_PATH           a game directory or a CD image (an ISO is recognised by its
    \\                       signature)
    \\
++ common_usage;
const standalone_usage =
    \\usage: gameport-sdl-standalone [OPTIONS]
    \\  The game's files are built into the program.
    \\
++ common_usage;
const common_usage =
    \\  --help, -h           show this help
    \\  --scale N            window scale, 1 to 64 (default 3)
    \\  --no-vsync           do not ask for display-paced presentation
    \\  --software           force SDL's software renderer
    \\  --event-log SECONDS  write every polled event to standard output as one JSON line
    \\                       and quit after that many seconds
    \\  --run-for SECONDS    quit after that many seconds, without the event log
    \\  --fps N              the fallback pacer's rate, 1 to 1000 (default 60)
    \\  --saves DIR          where saves are kept (default: the per-user application data
    \\                       directory)
    \\
;

pub const Options = struct {
    help: bool = false,
    scale: ?u32 = null,
    /// `--no-vsync` sets it to false.
    vsync: ?bool = null,
    software: bool = false,
    /// When set, the run stops after this many nanoseconds, and the host logs every event.
    event_log_ns: ?u64 = null,
    /// `--run-for`: stop after this many nanoseconds, without an event log.
    run_for_ns: ?u64 = null,
    /// `--fps`: the rate of the fallback pacer. It changes only the pacing, never the game.
    fps: ?u32 = null,
    /// The sources of the game's assets and saves.
    providers: native.cli.Options = .{},

    /// The time at which the run ends by itself: the nearer of the given deadlines, or null.
    pub fn deadlineNs(self: Options) ?u64 {
        if (self.event_log_ns) |ns| {
            if (self.run_for_ns) |other| return @min(ns, other);
            return ns;
        }
        return self.run_for_ns;
    }
};

pub fn runWithContent(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, options: Options, content: Content) !u8 {
    var err_buf: [1024]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_writer.interface;
    const name = content.programName();

    var ver_buf: [32]u8 = undefined;
    const check = version.checkVersion(&ver_buf);
    try err.print("{s}: SDL2 {s} linked (pinned {s})\n", .{ name, check.linked, check.pinned });
    try err.flush();

    // The providers: the save directory, and the game directory or CD image of the positional
    // argument. They outlive the game and the backend, which only borrow their interfaces.
    var providers: native.cli.Providers = .empty;
    defer providers.deinit();
    var provider_options = options.providers;
    if (content == .embedded) provider_options.assets = null;
    providers.open(gpa, io, environ, provider_options) catch |e| {
        std.log.err("cannot open the providers: {s}", .{@errorName(e)});
        return 1;
    };
    // Built-in files for the standalone build, or an empty table when no asset path was given.
    var memory_assets = gameport.memory.MemoryAssetSource.init(gpa);
    defer memory_assets.deinit();
    if (content == .embedded) for (content.embedded) |entry| try memory_assets.add(entry.name, entry.bytes);
    const assets = providers.assetSource() orelse memory_assets.assetSource();
    try err.print("{s}: assets: {s}, saves: {s}\n", .{ name, if (content == .embedded) "embedded" else @tagName(providers.kind), providers.saves_path });
    try err.flush();

    // The backend is made before the game and released after it.
    defer c.SDL_Quit();
    var backend = try SdlBackend.init(gpa, .{
        .title = "gameport",
        .initial_window_scale = options.scale orelse 3,
        .prefer_vsync = options.vsync orelse true,
    });
    defer backend.deinit();
    backend.force_software_renderer = options.software;

    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};
    if (options.event_log_ns != null) backend.event_log = out;

    // The executor of the game's I/O workflows: one job at a time, beside the frame loop, so no
    // update waits for a file. It stops before the backend and the providers: its `deinit` cancels
    // and joins the job that runs.
    var executor = native.executor.Executor.init(gpa, io, assets, providers.storage(), .{});
    defer executor.deinit();
    backend.jobs = executor.jobs();

    var game = try gameport.Game.init(gpa);
    defer game.deinit();

    var p = backend.asPlatform();
    var pacer: Pacer = .{ .period_ns = std.time.ns_per_s / (options.fps orelse fallback_hz) };
    var deadline_ns: ?u64 = null;
    const deadline_limit = options.deadlineNs();
    var announced_first_frame = false;
    const start_ns = p.nowNs();
    while (true) {
        const frames_before = game.frames_presented;
        // Collect the job that finished, start the next one, and publish, before the update.
        executor.update();
        const result = game.update(&p) catch |e| {
            std.log.err("game update failed: {s}", .{@errorName(e)});
            try out.flush();
            return 1;
        };
        // A window that never painted looks the same as a window whose frames do not reach the
        // display. The renderer's name and the first frame tell them apart.
        if (!announced_first_frame and game.frames_presented > 0) {
            announced_first_frame = true;
            const size = backend.window_size;
            try err.print("{s}: first frame after {d}ms in a {d}x{d} window, renderer {s}{s}\n", .{
                name,
                (p.nowNs() - start_ns) / std.time.ns_per_ms,
                size.width,
                size.height,
                if (backend.rendererName().len != 0) backend.rendererName() else "unknown",
                if (backend.vsync) ", display-paced" else "",
            });
            try err.flush();
        }
        if (backend.event_log != null) try out.flush();
        if (result == .finished) break;
        const now = p.nowNs();
        if (deadline_limit) |limit| {
            // The deadline starts when the platform is up, so a slow start does not use log time.
            if (deadline_ns == null and backend.started) deadline_ns = now + limit;
            if (deadline_ns) |d| if (now >= d) break;
        }
        // The display paces an iteration only if the iteration presented a frame.
        pacer.wait(now, backend.vsync and game.frames_presented != frames_before);
    }

    const audio = p.audioStatus();
    try err.print("{s}: {d} updates, {d} frames presented, {d} events consumed, paced by {s}\n", .{
        name,
        game.update_count,
        game.frames_presented,
        game.events_consumed,
        if (backend.vsync) "the display" else "the fallback clock",
    });
    try err.print("{s}: audio {s}, {d} frames played, {d} still queued\n", .{ name, if (audio.running) "open" else "closed", audio.played_frames, audio.queued_frames });
    try err.flush();
    try out.flush();
    return 0;
}

/// Keeps the fallback rate. A long update does not cause a burst of short frames after it.
pub const Pacer = struct {
    period_ns: u64 = std.time.ns_per_s / fallback_hz,
    next_ns: u64 = 0,

    /// `vsync` tells that the display paced this iteration, which is true only if the iteration
    /// presented a frame. Otherwise the clock paces it, so a loop that draws nothing does not spin.
    pub fn wait(self: *Pacer, now_ns: u64, vsync: bool) void {
        if (vsync) {
            self.next_ns = 0;
            return;
        }
        // Keep the ideal grid, so the next sleep makes up for a sleep that overran. Only an update
        // more than one full period late resynchronises, so no burst of instant frames follows.
        if (self.next_ns == 0 or now_ns > self.next_ns + self.period_ns) self.next_ns = now_ns;
        self.next_ns += self.period_ns;
        if (self.next_ns <= now_ns) return;
        const ms = (self.next_ns - now_ns) / std.time.ns_per_ms;
        if (ms > 0) c.SDL_Delay(@intCast(ms));
    }
};

pub const ArgError = error{ BadArguments, MissingAssets };

/// Parses the command line from an iterator shaped like `std.process.Args.iterate()`, whose first
/// item is the program name.
pub fn parseArgsWithContent(iter: anytype, content: Content) ArgError!Options {
    var args = iter;
    var options: Options = .{};
    _ = args.skip();
    while (args.next()) |arg| {
        if (options.providers.take(arg, &args) catch return error.BadArguments) continue;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const value = args.next() orelse return error.BadArguments;
            const scale = std.fmt.parseInt(u32, value, 10) catch return error.BadArguments;
            if (scale == 0 or scale > SdlBackend.max_window_scale) return error.BadArguments;
            options.scale = scale;
        } else if (std.mem.eql(u8, arg, "--no-vsync")) {
            options.vsync = false;
        } else if (std.mem.eql(u8, arg, "--software")) {
            options.software = true;
        } else if (std.mem.eql(u8, arg, "--event-log")) {
            options.event_log_ns = try seconds(args.next());
        } else if (std.mem.eql(u8, arg, "--run-for")) {
            options.run_for_ns = try seconds(args.next());
        } else if (std.mem.eql(u8, arg, "--fps")) {
            const value = args.next() orelse return error.BadArguments;
            const rate = std.fmt.parseInt(u32, value, 10) catch return error.BadArguments;
            if (rate == 0 or rate > 1000) return error.BadArguments;
            options.fps = rate;
        } else {
            return error.BadArguments;
        }
    }
    switch (content) {
        .external => if (assets_required and !options.help and options.providers.assets == null) return error.MissingAssets,
        .embedded => if (options.providers.assets != null) return error.BadArguments,
    }
    return options;
}

fn seconds(value: ?[]const u8) ArgError!u64 {
    const text = value orelse return error.BadArguments;
    const s = std.fmt.parseFloat(f64, text) catch return error.BadArguments;
    if (!(s > 0) or s > 86_400) return error.BadArguments;
    return @intFromFloat(s * std.time.ns_per_s);
}

/// A replacement for the process argument iterator, to test the parser without a process. Its
/// methods are public because the shared option parser (`native.cli`) reads the iterator
/// generically, and Zig sees only public declarations across modules.
const SliceArgs = struct {
    items: []const []const u8,
    index: usize = 0,

    pub fn skip(self: *SliceArgs) bool {
        if (self.index >= self.items.len) return false;
        self.index += 1;
        return true;
    }

    pub fn next(self: *SliceArgs) ?[]const u8 {
        if (self.index >= self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};

test "the host options are parsed, bounded and defaulted" {
    const defaults = try parseArgsWithContent(SliceArgs{ .items = &.{"gameport-sdl"} }, .external);
    try std.testing.expectEqual(@as(?u32, null), defaults.scale);
    try std.testing.expectEqual(@as(?bool, null), defaults.vsync);
    try std.testing.expectEqual(@as(?u64, null), defaults.deadlineNs());

    const all = try parseArgsWithContent(SliceArgs{ .items = &.{ "gameport-sdl", "--scale", "2", "--no-vsync", "--software", "--event-log", "1.5", "--run-for", "1", "game.iso", "--saves", "saves" } }, .external);
    try std.testing.expectEqual(@as(?u32, 2), all.scale);
    try std.testing.expectEqual(@as(?bool, false), all.vsync);
    try std.testing.expect(all.software);
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), all.deadlineNs());
    try std.testing.expectEqualStrings("game.iso", all.providers.assets.?);
    try std.testing.expectEqualStrings("saves", all.providers.saves.?);

    for ([_][]const []const u8{
        &.{ "gameport-sdl", "--scale", "0" },
        &.{ "gameport-sdl", "--scale", "99999" },
        &.{ "gameport-sdl", "--event-log", "-1" },
        &.{ "gameport-sdl", "--fps", "0" },
        &.{ "gameport-sdl", "--frobnicate" },
        &.{ "gameport-sdl", "first.iso", "second.iso" },
    }) |args| try std.testing.expectError(error.BadArguments, parseArgsWithContent(SliceArgs{ .items = args }, .external));
}

test "the standalone host refuses an asset path: its files are built in" {
    const content = Content{ .embedded = &.{} };
    const options = try parseArgsWithContent(SliceArgs{ .items = &.{ "gameport-sdl-standalone", "--saves", "saved-games" } }, content);
    try std.testing.expect(options.providers.assets == null);
    try std.testing.expectError(error.BadArguments, parseArgsWithContent(SliceArgs{ .items = &.{ "gameport-sdl-standalone", "game.iso" } }, content));
}

test "the fallback pacer holds its period without accumulating debt" {
    var pacer: Pacer = .{};
    pacer.wait(0, true);
    try std.testing.expectEqual(@as(u64, 0), pacer.next_ns);
    pacer.wait(0, false);
    try std.testing.expectEqual(pacer.period_ns, pacer.next_ns);
    pacer.wait(pacer.period_ns, false);
    try std.testing.expectEqual(@as(u64, 2 * (std.time.ns_per_s / fallback_hz)), pacer.next_ns);
    pacer.wait(10 * std.time.ns_per_s, false);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s) + pacer.period_ns, pacer.next_ns);
}
