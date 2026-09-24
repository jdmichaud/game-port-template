//! `SdlBackend`: the Linux/SDL platform (DESIGN.md). It presents through a window,
//! a renderer and one streaming RGBA32 texture. It translates SDL's event queue into the
//! project's events, with monotonic nanosecond time stamps. The performance counter is the
//! clock. SDL's queued-audio API implements the bounded PCM queue contract. An event reports the
//! relative mouse capture. This file has no palette logic and no game knowledge.
//!
//! `SDL_InitSubSystem` starts each subsystem, and each one is released separately, so several
//! backends (or the tests) can exist in one process. `deinit` is valid after a successful or a
//! failed `start`.
const std = @import("std");
const builtin = @import("builtin");
const gameport = @import("gameport");
const platform = gameport.platform;
const workflow = gameport.workflow;
const c = @import("sdl.zig");
const eventlog = @import("eventlog.zig");

pub const SdlBackend = struct {
    /// The runner of the game's I/O workflows: the host's executor. Without one, a submission
    /// is refused.
    jobs: ?workflow.Jobs = null,
    /// The network calls go to this transport, when the host has one.
    net: platform.NetForward = .{},
    allocator: std.mem.Allocator,
    /// The host options, with `title` pointing to the backend's own NUL-terminated copy.
    options: platform.HostOptions,
    title: [:0]u8,

    // Host settings outside the shared options. The host sets them between `init` and `start`.
    /// Use SDL's software renderer, not an accelerated one (useful under Xvfb).
    force_software_renderer: bool = false,
    /// The audio queue capacity in sample frames. 0 means one second at the negotiated rate.
    audio_capacity_frames: u64 = 0,
    /// When set, the backend writes each delivered event to it as one JSON line (`eventlog.zig`).
    event_log: ?*std.Io.Writer = null,
    /// Test hook: the next texture creation fails as an SDL failure does.
    fail_next_texture: bool = false,

    started: bool = false,
    /// The subsystem flags that this backend initialised. `deinit` releases them.
    subsystems: u32 = 0,
    capabilities: platform.Capabilities = .{},
    counter_base: u64 = 0,
    counter_freq: u64 = 1,
    /// `SDL_GetTicks64` at `start`: the origin for the conversion of SDL event time stamps.
    ticks_base_ms: u64 = 0,
    last_event_ns: u64 = 0,

    window: ?*c.Window = null,
    keyboard_focused: bool = false,
    renderer: ?*c.Renderer = null,
    texture: ?*c.Texture = null,
    resolution: ?platform.Size = null,
    /// The window size that the backend last requested. A different actual size means that the
    /// user resized the window; a later mode change then keeps the user's size.
    window_size: platform.Size = .{ .width = 0, .height = 0 },
    /// Whether the renderer really presents in step with the display.
    vsync: bool = false,
    software: bool = false,
    frames_presented: u64 = 0,

    /// Events that the backend made itself (capture changes) or that did not fit in the
    /// destination of a poll. They come before new SDL events, so the order stays correct.
    pending: std.ArrayList(platform.Event) = .empty,
    pending_next: usize = 0,
    /// Whether the game has the pointer. The game reads the mouse as a DOS driver reports it:
    /// relative counts, with no desktop pointer. On a desktop the pointer must thus be captured,
    /// else it leaves the window during a stroke and the window edge stops it. Escape is a game
    /// key, so Ctrl+F10 (the DOSBox chord) releases the pointer. Focus loss also releases it,
    /// and a click captures it again.
    captured: bool = false,
    /// Whether the game requested the pointer. If not, the desktop keeps the pointer, and a
    /// click in the window is a normal click, not a capture.
    relative_wanted: bool = false,
    /// The button release of the click that captured the pointer belongs to the host, not to
    /// the game.
    swallow_button_up: bool = false,
    /// Optional device calibration, independent of the video size and the window size.
    mouse_scale_num: i64 = 1,
    mouse_scale_den: i64 = 1,
    scale_text: [32]u8 = @splat(0),
    scale_text_len: usize = 0,
    /// The remainder of the division from device counts to mickeys, one per axis, in device
    /// counts times the scale numerator (see `pageMotion`).
    motion_residue_x: i64 = 0,
    motion_residue_y: i64 = 0,
    renderer_name_buf: [32]u8 = @splat(0),
    renderer_name_len: usize = 0,
    controllers: std.ArrayList(*c.GameController) = .empty,

    audio: Audio = .{},

    pub const Audio = struct {
        device: c.AudioDeviceID = 0,
        format: platform.AudioFormat = .{},
        bytes_per_frame: u32 = 0,
        capacity_frames: u64 = 0,
        /// All frames that `audio_queue` accepted. `played` is computed from this count and
        /// SDL's queue size.
        accepted_frames: u64 = 0,
        /// The frames that `audio_clear` discarded. They are never reported as played.
        discarded_frames: u64 = 0,
    };

    /// The largest render resolution that the backend accepts, in each dimension.
    pub const max_dimension: u32 = 16384;
    /// The largest window scale. It keeps `resolution * scale` inside a `u32`.
    pub const max_window_scale: u32 = 64;
    /// The maximum number of project events for one SDL event. Only text input splits. SDL
    /// delivers at most 31 bytes, and each chunk except the last holds at least five bytes (a
    /// chunk ends only when a code point of up to four bytes does not fit). Thus seven chunks is
    /// the bound.
    pub const max_events_per_sdl_event = 8;

    pub fn init(allocator: std.mem.Allocator, options: platform.HostOptions) !SdlBackend {
        const title = try allocator.dupeSentinel(u8, options.title, 0);
        return .{
            .allocator = allocator,
            .options = .{
                .title = title,
                .initial_window_scale = options.initial_window_scale,
                .prefer_vsync = options.prefer_vsync,
            },
            .title = title,
        };
    }

    /// Stops the running devices, releases every SDL object and subsystem that this backend
    /// acquired, then frees the Zig-owned state. Valid after a failed `start` or without one.
    pub fn deinit(self: *SdlBackend) void {
        self.closeAudio();
        for (self.controllers.items) |handle| c.SDL_GameControllerClose(handle);
        self.controllers.deinit(self.allocator);
        self.destroyPresentation();
        if (self.subsystems != 0) c.SDL_QuitSubSystem(self.subsystems);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.title);
        self.* = undefined;
    }

    pub fn asPlatform(self: *SdlBackend) platform.Platform {
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

    fn cast(ctx: *anyopaque) *SdlBackend {
        return @ptrCast(@alignCast(ctx));
    }

    // --- lifecycle ---------------------------------------------------------------------------

    fn initSubsystem(self: *SdlBackend, flags: u32) bool {
        if (c.SDL_InitSubSystem(flags) != 0) {
            std.log.warn("SDL subsystem 0x{x} unavailable: {s}", .{ flags, c.SDL_GetError() });
            return false;
        }
        self.subsystems |= flags;
        return true;
    }

    /// Timer, events and video are required. If the audio or controller subsystem fails, the
    /// capability is reported as absent. A failed attempt releases the subsystems that it
    /// acquired, so a later `start` begins from the state after `init`.
    fn start(ctx: *anyopaque) platform.PlatformError!platform.Capabilities {
        const self = cast(ctx);
        if (self.started) return self.capabilities;
        _ = c.SDL_SetHint(c.HINT_RENDER_SCALE_QUALITY, "0");
        // Windows stretches the window of a program that does not declare that it knows the
        // display's DPI: on a display scaled to 150%, every pixel of the frame is 1.5 pixels
        // wide. SDL declares it when video starts, and then sizes the window in the display's
        // own pixels, which the window scale divides exactly.
        if (builtin.os.tag == .windows) _ = c.SDL_SetHint(c.HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
        const held = self.subsystems;
        errdefer {
            const acquired = self.subsystems & ~held;
            if (acquired != 0) c.SDL_QuitSubSystem(acquired);
            self.subsystems = held;
        }
        if (!self.initSubsystem(c.INIT_TIMER | c.INIT_EVENTS)) return error.DeviceFailure;
        if (!self.initSubsystem(c.INIT_VIDEO)) return error.DeviceFailure;
        const audio = self.initSubsystem(c.INIT_AUDIO);
        const controllers = self.initSubsystem(c.INIT_GAMECONTROLLER);
        self.counter_freq = @max(c.SDL_GetPerformanceFrequency(), 1);
        self.counter_base = c.SDL_GetPerformanceCounter();
        self.ticks_base_ms = c.SDL_GetTicks64();
        self.last_event_ns = 0;
        c.SDL_StartTextInput();
        self.started = true;
        self.capabilities = .{ .video = true, .audio = audio, .controllers = controllers, .network = false };
        return self.capabilities;
    }

    // --- time --------------------------------------------------------------------------------

    /// Converts counter ticks to nanoseconds, with no overflow for frequencies up to 1 GHz.
    pub fn counterToNs(delta: u64, freq: u64) u64 {
        const whole = delta / freq;
        const rest = delta % freq;
        return whole * std.time.ns_per_s + rest * std.time.ns_per_s / freq;
    }

    fn nowNs(ctx: *anyopaque) u64 {
        const self = cast(ctx);
        return self.elapsedNs();
    }

    fn elapsedNs(self: *const SdlBackend) u64 {
        if (!self.started) return 0;
        const delta = c.SDL_GetPerformanceCounter() -| self.counter_base;
        return counterToNs(delta, self.counter_freq);
    }

    /// Converts an SDL event time stamp (milliseconds, 32-bit, `SDL_GetTicks` domain) into the
    /// `now_ns` domain. The result is never later than now and never earlier than the previous
    /// event, so the delivery order and the time stamps agree.
    fn eventTimeNs(self: *SdlBackend, timestamp_ms: u32) u64 {
        const now = self.elapsedNs();
        const now_ms = c.SDL_GetTicks64();
        const age_ms: u32 = @as(u32, @truncate(now_ms)) -% timestamp_ms;
        const event_ms = now_ms -| age_ms;
        var t = (event_ms -| self.ticks_base_ms) * std.time.ns_per_ms;
        if (t > now) t = now;
        return self.orderedTime(t);
    }

    fn orderedTime(self: *SdlBackend, t: u64) u64 {
        const ordered = @max(t, self.last_event_ns);
        self.last_event_ns = ordered;
        return ordered;
    }

    // --- presentation ------------------------------------------------------------------------

    /// The window size for a mode: the resolution times the scale preference. The scale is
    /// reduced until the window fits the usable display bounds, but never below 1.
    pub fn fitWindowSize(width: u32, height: u32, scale: u32, bounds: ?platform.Size) platform.Size {
        var s: u32 = std.math.clamp(scale, 1, max_window_scale);
        if (bounds) |b| {
            while (s > 1 and (width * s > b.width or height * s > b.height)) s -= 1;
        }
        return .{ .width = width * s, .height = height * s };
    }

    /// The largest rectangle with the aspect ratio of the frame that fits the output, centred.
    pub fn fitRect(out_w: i32, out_h: i32, width: u32, height: u32) c.Rect {
        if (out_w <= 0 or out_h <= 0 or width == 0 or height == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const ow: i64 = out_w;
        const oh: i64 = out_h;
        const w: i64 = width;
        const h: i64 = height;
        var dw: i64 = ow;
        var dh: i64 = oh;
        if (ow * h <= oh * w) {
            dh = @max(@divTrunc(ow * h, w), 1);
        } else {
            dw = @max(@divTrunc(oh * w, h), 1);
        }
        return .{
            .x = @intCast(@divTrunc(ow - dw, 2)),
            .y = @intCast(@divTrunc(oh - dh, 2)),
            .w = @intCast(dw),
            .h = @intCast(dh),
        };
    }

    /// The rectangle of the page in the window, where `present` blits the frame.
    fn presentRect(self: *SdlBackend) ?struct { rect: c.Rect, page: platform.Size } {
        const res = self.resolution orelse return null;
        const out = self.outputSize() orelse return null;
        const rect = fitRect(
            @intCast(@min(out.width, std.math.maxInt(i32))),
            @intCast(@min(out.height, std.math.maxInt(i32))),
            res.width,
            res.height,
        );
        if (rect.w <= 0 or rect.h <= 0) return null;
        return .{ .rect = rect, .page = res };
    }

    /// One pointer motion, converted from device counts to mickeys by the `--mouse-scale`
    /// fraction. The game reads the result as the counts of a DOS mouse driver.
    ///
    /// The window scale does not apply: a relative delta is not a window measurement. Each axis
    /// keeps its remainder, so a slow drag does not round to zero.
    fn pageMotion(self: *SdlBackend, dx: i32, dy: i32) struct { dx: i32, dy: i32 } {
        if (self.mouse_scale_den == 0) return .{ .dx = dx, .dy = dy };
        self.motion_residue_x += @as(i64, dx) * self.mouse_scale_num;
        self.motion_residue_y += @as(i64, dy) * self.mouse_scale_num;
        const step_x = @divTrunc(self.motion_residue_x, self.mouse_scale_den);
        const step_y = @divTrunc(self.motion_residue_y, self.mouse_scale_den);
        self.motion_residue_x -= step_x * self.mouse_scale_den;
        self.motion_residue_y -= step_y * self.mouse_scale_den;
        return .{ .dx = @intCast(step_x), .dy = @intCast(step_y) };
    }

    /// One pointer position in page pixels: the window point minus the offset of the blit,
    /// scaled. Outside the blit, the position is clamped to the page, where the pointer is drawn.
    fn pagePoint(self: *SdlBackend, x: i32, y: i32) struct { x: i32, y: i32 } {
        const found = self.presentRect() orelse return .{ .x = x, .y = y };
        const page_x = @divTrunc(@as(i64, x - found.rect.x) * @as(i64, found.page.width), found.rect.w);
        const page_y = @divTrunc(@as(i64, y - found.rect.y) * @as(i64, found.page.height), found.rect.h);
        return .{
            .x = @intCast(std.math.clamp(page_x, 0, @as(i64, found.page.width) - 1)),
            .y = @intCast(std.math.clamp(page_y, 0, @as(i64, found.page.height) - 1)),
        };
    }

    fn setResolution(ctx: *anyopaque, width: u32, height: u32) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidResolution;
        // An unchanged resolution is not a mode change. The film player sets its size on every
        // frame. A new texture and a window resize on each frame stall the update loop, and the
        // sound queue then runs empty.
        if (self.window != null) if (self.resolution) |current| {
            if (current.width == width and current.height == height) return;
        };
        if (self.window == null) {
            try self.createPresentation(width, height);
        } else {
            // Make the new texture before the change. The old texture stays until the new one
            // exists.
            const renderer = self.renderer orelse return error.DeviceFailure;
            const fresh = self.createTexture(renderer, width, height) orelse return error.DeviceFailure;
            if (self.texture) |old| c.SDL_DestroyTexture(old);
            self.texture = fresh;
            self.refitWindow(width, height);
        }
        self.resolution = .{ .width = width, .height = height };
    }

    /// The usable area of the display that shows the window, if SDL can report it.
    fn displayBounds(self: *const SdlBackend) ?platform.Size {
        const index = if (self.window) |w| @max(c.SDL_GetWindowDisplayIndex(w), 0) else 0;
        var rect: c.Rect = undefined;
        if (c.SDL_GetDisplayUsableBounds(index, &rect) != 0 or rect.w <= 0 or rect.h <= 0) return null;
        return .{ .width = @intCast(rect.w), .height = @intCast(rect.h) };
    }

    /// Sets the window size for the new resolution after a mode change. A window that the user
    /// resized keeps its size: the frame is then letterboxed into it, as the design requires for
    /// window state and render resolution.
    fn refitWindow(self: *SdlBackend, width: u32, height: u32) void {
        const window = self.window orelse return;
        var w: c_int = 0;
        var h: c_int = 0;
        c.SDL_GetWindowSize(window, &w, &h);
        if (w < 0 or h < 0) return;
        if (@as(u32, @intCast(w)) != self.window_size.width or @as(u32, @intCast(h)) != self.window_size.height) return;
        const size = fitWindowSize(width, height, self.options.initial_window_scale, self.displayBounds());
        c.SDL_SetWindowSize(window, @intCast(size.width), @intCast(size.height));
        self.window_size = size;
    }

    fn createPresentation(self: *SdlBackend, width: u32, height: u32) platform.PlatformError!void {
        const size = fitWindowSize(width, height, self.options.initial_window_scale, self.displayBounds());
        const flags = c.WINDOW_SHOWN | c.WINDOW_RESIZABLE | c.WINDOW_ALLOW_HIGHDPI;
        const window = c.SDL_CreateWindow(self.title.ptr, c.WINDOWPOS_CENTERED, c.WINDOWPOS_CENTERED, @intCast(size.width), @intCast(size.height), flags) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
            return error.DeviceFailure;
        };
        errdefer c.SDL_DestroyWindow(window);
        const created = self.createRenderer(window) orelse {
            std.log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
            return error.DeviceFailure;
        };
        errdefer c.SDL_DestroyRenderer(created.renderer);
        self.recordRendererInfo(created);
        const texture = self.createTexture(created.renderer, width, height) orelse return error.DeviceFailure;
        self.window = window;
        self.renderer = created.renderer;
        self.texture = texture;
        self.window_size = size;
    }

    const CreatedRenderer = struct { renderer: *c.Renderer, asked_vsync: bool };

    fn createRenderer(self: *const SdlBackend, window: *c.Window) ?CreatedRenderer {
        if (self.force_software_renderer) {
            const r = c.SDL_CreateRenderer(window, -1, c.RENDERER_SOFTWARE) orelse return null;
            return .{ .renderer = r, .asked_vsync = false };
        }
        if (self.options.prefer_vsync) {
            if (c.SDL_CreateRenderer(window, -1, c.RENDERER_ACCELERATED | c.RENDERER_PRESENTVSYNC)) |r| {
                return .{ .renderer = r, .asked_vsync = true };
            }
        }
        if (c.SDL_CreateRenderer(window, -1, c.RENDERER_ACCELERATED)) |r| return .{ .renderer = r, .asked_vsync = false };
        const r = c.SDL_CreateRenderer(window, -1, c.RENDERER_SOFTWARE) orelse return null;
        return .{ .renderer = r, .asked_vsync = false };
    }

    /// SDL's software driver sets `PRESENTVSYNC` in its renderer info, also when the flag was not
    /// requested, and its `SDL_RenderPresent` does not wait for the display. Thus the flag alone
    /// does not prove display pacing. Only an accelerated renderer that this backend created with
    /// the flag counts as paced.
    fn recordRendererInfo(self: *SdlBackend, created: CreatedRenderer) void {
        var info: c.RendererInfo = undefined;
        if (c.SDL_GetRendererInfo(created.renderer, &info) != 0) return;
        self.software = info.flags & c.RENDERER_SOFTWARE != 0;
        self.vsync = created.asked_vsync and !self.software and info.flags & c.RENDERER_PRESENTVSYNC != 0;
        // The SDL driver in use, for the host's start-up line: "opengl", "software",
        // "opengles2" and others. A window that never paints is almost always a driver problem,
        // and only this code knows the driver.
        const text = std.mem.sliceTo(info.name, 0);
        const n = @min(text.len, self.renderer_name_buf.len);
        @memcpy(self.renderer_name_buf[0..n], text[0..n]);
        self.renderer_name_len = n;
    }

    /// The name of the driver, as `SDL_GetRendererInfo` reports it.
    pub fn rendererName(self: *const SdlBackend) []const u8 {
        return self.renderer_name_buf[0..self.renderer_name_len];
    }

    fn createTexture(self: *SdlBackend, renderer: *c.Renderer, width: u32, height: u32) ?*c.Texture {
        if (self.fail_next_texture) {
            self.fail_next_texture = false;
            return null;
        }
        return c.SDL_CreateTexture(renderer, c.PIXELFORMAT_RGBA32, c.TEXTUREACCESS_STREAMING, @intCast(width), @intCast(height)) orelse {
            std.log.err("SDL_CreateTexture({d}x{d}) failed: {s}", .{ width, height, c.SDL_GetError() });
            return null;
        };
    }

    fn destroyPresentation(self: *SdlBackend) void {
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        if (self.renderer) |r| c.SDL_DestroyRenderer(r);
        if (self.window) |w| c.SDL_DestroyWindow(w);
        self.texture = null;
        self.renderer = null;
        self.window = null;
        self.resolution = null;
        self.window_size = .{ .width = 0, .height = 0 };
    }

    /// The output size of the renderer in pixels, or null before the window exists.
    pub fn outputSize(self: *const SdlBackend) ?platform.Size {
        const renderer = self.renderer orelse return null;
        var w: c_int = 0;
        var h: c_int = 0;
        if (c.SDL_GetRendererOutputSize(renderer, &w, &h) != 0 or w < 0 or h < 0) return null;
        return .{ .width = @intCast(w), .height = @intCast(h) };
    }

    fn present(ctx: *anyopaque, frame: platform.RgbaFrame) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        frame.validate() catch return error.InvalidFrame;
        const res = self.resolution orelse return error.InvalidResolution;
        if (frame.width != res.width or frame.height != res.height) return error.InvalidFrame;
        const pitch = std.math.cast(c_int, frame.stride) orelse return error.InvalidFrame;
        const renderer = self.renderer orelse return error.InvalidResolution;
        const texture = self.texture orelse return error.InvalidResolution;
        // SDL copies the rows into the texture. The backend keeps no reference to the buffer.
        if (c.SDL_UpdateTexture(texture, null, frame.pixels.ptr, pitch) != 0) return error.DeviceFailure;
        const out = self.outputSize() orelse platform.Size{ .width = res.width, .height = res.height };
        const dst = fitRect(@intCast(@min(out.width, std.math.maxInt(i32))), @intCast(@min(out.height, std.math.maxInt(i32))), res.width, res.height);
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(renderer);
        if (c.SDL_RenderCopy(renderer, texture, null, &dst) != 0) return error.DeviceFailure;
        c.SDL_RenderPresent(renderer);
        self.frames_presented += 1;
    }

    // --- events ------------------------------------------------------------------------------

    fn pollEvents(ctx: *anyopaque, dst: []platform.Event) usize {
        const self = cast(ctx);
        const n = self.net.poll(dst, self.poll(dst));
        if (self.event_log) |w| {
            // A full log is only a diagnostic. It never causes the loss of an event for the game.
            for (dst[0..n]) |ev| eventlog.writeEvent(ev, w) catch {};
        }
        return n;
    }

    fn poll(self: *SdlBackend, dst: []platform.Event) usize {
        var n: usize = 0;
        while (n < dst.len and self.pending_next < self.pending.items.len) : (self.pending_next += 1) {
            dst[n] = self.pending.items[self.pending_next];
            n += 1;
        }
        if (self.pending_next == self.pending.items.len and self.pending_next != 0) {
            self.pending.clearRetainingCapacity();
            self.pending_next = 0;
        }
        if (!self.started) return n;
        var ev: c.Event = undefined;
        while (n < dst.len and c.SDL_PollEvent(&ev) != 0) {
            var out: [max_events_per_sdl_event]platform.Event = undefined;
            const count = self.translate(&ev, &out);
            for (out[0..count]) |e| {
                if (n < dst.len) {
                    dst[n] = e;
                    n += 1;
                } else {
                    // Only a multi-event translation can overflow. Keep the rest in order.
                    self.pending.append(self.allocator, e) catch {};
                }
            }
        }
        return n;
    }

    /// Translates one SDL event into zero or more project events. A text input can split into
    /// several events. `out` needs room for `max_events_per_sdl_event` events.
    fn translate(self: *SdlBackend, ev: *const c.Event, out: []platform.Event) usize {
        const payload: platform.Event.Payload = switch (ev.type) {
            c.QUIT => .quit,
            c.WINDOWEVENT => switch (ev.window.event) {
                c.WINDOWEVENT_FOCUS_GAINED => blk2: {
                    self.keyboard_focused = true;
                    break :blk2 .focus_gained;
                },
                c.WINDOWEVENT_FOCUS_LOST => blk2: {
                    const was_focused = self.keyboard_focused;
                    self.keyboard_focused = false;
                    // The pointer goes back to the desktop with the focus.
                    self.setCapture(false);
                    if (!was_focused) return 0;
                    break :blk2 .focus_lost;
                },
                c.WINDOWEVENT_SIZE_CHANGED => .{ .drawable_resized = self.outputSize() orelse .{
                    .width = @intCast(@max(ev.window.data1, 0)),
                    .height = @intCast(@max(ev.window.data2, 0)),
                } },
                else => return 0,
            },
            c.KEYDOWN, c.KEYUP => blk: {
                // SDL releases held keys before it queues WINDOWEVENT_FOCUS_LOST. Report the
                // loss first, so these synthetic releases cannot commit a drag or a stroke.
                // Injected events without a window are kept.
                if (ev.key.window_id != 0 and self.window != null and
                    (!self.keyboard_focused or c.SDL_GetKeyboardFocus() != self.window))
                {
                    if (!self.keyboard_focused) return 0;
                    self.keyboard_focused = false;
                    break :blk .focus_lost;
                }
                // Ctrl+F10 is the host's chord, and the game never sees it. It moves the pointer
                // between the desktop and the game.
                if (keyFromScancode(ev.key.keysym.scancode) == .f10 and (ev.key.keysym.mod & c.KMOD_CTRL) != 0) {
                    if (ev.type == c.KEYDOWN) self.setCapture(!self.captured);
                    return 0;
                }
                const key: platform.Event.KeyEvent = .{ .key = keyFromScancode(ev.key.keysym.scancode), .repeat = ev.key.repeat != 0 };
                break :blk if (ev.type == c.KEYDOWN) .{ .key_down = key } else .{ .key_up = key };
            },
            c.TEXTINPUT => {
                const t = self.eventTimeNs(ev.common.timestamp);
                return splitText(std.mem.sliceTo(&ev.text.text, 0), t, out);
            },
            c.MOUSEMOTION => blk: {
                if (self.relative_wanted and !self.captured) return 0;
                const motion = self.pageMotion(ev.motion.xrel, ev.motion.yrel);
                const at = self.pagePoint(ev.motion.x, ev.motion.y);
                break :blk .{ .mouse_motion = .{ .dx = motion.dx, .dy = motion.dy, .x = at.x, .y = at.y } };
            },
            c.MOUSEBUTTONDOWN, c.MOUSEBUTTONUP => blk: {
                // A click while the desktop has the pointer captures the pointer. The game does
                // not get this click.
                if (self.swallow_button_up and ev.type == c.MOUSEBUTTONUP) {
                    self.swallow_button_up = false;
                    return 0;
                }
                if (!self.captured and self.relative_wanted and ev.type == c.MOUSEBUTTONDOWN) {
                    self.setCapture(true);
                    self.swallow_button_up = true;
                    return 0;
                }
                const at = self.pagePoint(ev.button.x, ev.button.y);
                const button: platform.Event.MouseButtonEvent = .{ .button = mouseButton(ev.button.button), .x = at.x, .y = at.y };
                break :blk if (ev.type == c.MOUSEBUTTONDOWN) .{ .mouse_button_down = button } else .{ .mouse_button_up = button };
            },
            c.MOUSEWHEEL => blk: {
                const sign: i32 = if (ev.wheel.direction == c.MOUSEWHEEL_FLIPPED) -1 else 1;
                break :blk .{ .mouse_wheel = .{ .dx = ev.wheel.x * sign, .dy = ev.wheel.y * sign } };
            },
            c.CONTROLLERDEVICEADDED => blk: {
                const id = self.openController(ev.cdevice.which) orelse return 0;
                break :blk .{ .controller_added = id };
            },
            c.CONTROLLERDEVICEREMOVED => blk: {
                self.closeController(ev.cdevice.which);
                break :blk .{ .controller_removed = controllerId(ev.cdevice.which) };
            },
            c.CONTROLLERBUTTONDOWN, c.CONTROLLERBUTTONUP => blk: {
                const button: platform.Event.ControllerButtonEvent = .{ .controller = controllerId(ev.cbutton.which), .button = @fromBackingInt(ev.cbutton.button) };
                break :blk if (ev.type == c.CONTROLLERBUTTONDOWN) .{ .controller_button_down = button } else .{ .controller_button_up = button };
            },
            c.CONTROLLERAXISMOTION => .{ .controller_axis = .{ .controller = controllerId(ev.caxis.which), .axis = @fromBackingInt(ev.caxis.axis), .value = ev.caxis.value } },
            else => return 0,
        };
        out[0] = .{ .time_ns = self.eventTimeNs(ev.common.timestamp), .payload = payload };
        return 1;
    }

    /// Packs UTF-8 `text` into `TextInput` events of at most 8 bytes. It splits only between code
    /// points. Returns the number of events written to `out`.
    pub fn splitText(text: []const u8, time_ns: u64, out: []platform.Event) usize {
        var i: usize = 0;
        var count: usize = 0;
        while (i < text.len and count < out.len) {
            var chunk: platform.Event.TextInput = .{};
            while (i < text.len) {
                const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const len = @min(@as(usize, seq), text.len - i);
                if (chunk.len + len > chunk.bytes.len) break;
                @memcpy(chunk.bytes[chunk.len..][0..len], text[i..][0..len]);
                chunk.len += @intCast(len);
                i += len;
            }
            out[count] = .{ .time_ns = time_ns, .payload = .{ .text_input = chunk } };
            count += 1;
        }
        return count;
    }

    fn controllerId(instance: c.JoystickID) platform.ControllerId {
        return @fromBackingInt(@as(u32, @bitCast(instance)));
    }

    /// Opens the controller at a device index and returns its instance id.
    fn openController(self: *SdlBackend, device_index: i32) ?platform.ControllerId {
        const handle = c.SDL_GameControllerOpen(device_index) orelse return null;
        const joystick = c.SDL_GameControllerGetJoystick(handle) orelse {
            c.SDL_GameControllerClose(handle);
            return null;
        };
        const instance = c.SDL_JoystickInstanceID(joystick);
        self.controllers.append(self.allocator, handle) catch {
            c.SDL_GameControllerClose(handle);
            return null;
        };
        return controllerId(instance);
    }

    fn closeController(self: *SdlBackend, instance: c.JoystickID) void {
        const handle = c.SDL_GameControllerFromInstanceID(instance) orelse return;
        for (self.controllers.items, 0..) |h, i| {
            if (h == handle) {
                _ = self.controllers.swapRemove(i);
                c.SDL_GameControllerClose(handle);
                return;
            }
        }
    }

    // --- audio -------------------------------------------------------------------------------

    fn audioOpen(ctx: *anyopaque, requested: platform.AudioFormat) platform.PlatformError!platform.AudioFormat {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        if (!self.capabilities.audio) return error.Unsupported;
        if (requested.channels == 0 or requested.sample_rate == 0 or requested.sample_rate > std.math.maxInt(c_int)) return error.Unsupported;
        self.closeAudio();
        const desired: c.AudioSpec = .{
            .freq = @intCast(requested.sample_rate),
            .format = c.AUDIO_S16,
            .channels = requested.channels,
            .silence = 0,
            .samples = 1024,
            .padding = 0,
            .size = 0,
            .callback = null,
            .userdata = null,
        };
        var obtained: c.AudioSpec = undefined;
        const device = c.SDL_OpenAudioDevice(null, 0, &desired, &obtained, c.AUDIO_ALLOW_FREQUENCY_CHANGE | c.AUDIO_ALLOW_CHANNELS_CHANGE);
        if (device == 0) {
            std.log.err("SDL_OpenAudioDevice failed: {s}", .{c.SDL_GetError()});
            return error.DeviceFailure;
        }
        if (obtained.format != c.AUDIO_S16 or obtained.channels == 0 or obtained.freq <= 0) {
            c.SDL_CloseAudioDevice(device);
            return error.Unsupported;
        }
        const format: platform.AudioFormat = .{ .channels = obtained.channels, .sample_rate = @intCast(obtained.freq) };
        self.audio = .{
            .device = device,
            .format = format,
            .bytes_per_frame = @as(u32, obtained.channels) * @sizeOf(i16),
            .capacity_frames = if (self.audio_capacity_frames != 0) self.audio_capacity_frames else format.sample_rate,
        };
        c.SDL_PauseAudioDevice(device, 0);
        return format;
    }

    fn queuedFrames(self: *const SdlBackend) u64 {
        if (self.audio.device == 0) return 0;
        return c.SDL_GetQueuedAudioSize(self.audio.device) / self.audio.bytes_per_frame;
    }

    fn audioQueue(ctx: *anyopaque, samples: []const i16) platform.PlatformError!usize {
        const self = cast(ctx);
        if (self.audio.device == 0) return error.DeviceFailure;
        const channels: usize = self.audio.format.channels;
        const offered = samples.len / channels;
        const room = self.audio.capacity_frames -| self.queuedFrames();
        const accepted: usize = @intCast(@min(offered, room));
        if (accepted == 0) return 0;
        const bytes: u32 = @intCast(accepted * self.audio.bytes_per_frame);
        if (c.SDL_QueueAudio(self.audio.device, samples.ptr, bytes) != 0) return error.DeviceFailure;
        self.audio.accepted_frames += accepted;
        return accepted;
    }

    /// `played` counts the frames that SDL took from its queue for the device. Discarded frames
    /// are not counted.
    fn audioStatus(ctx: *anyopaque) platform.AudioStatus {
        const self = cast(ctx);
        if (self.audio.device == 0) return .{};
        const queued = self.queuedFrames();
        const status = c.SDL_GetAudioDeviceStatus(self.audio.device);
        return .{
            .queued_frames = queued,
            .played_frames = self.audio.accepted_frames -| self.audio.discarded_frames -| queued,
            .running = status == c.AUDIO_PLAYING,
            .suspended = status != c.AUDIO_PLAYING,
        };
    }

    fn audioClear(ctx: *anyopaque) void {
        const self = cast(ctx);
        if (self.audio.device == 0) return;
        c.SDL_LockAudioDevice(self.audio.device);
        self.audio.discarded_frames += self.queuedFrames();
        c.SDL_ClearQueuedAudio(self.audio.device);
        c.SDL_UnlockAudioDevice(self.audio.device);
    }

    fn audioClose(ctx: *anyopaque) void {
        cast(ctx).closeAudio();
    }

    fn closeAudio(self: *SdlBackend) void {
        if (self.audio.device != 0) c.SDL_CloseAudioDevice(self.audio.device);
        self.audio = .{};
    }

    // --- capture and network -----------------------------------------------------------------

    /// Requests relative mode. A `capture_changed` event reports the state that SDL really
    /// reached, also when the request failed.
    fn setRelativeMouse(ctx: *anyopaque, enabled: bool) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        self.relative_wanted = enabled;
        const rc = c.SDL_SetRelativeMouseMode(if (enabled) c.TRUE else c.FALSE);
        const actual = c.SDL_GetRelativeMouseMode() == c.TRUE;
        self.captured = actual;
        _ = c.SDL_ShowCursor(if (actual) c.CURSOR_DISABLE else c.CURSOR_ENABLE);
        const t = self.orderedTime(self.elapsedNs());
        self.pending.append(self.allocator, .{ .time_ns = t, .payload = .{ .capture_changed = actual } }) catch return error.OutOfMemory;
        if (rc != 0) return error.Unsupported;
    }

    /// The device-count scale, as a fraction. The host sets it from `--mouse-scale`.
    pub fn setMouseScale(self: *SdlBackend, num: i64, den: i64) void {
        if (num <= 0 or den <= 0) return;
        self.mouse_scale_num = num;
        self.mouse_scale_den = den;
        self.motion_residue_x = 0;
        self.motion_residue_y = 0;
    }

    /// The scale, for the line the host prints.
    pub fn mouseScaleText(self: *SdlBackend) []const u8 {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}/{d} of the device's counts", .{ self.mouse_scale_num, self.mouse_scale_den }) catch return "an unprintable scale";
        @memcpy(self.scale_text[0..text.len], text);
        self.scale_text_len = text.len;
        return self.scale_text[0..self.scale_text_len];
    }

    /// Changes the capture for the host's own chord, not for the game. It does the work of
    /// `setRelativeMouse` without the `NotStarted` contract, so an event handler can use it.
    fn setCapture(self: *SdlBackend, enabled: bool) void {
        if (!self.started or enabled == self.captured) return;
        _ = c.SDL_SetRelativeMouseMode(if (enabled) c.TRUE else c.FALSE);
        self.captured = c.SDL_GetRelativeMouseMode() == c.TRUE;
        _ = c.SDL_ShowCursor(if (self.captured) c.CURSOR_DISABLE else c.CURSOR_ENABLE);
        const t = self.orderedTime(self.elapsedNs());
        self.pending.append(self.allocator, .{ .time_ns = t, .payload = .{ .capture_changed = self.captured } }) catch {};
        self.motion_residue_x = 0;
        self.motion_residue_y = 0;
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

// --- key and button mapping ------------------------------------------------------------------

const ScancodeKey = struct { u16, platform.Key };

/// SDL scancode to project key. Every key of the `Key` enum has an entry (a test checks this).
/// The keypad Enter is also `enter`, and a scancode without an entry is `unknown`.
const scancode_keys = [_]ScancodeKey{
    .{ 41, .escape },      .{ 40, .enter },        .{ 88, .enter },        .{ 44, .space },
    .{ 43, .tab },         .{ 42, .backspace },    .{ 80, .left },         .{ 79, .right },
    .{ 82, .up },          .{ 81, .down },         .{ 74, .home },         .{ 77, .end },
    .{ 75, .page_up },     .{ 78, .page_down },    .{ 73, .insert },       .{ 76, .delete },
    .{ 225, .left_shift }, .{ 229, .right_shift }, .{ 224, .left_ctrl },   .{ 228, .right_ctrl },
    .{ 226, .left_alt },   .{ 230, .right_alt },   .{ 4, .a },             .{ 5, .b },
    .{ 6, .c },            .{ 7, .d },             .{ 8, .e },             .{ 9, .f },
    .{ 10, .g },           .{ 11, .h },            .{ 12, .i },            .{ 13, .j },
    .{ 14, .k },           .{ 15, .l },            .{ 16, .m },            .{ 17, .n },
    .{ 18, .o },           .{ 19, .p },            .{ 20, .q },            .{ 21, .r },
    .{ 22, .s },           .{ 23, .t },            .{ 24, .u },            .{ 25, .v },
    .{ 26, .w },           .{ 27, .x },            .{ 28, .y },            .{ 29, .z },
    .{ 39, .digit_0 },     .{ 30, .digit_1 },      .{ 31, .digit_2 },      .{ 32, .digit_3 },
    .{ 33, .digit_4 },     .{ 34, .digit_5 },      .{ 35, .digit_6 },      .{ 36, .digit_7 },
    .{ 37, .digit_8 },     .{ 38, .digit_9 },      .{ 58, .f1 },           .{ 59, .f2 },
    .{ 60, .f3 },          .{ 61, .f4 },           .{ 62, .f5 },           .{ 63, .f6 },
    .{ 64, .f7 },          .{ 65, .f8 },           .{ 66, .f9 },           .{ 67, .f10 },
    .{ 68, .f11 },         .{ 69, .f12 },          .{ 45, .minus },        .{ 46, .equals },
    .{ 54, .comma },       .{ 55, .period },       .{ 56, .slash },        .{ 51, .semicolon },
    .{ 52, .apostrophe },  .{ 53, .grave },        .{ 47, .left_bracket }, .{ 48, .right_bracket },
    .{ 49, .backslash },   .{ 87, .keypad_plus },  .{ 86, .keypad_minus },
    // The keypad's other keys are the keys that they double with Num Lock off: 0 is Insert, the
    // period Delete, and 8, 2, 4 and 6 the arrows. The digits that a text field takes arrive as
    // text input. Change this when the game reads the keypad differently.
    .{ 98, .insert },
    .{ 99, .delete },      .{ 96, .up },           .{ 90, .down },         .{ 92, .left },
    .{ 94, .right },       .{ 95, .home },         .{ 97, .page_up },      .{ 89, .end },
    .{ 91, .page_down },
};

const key_table: [512]platform.Key = blk: {
    var table: [512]platform.Key = @splat(.unknown);
    for (scancode_keys) |entry| table[entry[0]] = entry[1];
    break :blk table;
};

pub fn keyFromScancode(scancode: u32) platform.Key {
    return if (scancode < key_table.len) key_table[scancode] else .unknown;
}

/// SDL numbers buttons from 1. The project's enum starts at `left = 0`, in the same order.
pub fn mouseButton(sdl_button: u8) platform.MouseButton {
    return @fromBackingInt(sdl_button -| 1);
}

// --- tests -----------------------------------------------------------------------------------

/// Picks SDL's video driver whatever the environment says, on every platform: SDL reads the
/// driver from its hint, and a hint of override priority wins over the environment variable.
fn useVideoDriver(name: [*:0]const u8) void {
    _ = c.SDL_SetHintWithPriority(c.HINT_VIDEODRIVER, name, c.HINT_OVERRIDE);
}

/// The tests run without a display or a sound card.
fn useDummyDrivers() void {
    useVideoDriver("dummy");
    _ = c.SDL_SetHintWithPriority(c.HINT_AUDIODRIVER, "dummy", c.HINT_OVERRIDE);
}

fn startedBackend(scale: u32) !SdlBackend {
    useDummyDrivers();
    var backend = try SdlBackend.init(std.testing.allocator, .{ .title = "gameport test", .initial_window_scale = scale });
    backend.force_software_renderer = true;
    return backend;
}

/// Reads the whole output of the renderer as RGBA32 rows of `width * 4` bytes.
fn readBack(backend: *SdlBackend, dst: []u8, width: u32) !void {
    const renderer = backend.renderer orelse return error.NoRenderer;
    if (c.SDL_RenderReadPixels(renderer, null, c.PIXELFORMAT_RGBA32, dst.ptr, @intCast(width * 4)) != 0) return error.ReadBackFailed;
}

fn patternByte(x: u32, y: u32, channel: u32) u8 {
    return switch (channel) {
        0 => @truncate(x * 40 + 3),
        1 => @truncate(y * 70 + 5),
        2 => @truncate((x ^ y) * 90 + 7),
        else => 255,
    };
}

test "every named key has a scancode" {
    inline for (@typeInfo(platform.Key).@"enum".field_names) |name| {
        const key: platform.Key = @field(platform.Key, name);
        if (key == .unknown) continue;
        var found = false;
        for (scancode_keys) |entry| {
            if (entry[1] == key) found = true;
        }
        if (!found) {
            std.debug.print("key {s} has no scancode\n", .{name});
            return error.UnmappedKey;
        }
    }
    try std.testing.expectEqual(platform.Key.a, keyFromScancode(4));
    try std.testing.expectEqual(platform.Key.enter, keyFromScancode(88));
    try std.testing.expectEqual(platform.Key.unknown, keyFromScancode(57)); // caps lock
    try std.testing.expectEqual(platform.Key.unknown, keyFromScancode(100_000));
    try std.testing.expectEqual(platform.MouseButton.left, mouseButton(c.BUTTON_LEFT));
    try std.testing.expectEqual(platform.MouseButton.x2, mouseButton(c.BUTTON_X2));
}

test "fitting: window size and letterbox rectangle" {
    const fit = SdlBackend.fitWindowSize;
    try std.testing.expectEqual(platform.Size{ .width = 960, .height = 600 }, fit(320, 200, 3, .{ .width = 1024, .height = 768 }));
    try std.testing.expectEqual(platform.Size{ .width = 640, .height = 400 }, fit(320, 200, 3, .{ .width = 800, .height = 600 }));
    try std.testing.expectEqual(platform.Size{ .width = 320, .height = 200 }, fit(320, 200, 3, .{ .width = 100, .height = 100 }));
    try std.testing.expectEqual(platform.Size{ .width = 320, .height = 200 }, fit(320, 200, 0, null));
    try std.testing.expectEqual(platform.Size{ .width = 1280, .height = 800 }, fit(320, 200, 4, null));
    // A very large scale is clamped, so the multiplication does not overflow.
    const capped = fit(1024, 768, std.math.maxInt(u32), null);
    try std.testing.expectEqual(1024 * SdlBackend.max_window_scale, capped.width);

    const rect = SdlBackend.fitRect;
    try std.testing.expectEqual(c.Rect{ .x = 0, .y = 0, .w = 640, .h = 400 }, rect(640, 400, 320, 200));
    try std.testing.expectEqual(c.Rect{ .x = 0, .y = 100, .w = 640, .h = 400 }, rect(640, 600, 320, 200));
    try std.testing.expectEqual(c.Rect{ .x = 160, .y = 0, .w = 320, .h = 200 }, rect(640, 200, 320, 200));
    try std.testing.expectEqual(c.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, rect(0, 200, 320, 200));
    try std.testing.expectEqual(@as(u64, 1_500_000_000), SdlBackend.counterToNs(1500, 1000));
    try std.testing.expectEqual(@as(u64, 3_000_000_000), SdlBackend.counterToNs(3_000_000_000, 1_000_000_000));
}

test "text input splits between code points into 8-byte chunks" {
    var out: [SdlBackend.max_events_per_sdl_event]platform.Event = undefined;
    // "héllo wörld": 13 bytes; 'é' and 'ö' are two bytes each.
    const n = SdlBackend.splitText("héllo wörld", 7, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("héllo w", out[0].payload.text_input.slice());
    try std.testing.expectEqualStrings("örld", out[1].payload.text_input.slice());
    try std.testing.expectEqual(@as(u64, 7), out[1].time_ns);
    try std.testing.expectEqual(@as(usize, 0), SdlBackend.splitText("", 0, &out));

    // The worst case that SDL can deliver: 31 bytes that pack five to a chunk. The translation
    // buffer holds eight events for this case, so no event is lost.
    const worst = "a\u{10000}a\u{10000}a\u{10000}a\u{10000}a\u{10000}a\u{10000}a";
    try std.testing.expectEqual(@as(usize, 31), worst.len);
    const chunks = SdlBackend.splitText(worst, 0, &out);
    try std.testing.expect(chunks <= SdlBackend.max_events_per_sdl_event);
    var seen: usize = 0;
    for (out[0..chunks]) |e| seen += e.payload.text_input.len;
    try std.testing.expectEqual(worst.len, seen);
}

test "present honours channel order and stride and retains nothing" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    try std.testing.expectEqual(@as(u64, 0), p.nowNs());
    try std.testing.expectError(error.NotStarted, p.setResolution(8, 6));
    const caps = try p.start();
    try std.testing.expect(caps.video);
    try p.setResolution(8, 6);
    try std.testing.expect(backend.software);
    // The software renderer sets PRESENTVSYNC but does not wait for a display. The host must not
    // treat it as paced.
    try std.testing.expect(!backend.vsync);
    try std.testing.expectEqual(platform.Size{ .width = 8, .height = 6 }, backend.outputSize().?);

    // Rows of 8 pixels, padded to a 40-byte stride. The padding holds a marker that must not
    // reach the screen.
    const stride = 40;
    var pixels: [6 * stride]u8 = @splat(0xEE);
    var y: u32 = 0;
    while (y < 6) : (y += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            var ch: u32 = 0;
            while (ch < 4) : (ch += 1) pixels[y * stride + x * 4 + ch] = patternByte(x, y, ch);
        }
    }
    try p.present(.{ .width = 8, .height = 6, .stride = stride, .pixels = &pixels });
    @memset(&pixels, 0);
    var back: [8 * 6 * 4]u8 = undefined;
    try readBack(&backend, &back, 8);
    y = 0;
    while (y < 6) : (y += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            var ch: u32 = 0;
            while (ch < 4) : (ch += 1) {
                try std.testing.expectEqual(patternByte(x, y, ch), back[(y * 8 + x) * 4 + ch]);
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 1), backend.frames_presented);
    try std.testing.expectError(error.InvalidFrame, p.present(.{ .width = 8, .height = 6, .stride = 31, .pixels = &pixels }));
    try std.testing.expectError(error.InvalidFrame, p.present(.{ .width = 4, .height = 6, .stride = 16, .pixels = &pixels }));
    try std.testing.expect(p.nowNs() > 0);
}

test "a failed mode change leaves the previous mode usable" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    try std.testing.expectError(error.InvalidResolution, p.setResolution(0, 6));
    try p.setResolution(8, 6);
    var small: [8 * 6 * 4]u8 = @splat(0x80);
    try p.present(.{ .width = 8, .height = 6, .stride = 32, .pixels = &small });

    backend.fail_next_texture = true;
    try std.testing.expectError(error.DeviceFailure, p.setResolution(16, 12));
    try std.testing.expectEqual(platform.Size{ .width = 8, .height = 6 }, backend.resolution.?);
    try p.present(.{ .width = 8, .height = 6, .stride = 32, .pixels = &small });
    try std.testing.expectError(error.InvalidResolution, p.setResolution(SdlBackend.max_dimension + 1, 12));

    try p.setResolution(16, 12);
    var large: [16 * 12 * 4]u8 = @splat(0x40);
    try p.present(.{ .width = 16, .height = 12, .stride = 64, .pixels = &large });
    try std.testing.expectError(error.InvalidFrame, p.present(.{ .width = 8, .height = 6, .stride = 32, .pixels = &small }));
    // The user did not resize the window, so it follows the new mode at the same scale.
    try std.testing.expectEqual(platform.Size{ .width = 16, .height = 12 }, backend.outputSize().?);
    var back: [16 * 12 * 4]u8 = undefined;
    try readBack(&backend, &back, 16);
    try std.testing.expectEqual(@as(u8, 0x40), back[0]);
    try std.testing.expectEqual(@as(u64, 3), backend.frames_presented);
}

test "a window the user resized keeps its size and letterboxes the frame" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    try p.setResolution(16, 12);
    // A window manager or the user resizes the window without the backend.
    c.SDL_SetWindowSize(backend.window.?, 40, 40);
    try std.testing.expectEqual(platform.Size{ .width = 40, .height = 40 }, backend.outputSize().?);

    try p.setResolution(8, 6);
    try std.testing.expectEqual(platform.Size{ .width = 40, .height = 40 }, backend.outputSize().?);
    var frame: [8 * 6 * 4]u8 = @splat(0x7F);
    try p.present(.{ .width = 8, .height = 6, .stride = 32, .pixels = &frame });

    // 8x6 in a 40x40 output is 40x30 centred vertically: five black rows, then the frame.
    var back: [40 * 40 * 4]u8 = undefined;
    try readBack(&backend, &back, 40);
    try std.testing.expectEqual(@as(u8, 0), back[0]);
    try std.testing.expectEqual(@as(u8, 0), back[4 * 40 * 4]);
    try std.testing.expectEqual(@as(u8, 0x7F), back[5 * 40 * 4]);
    try std.testing.expectEqual(@as(u8, 0x7F), back[34 * 40 * 4]);
    try std.testing.expectEqual(@as(u8, 0), back[35 * 40 * 4]);
}

test "audio: open, bounded queue with partial acceptance, status, clear, close" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    try std.testing.expectError(error.NotStarted, p.audioOpen(.{}));
    const caps = try p.start();
    try std.testing.expect(caps.audio);
    backend.audio_capacity_frames = 1000;
    const fmt = try p.audioOpen(.{ .channels = 2, .sample_rate = 8000 });
    try std.testing.expectEqual(@as(u8, 2), fmt.channels);
    try std.testing.expectEqual(@as(u32, 8000), fmt.sample_rate);
    // Pause the device, so the dummy driver does not drain the queue during the count.
    c.SDL_PauseAudioDevice(backend.audio.device, 1);
    try std.testing.expect(p.audioStatus().suspended);

    const samples: [2400]i16 = @splat(0x1234); // 1200 frames offered, 1000 fit
    try std.testing.expectEqual(@as(usize, 1000), try p.audioQueue(&samples));
    try std.testing.expectEqual(@as(usize, 0), try p.audioQueue(&samples));
    var status = p.audioStatus();
    try std.testing.expectEqual(@as(u64, 1000), status.queued_frames);
    try std.testing.expectEqual(@as(u64, 0), status.played_frames);
    try std.testing.expect(!status.running);

    p.audioClear();
    status = p.audioStatus();
    try std.testing.expectEqual(@as(u64, 0), status.queued_frames);
    try std.testing.expectEqual(@as(u64, 0), status.played_frames);
    try std.testing.expectEqual(@as(usize, 300), try p.audioQueue(samples[0..600]));
    try std.testing.expectEqual(@as(u64, 300), p.audioStatus().queued_frames);

    // Let the device run. The frames that it takes are reported as played, never lost.
    c.SDL_PauseAudioDevice(backend.audio.device, 0);
    try std.testing.expect(p.audioStatus().running);
    c.SDL_Delay(50);
    status = p.audioStatus();
    try std.testing.expectEqual(@as(u64, 300), status.queued_frames + status.played_frames);

    p.audioClose();
    try std.testing.expectError(error.DeviceFailure, p.audioQueue(&samples));
    try std.testing.expectEqual(platform.AudioStatus{}, p.audioStatus());
    try std.testing.expectError(error.Unsupported, p.audioOpen(.{ .channels = 0 }));
}

test "the event log receives every delivered event, once, in delivery order" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var log_buf: [4096]u8 = undefined;
    var log = std.Io.Writer.fixed(&log_buf);
    backend.event_log = &log;
    var p = backend.asPlatform();
    _ = try p.start();
    try p.setResolution(8, 6);
    var buf: [16]platform.Event = undefined;
    while (p.pollEvents(&buf) != 0) {} // the events from the window creation
    log.end = 0;

    p.setRelativeMouse(true) catch {};
    p.setRelativeMouse(false) catch {};
    try std.testing.expectEqual(@as(usize, 2), p.pollEvents(&buf));
    try std.testing.expectEqual(@as(usize, 0), p.pollEvents(&buf));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log.buffered(), "\n"), '\n');
    const first = lines.next().?;
    const second = lines.next().?;
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
    try std.testing.expect(std.mem.indexOf(u8, first, "\"kind\":\"capture_changed\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, second, "\"captured\":false}"));
}

test "relative mouse requests report the actual capture state" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    try std.testing.expectError(error.NotStarted, p.setRelativeMouse(true));
    _ = try p.start();
    try p.setResolution(8, 6);
    var buf: [8]platform.Event = undefined;
    _ = p.pollEvents(&buf); // discard the events from the window creation
    const granted = if (p.setRelativeMouse(true)) true else |err| blk: {
        try std.testing.expectEqual(error.Unsupported, err);
        break :blk false;
    };
    try std.testing.expectEqual(@as(usize, 1), p.pollEvents(&buf));
    try std.testing.expectEqual(platform.Event.Kind.capture_changed, std.meta.activeTag(buf[0].payload));
    try std.testing.expectEqual(granted, buf[0].payload.capture_changed);
    try std.testing.expectEqual(c.SDL_GetRelativeMouseMode() == c.TRUE, buf[0].payload.capture_changed);
    p.setRelativeMouse(false) catch {};
    try std.testing.expectEqual(@as(usize, 1), p.pollEvents(&buf));
    try std.testing.expect(!buf[0].payload.capture_changed);
    try std.testing.expect(buf[0].time_ns <= p.nowNs());
    try std.testing.expectError(error.Unsupported, p.netConnect(.{ .host = "localhost", .port = 1 }));
}

test "translation: keys, buttons, wheel direction and timestamps" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    var out: [4]platform.Event = undefined;
    var ev: c.Event = .{ .raw = @splat(0) };
    ev.key = .{ .type = c.KEYDOWN, .timestamp = @truncate(c.SDL_GetTicks64()), .window_id = 0, .state = c.PRESSED, .repeat = 1, .padding2 = 0, .padding3 = 0, .keysym = .{ .scancode = 22, .sym = 0, .mod = 0, .unused = 0 } };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Key.s, out[0].payload.key_down.key);
    try std.testing.expect(out[0].payload.key_down.repeat);
    try std.testing.expect(out[0].time_ns <= p.nowNs());

    ev.wheel = .{ .type = c.MOUSEWHEEL, .timestamp = 0, .window_id = 0, .which = 0, .x = 0, .y = 1, .direction = c.MOUSEWHEEL_FLIPPED, .precise_x = 0, .precise_y = 1, .mouse_x = 0, .mouse_y = 0 };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(@as(i32, -1), out[0].payload.mouse_wheel.dy);
    // A time stamp of 0 ms is before the backend's origin. It is clamped to the time of the
    // previous event, never earlier, so the delivery order and the time stamps agree.
    const first = out[0].time_ns;

    ev.button = .{ .type = c.MOUSEBUTTONUP, .timestamp = @truncate(c.SDL_GetTicks64()), .window_id = 0, .which = 0, .button = c.BUTTON_RIGHT, .state = c.RELEASED, .clicks = 1, .padding1 = 0, .x = 3, .y = 4 };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.MouseButton.right, out[0].payload.mouse_button_up.button);
    try std.testing.expectEqual(@as(i32, 4), out[0].payload.mouse_button_up.y);
    try std.testing.expect(out[0].time_ns >= first);

    ev.text = .{ .type = c.TEXTINPUT, .timestamp = 0, .window_id = 0, .text = @splat(0) };
    @memcpy(ev.text.text[0..9], "abcdefghi");
    try std.testing.expectEqual(@as(usize, 2), backend.translate(&ev, &out));
    try std.testing.expectEqualStrings("i", out[1].payload.text_input.slice());

    ev.common = .{ .type = c.TEXTEDITING, .timestamp = 0 };
    try std.testing.expectEqual(@as(usize, 0), backend.translate(&ev, &out));
}

// The event kinds that no injected input can make on a headless server: window state, quit, and
// controller activity without a controller.
test "translation: window state, quit and controller events" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    try p.setResolution(8, 6);
    var out: [4]platform.Event = undefined;
    var ev: c.Event = .{ .raw = @splat(0) };

    ev.window = .{ .type = c.WINDOWEVENT, .timestamp = 0, .window_id = 0, .event = c.WINDOWEVENT_FOCUS_GAINED, .padding1 = 0, .padding2 = 0, .padding3 = 0, .data1 = 0, .data2 = 0 };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Event.Kind.focus_gained, std.meta.activeTag(out[0].payload));
    ev.window.event = c.WINDOWEVENT_FOCUS_LOST;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Event.Kind.focus_lost, std.meta.activeTag(out[0].payload));
    // A size change reports the drawable, which is the area where the renderer presents.
    ev.window.event = c.WINDOWEVENT_SIZE_CHANGED;
    ev.window.data1 = 3;
    ev.window.data2 = 5;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(backend.outputSize().?, out[0].payload.drawable_resized);
    // Window states that the game does not need are dropped, not translated.
    ev.window.event = 1; // SDL_WINDOWEVENT_SHOWN
    try std.testing.expectEqual(@as(usize, 0), backend.translate(&ev, &out));

    ev.common = .{ .type = c.QUIT, .timestamp = 0 };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Event.Kind.quit, std.meta.activeTag(out[0].payload));

    // SDL's controller button and axis numbers are the project's numbers, so no mapping table is
    // necessary.
    ev.cbutton = .{ .type = c.CONTROLLERBUTTONDOWN, .timestamp = 0, .which = 7, .button = 3, .state = c.PRESSED, .padding1 = 0, .padding2 = 0 };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.ControllerButton.y, out[0].payload.controller_button_down.button);
    try std.testing.expectEqual(@as(u32, 7), @backingInt(out[0].payload.controller_button_down.controller));
    ev.caxis = .{ .type = c.CONTROLLERAXISMOTION, .timestamp = 0, .which = 7, .axis = 5, .padding1 = 0, .padding2 = 0, .padding3 = 0, .value = -1234, .padding4 = 0 };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.ControllerAxis.trigger_right, out[0].payload.controller_axis.axis);
    try std.testing.expectEqual(@as(i16, -1234), out[0].payload.controller_axis.value);
    // A removal reports the instance id, even when this backend has no open controller.
    ev.cdevice = .{ .type = c.CONTROLLERDEVICEREMOVED, .timestamp = 0, .which = 7 };
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(@as(u32, 7), @backingInt(out[0].payload.controller_removed));
    // An addition that SDL cannot open makes no event, not an unusable id.
    ev.cdevice = .{ .type = c.CONTROLLERDEVICEADDED, .timestamp = 0, .which = 99 };
    try std.testing.expectEqual(@as(usize, 0), backend.translate(&ev, &out));
}

test "a failed start leaves a backend that deinit cleans up" {
    useVideoDriver("nonexistent");
    defer useDummyDrivers();
    var backend = try SdlBackend.init(std.testing.allocator, .{ .title = "no display" });
    defer backend.deinit();
    var p = backend.asPlatform();
    try std.testing.expectError(error.DeviceFailure, p.start());
    try std.testing.expect(!backend.started);
    // The attempt released every subsystem that it acquired before video failed.
    try std.testing.expectEqual(@as(u32, 0), backend.subsystems);
    var buf: [4]platform.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), p.pollEvents(&buf));
    try std.testing.expectError(error.NotStarted, p.present(.{ .width = 1, .height = 1, .stride = 4, .pixels = &.{ 0, 0, 0, 255 } }));

    // The failure returned SDL to its initial state: the same backend starts when a driver exists.
    useDummyDrivers();
    _ = try p.start();
    backend.force_software_renderer = true;
    try p.setResolution(4, 4);
}
