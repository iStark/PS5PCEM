// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Small asynchronous FIFO for Vulkan shader/pipeline creation jobs.
//!
//! A worker is started on demand and exits when the queue drains, so an idle
//! renderer owns no spinning background thread. One worker also satisfies
//! Vulkan's external-synchronization rule for a shared `VkPipelineCache`.

const std = @import("std");

pub const RunFn = *const fn (*Job) void;

pub const Job = struct {
    next: ?*Job = null,
    run: RunFn,
    state: std.atomic.Value(u8) = .init(pending),

    const pending: u8 = 0;
    const running: u8 = 1;
    const complete: u8 = 2;

    pub fn wait(self: *Job) void {
        var spins: usize = 0;
        while (self.state.load(.acquire) != complete) : (spins += 1) {
            if (spins < 64) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

pub const Queue = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*Job = null,
    tail: ?*Job = null,
    worker_running: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *Queue) void {
        var spins: usize = 0;
        while (!self.lock.tryLock()) : (spins += 1) {
            if (spins < 64) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn submit(self: *Queue, job: *Job) void {
        job.next = null;
        job.state.store(Job.pending, .release);
        self.acquire();
        if (self.tail) |tail| {
            tail.next = job;
        } else {
            self.head = job;
        }
        self.tail = job;
        const start_worker = !self.worker_running.load(.monotonic);
        if (start_worker) self.worker_running.store(true, .release);
        self.lock.unlock();

        if (!start_worker) return;
        const thread = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            // Thread creation can fail under process pressure. Running the same
            // drain loop here preserves correctness and cache serialization.
            workerMain(self);
            return;
        };
        thread.detach();
    }

    pub fn waitIdle(self: *Queue) void {
        var spins: usize = 0;
        while (self.worker_running.load(.acquire)) : (spins += 1) {
            if (spins < 64) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    fn workerMain(self: *Queue) void {
        while (true) {
            self.acquire();
            const job = self.head orelse {
                self.tail = null;
                self.worker_running.store(false, .release);
                self.lock.unlock();
                return;
            };
            self.head = job.next;
            if (self.head == null) self.tail = null;
            job.next = null;
            job.state.store(Job.running, .release);
            self.lock.unlock();

            job.run(job);
            job.state.store(Job.complete, .release);
        }
    }
};

test "jobs execute asynchronously in FIFO order" {
    const Work = struct {
        job: Job,
        output: *std.atomic.Value(u32),
        value: u32,

        fn run(base: *Job) void {
            const self: *@This() = @fieldParentPtr("job", base);
            while (true) {
                const previous = self.output.load(.acquire);
                if (self.output.cmpxchgWeak(previous, previous * 10 + self.value, .acq_rel, .acquire) == null) break;
            }
        }
    };

    var output = std.atomic.Value(u32).init(0);
    var first = Work{ .job = .{ .run = Work.run }, .output = &output, .value = 1 };
    var second = Work{ .job = .{ .run = Work.run }, .output = &output, .value = 2 };
    var queue = Queue{};
    queue.submit(&first.job);
    queue.submit(&second.job);
    first.job.wait();
    second.job.wait();
    queue.waitIdle();
    try std.testing.expectEqual(@as(u32, 12), output.load(.acquire));
}
