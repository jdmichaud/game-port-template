//! The debugging host (DESIGN.md): a command and response protocol over the agent backend and the
//! shared game. A command is a JSON object on one line; a response is a JSON object on one line.
//! The same `execute` serves the stdin loop of gameport-agent and the `agent.scenario` test driver,
//! so a scripted scenario gives the same responses in both.
//!
//! Commands (`cmd`):
//!   reset          {record_audio?: bool, assets?: [{name, text}]}
//!                  a new game and backend; the in-memory source then holds exactly `assets`, so a
//!                  scenario gives the game synthetic files instead of the original's
//!   inject         {events: [{t?: ns, kind, ...}]}          scripted device events
//!   advance        {ns}                                     the controlled clock
//!   step           {updates? = 1, advance_ns? = 16 ms}      a bounded number of game updates
//!   run_until      {condition: {phase|frames|updates|finished},
//!                   max_updates? = 1000, max_virtual_ns?, advance_ns? = 16 ms}
//!   inspect        {}                                       the state, read only
//!   capture        {what? = "frame"|"audio", path?}         the latest output
//!   save_recording {path}                                   all recorded commands so far
//!   assets_list    {prefix?}                                the logical names of the bound source
//!   save_list      {}                                       the keys of the bound store
//!   quit           {}
//! A port adds its own commands here (a match, a simulation, a computer player...), each with a
//! typed result in `Outcome`, and observes them in `src/testrunner/scenario.zig`.
//! Each run_until has explicit limits. The response gives the cause of the stop (`stopped_by`).
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;
const Game = gameport.Game;
const AgentBackend = @import("backend.zig").AgentBackend;

pub const default_advance_ns: u64 = 16 * std.time.ns_per_ms;
pub const default_max_updates: u64 = 1000;

/// What the host shows of the game. The first fields are the ones every game has; the rest are the
/// placeholder game's, and a port replaces them with its own.
pub const SnapshotOut = struct {
    phase: []const u8,
    update_count: u64,
    events_consumed: u64,
    frames_presented: u64,
    last_frame_hash: []const u8,
    state_hash: []const u8,
    title: []const u8,
    bounces: u32,
    saves_written: u32,
    loads_done: u32,
};

pub const StepResult = struct {
    ran: u64,
    result: []const u8,
    stopped_by: []const u8,
    clock_ns: u64,
    game: SnapshotOut,
};

pub const BackendOut = struct {
    started: bool,
    clock_ns: u64,
    frames_presented: u64,
    last_frame_hash: []const u8,
    events_pending: usize,
    relative_mouse: bool,
    audio: platform.AudioStatus,
    calls: AgentBackend.Calls,
};

pub const InspectResult = struct {
    instance: u32,
    game: ?SnapshotOut,
    backend: BackendOut,
};

pub const CaptureResult = struct {
    what: []const u8,
    path: ?[]const u8,
    width: u32 = 0,
    height: u32 = 0,
    channels: u8 = 0,
    sample_rate: u32 = 0,
    frames: u64 = 0,
    bytes: usize,
    sha256: []const u8,
};

pub const Outcome = union(enum) {
    reset: struct { instance: u32 },
    inject: struct { accepted: usize, clock_ns: u64 },
    advance: struct { clock_ns: u64 },
    step: StepResult,
    run_until: StepResult,
    inspect: InspectResult,
    capture: CaptureResult,
    save_recording: struct { path: []const u8, commands: usize },
    assets_list: struct { prefix: []const u8, count: usize, names: []const []const u8 },
    save_list: struct { count: usize, names: []const []const u8 },
    quit: struct { instance: u32 },
};

pub const Response = union(enum) {
    ok: Outcome,
    err: []const u8,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: AgentBackend,
    assets: gameport.memory.MemoryAssetSource,
    storage: gameport.memory.MemoryStorage,
    /// Set by the entry point when the host starts with an asset path: the game then reads that
    /// directory or CD image, not the in-memory table. The host borrows it.
    assets_override: ?platform.AssetSource = null,
    /// Set by the entry point for an asset path or `--saves`. It replaces the in-memory store, and
    /// `reset` does not empty it.
    storage_override: ?platform.Storage = null,
    /// The copies of the files that `reset {assets}` gave: the in-memory source only borrows its
    /// names and bytes.
    owned_assets: std.ArrayList([]u8) = .empty,
    game: ?Game = null,
    /// The game's I/O workflows. They run in this thread, at the first update after their
    /// submission, so a scenario replays with the same results at the same updates.
    jobs: ?gameport.workflow.Inline = null,
    instance: u32 = 0,
    /// Each command with a `cmd` field, failed ones included, one per line, for `save_recording`.
    recording: std.ArrayList(u8) = .empty,
    commands_recorded: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Host {
        return .{
            .gpa = gpa,
            .io = io,
            .backend = AgentBackend.init(gpa, .{}),
            .assets = gameport.memory.MemoryAssetSource.init(gpa),
            .storage = gameport.memory.MemoryStorage.init(gpa),
        };
    }

    pub fn deinit(self: *Host) void {
        if (self.game) |*g| g.deinit();
        if (self.jobs) |*j| j.deinit();
        self.backend.deinit();
        self.assets.deinit();
        self.freeOwnedAssets();
        self.storage.deinit();
        self.recording.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeOwnedAssets(self: *Host) void {
        for (self.owned_assets.items) |bytes| self.gpa.free(bytes);
        self.owned_assets.deinit(self.gpa);
        self.owned_assets = .empty;
    }

    /// Parses one command line, records it, executes it and writes the response line. Returns
    /// false after `quit`.
    pub fn executeLine(self: *Host, arena: std.mem.Allocator, line: []const u8, out: *std.Io.Writer) !bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') return true;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch {
            try writeResponse("?", .{ .err = "not a JSON object" }, out);
            return true;
        };
        const name = commandName(value) orelse "?";
        const response = try self.execute(arena, value);
        try writeResponse(name, response, out);
        return !(response == .ok and response.ok == .quit);
    }

    pub fn commandName(command: std.json.Value) ?[]const u8 {
        if (command != .object) return null;
        const v = command.object.get("cmd") orelse return null;
        return if (v == .string) v.string else null;
    }

    /// Executes one parsed command. Results are allocated in `arena`.
    pub fn execute(self: *Host, arena: std.mem.Allocator, command: std.json.Value) error{OutOfMemory}!Response {
        const name = commandName(command) orelse return .{ .err = "cmd is missing" };
        const obj = command.object;
        try self.record(arena, command);
        if (std.mem.eql(u8, name, "reset")) return self.cmdReset(obj);
        if (std.mem.eql(u8, name, "inject")) return self.cmdInject(obj);
        if (std.mem.eql(u8, name, "advance")) return self.cmdAdvance(obj);
        if (std.mem.eql(u8, name, "step")) return self.cmdStep(arena, obj);
        if (std.mem.eql(u8, name, "run_until")) return self.cmdRunUntil(arena, obj);
        if (std.mem.eql(u8, name, "inspect")) return self.cmdInspect(arena);
        if (std.mem.eql(u8, name, "capture")) return self.cmdCapture(arena, obj);
        if (std.mem.eql(u8, name, "save_recording")) return self.cmdSaveRecording(obj);
        if (std.mem.eql(u8, name, "assets_list")) return self.cmdAssetsList(arena, obj);
        if (std.mem.eql(u8, name, "save_list")) return self.cmdSaveList(arena);
        if (std.mem.eql(u8, name, "quit")) return .{ .ok = .{ .quit = .{ .instance = self.instance } } };
        return .{ .err = "unknown command" };
    }

    fn record(self: *Host, arena: std.mem.Allocator, command: std.json.Value) error{OutOfMemory}!void {
        const text = try std.json.Stringify.valueAlloc(arena, command, .{});
        try self.recording.appendSlice(self.gpa, text);
        try self.recording.append(self.gpa, '\n');
        self.commands_recorded += 1;
    }

    fn cmdReset(self: *Host, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        if (self.game) |*g| g.deinit();
        self.game = null;
        if (self.jobs) |*j| j.deinit();
        self.jobs = null;
        self.backend.reset();
        if (self.storage_override == null) {
            self.storage.deinit();
            self.storage = gameport.memory.MemoryStorage.init(self.gpa);
        }
        if (obj.get("record_audio")) |v| {
            if (v == .bool) self.backend.audio.record = v.bool;
        }
        // The in-memory source holds exactly the files of this reset.
        self.assets.deinit();
        self.assets = gameport.memory.MemoryAssetSource.init(self.gpa);
        self.freeOwnedAssets();
        if (obj.get("assets")) |list| {
            if (self.assets_override != null) return .{ .err = "assets needs the in-memory source: the host was started with an asset path" };
            if (list != .array) return .{ .err = "assets is not an array" };
            for (list.array.items) |item| {
                if (item != .object) return .{ .err = "an asset is not an object" };
                const name = stringField(item.object, "name") orelse return .{ .err = "an asset has no name" };
                const text = stringField(item.object, "text") orelse return .{ .err = "an asset has no text" };
                const owned_name = try self.gpa.dupe(u8, name);
                self.owned_assets.append(self.gpa, owned_name) catch |err| {
                    self.gpa.free(owned_name);
                    return err;
                };
                const owned_text = try self.gpa.dupe(u8, text);
                self.owned_assets.append(self.gpa, owned_text) catch |err| {
                    self.gpa.free(owned_text);
                    return err;
                };
                self.assets.add(owned_name, owned_text) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return .{ .err = "an asset name is invalid" },
                };
            }
        }
        self.game = try Game.init(self.gpa);
        self.jobs = gameport.workflow.Inline.init(self.gpa, self.assetSource(), self.saveStorage());
        self.backend.jobs = self.jobs.?.jobs();
        self.instance += 1;
        return .{ .ok = .{ .reset = .{ .instance = self.instance } } };
    }

    fn cmdInject(self: *Host, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        const events = obj.get("events") orelse return .{ .err = "events is missing" };
        if (events != .array) return .{ .err = "events is not an array" };
        var accepted: usize = 0;
        for (events.array.items) |item| {
            if (item != .object) return .{ .err = "event is not an object" };
            const event = parseEvent(item.object, self.backend.clock_ns) catch |err| return .{ .err = @errorName(err) };
            try self.backend.inject(event);
            accepted += 1;
        }
        return .{ .ok = .{ .inject = .{ .accepted = accepted, .clock_ns = self.backend.clock_ns } } };
    }

    fn cmdAdvance(self: *Host, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        const ns = unsignedField(obj, "ns") orelse return .{ .err = "ns is missing" };
        self.backend.advance(ns);
        return .{ .ok = .{ .advance = .{ .clock_ns = self.backend.clock_ns } } };
    }

    fn cmdStep(self: *Host, arena: std.mem.Allocator, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        const game = &(self.game orelse return .{ .err = "no instance: reset first" });
        const updates = unsignedField(obj, "updates") orelse 1;
        const advance_ns = unsignedField(obj, "advance_ns") orelse default_advance_ns;
        var p = self.backend.asPlatform();
        var ran: u64 = 0;
        var result: gameport.game.UpdateResult = if (game.phase == .finished) .finished else .running;
        var stopped_by: []const u8 = "count";
        while (ran < updates) {
            if (game.phase == .finished) {
                stopped_by = "finished";
                break;
            }
            result = game.update(&p) catch |err| return .{ .err = try std.fmt.allocPrint(arena, "update failed: {s}", .{@errorName(err)}) };
            ran += 1;
            self.backend.advance(advance_ns);
        }
        return .{ .ok = .{ .step = try self.stepResult(arena, game, ran, result, stopped_by) } };
    }

    const Condition = union(enum) {
        phase: gameport.game.Phase,
        frames: u64,
        updates: u64,
        finished,
    };

    fn parseCondition(obj: std.json.ObjectMap) error{InvalidCondition}!Condition {
        const c = obj.get("condition") orelse return error.InvalidCondition;
        if (c != .object) return error.InvalidCondition;
        if (c.object.get("phase")) |v| {
            if (v != .string) return error.InvalidCondition;
            return .{ .phase = std.meta.stringToEnum(gameport.game.Phase, v.string) orelse return error.InvalidCondition };
        }
        if (unsignedField(c.object, "frames")) |n| return .{ .frames = n };
        if (unsignedField(c.object, "updates")) |n| return .{ .updates = n };
        if (c.object.get("finished")) |_| return .finished;
        return error.InvalidCondition;
    }

    fn conditionMet(cond: Condition, game: *const Game) bool {
        return switch (cond) {
            .phase => |ph| game.phase == ph,
            .frames => |n| game.frames_presented >= n,
            .updates => |n| game.update_count >= n,
            .finished => game.phase == .finished,
        };
    }

    fn cmdRunUntil(self: *Host, arena: std.mem.Allocator, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        const game = &(self.game orelse return .{ .err = "no instance: reset first" });
        const cond = parseCondition(obj) catch return .{ .err = "condition must be one of phase, frames, updates, finished" };
        const max_updates = unsignedField(obj, "max_updates") orelse default_max_updates;
        const max_virtual_ns = unsignedField(obj, "max_virtual_ns") orelse 0;
        const advance_ns = unsignedField(obj, "advance_ns") orelse default_advance_ns;
        const start_clock = self.backend.clock_ns;
        var p = self.backend.asPlatform();
        var ran: u64 = 0;
        var result: gameport.game.UpdateResult = if (game.phase == .finished) .finished else .running;
        var stopped_by: []const u8 = undefined;
        while (true) {
            if (conditionMet(cond, game)) {
                stopped_by = "condition";
                break;
            }
            if (game.phase == .finished) {
                stopped_by = "finished";
                break;
            }
            if (ran >= max_updates) {
                stopped_by = "limit:max_updates";
                break;
            }
            if (max_virtual_ns != 0 and self.backend.clock_ns - start_clock >= max_virtual_ns) {
                stopped_by = "limit:max_virtual_ns";
                break;
            }
            result = game.update(&p) catch |err| return .{ .err = try std.fmt.allocPrint(arena, "update failed: {s}", .{@errorName(err)}) };
            ran += 1;
            self.backend.advance(advance_ns);
        }
        return .{ .ok = .{ .run_until = try self.stepResult(arena, game, ran, result, stopped_by) } };
    }

    fn stepResult(self: *Host, arena: std.mem.Allocator, game: *const Game, ran: u64, result: gameport.game.UpdateResult, stopped_by: []const u8) error{OutOfMemory}!StepResult {
        return .{
            .ran = ran,
            .result = @tagName(result),
            .stopped_by = stopped_by,
            .clock_ns = self.backend.clock_ns,
            .game = try snapshotOut(arena, game),
        };
    }

    fn cmdInspect(self: *Host, arena: std.mem.Allocator) error{OutOfMemory}!Response {
        return .{ .ok = .{ .inspect = .{
            .instance = self.instance,
            .game = if (self.game) |*g| try snapshotOut(arena, g) else null,
            .backend = .{
                .started = self.backend.started,
                .clock_ns = self.backend.clock_ns,
                .frames_presented = self.backend.frames_presented,
                .last_frame_hash = try hex64(arena, self.backend.last_frame_hash),
                .events_pending = self.backend.pending.items.len - self.backend.next_pending,
                .relative_mouse = self.backend.relative_mouse,
                .audio = .{
                    .queued_frames = self.backend.audio.queued_frames,
                    .played_frames = self.backend.audio.played_frames,
                    .running = self.backend.audio.open,
                    .suspended = false,
                },
                .calls = self.backend.calls,
            },
        } } };
    }

    fn cmdCapture(self: *Host, arena: std.mem.Allocator, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        const what = stringField(obj, "what") orelse "frame";
        const path = stringField(obj, "path");
        if (std.mem.eql(u8, what, "frame")) {
            const frame = self.backend.captureFrame() orelse return .{ .err = "no frame has been presented" };
            const digest = try sha256Hex(arena, frame.pixels);
            if (path) |pth| {
                writePpm(self.io, pth, frame) catch |err| return .{ .err = try std.fmt.allocPrint(arena, "cannot write {s}: {s}", .{ pth, @errorName(err) }) };
            }
            return .{ .ok = .{ .capture = .{
                .what = "frame",
                .path = path,
                .width = frame.width,
                .height = frame.height,
                .bytes = frame.pixels.len,
                .sha256 = digest,
            } } };
        }
        if (std.mem.eql(u8, what, "audio")) {
            if (!self.backend.audio.record) return .{ .err = "audio recording is off: reset with record_audio" };
            const pcm = std.mem.sliceAsBytes(self.backend.audio.pcm.items);
            const digest = try sha256Hex(arena, pcm);
            if (path) |pth| {
                writeBytes(self.io, pth, pcm) catch |err| return .{ .err = try std.fmt.allocPrint(arena, "cannot write {s}: {s}", .{ pth, @errorName(err) }) };
            }
            const channels = self.backend.audio.format.channels;
            return .{ .ok = .{ .capture = .{
                .what = "audio",
                .path = path,
                .channels = channels,
                .sample_rate = self.backend.audio.format.sample_rate,
                .frames = if (channels == 0) 0 else self.backend.audio.pcm.items.len / channels,
                .bytes = pcm.len,
                .sha256 = digest,
            } } };
        }
        return .{ .err = "what must be frame or audio" };
    }

    /// The source that the game reads: the bound one with an asset path, else the in-memory table.
    pub fn assetSource(self: *Host) platform.AssetSource {
        return self.assets_override orelse self.assets.assetSource();
    }

    /// The store that the game writes: the bound one with an asset path or `--saves`.
    pub fn saveStorage(self: *Host) platform.Storage {
        return self.storage_override orelse self.storage.storage();
    }

    /// The logical names of the bound source under `prefix`. The host lists them in the command,
    /// not through the workflow executor: it has no frame loop that must stay responsive.
    fn cmdAssetsList(self: *Host, arena: std.mem.Allocator, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        const prefix = stringField(obj, "prefix") orelse "";
        var entries = self.assetSource().list(prefix) catch |err| {
            return .{ .err = try std.fmt.allocPrint(arena, "assets_list failed: {s}", .{@errorName(err)}) };
        };
        defer entries.deinit();
        const names = try arena.alloc([]const u8, entries.names.len);
        for (entries.names, 0..) |name, i| names[i] = try arena.dupe(u8, name);
        return .{ .ok = .{ .assets_list = .{ .prefix = prefix, .count = names.len, .names = names } } };
    }

    /// All save keys of the bound store, sorted.
    fn cmdSaveList(self: *Host, arena: std.mem.Allocator) error{OutOfMemory}!Response {
        var names = self.saveStorage().listSaves() catch |err| {
            return .{ .err = try std.fmt.allocPrint(arena, "save_list failed: {s}", .{@errorName(err)}) };
        };
        defer names.deinit();
        const out = try arena.alloc([]const u8, names.names.len);
        for (names.names, 0..) |n, i| out[i] = try arena.dupe(u8, n);
        return .{ .ok = .{ .save_list = .{ .count = out.len, .names = out } } };
    }

    fn cmdSaveRecording(self: *Host, obj: std.json.ObjectMap) error{OutOfMemory}!Response {
        const path = stringField(obj, "path") orelse return .{ .err = "path is missing" };
        writeBytes(self.io, path, self.recording.items) catch return .{ .err = "cannot write the recording" };
        return .{ .ok = .{ .save_recording = .{ .path = path, .commands = self.commands_recorded } } };
    }
};

fn unsignedField(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .string => |s| std.fmt.parseInt(u64, s, 0) catch null,
        else => null,
    };
}

fn signedField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 0) catch null,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn hex64(arena: std.mem.Allocator, v: u64) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{x:0>16}", .{v});
}

fn sha256Hex(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    const hex = std.fmt.bytesToHex(out, .lower);
    return arena.dupe(u8, &hex);
}

pub fn snapshotOut(arena: std.mem.Allocator, game: *const Game) error{OutOfMemory}!SnapshotOut {
    return .{
        .phase = @tagName(game.phase),
        .update_count = game.update_count,
        .events_consumed = game.events_consumed,
        .frames_presented = game.frames_presented,
        .last_frame_hash = try hex64(arena, game.last_frame_hash),
        .state_hash = try hex64(arena, game.state.hash()),
        .title = try arena.dupe(u8, game.title()),
        .bounces = game.state.bounces,
        .saves_written = game.saves_written,
        .loads_done = game.loads_done,
    };
}

pub const EventParseError = error{ MissingKind, UnknownKind, MissingKey, UnknownKey, MissingField, UnknownButton, TextTooLong, Unsupported };

/// One scripted event from its JSON form: `kind` names the payload, `t` is its time, and the other
/// fields are the payload's.
pub fn parseEvent(obj: std.json.ObjectMap, default_time: u64) EventParseError!platform.Event {
    const kind_name = stringField(obj, "kind") orelse return error.MissingKind;
    const kind = std.meta.stringToEnum(platform.Event.Kind, kind_name) orelse return error.UnknownKind;
    const t = unsignedField(obj, "t") orelse default_time;
    const payload: platform.Event.Payload = switch (kind) {
        .key_down, .key_up => blk: {
            const key_name = stringField(obj, "key") orelse return error.MissingKey;
            const key = std.meta.stringToEnum(platform.Key, key_name) orelse return error.UnknownKey;
            const repeat = if (obj.get("repeat")) |r| (r == .bool and r.bool) else false;
            const ev: platform.Event.KeyEvent = .{ .key = key, .repeat = repeat };
            break :blk if (kind == .key_down) .{ .key_down = ev } else .{ .key_up = ev };
        },
        .text_input => blk: {
            const text = stringField(obj, "text") orelse return error.MissingField;
            if (text.len > 8) return error.TextTooLong;
            var ti: platform.Event.TextInput = .{};
            @memcpy(ti.bytes[0..text.len], text);
            ti.len = @intCast(text.len);
            break :blk .{ .text_input = ti };
        },
        .mouse_motion => .{ .mouse_motion = .{
            .dx = @intCast(signedField(obj, "dx") orelse 0),
            .dy = @intCast(signedField(obj, "dy") orelse 0),
            .x = @intCast(signedField(obj, "x") orelse 0),
            .y = @intCast(signedField(obj, "y") orelse 0),
        } },
        .mouse_button_down, .mouse_button_up => blk: {
            const button_name = stringField(obj, "button") orelse return error.MissingField;
            const button = std.meta.stringToEnum(platform.MouseButton, button_name) orelse return error.UnknownButton;
            const ev: platform.Event.MouseButtonEvent = .{
                .button = button,
                .x = @intCast(signedField(obj, "x") orelse 0),
                .y = @intCast(signedField(obj, "y") orelse 0),
            };
            break :blk if (kind == .mouse_button_down) .{ .mouse_button_down = ev } else .{ .mouse_button_up = ev };
        },
        .mouse_wheel => .{ .mouse_wheel = .{
            .dx = @intCast(signedField(obj, "dx") orelse 0),
            .dy = @intCast(signedField(obj, "dy") orelse 0),
        } },
        .controller_added => .{ .controller_added = @fromBackingInt(@intCast(@as(u32, @intCast(unsignedField(obj, "controller") orelse 0)))) },
        .controller_removed => .{ .controller_removed = @fromBackingInt(@intCast(@as(u32, @intCast(unsignedField(obj, "controller") orelse 0)))) },
        .controller_button_down, .controller_button_up => blk: {
            const button_name = stringField(obj, "button") orelse return error.MissingField;
            const button = std.meta.stringToEnum(platform.ControllerButton, button_name) orelse return error.UnknownButton;
            const ev: platform.Event.ControllerButtonEvent = .{
                .controller = @fromBackingInt(@intCast(@as(u32, @intCast(unsignedField(obj, "controller") orelse 0)))),
                .button = button,
            };
            break :blk if (kind == .controller_button_down) .{ .controller_button_down = ev } else .{ .controller_button_up = ev };
        },
        .controller_axis => blk: {
            const axis_name = stringField(obj, "axis") orelse return error.MissingField;
            const axis = std.meta.stringToEnum(platform.ControllerAxis, axis_name) orelse return error.UnknownButton;
            break :blk .{ .controller_axis = .{
                .controller = @fromBackingInt(@intCast(@as(u32, @intCast(unsignedField(obj, "controller") orelse 0)))),
                .axis = axis,
                .value = @intCast(std.math.clamp(signedField(obj, "value") orelse 0, -32768, 32767)),
            } };
        },
        .focus_gained => .focus_gained,
        .focus_lost => .focus_lost,
        .capture_changed => .{ .capture_changed = if (obj.get("captured")) |c| (c == .bool and c.bool) else false },
        .drawable_resized => .{ .drawable_resized = .{
            .width = @intCast(unsignedField(obj, "width") orelse 0),
            .height = @intCast(unsignedField(obj, "height") orelse 0),
        } },
        .quit => .quit,
        // This host does not script transport events.
        .connected, .disconnected, .received => return error.Unsupported,
    };
    return .{ .time_ns = t, .payload = payload };
}

/// Writes a binary PPM (P6): lossless RGB without the alpha, which is always 255.
fn writePpm(io: std.Io, path: []const u8, frame: platform.RgbaFrame) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;
    try w.print("P6\n{d} {d}\n255\n", .{ frame.width, frame.height });
    var y: u32 = 0;
    while (y < frame.height) : (y += 1) {
        const row = frame.row(y);
        var x: usize = 0;
        while (x < row.len) : (x += 4) try w.writeAll(row[x .. x + 3]);
    }
    try w.flush();
}

fn writeBytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

/// Writes one response line: `{"ok":true,"cmd":name,"result":{...}}` or `{"ok":false,...}`.
pub fn writeResponse(name: []const u8, response: Response, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("ok");
    try js.write(response == .ok);
    try js.objectField("cmd");
    try js.write(name);
    switch (response) {
        .ok => |outcome| {
            try js.objectField("result");
            switch (outcome) {
                inline else => |payload| try js.write(payload),
            }
        },
        .err => |message| {
            try js.objectField("error");
            try js.write(message);
        },
    }
    try js.endObject();
    try w.writeByte('\n');
}

fn runScript(host: *Host, gpa: std.mem.Allocator, script: []const []const u8, out: *std.Io.Writer) !void {
    for (script) |line| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        _ = try host.executeLine(arena_state.allocator(), line, out);
    }
}

const test_script = [_][]const u8{
    \\{"cmd":"reset","assets":[{"name":"TITLE.TXT","text":"Skeleton\nsecond line"}]}
    ,
    \\{"cmd":"step","updates":30}
    ,
    \\{"cmd":"inject","events":[{"kind":"key_down","key":"up"},{"kind":"key_down","key":"f2"}]}
    ,
    \\{"cmd":"step","updates":30}
    ,
    \\{"cmd":"inject","events":[{"kind":"key_down","key":"escape"}]}
    ,
    \\{"cmd":"run_until","condition":{"finished":true},"max_updates":100}
    ,
    \\{"cmd":"save_list"}
    ,
    \\{"cmd":"inspect"}
    ,
};

test "the same script replays identically on independent hosts" {
    const gpa = std.testing.allocator;
    var a = Host.init(gpa, std.testing.io);
    defer a.deinit();
    var b = Host.init(gpa, std.testing.io);
    defer b.deinit();
    var out_a: std.Io.Writer.Allocating = .init(gpa);
    defer out_a.deinit();
    var out_b: std.Io.Writer.Allocating = .init(gpa);
    defer out_b.deinit();
    try runScript(&a, gpa, &test_script, &out_a.writer);
    try runScript(&b, gpa, &test_script, &out_b.writer);
    try std.testing.expectEqualStrings(out_a.written(), out_b.written());
    // The title came from the synthetic asset, F2 wrote the save, and Escape finished the game.
    try std.testing.expect(std.mem.indexOf(u8, out_a.written(), "\"title\":\"Skeleton\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_a.written(), "\"saves_written\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_a.written(), "\"names\":[\"STATE\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_a.written(), "\"phase\":\"finished\"") != null);
}

test "an unknown command and a command before reset are errors, and the host goes on" {
    const gpa = std.testing.allocator;
    var host = Host.init(gpa, std.testing.io);
    defer host.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try runScript(&host, gpa, &.{ "{\"cmd\":\"fly\"}", "{\"cmd\":\"step\"}", "{\"cmd\":\"reset\"}", "{\"cmd\":\"step\"}" }, &out.writer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "{\"ok\":false"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "{\"ok\":false"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "{\"ok\":true"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "{\"ok\":true"));
}
