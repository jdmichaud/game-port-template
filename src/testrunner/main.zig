//! gameport-test: the scenario and comparison runner.
//!
//!   gameport-test run <suite-dir | case-file> [--report PATH] [--root DIR]
//!                  [--only ID] [--in-process] [--self EXE]
//!   gameport-test case <case-file> [--root DIR] [--print-actual]
//!                  (one JSON report line, or the actual observations with --print-actual)
//!   gameport-test list <suite-dir>
//!   gameport-test digest <file>
//!
//! Without `--in-process`, `run` executes each case in its own child process
//! (`gameport-test case ...`) under the wall-clock bound of the case. Thus a stalled driver gives
//! `timeout` and a crashed driver gives `crash`. Then `run` checks that the reference inputs of
//! the case are unchanged and prints the case's verdict, and with `--report` writes its report
//! line to that file. At the end it prints a summary. It exits with a non-zero status when a
//! verified expectation failed or no case ran.
const std = @import("std");
const testkit = @import("testkit");
const drivers = @import("drivers.zig");

const Verdict = testkit.Verdict;
const Case = testkit.Case;
const report = testkit.report;
const exec = testkit.exec;

const usage =
    \\usage: gameport-test run <suite-dir|case-file> [--report PATH] [--root DIR] [--only ID] [--in-process] [--self EXE]
    \\       gameport-test case <case-file> [--root DIR] [--print-actual]
    \\       gameport-test list <suite-dir>
    \\       gameport-test digest <file>
    \\
;

const Options = struct {
    root: []const u8 = ".",
    report: ?[]const u8 = null,
    in_process: bool = false,
    only: ?[]const u8 = null,
    self_exe: ?[]const u8 = null,
    positional: ?[]const u8 = null,
    print_actual: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const command = args.next() orelse return usageExit(io);

    var opts: Options = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            opts.root = args.next() orelse return usageExit(io);
        } else if (std.mem.eql(u8, arg, "--report")) {
            opts.report = args.next() orelse return usageExit(io);
        } else if (std.mem.eql(u8, arg, "--only")) {
            opts.only = args.next() orelse return usageExit(io);
        } else if (std.mem.eql(u8, arg, "--self")) {
            opts.self_exe = args.next() orelse return usageExit(io);
        } else if (std.mem.eql(u8, arg, "--in-process")) {
            opts.in_process = true;
        } else if (std.mem.eql(u8, arg, "--print-actual")) {
            opts.print_actual = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageExit(io);
        } else {
            opts.positional = arg;
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (std.mem.eql(u8, command, "run")) {
        const target = opts.positional orelse return usageExit(io);
        const code = try runSuite(gpa, arena, io, opts, target);
        std.process.exit(code);
    } else if (std.mem.eql(u8, command, "case")) {
        const path = opts.positional orelse return usageExit(io);
        try runOneAndPrint(gpa, arena, io, opts, path);
    } else if (std.mem.eql(u8, command, "list")) {
        const dir = opts.positional orelse return usageExit(io);
        const cases = try loadSuite(arena, io, dir);
        var out = stdoutWriter(io);
        for (cases) |c| {
            switch (c) {
                .ok => |k| try out.interface.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ k.id, k.driver, @tagName(k.class), @tagName(k.status), k.path }),
                .invalid => |inv| try out.interface.print("INVALID\t{s}\t{s}\n", .{ inv.path, inv.diag }),
            }
        }
        try out.interface.flush();
    } else if (std.mem.eql(u8, command, "digest")) {
        const path = opts.positional orelse return usageExit(io);
        const hex = testkit.digest.fileSha256Hex(io, gpa, path) catch |err| {
            std.log.err("cannot digest {s}: {s}", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        var out = stdoutWriter(io);
        try out.interface.print("{s}  {s}\n", .{ &hex, path });
        try out.interface.flush();
    } else {
        return usageExit(io);
    }
}

fn stdoutWriter(io: std.Io) std.Io.File.Writer {
    const S = struct {
        var buf: [16 * 1024]u8 = undefined;
    };
    return std.Io.File.stdout().writerStreaming(io, &S.buf);
}

fn usageExit(io: std.Io) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(usage);
    try w.interface.flush();
    std.process.exit(2);
}

const LoadedCase = union(enum) {
    ok: Case,
    invalid: struct { path: []const u8, diag: []const u8 },
};

/// Loads one case file or every `*.case.json` in a directory, sorted by name.
fn loadSuite(arena: std.mem.Allocator, io: std.Io, target: []const u8) ![]LoadedCase {
    var list: std.ArrayList(LoadedCase) = .empty;
    if (std.mem.endsWith(u8, target, ".case.json")) {
        try list.append(arena, try loadCase(arena, io, target));
        return list.toOwnedSlice(arena);
    }
    var dir = std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open suite {s}: {s}", .{ target, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Some file systems give no entry type. The read below then decides if it is a file.
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (!std.mem.endsWith(u8, entry.name, ".case.json")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ target, name });
        try list.append(arena, try loadCase(arena, io, path));
    }
    return list.toOwnedSlice(arena);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn loadCase(arena: std.mem.Allocator, io: std.Io, path: []const u8) !LoadedCase {
    const bytes = testkit.digest.readFile(io, arena, path) catch |err| {
        return .{ .invalid = .{ .path = path, .diag = @errorName(err) } };
    };
    var diag: []const u8 = "";
    const c = Case.parse(arena, path, bytes, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCase => return .{ .invalid = .{ .path = path, .diag = diag } },
    };
    return .{ .ok = c };
}

/// `gameport-test case`: runs one case in this process and prints its report line, or its actual
/// observations with `--print-actual`.
fn runOneAndPrint(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, opts: Options, path: []const u8) !void {
    var out = stdoutWriter(io);
    const loaded = try loadCase(arena, io, path);
    const entry = switch (loaded) {
        .invalid => |inv| invalidEntry(arena, inv.path, inv.diag),
        .ok => |*c| blk: {
            const resolver = exec.Resolver{ .io = io, .root = opts.root };
            const result = try exec.runCase(gpa, arena, io, &resolver, &drivers.drivers, c);
            if (opts.print_actual) {
                try writeObservations(&out.interface, c, result.actual);
                try out.interface.flush();
                return;
            }
            break :blk try entryFromResult(arena, c, result);
        },
    };
    try entry.write(&out.interface);
    try out.interface.flush();
}

/// Prints the actual observations of the driver as a `testkit-observations/1` document. A fixture
/// author copies this document into `expected` or saves it as an `expected_file`.
fn writeObservations(w: *std.Io.Writer, c: *const Case, actual: []const testkit.Observation) !void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_1 } };
    try js.beginObject();
    try js.objectField("schema");
    try js.write(testkit.observation.schema);
    try js.objectField("producer");
    try js.beginObject();
    try js.objectField("tool");
    try js.write("gameport-test case --print-actual");
    try js.objectField("case");
    try js.write(c.id);
    try js.objectField("driver");
    try js.write(c.driver);
    try js.endObject();
    try js.objectField("observations");
    try js.beginArray();
    var text_buf: [512]u8 = undefined;
    for (actual) |o| {
        try js.beginObject();
        try js.objectField("n");
        try js.write(o.name);
        try js.objectField("v");
        try js.write(try std.fmt.bufPrint(&text_buf, "{f}", .{o.value}));
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try w.writeByte('\n');
}

fn invalidEntry(arena: std.mem.Allocator, path: []const u8, diag: []const u8) report.Entry {
    return .{
        .case_id = path,
        .case_path = path,
        .driver = "",
        .class = .@"specified-contract",
        .status = .verified,
        .verdict = .reference_error,
        .expected_verdict = .pass,
        .outcome = .failed,
        .detail = std.fmt.allocPrint(arena, "invalid case: {s}", .{diag}) catch "invalid case",
        .difference = null,
        .compared = 0,
        .elapsed_ms = 0,
        .replay = "",
        .inputs = &.{},
    };
}

fn replayCommand(arena: std.mem.Allocator, c: *const Case) ![]const u8 {
    return std.fmt.allocPrint(arena, "gameport-test case {s}", .{c.path});
}

fn entryFromResult(arena: std.mem.Allocator, c: *const Case, result: exec.CaseResult) !report.Entry {
    return .{
        .case_id = c.id,
        .case_path = c.path,
        .driver = c.driver,
        .class = c.class,
        .status = c.status,
        .verdict = result.verdict,
        .expected_verdict = c.expected_verdict,
        .outcome = report.outcomeOf(result.verdict, c.expected_verdict, c.status),
        .detail = result.detail,
        .difference = if (result.comparison) |cmp| cmp.difference else null,
        .compared = if (result.comparison) |cmp| cmp.compared else 0,
        .elapsed_ms = result.elapsed_ms,
        .replay = try replayCommand(arena, c),
        .inputs = c.inputs,
    };
}

/// `gameport-test run`: runs each case in isolation, reports it, and prints a summary. Returns the
/// exit code.
fn runSuite(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, opts: Options, target: []const u8) !u8 {
    var out = stdoutWriter(io);
    // The general-purpose allocator resolves the path. On this Zig revision, a resolution in the
    // arena can corrupt an earlier arena allocation.
    const self_exe_owned: ?[:0]u8 = if (opts.self_exe == null) (std.process.executablePathAlloc(io, gpa) catch null) else null;
    defer if (self_exe_owned) |owned| gpa.free(owned);
    const self_exe: []const u8 = opts.self_exe orelse (self_exe_owned orelse "gameport-test");
    const cases = try loadSuite(arena, io, target);

    // The report file is written only when `--report` names one. Standard output gets each case
    // and the summary either way.
    var report_buf: [64 * 1024]u8 = undefined;
    var report_file: ?std.Io.File = null;
    defer if (report_file) |f| f.close(io);
    var report_writer: std.Io.File.Writer = undefined;
    if (opts.report) |report_path| {
        if (std.fs.path.dirname(report_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
                std.log.err("cannot create report directory {s}: {s}", .{ dir, @errorName(err) });
                return 2;
            };
        }
        report_file = std.Io.Dir.cwd().createFile(io, report_path, .{}) catch |err| {
            std.log.err("cannot create report {s}: {s}", .{ report_path, @errorName(err) });
            return 2;
        };
        report_writer = report_file.?.writer(io, &report_buf);
    }

    const resolver = exec.Resolver{ .io = io, .root = opts.root };

    var summary = report.Summary{};
    var ran: usize = 0;
    for (cases) |loaded| {
        var entry: report.Entry = switch (loaded) {
            .invalid => |inv| invalidEntry(arena, inv.path, inv.diag),
            .ok => |*c| blk: {
                if (opts.only) |only| if (!std.mem.eql(u8, only, c.id)) continue;
                break :blk if (opts.in_process)
                    try entryFromResult(arena, c, try exec.runCase(gpa, arena, io, &resolver, &drivers.drivers, c))
                else
                    try runIsolated(gpa, arena, io, opts, self_exe, c);
            },
        };
        ran += 1;

        // The reference inputs must be unchanged after the case, whatever the driver did.
        if (loaded == .ok and entry.verdict != .missing_input and entry.verdict != .reference_error) {
            if (try exec.verifyInputs(gpa, arena, io, &resolver, &loaded.ok)) |changed| {
                entry.verdict = .reference_error;
                entry.detail = try std.fmt.allocPrint(arena, "reference input changed during the case: {s}", .{changed.detail orelse ""});
                entry.outcome = report.outcomeOf(entry.verdict, entry.expected_verdict, entry.status);
            }
        }

        summary.add(entry.verdict, entry.outcome);
        if (report_file != null) {
            try entry.write(&report_writer.interface);
            try report_writer.interface.flush();
        }
        const marker: []const u8 = switch (entry.outcome) {
            .ok => "ok        ",
            .failed => "FAILED    ",
            .diagnostic => "diagnostic",
        };
        try out.interface.print("{s} {s}: {s}", .{ marker, entry.case_id, @tagName(entry.verdict) });
        if (entry.verdict != entry.expected_verdict) try out.interface.print(" (expected {s})", .{@tagName(entry.expected_verdict)});
        if (entry.detail) |d| try out.interface.print(" - {s}", .{d});
        if (entry.difference) |d| {
            try out.interface.print(" - first difference at {d} {s}", .{ d.index, d.name });
            if (d.actual_name) |an| try out.interface.print(" (actual name {s})", .{an});
            try out.interface.print(": expected {s}, actual {s}", .{ d.expected orelse "<none>", d.actual orelse "<none>" });
        }
        try out.interface.print(" [{d} ms]\n", .{entry.elapsed_ms});
        try out.interface.flush();
    }

    try out.interface.print("{s}: ", .{target});
    try summary.write(&out.interface);
    if (opts.report) |report_path| try out.interface.print("report: {s}\n", .{report_path});
    try out.interface.flush();
    if (ran == 0) {
        std.log.err("no case ran in {s}", .{target});
        return 2;
    }
    return if (summary.failed > 0) 1 else 0;
}

/// Runs a case in a child process under its wall-clock bound.
fn runIsolated(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, opts: Options, self_exe: []const u8, c: *const Case) !report.Entry {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self_exe, "case", c.path, "--root", opts.root });

    const wall_ms = c.bounds.wallClockMs();
    const started = std.Io.Timestamp.now(io, .awake);
    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(@intCast(wall_ms)), .clock = .awake } },
    }) catch |err| {
        const elapsed = elapsedMs(io, started);
        return switch (err) {
            error.Timeout => synthesized(arena, c, .timeout, try std.fmt.allocPrint(arena, "limit wall_clock_ms {d}", .{wall_ms}), elapsed),
            else => synthesized(arena, c, .infrastructure, try std.fmt.allocPrint(arena, "cannot run the case process: {s}", .{@errorName(err)}), elapsed),
        };
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const elapsed = elapsedMs(io, started);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                return synthesized(arena, c, .crash, try std.fmt.allocPrint(arena, "case process exited with code {d}", .{code}), elapsed);
            }
        },
        .signal => |sig| return synthesized(arena, c, .crash, try std.fmt.allocPrint(arena, "case process terminated by signal {t}", .{sig}), elapsed),
        .stopped, .unknown => return synthesized(arena, c, .crash, "case process ended unexpectedly", elapsed),
    }

    return parseChildEntry(arena, c, result.stdout, elapsed) catch synthesized(arena, c, .infrastructure, "case process printed no report line", elapsed);
}

fn elapsedMs(io: std.Io, started: std.Io.Timestamp) u64 {
    const now = std.Io.Timestamp.now(io, .awake);
    const delta = now.nanoseconds - started.nanoseconds;
    return if (delta <= 0) 0 else @intCast(@divTrunc(delta, std.time.ns_per_ms));
}

fn synthesized(arena: std.mem.Allocator, c: *const Case, verdict: Verdict, detail: []const u8, elapsed_ms: u64) report.Entry {
    return .{
        .case_id = c.id,
        .case_path = c.path,
        .driver = c.driver,
        .class = c.class,
        .status = c.status,
        .verdict = verdict,
        .expected_verdict = c.expected_verdict,
        .outcome = report.outcomeOf(verdict, c.expected_verdict, c.status),
        .detail = detail,
        .difference = null,
        .compared = 0,
        .elapsed_ms = elapsed_ms,
        .replay = replayCommand(arena, c) catch "",
        .inputs = c.inputs,
    };
}

/// Rebuilds the entry from the report line of the child, so that the parent owns the record.
fn parseChildEntry(arena: std.mem.Allocator, c: *const Case, stdout: []const u8, elapsed_ms: u64) !report.Entry {
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, stdout, "\r\n"), '\n');
    const line = lines.first();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    if (root != .object) return error.InvalidReport;
    const obj = root.object;
    const verdict_name = getString(obj, "verdict") orelse return error.InvalidReport;
    const verdict = std.meta.stringToEnum(Verdict, verdict_name) orelse return error.InvalidReport;
    var entry = synthesized(arena, c, verdict, "", elapsed_ms);
    entry.detail = getString(obj, "detail");
    if (obj.get("compared")) |v| if (v == .integer and v.integer >= 0) {
        entry.compared = @intCast(v.integer);
    };
    if (obj.get("elapsed_ms")) |v| if (v == .integer and v.integer >= 0) {
        entry.elapsed_ms = @intCast(v.integer);
    };
    if (obj.get("difference")) |d| if (d == .object) {
        const index_value = d.object.get("index") orelse return error.InvalidReport;
        if (index_value != .integer or index_value.integer < 0) return error.InvalidReport;
        entry.difference = .{
            .index = @intCast(index_value.integer),
            .name = getString(d.object, "name") orelse "",
            .actual_name = getString(d.object, "actual_name"),
            .expected = getString(d.object, "expected"),
            .actual = getString(d.object, "actual"),
        };
    };
    return entry;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

test {
    _ = drivers;
    _ = @import("zigfn.zig");
}
