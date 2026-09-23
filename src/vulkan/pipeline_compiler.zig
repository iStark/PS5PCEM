// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded compiler pool with sleeping workers, foreground priority and joined
//! shutdown. Running jobs are never interrupted by a higher-priority request.
const std = @import("std");

// Only native uncancelable synchronization uses this instance, not async I/O.
fn syncIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Job = struct {
    next: ?*Job = null,
    run: *const fn (*Job) void,
    done: std.Io.Event = .unset,

    /// Keep job and inputs alive until completion. Resubmit only after wait.
    pub fn wait(self: *Job) void {
        self.done.waitUncancelable(syncIo());
    }
};

const List = struct {
    head: ?*Job = null,
    tail: ?*Job = null,

    fn push(self: *List, job: *Job) void {
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
    }

    fn pop(self: *List) ?*Job {
        const job = self.head orelse return null;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        job.next = null;
        return job;
    }
};

pub const Queue = struct {
    pub const maximum_workers = 4;
    worker_limit: usize = 2,
    lock: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    idle: std.Io.Condition = .init,
    foreground: List = .{},
    background: List = .{},
    threads: [maximum_workers]std.Thread = undefined,
    thread_count: usize = 0,
    outstanding: usize = 0,
    active: usize = 0,
    peak_active: usize = 0,
    stopping: bool = false,
    spawn_worker: *const fn (*Queue) std.Thread.SpawnError!std.Thread = spawnWorker,

    pub fn submit(self: *Queue, job: *Job) void {
        self.enqueue(job, false);
    }

    pub fn submitBackground(self: *Queue, job: *Job) void {
        self.enqueue(job, true);
    }

    fn enqueue(self: *Queue, job: *Job, background: bool) void {
        job.next = null;
        job.done = .unset;
        const io = syncIo();
        self.lock.lockUncancelable(io);
        std.debug.assert(!self.stopping);
        if (self.thread_count < std.math.clamp(self.worker_limit, 1, maximum_workers)) {
            if (self.spawn_worker(self)) |thread| {
                self.threads[self.thread_count] = thread;
                self.thread_count += 1;
            } else |_| {
                // Preserve required work even when no worker can be created.
                if (self.thread_count == 0) {
                    self.lock.unlock(io);
                    job.run(job);
                    job.done.set(io);
                    return;
                }
            }
        }
        if (background) self.background.push(job) else self.foreground.push(job);
        self.outstanding += 1;
        self.ready.signal(io);
        self.lock.unlock(io);
    }

    fn spawnWorker(self: *Queue) std.Thread.SpawnError!std.Thread {
        return std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn waitIdle(self: *Queue) void {
        const io = syncIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        while (self.outstanding != 0) self.idle.waitUncancelable(io, &self.lock);
    }

    /// Stop producers first. Drain accepted jobs, then join sleeping workers.
    /// waitIdle alone leaves workers alive and reusable.
    pub fn deinit(self: *Queue) void {
        self.waitIdle();
        const io = syncIo();
        self.lock.lockUncancelable(io);
        self.stopping = true;
        self.ready.broadcast(io);
        self.lock.unlock(io);
        for (self.threads[0..self.thread_count]) |thread| thread.join();
        self.thread_count = 0;
    }

    fn workerMain(self: *Queue) void {
        const io = syncIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        while (true) {
            const job = self.foreground.pop() orelse self.background.pop() orelse {
                if (self.stopping) return;
                self.ready.waitUncancelable(io, &self.lock);
                continue;
            };
            self.active += 1;
            self.peak_active = @max(self.peak_active, self.active);
            self.lock.unlock(io);
            job.run(job);
            job.done.set(io);
            // The owner may now release job. Never access it again here.
            self.lock.lockUncancelable(io);
            self.active -= 1;
            self.outstanding -= 1;
            if (self.outstanding == 0) self.idle.broadcast(io);
        }
    }
};

const TestWork = struct {
    job: Job = .{ .run = run },
    entered: ?*std.atomic.Value(u32) = null,
    gate: ?*std.Io.Event = null,
    output: *std.atomic.Value(u32),
    digit: u32,

    fn run(base: *Job) void {
        const self: *@This() = @fieldParentPtr("job", base);
        if (self.entered) |entered| _ = entered.fetchAdd(1, .release);
        if (self.gate) |gate| gate.waitUncancelable(syncIo());
        var previous = self.output.load(.acquire);
        while (true) previous = self.output.cmpxchgWeak(previous, previous * 10 + self.digit, .acq_rel, .acquire) orelse break;
    }
};

fn waitEntered(entered: *std.atomic.Value(u32), expected: u32) !void {
    const io = syncIo();
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (entered.load(.acquire) < expected) {
        if (std.Io.Clock.awake.now(io).nanoseconds - start > 5 * std.time.ns_per_s)
            return error.WorkersDidNotStart;
        std.Thread.yield() catch {};
    }
}

test "compiler jobs overlap within worker bound and workers survive idle" {
    var queue = Queue{ .worker_limit = 2 };
    var gate: std.Io.Event = .unset;
    defer queue.deinit();
    defer gate.set(syncIo());
    var entered = std.atomic.Value(u32).init(0);
    var output = std.atomic.Value(u32).init(0);
    var first = TestWork{ .entered = &entered, .gate = &gate, .output = &output, .digit = 1 };
    var second = TestWork{ .entered = &entered, .gate = &gate, .output = &output, .digit = 2 };
    var third = TestWork{ .entered = &entered, .gate = &gate, .output = &output, .digit = 3 };
    queue.submit(&first.job);
    queue.submit(&second.job);
    queue.submit(&third.job);
    try waitEntered(&entered, 2);
    try std.testing.expectEqual(@as(u32, 2), entered.load(.acquire));
    gate.set(syncIo());
    first.job.wait();
    second.job.wait();
    third.job.wait();
    queue.waitIdle();
    try std.testing.expectEqual(@as(usize, 2), queue.peak_active);
    try std.testing.expectEqual(@as(u32, 3), entered.load(.acquire));
    const completed = output.load(.acquire);
    first.gate = null;
    queue.submit(&first.job);
    first.job.wait();
    queue.waitIdle();
    try std.testing.expectEqual(completed * 10 + 1, output.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.thread_count);
}

test "foreground compilation precedes queued warmups with FIFO within priority" {
    var queue = Queue{ .worker_limit = 1 };
    var gate: std.Io.Event = .unset;
    defer queue.deinit();
    defer gate.set(syncIo());
    var entered = std.atomic.Value(u32).init(0);
    var output = std.atomic.Value(u32).init(0);
    var first = TestWork{ .entered = &entered, .gate = &gate, .output = &output, .digit = 1 };
    var second = TestWork{ .output = &output, .digit = 2 };
    var third = TestWork{ .output = &output, .digit = 3 };
    var urgent = TestWork{ .output = &output, .digit = 4 };
    queue.submitBackground(&first.job);
    try waitEntered(&entered, 1);
    queue.submitBackground(&second.job);
    queue.submitBackground(&third.job);
    queue.submit(&urgent.job);
    gate.set(syncIo());
    queue.waitIdle();
    try std.testing.expectEqual(@as(u32, 1423), output.load(.acquire));
}

test "compiler shutdown drains jobs and joins every worker" {
    var queue = Queue{ .worker_limit = 1 };
    var output = std.atomic.Value(u32).init(0);
    var jobs: [6]TestWork = undefined;
    for (&jobs, 0..) |*job, i| {
        job.* = .{ .output = &output, .digit = @intCast(i + 1) };
        queue.submit(&job.job);
    }
    queue.deinit();
    try std.testing.expectEqual(@as(u32, 123456), output.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.thread_count);
    for (&jobs) |*job| job.job.wait();
}

test "compiler preserves jobs when worker creation fails" {
    const Failing = struct {
        fn spawn(_: *Queue) std.Thread.SpawnError!std.Thread {
            return error.SystemResources;
        }
    };
    var queue = Queue{ .spawn_worker = Failing.spawn };
    defer queue.deinit();
    var output = std.atomic.Value(u32).init(0);
    var work = TestWork{ .output = &output, .digit = 7 };
    queue.submit(&work.job);
    work.job.wait();
    try std.testing.expectEqual(@as(u32, 7), output.load(.acquire));
}
