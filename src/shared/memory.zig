//! In-memory providers: an asset source over a name-to-bytes table, and a storage over an owned
//! table. They implement the shared contracts exactly (short reads, end of file, atomic
//! replacement). The agent host, the test runner and the unit tests use them.
const std = @import("std");
const platform = @import("platform.zig");

/// Immutable asset bytes, borrowed for the lifetime of their source.
pub const AssetEntry = struct { name: []const u8, bytes: []const u8 };

pub const MemoryAssetSource = struct {
    allocator: std.mem.Allocator,
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Open handles by slot. Each slot holds an entry index. A handle is the slot plus one, so a
    /// handle is never zero. A closed handle is invalid until its slot is used again.
    handles: std.ArrayList(?usize) = .empty,
    open_count: u32 = 0,
    /// The maximum number of bytes per `read_at`, to test short reads (0 = no limit).
    max_read: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MemoryAssetSource {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryAssetSource) void {
        self.entries.deinit(self.allocator);
        self.handles.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds `bytes` under `name`, a valid logical asset name kept as given. The caller keeps both
    /// alive. Lookups are case-insensitive: for a name that differs from an existing entry only
    /// by case, `add` replaces the bytes of that entry, and the entry keeps its first name.
    pub fn add(self: *MemoryAssetSource, name: []const u8, bytes: []const u8) !void {
        try platform.validateAssetName(name);
        if (self.find(name)) |index| {
            self.entries.values()[index] = bytes;
            return;
        }
        try self.entries.put(self.allocator, name, bytes);
    }

    fn find(self: *const MemoryAssetSource, name: []const u8) ?usize {
        for (self.entries.keys(), 0..) |key, i| {
            if (platform.assetNameEql(key, name)) return i;
        }
        return null;
    }

    pub fn assetSource(self: *MemoryAssetSource) platform.AssetSource {
        return .{ .context = self, .vtable = &vtable, .allocator = self.allocator };
    }

    const vtable = platform.AssetSource.VTable{
        .open = open,
        .read_at = readAt,
        .list = list,
        .close = close,
    };

    fn open(ctx: *anyopaque, path: []const u8) platform.AssetError!platform.OpenedAsset {
        const self: *MemoryAssetSource = @ptrCast(@alignCast(ctx));
        platform.validateAssetName(path) catch return error.InvalidName;
        const index = self.find(path) orelse return error.NotFound;
        var slot: ?usize = null;
        for (self.handles.items, 0..) |h, i| {
            if (h == null) {
                slot = i;
                break;
            }
        }
        if (slot == null) {
            self.handles.append(self.allocator, null) catch return error.OutOfMemory;
            slot = self.handles.items.len - 1;
        }
        self.handles.items[slot.?] = index;
        self.open_count += 1;
        return .{ .handle = @fromBackingInt(@intCast(@as(u32, @intCast(slot.? + 1)))), .length = self.entries.values()[index].len };
    }

    fn readAt(ctx: *anyopaque, file: platform.AssetHandle, offset: u64, dst: []u8) platform.AssetError!usize {
        const self: *MemoryAssetSource = @ptrCast(@alignCast(ctx));
        const raw = @backingInt(file);
        if (raw == 0 or raw > self.handles.items.len) return error.InvalidHandle;
        const index = self.handles.items[raw - 1] orelse return error.InvalidHandle;
        const bytes = self.entries.values()[index];
        if (offset >= bytes.len) return 0;
        const start: usize = @intCast(offset);
        var n = @min(dst.len, bytes.len - start);
        if (self.max_read != 0) n = @min(n, self.max_read);
        @memcpy(dst[0..n], bytes[start..][0..n]);
        return n;
    }

    fn list(ctx: *anyopaque, prefix: []const u8) platform.AssetError!platform.OwnedAssetEntries {
        const self: *MemoryAssetSource = @ptrCast(@alignCast(ctx));
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        for (self.entries.keys()) |key| {
            if (!platform.assetNameStartsWith(key, prefix)) continue;
            const copy = self.allocator.alloc(u8, key.len) catch return error.OutOfMemory;
            _ = platform.canonicalAssetName(key, copy);
            names.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
        }
        std.mem.sort([]const u8, names.items, {}, platform.assetNameLessThan);
        const slice = names.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        return .{ .names = slice, .allocator = self.allocator };
    }

    fn close(ctx: *anyopaque, file: platform.AssetHandle) void {
        const self: *MemoryAssetSource = @ptrCast(@alignCast(ctx));
        const raw = @backingInt(file);
        if (raw == 0 or raw > self.handles.items.len) return;
        if (self.handles.items[raw - 1] == null) return;
        self.handles.items[raw - 1] = null;
        self.open_count -= 1;
    }
};

pub const MemoryStorage = struct {
    allocator: std.mem.Allocator,
    records: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// When set, the next save fails with this error before anything is replaced.
    fail_next_save: ?platform.StorageError = null,
    saves: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) MemoryStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryStorage) void {
        for (self.records.keys(), self.records.values()) |k, v| {
            self.allocator.free(k);
            self.allocator.free(v);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn storage(self: *MemoryStorage) platform.Storage {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Storage.VTable{
        .save = save,
        .load = load,
        .list_saves = listSaves,
        .delete_save = deleteSave,
    };

    fn save(ctx: *anyopaque, name: []const u8, bytes: []const u8) platform.StorageError!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ctx));
        if (self.fail_next_save) |err| {
            self.fail_next_save = null;
            return err;
        }
        // Prepare the full replacement before the existing record changes.
        const copy = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        errdefer self.allocator.free(copy);
        if (self.records.getPtr(name)) |slot| {
            self.allocator.free(slot.*);
            slot.* = copy;
        } else {
            const key = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
            errdefer self.allocator.free(key);
            self.records.put(self.allocator, key, copy) catch return error.OutOfMemory;
        }
        self.saves += 1;
    }

    fn load(ctx: *anyopaque, name: []const u8) platform.StorageError!platform.OwnedBytes {
        const self: *MemoryStorage = @ptrCast(@alignCast(ctx));
        const bytes = self.records.get(name) orelse return error.NotFound;
        const copy = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        return .{ .bytes = copy, .allocator = self.allocator };
    }

    fn listSaves(ctx: *anyopaque) platform.StorageError!platform.OwnedSaveNames {
        const self: *MemoryStorage = @ptrCast(@alignCast(ctx));
        const names = self.allocator.alloc([]const u8, self.records.count()) catch return error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (names[0..filled]) |n| self.allocator.free(n);
            self.allocator.free(names);
        }
        for (self.records.keys()) |key| {
            names[filled] = self.allocator.dupe(u8, key) catch return error.OutOfMemory;
            filled += 1;
        }
        std.mem.sort([]const u8, names, {}, lessThan);
        return .{ .names = names, .allocator = self.allocator };
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn deleteSave(ctx: *anyopaque, name: []const u8) platform.StorageError!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ctx));
        const entry = self.records.fetchOrderedRemove(name) orelse return error.NotFound;
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }
};

test "read_all loops over short reads and closes on every exit" {
    var source = MemoryAssetSource.init(std.testing.allocator);
    defer source.deinit();
    const data = "0123456789abcdef";
    try source.add("BLOB.BIN", data);
    source.max_read = 5;
    const a = source.assetSource();
    var got = try a.readAll("BLOB.BIN", 64);
    defer got.deinit();
    try std.testing.expectEqualStrings(data, got.bytes);
    try std.testing.expectEqual(@as(u32, 0), source.open_count);
    try std.testing.expectError(error.TooLarge, a.readAll("BLOB.BIN", 8));
    try std.testing.expectError(error.NotFound, a.readAll("MISSING.BIN", 8));
    try std.testing.expectError(error.InvalidName, a.readAll("../etc", 8));
    try std.testing.expectEqual(@as(u32, 0), source.open_count);
}

test "listing honours the prefix and is owned" {
    var source = MemoryAssetSource.init(std.testing.allocator);
    defer source.deinit();
    try source.add("GAME0002.PT", "b");
    try source.add("game0001.pt", "a");
    try source.add("SETUP.CFG", "c");
    try source.add("DATA/1_1.MVE", "d");
    var entries = try source.assetSource().list("game");
    defer entries.deinit();
    try std.testing.expectEqual(@as(usize, 2), entries.names.len);
    // Canonical (upper-case) names, sorted.
    try std.testing.expectEqualStrings("GAME0001.PT", entries.names[0]);
    try std.testing.expectEqualStrings("GAME0002.PT", entries.names[1]);
    // DOS-style matching: any case opens the entry. Directory components are part of the name.
    const opened = try source.assetSource().open("Setup.Cfg");
    source.assetSource().close(opened.handle);
    const film = try source.assetSource().open("data/1_1.mve");
    source.assetSource().close(film.handle);
    try std.testing.expectError(error.NotFound, source.assetSource().open("1_1.MVE"));
    try std.testing.expectError(error.InvalidName, source.assetSource().open("DATA/"));
}

test "storage replaces atomically and validates names" {
    var store = MemoryStorage.init(std.testing.allocator);
    defer store.deinit();
    const s = store.storage();
    try s.save("SAVE1", "first");
    store.fail_next_save = error.Io;
    try std.testing.expectError(error.Io, s.save("SAVE1", "second"));
    var loaded = try s.load("SAVE1");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("first", loaded.bytes);
    try std.testing.expectError(error.InvalidName, s.save("bad name", "x"));
    try std.testing.expectError(error.NotFound, s.load("NOPE"));
    try s.save("A", "1");
    var names = try s.listSaves();
    defer names.deinit();
    try std.testing.expectEqual(@as(usize, 2), names.names.len);
    try std.testing.expectEqualStrings("A", names.names[0]);
    try s.deleteSave("A");
    try std.testing.expectError(error.NotFound, s.deleteSave("A"));
}
