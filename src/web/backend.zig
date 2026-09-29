//! The browser backend: the platform contract (`platform.Platform`) over the functions of the
//! page (`host.zig`). The page reports each device event through the exports of the module;
//! `poll_events` gives these events to the game in order. The rules follow the native host where
//! a browser permits it: the game reads the mouse as relative counts, so the pointer is locked
//! while the game has it, and a capture change is an event.
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;
const host_mod = @import("host.zig");
const Host = host_mod.Host;

pub const WebBackend = struct {
    allocator: std.mem.Allocator,
    host: *const Host,
    started: bool = false,
    capabilities: platform.Capabilities = .{},
    resolution: ?platform.Size = null,
    frames_presented: u64 = 0,

    /// The device events that the page reported and the game has not polled yet.
    events: std.ArrayList(platform.Event) = .empty,
    next_event: usize = 0,
    last_event_ns: u64 = 0,

    /// Whether the game asked for the relative mouse. While it did and the page has no pointer
    /// lock, motion is not given to the game: the desktop pointer is not the game's.
    relative_wanted: bool = false,
    /// Whether the page has the pointer lock.
    captured: bool = false,

    audio: Audio = .{},

    pub const Audio = struct {
        open: bool = false,
        format: platform.AudioFormat = .{},
        /// All frames that `audio_queue` accepted. `played` is computed from this count and the
        /// frames that the page still holds.
        accepted_frames: u64 = 0,
        /// The frames that `audio_clear` discarded. They are never reported as played.
        discarded_frames: u64 = 0,
    };

    /// The largest render resolution that the backend accepts, in each dimension.
    pub const max_dimension: u32 = 16384;

    pub fn init(allocator: std.mem.Allocator, host: *const Host) WebBackend {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn deinit(self: *WebBackend) void {
        if (self.audio.open) self.host.audio_close();
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn asPlatform(self: *WebBackend) platform.Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Platform.VTable{
        .start = start,
        .set_resolution = setResolution,
        .present = present,
        .poll_events = pollEvents,
        .now_ns = nowNs,
        .audio_open = audioOpen,
        .audio_queue = audioQueue,
        .audio_status = audioStatus,
        .audio_clear = audioClear,
        .audio_close = audioClose,
        .set_relative_mouse = setRelativeMouse,
    };

    fn cast(ctx: *anyopaque) *WebBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn start(ctx: *anyopaque) platform.PlatformError!platform.Capabilities {
        const self = cast(ctx);
        if (!self.started) {
            self.started = true;
            self.capabilities = .{ .video = true, .audio = true, .controllers = false };
        }
        return self.capabilities;
    }

    // --- time --------------------------------------------------------------------------------

    fn nowNs(ctx: *anyopaque) u64 {
        return cast(ctx).elapsedNs();
    }

    fn elapsedNs(self: *const WebBackend) u64 {
        const ms = self.host.now_ms();
        return if (ms > 0) @intFromFloat(ms * std.time.ns_per_ms) else 0;
    }

    /// The time of a new event: now, but never earlier than the previous event, so the delivery
    /// order and the time stamps agree.
    fn eventTime(self: *WebBackend) u64 {
        const t = @max(self.elapsedNs(), self.last_event_ns);
        self.last_event_ns = t;
        return t;
    }

    // --- presentation ------------------------------------------------------------------------

    fn setResolution(ctx: *anyopaque, width: u32, height: u32) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidResolution;
        // An unchanged resolution is not a mode change. The page resizes nothing.
        if (self.resolution) |current| {
            if (current.width == width and current.height == height) return;
        }
        self.host.set_resolution(width, height);
        self.resolution = .{ .width = width, .height = height };
    }

    fn present(ctx: *anyopaque, frame: platform.RgbaFrame) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        frame.validate() catch return error.InvalidFrame;
        const res = self.resolution orelse return error.InvalidResolution;
        if (frame.width != res.width or frame.height != res.height) return error.InvalidFrame;
        const stride = std.math.cast(u32, frame.stride) orelse return error.InvalidFrame;
        // The page copies the pixels into its canvas during the call and keeps no reference.
        self.host.present(frame.pixels.ptr, frame.width, frame.height, stride);
        self.frames_presented += 1;
    }

    // --- events ------------------------------------------------------------------------------

    fn pollEvents(ctx: *anyopaque, dst: []platform.Event) usize {
        const self = cast(ctx);
        var n: usize = 0;
        while (n < dst.len and self.next_event < self.events.items.len) : (self.next_event += 1) {
            dst[n] = self.events.items[self.next_event];
            n += 1;
        }
        if (self.next_event == self.events.items.len and self.next_event != 0) {
            self.events.clearRetainingCapacity();
            self.next_event = 0;
        }
        return n;
    }

    fn push(self: *WebBackend, payload: platform.Event.Payload) void {
        self.events.append(self.allocator, .{ .time_ns = self.eventTime(), .payload = payload }) catch {};
    }

    pub fn keyEvent(self: *WebBackend, key: platform.Key, down: bool, repeat: bool) void {
        const event: platform.Event.KeyEvent = .{ .key = key, .repeat = repeat };
        self.push(if (down) .{ .key_down = event } else .{ .key_up = event });
    }

    /// Text that a key typed, as UTF-8. It is split into `TextInput` events of at most eight
    /// bytes, only between code points.
    pub fn textEvent(self: *WebBackend, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            var chunk: platform.Event.TextInput = .{};
            while (i < text.len) {
                const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const len = @min(@as(usize, seq), text.len - i);
                if (chunk.len + len > chunk.bytes.len) break;
                @memcpy(chunk.bytes[chunk.len..][0..len], text[i..][0..len]);
                chunk.len += @intCast(len);
                i += len;
            }
            self.push(.{ .text_input = chunk });
        }
    }

    /// One pointer motion: `dx` and `dy` are the relative counts, `x` and `y` the position in
    /// page pixels. The game does not get the motion of a pointer that it asked for and does not
    /// have.
    pub fn motionEvent(self: *WebBackend, dx: i32, dy: i32, x: i32, y: i32) void {
        if (self.relative_wanted and !self.captured) return;
        self.push(.{ .mouse_motion = .{ .dx = dx, .dy = dy, .x = x, .y = y } });
    }

    pub fn buttonEvent(self: *WebBackend, button: platform.MouseButton, down: bool, x: i32, y: i32) void {
        const event: platform.Event.MouseButtonEvent = .{ .button = button, .x = x, .y = y };
        self.push(if (down) .{ .mouse_button_down = event } else .{ .mouse_button_up = event });
    }

    pub fn wheelEvent(self: *WebBackend, dx: i32, dy: i32) void {
        self.push(.{ .mouse_wheel = .{ .dx = dx, .dy = dy } });
    }

    pub fn focusEvent(self: *WebBackend, gained: bool) void {
        self.push(if (gained) .focus_gained else .focus_lost);
    }

    /// The page reports a change of the pointer lock.
    pub fn captureEvent(self: *WebBackend, captured: bool) void {
        if (captured == self.captured) return;
        self.captured = captured;
        self.push(.{ .capture_changed = captured });
    }

    pub fn resizedEvent(self: *WebBackend, width: u32, height: u32) void {
        self.push(.{ .drawable_resized = .{ .width = width, .height = height } });
    }

    pub fn quitEvent(self: *WebBackend) void {
        self.push(.quit);
    }

    // --- audio -------------------------------------------------------------------------------

    fn audioOpen(ctx: *anyopaque, requested: platform.AudioFormat) platform.PlatformError!platform.AudioFormat {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        if (requested.channels == 0 or requested.channels > 2 or requested.sample_rate == 0) return error.Unsupported;
        if (self.audio.open) self.host.audio_close();
        self.audio = .{};
        const rate = self.host.audio_open(requested.sample_rate, requested.channels);
        if (rate == 0) return error.DeviceFailure;
        self.audio = .{ .open = true, .format = .{ .channels = requested.channels, .sample_rate = rate } };
        return self.audio.format;
    }

    fn queuedFrames(self: *const WebBackend) u64 {
        const queued = self.host.audio_queued();
        return if (queued > 0) @intFromFloat(queued) else 0;
    }

    fn audioQueue(ctx: *anyopaque, samples: []const i16) platform.PlatformError!usize {
        const self = cast(ctx);
        if (!self.audio.open) return error.DeviceFailure;
        const channels: usize = self.audio.format.channels;
        const offered = std.math.cast(u32, samples.len / channels) orelse std.math.maxInt(u32);
        if (offered == 0) return 0;
        const accepted = @min(self.host.audio_queue(samples.ptr, offered, @intCast(channels)), offered);
        self.audio.accepted_frames += accepted;
        return accepted;
    }

    fn audioStatus(ctx: *anyopaque) platform.AudioStatus {
        const self = cast(ctx);
        if (!self.audio.open) return .{};
        const queued = self.queuedFrames();
        const state: host_mod.AudioState = @fromBackingInt(self.host.audio_state());
        return .{
            .queued_frames = queued,
            .played_frames = self.audio.accepted_frames -| self.audio.discarded_frames -| queued,
            .running = state == .running,
            .suspended = state != .running,
        };
    }

    fn audioClear(ctx: *anyopaque) void {
        const self = cast(ctx);
        if (!self.audio.open) return;
        self.audio.discarded_frames += self.queuedFrames();
        self.host.audio_clear();
    }

    fn audioClose(ctx: *anyopaque) void {
        const self = cast(ctx);
        if (self.audio.open) self.host.audio_close();
        self.audio = .{};
    }

    // --- capture -----------------------------------------------------------------------------

    /// Requests the pointer lock. A `capture_changed` event reports the state that the page
    /// really has. A browser locks the pointer only after a click, so the lock often comes later,
    /// with its own event.
    fn setRelativeMouse(ctx: *anyopaque, enabled: bool) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        self.relative_wanted = enabled;
        self.captured = self.host.set_relative_mouse(@intFromBool(enabled)) != 0;
        self.push(.{ .capture_changed = self.captured });
    }
};

// --- tests -------------------------------------------------------------------------------------

const testing = std.testing;

/// A page for the tests: a clock, a canvas and an audio output that it counts.
const FakePage = struct {
    var clock_ms: f64 = 0;
    var canvas: platform.Size = .{ .width = 0, .height = 0 };
    var presented: u64 = 0;
    var first_byte: u8 = 0;
    var audio_rate: u32 = 44100;
    var queued: f64 = 0;
    var cleared: u32 = 0;
    var room: u32 = std.math.maxInt(u32);
    var lock_granted: bool = false;

    fn reset() void {
        clock_ms = 0;
        canvas = .{ .width = 0, .height = 0 };
        presented = 0;
        audio_rate = 44100;
        queued = 0;
        cleared = 0;
        room = std.math.maxInt(u32);
        lock_granted = false;
    }
    fn nowMs() f64 {
        return clock_ms;
    }
    fn setResolution(w: u32, h: u32) void {
        canvas = .{ .width = w, .height = h };
    }
    fn present(pixels: [*]const u8, _: u32, _: u32, _: u32) void {
        first_byte = pixels[0];
        presented += 1;
    }
    fn audioOpen(_: u32, _: u32) u32 {
        return audio_rate;
    }
    fn audioQueue(_: [*]const i16, frames: u32, _: u32) u32 {
        const n = @min(frames, room);
        queued += @floatFromInt(n);
        return n;
    }
    fn audioQueued() f64 {
        return queued;
    }
    fn audioState() u32 {
        return @backingInt(host_mod.AudioState.running);
    }
    fn audioClear() void {
        cleared += 1;
        queued = 0;
    }
    fn noop() void {}
    fn relative(enabled: u32) u32 {
        return @intFromBool(enabled != 0 and lock_granted);
    }
    fn log(_: u32, _: [*]const u8, _: u32) void {}

    const host = Host{
        .now_ms = nowMs,
        .set_resolution = setResolution,
        .present = present,
        .audio_open = audioOpen,
        .audio_queue = audioQueue,
        .audio_queued = audioQueued,
        .audio_state = audioState,
        .audio_clear = audioClear,
        .audio_close = noop,
        .set_relative_mouse = relative,
        .log = log,
        .storage_save = storageSave,
        .storage_delete = storageDelete,
    };
    fn storageSave(_: [*]const u8, _: u32, _: [*]const u8, _: u32) u32 {
        return 1;
    }
    fn storageDelete(_: [*]const u8, _: u32) u32 {
        return 1;
    }
};

test "events come in order with ordered time stamps, and motion needs the pointer" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();

    FakePage.clock_ms = 10;
    backend.keyEvent(.a, true, false);
    backend.textEvent("a");
    FakePage.clock_ms = 5; // A clock that goes back does not reorder the events.
    backend.keyEvent(.a, false, false);
    try p.setRelativeMouse(true);
    backend.motionEvent(3, 4, 10, 10); // Wanted, not captured: dropped.
    backend.captureEvent(true);
    backend.motionEvent(5, -6, 20, 30);
    backend.buttonEvent(.right, true, 20, 30);

    var events: [16]platform.Event = undefined;
    const n = p.pollEvents(&events);
    try testing.expectEqual(@as(usize, 7), n);
    try testing.expectEqual(platform.Key.a, events[0].payload.key_down.key);
    try testing.expectEqualStrings("a", events[1].payload.text_input.slice());
    try testing.expectEqual(platform.Key.a, events[2].payload.key_up.key);
    try testing.expect(events[2].time_ns >= events[1].time_ns);
    try testing.expect(!events[3].payload.capture_changed);
    try testing.expect(events[4].payload.capture_changed);
    try testing.expectEqual(@as(i32, 5), events[5].payload.mouse_motion.dx);
    try testing.expectEqual(platform.MouseButton.right, events[6].payload.mouse_button_down.button);
    try testing.expectEqual(@as(usize, 0), p.pollEvents(&events));
}

test "long text splits between code points" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    backend.textEvent("abcdefghé!");
    var events: [4]platform.Event = undefined;
    var p = backend.asPlatform();
    const n = p.pollEvents(&events);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("abcdefgh", events[0].payload.text_input.slice());
    try testing.expectEqualStrings("é!", events[1].payload.text_input.slice());
}

test "presentation checks the frame against the resolution" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    var pixels: [4 * 3 * 4]u8 = @splat(7);
    try testing.expectError(error.NotStarted, p.present(.{ .width = 4, .height = 3, .stride = 16, .pixels = &pixels }));
    _ = try p.start();
    try testing.expectError(error.InvalidResolution, p.present(.{ .width = 4, .height = 3, .stride = 16, .pixels = &pixels }));
    try p.setResolution(4, 3);
    try testing.expectEqual(@as(u32, 4), FakePage.canvas.width);
    try p.present(.{ .width = 4, .height = 3, .stride = 16, .pixels = &pixels });
    try testing.expectEqual(@as(u64, 1), FakePage.presented);
    try testing.expectEqual(@as(u8, 7), FakePage.first_byte);
    try testing.expectError(error.InvalidFrame, p.present(.{ .width = 2, .height = 3, .stride = 8, .pixels = &pixels }));
    try testing.expectError(error.InvalidResolution, p.setResolution(0, 3));
}

test "audio counts accepted, played and discarded frames as the native host does" {
    FakePage.reset();
    var backend = WebBackend.init(testing.allocator, &FakePage.host);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    const samples: [200]i16 = @splat(0);
    try testing.expectError(error.DeviceFailure, p.audioQueue(&samples));
    FakePage.audio_rate = 48000;
    const got = try p.audioOpen(.{ .channels = 2, .sample_rate = 44100 });
    try testing.expectEqual(@as(u32, 48000), got.sample_rate);
    try testing.expectEqual(@as(usize, 100), try p.audioQueue(&samples));
    FakePage.room = 30;
    try testing.expectEqual(@as(usize, 30), try p.audioQueue(&samples));
    // The page played 70 of the 130 frames.
    FakePage.queued = 60;
    var status = p.audioStatus();
    try testing.expectEqual(@as(u64, 60), status.queued_frames);
    try testing.expectEqual(@as(u64, 70), status.played_frames);
    try testing.expect(status.running);
    p.audioClear();
    status = p.audioStatus();
    try testing.expectEqual(@as(u64, 0), status.queued_frames);
    try testing.expectEqual(@as(u64, 70), status.played_frames);
    p.audioClose();
    try testing.expect(!p.audioStatus().running);
}
