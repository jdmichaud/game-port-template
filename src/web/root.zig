//! The parts of the browser build that run without a browser: the key table, the storage and the
//! backend over a table of page functions. The unit tests build them for the native target;
//! `main.zig` builds them into the WebAssembly module.
pub const keys = @import("keys.zig");
pub const host = @import("host.zig");
pub const backend = @import("backend.zig");
pub const storage = @import("storage.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
