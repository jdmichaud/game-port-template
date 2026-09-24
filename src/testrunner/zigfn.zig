//! The `zig.function` driver: replays the reference vectors of a routine through its Zig
//! implementation. Config: `{"function": "<routine>", "reference": "<obs file>"}`.
//!
//! This is how the port's arithmetic is held to the original's: the original's routine is run over
//! many inputs outside this repository (under an emulator or an interpreter), its outputs are
//! recorded once as an observation file, and this driver calls the port's function on the same
//! inputs. For each observation of the reference file, the driver reads the `in` object, calls the
//! registered function and observes the output that the observation names (the text after `].`)
//! under the observation's own name. The expectations of the case are the same file, so the
//! comparison is exact and ordered. An unknown function gives `unsupported`. An observation without
//! an `in` object, with a missing input or with an input outside the documented domain gives a
//! `reference_error` that names the vector.
const std = @import("std");
const testkit = @import("testkit");
const gameport = @import("gameport");
const DriverContext = testkit.DriverContext;
const DriverError = testkit.exec.DriverError;

pub fn run(ctx: *DriverContext) DriverError!void {
    const name = ctx.case.configString("function") orelse return ctx.fail(error.InvalidConfig, "config.function is missing");
    const path = ctx.case.configString("reference") orelse return ctx.fail(error.InvalidConfig, "config.reference is missing");
    const function = findFunction(name) orelse {
        ctx.message = try std.fmt.allocPrint(ctx.arena, "unknown function: {s}", .{name});
        return error.Unsupported;
    };
    const list = try ctx.readObservations(path);
    for (list, 0..) |o, index| {
        const map = o.inputs orelse {
            ctx.message = try std.fmt.allocPrint(ctx.arena, "observation #{d} {s} carries no in object", .{ index, o.name });
            return error.ReferenceError;
        };
        const output = outputName(o.name) orelse {
            ctx.message = try std.fmt.allocPrint(ctx.arena, "observation #{d} {s} does not name an output", .{ index, o.name });
            return error.ReferenceError;
        };
        const value = function.call(.{ .map = map }, output) catch |err| {
            ctx.message = try std.fmt.allocPrint(ctx.arena, "observation #{d} {s}: {s}", .{ index, o.name, describe(err) });
            return error.ReferenceError;
        };
        try ctx.sink.unsigned(o.name, value);
    }
}

const CallError = error{
    /// The `in` object lacks an input the function needs.
    MissingInput,
    /// An input is not a `u:` value that fits the width of the routine.
    InvalidInput,
    /// The observation names an output that the function does not produce.
    UnknownOutput,
    /// The input is outside the documented domain: the original faults or does not return.
    OutOfDomain,
};

fn describe(err: CallError) []const u8 {
    return switch (err) {
        error.MissingInput => "the in object lacks an input the function needs",
        error.InvalidInput => "an input is not an unsigned value of the routine's width",
        error.UnknownOutput => "the observation names an output the function does not produce",
        error.OutOfDomain => "the input is outside the documented domain (the original faults or never returns)",
    };
}

/// The inputs of one observation, typed when they are read.
const Inputs = struct {
    map: std.json.ObjectMap,

    fn unsigned(self: Inputs, key: []const u8, comptime T: type) CallError!T {
        const v = self.map.get(key) orelse return error.MissingInput;
        if (v != .string) return error.InvalidInput;
        const typed = testkit.Value.parse(v.string) catch return error.InvalidInput;
        const n = typed.asUnsigned() orelse return error.InvalidInput;
        if (n > std.math.maxInt(T)) return error.InvalidInput;
        return @intCast(n);
    }
};

const Function = struct {
    name: []const u8,
    call: *const fn (Inputs, []const u8) CallError!u64,
};

/// The routines that the reference suite replays. A port registers each routine of the original
/// that it reimplements and that has recorded vectors.
const functions = [_]Function{
    .{ .name = "xorshift32", .call = xorshift32 },
};

pub fn findFunction(name: []const u8) ?Function {
    for (functions) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// `routine[inputs].output` -> `output`.
fn outputName(name: []const u8) ?[]const u8 {
    const close = std.mem.lastIndexOf(u8, name, "].") orelse return null;
    const out = name[close + 2 ..];
    return if (out.len == 0) null else out;
}

/// The placeholder game's generator: one step from `seed`. Its only output is the new seed.
fn xorshift32(in: Inputs, output: []const u8) CallError!u64 {
    if (!std.mem.eql(u8, output, "seed")) return error.UnknownOutput;
    var state: gameport.game.State = .{ .seed = try in.unsigned("seed", u32) };
    return state.next();
}

test "output names and the function table" {
    try std.testing.expectEqualStrings("seed", outputName("xorshift32[seed=0x00000001].seed").?);
    try std.testing.expect(outputName("no-output") == null);
    try std.testing.expect(outputName("x[a=1].") == null);
    try std.testing.expect(findFunction("xorshift32") != null);
    try std.testing.expect(findFunction("nothing") == null);
}

test "inputs are typed and checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"seed\":\"u:1\",\"wide\":\"u:4294967296\",\"typed\":\"i:5\"}", .{});
    const in = Inputs{ .map = parsed.object };
    try std.testing.expectEqual(@as(u32, 1), try in.unsigned("seed", u32));
    try std.testing.expectError(error.InvalidInput, in.unsigned("wide", u32));
    try std.testing.expectError(error.InvalidInput, in.unsigned("typed", u32));
    try std.testing.expectError(error.MissingInput, in.unsigned("absent", u32));
    // Marsaglia's xorshift32 from 1: 270369.
    try std.testing.expectEqual(@as(u64, 270369), try xorshift32(in, "seed"));
    try std.testing.expectError(error.UnknownOutput, xorshift32(in, "eax"));
}
