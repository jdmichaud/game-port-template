//! Native I/O: the `AssetSource` and `Storage` providers over the host file system, the contract
//! that every provider passes, and the command-line options of the native hosts. The agent and SDL
//! executables import this module. The shared `gameport` module never imports it, because the
//! shared module must stay free of host I/O.
pub const directory = @import("directory.zig");
pub const storage = @import("storage.zig");
pub const cli = @import("cli.zig");
pub const contract = @import("contract.zig");

pub const DirectoryAssetSource = directory.DirectoryAssetSource;
pub const DirectoryStorage = storage.DirectoryStorage;
pub const Providers = cli.Providers;

test {
    @import("std").testing.refAllDecls(@This());
}
