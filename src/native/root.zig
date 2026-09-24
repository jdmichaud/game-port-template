//! Native I/O: the `AssetSource` and `Storage` providers over the host file system, the byte source
//! for the shared ISO reader to read a CD image, the command-line options of the native hosts, and
//! the workflow executor, which runs one I/O job at a time through `std.Io`. The agent and SDL
//! executables import this module. The shared `gameport` module never imports it, because the
//! shared module must stay free of host I/O.
pub const directory = @import("directory.zig");
pub const storage = @import("storage.zig");
pub const iso_source = @import("iso_source.zig");
pub const cli = @import("cli.zig");
pub const contract = @import("contract.zig");
pub const executor = @import("executor.zig");

pub const DirectoryAssetSource = directory.DirectoryAssetSource;
pub const DirectoryStorage = storage.DirectoryStorage;
pub const Executor = executor.Executor;
pub const NativeByteSource = iso_source.NativeByteSource;
pub const Providers = cli.Providers;

test {
    @import("std").testing.refAllDecls(@This());
}
