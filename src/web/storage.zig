//! The storage of the browser guest: the game's records in memory, with each
//! save and delete also given to the page, which keeps the records in the browser's storage for
//! its address. The page gives them back at the next load (`add`), before the game starts, so
//! the settings record brings back the player's preferences, resolution and sound.
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;
const Host = @import("host.zig").Host;

pub const PageStorage = struct {
    records: gameport.memory.MemoryStorage,
    host: *const Host,

    pub fn init(gpa: std.mem.Allocator, host: *const Host) PageStorage {
        return .{ .records = gameport.memory.MemoryStorage.init(gpa), .host = host };
    }

    pub fn deinit(self: *PageStorage) void {
        self.records.deinit();
    }

    /// A record that the page kept from an earlier load. The page has it already, so it is not
    /// given back.
    pub fn add(self: *PageStorage, name: []const u8, bytes: []const u8) platform.StorageError!void {
        try self.records.storage().save(name, bytes);
    }

    pub fn storage(self: *PageStorage) platform.Storage {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Storage.VTable{
        .save = save,
        .load = load,
        .list_saves = listSaves,
        .delete_save = deleteSave,
    };

    fn of(ctx: *anyopaque) *PageStorage {
        return @ptrCast(@alignCast(ctx));
    }

    /// The page keeps the record first. A browser that refuses it fails the save, and the record
    /// in memory stays as it was, as `Storage.save` promises.
    fn save(ctx: *anyopaque, name: []const u8, bytes: []const u8) platform.StorageError!void {
        const self = of(ctx);
        if (self.host.storage_save(name.ptr, @intCast(name.len), bytes.ptr, @intCast(bytes.len)) != 1) return error.Io;
        return self.records.storage().save(name, bytes);
    }

    fn load(ctx: *anyopaque, name: []const u8) platform.StorageError!platform.OwnedBytes {
        return of(ctx).records.storage().load(name);
    }

    fn listSaves(ctx: *anyopaque) platform.StorageError!platform.OwnedSaveNames {
        return of(ctx).records.storage().listSaves();
    }

    fn deleteSave(ctx: *anyopaque, name: []const u8) platform.StorageError!void {
        const self = of(ctx);
        if (self.host.storage_delete(name.ptr, @intCast(name.len)) != 1) return error.Io;
        return self.records.storage().deleteSave(name);
    }
};

const testing = std.testing;

/// A page that keeps the last record it was given, and can refuse.
const FakePage = struct {
    var kept_name: [64]u8 = undefined;
    var kept_name_len: usize = 0;
    var kept_bytes: [64]u8 = undefined;
    var kept_len: usize = 0;
    var saves: u32 = 0;
    var deletes: u32 = 0;
    var refuse = false;

    fn reset() void {
        kept_name_len = 0;
        kept_len = 0;
        saves = 0;
        deletes = 0;
        refuse = false;
    }
    fn storageSave(name: [*]const u8, name_len: u32, bytes: [*]const u8, len: u32) u32 {
        if (refuse) return 0;
        saves += 1;
        @memcpy(kept_name[0..name_len], name[0..name_len]);
        kept_name_len = name_len;
        @memcpy(kept_bytes[0..len], bytes[0..len]);
        kept_len = len;
        return 1;
    }
    fn storageDelete(_: [*]const u8, _: u32) u32 {
        if (refuse) return 0;
        deletes += 1;
        return 1;
    }
    fn nowMs() f64 {
        return 0;
    }
    fn setResolution(_: u32, _: u32) void {}
    fn present(_: [*]const u8, _: u32, _: u32, _: u32) void {}
    fn audioOpen(_: u32, _: u32) u32 {
        return 0;
    }
    fn audioQueue(_: [*]const i16, _: u32, _: u32) u32 {
        return 0;
    }
    fn zero() f64 {
        return 0;
    }
    fn state() u32 {
        return 0;
    }
    fn noop() void {}
    fn relative(_: u32) u32 {
        return 0;
    }
    fn log(_: u32, _: [*]const u8, _: u32) void {}

    const host = Host{
        .now_ms = nowMs,
        .set_resolution = setResolution,
        .present = present,
        .audio_open = audioOpen,
        .audio_queue = audioQueue,
        .audio_queued = zero,
        .audio_state = state,
        .audio_clear = noop,
        .audio_close = noop,
        .set_relative_mouse = relative,
        .log = log,
        .storage_save = storageSave,
        .storage_delete = storageDelete,
    };
};

test "a save goes to the page and to memory; a record that the page kept is not given back" {
    FakePage.reset();
    var s = PageStorage.init(testing.allocator, &FakePage.host);
    defer s.deinit();
    // At the load, the page gives back what it kept.
    try s.add("SETTINGS.SAV", "kept");
    try testing.expectEqual(@as(u32, 0), FakePage.saves);
    var old = try s.storage().load("SETTINGS.SAV");
    try testing.expectEqualStrings("kept", old.bytes);
    old.deinit();
    // The game saves: the page keeps the new bytes, and memory has them.
    try s.storage().save("SETTINGS.SAV", "new settings");
    try testing.expectEqual(@as(u32, 1), FakePage.saves);
    try testing.expectEqualStrings("SETTINGS.SAV", FakePage.kept_name[0..FakePage.kept_name_len]);
    try testing.expectEqualStrings("new settings", FakePage.kept_bytes[0..FakePage.kept_len]);
    var now = try s.storage().load("SETTINGS.SAV");
    defer now.deinit();
    try testing.expectEqualStrings("new settings", now.bytes);
    // A delete goes to the page too.
    try s.storage().save("GAME0001.SAV", "a game");
    try s.storage().deleteSave("GAME0001.SAV");
    try testing.expectEqual(@as(u32, 1), FakePage.deletes);
    try testing.expectError(error.NotFound, s.storage().load("GAME0001.SAV"));
}

test "a save that the browser refuses fails, and the record in memory stays as it was" {
    FakePage.reset();
    var s = PageStorage.init(testing.allocator, &FakePage.host);
    defer s.deinit();
    try s.storage().save("SETTINGS.SAV", "first");
    FakePage.refuse = true;
    try testing.expectError(error.Io, s.storage().save("SETTINGS.SAV", "second"));
    try testing.expectError(error.Io, s.storage().deleteSave("SETTINGS.SAV"));
    var kept = try s.storage().load("SETTINGS.SAV");
    defer kept.deinit();
    try testing.expectEqualStrings("first", kept.bytes);
    // A name that the game could not store is refused before the page sees it.
    FakePage.refuse = false;
    try testing.expectError(error.InvalidName, s.storage().save("../x", "y"));
    try testing.expectEqual(@as(u32, 1), FakePage.saves);
}
