//! Checks the browser build's module, as part of `zig build web`: a WebAssembly binary that imports
//! its memory, the page's functions and the helpers that stand in for compiler-rt, which it does
//! not link (DESIGN.md 5.3), and nothing else; and the script names every function among them.
const std = @import("std");
const web_output = @import("web_output");

/// Everything that the module imports, all from `env`. Another name is a function that the build
/// left undefined, and the page could not start the module: a new helper goes into the script,
/// into `web-check` and here.
const expected_imports = [_][]const u8{
    "memory",
    "js_now",
    "js_set_resolution",
    "js_present",
    "js_audio_open",
    "js_audio_queue",
    "js_audio_queued",
    "js_audio_state",
    "js_audio_clear",
    "js_audio_close",
    "js_set_relative_mouse",
    "js_log",
    "js_storage_save",
    "js_storage_delete",
    "__multi3",
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(r: *Reader) !u8 {
        if (r.at >= r.bytes.len) return error.Truncated;
        r.at += 1;
        return r.bytes[r.at - 1];
    }

    fn leb(r: *Reader) !u32 {
        var value: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const b = try r.byte();
            value |= @as(u32, b & 0x7f) << shift;
            if (b & 0x80 == 0) return value;
            if (shift == 28) return error.Malformed;
            shift += 7;
        }
    }

    fn name(r: *Reader) ![]const u8 {
        const len = try r.leb();
        if (r.bytes.len - r.at < len) return error.Truncated;
        r.at += len;
        return r.bytes[r.at - len .. r.at];
    }

    fn limits(r: *Reader) !void {
        const flags = try r.leb();
        _ = try r.leb();
        if (flags & 1 != 0) _ = try r.leb();
    }
};

const Import = struct { module: []const u8, name: []const u8, function: bool };

/// The imports of a WebAssembly module, from its import section.
fn imports(gpa: std.mem.Allocator, wasm: []const u8) ![]Import {
    var list: std.ArrayList(Import) = .empty;
    errdefer list.deinit(gpa);
    var r = Reader{ .bytes = wasm, .at = 8 };
    while (r.at < wasm.len) {
        const id = try r.byte();
        const size = try r.leb();
        if (wasm.len - r.at < size) return error.Truncated;
        const end = r.at + size;
        if (id == 2) {
            var count = try r.leb();
            while (count > 0) : (count -= 1) {
                const module = try r.name();
                const field = try r.name();
                const kind = try r.byte();
                switch (kind) {
                    0 => _ = try r.leb(),
                    1 => {
                        _ = try r.byte();
                        try r.limits();
                    },
                    2 => try r.limits(),
                    3 => {
                        _ = try r.byte();
                        _ = try r.byte();
                    },
                    else => return error.Malformed,
                }
                try list.append(gpa, .{ .module = module, .name = field, .function = kind == 0 });
            }
        }
        r.at = end;
    }
    return list.toOwnedSlice(gpa);
}

test "the module imports its memory, the page's functions and its helpers, and nothing else" {
    const gpa = std.testing.allocator;
    // The magic and the version of a WebAssembly binary.
    try std.testing.expect(std.mem.startsWith(u8, web_output.module_wasm, "\x00asm\x01\x00\x00\x00"));
    const found = try imports(gpa, web_output.module_wasm);
    defer gpa.free(found);
    for (found) |import| {
        try std.testing.expectEqualStrings("env", import.module);
        const known = for (expected_imports) |name| {
            if (std.mem.eql(u8, name, import.name)) break true;
        } else false;
        if (!known) std.debug.print("the module imports {s}\n", .{import.name});
        try std.testing.expect(known);
    }
    try std.testing.expectEqual(expected_imports.len, found.len);
    // The script names each function: as a property (`js_now:`) or a method (`__multi3(`). The
    // browser runs show that it gives them.
    for (found) |import| {
        if (!import.function) continue;
        const named = for ([_][]const u8{ ":", "(" }) |suffix| {
            var key: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&key, "{s}{s}", .{ import.name, suffix });
            if (std.mem.indexOf(u8, web_output.script_js, text) != null) break true;
        } else false;
        if (!named) std.debug.print("the script does not name {s}\n", .{import.name});
        try std.testing.expect(named);
    }
}
