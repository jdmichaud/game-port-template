//! The keys of a browser keyboard. The page gives the `code` of each `KeyboardEvent`, which
//! names the physical key and does not change with the layout, as an SDL scan code does. This
//! table is the only place that maps them, so the page and the native host agree on every key.
const std = @import("std");
const gameport = @import("gameport");
const Key = gameport.platform.Key;

const CodeKey = struct { []const u8, Key };

/// `KeyboardEvent.code` to project key. Every key of the `Key` enum has an entry (a test checks
/// this). The keypad Enter is also `enter`, and a code without an entry is `unknown`.
const code_keys = [_]CodeKey{
    .{ "Escape", .escape },               .{ "Enter", .enter },
    .{ "NumpadEnter", .enter },           .{ "Space", .space },
    .{ "Tab", .tab },                     .{ "Backspace", .backspace },
    .{ "ArrowLeft", .left },              .{ "ArrowRight", .right },
    .{ "ArrowUp", .up },                  .{ "ArrowDown", .down },
    .{ "Home", .home },                   .{ "End", .end },
    .{ "PageUp", .page_up },              .{ "PageDown", .page_down },
    .{ "Insert", .insert },               .{ "Delete", .delete },
    .{ "ShiftLeft", .left_shift },        .{ "ShiftRight", .right_shift },
    .{ "ControlLeft", .left_ctrl },       .{ "ControlRight", .right_ctrl },
    .{ "AltLeft", .left_alt },            .{ "AltRight", .right_alt },
    .{ "KeyA", .a },                      .{ "KeyB", .b },
    .{ "KeyC", .c },                      .{ "KeyD", .d },
    .{ "KeyE", .e },                      .{ "KeyF", .f },
    .{ "KeyG", .g },                      .{ "KeyH", .h },
    .{ "KeyI", .i },                      .{ "KeyJ", .j },
    .{ "KeyK", .k },                      .{ "KeyL", .l },
    .{ "KeyM", .m },                      .{ "KeyN", .n },
    .{ "KeyO", .o },                      .{ "KeyP", .p },
    .{ "KeyQ", .q },                      .{ "KeyR", .r },
    .{ "KeyS", .s },                      .{ "KeyT", .t },
    .{ "KeyU", .u },                      .{ "KeyV", .v },
    .{ "KeyW", .w },                      .{ "KeyX", .x },
    .{ "KeyY", .y },                      .{ "KeyZ", .z },
    .{ "Digit0", .digit_0 },              .{ "Digit1", .digit_1 },
    .{ "Digit2", .digit_2 },              .{ "Digit3", .digit_3 },
    .{ "Digit4", .digit_4 },              .{ "Digit5", .digit_5 },
    .{ "Digit6", .digit_6 },              .{ "Digit7", .digit_7 },
    .{ "Digit8", .digit_8 },              .{ "Digit9", .digit_9 },
    .{ "F1", .f1 },                       .{ "F2", .f2 },
    .{ "F3", .f3 },                       .{ "F4", .f4 },
    .{ "F5", .f5 },                       .{ "F6", .f6 },
    .{ "F7", .f7 },                       .{ "F8", .f8 },
    .{ "F9", .f9 },                       .{ "F10", .f10 },
    .{ "F11", .f11 },                     .{ "F12", .f12 },
    .{ "Minus", .minus },                 .{ "Equal", .equals },
    .{ "Comma", .comma },                 .{ "Period", .period },
    .{ "Slash", .slash },                 .{ "Semicolon", .semicolon },
    .{ "Quote", .apostrophe },            .{ "Backquote", .grave },
    .{ "BracketLeft", .left_bracket },    .{ "BracketRight", .right_bracket },
    .{ "Backslash", .backslash },         .{ "NumpadAdd", .keypad_plus },
    .{ "NumpadSubtract", .keypad_minus },
    // The keypad's other keys, as the native host maps them: the keys that they double with Num
    // Lock off (0 is Insert, the period Delete, and 8, 2, 4 and 6 the arrows). The digits that a
    // text field takes arrive as text input.
    .{ "Numpad0", .insert },
    .{ "NumpadDecimal", .delete },        .{ "Numpad8", .up },
    .{ "Numpad2", .down },                .{ "Numpad4", .left },
    .{ "Numpad6", .right },               .{ "Numpad7", .home },
    .{ "Numpad9", .page_up },             .{ "Numpad1", .end },
    .{ "Numpad3", .page_down },
};

/// The project key of a `KeyboardEvent.code`, or `unknown`.
pub fn fromCode(code: []const u8) Key {
    for (code_keys) |entry| {
        if (std.mem.eql(u8, entry[0], code)) return entry[1];
    }
    return .unknown;
}

test "every key of the enum has a code, and the codes are unique" {
    inline for (@typeInfo(Key).@"enum".field_names) |name| {
        const key = @field(Key, name);
        if (key == .unknown) continue;
        var found = false;
        for (code_keys) |entry| {
            if (entry[1] == key) found = true;
        }
        try std.testing.expect(found);
    }
    for (code_keys, 0..) |a, i| {
        for (code_keys[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a[0], b[0]));
    }
}

test "codes map as the native host maps its scan codes" {
    try std.testing.expectEqual(Key.a, fromCode("KeyA"));
    try std.testing.expectEqual(Key.enter, fromCode("NumpadEnter"));
    try std.testing.expectEqual(Key.insert, fromCode("Numpad0"));
    try std.testing.expectEqual(Key.f10, fromCode("F10"));
    try std.testing.expectEqual(Key.apostrophe, fromCode("Quote"));
    try std.testing.expectEqual(Key.unknown, fromCode("MetaLeft"));
    try std.testing.expectEqual(Key.unknown, fromCode(""));
}
