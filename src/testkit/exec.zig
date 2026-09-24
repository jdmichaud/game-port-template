//! In-process execution of one case: input verification, loading of the expected observations,
//! the driver call, the comparison and the mapping of driver errors to verdicts. The runner has
//! the wall-clock watchdog and the crash isolation: it executes each case in a child process.
const std = @import("std");
const case_mod = @import("case.zig");
const Case = case_mod.Case;
const observation = @import("observation.zig");
const Observation = observation.Observation;
const Sink = observation.Sink;
const verdict_mod = @import("verdict.zig");
const Verdict = verdict_mod.Verdict;
const Comparison = verdict_mod.Comparison;
const digest = @import("digest.zig");

pub const DriverError = error{
    /// The driver or a configuration it was given is not supported.
    Unsupported,
    /// A bound was exceeded; `ctx.limit` names it.
    LimitExceeded,
    /// A required input is absent; `ctx.message` names it.
    MissingInput,
    /// An input cannot be read or decoded; `ctx.message` names it.
    ReferenceError,
    /// The driver configuration is not valid; `ctx.message` gives the reason.
    InvalidConfig,
    OutOfMemory,
    Io,
};

/// Resolves fixture paths. A fixture is a file of the repository: its path is relative to the
/// repository root. An absolute path names no fixture, so a case cannot read outside the tree.
pub const Resolver = struct {
    io: std.Io,
    root: []const u8,

    pub fn resolve(r: *const Resolver, arena: std.mem.Allocator, path: []const u8) error{ OutOfMemory, MissingInput }![]const u8 {
        if (std.fs.path.isAbsolute(path)) return error.MissingInput;
        const in_root = try std.fs.path.join(arena, &.{ r.root, path });
        return if (digest.fileExists(r.io, in_root)) in_root else error.MissingInput;
    }
};

pub const DriverContext = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    case: *const Case,
    sink: *Sink,
    resolver: *const Resolver,
    /// The limit a driver exceeded (`error.LimitExceeded`).
    limit: ?[]const u8 = null,
    /// A short explanation for `MissingInput`, `ReferenceError`, `InvalidConfig` or `Io`.
    message: ?[]const u8 = null,

    /// Resolves a path or fails the case as `missing_input`.
    pub fn resolvePath(ctx: *DriverContext, path: []const u8) DriverError![]const u8 {
        return ctx.resolver.resolve(ctx.arena, path) catch |err| switch (err) {
            error.MissingInput => {
                ctx.message = try std.fmt.allocPrint(ctx.arena, "input missing: {s}", .{path});
                return error.MissingInput;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// Reads a file resolved through `resolvePath`.
    pub fn readInput(ctx: *DriverContext, path: []const u8) DriverError![]u8 {
        const resolved = try ctx.resolvePath(path);
        return digest.readFile(ctx.io, ctx.arena, resolved) catch |err| switch (err) {
            error.FileNotFound => {
                ctx.message = try std.fmt.allocPrint(ctx.arena, "input missing: {s}", .{path});
                return error.MissingInput;
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => {
                ctx.message = try std.fmt.allocPrint(ctx.arena, "cannot read: {s}", .{path});
                return error.Io;
            },
        };
    }

    /// Loads an observation file resolved through `resolvePath`.
    pub fn readObservations(ctx: *DriverContext, path: []const u8) DriverError![]Observation {
        const bytes = try ctx.readInput(path);
        const parsed = observation.parseFile(ctx.arena, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidObservationFile => {
                ctx.message = try std.fmt.allocPrint(ctx.arena, "not a testkit-observations/1 file: {s}", .{path});
                return error.ReferenceError;
            },
        };
        return parsed.observations;
    }

    pub fn fail(ctx: *DriverContext, err: DriverError, message: []const u8) DriverError {
        ctx.message = message;
        return err;
    }

    pub fn exceeded(ctx: *DriverContext, limit: []const u8) DriverError {
        ctx.limit = limit;
        return error.LimitExceeded;
    }
};

pub const DriverFn = *const fn (*DriverContext) DriverError!void;

pub const Driver = struct {
    name: []const u8,
    run: DriverFn,
};

pub fn findDriver(drivers: []const Driver, name: []const u8) ?Driver {
    for (drivers) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

pub const CaseResult = struct {
    verdict: Verdict,
    comparison: ?Comparison,
    detail: ?[]const u8,
    elapsed_ms: u64,
    /// The observations of the driver, for fixture authoring (`gameport-test case --print-actual`).
    actual: []const Observation = &.{},
};

/// Verifies each listed input (presence and digest), loads the expected observations, runs the
/// driver and compares. The result is allocated in `arena`.
pub fn runCase(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, resolver: *const Resolver, drivers: []const Driver, c: *const Case) error{OutOfMemory}!CaseResult {
    const started = std.Io.Timestamp.now(io, .awake);
    var result = runCaseInner(gpa, arena, io, resolver, drivers, c) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    const ended = std.Io.Timestamp.now(io, .awake);
    const elapsed_ns = ended.nanoseconds - started.nanoseconds;
    result.elapsed_ms = if (elapsed_ns <= 0) 0 else @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
    return result;
}

fn runCaseInner(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, resolver: *const Resolver, drivers: []const Driver, c: *const Case) error{OutOfMemory}!CaseResult {
    const driver = findDriver(drivers, c.driver) orelse return .{
        .verdict = .unsupported,
        .comparison = null,
        .detail = try std.fmt.allocPrint(arena, "unknown driver: {s}", .{c.driver}),
        .elapsed_ms = 0,
    };

    if (try verifyInputs(gpa, arena, io, resolver, c)) |failure| return failure;

    // Expected observations: the file first, then the inline list.
    var expected: std.ArrayList(Observation) = .empty;
    if (c.expected_file) |path| {
        const resolved = resolver.resolve(arena, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingInput => return .{
                .verdict = .missing_input,
                .comparison = null,
                .detail = try std.fmt.allocPrint(arena, "expected_file missing: {s}", .{path}),
                .elapsed_ms = 0,
            },
        };
        const bytes = digest.readFile(io, arena, resolved) catch return .{
            .verdict = .reference_error,
            .comparison = null,
            .detail = try std.fmt.allocPrint(arena, "expected_file unreadable: {s}", .{path}),
            .elapsed_ms = 0,
        };
        const parsed = observation.parseFile(arena, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidObservationFile => return .{
                .verdict = .reference_error,
                .comparison = null,
                .detail = try std.fmt.allocPrint(arena, "expected_file is not a testkit-observations/1 file: {s}", .{path}),
                .elapsed_ms = 0,
            },
        };
        try expected.appendSlice(arena, parsed.observations);
    }
    try expected.appendSlice(arena, c.expected);

    var sink = Sink.init(arena);
    var ctx = DriverContext{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .case = c,
        .sink = &sink,
        .resolver = resolver,
    };
    driver.run(&ctx) catch |err| {
        const mapped: Verdict = switch (err) {
            error.Unsupported => .unsupported,
            error.LimitExceeded => .timeout,
            error.MissingInput => .missing_input,
            error.ReferenceError, error.InvalidConfig => .reference_error,
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => .infrastructure,
        };
        const detail = if (err == error.LimitExceeded)
            try std.fmt.allocPrint(arena, "limit {s}", .{ctx.limit orelse "unnamed"})
        else
            ctx.message orelse @errorName(err);
        return .{ .verdict = mapped, .comparison = null, .detail = detail, .elapsed_ms = 0, .actual = sink.slice() };
    };

    const comparison = try verdict_mod.compare(arena, expected.items, sink.slice());
    return .{ .verdict = comparison.verdict, .comparison = comparison, .detail = null, .elapsed_ms = 0, .actual = sink.slice() };
}

/// Checks that each listed input exists and has the listed digest. Returns a failing result, or
/// null when all inputs are correct.
pub fn verifyInputs(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, resolver: *const Resolver, c: *const Case) error{OutOfMemory}!?CaseResult {
    for (c.inputs) |input| {
        const resolved = resolver.resolve(arena, input.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingInput => return .{
                .verdict = .missing_input,
                .comparison = null,
                .detail = try std.fmt.allocPrint(arena, "input missing: {s}", .{input.path}),
                .elapsed_ms = 0,
            },
        };
        const actual = digest.fileSha256Hex(io, gpa, resolved) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{
                .verdict = .reference_error,
                .comparison = null,
                .detail = try std.fmt.allocPrint(arena, "input unreadable: {s}", .{input.path}),
                .elapsed_ms = 0,
            },
        };
        if (!std.mem.eql(u8, &actual, input.sha256)) {
            return .{
                .verdict = .reference_error,
                .comparison = null,
                .detail = try std.fmt.allocPrint(arena, "digest mismatch: {s} is {s}, case lists {s}", .{ input.path, &actual, input.sha256 }),
                .elapsed_ms = 0,
            };
        }
    }
    return null;
}

const testing_drivers = [_]Driver{
    .{ .name = "test.echo", .run = echoDriver },
    .{ .name = "test.limit", .run = limitDriver },
};

fn echoDriver(ctx: *DriverContext) DriverError!void {
    const obj = ctx.case.configObject() orelse return ctx.fail(error.InvalidConfig, "config missing");
    const values = obj.get("values") orelse return ctx.fail(error.InvalidConfig, "config.values missing");
    const list = observation.parseArray(ctx.arena, values.array) catch return ctx.fail(error.InvalidConfig, "config.values invalid");
    for (list) |o| try ctx.sink.observe(o.name, o.value);
}

fn limitDriver(ctx: *DriverContext) DriverError!void {
    return ctx.exceeded("max_updates");
}

test "runCase maps driver results to verdicts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const resolver = Resolver{ .io = io, .root = "." };
    var diag: []const u8 = "";

    const pass_text =
        \\{"schema":"testkit-case/1","id":"p","driver":"test.echo",
        \\ "reference":{"class":"specified-contract","status":"verified","evidence":"e","redistribution":"redistributable"},
        \\ "config":{"values":[{"n":"a","v":"u:1"}]},"expected":[{"n":"a","v":"u:1"}]}
    ;
    const pass_case = try Case.parse(arena, "p", pass_text, &diag);
    const pass = try runCase(std.testing.allocator, arena, io, &resolver, &testing_drivers, &pass_case);
    try std.testing.expectEqual(Verdict.pass, pass.verdict);

    const wrong_text =
        \\{"schema":"testkit-case/1","id":"w","driver":"test.echo",
        \\ "reference":{"class":"specified-contract","status":"verified","evidence":"e","redistribution":"redistributable"},
        \\ "config":{"values":[{"n":"a","v":"u:2"}]},"expected":[{"n":"a","v":"u:1"}]}
    ;
    const wrong_case = try Case.parse(arena, "w", wrong_text, &diag);
    const wrong = try runCase(std.testing.allocator, arena, io, &resolver, &testing_drivers, &wrong_case);
    try std.testing.expectEqual(Verdict.mismatch, wrong.verdict);
    try std.testing.expectEqualStrings("u:2", wrong.comparison.?.difference.?.actual.?);

    const limit_text =
        \\{"schema":"testkit-case/1","id":"l","driver":"test.limit",
        \\ "reference":{"class":"specified-contract","status":"verified","evidence":"e","redistribution":"redistributable"}}
    ;
    const limit_case = try Case.parse(arena, "l", limit_text, &diag);
    const limit = try runCase(std.testing.allocator, arena, io, &resolver, &testing_drivers, &limit_case);
    try std.testing.expectEqual(Verdict.timeout, limit.verdict);
    try std.testing.expectEqualStrings("limit max_updates", limit.detail.?);

    const unknown_text =
        \\{"schema":"testkit-case/1","id":"u","driver":"nope",
        \\ "reference":{"class":"specified-contract","status":"verified","evidence":"e","redistribution":"redistributable"}}
    ;
    const unknown_case = try Case.parse(arena, "u", unknown_text, &diag);
    try std.testing.expectEqual(Verdict.unsupported, (try runCase(std.testing.allocator, arena, io, &resolver, &testing_drivers, &unknown_case)).verdict);

    const missing_text =
        \\{"schema":"testkit-case/1","id":"m","driver":"test.echo",
        \\ "reference":{"class":"original-derived","status":"verified","evidence":"e","redistribution":"restricted"},
        \\ "inputs":{"files":[{"path":"tests/never/there.bin","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}}
    ;
    const missing_case = try Case.parse(arena, "m", missing_text, &diag);
    try std.testing.expectEqual(Verdict.missing_input, (try runCase(std.testing.allocator, arena, io, &resolver, &testing_drivers, &missing_case)).verdict);
}

test "verifyInputs detects a modified reference file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ref.obs.json", .data = "original" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const resolver = Resolver{ .io = io, .root = dir_path };
    var diag: []const u8 = "";
    const text = try std.fmt.allocPrint(arena,
        \\{{"schema":"testkit-case/1","id":"r","driver":"test.echo",
        \\ "reference":{{"class":"original-derived","status":"verified","evidence":"e","redistribution":"restricted"}},
        \\ "inputs":{{"files":[{{"path":"ref.obs.json","sha256":"{s}"}}]}},"config":{{"values":[]}}}}
    , .{&digest.sha256Hex("original")});
    const c = try Case.parse(arena, "r", text, &diag);
    try std.testing.expect((try verifyInputs(std.testing.allocator, arena, io, &resolver, &c)) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "ref.obs.json", .data = "tampered" });
    const changed = (try verifyInputs(std.testing.allocator, arena, io, &resolver, &c)).?;
    try std.testing.expectEqual(Verdict.reference_error, changed.verdict);
    try std.testing.expect(std.mem.indexOf(u8, changed.detail.?, "digest mismatch") != null);
}
