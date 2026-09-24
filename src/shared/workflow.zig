//! The I/O workflows of the game (DESIGN.md): the requests that the game
//! submits through `Platform`, the results that it takes back, and the body of one workflow.
//!
//! A workflow is a finite job: read an asset or one range of it, list a prefix, load, replace or
//! delete a save. The game submits a job from an update and takes its completion at a later
//! update boundary; no update waits for a file. A native host runs the jobs through its executor
//! (`native/executor.zig`), one at a time, beside the frame loop. `Inline` runs them in the thread
//! that asks for them, for hosts that need a fixed order more than a free frame loop.
//!
//! Every job copies its inputs at submission and publishes an owned result, which the game
//! accepts or releases through `Completion.deinit`.
const std = @import("std");
const platform = @import("platform.zig");

/// The job identity that a submission returns. A cancellation takes it, and every completion
/// carries it.
pub const JobId = enum(u64) { none = 0, _ };

/// The size limit of `read_asset` when the caller gives none. It is enough for the largest asset
/// of the original that is not a movie. Movies are much larger and are read range by range.
pub const default_max_bytes: usize = 16 * 1024 * 1024;

/// The work of a workflow. Every variant is finite: a movie is read buffer by buffer, and a
/// transport receive loop is never a job.
pub const Request = union(enum) {
    /// The whole asset, through the shared `AssetSource.readAll` helper. Fails past `max_bytes`.
    read_asset: struct { path: []const u8, max_bytes: usize = default_max_bytes },
    /// One range of an asset: open, read at the offset, close. The job reads until the range is
    /// full or the file ends, so the result is shorter than `len` only at end of file. The
    /// completion also gives the length of the whole asset.
    read_asset_range: struct { path: []const u8, offset: u64, len: usize },
    /// The logical names under a prefix, canonical and sorted.
    list_assets: struct { prefix: []const u8 },
    /// One saved record.
    load_save: struct { name: []const u8 },
    /// Replaces a record atomically. With `required`, an orderly shutdown waits for the job.
    save_record: struct { name: []const u8, bytes: []const u8, required: bool = false },
    delete_save: struct { name: []const u8 },
    /// Every save key, sorted.
    list_saves,
};

pub const Kind = std.meta.Tag(Request);

/// The error set of every job: the asset error set, which contains the storage error set.
pub const Failure = platform.AssetError;

/// What a finished job produced. Owned values are released through the completion.
pub const Result = union(enum) {
    /// `read_asset`, `read_asset_range`, `load_save`.
    bytes: platform.OwnedBytes,
    /// `list_assets`, `list_saves`.
    names: platform.OwnedNames,
    /// `save_record`, `delete_save`.
    done,
    /// The job ended on an error; the previous state of the target is unchanged.
    failed: Failure,
    /// The job was canceled before it finished, either in the queue or at a cancellation point.
    canceled,
};

/// A finished workflow for the application. The caller owns it until `deinit`.
pub const Completion = struct {
    id: JobId,
    kind: Kind,
    /// The path, prefix or save key the job was given, copied at submission.
    name: []const u8,
    /// A cancellation was requested for this job. Its result can still be a success: a job that
    /// finished first keeps its result, and a committed save stays committed.
    cancel_requested: bool,
    result: Result,
    /// The length of the whole asset, for `read_asset` and `read_asset_range`. A reader that
    /// streams a file sizes its buffer from the first range.
    asset_length: u64 = 0,
    allocator: std.mem.Allocator,

    /// Releases the result and the copied inputs.
    pub fn deinit(self: *Completion) void {
        switch (self.result) {
            .bytes => self.result.bytes.deinit(),
            .names => self.result.names.deinit(),
            else => {},
        }
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// The bytes of a successful read, or null for any other outcome.
    pub fn bytes(self: *const Completion) ?[]const u8 {
        return switch (self.result) {
            .bytes => |b| b.bytes,
            else => null,
        };
    }

    /// Moves the bytes of a successful read out of the completion. The caller releases them with
    /// `OwnedBytes.deinit`; the completion keeps nothing to release.
    pub fn takeBytes(self: *Completion) ?platform.OwnedBytes {
        return switch (self.result) {
            .bytes => |owned| {
                self.result = .done;
                return owned;
            },
            else => null,
        };
    }
};

pub const SubmitError = error{
    /// The queue is full; the caller retries after an update.
    QueueFull,
    /// Shutdown has begun, or the host runs no workflows.
    Closed,
    OutOfMemory,
};

/// A runner of workflows that a backend forwards `Platform.ioSubmit`, `ioTake` and `ioCancel`
/// to: the native executor, or `Inline`.
pub const Jobs = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        submit: *const fn (*anyopaque, Request) SubmitError!JobId,
        take: *const fn (*anyopaque) ?Completion,
        cancel: *const fn (*anyopaque, JobId) bool,
    };

    pub fn submit(j: Jobs, request: Request) SubmitError!JobId {
        return j.vtable.submit(j.context, request);
    }
    pub fn take(j: Jobs) ?Completion {
        return j.vtable.take(j.context);
    }
    pub fn cancel(j: Jobs, id: JobId) bool {
        return j.vtable.cancel(j.context, id);
    }
};

/// The inputs of one job, as the executor copied them.
pub const Work = struct {
    kind: Kind,
    /// Path, prefix or save key. Empty for `list_saves`.
    name: []const u8,
    /// The bytes of a `save_record`.
    payload: []const u8 = &.{},
    offset: u64 = 0,
    len: usize = 0,
    max_bytes: usize = 0,
};

/// What `run` produced: the result and, for a read, the length of the whole asset.
pub const Outcome = struct {
    result: Result,
    asset_length: u64 = 0,
};

/// The body of one workflow, as ordinary calls. It uses only its own memory and the providers.
pub fn run(allocator: std.mem.Allocator, assets: platform.AssetSource, storage: platform.Storage, work: Work) Outcome {
    switch (work.kind) {
        .read_asset => {
            const owned = assets.readAll(work.name, work.max_bytes) catch |err| return .{ .result = .{ .failed = err } };
            return .{ .result = .{ .bytes = owned }, .asset_length = owned.bytes.len };
        },
        .read_asset_range => {
            const opened = assets.open(work.name) catch |err| return .{ .result = .{ .failed = err } };
            defer assets.close(opened.handle);
            const want: usize = if (work.offset >= opened.length) 0 else @intCast(@min(work.len, opened.length - work.offset));
            const buf = allocator.alloc(u8, want) catch return .{ .result = .{ .failed = error.OutOfMemory } };
            var filled: usize = 0;
            while (filled < buf.len) {
                const n = assets.readAt(opened.handle, work.offset + filled, buf[filled..]) catch |err| {
                    allocator.free(buf);
                    return .{ .result = .{ .failed = err } };
                };
                // End of file inside the range: the caller gets the bytes that exist.
                if (n == 0) break;
                filled += n;
            }
            const exact = shrink(allocator, buf, filled) orelse return .{ .result = .{ .failed = error.OutOfMemory } };
            return .{ .result = .{ .bytes = .{ .bytes = exact, .allocator = allocator } }, .asset_length = opened.length };
        },
        .list_assets => {
            const names = assets.list(work.name) catch |err| return .{ .result = .{ .failed = err } };
            return .{ .result = .{ .names = names } };
        },
        .load_save => {
            const owned = storage.load(work.name) catch |err| return .{ .result = .{ .failed = storageFailure(err) } };
            return .{ .result = .{ .bytes = owned } };
        },
        .save_record => {
            storage.save(work.name, work.payload) catch |err| return .{ .result = .{ .failed = storageFailure(err) } };
            return .{ .result = .done };
        },
        .delete_save => {
            storage.deleteSave(work.name) catch |err| return .{ .result = .{ .failed = storageFailure(err) } };
            return .{ .result = .done };
        },
        .list_saves => {
            const names = storage.listSaves() catch |err| return .{ .result = .{ .failed = storageFailure(err) } };
            return .{ .result = .{ .names = names } };
        },
    }
}

/// `buf[0..len]` as an allocation of its own length, or null when that fails. `buf` is always
/// released or reused.
fn shrink(allocator: std.mem.Allocator, buf: []u8, len: usize) ?[]u8 {
    if (len == buf.len) return buf;
    if (allocator.resize(buf, len)) return buf[0..len];
    const exact = allocator.alloc(u8, len) catch {
        allocator.free(buf);
        return null;
    };
    @memcpy(exact, buf[0..len]);
    allocator.free(buf);
    return exact;
}

/// The storage error set is a subset of the asset error set. This function does the widening.
pub fn storageFailure(err: platform.StorageError) Failure {
    return switch (err) {
        error.NotFound => error.NotFound,
        error.InvalidName => error.InvalidName,
        error.Io => error.Io,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
    };
}

/// Workflows that run in the thread that asks for them. A job runs at the first `take` after its
/// submission, so a result is never visible in the update that submitted it, as with a native
/// executor; but the order and the timing are fixed, which a test or a recorded scenario needs.
pub const Inline = struct {
    allocator: std.mem.Allocator,
    assets: platform.AssetSource,
    storage: platform.Storage,
    queue: std.ArrayList(Pending) = .empty,
    ready: std.ArrayList(Completion) = .empty,
    next_id: u64 = 1,
    max_queued: usize = 8,
    /// Jobs run by `take` so far.
    ran: u64 = 0,

    const Pending = struct { id: JobId, work: Work, canceled: bool = false };

    pub fn init(allocator: std.mem.Allocator, assets: platform.AssetSource, storage: platform.Storage) Inline {
        return .{ .allocator = allocator, .assets = assets, .storage = storage };
    }

    pub fn jobs(self: *Inline) Jobs {
        return .{ .context = self, .vtable = &jobs_vtable };
    }

    const jobs_vtable = Jobs.VTable{
        .submit = jobsSubmit,
        .take = jobsTake,
        .cancel = jobsCancel,
    };
    fn jobsSubmit(ctx: *anyopaque, request: Request) SubmitError!JobId {
        const self: *Inline = @ptrCast(@alignCast(ctx));
        return self.submit(request);
    }
    fn jobsTake(ctx: *anyopaque) ?Completion {
        const self: *Inline = @ptrCast(@alignCast(ctx));
        return self.take();
    }
    fn jobsCancel(ctx: *anyopaque, id: JobId) bool {
        const self: *Inline = @ptrCast(@alignCast(ctx));
        return self.cancel(id);
    }

    pub fn deinit(self: *Inline) void {
        for (self.queue.items) |pending| self.freeWork(pending.work);
        self.queue.deinit(self.allocator);
        for (self.ready.items) |*c| c.deinit();
        self.ready.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn submit(self: *Inline, request: Request) SubmitError!JobId {
        if (self.queue.items.len >= self.max_queued) return error.QueueFull;
        var work: Work = .{ .kind = std.meta.activeTag(request), .name = &.{} };
        switch (request) {
            .read_asset => |r| {
                work.name = try self.allocator.dupe(u8, r.path);
                work.max_bytes = r.max_bytes;
            },
            .read_asset_range => |r| {
                work.name = try self.allocator.dupe(u8, r.path);
                work.offset = r.offset;
                work.len = r.len;
            },
            .list_assets => |r| work.name = try self.allocator.dupe(u8, r.prefix),
            .load_save => |r| work.name = try self.allocator.dupe(u8, r.name),
            .delete_save => |r| work.name = try self.allocator.dupe(u8, r.name),
            .save_record => |r| {
                work.name = try self.allocator.dupe(u8, r.name);
                work.payload = self.allocator.dupe(u8, r.bytes) catch |err| {
                    self.allocator.free(work.name);
                    return err;
                };
            },
            .list_saves => work.name = try self.allocator.alloc(u8, 0),
        }
        const id: JobId = @fromBackingInt(@intCast(self.next_id));
        self.queue.append(self.allocator, .{ .id = id, .work = work }) catch |err| {
            self.freeWork(work);
            return err;
        };
        self.next_id += 1;
        return id;
    }

    /// Runs the queued jobs, then gives the oldest completion.
    pub fn take(self: *Inline) ?Completion {
        while (self.queue.items.len != 0) {
            const pending = self.queue.orderedRemove(0);
            const outcome: Outcome = if (pending.canceled) .{ .result = .canceled } else run(self.allocator, self.assets, self.storage, pending.work);
            self.allocator.free(pending.work.payload);
            self.ran += 1;
            const completion: Completion = .{
                .id = pending.id,
                .kind = pending.work.kind,
                .name = pending.work.name,
                .cancel_requested = pending.canceled,
                .result = outcome.result,
                .asset_length = outcome.asset_length,
                .allocator = self.allocator,
            };
            self.ready.append(self.allocator, completion) catch {
                var lost = completion;
                lost.deinit();
            };
        }
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    /// A queued job never runs; its completion reports `canceled`.
    pub fn cancel(self: *Inline, id: JobId) bool {
        for (self.queue.items) |*pending| {
            if (pending.id == id and !pending.canceled) {
                pending.canceled = true;
                return true;
            }
        }
        return false;
    }

    fn freeWork(self: *Inline, work: Work) void {
        self.allocator.free(work.name);
        self.allocator.free(work.payload);
    }
};

const testing = std.testing;
const memory = @import("memory.zig");

test "a range read gives the bytes of the range and the length of the whole asset" {
    var assets = memory.MemoryAssetSource.init(testing.allocator);
    defer assets.deinit();
    try assets.add("DATA/FILM.MVE", "0123456789");
    var storage = memory.MemoryStorage.init(testing.allocator);
    defer storage.deinit();
    var jobs = Inline.init(testing.allocator, assets.assetSource(), storage.storage());
    defer jobs.deinit();

    const first = try jobs.submit(.{ .read_asset_range = .{ .path = "DATA/FILM.MVE", .offset = 0, .len = 4 } });
    const last = try jobs.submit(.{ .read_asset_range = .{ .path = "DATA/FILM.MVE", .offset = 8, .len = 4 } });
    var a = jobs.take() orelse return error.TestUnexpectedResult;
    defer a.deinit();
    try testing.expectEqual(first, a.id);
    try testing.expectEqualStrings("0123", a.bytes().?);
    try testing.expectEqual(@as(u64, 10), a.asset_length);
    // At the end of the file the range is shorter.
    var b = jobs.take() orelse return error.TestUnexpectedResult;
    defer b.deinit();
    try testing.expectEqual(last, b.id);
    try testing.expectEqualStrings("89", b.bytes().?);
    try testing.expect(jobs.take() == null);
}

test "a canceled job does not run, and a missing asset is a failure" {
    var assets = memory.MemoryAssetSource.init(testing.allocator);
    defer assets.deinit();
    var storage = memory.MemoryStorage.init(testing.allocator);
    defer storage.deinit();
    var jobs = Inline.init(testing.allocator, assets.assetSource(), storage.storage());
    defer jobs.deinit();

    const gone = try jobs.submit(.{ .read_asset = .{ .path = "DATA/NONE.BMP" } });
    const dropped = try jobs.submit(.{ .read_asset = .{ .path = "DATA/NONE.BMP" } });
    try testing.expect(jobs.cancel(dropped));
    var a = jobs.take() orelse return error.TestUnexpectedResult;
    defer a.deinit();
    try testing.expectEqual(gone, a.id);
    try testing.expectEqual(Result{ .failed = error.NotFound }, a.result);
    var b = jobs.take() orelse return error.TestUnexpectedResult;
    defer b.deinit();
    try testing.expectEqual(Result.canceled, b.result);
    try testing.expect(b.cancel_requested);
    try testing.expectEqual(@as(u64, 2), jobs.ran);
}

test "takeBytes moves the bytes out, and the completion releases nothing twice" {
    var assets = memory.MemoryAssetSource.init(testing.allocator);
    defer assets.deinit();
    try assets.add("MPS.EXE", "MZ");
    var storage = memory.MemoryStorage.init(testing.allocator);
    defer storage.deinit();
    var jobs = Inline.init(testing.allocator, assets.assetSource(), storage.storage());
    defer jobs.deinit();
    _ = try jobs.submit(.{ .read_asset = .{ .path = "MPS.EXE" } });
    var c = jobs.take() orelse return error.TestUnexpectedResult;
    var owned = c.takeBytes() orelse return error.TestUnexpectedResult;
    c.deinit();
    try testing.expectEqualStrings("MZ", owned.bytes);
    owned.deinit();
}
