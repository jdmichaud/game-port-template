//! The agent platform: a backend with scripted devices, a controlled clock and captured output. A
//! port drives its game through it to test and to debug without a window: the same input gives the
//! same frames on every machine. A port grows a driver on top of it for its tests (DESIGN.md).
pub const AgentBackend = @import("backend.zig").AgentBackend;

test {
    @import("std").testing.refAllDecls(@This());
}
