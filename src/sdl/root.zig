//! The SDL platform module, of Linux and Windows: the only code that links SDL3. `c` is SDL's own
//! API, translated from its headers by build.zig.
const std = @import("std");
pub const c = @import("c");
pub const backend = @import("backend.zig");
pub const eventlog = @import("eventlog.zig");
pub const host = @import("host.zig");
pub const SdlBackend = backend.SdlBackend;

test {
    std.testing.refAllDecls(@This());
}

/// The linked SDL release, as "major.minor.patch".
pub fn linkedVersion(buf: []u8) []const u8 {
    const v = c.SDL_GetVersion();
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ @divTrunc(v, 1_000_000), @mod(@divTrunc(v, 1000), 1000), @mod(v, 1000) }) catch unreachable;
}

test "the linked library is an SDL 3 release" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, linkedVersion(&buf), "3."));
}
