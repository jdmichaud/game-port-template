//! `AgentBackend`: the native debugging platform (DESIGN.md). It has scripted
//! devices, a clock that advances only on command, frame capture and emulated audio playback,
//! all through the standard platform contracts. It uses no SDL, no window and no physical device.
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;
const workflow = gameport.workflow;

pub const AgentBackend = struct {
    /// The runner of the game's I/O workflows, which the host sets. Without one, a submission
    /// is refused.
    jobs: ?workflow.Jobs = null,
    /// The network calls go to this transport, when a host gives one (a simulated link in tests).
    net: platform.NetForward = .{},
    allocator: std.mem.Allocator,
    options: platform.HostOptions,
    started: bool = false,
    /// The controlled monotonic time. `now_ns` returns it; injected events use the same base.
    clock_ns: u64 = 0,
    /// Scripted events in injection order. An event is delivered when `time_ns <= clock_ns`.
    pending: std.ArrayList(platform.Event) = .empty,
    next_pending: usize = 0,
    resolution: ?platform.Size = null,
    /// The last presented frame, copied in `present`. The buffer of the game is never kept.
    capture: std.ArrayList(u8) = .empty,
    capture_size: platform.Size = .{ .width = 0, .height = 0 },
    frames_presented: u64 = 0,
    last_frame_hash: u64 = 0,
    audio: Audio = .{},
    relative_mouse: bool = false,
    /// Counts of six platform calls (the fields of `Calls`), for replay reports.
    calls: Calls = .{},

    pub const Audio = struct {
        open: bool = false,
        format: platform.AudioFormat = .{},
        /// The queue capacity in sample frames: one second at the negotiated rate.
        capacity_frames: u64 = 0,
        queued_frames: u64 = 0,
        played_frames: u64 = 0,
        /// The playback remainder in nanoseconds, so that the consumption stays exact over time.
        carry_ns: u64 = 0,
        /// The recorded PCM (interleaved i16), when `record` is set.
        record: bool = false,
        pcm: std.ArrayList(i16) = .empty,
    };

    pub const Calls = struct {
        start: u64 = 0,
        set_resolution: u64 = 0,
        present: u64 = 0,
        poll_events: u64 = 0,
        now_ns: u64 = 0,
        audio_queue: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, options: platform.HostOptions) AgentBackend {
        return .{ .allocator = allocator, .options = options };
    }

    /// Valid whether `start` succeeded or not. It stops nothing, because nothing runs on its own.
    pub fn deinit(self: *AgentBackend) void {
        self.pending.deinit(self.allocator);
        self.capture.deinit(self.allocator);
        self.audio.pcm.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns to the initial state and frees the captures and the scripted events.
    pub fn reset(self: *AgentBackend) void {
        self.pending.clearAndFree(self.allocator);
        self.capture.clearAndFree(self.allocator);
        self.audio.pcm.clearAndFree(self.allocator);
        const allocator = self.allocator;
        const options = self.options;
        self.* = init(allocator, options);
    }

    pub fn asPlatform(self: *AgentBackend) platform.Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    /// Queues a scripted event. Delivery is in injection order: an event with a later time holds
    /// back the events after it.
    pub fn inject(self: *AgentBackend, event: platform.Event) !void {
        try self.pending.append(self.allocator, event);
    }

    /// Advances the controlled clock and plays queued audio for that long.
    pub fn advance(self: *AgentBackend, ns: u64) void {
        self.clock_ns += ns;
        self.playAudio(ns);
    }

    pub fn captureFrame(self: *const AgentBackend) ?platform.RgbaFrame {
        if (self.frames_presented == 0) return null;
        return .{
            .width = self.capture_size.width,
            .height = self.capture_size.height,
            .stride = @as(usize, self.capture_size.width) * platform.RgbaFrame.bytes_per_pixel,
            .pixels = self.capture.items,
        };
    }

    fn playAudio(self: *AgentBackend, ns: u64) void {
        if (!self.audio.open) return;
        const total = self.audio.carry_ns + ns;
        const frames = total * self.audio.format.sample_rate / std.time.ns_per_s;
        self.audio.carry_ns = total - frames * std.time.ns_per_s / self.audio.format.sample_rate;
        const played = @min(frames, self.audio.queued_frames);
        self.audio.queued_frames -= played;
        self.audio.played_frames += played;
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
        .net_connect = netConnect,
        .net_listen = netListen,
        .net_stop_listening = netStopListening,
        .net_listen_status = netListenStatus,
        .net_send = netSend,
        .net_close = netClose,
        .io_submit = ioSubmit,
        .io_take = ioTake,
        .io_cancel = ioCancel,
    };

    fn cast(ctx: *anyopaque) *AgentBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn start(ctx: *anyopaque) platform.PlatformError!platform.Capabilities {
        const self = cast(ctx);
        self.calls.start += 1;
        self.started = true;
        return .{ .video = true, .audio = true, .controllers = true, .network = false };
    }

    fn setResolution(ctx: *anyopaque, width: u32, height: u32) platform.PlatformError!void {
        const self = cast(ctx);
        self.calls.set_resolution += 1;
        if (!self.started) return error.NotStarted;
        if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.InvalidResolution;
        const bytes = @as(usize, width) * height * platform.RgbaFrame.bytes_per_pixel;
        // Prepare the new capture storage before the mode changes.
        self.capture.resize(self.allocator, bytes) catch return error.OutOfMemory;
        @memset(self.capture.items, 0);
        self.resolution = .{ .width = width, .height = height };
        self.capture_size = .{ .width = width, .height = height };
    }

    fn present(ctx: *anyopaque, frame: platform.RgbaFrame) platform.PlatformError!void {
        const self = cast(ctx);
        self.calls.present += 1;
        if (!self.started) return error.NotStarted;
        frame.validate() catch return error.InvalidFrame;
        const res = self.resolution orelse return error.InvalidResolution;
        if (frame.width != res.width or frame.height != res.height) return error.InvalidFrame;
        const row_bytes = @as(usize, frame.width) * platform.RgbaFrame.bytes_per_pixel;
        var y: u32 = 0;
        while (y < frame.height) : (y += 1) {
            @memcpy(self.capture.items[@as(usize, y) * row_bytes ..][0..row_bytes], frame.row(y));
        }
        self.frames_presented += 1;
        self.last_frame_hash = std.hash.Wyhash.hash(0, self.capture.items);
    }

    fn pollEvents(ctx: *anyopaque, dst: []platform.Event) usize {
        const self = cast(ctx);
        self.calls.poll_events += 1;
        var n: usize = 0;
        while (n < dst.len and self.next_pending < self.pending.items.len) {
            const ev = self.pending.items[self.next_pending];
            if (ev.time_ns > self.clock_ns) break;
            dst[n] = ev;
            n += 1;
            self.next_pending += 1;
        }
        if (self.next_pending == self.pending.items.len and self.next_pending != 0) {
            self.pending.clearRetainingCapacity();
            self.next_pending = 0;
        }
        return self.net.poll(dst, n);
    }

    fn nowNs(ctx: *anyopaque) u64 {
        const self = cast(ctx);
        self.calls.now_ns += 1;
        return self.clock_ns;
    }

    fn audioOpen(ctx: *anyopaque, requested: platform.AudioFormat) platform.PlatformError!platform.AudioFormat {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        if (requested.channels == 0 or requested.sample_rate == 0) return error.Unsupported;
        self.audio.open = true;
        self.audio.format = requested;
        self.audio.capacity_frames = requested.sample_rate;
        self.audio.queued_frames = 0;
        self.audio.played_frames = 0;
        self.audio.carry_ns = 0;
        return requested;
    }

    fn audioQueue(ctx: *anyopaque, samples: []const i16) platform.PlatformError!usize {
        const self = cast(ctx);
        self.calls.audio_queue += 1;
        if (!self.audio.open) return error.DeviceFailure;
        const channels: usize = self.audio.format.channels;
        const offered = samples.len / channels;
        const room = self.audio.capacity_frames - self.audio.queued_frames;
        const accepted = @min(offered, room);
        if (self.audio.record) {
            self.audio.pcm.appendSlice(self.allocator, samples[0 .. accepted * channels]) catch return error.OutOfMemory;
        }
        self.audio.queued_frames += accepted;
        return accepted;
    }

    fn audioStatus(ctx: *anyopaque) platform.AudioStatus {
        const self = cast(ctx);
        return .{
            .queued_frames = self.audio.queued_frames,
            .played_frames = self.audio.played_frames,
            .running = self.audio.open,
            .suspended = false,
        };
    }

    fn audioClear(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.audio.queued_frames = 0;
    }

    fn audioClose(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.audio.open = false;
        self.audio.queued_frames = 0;
    }

    fn setRelativeMouse(ctx: *anyopaque, enabled: bool) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        self.relative_mouse = enabled;
        // The simulated host grants the request and reports it, as a real host does.
        self.pending.append(self.allocator, .{ .time_ns = self.clock_ns, .payload = .{ .capture_changed = enabled } }) catch return error.OutOfMemory;
    }

    fn netConnect(ctx: *anyopaque, endpoint: platform.Endpoint) platform.PlatformError!platform.ConnectionId {
        return cast(ctx).net.connect(endpoint);
    }

    fn netListen(ctx: *anyopaque, endpoint: platform.Endpoint) platform.PlatformError!void {
        return cast(ctx).net.listen(endpoint);
    }

    fn netStopListening(ctx: *anyopaque) void {
        cast(ctx).net.stopListening();
    }

    fn netListenStatus(ctx: *anyopaque) platform.ListenStatus {
        return cast(ctx).net.listenStatus();
    }

    fn netSend(ctx: *anyopaque, connection: platform.ConnectionId, message: []const u8) platform.PlatformError!void {
        return cast(ctx).net.send(connection, message);
    }

    fn netClose(ctx: *anyopaque, connection: platform.ConnectionId) void {
        cast(ctx).net.close(connection);
    }

    // --- I/O workflows -------------------------------------------------------------------------

    fn ioSubmit(ctx: *anyopaque, request: workflow.Request) workflow.SubmitError!workflow.JobId {
        const jobs = cast(ctx).jobs orelse return error.Closed;
        return jobs.submit(request);
    }
    fn ioTake(ctx: *anyopaque) ?workflow.Completion {
        const jobs = cast(ctx).jobs orelse return null;
        return jobs.take();
    }
    fn ioCancel(ctx: *anyopaque, id: workflow.JobId) bool {
        const jobs = cast(ctx).jobs orelse return false;
        return jobs.cancel(id);
    }
};

test "events are delivered in order once the clock reaches them" {
    var backend = AgentBackend.init(std.testing.allocator, .{});
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    try backend.inject(.{ .time_ns = 10, .payload = .{ .key_down = .{ .key = .s } } });
    try backend.inject(.{ .time_ns = 10, .payload = .{ .key_up = .{ .key = .s } } });
    try backend.inject(.{ .time_ns = 30, .payload = .quit });
    var buf: [8]platform.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), p.pollEvents(&buf));
    backend.advance(10);
    try std.testing.expectEqual(@as(usize, 2), p.pollEvents(&buf));
    try std.testing.expectEqual(platform.Event.Kind.key_down, std.meta.activeTag(buf[0].payload));
    try std.testing.expectEqual(platform.Event.Kind.key_up, std.meta.activeTag(buf[1].payload));
    try std.testing.expectEqual(@as(usize, 0), p.pollEvents(&buf));
    backend.advance(25);
    try std.testing.expectEqual(@as(usize, 1), p.pollEvents(&buf));
    try std.testing.expectEqual(@as(u64, 35), p.nowNs());
}

test "present copies the frame and the game's buffer can be reused" {
    var backend = AgentBackend.init(std.testing.allocator, .{});
    defer backend.deinit();
    var p = backend.asPlatform();
    try std.testing.expectError(error.NotStarted, p.setResolution(4, 2));
    _ = try p.start();
    try p.setResolution(4, 2);
    var pixels: [32]u8 = @splat(7);
    try p.present(.{ .width = 4, .height = 2, .stride = 16, .pixels = &pixels });
    @memset(&pixels, 0);
    const captured = backend.captureFrame().?;
    try std.testing.expectEqual(@as(u8, 7), captured.pixels[0]);
    try std.testing.expectError(error.InvalidFrame, p.present(.{ .width = 3, .height = 2, .stride = 12, .pixels = &pixels }));
    // Padded rows are copied without their padding.
    var padded: [40]u8 = @splat(9);
    try p.present(.{ .width = 4, .height = 2, .stride = 20, .pixels = &padded });
    try std.testing.expectEqual(@as(usize, 32), backend.captureFrame().?.pixels.len);
}

test "audio queue is bounded and consumed by controlled time" {
    var backend = AgentBackend.init(std.testing.allocator, .{});
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    const fmt = try p.audioOpen(.{ .channels = 2, .sample_rate = 1000 });
    try std.testing.expectEqual(@as(u32, 1000), fmt.sample_rate);
    const samples: [2400]i16 = @splat(0); // 1200 frames offered, 1000 fit
    try std.testing.expectEqual(@as(usize, 1000), try p.audioQueue(&samples));
    try std.testing.expectEqual(@as(usize, 0), try p.audioQueue(&samples));
    backend.advance(250 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 250), p.audioStatus().played_frames);
    try std.testing.expectEqual(@as(u64, 750), p.audioStatus().queued_frames);
    backend.advance(std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 1000), p.audioStatus().played_frames);
    p.audioClose();
    try std.testing.expectError(error.DeviceFailure, p.audioQueue(&samples));
}

test "reset frees everything and isolates instances" {
    var a = AgentBackend.init(std.testing.allocator, .{});
    defer a.deinit();
    var b = AgentBackend.init(std.testing.allocator, .{});
    defer b.deinit();
    var pa = a.asPlatform();
    _ = try pa.start();
    try pa.setResolution(2, 2);
    try a.inject(.{ .time_ns = 0, .payload = .quit });
    a.advance(5);
    try std.testing.expectEqual(@as(u64, 0), b.clock_ns);
    try std.testing.expectEqual(@as(usize, 0), b.pending.items.len);
    a.reset();
    try std.testing.expectEqual(@as(u64, 0), a.clock_ns);
    try std.testing.expect(!a.started);
    try std.testing.expectEqual(@as(usize, 0), a.capture.items.len);
}
