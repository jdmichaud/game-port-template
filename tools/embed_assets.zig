//! Build-time extraction of the game files that the standalone executable carries: the names in
//! `embedded-assets.txt`, read from a CD image or a game directory. The output is a Zig module
//! that embeds them and a manifest of their sizes and digests. Neither is ever committed.
const std = @import("std");
const gameport = @import("gameport");
const native = @import("native");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const source = args.next() orelse return error.MissingSource;
    const destination = args.next() orelse return error.MissingDestination;
    if (args.next() != null) return error.UnexpectedArgument;

    if (native.iso_source.looksLikeIsoImage(init.io, source)) {
        var bytes = try native.NativeByteSource.open(init.io, source);
        defer bytes.deinit();
        var image = try gameport.iso.IsoAssetSource.init(init.gpa, bytes.byteSource());
        defer image.deinit();
        try pack(init.gpa, init.io, image.assetSource(), destination);
    } else {
        var directory = try native.DirectoryAssetSource.open(init.gpa, init.io, source);
        defer directory.deinit();
        try pack(init.gpa, init.io, directory.assetSource(), destination);
    }
}

fn pack(gpa: std.mem.Allocator, io: std.Io, assets: gameport.platform.AssetSource, destination: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, destination);
    var output = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer output.close(io);

    var module = std.Io.Writer.Allocating.init(gpa);
    defer module.deinit();
    var manifest = std.Io.Writer.Allocating.init(gpa);
    defer manifest.deinit();
    try module.writer.writeAll(
        "// Generated from the game's files. Do not commit this file or its inputs.\n" ++
            "pub const embedded = true;\n" ++
            "pub const entries = [_]@import(\"gameport\").memory.AssetEntry{\n",
    );
    try manifest.writer.writeAll("{\"files\":[\n");
    var names = std.mem.tokenizeAny(u8, @embedFile("embedded-assets.txt"), "\r\n");
    var count: usize = 0;
    var total: u64 = 0;
    while (names.next()) |name| {
        try gameport.platform.validateAssetName(name);
        var data = assets.readAll(name, 4 << 20) catch |err| {
            std.log.err("required embedded asset {s}: {s}", .{ name, @errorName(err) });
            return error.RequiredAssetUnavailable;
        };
        defer data.deinit();
        if (data.bytes.len == 0) {
            std.log.err("required embedded asset {s} is empty", .{name});
            return error.RequiredAssetUnavailable;
        }
        const path = try std.fmt.allocPrint(gpa, "files/{s}", .{name});
        defer gpa.free(path);
        if (std.fs.path.dirname(path)) |dir| try output.createDirPath(io, dir);
        try output.writeFile(io, .{ .sub_path = path, .data = data.bytes });
        try module.writer.print("    .{{ .name = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ name, path });
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data.bytes, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        if (count != 0) try manifest.writer.writeAll(",\n");
        try manifest.writer.print("  {{\"name\":\"{s}\",\"bytes\":{d},\"sha256\":\"{s}\"}}", .{ name, data.bytes.len, hex });
        count += 1;
        total += data.bytes.len;
    }
    try module.writer.writeAll("};\n");
    try manifest.writer.print("\n],\"file_count\":{d},\"total_bytes\":{d}}}\n", .{ count, total });
    try output.writeFile(io, .{ .sub_path = "assets.zig", .data = module.written() });
    try output.writeFile(io, .{ .sub_path = "manifest.json", .data = manifest.written() });
    std.log.info("embedded: {d} files, {d} bytes", .{ count, total });
}
