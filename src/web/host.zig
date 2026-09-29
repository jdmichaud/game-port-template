//! The functions of the page that the web backend calls. The WebAssembly root fills this table
//! with the functions that `gameport.js` imports into the module. The unit tests fill it with
//! their own functions, so the backend and the transport run without a browser.
//!
//! Only `u32`, `i32`, `f64` and pointers cross the boundary. A 64-bit integer would arrive in
//! JavaScript as a `BigInt`, which the script does not use.

/// The audio state that the page reports.
pub const AudioState = enum(u32) { closed = 0, running = 1, suspended = 2, _ };

pub const Host = struct {
    /// `performance.now()`: milliseconds from the start of the page, monotonic.
    now_ms: *const fn () f64,
    /// The size of the canvas. The page scales it to the window.
    set_resolution: *const fn (width: u32, height: u32) void,
    /// Copies one RGBA frame to the canvas. The page reads the pixels during the call only.
    present: *const fn (pixels: [*]const u8, width: u32, height: u32, stride: u32) void,
    /// Opens the output at `rate` if the browser allows it. Returns the rate that the output
    /// really has, or 0 when there is no output.
    audio_open: *const fn (rate: u32, channels: u32) u32,
    /// Schedules interleaved 16-bit frames after the frames that are already queued. Returns the
    /// number of frames accepted; the page accepts fewer when its queue is full.
    audio_queue: *const fn (samples: [*]const i16, frames: u32, channels: u32) u32,
    /// The frames that the output has not played yet.
    audio_queued: *const fn () f64,
    audio_state: *const fn () u32,
    /// Discards the queued frames.
    audio_clear: *const fn () void,
    audio_close: *const fn () void,
    /// Asks for the pointer lock (1) or releases it (0). Returns 1 when the pointer is locked
    /// now. A browser locks the pointer only after a click, so the page also reports each later
    /// change.
    set_relative_mouse: *const fn (enabled: u32) u32,
    /// Writes one line to the browser's console: 0 error, 1 warning, 2 information, 3 debug.
    log: *const fn (level: u32, text: [*]const u8, len: u32) void,
    /// Keeps one of the game's records in the browser's storage for the page's address. Returns 1
    /// when the record is kept, 0 when the browser refused it (no storage, or a full one).
    storage_save: *const fn (name: [*]const u8, name_len: u32, bytes: [*]const u8, len: u32) u32,
    /// Forgets a record. Returns 1, or 0 when the browser refused.
    storage_delete: *const fn (name: [*]const u8, name_len: u32) u32,
};
