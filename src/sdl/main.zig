//! gameport-sdl: the interactive SDL host. The entry point only creates the process resources and
//! gives them to `sdl.host.run`. That function owns the backend, the providers, the game and the
//! outer loop.
const std = @import("std");
const sdl = @import("sdl");
const native = @import("native");

pub fn main(init: std.process.Init) !void {
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    const options = sdl.host.parseArgs(try init.minimal.args.iterateAllocator(init.arena.allocator())) catch |err| {
        try showUsage(init.io, if (err == error.MissingAssets) "an asset path is required" else "invalid arguments");
        std.process.exit(2);
    };
    if (options.help) return showHelp(init.io, init.arena.allocator(), init.environ_map, options.providers.saves);
    const status = try sdl.host.run(init.gpa, init.io, init.environ_map, options);
    if (status != 0) std.process.exit(status);
}

/// `--help`, on standard output: how the program is called, the folders it uses (at `--saves`
/// when given), then the options.
fn showHelp(io: std.Io, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, saves: ?[]const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(sdl.host.usage_head);
    try native.cli.writeStorageHelp(&w.interface, allocator, environ, saves);
    try w.interface.writeAll(sdl.host.usage_options);
    try w.interface.flush();
}

fn showUsage(io: std.Io, message: ?[]const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    if (message) |text| try w.interface.print("gameport-sdl: {s}\n\n", .{text});
    try w.interface.writeAll(sdl.host.usage);
    try w.interface.flush();
}
