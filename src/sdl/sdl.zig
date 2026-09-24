//! SDL2 bindings, declared by hand, for the functions that the host uses. Hand declarations (not
//! a translation of the headers) keep the SDL surface in use explicit and reviewable. The SDL2
//! ABI is stable across 2.x. Each declaration mirrors /usr/include/SDL2 of the pinned release.
//! The `layout` test below checks the struct sizes, and the offsets of the fields that the
//! backend reads, against the values that a C probe printed for those headers.
const std = @import("std");

pub const Version = extern struct {
    major: u8,
    minor: u8,
    patch: u8,
};

pub const Window = opaque {};
pub const Renderer = opaque {};
pub const Texture = opaque {};
pub const GameController = opaque {};
pub const Joystick = opaque {};

pub const Bool = c_int;
pub const FALSE: Bool = 0;
pub const TRUE: Bool = 1;

pub const Rect = extern struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

// --- subsystems ------------------------------------------------------------------------------

pub const INIT_TIMER: u32 = 0x00000001;
pub const INIT_AUDIO: u32 = 0x00000010;
pub const INIT_VIDEO: u32 = 0x00000020;
pub const INIT_JOYSTICK: u32 = 0x00000200;
pub const INIT_GAMECONTROLLER: u32 = 0x00002000;
pub const INIT_EVENTS: u32 = 0x00004000;

pub extern "c" fn SDL_Init(flags: u32) c_int;
pub extern "c" fn SDL_InitSubSystem(flags: u32) c_int;
pub extern "c" fn SDL_QuitSubSystem(flags: u32) void;
pub extern "c" fn SDL_WasInit(flags: u32) u32;
pub extern "c" fn SDL_Quit() void;
pub extern "c" fn SDL_GetVersion(ver: *Version) void;
pub extern "c" fn SDL_GetError() [*:0]const u8;
pub extern "c" fn SDL_ClearError() void;
pub extern "c" fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) Bool;
pub extern "c" fn SDL_SetHintWithPriority(name: [*:0]const u8, value: [*:0]const u8, priority: c_int) Bool;

/// `SDL_HINT_OVERRIDE`: the hint wins over the environment variable of the same name.
pub const HINT_OVERRIDE: c_int = 2;

pub const HINT_RENDER_SCALE_QUALITY = "SDL_RENDER_SCALE_QUALITY";
pub const HINT_VIDEODRIVER = "SDL_VIDEODRIVER";
pub const HINT_AUDIODRIVER = "SDL_AUDIODRIVER";
/// Read when video starts: "permonitorv2" declares per-monitor DPI awareness (Windows 10 1703),
/// and SDL falls back to the older forms on older systems.
pub const HINT_WINDOWS_DPI_AWARENESS = "SDL_WINDOWS_DPI_AWARENESS";

// --- time ------------------------------------------------------------------------------------

pub extern "c" fn SDL_GetPerformanceCounter() u64;
pub extern "c" fn SDL_GetPerformanceFrequency() u64;
pub extern "c" fn SDL_GetTicks64() u64;
pub extern "c" fn SDL_Delay(ms: u32) void;

// --- video -----------------------------------------------------------------------------------

pub const WINDOWPOS_UNDEFINED: c_int = @bitCast(@as(u32, 0x1FFF0000));
pub const WINDOWPOS_CENTERED: c_int = @bitCast(@as(u32, 0x2FFF0000));

pub const WINDOW_SHOWN: u32 = 0x00000004;
pub const WINDOW_RESIZABLE: u32 = 0x00000020;
pub const WINDOW_ALLOW_HIGHDPI: u32 = 0x00002000;

pub extern "c" fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*Window;
pub extern "c" fn SDL_DestroyWindow(window: *Window) void;
pub extern "c" fn SDL_SetWindowSize(window: *Window, w: c_int, h: c_int) void;
pub extern "c" fn SDL_GetWindowSize(window: *Window, w: *c_int, h: *c_int) void;
pub extern "c" fn SDL_SetWindowMinimumSize(window: *Window, min_w: c_int, min_h: c_int) void;
pub extern "c" fn SDL_GetWindowDisplayIndex(window: *Window) c_int;
pub extern "c" fn SDL_GetKeyboardFocus() ?*Window;
pub extern "c" fn SDL_GetDisplayUsableBounds(display_index: c_int, rect: *Rect) c_int;

// --- rendering -------------------------------------------------------------------------------

pub const RENDERER_SOFTWARE: u32 = 0x00000001;
pub const RENDERER_ACCELERATED: u32 = 0x00000002;
pub const RENDERER_PRESENTVSYNC: u32 = 0x00000004;

pub const TEXTUREACCESS_STREAMING: c_int = 1;

/// `SDL_PIXELFORMAT_RGBA32`: R, G, B, A bytes in memory order on every endianness
/// (`SDL_PIXELFORMAT_ABGR8888` on little-endian hosts; a C probe checked the value).
pub const PIXELFORMAT_RGBA32: u32 = 0x16762004;

pub const RendererInfo = extern struct {
    name: [*:0]const u8,
    flags: u32,
    num_texture_formats: u32,
    texture_formats: [16]u32,
    max_texture_width: c_int,
    max_texture_height: c_int,
};

pub extern "c" fn SDL_CreateRenderer(window: *Window, index: c_int, flags: u32) ?*Renderer;
pub extern "c" fn SDL_DestroyRenderer(renderer: *Renderer) void;
pub extern "c" fn SDL_GetRendererInfo(renderer: *Renderer, info: *RendererInfo) c_int;
pub extern "c" fn SDL_GetRendererOutputSize(renderer: *Renderer, w: *c_int, h: *c_int) c_int;
pub extern "c" fn SDL_CreateTexture(renderer: *Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*Texture;
pub extern "c" fn SDL_DestroyTexture(texture: *Texture) void;
pub extern "c" fn SDL_UpdateTexture(texture: *Texture, rect: ?*const Rect, pixels: *const anyopaque, pitch: c_int) c_int;
pub extern "c" fn SDL_SetRenderDrawColor(renderer: *Renderer, r: u8, g: u8, b: u8, a: u8) c_int;
pub extern "c" fn SDL_RenderClear(renderer: *Renderer) c_int;
pub extern "c" fn SDL_RenderCopy(renderer: *Renderer, texture: *Texture, src: ?*const Rect, dst: ?*const Rect) c_int;
pub extern "c" fn SDL_RenderPresent(renderer: *Renderer) void;
pub extern "c" fn SDL_RenderReadPixels(renderer: *Renderer, rect: ?*const Rect, format: u32, pixels: *anyopaque, pitch: c_int) c_int;

// --- events ----------------------------------------------------------------------------------

pub const QUIT: u32 = 0x100;
pub const WINDOWEVENT: u32 = 0x200;
pub const KEYDOWN: u32 = 0x300;
pub const KEYUP: u32 = 0x301;
pub const TEXTEDITING: u32 = 0x302;
pub const TEXTINPUT: u32 = 0x303;
pub const MOUSEMOTION: u32 = 0x400;
pub const MOUSEBUTTONDOWN: u32 = 0x401;
pub const MOUSEBUTTONUP: u32 = 0x402;
pub const MOUSEWHEEL: u32 = 0x403;
pub const CONTROLLERAXISMOTION: u32 = 0x650;
pub const CONTROLLERBUTTONDOWN: u32 = 0x651;
pub const CONTROLLERBUTTONUP: u32 = 0x652;
pub const CONTROLLERDEVICEADDED: u32 = 0x653;
pub const CONTROLLERDEVICEREMOVED: u32 = 0x654;

pub const WINDOWEVENT_SIZE_CHANGED: u8 = 6;
pub const WINDOWEVENT_FOCUS_GAINED: u8 = 12;
pub const WINDOWEVENT_FOCUS_LOST: u8 = 13;

pub const PRESSED: u8 = 1;
pub const RELEASED: u8 = 0;

pub const MOUSEWHEEL_FLIPPED: u32 = 1;

pub const BUTTON_LEFT: u8 = 1;
pub const BUTTON_MIDDLE: u8 = 2;
pub const BUTTON_RIGHT: u8 = 3;
pub const BUTTON_X1: u8 = 4;
pub const BUTTON_X2: u8 = 5;

pub const TEXTINPUTEVENT_TEXT_SIZE = 32;

pub const JoystickID = i32;

pub const Keysym = extern struct {
    scancode: c_uint,
    sym: i32,
    mod: u16,
    unused: u32,
};

pub const CommonEvent = extern struct {
    type: u32,
    timestamp: u32,
};

pub const WindowEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    event: u8,
    padding1: u8,
    padding2: u8,
    padding3: u8,
    data1: i32,
    data2: i32,
};

pub const KeyboardEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    state: u8,
    repeat: u8,
    padding2: u8,
    padding3: u8,
    keysym: Keysym,
};

pub const TextInputEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    text: [TEXTINPUTEVENT_TEXT_SIZE]u8,
};

pub const MouseMotionEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    state: u32,
    x: i32,
    y: i32,
    xrel: i32,
    yrel: i32,
};

pub const MouseButtonEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    button: u8,
    state: u8,
    clicks: u8,
    padding1: u8,
    x: i32,
    y: i32,
};

pub const MouseWheelEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    x: i32,
    y: i32,
    direction: u32,
    precise_x: f32,
    precise_y: f32,
    mouse_x: i32,
    mouse_y: i32,
};

pub const ControllerAxisEvent = extern struct {
    type: u32,
    timestamp: u32,
    which: JoystickID,
    axis: u8,
    padding1: u8,
    padding2: u8,
    padding3: u8,
    value: i16,
    padding4: u16,
};

pub const ControllerButtonEvent = extern struct {
    type: u32,
    timestamp: u32,
    which: JoystickID,
    button: u8,
    state: u8,
    padding1: u8,
    padding2: u8,
};

pub const ControllerDeviceEvent = extern struct {
    type: u32,
    timestamp: u32,
    /// The device index for ADDED, the instance id for REMOVED.
    which: i32,
};

/// `SDL_Event`: 56 bytes, 8-byte aligned. The `raw` member sets the size and the alignment, and
/// covers the variants that the host does not read.
pub const Event = extern union {
    type: u32,
    common: CommonEvent,
    window: WindowEvent,
    key: KeyboardEvent,
    text: TextInputEvent,
    motion: MouseMotionEvent,
    button: MouseButtonEvent,
    wheel: MouseWheelEvent,
    caxis: ControllerAxisEvent,
    cbutton: ControllerButtonEvent,
    cdevice: ControllerDeviceEvent,
    raw: [7]u64,
};

pub extern "c" fn SDL_PollEvent(event: *Event) c_int;
pub extern "c" fn SDL_StartTextInput() void;
pub extern "c" fn SDL_StopTextInput() void;

// --- mouse -----------------------------------------------------------------------------------

pub extern "c" fn SDL_SetRelativeMouseMode(enabled: Bool) c_int;
pub extern "c" fn SDL_ShowCursor(toggle: c_int) c_int;
/// `SDL_DISABLE` and `SDL_ENABLE`: the two `SDL_ShowCursor` arguments that the backend uses.
pub const CURSOR_DISABLE: c_int = 0;
pub const CURSOR_ENABLE: c_int = 1;
/// The two control-key bits of a keysym's modifier field (`KMOD_LCTRL | KMOD_RCTRL`).
pub const KMOD_CTRL: u16 = 0x0040 | 0x0080;
pub extern "c" fn SDL_GetRelativeMouseMode() Bool;
pub extern "c" fn SDL_GetMouseState(x: ?*c_int, y: ?*c_int) u32;

// --- game controllers ------------------------------------------------------------------------

pub extern "c" fn SDL_GameControllerOpen(joystick_index: c_int) ?*GameController;
pub extern "c" fn SDL_GameControllerClose(controller: *GameController) void;
pub extern "c" fn SDL_GameControllerFromInstanceID(id: JoystickID) ?*GameController;
pub extern "c" fn SDL_GameControllerGetJoystick(controller: *GameController) ?*Joystick;
pub extern "c" fn SDL_JoystickInstanceID(joystick: *Joystick) JoystickID;

// --- audio -----------------------------------------------------------------------------------

pub const AudioDeviceID = u32;
pub const AudioFormat = u16;
/// `AUDIO_S16SYS` on a little-endian host: signed 16-bit little-endian samples.
pub const AUDIO_S16: AudioFormat = 0x8010;

pub const AUDIO_ALLOW_FREQUENCY_CHANGE: c_int = 0x00000001;
pub const AUDIO_ALLOW_FORMAT_CHANGE: c_int = 0x00000002;
pub const AUDIO_ALLOW_CHANNELS_CHANGE: c_int = 0x00000004;

pub const AUDIO_STOPPED: c_int = 0;
pub const AUDIO_PLAYING: c_int = 1;
pub const AUDIO_PAUSED: c_int = 2;

pub const AudioCallback = *const fn (userdata: ?*anyopaque, stream: [*]u8, len: c_int) callconv(.c) void;

pub const AudioSpec = extern struct {
    freq: c_int,
    format: AudioFormat,
    channels: u8,
    silence: u8,
    samples: u16,
    padding: u16,
    size: u32,
    callback: ?AudioCallback,
    userdata: ?*anyopaque,
};

pub extern "c" fn SDL_OpenAudioDevice(device: ?[*:0]const u8, iscapture: c_int, desired: *const AudioSpec, obtained: ?*AudioSpec, allowed_changes: c_int) AudioDeviceID;
pub extern "c" fn SDL_CloseAudioDevice(dev: AudioDeviceID) void;
pub extern "c" fn SDL_PauseAudioDevice(dev: AudioDeviceID, pause_on: c_int) void;
pub extern "c" fn SDL_GetAudioDeviceStatus(dev: AudioDeviceID) c_int;
pub extern "c" fn SDL_QueueAudio(dev: AudioDeviceID, data: *const anyopaque, len: u32) c_int;
pub extern "c" fn SDL_GetQueuedAudioSize(dev: AudioDeviceID) u32;
pub extern "c" fn SDL_ClearQueuedAudio(dev: AudioDeviceID) void;
pub extern "c" fn SDL_LockAudioDevice(dev: AudioDeviceID) void;
pub extern "c" fn SDL_UnlockAudioDevice(dev: AudioDeviceID) void;

test "layout: the declared structs match the SDL2 ABI sizes" {
    // The sizes that a C probe printed for the pinned headers.
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Event));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Event));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(AudioSpec));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(RendererInfo));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Keysym));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Rect));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(WindowEvent));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(KeyboardEvent));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(TextInputEvent));
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(MouseMotionEvent));
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(MouseButtonEvent));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(MouseWheelEvent));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(ControllerAxisEvent));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ControllerButtonEvent));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(ControllerDeviceEvent));

    // The sizes alone do not find a reordered field, so the test also checks the offsets that
    // the backend reads against the output of the same probe.
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(KeyboardEvent, "keysym"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(TextInputEvent, "text"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(MouseWheelEvent, "direction"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ControllerDeviceEvent, "which"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ControllerAxisEvent, "value"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(MouseMotionEvent, "xrel"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(MouseButtonEvent, "x"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(WindowEvent, "data1"));
}
