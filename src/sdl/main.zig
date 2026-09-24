//! gameport-sdl: the interactive SDL host. The entry point only creates the process
//! resources and gives them to `sdl.host.runWithContent`. That function owns the backend, the
//! providers, the game and the outer loop.
const std = @import("std");
const sdl = @import("sdl");
const bundle = @import("game_assets");
const content: sdl.host.Content = if (bundle.embedded) .{ .embedded = &bundle.entries } else .external;

pub fn main(init: std.process.Init) !void {
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    const options = sdl.host.parseArgsWithContent(try init.minimal.args.iterateAllocator(init.arena.allocator()), content) catch |err| {
        try showUsage(init.io, if (err == error.MissingAssets) "an asset path is required" else "invalid arguments");
        std.process.exit(2);
    };
    if (options.help) return showUsage(init.io, null);
    const status = try sdl.host.runWithContent(init.gpa, init.io, init.environ_map, options, content);
    if (status != 0) std.process.exit(status);
}

fn showUsage(io: std.Io, message: ?[]const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    if (message) |text| try w.interface.print("{s}: {s}\n\n", .{ content.programName(), text });
    try w.interface.writeAll(content.usage());
    try w.interface.flush();
}
