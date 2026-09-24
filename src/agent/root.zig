//! The agent platform: a backend with scripted devices, a controlled clock and captured output, and
//! the JSON host that drives the game through it.
pub const AgentBackend = @import("backend.zig").AgentBackend;
pub const host = @import("host.zig");
pub const Host = host.Host;

test {
    @import("std").testing.refAllDecls(@This());
}
