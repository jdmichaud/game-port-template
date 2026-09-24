//! `DirectoryAssetSource`: the `AssetSource` contract over a host directory.
//!
//! Logical names follow the shared rules (`platform.validateAssetName`): ASCII, with directory
//! components separated by `/`. Matching against the host entries is DOS-style, that is ASCII
//! case-insensitive: `game.cfg` opens `GAME.CFG`, and `GAME.CFG` opens `game.cfg`. An entry with
//! the exact case wins over a case-insensitive match. Host paths keep their platform encoding;
//! only the logical names are ASCII. An entry whose host name is not a valid logical name (a
//! leading dot, a space, non-ASCII bytes) is invisible: it cannot be listed or opened.
//!
//! Listings are recursive, canonical (upper case) and sorted. The prefix is matched
//! case-insensitively against the whole logical name (`DATA/` lists that directory).
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;

pub const DirectoryAssetSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Opened for iteration. Owned when `open` opened it, borrowed through `initDir`.
    dir: std.Io.Dir,
    owns_dir: bool,
    /// Open handles by slot. A handle is the slot index plus one, so a handle is never zero.
    handles: std.ArrayList(?Handle) = .empty,
    /// The maximum number of bytes per `read_at` (0 = no limit). Tests use it to exercise the
    /// short-read loop of `readAll`.
    max_read: usize = 0,

    const Handle = struct {
        file: std.Io.File,
        length: u64,
    };

    pub const OpenError = error{ NotFound, NotADirectory, AccessDenied, Io, Canceled };

    /// Opens the directory at `path`, which is absolute or relative to the working directory.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) OpenError!DirectoryAssetSource {
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
    pub fn initDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) DirectoryAssetSource {
        return .{ .allocator = allocator, .io = io, .dir = dir, .owns_dir = false };
    }

    /// Closes each handle that is still open, and the directory if the source owns it. The game
    /// closes its own handles; this is a safety net.
    pub fn deinit(self: *DirectoryAssetSource) void {
        for (self.handles.items) |slot| {
            if (slot) |h| h.file.close(self.io);
        }
        self.handles.deinit(self.allocator);
        if (self.owns_dir) self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn openHandles(self: *const DirectoryAssetSource) usize {
        var n: usize = 0;
        for (self.handles.items) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    pub fn assetSource(self: *DirectoryAssetSource) platform.AssetSource {
        return .{ .context = self, .vtable = &vtable, .allocator = self.allocator };
    }

    const vtable = platform.AssetSource.VTable{
        .open = openAsset,
        .read_at = readAt,
        .list = list,
        .close = close,
    };

    fn cast(ctx: *anyopaque) *DirectoryAssetSource {
        return @ptrCast(@alignCast(ctx));
    }

    fn openAsset(ctx: *anyopaque, path: []const u8) platform.AssetError!platform.OpenedAsset {
        const self = cast(ctx);
        platform.validateAssetName(path) catch return error.InvalidName;
        const file = try self.resolve(path);
        errdefer file.close(self.io);
        const st = file.stat(self.io) catch |err| return mapError(err);
        if (st.kind == .directory) return error.NotFound;
        const slot = try self.allocateSlot();
        self.handles.items[slot] = .{ .file = file, .length = st.size };
        return .{ .handle = @fromBackingInt(@intCast(@as(u32, @intCast(slot + 1)))), .length = st.size };
    }

    fn allocateSlot(self: *DirectoryAssetSource) platform.AssetError!usize {
        for (self.handles.items, 0..) |slot, i| {
            if (slot == null) return i;
        }
        self.handles.append(self.allocator, null) catch return error.OutOfMemory;
        return self.handles.items.len - 1;
    }

    /// Walks the components of the logical name and matches each one case-insensitively.
    fn resolve(self: *DirectoryAssetSource, path: []const u8) platform.AssetError!std.Io.File {
        const io = self.io;
        var dir = self.dir;
        var owned_dir = false;
        defer if (owned_dir) dir.close(io);
        var it = std.mem.splitScalar(u8, path, platform.asset_separator);
        while (it.next()) |component| {
            const last = it.peek() == null;
            var name_buf: [platform.max_name_len]u8 = undefined;
            const host_name = try self.matchEntry(dir, component, if (last) .file else .directory, &name_buf);
            if (last) {
                return dir.openFile(io, host_name, .{}) catch |err| return mapError(err);
            }
            const next = dir.openDir(io, host_name, .{ .iterate = true }) catch |err| return mapError(err);
            if (owned_dir) dir.close(io);
            dir = next;
            owned_dir = true;
        }
        unreachable;
    }

    const Want = enum { file, directory };

    /// Finds the host entry that `component` names: the exact spelling first, else the first
    /// case-insensitive match in byte order. Returns the host name (copied into `buf`).
    fn matchEntry(self: *DirectoryAssetSource, dir: std.Io.Dir, component: []const u8, want: Want, buf: *[platform.max_name_len]u8) platform.AssetError![]const u8 {
        const io = self.io;
        if (dir.statFile(io, component, .{})) |st| {
            const ok = switch (want) {
                .file => st.kind != .directory,
                .directory => st.kind == .directory,
            };
            if (ok) return component;
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return mapError(err),
        }
        var found: ?[]const u8 = null;
        var scan = try iterable(io, dir);
        defer scan.close(io);
        var iter = scan.iterate();
        while (iter.next(io) catch |err| return mapError(err)) |entry| {
            if (entry.name.len != component.len or entry.name.len > buf.len) continue;
            if (!platform.assetNameEql(entry.name, component)) continue;
            if (found) |f| {
                if (!std.mem.lessThan(u8, entry.name, f)) continue;
            }
            const kind = self.entryKind(dir, entry) orelse continue;
            const ok = switch (want) {
                .file => kind != .directory,
                .directory => kind == .directory,
            };
            if (!ok) continue;
            @memcpy(buf[0..entry.name.len], entry.name);
            found = buf[0..entry.name.len];
        }
        return found orelse error.NotFound;
    }

    /// A handle on `dir`, opened for one walk and closed after it. The provider never enumerates
    /// a directory through a handle that it keeps. A file system can cache the entries per
    /// handle (sshfs does: a second pass shows the state of the first pass). A listing after a
    /// save or an install is then stale. A new handle for each walk costs one syscall pair and
    /// always shows the current directory.
    fn iterable(io: std.Io, dir: std.Io.Dir) platform.AssetError!std.Io.Dir {
        return dir.openDir(io, ".", .{ .iterate = true }) catch |err| return mapError(err);
    }

    /// The kind of the entry, after symbolic links. Null when the kind is not known.
    fn entryKind(self: *DirectoryAssetSource, dir: std.Io.Dir, entry: std.Io.Dir.Entry) ?std.Io.File.Kind {
        switch (entry.kind) {
            .file, .directory => return entry.kind,
            else => {
                const st = dir.statFile(self.io, entry.name, .{}) catch return null;
                return st.kind;
            },
        }
    }

    fn readAt(ctx: *anyopaque, file: platform.AssetHandle, offset: u64, dst: []u8) platform.AssetError!usize {
        const self = cast(ctx);
        const h = self.lookup(file) orelse return error.InvalidHandle;
        if (dst.len == 0) return 0;
        if (offset >= h.length) return 0;
        var n = dst.len;
        if (self.max_read != 0) n = @min(n, self.max_read);
        const remaining = h.length - offset;
        if (remaining < n) n = @intCast(remaining);
        return h.file.readPositional(self.io, &.{dst[0..n]}, offset) catch |err| return mapError(err);
    }

    fn lookup(self: *DirectoryAssetSource, file: platform.AssetHandle) ?Handle {
        const raw = @backingInt(file);
        if (raw == 0 or raw > self.handles.items.len) return null;
        return self.handles.items[raw - 1];
    }

    fn close(ctx: *anyopaque, file: platform.AssetHandle) void {
        const self = cast(ctx);
        const raw = @backingInt(file);
        if (raw == 0 or raw > self.handles.items.len) return;
        if (self.handles.items[raw - 1]) |h| h.file.close(self.io);
        self.handles.items[raw - 1] = null;
    }

    fn list(ctx: *anyopaque, prefix: []const u8) platform.AssetError!platform.OwnedAssetEntries {
        const self = cast(ctx);
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        var logical: [platform.max_asset_name_len]u8 = undefined;
        try self.walk(self.dir, &logical, 0, 1, prefix, &names);
        std.mem.sort([]const u8, names.items, {}, platform.assetNameLessThan);
        const slice = names.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        return .{ .names = slice, .allocator = self.allocator };
    }

    /// Appends the canonical logical names under `dir` that match `prefix`. The logical prefix
    /// of `dir` is `logical[0..used]`.
    fn walk(self: *DirectoryAssetSource, dir: std.Io.Dir, logical: *[platform.max_asset_name_len]u8, used: usize, depth: usize, prefix: []const u8, names: *std.ArrayList([]const u8)) platform.AssetError!void {
        const io = self.io;
        var scan = try iterable(io, dir);
        defer scan.close(io);
        var iter = scan.iterate();
        while (iter.next(io) catch |err| return mapError(err)) |entry| {
            platform.validateName(entry.name) catch continue;
            if (used + entry.name.len > logical.len) continue;
            const kind = self.entryKind(dir, entry) orelse continue;
            const full = logical[0 .. used + entry.name.len];
            _ = platform.canonicalAssetName(entry.name, logical[used..][0..entry.name.len]);
            switch (kind) {
                .directory => {
                    if (depth >= platform.max_asset_depth or full.len + 1 >= logical.len) continue;
                    var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => continue,
                    };
                    defer sub.close(io);
                    logical[full.len] = platform.asset_separator;
                    // The sub-walk overwrites `logical` after `full.len + 1`. The entry's own
                    // name is not used after the sub-walk, so nothing is saved here.
                    try self.walk(sub, logical, full.len + 1, depth + 1, prefix, names);
                },
                .file => {
                    if (!platform.assetNameStartsWith(full, prefix)) continue;
                    const copy = self.allocator.dupe(u8, full) catch return error.OutOfMemory;
                    names.append(self.allocator, copy) catch {
                        self.allocator.free(copy);
                        return error.OutOfMemory;
                    };
                },
                else => {},
            }
        }
    }
};

fn mapError(err: anyerror) platform.AssetError {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => error.NotFound,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

const contract = @import("contract.zig");

/// Writes the contract fixture into `dir`, with mixed host case and an invisible entry.
pub fn writeFixture(io: std.Io, dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = contract.fixture.blob_name, .data = contract.fixture.blob });
    try dir.writeFile(io, .{ .sub_path = contract.fixture.empty_name, .data = "" });
    try dir.writeFile(io, .{ .sub_path = "game.cfg", .data = contract.fixture.config });
    try dir.createDirPath(io, "sub");
    var pattern: [contract.fixture.nested_len]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = "sub/nested.dat", .data = contract.fixture.nested(&pattern) });
    // Not a logical name: it is never listed and never opened.
    try dir.writeFile(io, .{ .sub_path = ".hidden", .data = "x" });
}

test "directory asset source passes the contract over a host directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir);
    var source = DirectoryAssetSource.initDir(std.testing.allocator, io, tmp.dir);
    defer source.deinit();
    try contract.assetContract(source.assetSource());
    try std.testing.expectEqual(@as(usize, 0), source.openHandles());
    // Forced short reads exercise the `readAll` loop on real files.
    source.max_read = 5;
    try contract.assetContract(source.assetSource());
    try std.testing.expectEqual(@as(usize, 0), source.openHandles());
}

test "directory asset source opens a path and closes leaked handles on deinit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    var source = try DirectoryAssetSource.open(std.testing.allocator, io, path_buf[0..len]);
    defer source.deinit();
    const a = source.assetSource();
    _ = try a.open("GAME.CFG");
    _ = try a.open("game.CFG");
    try std.testing.expectEqual(@as(usize, 2), source.openHandles());
    try std.testing.expectError(error.NotFound, DirectoryAssetSource.open(std.testing.allocator, io, "/nonexistent/gameport/assets"));
}

fn directoryAssetsUnderAllocator(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var source = DirectoryAssetSource.initDir(allocator, std.testing.io, dir);
    defer source.deinit();
    try contract.exerciseAssets(source.assetSource());
}

test "directory asset source survives every allocation failure without leaking" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, directoryAssetsUnderAllocator, .{tmp.dir});
}
