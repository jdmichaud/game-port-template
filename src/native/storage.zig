//! `DirectoryStorage`: the `Storage` contract over an application data directory. A record is a
//! file named by its validated key. `save` writes the bytes to a temporary file in the same
//! directory, syncs it and renames it over the target. Thus a replacement is atomic, and a
//! failure before the rename leaves the previous record intact and no temporary file. Temporary
//! names start with a dot, which no key can do, so they never collide with records and never
//! appear in listings. The single active workflow of the executor serialises the operations on
//! one record, so this type has no locking of its own.
const std = @import("std");
const builtin = @import("builtin");
const gameport = @import("gameport");
const platform = gameport.platform;

pub const DirectoryStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Opened for iteration. Owned when `open` opened it, borrowed through `initDir`.
    dir: std.Io.Dir,
    owns_dir: bool,
    /// Test hook: the next save fails with `error.Io` at this point.
    fail_next: ?Fault = null,
    saves: u64 = 0,

    /// The points in a save where a test can inject a failure.
    pub const Fault = enum {
        /// Before the temporary file exists: nothing is written.
        before_create,
        /// After the bytes are written, before they are synced.
        before_sync,
        /// After the sync, before the rename that commits the replacement.
        before_rename,
    };

    pub const OpenError = error{ NotFound, NotADirectory, AccessDenied, Io, Canceled };

    /// Opens the directory at `path`. With `create`, first creates it if it does not exist.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, create: bool) OpenError!DirectoryStorage {
        if (create) {
            std.Io.Dir.cwd().createDirPath(io, path) catch |err| return switch (err) {
                error.AccessDenied, error.PermissionDenied => error.AccessDenied,
                error.Canceled => error.Canceled,
                error.NotDir => error.NotADirectory,
                else => error.Io,
            };
        }
        const dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            error.NotDir => error.NotADirectory,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.Canceled => error.Canceled,
            else => error.Io,
        };
        return .{ .allocator = allocator, .io = io, .dir = dir, .owns_dir = true };
    }

    /// Wraps a directory that the caller opened with `iterate = true` and keeps open.
    pub fn initDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) DirectoryStorage {
        return .{ .allocator = allocator, .io = io, .dir = dir, .owns_dir = false };
    }

    pub fn deinit(self: *DirectoryStorage) void {
        if (self.owns_dir) self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn storage(self: *DirectoryStorage) platform.Storage {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Storage.VTable{
        .save = save,
        .load = load,
        .list_saves = listSaves,
        .delete_save = deleteSave,
    };

    fn cast(ctx: *anyopaque) *DirectoryStorage {
        return @ptrCast(@alignCast(ctx));
    }

    /// `.<name>.<16 hex digits>.tmp`: never a valid key, unique per attempt.
    const temp_suffix = ".tmp";
    const TempName = [1 + platform.max_name_len + 1 + 16 + temp_suffix.len]u8;

    fn tempName(self: *DirectoryStorage, name: []const u8, buf: *TempName) []const u8 {
        var random: [8]u8 = undefined;
        self.io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        return std.fmt.bufPrint(buf, ".{s}.{s}{s}", .{ name, &hex, temp_suffix }) catch unreachable;
    }

    fn takeFault(self: *DirectoryStorage, at: Fault) platform.StorageError!void {
        if (self.fail_next == at) {
            self.fail_next = null;
            return error.Io;
        }
    }

    fn save(ctx: *anyopaque, name: []const u8, bytes: []const u8) platform.StorageError!void {
        const self = cast(ctx);
        const io = self.io;
        platform.validateName(name) catch return error.InvalidName;
        try self.takeFault(.before_create);
        var temp_buf: TempName = undefined;
        const temp = self.tempName(name, &temp_buf);
        const file = self.dir.createFile(io, temp, .{ .exclusive = true }) catch |err| return mapError(err);
        var file_open = true;
        // Until the rename commits, any exit removes the temporary and keeps the old record.
        var committed = false;
        defer if (!committed) {
            if (file_open) file.close(io);
            self.dir.deleteFile(io, temp) catch {};
        };
        file.writeStreamingAll(io, bytes) catch |err| return mapError(err);
        try self.takeFault(.before_sync);
        file.sync(io) catch |err| return mapError(err);
        file.close(io);
        file_open = false;
        try self.takeFault(.before_rename);
        self.dir.rename(temp, self.dir, name, io) catch |err| return mapError(err);
        committed = true;
        self.syncDirectory();
        self.saves += 1;
    }

    /// Writes the directory entry to disk, so the rename is durable. This is best effort: the
    /// data is synced and the rename is done. A failure here leaves the record replaced, with a
    /// slightly longer window for loss at a power failure.
    fn syncDirectory(self: *DirectoryStorage) void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        const as_file = std.Io.File{ .handle = self.dir.handle, .flags = .{ .nonblocking = false } };
        as_file.sync(self.io) catch {};
    }

    fn load(ctx: *anyopaque, name: []const u8) platform.StorageError!platform.OwnedBytes {
        const self = cast(ctx);
        const io = self.io;
        platform.validateName(name) catch return error.InvalidName;
        const file = self.dir.openFile(io, name, .{}) catch |err| return mapError(err);
        defer file.close(io);
        const st = file.stat(io) catch |err| return mapError(err);
        if (st.kind == .directory) return error.NotFound;
        if (st.size > std.math.maxInt(usize)) return error.Io;
        const len: usize = @intCast(st.size);
        const buf = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
        errdefer self.allocator.free(buf);
        const got = file.readPositionalAll(io, buf, 0) catch |err| return mapError(err);
        if (got != len) return error.Io;
        return .{ .bytes = buf, .allocator = self.allocator };
    }

    fn listSaves(ctx: *anyopaque) platform.StorageError!platform.OwnedSaveNames {
        const self = cast(ctx);
        const io = self.io;
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        // Enumerate through a handle that is open for this listing only. A file system can cache
        // the entries per handle (sshfs does). The provider's own handle then shows the state of
        // the first listing, without the later saves.
        var scan = self.dir.openDir(io, ".", .{ .iterate = true }) catch |err| return mapError(err);
        defer scan.close(io);
        var iter = scan.iterate();
        while (iter.next(io) catch |err| return mapError(err)) |entry| {
            platform.validateName(entry.name) catch continue;
            const kind = switch (entry.kind) {
                .file, .directory => entry.kind,
                else => (self.dir.statFile(io, entry.name, .{}) catch continue).kind,
            };
            if (kind != .file) continue;
            const copy = self.allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            names.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
        }
        std.mem.sort([]const u8, names.items, {}, platform.assetNameLessThan);
        const slice = names.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        return .{ .names = slice, .allocator = self.allocator };
    }

    fn deleteSave(ctx: *anyopaque, name: []const u8) platform.StorageError!void {
        const self = cast(ctx);
        platform.validateName(name) catch return error.InvalidName;
        self.dir.deleteFile(self.io, name) catch |err| return mapError(err);
        self.syncDirectory();
    }
};

fn mapError(err: anyerror) platform.StorageError {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => error.NotFound,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

const contract = @import("contract.zig");

fn injectFault(ctx: *anyopaque, fault: contract.Fault) void {
    const store: *DirectoryStorage = @ptrCast(@alignCast(ctx));
    store.fail_next = switch (fault) {
        .before_create => .before_create,
        .before_sync => .before_sync,
        .before_rename => .before_rename,
    };
}

/// Counts the host entries of `dir` through a new handle: all entries, or only the temporary
/// files of a save in progress (their names start with a dot).
fn hostEntries(io: std.Io, dir: std.Io.Dir, only_temporaries: bool) !usize {
    var scan = try dir.openDir(io, ".", .{ .iterate = true });
    defer scan.close(io);
    var n: usize = 0;
    var it = scan.iterate();
    while (try it.next(io)) |entry| {
        if (only_temporaries and entry.name[0] != '.') continue;
        n += 1;
    }
    return n;
}

test "directory storage passes the contract with atomic replacement" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = DirectoryStorage.initDir(std.testing.allocator, io, tmp.dir);
    defer store.deinit();
    try contract.storageContract(store.storage(), .{ .context = &store, .inject = injectFault });
    // Four records remain (BIG, E, SAVE1, Z), and no temporary file remains after a failed save.
    try std.testing.expectEqual(@as(usize, 4), try hostEntries(io, tmp.dir, false));
    // SAVE1 twice, Z, A, E, BIG and the SAVE1 written after the three injected failures.
    try std.testing.expectEqual(@as(u64, 7), store.saves);
}

test "directory storage ignores leftovers and opens or creates its directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..len];
    const sub = try std.fmt.allocPrint(std.testing.allocator, "{s}/saves/nested", .{base});
    defer std.testing.allocator.free(sub);
    try std.testing.expectError(error.NotFound, DirectoryStorage.open(std.testing.allocator, io, sub, false));
    var store = try DirectoryStorage.open(std.testing.allocator, io, sub, true);
    defer store.deinit();
    const s = store.storage();
    try s.save("GAME0001.PT", "pos");
    // The temporary file of an interrupted save, a dot file and a directory are not records.
    try store.dir.writeFile(io, .{ .sub_path = ".GAME0001.PT.0123456789abcdef.tmp", .data = "half" });
    try store.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    try store.dir.createDirPath(io, "FOLDER");
    var names = try s.listSaves();
    defer names.deinit();
    try std.testing.expectEqual(@as(usize, 1), names.names.len);
    try std.testing.expectEqualStrings("GAME0001.PT", names.names[0]);
    try std.testing.expectError(error.NotFound, s.load("FOLDER"));
}

fn directoryStorageUnderAllocator(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var store = DirectoryStorage.initDir(allocator, std.testing.io, dir);
    defer store.deinit();
    try contract.exerciseStorage(store.storage());
}

test "directory storage survives every allocation failure without leaking" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, directoryStorageUnderAllocator, .{tmp.dir});
    // The last run of the sweep fails at its last allocation, so its record can remain. A
    // temporary file must never remain after a failed save.
    try std.testing.expectEqual(@as(usize, 0), try hostEntries(io, tmp.dir, true));
}
