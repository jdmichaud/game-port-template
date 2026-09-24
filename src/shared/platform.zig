//! The platform boundary (DESIGN.md-3): devices, read-only assets and persistent
//! storage, as bound interfaces that the game calls. No code here knows about the game.
//!
//! Each interface is a context pointer plus a vtable, so several backends and several games can
//! exist in one process. Memory ownership follows the design. `present` borrows its frame only
//! during the call. Received network bytes stay valid until the next poll. Each returned buffer
//! is released through its own `deinit`.
const std = @import("std");
const workflow = @import("workflow.zig");

pub const Capabilities = struct {
    video: bool = false,
    audio: bool = false,
    controllers: bool = false,
    network: bool = false,
};

pub const HostOptions = struct {
    title: []const u8 = "gameport",
    initial_window_scale: u32 = 3,
    prefer_vsync: bool = true,
};

/// A completed full-colour frame: R, G, B, A bytes per pixel, rows top to bottom, alpha 255.
pub const RgbaFrame = struct {
    width: u32,
    height: u32,
    /// Bytes between row starts; at least `width * 4`.
    stride: usize,
    pixels: []const u8,

    pub const bytes_per_pixel: usize = 4;

    pub const ValidateError = error{InvalidFrame};

    /// Checks for positive dimensions, `stride >= width * 4`, and enough bytes for every active
    /// pixel. All arithmetic is checked.
    pub fn validate(f: RgbaFrame) ValidateError!void {
        if (f.width == 0 or f.height == 0) return error.InvalidFrame;
        const row_bytes = std.math.mul(usize, f.width, bytes_per_pixel) catch return error.InvalidFrame;
        if (f.stride < row_bytes) return error.InvalidFrame;
        const padded_rows = std.math.mul(usize, f.stride, f.height - 1) catch return error.InvalidFrame;
        const needed = std.math.add(usize, padded_rows, row_bytes) catch return error.InvalidFrame;
        if (f.pixels.len < needed) return error.InvalidFrame;
    }

    /// The active bytes of row `y` (no padding).
    pub fn row(f: RgbaFrame, y: u32) []const u8 {
        const start = @as(usize, y) * f.stride;
        return f.pixels[start..][0 .. @as(usize, f.width) * bytes_per_pixel];
    }
};

pub const AudioFormat = struct {
    channels: u8 = 2,
    sample_rate: u32 = 44100,
};

pub const AudioStatus = struct {
    queued_frames: u64 = 0,
    played_frames: u64 = 0,
    running: bool = false,
    suspended: bool = false,
};

pub const ConnectionId = enum(u32) { _ };

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
};

/// The largest message that a transport carries (DESIGN.md). A larger message
/// is refused with `error.MessageTooLarge`, so a peer cannot make the other side hold an
/// unbounded buffer.
pub const max_message_len: usize = 64 * 1024;

/// What a listening transport reports: whether it accepts guests, on which port, and the
/// addresses of this machine that a guest can open, most useful first.
pub const ListenStatus = struct {
    listening: bool = false,
    port: u16 = 0,
    addresses: [max_addresses]Address = @splat(.{}),
    address_count: u8 = 0,

    pub const max_addresses = 4;

    /// One address as text: an IPv4 dotted quad or an IPv6 address, at most 45 characters.
    pub const Address = struct {
        bytes: [46]u8 = @splat(0),
        len: u8 = 0,

        pub fn init(text_in: []const u8) Address {
            var a: Address = .{};
            const n = @min(text_in.len, a.bytes.len);
            @memcpy(a.bytes[0..n], text_in[0..n]);
            a.len = @intCast(n);
            return a;
        }

        pub fn text(a: *const Address) []const u8 {
            return a.bytes[0..a.len];
        }
    };

    /// The addresses that the transport reported.
    pub fn list(s: *const ListenStatus) []const Address {
        return s.addresses[0..s.address_count];
    }

    /// Adds an address if there is room. Returns false when the list is full.
    pub fn add(s: *ListenStatus, text_in: []const u8) bool {
        if (s.address_count == max_addresses) return false;
        s.addresses[s.address_count] = Address.init(text_in);
        s.address_count += 1;
        return true;
    }
};

/// The key identities of the project. The values are stable; hosts map their scan codes to them.
pub const Key = enum(u16) {
    unknown = 0,
    escape,
    enter,
    space,
    tab,
    backspace,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    minus,
    equals,
    comma,
    period,
    slash,
    semicolon,
    apostrophe,
    grave,
    left_bracket,
    right_bracket,
    backslash,
    keypad_plus,
    keypad_minus,
    _,
};

pub const MouseButton = enum(u8) { left = 0, middle, right, x1, x2, _ };
pub const ControllerId = enum(u32) { _ };
pub const ControllerButton = enum(u8) {
    a,
    b,
    x,
    y,
    back,
    guide,
    start,
    left_stick,
    right_stick,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    _,
};
pub const ControllerAxis = enum(u8) { left_x, left_y, right_x, right_y, trigger_left, trigger_right, _ };

pub const Size = struct { width: u32, height: u32 };

/// One device or transport event, in order, with a time stamp from the host's monotonic clock.
pub const Event = struct {
    time_ns: u64,
    payload: Payload,

    pub const KeyEvent = struct { key: Key, repeat: bool = false };
    pub const TextInput = struct {
        /// UTF-8 bytes of the text; `len` of them are valid.
        bytes: [8]u8 = @splat(0),
        len: u8 = 0,
        pub fn slice(t: *const TextInput) []const u8 {
            return t.bytes[0..t.len];
        }
    };
    pub const MouseMotion = struct { dx: i32, dy: i32, x: i32, y: i32 };
    pub const MouseButtonEvent = struct { button: MouseButton, x: i32, y: i32 };
    pub const MouseWheel = struct { dx: i32, dy: i32 };
    pub const ControllerButtonEvent = struct { controller: ControllerId, button: ControllerButton };
    pub const ControllerAxisEvent = struct { controller: ControllerId, axis: ControllerAxis, value: i16 };
    pub const Received = struct { connection: ConnectionId, message: []const u8 };

    pub const Payload = union(enum) {
        key_down: KeyEvent,
        key_up: KeyEvent,
        text_input: TextInput,
        mouse_motion: MouseMotion,
        mouse_button_down: MouseButtonEvent,
        mouse_button_up: MouseButtonEvent,
        mouse_wheel: MouseWheel,
        controller_added: ControllerId,
        controller_removed: ControllerId,
        controller_button_down: ControllerButtonEvent,
        controller_button_up: ControllerButtonEvent,
        controller_axis: ControllerAxisEvent,
        focus_gained,
        focus_lost,
        /// The actual relative-mouse capture state after a request or a host change.
        capture_changed: bool,
        drawable_resized: Size,
        quit,
        connected: ConnectionId,
        disconnected: ConnectionId,
        received: Received,
    };

    pub const Kind = std.meta.Tag(Payload);
};

pub const PlatformError = error{
    Unsupported,
    DeviceFailure,
    OutOfMemory,
    InvalidFrame,
    InvalidResolution,
    NotStarted,
    QueueFull,
    /// The transport cannot listen on the endpoint: the port is in use, or the address is not
    /// one of this machine.
    AddressUnavailable,
    /// The connection is not open: it closed, or the id was never given.
    NotConnected,
    /// A message larger than `max_message_len`.
    MessageTooLarge,
};

/// The network half of a backend (DESIGN.md). A backend forwards its `net_*`
/// calls to it and appends its events to the device events of `poll_events`. The transport
/// delivers whole messages, reliably and in order, while a connection lives. `send` copies the
/// message into a bounded queue: success means accepted for sending, not received. A host that
/// serves guests listens on an endpoint; each guest that comes is a `connected` event with its
/// own connection id. Bytes of a `received` event stay valid until the next `poll`.
pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        connect: *const fn (*anyopaque, Endpoint) PlatformError!ConnectionId,
        listen: *const fn (*anyopaque, Endpoint) PlatformError!void,
        stop_listening: *const fn (*anyopaque) void,
        listen_status: *const fn (*anyopaque) ListenStatus,
        send: *const fn (*anyopaque, ConnectionId, []const u8) PlatformError!void,
        close: *const fn (*anyopaque, ConnectionId) void,
        poll: *const fn (*anyopaque, []Event) usize,
    };

    pub fn connect(t: Transport, endpoint: Endpoint) PlatformError!ConnectionId {
        return t.vtable.connect(t.context, endpoint);
    }
    pub fn listen(t: Transport, endpoint: Endpoint) PlatformError!void {
        return t.vtable.listen(t.context, endpoint);
    }
    pub fn stopListening(t: Transport) void {
        t.vtable.stop_listening(t.context);
    }
    pub fn listenStatus(t: Transport) ListenStatus {
        return t.vtable.listen_status(t.context);
    }
    pub fn send(t: Transport, connection: ConnectionId, message: []const u8) PlatformError!void {
        return t.vtable.send(t.context, connection, message);
    }
    pub fn close(t: Transport, connection: ConnectionId) void {
        t.vtable.close(t.context, connection);
    }
    /// Appends the pending network events to `dst`, in order. Returns the number written.
    pub fn poll(t: Transport, dst: []Event) usize {
        return t.vtable.poll(t.context, dst);
    }
};

/// The network calls of a backend that forwards them to an optional transport. Each backend
/// keeps one of these, so the forwarding is written once.
pub const NetForward = struct {
    transport: ?Transport = null,

    pub fn connect(f: *const NetForward, endpoint: Endpoint) PlatformError!ConnectionId {
        const t = f.transport orelse return error.Unsupported;
        return t.connect(endpoint);
    }
    pub fn listen(f: *const NetForward, endpoint: Endpoint) PlatformError!void {
        const t = f.transport orelse return error.Unsupported;
        return t.listen(endpoint);
    }
    pub fn stopListening(f: *const NetForward) void {
        if (f.transport) |t| t.stopListening();
    }
    pub fn listenStatus(f: *const NetForward) ListenStatus {
        const t = f.transport orelse return .{};
        return t.listenStatus();
    }
    pub fn send(f: *const NetForward, connection: ConnectionId, message: []const u8) PlatformError!void {
        const t = f.transport orelse return error.Unsupported;
        return t.send(connection, message);
    }
    pub fn close(f: *const NetForward, connection: ConnectionId) void {
        if (f.transport) |t| t.close(connection);
    }
    /// Appends the transport's events after the `used` device events already in `dst`.
    pub fn poll(f: *const NetForward, dst: []Event, used: usize) usize {
        const t = f.transport orelse return used;
        if (used >= dst.len) return used;
        return used + t.poll(dst[used..]);
    }
};

/// Lifecycle, device events, time, presentation, PCM output, transport and I/O workflows.
pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (*anyopaque) PlatformError!Capabilities,
        set_resolution: *const fn (*anyopaque, u32, u32) PlatformError!void,
        present: *const fn (*anyopaque, RgbaFrame) PlatformError!void,
        poll_events: *const fn (*anyopaque, []Event) usize,
        now_ns: *const fn (*anyopaque) u64,
        audio_open: *const fn (*anyopaque, AudioFormat) PlatformError!AudioFormat,
        audio_queue: *const fn (*anyopaque, []const i16) PlatformError!usize,
        audio_status: *const fn (*anyopaque) AudioStatus,
        audio_clear: *const fn (*anyopaque) void,
        audio_close: *const fn (*anyopaque) void,
        set_relative_mouse: *const fn (*anyopaque, bool) PlatformError!void,
        net_connect: *const fn (*anyopaque, Endpoint) PlatformError!ConnectionId,
        net_listen: *const fn (*anyopaque, Endpoint) PlatformError!void,
        net_stop_listening: *const fn (*anyopaque) void,
        net_listen_status: *const fn (*anyopaque) ListenStatus,
        net_send: *const fn (*anyopaque, ConnectionId, []const u8) PlatformError!void,
        net_close: *const fn (*anyopaque, ConnectionId) void,
        io_submit: *const fn (*anyopaque, workflow.Request) workflow.SubmitError!workflow.JobId,
        io_take: *const fn (*anyopaque) ?workflow.Completion,
        io_cancel: *const fn (*anyopaque, workflow.JobId) bool,
    };

    pub fn start(p: *Platform) PlatformError!Capabilities {
        return p.vtable.start(p.context);
    }
    pub fn setResolution(p: *Platform, width: u32, height: u32) PlatformError!void {
        return p.vtable.set_resolution(p.context, width, height);
    }
    /// Borrows `frame` for the duration of the call only.
    pub fn present(p: *Platform, frame: RgbaFrame) PlatformError!void {
        return p.vtable.present(p.context, frame);
    }
    /// Fills `dst` in order without waiting. Returns the number of events written.
    pub fn pollEvents(p: *Platform, dst: []Event) usize {
        return p.vtable.poll_events(p.context, dst);
    }
    pub fn nowNs(p: *Platform) u64 {
        return p.vtable.now_ns(p.context);
    }
    pub fn audioOpen(p: *Platform, requested: AudioFormat) PlatformError!AudioFormat {
        return p.vtable.audio_open(p.context, requested);
    }
    /// Copies samples into the bounded queue. Returns the number of sample frames accepted.
    pub fn audioQueue(p: *Platform, samples: []const i16) PlatformError!usize {
        return p.vtable.audio_queue(p.context, samples);
    }
    pub fn audioStatus(p: *Platform) AudioStatus {
        return p.vtable.audio_status(p.context);
    }
    pub fn audioClear(p: *Platform) void {
        p.vtable.audio_clear(p.context);
    }
    pub fn audioClose(p: *Platform) void {
        p.vtable.audio_close(p.context);
    }
    /// Requests relative mouse mode. The actual state arrives as a `capture_changed` event.
    pub fn setRelativeMouse(p: *Platform, enabled: bool) PlatformError!void {
        return p.vtable.set_relative_mouse(p.context, enabled);
    }
    pub fn netConnect(p: *Platform, endpoint: Endpoint) PlatformError!ConnectionId {
        return p.vtable.net_connect(p.context, endpoint);
    }
    /// Starts to accept guests on `endpoint`. Each guest is a `connected` event.
    pub fn netListen(p: *Platform, endpoint: Endpoint) PlatformError!void {
        return p.vtable.net_listen(p.context, endpoint);
    }
    /// Stops accepting guests. Connections that are open stay open.
    pub fn netStopListening(p: *Platform) void {
        p.vtable.net_stop_listening(p.context);
    }
    pub fn netListenStatus(p: *Platform) ListenStatus {
        return p.vtable.net_listen_status(p.context);
    }
    pub fn netSend(p: *Platform, connection: ConnectionId, message: []const u8) PlatformError!void {
        return p.vtable.net_send(p.context, connection, message);
    }
    pub fn netClose(p: *Platform, connection: ConnectionId) void {
        p.vtable.net_close(p.context, connection);
    }
    /// Queues an I/O workflow (`workflow.zig`). It starts at a later update boundary; its
    /// completion comes through `ioTake`.
    pub fn ioSubmit(p: *Platform, request: workflow.Request) workflow.SubmitError!workflow.JobId {
        return p.vtable.io_submit(p.context, request);
    }
    /// The oldest published completion, or null. The caller owns it until `Completion.deinit`.
    pub fn ioTake(p: *Platform) ?workflow.Completion {
        return p.vtable.io_take(p.context);
    }
    /// Requests the cancellation of a job. A job that finished first keeps its result. Returns
    /// false when the job is unknown, finished or taken.
    pub fn ioCancel(p: *Platform, id: workflow.JobId) bool {
        return p.vtable.io_cancel(p.context, id);
    }
};

/// A buffer returned to the caller, released through its retained allocator.
pub const OwnedBytes = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedBytes) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// An owned list of names (asset entries or save keys). The list also owns each string.
pub const OwnedNames = struct {
    names: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedNames) void {
        for (self.names) |n| self.allocator.free(n);
        self.allocator.free(self.names);
        self.* = undefined;
    }
};

pub const OwnedAssetEntries = OwnedNames;
pub const OwnedSaveNames = OwnedNames;

pub const AssetHandle = enum(u32) { _ };

pub const OpenedAsset = struct {
    handle: AssetHandle,
    length: u64,
};

pub const AssetError = error{
    NotFound,
    InvalidName,
    InvalidHandle,
    Io,
    TooLarge,
    ShortRead,
    OutOfMemory,
    Canceled,
};

/// Named, read-only game files.
pub const AssetSource = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// The provider's allocator, for owned results such as the buffer of `readAll`.
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        open: *const fn (*anyopaque, []const u8) AssetError!OpenedAsset,
        read_at: *const fn (*anyopaque, AssetHandle, u64, []u8) AssetError!usize,
        list: *const fn (*anyopaque, []const u8) AssetError!OwnedAssetEntries,
        close: *const fn (*anyopaque, AssetHandle) void,
    };

    pub fn open(a: AssetSource, path: []const u8) AssetError!OpenedAsset {
        return a.vtable.open(a.context, path);
    }
    /// Reads at `offset` into `dst` and returns the count; short reads and end of file are allowed.
    pub fn readAt(a: AssetSource, file: AssetHandle, offset: u64, dst: []u8) AssetError!usize {
        return a.vtable.read_at(a.context, file, offset, dst);
    }
    pub fn list(a: AssetSource, prefix: []const u8) AssetError!OwnedAssetEntries {
        return a.vtable.list(a.context, prefix);
    }
    pub fn close(a: AssetSource, file: AssetHandle) void {
        a.vtable.close(a.context, file);
    }

    /// Reads the whole asset into an owned buffer. The length must fit `max_bytes` and the
    /// address space (else `TooLarge`). The helper calls `read_at` until the buffer is full, and
    /// fails with `ShortRead` if a read returns 0 first. The asset is closed on every exit.
    pub fn readAll(a: AssetSource, path: []const u8, max_bytes: usize) AssetError!OwnedBytes {
        const opened = try a.open(path);
        defer a.close(opened.handle);
        if (opened.length > max_bytes or opened.length > std.math.maxInt(usize)) return error.TooLarge;
        const len: usize = @intCast(opened.length);
        const buf = a.allocator.alloc(u8, len) catch return error.OutOfMemory;
        errdefer a.allocator.free(buf);
        var done: usize = 0;
        while (done < len) {
            const n = try a.readAt(opened.handle, done, buf[done..]);
            if (n == 0) return error.ShortRead;
            done += n;
        }
        return .{ .bytes = buf, .allocator = a.allocator };
    }
};

pub const StorageError = error{
    NotFound,
    InvalidName,
    Io,
    OutOfMemory,
    Canceled,
};

/// Persistent named byte records in one flat collection.
pub const Storage = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        save: *const fn (*anyopaque, []const u8, []const u8) StorageError!void,
        load: *const fn (*anyopaque, []const u8) StorageError!OwnedBytes,
        list_saves: *const fn (*anyopaque) StorageError!OwnedSaveNames,
        delete_save: *const fn (*anyopaque, []const u8) StorageError!void,
    };

    /// Replaces the record atomically. Returns when the new record is persistent.
    pub fn save(s: Storage, name: []const u8, bytes: []const u8) StorageError!void {
        try validateName(name);
        return s.vtable.save(s.context, name, bytes);
    }
    pub fn load(s: Storage, name: []const u8) StorageError!OwnedBytes {
        try validateName(name);
        return s.vtable.load(s.context, name);
    }
    pub fn listSaves(s: Storage) StorageError!OwnedSaveNames {
        return s.vtable.list_saves(s.context);
    }
    pub fn deleteSave(s: Storage, name: []const u8) StorageError!void {
        try validateName(name);
        return s.vtable.delete_save(s.context, name);
    }
};

pub const max_name_len = 64;

/// Portable file name rules for save keys and logical asset names: 1 to 64 ASCII characters
/// from letters, digits, `.`, `_` and `-`; no `.` at the start; no `..`. A name that breaks a
/// rule is an error; no code corrects it.
pub fn validateName(name: []const u8) error{InvalidName}!void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidName;
    if (name[0] == '.') return error.InvalidName;
    if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidName;
    for (name) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
        if (!ok) return error.InvalidName;
    }
}

/// The separator between the directory components of a logical asset name.
pub const asset_separator: u8 = '/';
/// A logical asset name is at most this long, separators included.
pub const max_asset_name_len = 128;
/// A logical asset name has at most this many components (`DATA/1_1.MVE` has two).
pub const max_asset_depth = 8;

/// Logical asset names add directory components to the flat rules: `GAME.CFG`, `DATA/1_1.MVE`.
/// Each component obeys `validateName`. One `/` separates two components; a leading, trailing
/// or doubled separator is invalid. A name has at most `max_asset_depth` components and
/// `max_asset_name_len` bytes. Providers match names DOS-style, that is ASCII case-insensitive
/// (`assetNameEql`), so `game.cfg` opens `GAME.CFG`. Listings return the upper-case form
/// (`canonicalAssetName`), and `list` matches its prefix the same way.
pub fn validateAssetName(name: []const u8) error{InvalidName}!void {
    if (name.len == 0 or name.len > max_asset_name_len) return error.InvalidName;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, name, asset_separator);
    while (it.next()) |component| {
        try validateName(component);
        depth += 1;
        if (depth > max_asset_depth) return error.InvalidName;
    }
}

/// ASCII case-insensitive equality: the DOS matching rule for logical names.
pub fn assetNameEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The case-insensitive prefix test of `list(prefix)`.
pub fn assetNameStartsWith(name: []const u8, prefix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, prefix);
}

/// The canonical (upper-case) form of a logical name, as listings return it.
pub fn canonicalAssetName(name: []const u8, out: []u8) []u8 {
    return std.ascii.upperString(out, name);
}

/// The sort order of canonical names, for consistent listings.
pub fn assetNameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "frame validation uses checked arithmetic" {
    const pixels: [48]u8 = @splat(0);
    try (RgbaFrame{ .width = 4, .height = 3, .stride = 16, .pixels = &pixels }).validate();
    try std.testing.expectError(error.InvalidFrame, (RgbaFrame{ .width = 0, .height = 3, .stride = 16, .pixels = &pixels }).validate());
    try std.testing.expectError(error.InvalidFrame, (RgbaFrame{ .width = 4, .height = 3, .stride = 15, .pixels = &pixels }).validate());
    try std.testing.expectError(error.InvalidFrame, (RgbaFrame{ .width = 4, .height = 4, .stride = 16, .pixels = &pixels }).validate());
    try std.testing.expectError(error.InvalidFrame, (RgbaFrame{ .width = std.math.maxInt(u32), .height = 2, .stride = std.math.maxInt(usize), .pixels = &pixels }).validate());
    // Padded rows: the last row needs only its active bytes.
    const padded: [56]u8 = @splat(0);
    try (RgbaFrame{ .width = 4, .height = 3, .stride = 20, .pixels = &padded }).validate();
}

test "asset names allow directory components and match case-insensitively" {
    try validateAssetName("GAME.CFG");
    try validateAssetName("DATA/1_1.MVE");
    try validateAssetName("MANUAL/GAME/X.TXT");
    try std.testing.expectError(error.InvalidName, validateAssetName(""));
    try std.testing.expectError(error.InvalidName, validateAssetName("/GAME.CFG"));
    try std.testing.expectError(error.InvalidName, validateAssetName("DATA/"));
    try std.testing.expectError(error.InvalidName, validateAssetName("DATA//X"));
    try std.testing.expectError(error.InvalidName, validateAssetName("../GAME.EXE"));
    try std.testing.expectError(error.InvalidName, validateAssetName("DATA/.hidden"));
    try std.testing.expectError(error.InvalidName, validateAssetName("A/B/C/D/E/F/G/H/I"));
    var long: [max_asset_name_len + 1]u8 = @splat('x');
    long[64] = '/';
    try std.testing.expectError(error.InvalidName, validateAssetName(&long));
    try std.testing.expect(assetNameEql("game.cfg", "GAME.CFG"));
    try std.testing.expect(!assetNameEql("GAME.CFG", "GAME.EXE"));
    try std.testing.expect(assetNameStartsWith("GAME0001.PT", "game"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("DATA/1_1.MVE", canonicalAssetName("data/1_1.mve", &buf));
}

test "name validation" {
    try validateName("GAME0001.P");
    try validateName("a-b_c.9");
    try std.testing.expectError(error.InvalidName, validateName(""));
    try std.testing.expectError(error.InvalidName, validateName(".hidden"));
    try std.testing.expectError(error.InvalidName, validateName("a..b"));
    try std.testing.expectError(error.InvalidName, validateName("dir/name"));
    try std.testing.expectError(error.InvalidName, validateName("sp ace"));
    try std.testing.expectError(error.InvalidName, validateName("é"));
    const long: [65]u8 = @splat('x');
    try std.testing.expectError(error.InvalidName, validateName(&long));
}
