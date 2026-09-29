//! The command-line options that both native hosts take and open for the game: a positional
//! asset path and `--saves <dir>`.
//!
//! The asset path is the directory of the original's files. A port whose original ships on a CD
//! adds an image reader beside `DirectoryAssetSource` (DESIGN.md). `--saves` defaults to the per-user application data directory, which
//! is created on first use. The result is a bound `AssetSource` and `Storage`. The game uses
//! them and does not know which kind of source it has.
const std = @import("std");
const builtin = @import("builtin");
const gameport = @import("gameport");
const platform = gameport.platform;
const DirectoryAssetSource = @import("directory.zig").DirectoryAssetSource;
const DirectoryStorage = @import("storage.zig").DirectoryStorage;

pub const usage =
    \\  ASSET_PATH    the directory of the original's files
    \\  --saves DIR    where saves are kept (default: the per-user application data directory)
    \\
;

pub const TakeError = error{ MissingValue, DuplicateAssets };

pub const Options = struct {
    assets: ?[]const u8 = null,
    saves: ?[]const u8 = null,

    /// Consumes `--saves` and the single positional asset path. Returns false for
    /// any other argument. After `--`, an asset path can start with a dash.
    pub fn take(self: *Options, arg: []const u8, args: anytype) TakeError!bool {
        if (std.mem.eql(u8, arg, "--saves")) {
            const value = args.next() orelse return error.MissingValue;
            if (value.len == 0) return error.MissingValue;
            self.saves = value;
            return true;
        }
        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |path| try self.setAsset(path);
            return true;
        }
        if (arg.len == 0 or arg[0] != '-') {
            try self.setAsset(arg);
            return true;
        }
        return false;
    }

    fn setAsset(self: *Options, path: []const u8) error{ MissingValue, DuplicateAssets }!void {
        if (path.len == 0) return error.MissingValue;
        if (self.assets != null) return error.DuplicateAssets;
        self.assets = path;
    }
};

/// The kind of asset source, for the host's start-up line and the agent's diagnostics.
pub const AssetKind = enum { none, directory };

pub const OpenError = error{
    NotFound,
    NotADirectory,
    AccessDenied,
    NoApplicationDirectory,
    Io,
    Canceled,
    OutOfMemory,
};

/// The providers that a host owns while the game runs.
pub const Providers = struct {
    allocator: std.mem.Allocator = undefined,
    kind: AssetKind = .none,
    /// The save directory in use (owned).
    saves_path: []u8 = &.{},
    assets_directory: ?DirectoryAssetSource = null,
    saves: ?DirectoryStorage = null,

    pub const empty: Providers = .{};

    /// Opens the save directory, and creates it if it does not exist. If the options give an
    /// asset path, also opens the asset source at that path.
    pub fn open(
        self: *Providers,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        options: Options,
    ) OpenError!void {
        self.allocator = allocator;
        errdefer self.deinit();
        self.saves_path = if (options.saves) |path|
            try allocator.dupe(u8, path)
        else
            try defaultSaveDirectory(allocator, environ);
        self.saves = try mapOpen(DirectoryStorage.open(allocator, io, self.saves_path, true));
        const path = options.assets orelse return;
        self.assets_directory = try mapOpen(DirectoryAssetSource.open(allocator, io, path));
        self.kind = .directory;
    }

    fn mapOpen(result: anytype) OpenError!@typeInfo(@TypeOf(result)).error_union.payload {
        return result catch |err| switch (err) {
            error.NotFound => error.NotFound,
            error.NotADirectory => error.NotADirectory,
            error.AccessDenied => error.AccessDenied,
            error.Canceled => error.Canceled,
            error.Io => error.Io,
        };
    }

    pub fn deinit(self: *Providers) void {
        if (self.assets_directory) |*d| d.deinit();
        if (self.saves) |*s| s.deinit();
        self.allocator.free(self.saves_path);
        self.* = .empty;
    }

    /// The bound asset source. Null when the host has no asset path and uses its own assets.
    pub fn assetSource(self: *Providers) ?platform.AssetSource {
        return switch (self.kind) {
            .none => null,
            .directory => self.assets_directory.?.assetSource(),
        };
    }

    pub fn storage(self: *Providers) platform.Storage {
        return self.saves.?.storage();
    }
};

/// The per-user application data directory for the gameport saves:
/// `$XDG_DATA_HOME/gameport/saves`, else `$HOME/.local/share/gameport/saves`, and
/// `%APPDATA%\gameport\saves` on Windows. The caller owns the result.
pub fn defaultSaveDirectory(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) OpenError![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = environ.get("APPDATA") orelse return error.NoApplicationDirectory;
        if (appdata.len == 0) return error.NoApplicationDirectory;
        return std.fmt.allocPrint(allocator, "{s}\\gameport\\saves", .{appdata}) catch return error.OutOfMemory;
    }
    if (environ.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len != 0) {
            return std.fmt.allocPrint(allocator, "{s}/gameport/saves", .{data_home}) catch return error.OutOfMemory;
        }
    }
    const home = environ.get("HOME") orelse return error.NoApplicationDirectory;
    if (home.len == 0) return error.NoApplicationDirectory;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/gameport/saves", .{home}) catch return error.OutOfMemory;
}

const contract = @import("contract.zig");

fn testEnviron(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "the save directory follows the platform's application data convention" {
    const allocator = std.testing.allocator;
    {
        var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/data" }});
        defer env.deinit();
        if (builtin.os.tag == .windows) {
            // Windows reads %APPDATA% only.
            try std.testing.expectError(error.NoApplicationDirectory, defaultSaveDirectory(allocator, &env));
        } else {
            const path = try defaultSaveDirectory(allocator, &env);
            defer allocator.free(path);
            try std.testing.expectEqualStrings("/data/gameport/saves", path);
        }
    }
    {
        var env = try testEnviron(allocator, &.{ .{ "HOME", "/home/player" }, .{ "APPDATA", "C:\\Users\\player\\AppData\\Roaming" } });
        defer env.deinit();
        const path = try defaultSaveDirectory(allocator, &env);
        defer allocator.free(path);
        const want = if (builtin.os.tag == .windows)
            "C:\\Users\\player\\AppData\\Roaming\\gameport\\saves"
        else
            "/home/player/.local/share/gameport/saves";
        try std.testing.expectEqualStrings(want, path);
    }
    {
        var env = try testEnviron(allocator, &.{});
        defer env.deinit();
        try std.testing.expectError(error.NoApplicationDirectory, defaultSaveDirectory(allocator, &env));
    }
}

test "the options open a game directory, or none" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.createDirPath(io, "game");
    var game_dir = try tmp.dir.openDir(io, "game", .{ .iterate = true });
    defer game_dir.close(io);
    try @import("directory.zig").writeFixture(io, game_dir);

    var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/unused" }});
    defer env.deinit();
    var paths: [2][]u8 = undefined;
    inline for (.{ "game", "saves" }, 0..) |sub, i| {
        paths[i] = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, sub });
    }
    defer for (paths) |p| allocator.free(p);

    // A game directory: the asset source passes the contract, and the storage keeps a record.
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, .{ .assets = paths[0], .saves = paths[1] });
        defer providers.deinit();
        try std.testing.expect(providers.kind != .none);
        try contract.assetContract(providers.assetSource().?);
        const s = providers.storage();
        try s.save("CLI.PT", "position");
        var loaded = try s.load("CLI.PT");
        defer loaded.deinit();
        try std.testing.expectEqualStrings("position", loaded.bytes);
        try s.deleteSave("CLI.PT");
    }

    // Without an asset path, only the save directory opens, and `open` creates it.
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, .{ .saves = paths[1] });
        defer providers.deinit();
        try std.testing.expectEqual(AssetKind.none, providers.kind);
        try std.testing.expect(providers.assetSource() == null);
        var names = try providers.storage().listSaves();
        names.deinit();
        try std.testing.expectEqualStrings(paths[1], providers.saves_path);
    }

    // A path that is missing, or not a directory.
    {
        var providers: Providers = .empty;
        const missing = try std.fmt.allocPrint(allocator, "{s}/absent", .{base});
        defer allocator.free(missing);
        try std.testing.expectError(error.NotFound, providers.open(allocator, io, &env, .{ .assets = missing, .saves = paths[1] }));
        const not_a_directory = try std.fmt.allocPrint(allocator, "{s}/game/game.cfg", .{base});
        defer allocator.free(not_a_directory);
        try std.testing.expectError(error.NotADirectory, providers.open(allocator, io, &env, .{ .assets = not_a_directory, .saves = paths[1] }));
    }
}
