//! `SdlBackend`: the SDL platform of Linux and Windows (DESIGN.md). It presents through a window,
//! a renderer and one streaming RGBA32 texture. It translates SDL's event queue into the
//! project's events, with monotonic nanosecond time stamps from SDL's own clock. An SDL audio
//! stream implements the bounded PCM queue contract. An event reports the relative mouse capture.
//! This file has no palette logic and no game knowledge.
//!
//! `SDL_InitSubSystem` starts each subsystem, and each one is released separately, so several
//! backends (or the tests) can exist in one process. `deinit` is valid after a successful or a
//! failed `start`.
const std = @import("std");
const builtin = @import("builtin");
const gameport = @import("gameport");
const platform = gameport.platform;
const c = @import("c");
const eventlog = @import("eventlog.zig");

pub const SdlBackend = struct {
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
    /// `SDL_GetTicksNS` at `start`: the origin of `now_ns` and of the events' time stamps, which
    /// SDL gives in the same clock.
    ticks_base_ns: u64 = 0,
    last_event_ns: u64 = 0,

    window: ?*c.SDL_Window = null,
    keyboard_focused: bool = false,
    renderer: ?*c.SDL_Renderer = null,
    texture: ?*c.SDL_Texture = null,
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
    /// counts times the scale numerator (see `pageMotion`). SDL reports fractional counts.
    motion_residue_x: f64 = 0,
    motion_residue_y: f64 = 0,
    /// The wheel's fractional steps not yet reported, one per axis.
    wheel_residue_x: f32 = 0,
    wheel_residue_y: f32 = 0,
    renderer_name_buf: [32]u8 = @splat(0),
    renderer_name_len: usize = 0,
    controllers: std.ArrayList(*c.SDL_Gamepad) = .empty,

    audio: Audio = .{},

    pub const Audio = struct {
        /// The stream to the default playback device, which SDL opens and closes with it.
        stream: ?*c.SDL_AudioStream = null,
        format: platform.AudioFormat = .{},
        bytes_per_frame: u32 = 0,
        capacity_frames: u64 = 0,
        /// All frames that `audio_queue` accepted. `played` is computed from this count and
        /// the stream's queue size.
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
        for (self.controllers.items) |handle| c.SDL_CloseGamepad(handle);
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
    };

    fn cast(ctx: *anyopaque) *SdlBackend {
        return @ptrCast(@alignCast(ctx));
    }

    // --- lifecycle ---------------------------------------------------------------------------

    fn initSubsystem(self: *SdlBackend, flags: u32) bool {
        if (!c.SDL_InitSubSystem(flags)) {
            std.log.warn("SDL subsystem 0x{x} unavailable: {s}", .{ flags, c.SDL_GetError() });
            return false;
        }
        self.subsystems |= flags;
        return true;
    }

    /// Events and video are required. If the audio or gamepad subsystem fails, the capability is
    /// reported as absent. A failed attempt releases the subsystems that it acquired, so a later
    /// `start` begins from the state after `init`. SDL3 declares itself DPI-aware on Windows.
    fn start(ctx: *anyopaque) platform.PlatformError!platform.Capabilities {
        const self = cast(ctx);
        if (self.started) return self.capabilities;
        const held = self.subsystems;
        errdefer {
            const acquired = self.subsystems & ~held;
            if (acquired != 0) c.SDL_QuitSubSystem(acquired);
            self.subsystems = held;
        }
        if (!self.initSubsystem(c.SDL_INIT_EVENTS)) return error.DeviceFailure;
        if (!self.initSubsystem(c.SDL_INIT_VIDEO)) return error.DeviceFailure;
        const audio = self.initSubsystem(c.SDL_INIT_AUDIO);
        const controllers = self.initSubsystem(c.SDL_INIT_GAMEPAD);
        self.ticks_base_ns = c.SDL_GetTicksNS();
        self.last_event_ns = 0;
        self.started = true;
        self.capabilities = .{ .video = true, .audio = audio, .controllers = controllers };
        return self.capabilities;
    }

    // --- time --------------------------------------------------------------------------------

    fn nowNs(ctx: *anyopaque) u64 {
        const self = cast(ctx);
        return self.elapsedNs();
    }

    fn elapsedNs(self: *const SdlBackend) u64 {
        if (!self.started) return 0;
        return c.SDL_GetTicksNS() -| self.ticks_base_ns;
    }

    /// Converts an SDL event time stamp (nanoseconds, `SDL_GetTicksNS` clock) into the `now_ns`
    /// domain. The result is never later than now and never earlier than the previous event, so
    /// the delivery order and the time stamps agree.
    fn eventTimeNs(self: *SdlBackend, timestamp_ns: u64) u64 {
        const t = @min(timestamp_ns -| self.ticks_base_ns, self.elapsedNs());
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

    /// A rectangle in output pixels.
    pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

    /// The largest rectangle with the aspect ratio of the frame that fits the output, centred.
    pub fn fitRect(out_w: i32, out_h: i32, width: u32, height: u32) Rect {
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
    fn presentRect(self: *SdlBackend) ?struct { rect: Rect, page: platform.Size } {
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

    /// One pointer motion, converted from device counts to the game's counts by the
    /// `--mouse-scale` fraction.
    ///
    /// The window scale does not apply: a relative delta is not a window measurement. Each axis
    /// keeps its remainder, so a slow drag does not round to zero.
    fn pageMotion(self: *SdlBackend, dx: f32, dy: f32) struct { dx: i32, dy: i32 } {
        const num: f64 = @floatFromInt(self.mouse_scale_num);
        const den: f64 = @floatFromInt(self.mouse_scale_den);
        self.motion_residue_x += @as(f64, dx) * num;
        self.motion_residue_y += @as(f64, dy) * num;
        const step_x = @trunc(self.motion_residue_x / den);
        const step_y = @trunc(self.motion_residue_y / den);
        self.motion_residue_x -= step_x * den;
        self.motion_residue_y -= step_y * den;
        return .{ .dx = @intFromFloat(step_x), .dy = @intFromFloat(step_y) };
    }

    /// One pointer position in page pixels: the window point minus the offset of the blit,
    /// scaled. Outside the blit, the position is clamped to the page, where the pointer is drawn.
    fn pagePoint(self: *SdlBackend, fx: f32, fy: f32) struct { x: i32, y: i32 } {
        const x: i32 = @intFromFloat(@floor(fx));
        const y: i32 = @intFromFloat(@floor(fy));
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
        const display = if (self.window) |w| c.SDL_GetDisplayForWindow(w) else c.SDL_GetPrimaryDisplay();
        var rect: c.SDL_Rect = undefined;
        if (!c.SDL_GetDisplayUsableBounds(display, &rect) or rect.w <= 0 or rect.h <= 0) return null;
        return .{ .width = @intCast(rect.w), .height = @intCast(rect.h) };
    }

    /// Sets the window size for the new resolution after a mode change. A window that the user
    /// resized keeps its size: the frame is then letterboxed into it, as the design requires for
    /// window state and render resolution.
    fn refitWindow(self: *SdlBackend, width: u32, height: u32) void {
        const window = self.window orelse return;
        var w: c_int = 0;
        var h: c_int = 0;
        if (!c.SDL_GetWindowSize(window, &w, &h) or w < 0 or h < 0) return;
        if (@as(u32, @intCast(w)) != self.window_size.width or @as(u32, @intCast(h)) != self.window_size.height) return;
        const size = fitWindowSize(width, height, self.options.initial_window_scale, self.displayBounds());
        _ = c.SDL_SetWindowSize(window, @intCast(size.width), @intCast(size.height));
        self.window_size = size;
    }

    fn createPresentation(self: *SdlBackend, width: u32, height: u32) platform.PlatformError!void {
        const size = fitWindowSize(width, height, self.options.initial_window_scale, self.displayBounds());
        // The window is sized in the display's pixels, which the window scale divides exactly.
        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const window = c.SDL_CreateWindow(self.title.ptr, @intCast(size.width), @intCast(size.height), flags) orelse {
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
        // Text input is per window in SDL3; the game reads it on any screen that takes text.
        _ = c.SDL_StartTextInput(window);
        self.window = window;
        self.renderer = created.renderer;
        self.texture = texture;
        self.window_size = size;
    }

    const CreatedRenderer = struct { renderer: *c.SDL_Renderer, asked_vsync: bool };

    fn createRenderer(self: *const SdlBackend, window: *c.SDL_Window) ?CreatedRenderer {
        const r = c.SDL_CreateRenderer(window, if (self.force_software_renderer) "software" else null) orelse {
            if (self.force_software_renderer) return null;
            const soft = c.SDL_CreateRenderer(window, "software") orelse return null;
            return .{ .renderer = soft, .asked_vsync = false };
        };
        const asked = !self.force_software_renderer and self.options.prefer_vsync and c.SDL_SetRenderVSync(r, 1);
        return .{ .renderer = r, .asked_vsync = asked };
    }

    /// The software renderer's present does not wait for the display, whatever it reports, so
    /// only an accelerated renderer that accepted vsync counts as paced.
    fn recordRendererInfo(self: *SdlBackend, created: CreatedRenderer) void {
        const name = c.SDL_GetRendererName(created.renderer) orelse return;
        const text = std.mem.sliceTo(name, 0);
        self.software = std.mem.eql(u8, text, "software");
        var vsync: c_int = 0;
        self.vsync = created.asked_vsync and !self.software and c.SDL_GetRenderVSync(created.renderer, &vsync) and vsync != 0;
        // The SDL driver in use, for the host's start-up line: "opengl", "software", "vulkan"
        // and others. A window that never paints is almost always a driver problem, and only
        // this code knows the driver.
        const n = @min(text.len, self.renderer_name_buf.len);
        @memcpy(self.renderer_name_buf[0..n], text[0..n]);
        self.renderer_name_len = n;
    }

    /// The name of the driver, as `SDL_GetRendererName` reports it.
    pub fn rendererName(self: *const SdlBackend) []const u8 {
        return self.renderer_name_buf[0..self.renderer_name_len];
    }

    fn createTexture(self: *SdlBackend, renderer: *c.SDL_Renderer, width: u32, height: u32) ?*c.SDL_Texture {
        if (self.fail_next_texture) {
            self.fail_next_texture = false;
            return null;
        }
        const texture: *c.SDL_Texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, @intCast(width), @intCast(height)) orelse {
            std.log.err("SDL_CreateTexture({d}x{d}) failed: {s}", .{ width, height, c.SDL_GetError() });
            return null;
        };
        // Whole pixels when the frame is scaled up: the original's pixels stay sharp. The frame is
        // copied as it is: SDL3 blends a texture with an alpha channel by default.
        _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST);
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_NONE);
        return texture;
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
        if (!c.SDL_GetCurrentRenderOutputSize(renderer, &w, &h) or w < 0 or h < 0) return null;
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
        if (!c.SDL_UpdateTexture(texture, null, frame.pixels.ptr, pitch)) return error.DeviceFailure;
        const out = self.outputSize() orelse platform.Size{ .width = res.width, .height = res.height };
        const r = fitRect(@intCast(@min(out.width, std.math.maxInt(i32))), @intCast(@min(out.height, std.math.maxInt(i32))), res.width, res.height);
        const dst: c.SDL_FRect = .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(renderer);
        if (!c.SDL_RenderTexture(renderer, texture, null, &dst)) return error.DeviceFailure;
        _ = c.SDL_RenderPresent(renderer);
        self.frames_presented += 1;
    }

    // --- events ------------------------------------------------------------------------------

    fn pollEvents(ctx: *anyopaque, dst: []platform.Event) usize {
        const self = cast(ctx);
        const n = self.poll(dst);
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
        var ev: c.SDL_Event = undefined;
        while (n < dst.len and c.SDL_PollEvent(&ev)) {
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
    fn translate(self: *SdlBackend, ev: *const c.SDL_Event, out: []platform.Event) usize {
        const payload: platform.Event.Payload = switch (ev.type) {
            c.SDL_EVENT_QUIT => .quit,
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => blk: {
                self.keyboard_focused = true;
                break :blk .focus_gained;
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => blk: {
                const was_focused = self.keyboard_focused;
                self.keyboard_focused = false;
                // The pointer goes back to the desktop with the focus.
                self.setCapture(false);
                if (!was_focused) return 0;
                break :blk .focus_lost;
            },
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => .{ .drawable_resized = self.outputSize() orelse .{
                .width = @intCast(@max(ev.window.data1, 0)),
                .height = @intCast(@max(ev.window.data2, 0)),
            } },
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => blk: {
                // SDL releases held keys before it queues the focus loss. Report the loss first, so
                // these synthetic releases cannot commit a drag or a stroke. Injected events
                // without a window are kept.
                if (ev.key.windowID != 0 and self.window != null and
                    (!self.keyboard_focused or c.SDL_GetKeyboardFocus() != self.window))
                {
                    if (!self.keyboard_focused) return 0;
                    self.keyboard_focused = false;
                    break :blk .focus_lost;
                }
                // Ctrl+F10 is the host's chord, and the game never sees it. It moves the pointer
                // between the desktop and the game.
                if (keyFromScancode(ev.key.scancode) == .f10 and (ev.key.mod & c.SDL_KMOD_CTRL) != 0) {
                    if (ev.key.down) self.setCapture(!self.captured);
                    return 0;
                }
                const key: platform.Event.KeyEvent = .{ .key = keyFromScancode(ev.key.scancode), .repeat = ev.key.repeat };
                break :blk if (ev.key.down) .{ .key_down = key } else .{ .key_up = key };
            },
            c.SDL_EVENT_TEXT_INPUT => {
                const t = self.eventTimeNs(ev.common.timestamp);
                const text = ev.text.text orelse return 0;
                return splitText(std.mem.sliceTo(text, 0), t, out);
            },
            c.SDL_EVENT_MOUSE_MOTION => blk: {
                if (self.relative_wanted and !self.captured) return 0;
                const motion = self.pageMotion(ev.motion.xrel, ev.motion.yrel);
                const at = self.pagePoint(ev.motion.x, ev.motion.y);
                break :blk .{ .mouse_motion = .{ .dx = motion.dx, .dy = motion.dy, .x = at.x, .y = at.y } };
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => blk: {
                // A click while the desktop has the pointer captures the pointer. The game does
                // not get this click.
                if (self.swallow_button_up and !ev.button.down) {
                    self.swallow_button_up = false;
                    return 0;
                }
                if (!self.captured and self.relative_wanted and ev.button.down) {
                    self.setCapture(true);
                    self.swallow_button_up = true;
                    return 0;
                }
                const at = self.pagePoint(ev.button.x, ev.button.y);
                const button: platform.Event.MouseButtonEvent = .{ .button = mouseButton(ev.button.button), .x = at.x, .y = at.y };
                break :blk if (ev.button.down) .{ .mouse_button_down = button } else .{ .mouse_button_up = button };
            },
            c.SDL_EVENT_MOUSE_WHEEL => blk: {
                // SDL reports fractions of a step (smooth scrolling); the game gets whole steps.
                const sign: f32 = if (ev.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                self.wheel_residue_x += ev.wheel.x * sign;
                self.wheel_residue_y += ev.wheel.y * sign;
                const dx = @trunc(self.wheel_residue_x);
                const dy = @trunc(self.wheel_residue_y);
                self.wheel_residue_x -= dx;
                self.wheel_residue_y -= dy;
                if (dx == 0 and dy == 0) return 0;
                break :blk .{ .mouse_wheel = .{ .dx = @intFromFloat(dx), .dy = @intFromFloat(dy) } };
            },
            c.SDL_EVENT_GAMEPAD_ADDED => blk: {
                const id = self.openController(ev.gdevice.which) orelse return 0;
                break :blk .{ .controller_added = id };
            },
            c.SDL_EVENT_GAMEPAD_REMOVED => blk: {
                self.closeController(ev.gdevice.which);
                break :blk .{ .controller_removed = controllerId(ev.gdevice.which) };
            },
            c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_EVENT_GAMEPAD_BUTTON_UP => blk: {
                // The project's buttons are SDL's first fifteen; the others are not mapped.
                if (ev.gbutton.button >= @typeInfo(platform.ControllerButton).@"enum".field_names.len) return 0;
                const button: platform.Event.ControllerButtonEvent = .{ .controller = controllerId(ev.gbutton.which), .button = @fromBackingInt(ev.gbutton.button) };
                break :blk if (ev.gbutton.down) .{ .controller_button_down = button } else .{ .controller_button_up = button };
            },
            c.SDL_EVENT_GAMEPAD_AXIS_MOTION => .{ .controller_axis = .{ .controller = controllerId(ev.gaxis.which), .axis = @fromBackingInt(ev.gaxis.axis), .value = ev.gaxis.value } },
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

    fn controllerId(instance: c.SDL_JoystickID) platform.ControllerId {
        return @fromBackingInt(@as(u32, instance));
    }

    /// Opens the gamepad of an instance id, which SDL3 gives in the event itself.
    fn openController(self: *SdlBackend, instance: c.SDL_JoystickID) ?platform.ControllerId {
        const handle = c.SDL_OpenGamepad(instance) orelse return null;
        self.controllers.append(self.allocator, handle) catch {
            c.SDL_CloseGamepad(handle);
            return null;
        };
        return controllerId(instance);
    }

    fn closeController(self: *SdlBackend, instance: c.SDL_JoystickID) void {
        const handle = c.SDL_GetGamepadFromID(instance) orelse return;
        for (self.controllers.items, 0..) |h, i| {
            if (h == handle) {
                _ = self.controllers.swapRemove(i);
                c.SDL_CloseGamepad(handle);
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
        // The stream takes the game's format as it is and converts it for the device, so the
        // format obtained is the one requested.
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_S16, .channels = requested.channels, .freq = @intCast(requested.sample_rate) };
        const stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null) orelse {
            std.log.err("SDL_OpenAudioDeviceStream failed: {s}", .{c.SDL_GetError()});
            return error.DeviceFailure;
        };
        const format: platform.AudioFormat = .{ .channels = requested.channels, .sample_rate = requested.sample_rate };
        self.audio = .{
            .stream = stream,
            .format = format,
            .bytes_per_frame = @as(u32, requested.channels) * @sizeOf(i16),
            .capacity_frames = if (self.audio_capacity_frames != 0) self.audio_capacity_frames else format.sample_rate,
        };
        _ = c.SDL_ResumeAudioStreamDevice(stream);
        return format;
    }

    fn queuedFrames(self: *const SdlBackend) u64 {
        const stream = self.audio.stream orelse return 0;
        return @as(u64, @intCast(@max(c.SDL_GetAudioStreamQueued(stream), 0))) / self.audio.bytes_per_frame;
    }

    fn audioQueue(ctx: *anyopaque, samples: []const i16) platform.PlatformError!usize {
        const self = cast(ctx);
        const stream = self.audio.stream orelse return error.DeviceFailure;
        const channels: usize = self.audio.format.channels;
        const offered = samples.len / channels;
        const room = self.audio.capacity_frames -| self.queuedFrames();
        const accepted: usize = @intCast(@min(offered, room));
        if (accepted == 0) return 0;
        const bytes: c_int = @intCast(accepted * self.audio.bytes_per_frame);
        if (!c.SDL_PutAudioStreamData(stream, samples.ptr, bytes)) return error.DeviceFailure;
        self.audio.accepted_frames += accepted;
        return accepted;
    }

    /// `played` counts the frames that the device took from the stream. Discarded frames are not
    /// counted.
    fn audioStatus(ctx: *anyopaque) platform.AudioStatus {
        const self = cast(ctx);
        const stream = self.audio.stream orelse return .{};
        const queued = self.queuedFrames();
        const paused = c.SDL_AudioStreamDevicePaused(stream);
        return .{
            .queued_frames = queued,
            .played_frames = self.audio.accepted_frames -| self.audio.discarded_frames -| queued,
            .running = !paused,
            .suspended = paused,
        };
    }

    fn audioClear(ctx: *anyopaque) void {
        const self = cast(ctx);
        const stream = self.audio.stream orelse return;
        _ = c.SDL_LockAudioStream(stream);
        self.audio.discarded_frames += self.queuedFrames();
        _ = c.SDL_ClearAudioStream(stream);
        _ = c.SDL_UnlockAudioStream(stream);
    }

    fn audioClose(ctx: *anyopaque) void {
        cast(ctx).closeAudio();
    }

    fn closeAudio(self: *SdlBackend) void {
        if (self.audio.stream) |stream| c.SDL_DestroyAudioStream(stream);
        self.audio = .{};
    }

    // --- capture -------------------------------------------------------------------------

    /// Requests relative mode for the window. A `capture_changed` event reports the state that
    /// SDL really reached, also when the request failed (before the window exists, for one).
    fn setRelativeMouse(ctx: *anyopaque, enabled: bool) platform.PlatformError!void {
        const self = cast(ctx);
        if (!self.started) return error.NotStarted;
        self.relative_wanted = enabled;
        const ok = self.applyRelative(enabled);
        const t = self.orderedTime(self.elapsedNs());
        self.pending.append(self.allocator, .{ .time_ns = t, .payload = .{ .capture_changed = self.captured } }) catch return error.OutOfMemory;
        if (!ok) return error.Unsupported;
    }

    /// Sets the window's relative mode and the cursor, and records the state that SDL reached.
    fn applyRelative(self: *SdlBackend, enabled: bool) bool {
        const window = self.window orelse {
            self.captured = false;
            return !enabled;
        };
        const ok = c.SDL_SetWindowRelativeMouseMode(window, enabled);
        self.captured = c.SDL_GetWindowRelativeMouseMode(window);
        _ = if (self.captured) c.SDL_HideCursor() else c.SDL_ShowCursor();
        return ok;
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
        _ = self.applyRelative(enabled);
        const t = self.orderedTime(self.elapsedNs());
        self.pending.append(self.allocator, .{ .time_ns = t, .payload = .{ .capture_changed = self.captured } }) catch {};
        self.motion_residue_x = 0;
        self.motion_residue_y = 0;
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
    _ = c.SDL_SetHintWithPriority(c.SDL_HINT_VIDEO_DRIVER, name, c.SDL_HINT_OVERRIDE);
}

/// The tests run without a display or a sound card.
fn useDummyDrivers() void {
    useVideoDriver("dummy");
    _ = c.SDL_SetHintWithPriority(c.SDL_HINT_AUDIO_DRIVER, "dummy", c.SDL_HINT_OVERRIDE);
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
    const read = c.SDL_RenderReadPixels(renderer, null) orelse return error.ReadBackFailed;
    defer c.SDL_DestroySurface(read);
    const rgba = c.SDL_ConvertSurface(read, c.SDL_PIXELFORMAT_RGBA32) orelse return error.ReadBackFailed;
    defer c.SDL_DestroySurface(rgba);
    const rows: usize = @intCast(rgba.*.h);
    const pitch: usize = @intCast(rgba.*.pitch);
    const src: [*]const u8 = @ptrCast(rgba.*.pixels orelse return error.ReadBackFailed);
    for (0..rows) |y| @memcpy(dst[y * width * 4 ..][0 .. width * 4], src[y * pitch ..][0 .. width * 4]);
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
    try std.testing.expectEqual(platform.MouseButton.left, mouseButton(c.SDL_BUTTON_LEFT));
    try std.testing.expectEqual(platform.MouseButton.x2, mouseButton(c.SDL_BUTTON_X2));
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
    const Rect = SdlBackend.Rect;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 640, .h = 400 }, rect(640, 400, 320, 200));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 100, .w = 640, .h = 400 }, rect(640, 600, 320, 200));
    try std.testing.expectEqual(Rect{ .x = 160, .y = 0, .w = 320, .h = 200 }, rect(640, 200, 320, 200));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, rect(0, 200, 320, 200));
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
    // The software renderer does not wait for a display. The host must not treat it as paced.
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
    _ = c.SDL_SetWindowSize(backend.window.?, 40, 40);
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
    _ = c.SDL_PauseAudioStreamDevice(backend.audio.stream);
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
    _ = c.SDL_ResumeAudioStreamDevice(backend.audio.stream);
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
    try std.testing.expectEqual(c.SDL_GetWindowRelativeMouseMode(backend.window), buf[0].payload.capture_changed);
    p.setRelativeMouse(false) catch {};
    try std.testing.expectEqual(@as(usize, 1), p.pollEvents(&buf));
    try std.testing.expect(!buf[0].payload.capture_changed);
    try std.testing.expect(buf[0].time_ns <= p.nowNs());
}

test "translation: keys, buttons, wheel direction and timestamps" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    var out: [4]platform.Event = undefined;
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.key.type = c.SDL_EVENT_KEY_DOWN;
    ev.key.timestamp = c.SDL_GetTicksNS();
    ev.key.scancode = 22;
    ev.key.down = true;
    ev.key.repeat = true;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Key.s, out[0].payload.key_down.key);
    try std.testing.expect(out[0].payload.key_down.repeat);
    try std.testing.expect(out[0].time_ns <= p.nowNs());

    ev = std.mem.zeroes(c.SDL_Event);
    ev.wheel.type = c.SDL_EVENT_MOUSE_WHEEL;
    ev.wheel.y = 1;
    ev.wheel.direction = c.SDL_MOUSEWHEEL_FLIPPED;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(@as(i32, -1), out[0].payload.mouse_wheel.dy);
    // A half step is kept until the next half makes a whole one.
    ev.wheel.y = 0.5;
    ev.wheel.direction = 0;
    try std.testing.expectEqual(@as(usize, 0), backend.translate(&ev, &out));
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(@as(i32, 1), out[0].payload.mouse_wheel.dy);
    // A time stamp of 0 is before the backend's origin. It is clamped to the time of the previous
    // event, never earlier, so the delivery order and the time stamps agree.
    const first = out[0].time_ns;

    ev = std.mem.zeroes(c.SDL_Event);
    ev.button.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    ev.button.timestamp = c.SDL_GetTicksNS();
    ev.button.button = c.SDL_BUTTON_RIGHT;
    ev.button.x = 3;
    ev.button.y = 4;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.MouseButton.right, out[0].payload.mouse_button_up.button);
    try std.testing.expectEqual(@as(i32, 4), out[0].payload.mouse_button_up.y);
    try std.testing.expect(out[0].time_ns >= first);

    ev = std.mem.zeroes(c.SDL_Event);
    ev.text.type = c.SDL_EVENT_TEXT_INPUT;
    ev.text.text = "abcdefghi";
    try std.testing.expectEqual(@as(usize, 2), backend.translate(&ev, &out));
    try std.testing.expectEqualStrings("i", out[1].payload.text_input.slice());

    ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_TEXT_EDITING;
    try std.testing.expectEqual(@as(usize, 0), backend.translate(&ev, &out));
}

// The event kinds that no injected input can make on a headless server: window state, quit, and
// gamepad activity without a gamepad.
test "translation: window state, quit and gamepad events" {
    var backend = try startedBackend(1);
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    try p.setResolution(8, 6);
    var out: [4]platform.Event = undefined;
    var ev = std.mem.zeroes(c.SDL_Event);

    ev.type = c.SDL_EVENT_WINDOW_FOCUS_GAINED;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Event.Kind.focus_gained, std.meta.activeTag(out[0].payload));
    ev.type = c.SDL_EVENT_WINDOW_FOCUS_LOST;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Event.Kind.focus_lost, std.meta.activeTag(out[0].payload));
    // A size change reports the drawable, which is the area where the renderer presents.
    ev.window.type = c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
    ev.window.data1 = 3;
    ev.window.data2 = 5;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(backend.outputSize().?, out[0].payload.drawable_resized);
    // Window states that the game does not need are dropped, not translated.
    ev.type = c.SDL_EVENT_WINDOW_SHOWN;
    try std.testing.expectEqual(@as(usize, 0), backend.translate(&ev, &out));

    ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_QUIT;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.Event.Kind.quit, std.meta.activeTag(out[0].payload));

    // SDL's gamepad button and axis numbers are the project's numbers (south, east, west, north
    // are a, b, x, y), so no mapping table is necessary.
    ev = std.mem.zeroes(c.SDL_Event);
    ev.gbutton.type = c.SDL_EVENT_GAMEPAD_BUTTON_DOWN;
    ev.gbutton.which = 7;
    ev.gbutton.button = c.SDL_GAMEPAD_BUTTON_NORTH;
    ev.gbutton.down = true;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.ControllerButton.y, out[0].payload.controller_button_down.button);
    try std.testing.expectEqual(@as(u32, 7), @backingInt(out[0].payload.controller_button_down.controller));
    // A button beyond the project's set (a paddle, the touchpad) makes no event.
    ev.gbutton.button = c.SDL_GAMEPAD_BUTTON_TOUCHPAD;
    try std.testing.expectEqual(@as(usize, 0), backend.translate(&ev, &out));
    ev = std.mem.zeroes(c.SDL_Event);
    ev.gaxis.type = c.SDL_EVENT_GAMEPAD_AXIS_MOTION;
    ev.gaxis.which = 7;
    ev.gaxis.axis = c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER;
    ev.gaxis.value = -1234;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(platform.ControllerAxis.trigger_right, out[0].payload.controller_axis.axis);
    try std.testing.expectEqual(@as(i16, -1234), out[0].payload.controller_axis.value);
    // A removal reports the instance id, even when this backend has no open gamepad.
    ev = std.mem.zeroes(c.SDL_Event);
    ev.gdevice.type = c.SDL_EVENT_GAMEPAD_REMOVED;
    ev.gdevice.which = 7;
    try std.testing.expectEqual(@as(usize, 1), backend.translate(&ev, &out));
    try std.testing.expectEqual(@as(u32, 7), @backingInt(out[0].payload.controller_removed));
    // An addition that SDL cannot open makes no event, not an unusable id.
    ev.gdevice.type = c.SDL_EVENT_GAMEPAD_ADDED;
    ev.gdevice.which = 99;
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
