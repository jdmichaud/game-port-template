//! A placeholder game: the smallest program that uses every part of the platform boundary, so that
//! the hosts, the runner and the builds of the skeleton have something to run. A ball bounces in a
//! box. The arrow keys push it, each bounce clicks, F2 saves the state, F3 loads it back and Escape
//! quits. Replace it with the port's own game, and keep its shape: `init`, one `update` per frame
//! with the platform, `deinit`, and the fields that the hosts inspect.
//!
//! It shows the pattern that an old game needs:
//! - The state is integers (16.16 fixed point), advanced by one fixed step per update, so the same
//!   input gives the same state on every platform. `State.hash` names it.
//! - The picture is drawn as palette indices into a page of the original's size, and one
//!   conversion makes the RGBA frame that the platform presents.
//! - Files go through workflows (`workflow.zig`): an update submits a request, a later update takes
//!   the completion, and no update waits for a file.
//! - A save has one versioned format, and a record of another version is refused.
const std = @import("std");
const platform = @import("platform.zig");
const workflow = @import("workflow.zig");

pub const page_width: u32 = 320;
pub const page_height: u32 = 200;

pub const Phase = enum { startup, loading, playing, finished };
pub const UpdateResult = enum { running, finished };

/// The asset that the game reads at startup. Its first line is the title. A missing asset is not an
/// error: the title stays empty.
pub const title_asset = "TITLE.TXT";
/// The save record that F2 writes and F3 reads.
pub const save_name = "STATE";

/// One in 16.16 fixed point.
pub const one: i32 = 1 << 16;
const ball_size: u32 = 6;
const wall: u32 = 4;
const max_speed: i32 = 4 * one;

/// Palette indices of the page, and the palette that converts them. An original game keeps its
/// own palette; the conversion to RGBA happens once, when a frame is presented.
const colour_background: u8 = 0;
const colour_wall: u8 = 1;
const colour_ball: u8 = 2;
const palette = [_][3]u8{ .{ 0x10, 0x10, 0x40 }, .{ 0xa0, 0xa0, 0xa0 }, .{ 0xff, 0xe0, 0x40 } };

/// The sound: a click of `click_samples` at `click_hz`, and the device format that the game asks
/// for. The queue is kept `audio_ahead` frames ahead of the device.
const audio_format: platform.AudioFormat = .{ .channels = 1, .sample_rate = 22050 };
const click_hz: u32 = 880;
const click_samples: u32 = 441;
const audio_ahead: u64 = 2048;

/// Everything that decides what the game does next.
pub const State = struct {
    x: i32 = 160 * one,
    y: i32 = 100 * one,
    dx: i32 = one,
    dy: i32 = one / 2,
    bounces: u32 = 0,
    /// The one random generator of the game. Every draw goes through `next`, in update order.
    seed: u32 = 0x2545f491,

    /// xorshift32.
    pub fn next(self: *State) u32 {
        var s = self.seed;
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        self.seed = s;
        return s;
    }

    /// One fixed step: move, and bounce off the walls. A bounce turns the vertical speed by a small
    /// random amount, so the path does not repeat. Returns whether the ball bounced.
    pub fn step(self: *State) bool {
        self.x +%= self.dx;
        self.y +%= self.dy;
        const min: i32 = @as(i32, wall) * one;
        const max_x: i32 = @as(i32, page_width - wall - ball_size) * one;
        const max_y: i32 = @as(i32, page_height - wall - ball_size) * one;
        var bounced = false;
        if (self.x < min or self.x > max_x) {
            self.x = std.math.clamp(self.x, min, max_x);
            self.dx = -self.dx;
            bounced = true;
        }
        if (self.y < min or self.y > max_y) {
            self.y = std.math.clamp(self.y, min, max_y);
            self.dy = -self.dy;
            bounced = true;
        }
        if (bounced) {
            self.bounces +%= 1;
            const nudge: i32 = @as(i32, @intCast(self.next() & 0x3fff)) - 0x2000;
            self.dy = std.math.clamp(self.dy +% nudge, -max_speed, max_speed);
        }
        return bounced;
    }

    /// An arrow key changes the speed by a quarter pixel an update.
    pub fn push(self: *State, key: platform.Key) void {
        const q = one / 4;
        switch (key) {
            .left => self.dx = std.math.clamp(self.dx - q, -max_speed, max_speed),
            .right => self.dx = std.math.clamp(self.dx + q, -max_speed, max_speed),
            .up => self.dy = std.math.clamp(self.dy - q, -max_speed, max_speed),
            .down => self.dy = std.math.clamp(self.dy + q, -max_speed, max_speed),
            else => {},
        }
    }

    /// The canonical hash of the state: every field in a fixed order, little endian. Two runs agree
    /// exactly when their hashes do; the tests and the hosts compare this, not the pixels.
    pub fn hash(self: State) u64 {
        var h = std.hash.Wyhash.init(0);
        for ([_]u32{ @bitCast(self.x), @bitCast(self.y), @bitCast(self.dx), @bitCast(self.dy), self.bounces, self.seed }) |v| {
            h.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
        }
        return h.final();
    }

    /// The save record: a magic, the version, then the fields, little endian.
    pub const magic = "GPST";
    pub const version: u16 = 1;
    pub const record_len: usize = magic.len + 2 + 6 * 4;

    pub fn encode(self: State) [record_len]u8 {
        var out: [record_len]u8 = undefined;
        @memcpy(out[0..magic.len], magic);
        std.mem.writeInt(u16, out[magic.len..][0..2], version, .little);
        var at: usize = magic.len + 2;
        for ([_]u32{ @bitCast(self.x), @bitCast(self.y), @bitCast(self.dx), @bitCast(self.dy), self.bounces, self.seed }) |v| {
            std.mem.writeInt(u32, out[at..][0..4], v, .little);
            at += 4;
        }
        return out;
    }

    /// A record of another version is refused, not converted: there is one save format.
    pub fn decode(bytes: []const u8) error{ NotAState, WrongVersion }!State {
        if (bytes.len != record_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.NotAState;
        if (std.mem.readInt(u16, bytes[magic.len..][0..2], .little) != version) return error.WrongVersion;
        var v: [6]u32 = undefined;
        for (&v, 0..) |*field, i| field.* = std.mem.readInt(u32, bytes[magic.len + 2 + 4 * i ..][0..4], .little);
        return .{ .x = @bitCast(v[0]), .y = @bitCast(v[1]), .dx = @bitCast(v[2]), .dy = @bitCast(v[3]), .bounces = v[4], .seed = v[5] };
    }
};

pub const Game = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .startup,
    state: State = .{},
    update_count: u64 = 0,
    frames_presented: u64 = 0,
    events_consumed: u64 = 0,
    /// The hash of the last presented page, as palette indices.
    last_frame_hash: u64 = 0,
    /// The first line of `title_asset`, when the asset exists.
    title_buf: [40]u8 = @splat(0),
    title_len: usize = 0,
    title_job: workflow.JobId = .none,
    /// A save or a load in flight. F2 and F3 do nothing until it completes.
    file_job: workflow.JobId = .none,
    saves_written: u32 = 0,
    loads_done: u32 = 0,
    audio: ?platform.AudioFormat = null,
    /// The samples of the current click still to queue, and the phase of its square wave.
    click_left: u32 = 0,
    click_phase: u32 = 0,
    page: []u8,
    rgba: []u8,

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Game {
        const page = try allocator.alloc(u8, page_width * page_height);
        errdefer allocator.free(page);
        const rgba = try allocator.alloc(u8, page_width * page_height * platform.RgbaFrame.bytes_per_pixel);
        return .{ .allocator = allocator, .page = page, .rgba = rgba };
    }

    pub fn deinit(self: *Game) void {
        self.allocator.free(self.page);
        self.allocator.free(self.rgba);
        self.* = undefined;
    }

    pub fn title(self: *const Game) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    /// One frame: the completions of earlier workflows, the input, one step of the state, the
    /// sound and the picture.
    pub fn update(self: *Game, p: *platform.Platform) !UpdateResult {
        if (self.phase == .finished) return .finished;
        self.update_count += 1;
        self.takeCompletions(p);
        switch (self.phase) {
            .startup => {
                _ = try p.start();
                try p.setResolution(page_width, page_height);
                self.audio = p.audioOpen(audio_format) catch null;
                self.title_job = p.ioSubmit(.{ .read_asset = .{ .path = title_asset, .max_bytes = 4096 } }) catch .none;
                self.phase = if (self.title_job == .none) .playing else .loading;
            },
            .loading => {
                self.consumeEvents(p);
                if (self.title_job == .none and self.phase == .loading) self.phase = .playing;
            },
            .playing => {
                self.consumeEvents(p);
                if (self.phase == .playing and self.state.step()) self.click_left = click_samples;
            },
            .finished => {},
        }
        if (self.phase == .finished) {
            if (self.audio != null) p.audioClose();
            return .finished;
        }
        self.feedAudio(p);
        try self.present(p);
        return .running;
    }

    fn takeCompletions(self: *Game, p: *platform.Platform) void {
        while (p.ioTake()) |taken| {
            var c = taken;
            defer c.deinit();
            if (c.id == self.title_job) {
                self.title_job = .none;
                const text = c.bytes() orelse continue;
                const line = std.mem.sliceTo(text, '\n');
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                self.title_len = @min(trimmed.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], trimmed[0..self.title_len]);
            } else if (c.id == self.file_job) {
                self.file_job = .none;
                switch (c.kind) {
                    .save_record => if (c.result == .done) {
                        self.saves_written += 1;
                    },
                    .load_save => if (c.bytes()) |bytes| {
                        if (State.decode(bytes)) |loaded| {
                            self.state = loaded;
                            self.loads_done += 1;
                        } else |_| {}
                    },
                    else => {},
                }
            }
        }
    }

    fn consumeEvents(self: *Game, p: *platform.Platform) void {
        var buf: [32]platform.Event = undefined;
        while (true) {
            const n = p.pollEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |event| {
                self.events_consumed += 1;
                switch (event.payload) {
                    .quit => self.phase = .finished,
                    .key_down => |k| switch (k.key) {
                        .escape => self.phase = .finished,
                        .f2 => self.saveState(p),
                        .f3 => self.loadState(p),
                        else => self.state.push(k.key),
                    },
                    else => {},
                }
            }
        }
    }

    fn saveState(self: *Game, p: *platform.Platform) void {
        if (self.file_job != .none) return;
        // The workflow copies the bytes at submission, so a buffer on the stack is enough.
        const record = self.state.encode();
        self.file_job = p.ioSubmit(.{ .save_record = .{ .name = save_name, .bytes = &record } }) catch .none;
    }

    fn loadState(self: *Game, p: *platform.Platform) void {
        if (self.file_job != .none) return;
        self.file_job = p.ioSubmit(.{ .load_save = .{ .name = save_name } }) catch .none;
    }

    /// Keeps the device queue `audio_ahead` frames ahead: the click while it lasts, then silence.
    fn feedAudio(self: *Game, p: *platform.Platform) void {
        const format = self.audio orelse return;
        const status = p.audioStatus();
        if (status.queued_frames >= audio_ahead) return;
        var samples: [512]i16 = undefined;
        const frames = samples.len / format.channels;
        const half_period = @max(format.sample_rate / (2 * click_hz), 1);
        for (0..frames) |f| {
            var value: i16 = 0;
            if (self.click_left > 0) {
                value = if ((self.click_phase / half_period) % 2 == 0) 6000 else -6000;
                self.click_phase += 1;
                self.click_left -= 1;
            }
            for (0..format.channels) |c| samples[f * format.channels + c] = value;
        }
        _ = p.audioQueue(samples[0 .. frames * format.channels]) catch {};
    }

    fn present(self: *Game, p: *platform.Platform) !void {
        self.draw();
        self.last_frame_hash = std.hash.Wyhash.hash(0, self.page);
        for (self.page, 0..) |index, i| {
            const rgb = palette[index];
            self.rgba[i * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], 0xff };
        }
        try p.present(.{
            .width = page_width,
            .height = page_height,
            .stride = page_width * platform.RgbaFrame.bytes_per_pixel,
            .pixels = self.rgba,
        });
        self.frames_presented += 1;
    }

    /// The page: the walls, then the ball at the integer part of its position.
    fn draw(self: *Game) void {
        @memset(self.page, colour_background);
        for (0..page_height) |y| {
            for (0..page_width) |x| {
                if (x < wall or y < wall or x >= page_width - wall or y >= page_height - wall) {
                    self.page[y * page_width + x] = colour_wall;
                }
            }
        }
        // A loaded record is trusted no further than the page: the ball is drawn inside it.
        const bx: u32 = @intCast(std.math.clamp(self.state.x >> 16, 0, @as(i32, page_width - ball_size)));
        const by: u32 = @intCast(std.math.clamp(self.state.y >> 16, 0, @as(i32, page_height - ball_size)));
        for (by..by + ball_size) |y| {
            @memset(self.page[y * page_width + bx ..][0..ball_size], colour_ball);
        }
    }
};

const testing = std.testing;

test "the same pushes give the same state, and a different push a different hash" {
    var a: State = .{};
    var b: State = .{};
    for (0..500) |i| {
        if (i == 100) {
            a.push(.up);
            b.push(.up);
        }
        _ = a.step();
        _ = b.step();
    }
    try testing.expectEqual(a.hash(), b.hash());
    try testing.expect(a.bounces > 0);
    b.push(.left);
    _ = a.step();
    _ = b.step();
    try testing.expect(a.hash() != b.hash());
}

test "the ball stays inside the walls" {
    var s: State = .{ .dx = max_speed, .dy = -max_speed };
    for (0..5000) |_| {
        _ = s.step();
        try testing.expect(s.x >= @as(i32, wall) * one and s.x <= @as(i32, page_width - wall - ball_size) * one);
        try testing.expect(s.y >= @as(i32, wall) * one and s.y <= @as(i32, page_height - wall - ball_size) * one);
    }
}

test "a save record comes back as the same state, and another version is refused" {
    var s: State = .{};
    for (0..123) |_| _ = s.step();
    const record = s.encode();
    const back = try State.decode(&record);
    try testing.expectEqual(s.hash(), back.hash());

    var other = record;
    std.mem.writeInt(u16, other[State.magic.len..][0..2], State.version + 1, .little);
    try testing.expectError(error.WrongVersion, State.decode(&other));
    try testing.expectError(error.NotAState, State.decode(record[0..10]));
}
