// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Ordered graphics/compute submission around the PM4 executor.
//!
//! Each queue advances independently until `WAIT_REG_MEM` blocks it. The root
//! DCB and its complete indirect-buffer continuation are retained, later work
//! on that same queue stays FIFO-ordered, and progress on the other queue gets
//! a chance to publish the real release label. No wait value is synthesized.

const std = @import("std");
const executor = @import("executor.zig");
const gpu_state = @import("state.zig");

pub const Error = executor.Error;

pub const QueueKind = enum { graphics, compute };

pub const PumpReport = struct {
    completed_submissions: usize = 0,
    blocked_checks: usize = 0,
    packets: usize = 0,
    draws: usize = 0,
    dispatches: usize = 0,

    fn record(self: *PumpReport, result: executor.Result) void {
        self.packets += result.packets;
        self.draws += result.draws;
        self.dispatches += result.dispatches;
        if (result.status == .blocked) self.blocked_checks += 1;
    }
};

const Submission = struct {
    words: []u32,
    continuation: ?executor.Continuation = null,
};

const Queue = struct {
    state: gpu_state.State = .{},
    active: ?Submission = null,
    pending: std.ArrayList(Submission) = .empty,
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    backend: executor.Backend,
    graphics: Queue = .{},
    compute: Queue = .{},

    pub fn init(allocator: std.mem.Allocator, backend: executor.Backend) Scheduler {
        return .{ .allocator = allocator, .backend = backend };
    }

    pub fn deinit(self: *Scheduler) void {
        self.deinitQueue(&self.graphics);
        self.deinitQueue(&self.compute);
    }

    pub fn state(self: *Scheduler, kind: QueueKind) *gpu_state.State {
        return &self.queueFor(kind).state;
    }

    pub fn isBlocked(self: *const Scheduler, kind: QueueKind) bool {
        const queue = self.queueForConst(kind);
        return if (queue.active) |active| active.continuation != null else false;
    }

    pub fn continuation(self: *const Scheduler, kind: QueueKind) ?executor.Continuation {
        const queue = self.queueForConst(kind);
        return if (queue.active) |active| active.continuation else null;
    }

    /// Work waiting behind the active submission on this queue.
    pub fn pendingCount(self: *const Scheduler, kind: QueueKind) usize {
        return self.queueForConst(kind).pending.items.len;
    }

    /// Owns a copy immediately: AGC may recycle the caller's command arena as
    /// soon as submit returns, while a blocked queue must retain its root DCB.
    pub fn submit(self: *Scheduler, kind: QueueKind, stream: []const u32) Error!PumpReport {
        if (stream.len == 0) return Error.InvalidPacket;
        const words = try self.allocator.dupe(u32, stream);
        self.queueFor(kind).pending.append(self.allocator, .{ .words = words }) catch |err| {
            self.allocator.free(words);
            return err;
        };
        return self.pump();
    }

    /// Rechecks blocked heads and drains newly runnable FIFO work. Callers use
    /// this after a synchronous `RELEASE_MEM`, or after an asynchronous backend
    /// reports that its release-label write has actually completed.
    pub fn pump(self: *Scheduler) Error!PumpReport {
        var report = PumpReport{};
        while (true) {
            var made_progress = false;
            for ([_]QueueKind{ .graphics, .compute }) |kind| {
                const step = try self.stepQueue(kind);
                switch (step) {
                    .idle => {},
                    .blocked => |result| report.record(result),
                    .completed => |result| {
                        report.record(result);
                        report.completed_submissions += 1;
                        made_progress = true;
                    },
                }
            }
            if (!made_progress) return report;
        }
    }

    const Step = union(enum) {
        idle,
        blocked: executor.Result,
        completed: executor.Result,
    };

    fn stepQueue(self: *Scheduler, kind: QueueKind) Error!Step {
        const queue = self.queueFor(kind);
        if (queue.active == null) {
            if (queue.pending.items.len == 0) return .idle;
            queue.active = queue.pending.orderedRemove(0);
        }

        const active = &queue.active.?;
        var dcb_executor = executor.DcbExecutor{
            .state = &queue.state,
            .backend = self.backend,
            .allocator = self.allocator,
        };
        const result = (if (active.continuation) |resume_point|
            dcb_executor.resumeFrom(active.words, resume_point)
        else
            dcb_executor.execute(active.words)) catch |err| {
            self.discardActive(queue);
            return err;
        };

        if (result.status == .blocked) {
            active.continuation = result.continuation orelse return Error.InvalidContinuation;
            return .{ .blocked = result };
        }

        self.discardActive(queue);
        return .{ .completed = result };
    }

    fn discardActive(self: *Scheduler, queue: *Queue) void {
        const finished = queue.active orelse return;
        queue.active = null;
        self.allocator.free(finished.words);
    }

    fn deinitQueue(self: *Scheduler, queue: *Queue) void {
        self.discardActive(queue);
        for (queue.pending.items) |submission| self.allocator.free(submission.words);
        queue.pending.deinit(self.allocator);
        queue.pending = .empty;
    }

    fn queueFor(self: *Scheduler, kind: QueueKind) *Queue {
        return switch (kind) {
            .graphics => &self.graphics,
            .compute => &self.compute,
        };
    }

    fn queueForConst(self: *const Scheduler, kind: QueueKind) *const Queue {
        return switch (kind) {
            .graphics => &self.graphics,
            .compute => &self.compute,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests

const pm4 = @import("pm4.zig");
const testing = std.testing;

const FakeBackend = struct {
    base: u64 = 0x1000,
    memory: [512]u8 = [_]u8{0} ** 512,
    events: [8]u8 = [_]u8{0} ** 8,
    event_count: usize = 0,

    fn interface(self: *FakeBackend) executor.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn putWords(self: *FakeBackend, address: u64, words: []const u32) void {
        const offset: usize = @intCast(address - self.base);
        for (words, 0..) |word, index| {
            std.mem.writeInt(u32, self.memory[offset + index * 4 ..][0..4], word, .little);
        }
    }

    const vtable = executor.Backend.VTable{
        .read = read,
        .write = write,
        .event = event,
    };

    fn from(context: ?*anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(context.?));
    }

    fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self = from(context);
        if (address < self.base) return false;
        const offset: usize = @intCast(address - self.base);
        if (offset + bytes.len > self.memory.len) return false;
        @memcpy(bytes, self.memory[offset .. offset + bytes.len]);
        return true;
    }

    fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const self = from(context);
        if (address < self.base) return false;
        const offset: usize = @intCast(address - self.base);
        if (offset + bytes.len > self.memory.len) return false;
        @memcpy(self.memory[offset .. offset + bytes.len], bytes);
        return true;
    }

    fn event(context: ?*anyopaque, value: gpu_state.EventWrite) bool {
        const self = from(context);
        if (self.event_count >= self.events.len) return false;
        self.events[self.event_count] = value.event_type;
        self.event_count += 1;
        return true;
    }
};

fn command(opcode: u8, body_words: u14) u32 {
    return (@as(u32, 3) << 30) |
        (@as(u32, body_words - 1) << 16) |
        (@as(u32, opcode) << 8);
}

fn customCommand(code: u6, body_words: u14) u32 {
    return command(pm4.nop, body_words) | (@as(u32, code) << 2);
}

test "release on compute resumes graphics and drains its FIFO without replay" {
    var host = FakeBackend{};
    const child = [_]u32{
        command(pm4.event_write, 1),              0x20,
        customCommand(pm4.custom.wait_mem_32, 6), 0x1080,
        0,                                        0xffff_ffff,
        1,                                        0x13,
        1,                                        command(pm4.event_write, 1),
        0x21,
    };
    host.putWords(0x1100, &child);
    var graphics = [_]u32{
        command(pm4.indirect_buffer, 3), 0x1100, 0, 0x0f20_0000 | child.len,
    };
    const queued_graphics = [_]u32{ command(pm4.event_write, 1), 0x22 };
    const compute = [_]u32{
        customCommand(pm4.custom.release_mem, 7),
        0x28 | (5 << 8),
        (1 << 29),
        0x1080,
        0,
        1,
        0,
        0,
    };

    var scheduler = Scheduler.init(testing.allocator, host.interface());
    defer scheduler.deinit();

    const blocked = try scheduler.submit(.graphics, &graphics);
    try testing.expect(blocked.blocked_checks != 0);
    try testing.expect(scheduler.isBlocked(.graphics));
    try testing.expectEqual(@as(u8, 2), scheduler.continuation(.graphics).?.frame_count);
    try testing.expectEqual(@as(usize, 1), host.event_count);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, host.memory[0x80..0x84], .little));

    // The scheduler owns the root DCB; recycling the caller's words cannot
    // redirect the saved indirect continuation.
    graphics[1] = 0x11c0;
    _ = try scheduler.submit(.graphics, &queued_graphics);
    try testing.expectEqual(@as(usize, 1), scheduler.pendingCount(.graphics));

    const released = try scheduler.submit(.compute, &compute);
    try testing.expectEqual(@as(usize, 3), released.completed_submissions);
    try testing.expect(!scheduler.isBlocked(.graphics));
    try testing.expectEqual(@as(usize, 0), scheduler.pendingCount(.graphics));
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x21, 0x22 }, host.events[0..host.event_count]);
    try testing.expectEqual(@as(u64, 3), scheduler.state(.graphics).event_count);
    try testing.expectEqual(@as(u64, 1), scheduler.state(.compute).release_count);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, host.memory[0x80..0x84], .little));
}

test "an unsatisfied queue remains blocked without mutating its label" {
    var host = FakeBackend{};
    const wait = [_]u32{
        customCommand(pm4.custom.wait_mem_32, 6),
        0x1040,
        0,
        0xffff_ffff,
        9,
        0x13,
        1,
    };
    var scheduler = Scheduler.init(testing.allocator, host.interface());
    defer scheduler.deinit();

    _ = try scheduler.submit(.graphics, &wait);
    const retry = try scheduler.pump();
    try testing.expectEqual(@as(usize, 0), retry.completed_submissions);
    try testing.expectEqual(@as(usize, 1), retry.blocked_checks);
    try testing.expect(scheduler.isBlocked(.graphics));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, host.memory[0x40..0x44], .little));
}
