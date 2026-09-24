//! The browser build: the shared game in a WebAssembly module (DESIGN.md). The page's script,
//! `gameport.js`, gives the game's files to the module, starts the game and calls `gp_frame` once
//! for each animation frame. The module draws, plays sound and reads input through `WebBackend`,
//! which calls the functions that the script imports. Every file is in memory before the game
//! starts, so no read waits and the module needs no suspension of its stack (no Asyncify).
//!
//! The module links no libc, and the script gives it its memory.
const std = @import("std");
const gameport = @import("gameport");
const Host = @import("host.zig").Host;
const WebBackend = @import("backend.zig").WebBackend;
const PageStorage = @import("storage.zig").PageStorage;
const keys = @import("keys.zig");

// --- the functions of the page ---------------------------------------------------------------

const page = struct {
    extern "env" fn js_now() f64;
    extern "env" fn js_set_resolution(width: u32, height: u32) void;
    extern "env" fn js_present(pixels: [*]const u8, width: u32, height: u32, stride: u32) void;
    extern "env" fn js_audio_open(rate: u32, channels: u32) u32;
    extern "env" fn js_audio_queue(samples: [*]const i16, frames: u32, channels: u32) u32;
    extern "env" fn js_audio_queued() f64;
    extern "env" fn js_audio_state() u32;
    extern "env" fn js_audio_clear() void;
    extern "env" fn js_audio_close() void;
    extern "env" fn js_set_relative_mouse(enabled: u32) u32;
    extern "env" fn js_net_connect(host: [*]const u8, host_len: u32, port: u32) i32;
    extern "env" fn js_net_send(connection: u32, bytes: [*]const u8, len: u32) i32;
    extern "env" fn js_net_close(connection: u32) void;
    extern "env" fn js_log(level: u32, text: [*]const u8, len: u32) void;
    extern "env" fn js_storage_save(name: [*]const u8, name_len: u32, bytes: [*]const u8, len: u32) u32;
    extern "env" fn js_storage_delete(name: [*]const u8, name_len: u32) u32;
};

/// The imported functions use the C calling convention. The backend's table holds Zig functions,
/// so each import has a small Zig function here.
const imports = struct {
    fn nowMs() f64 {
        return page.js_now();
    }
    fn setResolution(width: u32, height: u32) void {
        page.js_set_resolution(width, height);
    }
    fn present(pixels: [*]const u8, width: u32, height: u32, stride: u32) void {
        page.js_present(pixels, width, height, stride);
    }
    fn audioOpen(rate: u32, channels: u32) u32 {
        return page.js_audio_open(rate, channels);
    }
    fn audioQueue(samples: [*]const i16, frames: u32, channels: u32) u32 {
        return page.js_audio_queue(samples, frames, channels);
    }
    fn audioQueued() f64 {
        return page.js_audio_queued();
    }
    fn audioState() u32 {
        return page.js_audio_state();
    }
    fn audioClear() void {
        page.js_audio_clear();
    }
    fn audioClose() void {
        page.js_audio_close();
    }
    fn setRelativeMouse(enabled: u32) u32 {
        return page.js_set_relative_mouse(enabled);
    }
    fn netConnect(name: [*]const u8, name_len: u32, port: u32) i32 {
        return page.js_net_connect(name, name_len, port);
    }
    fn netSend(connection: u32, bytes: [*]const u8, len: u32) i32 {
        return page.js_net_send(connection, bytes, len);
    }
    fn netClose(connection: u32) void {
        page.js_net_close(connection);
    }
    fn log(level: u32, text: [*]const u8, len: u32) void {
        page.js_log(level, text, len);
    }
    fn storageSave(name: [*]const u8, name_len: u32, bytes: [*]const u8, len: u32) u32 {
        return page.js_storage_save(name, name_len, bytes, len);
    }
    fn storageDelete(name: [*]const u8, name_len: u32) u32 {
        return page.js_storage_delete(name, name_len);
    }
};

const host = Host{
    .now_ms = imports.nowMs,
    .set_resolution = imports.setResolution,
    .present = imports.present,
    .audio_open = imports.audioOpen,
    .audio_queue = imports.audioQueue,
    .audio_queued = imports.audioQueued,
    .audio_state = imports.audioState,
    .audio_clear = imports.audioClear,
    .audio_close = imports.audioClose,
    .set_relative_mouse = imports.setRelativeMouse,
    .net_connect = imports.netConnect,
    .net_send = imports.netSend,
    .net_close = imports.netClose,
    .log = imports.log,
    .storage_save = imports.storageSave,
    .storage_delete = imports.storageDelete,
};

// --- logs and panics go to the browser's console -----------------------------------------------

pub const std_options: std.Options = .{ .logFn = logToConsole };

fn logToConsole(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [512]u8 = undefined;
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const text = std.fmt.bufPrint(&buf, prefix ++ format, args) catch buf[0..];
    page.js_log(@backingInt(level), text.ptr, @intCast(text.len));
}

pub const panic = std.debug.FullPanic(panicToConsole);

fn panicToConsole(message: []const u8, _: ?usize) noreturn {
    const lead = "panic: ";
    page.js_log(0, lead.ptr, lead.len);
    page.js_log(0, message.ptr, @intCast(message.len));
    @trap();
}

// --- the state of the module -------------------------------------------------------------------

const gpa = std.heap.wasm_allocator;

var assets: gameport.memory.MemoryAssetSource = undefined;
/// The game's records, kept by the page in the browser's storage.
var storage: PageStorage = undefined;
var jobs: gameport.workflow.Inline = undefined;
var backend: WebBackend = undefined;
var ready = false;
var game: ?*gameport.Game = null;
var last_error: ?anyerror = null;

/// The bytes that the script writes before a call that takes text (a key code, typed text), and
/// where calls that answer with text write it.
var scratch: [4096]u8 = undefined;

// --- exports -----------------------------------------------------------------------------------

/// Makes the providers and the backend. The script calls it once, first.
export fn gp_init() i32 {
    if (ready) return 0;
    assets = gameport.memory.MemoryAssetSource.init(gpa);
    storage = PageStorage.init(gpa, &host);
    jobs = gameport.workflow.Inline.init(gpa, assets.assetSource(), storage.storage());
    backend = WebBackend.init(gpa, &host);
    backend.jobs = jobs.jobs();
    ready = true;
    return 0;
}

export fn gp_scratch() [*]u8 {
    return &scratch;
}

export fn gp_scratch_len() u32 {
    return scratch.len;
}

/// The address that `gp_alloc` gives for an empty buffer. It is never written or freed.
var empty_buffer: [1]u8 = .{0};

/// Memory for the script to fill: a game file and its name, or a kept record. Null when the
/// memory cannot grow.
export fn gp_alloc(len: u32) ?[*]u8 {
    if (len == 0) return &empty_buffer;
    const bytes = gpa.alloc(u8, len) catch return null;
    return bytes.ptr;
}

export fn gp_free(ptr: [*]u8, len: u32) void {
    if (len == 0) return;
    gpa.free(ptr[0..len]);
}

/// Adds one game file. The module keeps the name and the bytes, which `gp_alloc` made, for as long
/// as it runs. Returns 0, or -1 for an invalid name.
export fn gp_add_asset(name: [*]u8, name_len: u32, bytes: [*]u8, len: u32) i32 {
    if (!ready) return -1;
    assets.add(name[0..name_len], bytes[0..len]) catch return -1;
    return 0;
}

/// Gives back one record that the page kept from an earlier load, before `gp_start`. The module
/// frees the name and the bytes. Returns 0, or -1 when the record cannot be kept.
export fn gp_add_record(name: [*]u8, name_len: u32, bytes: [*]u8, len: u32) i32 {
    defer gp_free(name, name_len);
    defer gp_free(bytes, len);
    if (!ready) return -1;
    storage.add(name[0..name_len], bytes[0..len]) catch return -1;
    return 0;
}

/// Starts the game. Returns 0, or -1 with the reason in `gp_error`.
export fn gp_start() i32 {
    if (!ready) return -1;
    if (game != null) return 0;
    const g = gpa.create(gameport.Game) catch |err| {
        last_error = err;
        return -1;
    };
    g.* = gameport.Game.init(gpa) catch |err| {
        gpa.destroy(g);
        last_error = err;
        return -1;
    };
    game = g;
    return 0;
}

/// One update of the game. Returns 0 while the game runs, 1 when it has finished, -1 before
/// `gp_start` and -2 when the update failed (the reason is in `gp_error`).
export fn gp_frame() i32 {
    const g = game orelse return -1;
    var p = backend.asPlatform();
    const result = g.update(&p) catch |err| {
        last_error = err;
        return -2;
    };
    return if (result == .finished) 1 else 0;
}

/// Writes the name of the last error into the scratch buffer and returns its length.
export fn gp_error() u32 {
    const name = if (last_error) |err| @errorName(err) else "";
    const len = @min(name.len, scratch.len);
    @memcpy(scratch[0..len], name[0..len]);
    return @intCast(len);
}

/// A key: its `KeyboardEvent.code` (`code_len` bytes in the scratch buffer), down or up. Returns 1
/// when the key is one of the game's keys, so the page can keep the browser from acting on it.
export fn gp_key(code_len: u32, down: u32, repeat: u32) u32 {
    const key = keys.fromCode(scratch[0..@min(code_len, scratch.len)]);
    if (key == .unknown) return 0;
    backend.keyEvent(key, down != 0, repeat != 0);
    return 1;
}

/// Text that a key typed: `len` UTF-8 bytes in the scratch buffer.
export fn gp_text(len: u32) void {
    backend.textEvent(scratch[0..@min(len, scratch.len)]);
}

export fn gp_motion(dx: i32, dy: i32, x: i32, y: i32) void {
    backend.motionEvent(dx, dy, x, y);
}

/// A button, numbered as `MouseEvent.button` numbers them: 0 left, 1 middle, 2 right.
export fn gp_button(button: u32, down: u32, x: i32, y: i32) void {
    backend.buttonEvent(@fromBackingInt(@as(u8, @intCast(@min(button, 255)))), down != 0, x, y);
}

export fn gp_wheel(dx: i32, dy: i32) void {
    backend.wheelEvent(dx, dy);
}

export fn gp_focus(gained: u32) void {
    backend.focusEvent(gained != 0);
}

/// The page reports whether it has the pointer lock.
export fn gp_capture(captured: u32) void {
    backend.captureEvent(captured != 0);
}

export fn gp_resized(width: u32, height: u32) void {
    backend.resizedEvent(width, height);
}

/// The state of the game as one JSON object in the scratch buffer, for the page's tests and for
/// debugging. Returns its length, or 0 when it does not fit.
export fn gp_inspect() u32 {
    const g = game orelse return 0;
    var p = backend.asPlatform();
    const audio = p.audioStatus();
    var w: std.Io.Writer = .fixed(&scratch);
    std.json.Stringify.value(.{
        .phase = @tagName(g.phase),
        .update_count = g.update_count,
        .frames_presented = g.frames_presented,
        .events_consumed = g.events_consumed,
        .title = g.title(),
        .bounces = g.state.bounces,
        .saves_written = g.saves_written,
        .loads_done = g.loads_done,
        .audio_running = audio.running,
        .audio_played = audio.played_frames,
    }, .{}, &w) catch return 0;
    return @intCast(w.end);
}
