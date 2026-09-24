//! The event log of the SDL host: one JSON object on one line for each delivered platform event.
//!
//! The field names are the names that the `inject` command of the agent host parses (`parseEvent`
//! in src/agent/host.zig). Thus a line from an interactive session replays unchanged in a
//! headless run. An enum value that has no name is written as its number. The parser rejects
//! such a line; it does not read the number as a different value.
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;

/// Writes `ev` as one JSON object followed by a newline. Does not flush.
pub fn writeEvent(ev: platform.Event, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("kind");
    try js.write(@tagName(std.meta.activeTag(ev.payload)));
    try js.objectField("t");
    try js.write(ev.time_ns);
    switch (ev.payload) {
        .key_down, .key_up => |k| {
            try js.objectField("key");
            try writeEnum(&js, platform.Key, k.key);
            try js.objectField("repeat");
            try js.write(k.repeat);
        },
        .text_input => |t| {
            try js.objectField("text");
            try js.write(t.slice());
        },
        .mouse_motion => |m| {
            try js.objectField("dx");
            try js.write(m.dx);
            try js.objectField("dy");
            try js.write(m.dy);
            try js.objectField("x");
            try js.write(m.x);
            try js.objectField("y");
            try js.write(m.y);
        },
        .mouse_button_down, .mouse_button_up => |b| {
            try js.objectField("button");
            try writeEnum(&js, platform.MouseButton, b.button);
            try js.objectField("x");
            try js.write(b.x);
            try js.objectField("y");
            try js.write(b.y);
        },
        .mouse_wheel => |wheel| {
            try js.objectField("dx");
            try js.write(wheel.dx);
            try js.objectField("dy");
            try js.write(wheel.dy);
        },
        .controller_added, .controller_removed => |id| {
            try js.objectField("controller");
            try js.write(@backingInt(id));
        },
        .controller_button_down, .controller_button_up => |b| {
            try js.objectField("controller");
            try js.write(@backingInt(b.controller));
            try js.objectField("button");
            try writeEnum(&js, platform.ControllerButton, b.button);
        },
        .controller_axis => |a| {
            try js.objectField("controller");
            try js.write(@backingInt(a.controller));
            try js.objectField("axis");
            try writeEnum(&js, platform.ControllerAxis, a.axis);
            try js.objectField("value");
            try js.write(a.value);
        },
        .capture_changed => |captured| {
            try js.objectField("captured");
            try js.write(captured);
        },
        .drawable_resized => |size| {
            try js.objectField("width");
            try js.write(size.width);
            try js.objectField("height");
            try js.write(size.height);
        },
        .connected, .disconnected => |id| {
            try js.objectField("connection");
            try js.write(@backingInt(id));
        },
        .received => |r| {
            try js.objectField("connection");
            try js.write(@backingInt(r.connection));
            try js.objectField("bytes");
            try js.write(r.message.len);
        },
        .focus_gained, .focus_lost, .quit => {},
    }
    try js.endObject();
    try w.writeByte('\n');
}

/// The value's name, or its number when the non-exhaustive enum does not name it.
fn writeEnum(js: *std.json.Stringify, comptime E: type, value: E) std.Io.Writer.Error!void {
    if (std.enums.tagName(E, value)) |name| {
        try js.write(name);
    } else {
        try js.write(@backingInt(value));
    }
}

test "events are logged in the agent host's own vocabulary" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEvent(.{ .time_ns = 12, .payload = .{ .key_down = .{ .key = .s, .repeat = true } } }, &w);
    try writeEvent(.{ .time_ns = 13, .payload = .{ .mouse_motion = .{ .dx = -2, .dy = 3, .x = 10, .y = 20 } } }, &w);
    try writeEvent(.{ .time_ns = 14, .payload = .{ .mouse_button_down = .{ .button = .right, .x = 1, .y = 2 } } }, &w);
    try writeEvent(.{ .time_ns = 15, .payload = .{ .mouse_wheel = .{ .dx = 0, .dy = -1 } } }, &w);
    try writeEvent(.{ .time_ns = 16, .payload = .{ .capture_changed = true } }, &w);
    try writeEvent(.{ .time_ns = 17, .payload = .{ .drawable_resized = .{ .width = 640, .height = 400 } } }, &w);
    try writeEvent(.{ .time_ns = 18, .payload = .quit }, &w);
    var text: platform.Event.TextInput = .{};
    @memcpy(text.bytes[0..4], "a\"\\b");
    text.len = 4;
    try writeEvent(.{ .time_ns = 19, .payload = .{ .text_input = text } }, &w);
    try writeEvent(.{ .time_ns = 20, .payload = .{ .controller_axis = .{ .controller = @fromBackingInt(3), .axis = .left_x, .value = -300 } } }, &w);
    try writeEvent(.{ .time_ns = 21, .payload = .{ .key_up = .{ .key = @fromBackingInt(9999) } } }, &w);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, w.buffered(), "\n"), '\n');
    try std.testing.expectEqualStrings("{\"kind\":\"key_down\",\"t\":12,\"key\":\"s\",\"repeat\":true}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"mouse_motion\",\"t\":13,\"dx\":-2,\"dy\":3,\"x\":10,\"y\":20}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"mouse_button_down\",\"t\":14,\"button\":\"right\",\"x\":1,\"y\":2}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"mouse_wheel\",\"t\":15,\"dx\":0,\"dy\":-1}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"capture_changed\",\"t\":16,\"captured\":true}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"drawable_resized\",\"t\":17,\"width\":640,\"height\":400}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"quit\",\"t\":18}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"text_input\",\"t\":19,\"text\":\"a\\\"\\\\b\"}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"controller_axis\",\"t\":20,\"controller\":3,\"axis\":\"left_x\",\"value\":-300}", lines.next().?);
    try std.testing.expectEqualStrings("{\"kind\":\"key_up\",\"t\":21,\"key\":9999,\"repeat\":false}", lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
}
