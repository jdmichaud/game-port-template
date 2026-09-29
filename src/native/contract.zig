//! The provider contract cases. They use only the interfaces, so each implementation runs the same
//! cases: the in-memory providers, the directory providers, and any source a port adds. A provider
//! test fills its provider with `fixture` and calls `assetContract` or `storageContract`.
//! Allocation-failure sweeps wrap `exerciseAssets` or `exerciseStorage` in
//! `std.testing.checkAllAllocationFailures`.
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The files of every asset provider under test. The provider has no other files.
pub const fixture = struct {
    pub const blob_name = "BLOB.BIN";
    pub const blob = "0123456789abcdef";
    pub const empty_name = "EMPTY.BIN";
    pub const config_name = "GAME.CFG";
    pub const config = "VIDEO=VGA\r\nSOUND=SB16\r\n";
    /// In a subdirectory. Providers can store it in any case (`sub/nested.dat`).
    pub const nested_name = "SUB/NESTED.DAT";
    pub const nested_len = 3000;

    pub fn nested(buf: *[nested_len]u8) []u8 {
        for (buf, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
        return buf;
    }

    /// The canonical listing of the whole fixture.
    pub const listing = [_][]const u8{ blob_name, empty_name, config_name, nested_name };
};

/// Checks short reads and end of file, the `readAll` limits, handle closure, name rules, listing.
pub fn assetContract(a: platform.AssetSource) !void {
    // Open, length, positional reads, end of file.
    const blob = try a.open(fixture.blob_name);
    try expectEqual(@as(u64, fixture.blob.len), blob.length);
    var buf: [8]u8 = undefined;
    try expectEqual(@as(usize, 4), try a.readAt(blob.handle, 0, buf[0..4]));
    try expectEqualStrings("0123", buf[0..4]);
    try expectEqual(@as(usize, 2), try a.readAt(blob.handle, 14, &buf));
    try expectEqualStrings("ef", buf[0..2]);
    try expectEqual(@as(usize, 0), try a.readAt(blob.handle, 16, &buf));
    try expectEqual(@as(usize, 0), try a.readAt(blob.handle, 1 << 40, &buf));
    try expectEqual(@as(usize, 0), try a.readAt(blob.handle, 0, buf[0..0]));

    // Handles are independent: when one closes, the others stay valid. A closed handle is
    // invalid, even if its slot is used again later.
    const second = try a.open(fixture.config_name);
    a.close(blob.handle);
    try expectError(error.InvalidHandle, a.readAt(blob.handle, 0, &buf));
    try expectEqual(@as(usize, 2), try a.readAt(second.handle, 0, buf[0..2]));
    try expectEqualStrings(fixture.config[0..2], buf[0..2]);
    const third = try a.open(fixture.blob_name);
    try expectEqual(@as(usize, 1), try a.readAt(third.handle, 15, buf[0..1]));
    try expectEqual(@as(u8, 'f'), buf[0]);
    a.close(second.handle);
    a.close(third.handle);
    a.close(third.handle); // closing twice is harmless
    try expectError(error.InvalidHandle, a.readAt(@fromBackingInt(0), 0, &buf));
    try expectError(error.InvalidHandle, a.readAt(@fromBackingInt(0xffff), 0, &buf));

    // `readAll`: whole asset, size limit, DOS case matching, subdirectory names.
    var got = try a.readAll("blob.bin", fixture.blob.len);
    try expectEqualStrings(fixture.blob, got.bytes);
    try expectError(error.TooLarge, a.readAll(fixture.blob_name, fixture.blob.len - 1));
    var pattern: [fixture.nested_len]u8 = undefined;
    _ = fixture.nested(&pattern);
    var nested = try a.readAll("sub/nested.dat", 1 << 20);
    defer nested.deinit();
    try std.testing.expectEqualSlices(u8, &pattern, nested.bytes);
    var empty = try a.readAll(fixture.empty_name, 0);
    defer empty.deinit();
    try expectEqual(@as(usize, 0), empty.bytes.len);

    // Names: the rules are shared, a directory is not an asset, components are part of the name.
    try expectError(error.NotFound, a.open("MISSING.BIN"));
    try expectError(error.NotFound, a.open("NESTED.DAT"));
    try expectError(error.NotFound, a.open("SUB"));
    try expectError(error.InvalidName, a.open(""));
    try expectError(error.InvalidName, a.open("../GAME.EXE"));
    try expectError(error.InvalidName, a.open("SUB/"));
    try expectError(error.InvalidName, a.open("/BLOB.BIN"));
    try expectError(error.InvalidName, a.open(".hidden"));
    try expectError(error.NotFound, a.readAll("SUB/MISSING.DAT", 16));

    // Listing: canonical names, sorted, case-insensitive prefix.
    var all = try a.list("");
    defer all.deinit();
    try expectEqual(fixture.listing.len, all.names.len);
    for (fixture.listing, all.names) |want, name| try expectEqualStrings(want, name);
    var subdir = try a.list("sub/");
    defer subdir.deinit();
    try expectEqual(@as(usize, 1), subdir.names.len);
    try expectEqualStrings(fixture.nested_name, subdir.names[0]);
    var none = try a.list("ZZZ");
    defer none.deinit();
    try expectEqual(@as(usize, 0), none.names.len);

    // Later provider activity does not change the owned result.
    try expectEqualStrings(fixture.blob, got.bytes);
    got.deinit();
}

/// A bounded exercise (`readAll`, list, open, read) for allocation-failure sweeps. Each
/// allocation failure must come back as `error.OutOfMemory`, with no leak.
pub fn exerciseAssets(a: platform.AssetSource) !void {
    var got = try a.readAll(fixture.nested_name, 1 << 20);
    defer got.deinit();
    var all = try a.list("");
    defer all.deinit();
    const opened = try a.open(fixture.blob_name);
    defer a.close(opened.handle);
    var buf: [4]u8 = undefined;
    _ = try a.readAt(opened.handle, 0, &buf);
}

/// The points in a save where the harness asks the provider to fail.
pub const Fault = enum { before_create, before_sync, before_rename };

/// How a provider under test injects a failure into its next save.
pub const FaultInjector = struct {
    context: *anyopaque,
    inject: *const fn (*anyopaque, Fault) void,
};

/// Checks round trips, atomic replacement, sorted listing, deletion and the name rules. With an
/// injector, it also checks that a save that fails before the commit keeps the previous record.
pub fn storageContract(s: platform.Storage, faults: ?FaultInjector) !void {
    {
        var names = try s.listSaves();
        defer names.deinit();
        try expectEqual(@as(usize, 0), names.names.len);
    }
    try expectError(error.NotFound, s.load("NOPE"));
    try expectError(error.NotFound, s.deleteSave("NOPE"));

    try s.save("SAVE1", "first");
    {
        var loaded = try s.load("SAVE1");
        defer loaded.deinit();
        try expectEqualStrings("first", loaded.bytes);
    }
    try s.save("SAVE1", "second");
    var kept = try s.load("SAVE1");
    defer kept.deinit();
    try expectEqualStrings("second", kept.bytes);

    try expectError(error.InvalidName, s.save("bad name", "x"));
    try expectError(error.InvalidName, s.save("", "x"));
    try expectError(error.InvalidName, s.save(".tmp", "x"));
    try expectError(error.InvalidName, s.save("a/b", "x"));
    try expectError(error.InvalidName, s.load("../etc"));
    try expectError(error.InvalidName, s.deleteSave("a b"));

    try s.save("Z", "z");
    try s.save("A", "1");
    try s.save("E", "");
    {
        var names = try s.listSaves();
        defer names.deinit();
        try expectEqual(@as(usize, 4), names.names.len);
        try expectEqualStrings("A", names.names[0]);
        try expectEqualStrings("E", names.names[1]);
        try expectEqualStrings("SAVE1", names.names[2]);
        try expectEqualStrings("Z", names.names[3]);
    }
    {
        var empty = try s.load("E");
        defer empty.deinit();
        try expectEqual(@as(usize, 0), empty.bytes.len);
    }
    try s.deleteSave("A");
    try expectError(error.NotFound, s.deleteSave("A"));
    try expectError(error.NotFound, s.load("A"));

    // A large record round trips.
    const big = try std.testing.allocator.alloc(u8, 100 * 1024);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try s.save("BIG", big);
    {
        var loaded = try s.load("BIG");
        defer loaded.deinit();
        try std.testing.expectEqualSlices(u8, big, loaded.bytes);
    }

    // A failed replacement keeps the previous record and leaves no trace in the listing.
    if (faults) |f| {
        for ([_]Fault{ .before_create, .before_sync, .before_rename }) |fault| {
            f.inject(f.context, fault);
            try expectError(error.Io, s.save("SAVE1", "third"));
            var loaded = try s.load("SAVE1");
            defer loaded.deinit();
            try expectEqualStrings("second", loaded.bytes);
            var names = try s.listSaves();
            defer names.deinit();
            try expectEqual(@as(usize, 4), names.names.len);
            try expectEqualStrings("BIG", names.names[0]);
            try expectEqualStrings("E", names.names[1]);
            try expectEqualStrings("SAVE1", names.names[2]);
            try expectEqualStrings("Z", names.names[3]);
        }
        // The store is fully usable after the failures.
        try s.save("SAVE1", "fourth");
        var loaded = try s.load("SAVE1");
        defer loaded.deinit();
        try expectEqualStrings("fourth", loaded.bytes);
    }

    // The later operations do not change the owned load from before.
    try expectEqualStrings("second", kept.bytes);
}

/// A bounded exercise (save, load, list, delete) for allocation-failure sweeps.
pub fn exerciseStorage(s: platform.Storage) !void {
    try s.save("SWEEP", "payload");
    var loaded = try s.load("SWEEP");
    defer loaded.deinit();
    var names = try s.listSaves();
    defer names.deinit();
    try s.deleteSave("SWEEP");
}

fn memoryFault(ctx: *anyopaque, fault: Fault) void {
    const store: *gameport.memory.MemoryStorage = @ptrCast(@alignCast(ctx));
    _ = fault;
    store.fail_next_save = error.Io;
}

test "in-memory asset source passes the contract" {
    var source = gameport.memory.MemoryAssetSource.init(std.testing.allocator);
    defer source.deinit();
    var pattern: [fixture.nested_len]u8 = undefined;
    try source.add(fixture.blob_name, fixture.blob);
    try source.add("sub/nested.dat", fixture.nested(&pattern));
    try source.add(fixture.empty_name, "");
    try source.add(fixture.config_name, fixture.config);
    try assetContract(source.assetSource());
    try expectEqual(@as(u32, 0), source.open_count);
    source.max_read = 7;
    try assetContract(source.assetSource());
}

test "in-memory storage passes the contract" {
    var store = gameport.memory.MemoryStorage.init(std.testing.allocator);
    defer store.deinit();
    try storageContract(store.storage(), .{ .context = &store, .inject = memoryFault });
}

fn memoryAssetsUnderAllocator(allocator: std.mem.Allocator) !void {
    var source = gameport.memory.MemoryAssetSource.init(allocator);
    defer source.deinit();
    var pattern: [fixture.nested_len]u8 = undefined;
    try source.add(fixture.blob_name, fixture.blob);
    try source.add(fixture.nested_name, fixture.nested(&pattern));
    try exerciseAssets(source.assetSource());
}

fn memoryStorageUnderAllocator(allocator: std.mem.Allocator) !void {
    var store = gameport.memory.MemoryStorage.init(allocator);
    defer store.deinit();
    try exerciseStorage(store.storage());
}

test "in-memory providers survive every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, memoryAssetsUnderAllocator, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, memoryStorageUnderAllocator, .{});
}
