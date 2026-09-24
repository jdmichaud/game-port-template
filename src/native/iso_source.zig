//! `NativeByteSource`: the host part of reading a CD image. The ISO file system is shared code
//! (`src/shared/iso.zig`). This file only answers range reads from a file on disk; a browser host
//! replaces this part with a Blob.
//!
//! The image is never buffered: a 434 MiB CD is read one range at a time, at the offsets that the
//! shared reader asks for.
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;
const iso = gameport.iso;

pub const NativeByteSource = struct {
    io: std.Io,
    file: std.Io.File,
    /// Owned when `open` opened the file; borrowed through `initFile`.
    owns_file: bool,
    /// The size of the image, read once. The shared reader uses it to refuse an extent that goes
    /// past the end of the image.
    size: ?u64,

    pub const OpenError = error{ NotFound, NotAFile, AccessDenied, Io, Canceled };

    /// Opens the image at `path` for reading.
    pub fn open(io: std.Io, path: []const u8) OpenError!NativeByteSource {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            error.IsDir, error.NotDir => error.NotAFile,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.Canceled => error.Canceled,
            else => error.Io,
        };
        errdefer file.close(io);
        const st = file.stat(io) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.Io,
        };
        if (st.kind == .directory) return error.NotAFile;
        return .{ .io = io, .file = file, .owns_file = true, .size = st.size };
    }

    /// Wraps a file that the caller opened and keeps open.
    pub fn initFile(io: std.Io, file: std.Io.File, size: ?u64) NativeByteSource {
        return .{ .io = io, .file = file, .owns_file = false, .size = size };
    }

    pub fn deinit(self: *NativeByteSource) void {
        if (self.owns_file) self.file.close(self.io);
        self.* = undefined;
    }

    /// The bound interface for the shared ISO reader. The interface holds the address of the
    /// source, so the source must outlive it and must not move.
    pub fn byteSource(self: *NativeByteSource) iso.ByteSource {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = iso.ByteSource.VTable{ .read_at = readAt, .length = length };

    fn readAt(ctx: *anyopaque, offset: u64, dst: []u8) platform.AssetError!usize {
        const self: *NativeByteSource = @ptrCast(@alignCast(ctx));
        if (dst.len == 0) return 0;
        if (self.size) |size| {
            if (offset >= size) return 0;
        }
        return self.file.readPositional(self.io, &.{dst}, offset) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            else => error.Io,
        };
    }

    fn length(ctx: *anyopaque) ?u64 {
        const self: *NativeByteSource = @ptrCast(@alignCast(ctx));
        return self.size;
    }
};

/// Whether `path` is a CD image, by its content, not by its name. The ISO 9660 primary volume
/// descriptor starts sector 16 with type 1 and `CD001`. For a directory, a missing file or a
/// shorter file, the result is false; the caller then treats the path as a game directory.
pub fn looksLikeIsoImage(io: std.Io, path: []const u8) bool {
    var source = NativeByteSource.open(io, path) catch return false;
    defer source.deinit();
    var signature: [6]u8 = undefined;
    const n = source.file.readPositional(io, &.{&signature}, iso.sector_size * 16) catch return false;
    if (n < signature.len) return false;
    return signature[0] == 0x01 and std.mem.eql(u8, signature[1..6], "CD001");
}

const contract = @import("contract.zig");

/// Writes the contract fixture as a CD image at `sub_path`.
fn writeFixtureImage(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !void {
    var pattern: [contract.fixture.nested_len]u8 = undefined;
    const image = try iso.buildTestImage(std.testing.allocator, &.{
        .{ .path = contract.fixture.blob_name, .bytes = contract.fixture.blob },
        .{ .path = contract.fixture.empty_name, .bytes = "" },
        .{ .path = contract.fixture.config_name, .bytes = contract.fixture.config },
        .{ .path = contract.fixture.nested_name, .bytes = contract.fixture.nested(&pattern) },
    });
    defer std.testing.allocator.free(image);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = image });
}

test "an ISO image on disk passes the asset contract through the native byte source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixtureImage(io, tmp.dir, "game.iso");
    const file = try tmp.dir.openFile(io, "game.iso", .{});
    defer file.close(io);
    const st = try file.stat(io);
    var bytes = NativeByteSource.initFile(io, file, st.size);
    defer bytes.deinit();
    var source = try iso.IsoAssetSource.init(std.testing.allocator, bytes.byteSource());
    defer source.deinit();
    try contract.assetContract(source.assetSource());
    try std.testing.expectEqual(@as(usize, 0), source.openHandles());
}

test "an image is recognised by its signature, not by its name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeFixtureImage(io, tmp.dir, "not-named-like-an-image");
    try tmp.dir.writeFile(io, .{ .sub_path = "GAME.CFG", .data = "VIDEO=VGA\r\n" });
    try tmp.dir.createDirPath(io, "cdrom.iso");
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..len];
    var full: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    try std.testing.expect(looksLikeIsoImage(io, try std.fmt.bufPrint(&full, "{s}/not-named-like-an-image", .{base})));
    // A short file, a directory called `.iso` and a missing path are not images.
    try std.testing.expect(!looksLikeIsoImage(io, try std.fmt.bufPrint(&full, "{s}/GAME.CFG", .{base})));
    try std.testing.expect(!looksLikeIsoImage(io, try std.fmt.bufPrint(&full, "{s}/cdrom.iso", .{base})));
    try std.testing.expect(!looksLikeIsoImage(io, try std.fmt.bufPrint(&full, "{s}/absent.iso", .{base})));
}

test "the native byte source reports short reads and the end of the image" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "tiny.bin", .data = "0123456789" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    var full: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    var source = try NativeByteSource.open(io, try std.fmt.bufPrint(&full, "{s}/tiny.bin", .{path_buf[0..len]}));
    defer source.deinit();
    const bytes = source.byteSource();
    try std.testing.expectEqual(@as(?u64, 10), bytes.length());
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try bytes.readAt(6, buf[0..8]));
    try std.testing.expectEqualStrings("6789", buf[0..4]);
    try std.testing.expectEqual(@as(usize, 0), try bytes.readAt(10, &buf));
    try std.testing.expectError(error.ShortRead, bytes.readExact(6, buf[0..8]));
    try std.testing.expectError(error.NotFound, NativeByteSource.open(io, "/nonexistent/gameport/image.iso"));
}
