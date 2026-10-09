//! The shared module: the platform boundary, the in-memory providers and the game. It links
//! nothing and needs no libc, so the same code builds for the native hosts and for the browser
//! (wasm32-freestanding).
pub const platform = @import("platform.zig");
pub const memory = @import("memory.zig");
pub const game = @import("game.zig");
pub const Game = game.Game;

test {
    @import("std").testing.refAllDecls(@This());
}
