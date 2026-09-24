//! The I/O workflow executor (DESIGN.md): the bounded queue and the one active
//! workflow. On a native host, every asset and storage operation of the game runs through it.
//!
//! A workflow is a finite job: read an asset, list a prefix, load or replace a save. A workflow
//! owns its working memory and keeps the providers and its copied inputs alive until it ends. It
//! publishes an owned result, which the application accepts or releases. The game submits jobs
//! from an update, continues to render and to read input, and collects results at update
//! boundaries. No frame update waits for a file.
//!
//! The design fixes these rules, and this file enforces them:
//!
//!   * One job runs at a time. `update` starts the next queued job, collects the active job and
//!     publishes its result. `submit` only queues, so the host decides when work begins and a
//!     replay sees the same order.
//!   * The queue is bounded (`Options.max_queued`). A submission past the bound gets
//!     `error.QueueFull`; the queue never grows without limit.
//!   * `submit` copies the inputs, because the caller's buffer can be gone before the job runs.
//!     Results are owned values with `deinit`, and they outlive the job record that made them.
//!   * Cancellation is a request. A queued job never runs. An active job is canceled and joined.
//!     A job that finished first keeps its result, and `Completion.cancel_requested` tells that a
//!     cancellation raced it. A committed save is never undone.
//!   * `shutdown` finishes the saves marked `required`, cancels and joins the other jobs, and
//!     refuses new work. The host can then release the providers.
//!   * Results become visible at publication. With `auto_publish` (the interactive host), this is
//!     at every update. A host that must decide when the game sees a completion turns it off and
//!     calls `publish` itself.
//!
//! The worker uses the executor's allocator and the providers' allocators, so they must be
//! thread-safe. The hosts pass the process allocator, which is thread-safe.
//!
//! Native execution uses `std.Io.concurrent`, the only facility that guarantees progress
//! independently of the frame loop. An implementation that cannot supply it returns
//! `error.ConcurrencyUnavailable`. The executor then runs jobs inline in `update` and reports
//! this through `concurrency()`. This mode is slower but correct; it is not a failure.
const std = @import("std");
const gameport = @import("gameport");
const platform = gameport.platform;

const workflow = gameport.workflow;

/// The shared types of a workflow (`workflow.zig`): the game submits the same requests to every
/// host and takes the same completions back.
pub const JobId = workflow.JobId;
pub const default_max_bytes = workflow.default_max_bytes;
pub const Request = workflow.Request;
pub const Kind = workflow.Kind;
pub const Failure = workflow.Failure;
pub const Result = workflow.Result;
pub const Completion = workflow.Completion;

/// How the jobs are executed on this host.
pub const Concurrency = enum {
    /// No job has started yet.
    unknown,
    /// `std.Io.concurrent` accepted the job: it progresses while updates continue.
    concurrent,
    /// The last job got no concurrency and ran inside `update`, which blocks until the job ends.
    /// This is correct, but a long read delays the frame that started it. Each start asks again,
    /// so a temporary shortage of resources has no permanent effect.
    inline_only,
};

pub const Options = struct {
    /// How many jobs may wait behind the active one.
    max_queued: usize = 8,
    /// Publishes completed results at every update. A host that must decide when the game sees
    /// a completion clears this and calls `publish` itself.
    auto_publish: bool = true,
    /// Runs each job inside `update` instead of beside it. A job then ends at a fixed update, so
    /// a run replays the same way whatever the machine does.
    inline_jobs: bool = false,
};

pub const Stats = struct {
    submitted: u64 = 0,
    started: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
    canceled: u64 = 0,
    published: u64 = 0,
    taken: u64 = 0,
    released: u64 = 0,
    /// The maximum queue length, without the active job.
    peak_queued: usize = 0,
};

pub const SubmitError = workflow.SubmitError;

/// The record of one job. It owns every input that the job reads, so the caller's buffers can go
/// away when `submit` returns.
const Job = struct {
    id: JobId,
    kind: Kind,
    /// Path, prefix or save key. Empty for `list_saves`.
    name: []u8,
    /// The bytes of a `save_record`.
    payload: []u8,
    offset: u64 = 0,
    len: usize = 0,
    max_bytes: usize = 0,
    required: bool = false,
    cancel_requested: bool = false,
    /// Written by the worker, read by the host thread after `done` or after joining.
    result: Result = .canceled,
    /// The length of the whole asset of a read, written with `result`.
    asset_length: u64 = 0,
    /// The worker sets it with release order as its last action, so the host sees the
    /// completion without blocking. The host still joins the task before it reads the result.
    done: std.atomic.Value(bool) = .init(false),
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    assets: platform.AssetSource,
    storage: platform.Storage,
    options: Options,
    /// Waiting jobs, oldest first.
    queue: std.ArrayList(*Job) = .empty,
    /// The one job that may be running.
    active: ?*Job = null,
    future: std.Io.Future(void) = undefined,
    /// Finished, not published yet.
    completed: std.ArrayList(*Job) = .empty,
    /// Published, waiting for the application to take them.
    ready: std.ArrayList(*Job) = .empty,
    next_id: u64 = 1,
    concurrency_mode: Concurrency = .unknown,
    closed: bool = false,
    stats: Stats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        assets: platform.AssetSource,
        storage: platform.Storage,
        options: Options,
    ) Executor {
        return .{
            .allocator = allocator,
            .io = io,
            .assets = assets,
            .storage = storage,
            .options = options,
        };
    }

    /// Shuts the executor down (see `shutdown`) and releases every result that the application
    /// did not take. It is valid with or without an earlier `shutdown`.
    pub fn deinit(self: *Executor) void {
        self.shutdown();
        self.releaseAll();
        self.queue.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.* = undefined;
    }

    /// The executor as the runner that a backend forwards the game's workflows to.
    pub fn jobs(self: *Executor) workflow.Jobs {
        return .{ .context = self, .vtable = &jobs_vtable };
    }

    const jobs_vtable = workflow.Jobs.VTable{
        .submit = jobsSubmit,
        .take = jobsTake,
        .cancel = jobsCancel,
    };
    fn jobsSubmit(ctx: *anyopaque, request: Request) SubmitError!JobId {
        const self: *Executor = @ptrCast(@alignCast(ctx));
        return self.submit(request);
    }
    fn jobsTake(ctx: *anyopaque) ?Completion {
        const self: *Executor = @ptrCast(@alignCast(ctx));
        return self.takeResult();
    }
    fn jobsCancel(ctx: *anyopaque, id: JobId) bool {
        const self: *Executor = @ptrCast(@alignCast(ctx));
        return self.cancel(id);
    }

    pub fn concurrency(self: *const Executor) Concurrency {
        return self.concurrency_mode;
    }

    /// The number of jobs that wait behind the active job.
    pub fn queued(self: *const Executor) usize {
        return self.queue.items.len;
    }

    /// True when a job runs or waits.
    pub fn busy(self: *const Executor) bool {
        return self.active != null or self.queue.items.len != 0;
    }

    /// The number of published results that are not taken yet.
    pub fn readyCount(self: *const Executor) usize {
        return self.ready.items.len;
    }

    /// Copies the inputs of the request and queues it. The job starts in a later `update`.
    pub fn submit(self: *Executor, request: Request) SubmitError!JobId {
        if (self.closed) return error.Closed;
        if (self.queue.items.len >= self.options.max_queued) return error.QueueFull;
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .id = @fromBackingInt(@intCast(self.next_id)),
            .kind = std.meta.activeTag(request),
            .name = &.{},
            .payload = &.{},
        };
        errdefer self.allocator.free(job.name);
        switch (request) {
            .read_asset => |r| {
                job.name = try self.allocator.dupe(u8, r.path);
                job.max_bytes = r.max_bytes;
            },
            .read_asset_range => |r| {
                job.name = try self.allocator.dupe(u8, r.path);
                job.offset = r.offset;
                job.len = r.len;
            },
            .list_assets => |r| job.name = try self.allocator.dupe(u8, r.prefix),
            .load_save => |r| job.name = try self.allocator.dupe(u8, r.name),
            .delete_save => |r| job.name = try self.allocator.dupe(u8, r.name),
            .save_record => |r| {
                job.name = try self.allocator.dupe(u8, r.name);
                job.payload = try self.allocator.dupe(u8, r.bytes);
                job.required = r.required;
            },
            .list_saves => {},
        }
        errdefer self.allocator.free(job.payload);
        // Grow the lists that a finished job goes through here, where a failure can still be
        // reported. After a job starts, its completion must have a place, so publication and
        // collection cannot fail for lack of memory.
        const in_flight = self.queue.items.len + @intFromBool(self.active != null) +
            self.completed.items.len + self.ready.items.len;
        try self.completed.ensureTotalCapacity(self.allocator, in_flight + 1);
        try self.ready.ensureTotalCapacity(self.allocator, in_flight + 1);
        try self.queue.append(self.allocator, job);
        self.next_id += 1;
        self.stats.submitted += 1;
        self.stats.peak_queued = @max(self.stats.peak_queued, self.queue.items.len);
        return job.id;
    }

    /// One bounded step of the executor, at an update boundary: collect the active job if it is
    /// finished, start the next queued job, and publish if publication is automatic. It never
    /// waits for a running job.
    pub fn update(self: *Executor) void {
        self.collect();
        self.startNext();
        if (self.options.auto_publish) self.publish();
    }

    /// Moves every finished result to the ready list. A host without `auto_publish` calls this
    /// itself, to decide the update at which the game sees a completion.
    pub fn publish(self: *Executor) void {
        for (self.completed.items) |job| {
            self.ready.appendAssumeCapacity(job);
            self.stats.published += 1;
        }
        self.completed.clearRetainingCapacity();
    }

    /// Takes the oldest published completion. The caller owns it until `Completion.deinit`.
    pub fn takeResult(self: *Executor) ?Completion {
        if (self.ready.items.len == 0) return null;
        const job = self.ready.orderedRemove(0);
        defer self.allocator.destroy(job);
        self.allocator.free(job.payload);
        self.stats.taken += 1;
        return .{
            .id = job.id,
            .kind = job.kind,
            .name = job.name,
            .cancel_requested = job.cancel_requested,
            .result = job.result,
            .asset_length = job.asset_length,
            .allocator = self.allocator,
        };
    }

    /// Releases every completed and published result that the application did not take. A
    /// screen that closes discards its loads this way.
    pub fn releaseAll(self: *Executor) void {
        for (self.completed.items) |job| self.destroy(job);
        self.completed.clearRetainingCapacity();
        for (self.ready.items) |job| self.destroy(job);
        self.ready.clearRetainingCapacity();
    }

    /// Requests the cancellation of `id`. A queued job is removed and never runs. The active job
    /// is canceled and joined; it can still return a result that it made before. Returns false
    /// when the job is unknown, already finished or already taken.
    pub fn cancel(self: *Executor, id: JobId) bool {
        for (self.queue.items, 0..) |job, i| {
            if (job.id != id) continue;
            _ = self.queue.orderedRemove(i);
            job.cancel_requested = true;
            job.result = .canceled;
            self.stats.canceled += 1;
            self.finish(job);
            return true;
        }
        if (self.active) |job| {
            if (job.id == id) {
                self.cancelActive();
                return true;
            }
        }
        return false;
    }

    /// Cancels the active job and everything queued.
    pub fn cancelAll(self: *Executor) void {
        while (self.queue.items.len != 0) {
            const job = self.queue.orderedRemove(self.queue.items.len - 1);
            job.cancel_requested = true;
            job.result = .canceled;
            self.stats.canceled += 1;
            self.finish(job);
        }
        if (self.active != null) self.cancelActive();
    }

    /// Orderly shutdown: refuse new work, finish the required saves, and cancel and join all
    /// other jobs. Queued required saves run inline, because the host is closing. The results of
    /// the required saves stay available for the caller to check.
    pub fn shutdown(self: *Executor) void {
        self.closed = true;
        if (self.active) |job| {
            if (job.required) {
                self.join();
            } else {
                self.cancelActive();
            }
        }
        var i: usize = 0;
        while (i < self.queue.items.len) {
            const job = self.queue.items[i];
            if (job.required) {
                i += 1;
                continue;
            }
            _ = self.queue.orderedRemove(i);
            job.cancel_requested = true;
            job.result = .canceled;
            self.stats.canceled += 1;
            self.finish(job);
        }
        // The remaining jobs are required: run them to the end before the providers go away.
        while (self.queue.items.len != 0) {
            const job = self.queue.orderedRemove(0);
            self.stats.started += 1;
            self.execute(job);
            self.account(job);
            self.finish(job);
        }
    }

    /// Starts the oldest queued job when nothing is active.
    fn startNext(self: *Executor) void {
        if (self.active != null) return;
        if (self.queue.items.len == 0) return;
        const job = self.queue.orderedRemove(0);
        self.stats.started += 1;
        if (self.options.inline_jobs) {
            self.execute(job);
            job.done.store(true, .release);
            self.account(job);
            self.finish(job);
            return;
        }
        // Ask for concurrency at every start, not only once. The error also covers a temporary
        // shortage of resources, and one refusal must not make the inline mode permanent.
        if (self.io.concurrent(runJob, .{ self, job })) |future| {
            self.concurrency_mode = .concurrent;
            self.future = future;
            self.active = job;
            return;
        } else |err| switch (err) {
            // No concurrency: run the job inline and report this through `concurrency()`.
            error.ConcurrencyUnavailable => self.concurrency_mode = .inline_only,
        }
        self.execute(job);
        job.done.store(true, .release);
        self.account(job);
        self.finish(job);
    }

    /// Collects the active job if it is finished. It joins only a job that has already signalled
    /// completion, so an update never waits for a read.
    fn collect(self: *Executor) void {
        const job = self.active orelse return;
        if (!job.done.load(.acquire)) return;
        self.join();
    }

    /// Joins the active job and stores its result.
    fn join(self: *Executor) void {
        const job = self.active orelse return;
        self.future.await(self.io);
        self.active = null;
        self.account(job);
        self.finish(job);
    }

    /// Cancels the active job, joins it and stores its result. A job that had already committed
    /// keeps its result; `cancel_requested` records that a cancellation raced it.
    fn cancelActive(self: *Executor) void {
        const job = self.active orelse return;
        job.cancel_requested = true;
        self.future.cancel(self.io);
        self.active = null;
        if (!job.done.load(.acquire)) job.result = .canceled;
        self.account(job);
        self.finish(job);
    }

    fn account(self: *Executor, job: *Job) void {
        switch (job.result) {
            .failed => |err| {
                // A cancellation point inside the job reports `error.Canceled`. That is a
                // canceled job, not a failure of the store.
                if (err == error.Canceled) {
                    job.result = .canceled;
                    self.stats.canceled += 1;
                } else {
                    self.stats.failed += 1;
                }
            },
            .canceled => self.stats.canceled += 1,
            else => self.stats.completed += 1,
        }
    }

    fn finish(self: *Executor, job: *Job) void {
        self.completed.appendAssumeCapacity(job);
    }

    fn destroy(self: *Executor, job: *Job) void {
        switch (job.result) {
            .bytes => job.result.bytes.deinit(),
            .names => job.result.names.deinit(),
            else => {},
        }
        self.allocator.free(job.name);
        self.allocator.free(job.payload);
        self.allocator.destroy(job);
        self.stats.released += 1;
    }

    /// The worker. It uses only the job's own memory and the providers, which the executor keeps
    /// alive until the job ends. It sets the done flag last.
    fn runJob(self: *Executor, job: *Job) void {
        self.execute(job);
        job.done.store(true, .release);
    }

    /// The body of one workflow (`workflow.run`), as ordinary calls. The suspending providers of
    /// the design return their values there, and normal `try`/`defer` cleanup applies.
    fn execute(self: *Executor, job: *Job) void {
        const outcome = workflow.run(self.allocator, self.assets, self.storage, .{
            .kind = job.kind,
            .name = job.name,
            .payload = job.payload,
            .offset = job.offset,
            .len = job.len,
            .max_bytes = job.max_bytes,
        });
        job.result = outcome.result;
        job.asset_length = outcome.asset_length;
    }
};

// ---------------------------------------------------------------------------------------------
// The executor cases. They use only the interfaces, so they run against every provider pair: the
// in-memory providers, the directory providers below, and any other provider (an ISO source, a
// browser store) through the same calls.

const contract = @import("contract.zig");
const directory = @import("directory.zig");
const storage_provider = @import("storage.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Updates until no job is active or queued, and sleeps between updates as a host does. Returns
/// the number of updates. The tests use this number to see that the updates continue while a
/// workflow runs.
fn drain(ex: *Executor, io: std.Io) usize {
    var updates: usize = 0;
    while (ex.busy()) {
        ex.update();
        updates += 1;
        if (ex.busy()) io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return updates;
}

fn nothing() void {}

/// Whether this `Io` can run a job in parallel with the update loop. The timing cases need this.
/// Without it the executor is still correct; a separate case below checks the inline mode.
fn concurrencyAvailable(io: std.Io) bool {
    var probe = io.concurrent(nothing, .{}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return false,
    };
    probe.await(io);
    return true;
}

/// The provider-independent cases: admission, one job at a time, copied inputs, owned results,
/// controlled publication, cancellation of queued work, stale results, failures, and a shutdown
/// that finishes a required save. `assets` holds `contract.fixture`; `storage` starts empty.
pub fn executorContract(allocator: std.mem.Allocator, io: std.Io, assets: platform.AssetSource, storage: platform.Storage) !void {
    // One job at a time, in submission order, with a bounded queue.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{ .max_queued = 3, .auto_publish = false });
        defer ex.deinit();
        var ids: [3]JobId = undefined;
        ids[0] = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name } });
        ids[1] = try ex.submit(.{ .list_assets = .{ .prefix = "" } });
        ids[2] = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.config_name } });
        try std.testing.expectError(error.QueueFull, ex.submit(.{ .list_saves = {} }));
        try expectEqual(@as(usize, 3), ex.queued());
        ex.update();
        // Exactly one job left the queue, whether it is still running or already done.
        try expectEqual(@as(usize, 2), ex.queued());
        _ = drain(&ex, io);
        // No result is visible before publication. The host decides when the game sees a result,
        // so a run replays the same way at any host timing.
        try expectEqual(@as(usize, 0), ex.readyCount());
        try expect(ex.takeResult() == null);
        ex.publish();
        try expectEqual(@as(usize, 3), ex.readyCount());
        var first = ex.takeResult().?;
        defer first.deinit();
        try expectEqual(ids[0], first.id);
        try expectEqualStrings(contract.fixture.blob, first.bytes().?);
        var second = ex.takeResult().?;
        defer second.deinit();
        try expectEqual(ids[1], second.id);
        try expectEqual(contract.fixture.listing.len, second.result.names.names.len);
        var third = ex.takeResult().?;
        defer third.deinit();
        try expectEqual(ids[2], third.id);
        try expectEqualStrings(contract.fixture.config, third.bytes().?);
        // The result outlives the job that produced it and every job after it.
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.empty_name } });
        _ = drain(&ex, io);
        try expectEqualStrings(contract.fixture.blob, first.bytes().?);
    }

    // `submit` copies the inputs: the caller's buffer is gone before the job runs.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{});
        defer ex.deinit();
        var path: [contract.fixture.blob_name.len]u8 = undefined;
        @memcpy(&path, contract.fixture.blob_name);
        const id = try ex.submit(.{ .read_asset = .{ .path = &path } });
        @memset(&path, '?');
        _ = drain(&ex, io);
        var done = ex.takeResult().?;
        defer done.deinit();
        try expectEqual(id, done.id);
        try expectEqualStrings(contract.fixture.blob_name, done.name);
        try expectEqualStrings(contract.fixture.blob, done.bytes().?);
    }

    // Ranges: a short read at end of file returns what exists, not an error.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{});
        defer ex.deinit();
        _ = try ex.submit(.{ .read_asset_range = .{ .path = contract.fixture.blob_name, .offset = 10, .len = 32 } });
        _ = drain(&ex, io);
        var got = ex.takeResult().?;
        defer got.deinit();
        try expectEqualStrings(contract.fixture.blob[10..], got.bytes().?);
    }

    // A queued job that is canceled never runs. The started count shows this.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{});
        defer ex.deinit();
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name } });
        const dropped = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.config_name } });
        try expect(ex.cancel(dropped));
        try expect(!ex.cancel(dropped)); // it is no longer queued or active
        _ = drain(&ex, io);
        // Only the other job started, and the canceled job is ready first: results come in
        // completion order, not in submission order.
        try expectEqual(@as(u64, 1), ex.stats.started);
        var gone = ex.takeResult().?;
        defer gone.deinit();
        try expectEqual(dropped, gone.id);
        try expectEqualStrings(contract.fixture.config_name, gone.name);
        try expect(gone.result == .canceled);
        try expect(gone.cancel_requested);
        var kept = ex.takeResult().?;
        defer kept.deinit();
        try expectEqualStrings(contract.fixture.blob, kept.bytes().?);
    }

    // Stale results: a screen that closes releases the results that it did not take, and
    // `deinit` releases the remaining results. The testing allocator checks for leaks.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{});
        defer ex.deinit();
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.nested_name } });
        _ = try ex.submit(.{ .list_assets = .{ .prefix = "" } });
        _ = drain(&ex, io);
        try expectEqual(@as(usize, 2), ex.readyCount());
        ex.releaseAll();
        try expectEqual(@as(usize, 0), ex.readyCount());
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name } });
        _ = drain(&ex, io);
    }

    // A failing job reports the shared error and leaves the executor usable.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{});
        defer ex.deinit();
        _ = try ex.submit(.{ .read_asset = .{ .path = "MISSING.BIN" } });
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name, .max_bytes = 2 } });
        _ = try ex.submit(.{ .load_save = .{ .name = "NOSUCH" } });
        _ = drain(&ex, io);
        var missing = ex.takeResult().?;
        defer missing.deinit();
        try expectEqual(Result{ .failed = error.NotFound }, missing.result);
        var too_large = ex.takeResult().?;
        defer too_large.deinit();
        try expectEqual(Result{ .failed = error.TooLarge }, too_large.result);
        var no_save = ex.takeResult().?;
        defer no_save.deinit();
        try expectEqual(Result{ .failed = error.NotFound }, no_save.result);
        try expectEqual(@as(u64, 3), ex.stats.failed);
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name } });
        _ = drain(&ex, io);
        var good = ex.takeResult().?;
        defer good.deinit();
        try expectEqualStrings(contract.fixture.blob, good.bytes().?);
    }

    // Saves round trip through the executor, and listing sees them.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{});
        defer ex.deinit();
        _ = try ex.submit(.{ .save_record = .{ .name = "EXEC.PT", .bytes = "position" } });
        _ = try ex.submit(.{ .load_save = .{ .name = "EXEC.PT" } });
        _ = try ex.submit(.{ .list_saves = {} });
        _ = drain(&ex, io);
        var saved = ex.takeResult().?;
        defer saved.deinit();
        try expect(saved.result == .done);
        var loaded = ex.takeResult().?;
        defer loaded.deinit();
        try expectEqualStrings("position", loaded.bytes().?);
        var listed = ex.takeResult().?;
        defer listed.deinit();
        try expectEqual(@as(usize, 1), listed.result.names.names.len);
        try expectEqualStrings("EXEC.PT", listed.result.names.names[0]);
        _ = try ex.submit(.{ .delete_save = .{ .name = "EXEC.PT" } });
        _ = drain(&ex, io);
        var deleted = ex.takeResult().?;
        defer deleted.deinit();
        try expect(deleted.result == .done);
    }

    // Shutdown finishes the required save, cancels the rest and admits nothing more.
    {
        var ex = Executor.init(allocator, io, assets, storage, .{});
        defer ex.deinit();
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.nested_name } });
        _ = try ex.submit(.{ .save_record = .{ .name = "SHUTDOWN.PT", .bytes = "must persist", .required = true } });
        ex.shutdown();
        try expect(!ex.busy());
        try std.testing.expectError(error.Closed, ex.submit(.{ .list_saves = {} }));
        ex.publish();
        var dropped = ex.takeResult().?;
        defer dropped.deinit();
        try expect(dropped.result == .canceled);
        try expect(dropped.cancel_requested);
        var persisted = ex.takeResult().?;
        defer persisted.deinit();
        try expect(persisted.result == .done);
        var record = try storage.load("SHUTDOWN.PT");
        defer record.deinit();
        try expectEqualStrings("must persist", record.bytes);
        try storage.deleteSave("SHUTDOWN.PT");
    }
}

/// An asset source that reads slowly and can fail at `open`, where a workflow gets its
/// resources. It wraps any provider, so the timing cases run against every provider pair.
pub const SlowAssets = struct {
    inner: platform.AssetSource,
    io: std.Io,
    /// How long each read waits. `io.sleep` is a cancellation point, as a real read is.
    delay_ms: i64 = 5,
    /// Fails at `open`, before any allocation.
    fail_open: bool = false,
    opens: std.atomic.Value(u32) = .init(0),
    /// True during a read, so a test can cancel exactly during a read.
    reading: std.atomic.Value(bool) = .init(false),

    pub fn assetSource(self: *SlowAssets) platform.AssetSource {
        return .{ .context = self, .vtable = &vtable, .allocator = self.inner.allocator };
    }

    const vtable = platform.AssetSource.VTable{ .open = open, .read_at = readAt, .list = list, .close = close };

    fn cast(ctx: *anyopaque) *SlowAssets {
        return @ptrCast(@alignCast(ctx));
    }

    fn open(ctx: *anyopaque, path: []const u8) platform.AssetError!platform.OpenedAsset {
        const self = cast(ctx);
        _ = self.opens.fetchAdd(1, .acq_rel);
        if (self.fail_open) return error.Io;
        return self.inner.open(path);
    }

    fn readAt(ctx: *anyopaque, file: platform.AssetHandle, offset: u64, dst: []u8) platform.AssetError!usize {
        const self = cast(ctx);
        self.reading.store(true, .release);
        defer self.reading.store(false, .release);
        self.io.sleep(.fromMilliseconds(self.delay_ms), .awake) catch return error.Canceled;
        return self.inner.readAt(file, offset, dst);
    }

    fn list(ctx: *anyopaque, prefix: []const u8) platform.AssetError!platform.OwnedAssetEntries {
        return cast(ctx).inner.list(prefix);
    }

    fn close(ctx: *anyopaque, file: platform.AssetHandle) void {
        cast(ctx).inner.close(file);
    }
};

/// A store that stops inside `save`, before or after the replacement commits, so a test can
/// cancel exactly at that point. It wraps any provider.
pub const GatedStorage = struct {
    inner: platform.Storage,
    io: std.Io,
    /// Where the next save stops. Set before the job starts; the worker only reads it.
    gate: Gate = .none,
    /// The next save fails before it touches the store.
    fail_before_commit: bool = false,
    /// Set by the worker while it waits at the gate.
    waiting: std.atomic.Value(bool) = .init(false),
    committed: std.atomic.Value(u32) = .init(0),

    pub const Gate = enum { none, before_commit, after_commit };

    pub fn storage(self: *GatedStorage) platform.Storage {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = platform.Storage.VTable{ .save = save, .load = load, .list_saves = listSaves, .delete_save = deleteSave };

    fn cast(ctx: *anyopaque) *GatedStorage {
        return @ptrCast(@alignCast(ctx));
    }

    /// Waits at the gate until a cancellation arrives, or for at most one second, so a run
    /// without a cancellation still ends. Returns false after a cancellation.
    fn wait(self: *GatedStorage) bool {
        self.waiting.store(true, .release);
        defer self.waiting.store(false, .release);
        var left: u32 = 200;
        while (left != 0) : (left -= 1) {
            self.io.sleep(.fromMilliseconds(5), .awake) catch return false;
        }
        return true;
    }

    fn save(ctx: *anyopaque, name: []const u8, bytes: []const u8) platform.StorageError!void {
        const self = cast(ctx);
        if (self.fail_before_commit) {
            self.fail_before_commit = false;
            return error.Io;
        }
        // Before the commit, a cancellation stops the replacement: the previous record stays.
        if (self.gate == .before_commit and !self.wait()) return error.Canceled;
        try self.inner.save(name, bytes);
        _ = self.committed.fetchAdd(1, .acq_rel);
        // After the commit, the record is written. A cancellation that races the return cannot
        // undo it, so the job reports its success.
        if (self.gate == .after_commit) _ = self.wait();
    }

    fn load(ctx: *anyopaque, name: []const u8) platform.StorageError!platform.OwnedBytes {
        return cast(ctx).inner.load(name);
    }

    fn listSaves(ctx: *anyopaque) platform.StorageError!platform.OwnedSaveNames {
        return cast(ctx).inner.listSaves();
    }

    fn deleteSave(ctx: *anyopaque, name: []const u8) platform.StorageError!void {
        return cast(ctx).inner.deleteSave(name);
    }
};

/// The cases that need a running workflow: updates that continue during a read, the
/// cancellation of the active job, a provider failure at `open`, and a cancellation immediately
/// before and after a save commits.
pub fn executorTimingContract(allocator: std.mem.Allocator, io: std.Io, assets: platform.AssetSource, storage: platform.Storage) !void {
    if (!concurrencyAvailable(io)) return;
    var slow = SlowAssets{ .inner = assets, .io = io };
    var gated = GatedStorage{ .inner = storage, .io = io };

    // A slow read completes while updates continue. The update that starts it does not wait.
    {
        var ex = Executor.init(allocator, io, slow.assetSource(), gated.storage(), .{});
        defer ex.deinit();
        slow.delay_ms = 10;
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.nested_name } });
        const updates = drain(&ex, io);
        try expect(updates >= 2);
        try expectEqual(Concurrency.concurrent, ex.concurrency());
        var got = ex.takeResult().?;
        defer got.deinit();
        var pattern: [contract.fixture.nested_len]u8 = undefined;
        try std.testing.expectEqualSlices(u8, contract.fixture.nested(&pattern), got.bytes().?);
    }

    // The active job is canceled during its read, then joined. Its result is released with it.
    {
        var ex = Executor.init(allocator, io, slow.assetSource(), gated.storage(), .{});
        defer ex.deinit();
        // The delay is long, so the cancellation always comes during the read. The cancellation
        // interrupts the wait, so the long delay does not slow the test.
        slow.delay_ms = 250;
        const id = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.nested_name } });
        ex.update();
        while (!slow.reading.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch {};
        try expect(ex.cancel(id));
        try expect(!ex.busy());
        ex.update(); // the host's next update publishes what the cancellation finished
        var stopped = ex.takeResult().?;
        defer stopped.deinit();
        try expect(stopped.result == .canceled);
        try expect(stopped.cancel_requested);
        slow.delay_ms = 1;
    }

    // A provider failure at `open`: nothing is allocated, the error is reported, and the
    // executor takes the next job.
    {
        var ex = Executor.init(allocator, io, slow.assetSource(), gated.storage(), .{});
        defer ex.deinit();
        slow.fail_open = true;
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name } });
        _ = drain(&ex, io);
        var failed = ex.takeResult().?;
        defer failed.deinit();
        try expectEqual(Result{ .failed = error.Io }, failed.result);
        slow.fail_open = false;
        _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name } });
        _ = drain(&ex, io);
        var ok = ex.takeResult().?;
        defer ok.deinit();
        try expectEqualStrings(contract.fixture.blob, ok.bytes().?);
    }

    // Cancellation immediately before and after a save commits.
    {
        var ex = Executor.init(allocator, io, slow.assetSource(), gated.storage(), .{});
        defer ex.deinit();
        _ = try ex.submit(.{ .save_record = .{ .name = "GATED.PT", .bytes = "first" } });
        _ = drain(&ex, io);
        {
            var committed = ex.takeResult().?;
            defer committed.deinit();
            try expect(committed.result == .done);
        }

        // Before the commit: the replacement stops and the previous record stays.
        gated.gate = .before_commit;
        const before = try ex.submit(.{ .save_record = .{ .name = "GATED.PT", .bytes = "second" } });
        ex.update();
        while (!gated.waiting.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch {};
        try expect(ex.cancel(before));
        ex.update();
        {
            var stopped = ex.takeResult().?;
            defer stopped.deinit();
            try expect(stopped.result == .canceled);
            var kept = try storage.load("GATED.PT");
            defer kept.deinit();
            try expectEqualStrings("first", kept.bytes);
        }

        // After the commit: the cancellation cannot undo it, so the job reports its success and
        // the record is the new one.
        gated.gate = .after_commit;
        const after = try ex.submit(.{ .save_record = .{ .name = "GATED.PT", .bytes = "third" } });
        ex.update();
        while (!gated.waiting.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch {};
        try expect(ex.cancel(after));
        ex.update();
        {
            var raced = ex.takeResult().?;
            defer raced.deinit();
            try expect(raced.result == .done);
            try expect(raced.cancel_requested);
            var replaced = try storage.load("GATED.PT");
            defer replaced.deinit();
            try expectEqualStrings("third", replaced.bytes);
        }
        gated.gate = .none;

        // A failure before the commit keeps the committed record and reports the error.
        gated.fail_before_commit = true;
        _ = try ex.submit(.{ .save_record = .{ .name = "GATED.PT", .bytes = "fourth" } });
        _ = drain(&ex, io);
        {
            var failed = ex.takeResult().?;
            defer failed.deinit();
            try expectEqual(Result{ .failed = error.Io }, failed.result);
            var unchanged = try storage.load("GATED.PT");
            defer unchanged.deinit();
            try expectEqualStrings("third", unchanged.bytes);
        }
        try storage.deleteSave("GATED.PT");
    }
}

const ContractFn = *const fn (std.mem.Allocator, std.Io, platform.AssetSource, platform.Storage) anyerror!void;

fn memoryProviders(allocator: std.mem.Allocator, run: ContractFn) !void {
    var source = gameport.memory.MemoryAssetSource.init(allocator);
    defer source.deinit();
    var pattern: [contract.fixture.nested_len]u8 = undefined;
    try source.add(contract.fixture.blob_name, contract.fixture.blob);
    try source.add(contract.fixture.empty_name, "");
    try source.add(contract.fixture.config_name, contract.fixture.config);
    try source.add(contract.fixture.nested_name, contract.fixture.nested(&pattern));
    var store = gameport.memory.MemoryStorage.init(allocator);
    defer store.deinit();
    try run(allocator, std.testing.io, source.assetSource(), store.storage());
}

fn directoryProviders(allocator: std.mem.Allocator, run: ContractFn) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.createDirPath(io, "saves");
    var assets_dir = try tmp.dir.openDir(io, "assets", .{ .iterate = true });
    defer assets_dir.close(io);
    var saves_dir = try tmp.dir.openDir(io, "saves", .{ .iterate = true });
    defer saves_dir.close(io);
    try directory.writeFixture(io, assets_dir);
    var source = directory.DirectoryAssetSource.initDir(allocator, io, assets_dir);
    defer source.deinit();
    var store = storage_provider.DirectoryStorage.initDir(allocator, io, saves_dir);
    defer store.deinit();
    try run(allocator, io, source.assetSource(), store.storage());
}

test "the executor's contract holds over the in-memory providers" {
    try memoryProviders(std.testing.allocator, executorContract);
}

test "the executor's contract holds over the directory providers" {
    try directoryProviders(std.testing.allocator, executorContract);
}

test "workflows run beside the updates and cancel at their boundaries (in-memory)" {
    try memoryProviders(std.testing.allocator, executorTimingContract);
}

test "workflows run beside the updates and cancel at their boundaries (directory)" {
    try directoryProviders(std.testing.allocator, executorTimingContract);
}

test "an Io without concurrency runs the jobs inline and says so" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var source = gameport.memory.MemoryAssetSource.init(std.testing.allocator);
    defer source.deinit();
    try source.add(contract.fixture.blob_name, contract.fixture.blob);
    var store = gameport.memory.MemoryStorage.init(std.testing.allocator);
    defer store.deinit();
    var ex = Executor.init(std.testing.allocator, io, source.assetSource(), store.storage(), .{});
    defer ex.deinit();
    try expectEqual(Concurrency.unknown, ex.concurrency());
    _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.blob_name } });
    ex.update();
    try expectEqual(Concurrency.inline_only, ex.concurrency());
    try expect(!ex.busy());
    var got = ex.takeResult().?;
    defer got.deinit();
    try expectEqualStrings(contract.fixture.blob, got.bytes().?);
}

fn submitDrainTake(allocator: std.mem.Allocator) !void {
    var source = gameport.memory.MemoryAssetSource.init(allocator);
    defer source.deinit();
    var pattern: [contract.fixture.nested_len]u8 = undefined;
    try source.add(contract.fixture.blob_name, contract.fixture.blob);
    try source.add(contract.fixture.nested_name, contract.fixture.nested(&pattern));
    var store = gameport.memory.MemoryStorage.init(allocator);
    defer store.deinit();
    var ex = Executor.init(allocator, std.testing.io, source.assetSource(), store.storage(), .{});
    defer ex.deinit();
    _ = try ex.submit(.{ .read_asset = .{ .path = contract.fixture.nested_name } });
    _ = try ex.submit(.{ .save_record = .{ .name = "SWEEP.PT", .bytes = "payload", .required = true } });
    _ = try ex.submit(.{ .list_assets = .{ .prefix = "" } });
    _ = drain(&ex, std.testing.io);
    var exhausted = false;
    while (ex.takeResult()) |taken| {
        var c = taken;
        defer c.deinit();
        // A workflow reports memory exhaustion in its result, not as an error return. The
        // sweep needs an error to know that the injected failure was not lost.
        if (c.result == .failed and c.result.failed == error.OutOfMemory) exhausted = true;
    }
    if (exhausted) return error.OutOfMemory;
}

test "the executor survives every allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, submitDrainTake, .{});
}
