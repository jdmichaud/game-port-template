//! Pinned toolchain versions, supplied by build.zig.
const build_versions = @import("build_versions");

/// The SDL2 release that the SDL host expects to link against.
pub const sdl: []const u8 = build_versions.sdl;
