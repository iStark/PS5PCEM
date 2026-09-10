// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! A host mutex that does not require an std.Io instance.
const std = @import("std");
const builtin = @import("builtin");

pub const Mutex = struct {
    inner: if (builtin.os.tag == .windows) std.os.windows.SRWLOCK else std.atomic.Mutex = if (builtin.os.tag == .windows) .{} else .unlocked,

    pub fn lock(self: *Mutex) void {
        if (builtin.os.tag == .windows) {
            // Mapping operations can commit or protect large allocations.
            // Park contenders instead of spinning for their entire duration.
            std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.inner);
        } else {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (builtin.os.tag == .windows) {
            std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.inner);
        } else {
            self.inner.unlock();
        }
    }
};

test "host mutex preserves contended updates and wakes all waiters" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const Shared = struct {
        mutex: Mutex = .{},
        started: std.atomic.Value(u32) = .init(0),
        count: usize = 0,

        fn run(self: *@This()) void {
            _ = self.started.fetchAdd(1, .release);
            for (0..10000) |_| {
                self.mutex.lock();
                self.count += 1;
                self.mutex.unlock();
            }
        }
    };
    var shared = Shared{};
    shared.mutex.lock();
    var locked = true;
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        if (locked) shared.mutex.unlock();
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.run, .{&shared});
        spawned += 1;
    }
    while (shared.started.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(usize, 0), shared.count);
    shared.mutex.unlock();
    locked = false;
    for (threads) |thread| thread.join();
    spawned = 0;
    try std.testing.expectEqual(@as(usize, 40000), shared.count);
}
