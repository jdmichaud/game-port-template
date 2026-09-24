//! SHA-256 digests of buffers and files, as raw bytes or as lower-case hex.
const std = @import("std");

pub const Hex = [64]u8;

pub fn sha256Hex(bytes: []const u8) Hex {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return std.fmt.bytesToHex(out, .lower);
}

pub fn sha256(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

pub const max_file_bytes: usize = 512 * 1024 * 1024;

pub const FileError = error{ FileNotFound, Io, OutOfMemory };

/// Reads the full file and returns its digest as hex.
pub fn fileSha256Hex(io: std.Io, gpa: std.mem.Allocator, path: []const u8) FileError!Hex {
    const bytes = readFile(io, gpa, path) catch |err| return err;
    defer gpa.free(bytes);
    return sha256Hex(bytes);
}

/// Reads a whole file, up to `max_file_bytes`.
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) FileError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

test "digest of the empty buffer" {
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &sha256Hex(""));
}
