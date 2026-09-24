//! The SDL platform module, of Linux and Windows: the only code that links SDL2.
const std = @import("std");
const gameport = @import("gameport");
pub const c = @import("sdl.zig");
pub const backend = @import("backend.zig");
pub const eventlog = @import("eventlog.zig");
pub const host = @import("host.zig");
pub const SdlBackend = backend.SdlBackend;

test {
    std.testing.refAllDecls(@This());
}

/// The linked SDL2 release, as "major.minor.patch".
pub fn linkedVersion(buf: []u8) []const u8 {
    var v: c.Version = undefined;
    c.SDL_GetVersion(&v);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch unreachable;
}

pub const VersionCheck = struct {
    linked: []const u8,
    pinned: []const u8,
    matches: bool,
};

/// Compares the linked SDL2 release with the release that build.zig recorded: the one that
/// pkg-config reported on Linux, the `sdl2` package's on Windows.
pub fn checkVersion(buf: []u8) VersionCheck {
    const linked = linkedVersion(buf);
    return .{ .linked = linked, .pinned = gameport.version.sdl, .matches = std.mem.eql(u8, linked, gameport.version.sdl) };
}

test "the linked library is an SDL 2 release" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, linkedVersion(&buf), "2."));
}

test "SDL initialises and shuts down without a display" {
    try std.testing.expectEqual(@as(c_int, 0), c.SDL_Init(0));
    c.SDL_Quit();
}
