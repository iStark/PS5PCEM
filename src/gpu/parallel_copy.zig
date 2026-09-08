// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const builtin = @import("builtin");

pub var guest_copy_pool = Pool{};

/// Synchronous copies with a bounded set of sleeping helper threads. The caller
/// copies one partition and joins the others before returning. The pool must
/// remain at a stable address after its first large copy.
pub const Pool = struct {
    pub const minimum_bytes = 4 * 1024 * 1024;
    pub const maximum_participants = 4;

    participants: std.atomic.Value(u8) = .init(1),
    lock: std.atomic.Mutex = .unlocked,
    threaded: ?std.Io.Threaded = null,
    workers: [maximum_participants - 1]Worker = @splat(.{}),
    worker_count: usize = 0,
    start_failed: bool = false,

    const Worker = struct {
        thread: ?std.Thread = null,
        ready: std.Io.Event = .unset,
        complete: std.Io.Event = .unset,
        stop: bool = false,
        destination: []u8 = &.{},
        source: []const u8 = &.{},

        fn run(self: *Worker, io: std.Io) void {
            while (true) {
                self.ready.waitUncancelable(io);
                self.ready.reset();
                if (self.stop) return;
                @memcpy(self.destination, self.source);
                self.complete.set(io);
            }
        }
    };

    /// Same non-overlap contract as @memcpy. Busy/reentrant calls, small ranges
    /// and worker creation failures retain a synchronous inline fallback.
    pub fn copy(self: *Pool, destination: []u8, source: []const u8) void {
        std.debug.assert(destination.len == source.len);
        const participants = self.participants.load(.acquire);
        if (builtin.single_threaded or participants <= 1 or
            destination.len < minimum_bytes or !self.lock.tryLock())
        {
            @memcpy(destination, source);
            return;
        }
        defer self.lock.unlock();
        const wanted = @min(participants, maximum_participants) - 1;
        if (self.threaded == null) self.threaded = .init(std.heap.page_allocator, .{});
        const io = self.threaded.?.io();
        while (self.worker_count < wanted and !self.start_failed) {
            const worker = &self.workers[self.worker_count];
            worker.thread = std.Thread.spawn(.{}, Worker.run, .{ worker, io }) catch {
                self.start_failed = true;
                break;
            };
            self.worker_count += 1;
        }
        const count = @min(self.worker_count, wanted);
        // Align internal boundaries to destination cache lines. Arbitrarily
        // aligned callers and the final partial line remain supported.
        const stride = std.mem.alignBackward(usize, destination.len / (count + 1), 64);
        const adjustment = @intFromPtr(destination.ptr) % 64;
        var offset: usize = 0;
        for (self.workers[0..count], 0..) |*worker, index| {
            const end = stride * (index + 1) - adjustment;
            worker.destination = destination[offset..end];
            worker.source = source[offset..end];
            worker.ready.set(io);
            offset = end;
        }
        @memcpy(destination[offset..], source[offset..]);
        for (self.workers[0..count]) |*worker| {
            worker.complete.waitUncancelable(io);
            worker.complete.reset();
        }
    }

    /// The owner must stop issuing copies before destruction.
    pub fn deinit(self: *Pool) void {
        while (!self.lock.tryLock()) std.Thread.yield() catch {};
        defer self.lock.unlock();
        if (self.threaded) |*threaded| {
            const io = threaded.io();
            for (self.workers[0..self.worker_count]) |*worker| {
                worker.stop = true;
                worker.ready.set(io);
            }
            for (self.workers[0..self.worker_count]) |*worker| worker.thread.?.join();
            threaded.deinit();
        }
        self.threaded = null;
        self.workers = @splat(.{});
        self.worker_count = 0;
        self.start_failed = false;
    }
};

test "parallel copies join before return and preserve unaligned boundaries" {
    var pool = Pool{ .participants = .init(4) };
    defer pool.deinit();
    const allocator = std.testing.allocator;
    const size = Pool.minimum_bytes + 513;
    const source = try allocator.alloc(u8, size + 128);
    defer allocator.free(source);
    const destination = try allocator.alloc(u8, size + 128);
    defer allocator.free(destination);
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 17 +% (index >> 9));
    for ([_]usize{ 0, 1, 31, 63, 97 }) |offset| {
        @memset(destination, 0xc3);
        pool.copy(destination[offset..][0..size], source[3..][0..size]);
        try std.testing.expectEqualSlices(u8, source[3..][0..size], destination[offset..][0..size]);
        try std.testing.expect(std.mem.allEqual(u8, destination[0..offset], 0xc3));
        try std.testing.expect(std.mem.allEqual(u8, destination[offset + size ..], 0xc3));
    }
    // A busy pool must not wait for its caller or overwrite in-flight jobs.
    try std.testing.expect(pool.lock.tryLock());
    pool.copy(destination[0..size], source[0..size]);
    pool.lock.unlock();
    try std.testing.expectEqualSlices(u8, source[0..size], destination[0..size]);
    pool.deinit();
    pool.copy(destination[0..size], source[0..size]);
    try std.testing.expectEqualSlices(u8, source[0..size], destination[0..size]);
}

test "parallel copy concurrent callers and unavailable workers preserve every byte" {
    var pool = Pool{ .participants = .init(4) };
    defer pool.deinit();
    const Work = struct {
        pool: *Pool,
        bytes: []u8,
        source: []const u8,
        fn run(self: @This()) void {
            for (0..12) |_| self.pool.copy(self.bytes, self.source);
        }
    };
    const size = Pool.minimum_bytes + 7;
    const source = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(source);
    const destination = try std.testing.allocator.alloc(u8, 3 * size);
    defer std.testing.allocator.free(destination);
    for (source, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 13));
    @memset(destination, 0);
    var threads: [3]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, Work.run, .{Work{ .pool = &pool, .bytes = destination[i * size ..][0..size], .source = source }});
            started += 1;
        }
    }
    for (0..3) |i| try std.testing.expectEqualSlices(u8, source, destination[i * size ..][0..size]);
    pool.deinit();
    pool.start_failed = true;
    @memset(destination, 0);
    pool.copy(destination[0..size], source);
    try std.testing.expectEqualSlices(u8, source, destination[0..size]);
    try std.testing.expectEqual(@as(usize, 0), pool.worker_count);
}
