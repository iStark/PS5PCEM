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
    snapshots: std.ArrayList(Snapshot) = .empty,
    continuation: ?executor.Continuation = null,

    fn deinit(self: *Submission, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        for (self.snapshots.items) |snapshot| allocator.free(snapshot.words);
        self.snapshots.deinit(allocator);
        self.* = undefined;
    }
};

/// Guest ranges referenced by a command stream must live as long as the root
/// DCB. AGC is free to recycle both indirect command buffers and indirect
/// register lists immediately after submit returns.
const Snapshot = struct {
    address: u64,
    words: []u32,
};

const Queue = struct {
    state: gpu_state.State = .{},
    active: ?Submission = null,
    pending: std.ArrayList(Submission) = .empty,
    forced_read: ?ForcedRead = null,
};

const ForcedRead = struct {
    address: u64,
    length: u8,
    bytes: [8]u8 = @splat(0),
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

    /// Mirrors an explicit label write into the active submission's retained
    /// indirect-buffer snapshot. Command arenas may place synchronization
    /// labels beside PM4 packets; reading only the immutable snapshot after a
    /// host-side recovery write would otherwise observe the old label forever.
    pub fn mirrorActiveWrite(
        self: *Scheduler,
        kind: QueueKind,
        address: u64,
        bytes: []const u8,
    ) bool {
        const queue = self.queueFor(kind);
        const active = if (queue.active) |*submission| submission else return false;
        const requested_end = std.math.add(u64, address, bytes.len) catch return false;
        for (active.snapshots.items) |*snapshot| {
            if (address < snapshot.address) continue;
            const destination = std.mem.sliceAsBytes(snapshot.words);
            const snapshot_end = std.math.add(u64, snapshot.address, destination.len) catch continue;
            if (requested_end > snapshot_end) continue;
            const offset: usize = @intCast(address - snapshot.address);
            @memcpy(destination[offset..][0..bytes.len], bytes);
            return true;
        }
        return false;
    }

    /// Satisfies exactly one re-poll of the active WAIT_REG_MEM without
    /// changing guest memory. This is used when the watched address overlaps
    /// protected allocator metadata and publishing the synthetic recovery
    /// value would corrupt the guest heap.
    pub fn softSatisfyActiveWait(
        self: *Scheduler,
        kind: QueueKind,
        wait: gpu_state.WaitRegMem,
    ) bool {
        if (!wait.memory_space) return false;
        const queue = self.queueFor(kind);
        const active = queue.active orelse return false;
        if (active.continuation == null) return false;
        const blocked = queue.state.blocked_wait orelse return false;
        if (!std.meta.eql(blocked, wait)) return false;

        var forced = ForcedRead{ .address = wait.address, .length = switch (wait.width) {
            .bits_32 => 4,
            .bits_64 => 8,
        } };
        switch (wait.width) {
            .bits_32 => std.mem.writeInt(u32, forced.bytes[0..4], @truncate(wait.reference), .little),
            .bits_64 => std.mem.writeInt(u64, &forced.bytes, wait.reference, .little),
        }
        queue.forced_read = forced;
        return true;
    }

    /// Owns a copy immediately: AGC may recycle the caller's command arena as
    /// soon as submit returns, while a blocked queue must retain its root DCB
    /// and every indirect command/register buffer reachable from it.
    pub fn submit(self: *Scheduler, kind: QueueKind, stream: []const u32) Error!PumpReport {
        if (stream.len == 0) return Error.InvalidPacket;
        var submission = try self.copySubmission(stream);
        self.queueFor(kind).pending.append(self.allocator, submission) catch |err| {
            submission.deinit(self.allocator);
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
        const forced_read = queue.forced_read;
        queue.forced_read = null;
        var snapshot_backend = SnapshotBackend{
            .original = self.backend,
            .snapshots = active.snapshots.items,
            .forced_read = forced_read,
        };
        var snapshot_vtable = snapshot_backend.makeVtable();
        var dcb_executor = executor.DcbExecutor{
            .state = &queue.state,
            .backend = .{ .context = &snapshot_backend, .vtable = &snapshot_vtable },
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
        var finished = queue.active orelse return;
        queue.active = null;
        finished.deinit(self.allocator);
    }

    fn deinitQueue(self: *Scheduler, queue: *Queue) void {
        self.discardActive(queue);
        for (queue.pending.items) |*submission| submission.deinit(self.allocator);
        queue.pending.deinit(self.allocator);
        queue.pending = .empty;
    }

    fn copySubmission(self: *Scheduler, stream: []const u32) Error!Submission {
        var submission = Submission{ .words = try self.allocator.dupe(u32, stream) };
        errdefer submission.deinit(self.allocator);

        var active_addresses: [executor.maximum_stream_depth]u64 = undefined;
        try self.snapshotStream(
            &submission,
            submission.words,
            @intFromPtr(stream.ptr),
            0,
            &active_addresses,
        );
        return submission;
    }

    fn snapshotStream(
        self: *Scheduler,
        submission: *Submission,
        stream: []const u32,
        stream_address: u64,
        depth: usize,
        active_addresses: *[executor.maximum_stream_depth]u64,
    ) Error!void {
        var walker = pm4.Walker.init(stream);
        while (true) {
            const packet = walker.next() catch |err| {
                const offset = @min(walker.index, stream.len);
                const header = if (offset < stream.len) stream[offset] else 0;
                std.debug.print(
                    "[gpu scheduler] {s} stream @0x{x} stopped at {d}/{d} header=0x{x:0>8}: {s}\n",
                    .{
                        if (depth == 0) "root" else "indirect",
                        stream_address,
                        offset,
                        stream.len,
                        header,
                        @errorName(err),
                    },
                );
                return err;
            } orelse break;
            if (pm4.indirectRegisterSpaceOf(packet.opcode) != null and packet.body.len == 4) {
                const address = (@as(u64, packet.body[1]) << 32) | (packet.body[0] & 0xffff_fffc);
                const count: usize = packet.body[3] & 0x3fff;
                if (address != 0 and count != 0) {
                    const word_count = std.math.mul(usize, count, 2) catch return Error.InvalidPacket;
                    _ = try self.captureWords(submission, address, word_count);
                }
            } else if (pm4.customCode(packet)) |code| {
                const is_indirect_registers = code == pm4.custom.context_regs_indirect or
                    code == pm4.custom.sh_regs_indirect or
                    code == pm4.custom.uconfig_regs_indirect;
                if (is_indirect_registers and packet.body.len >= 3) {
                    const address = (@as(u64, packet.body[2]) << 32) | (packet.body[1] & 0xffff_fffc);
                    const count: usize = packet.body[0] & 0x3fff;
                    if (address != 0 and count != 0) {
                        const word_count = std.math.mul(usize, count, 2) catch return Error.InvalidPacket;
                        _ = try self.captureWords(submission, address, word_count);
                    }
                }
            }

            if (packet.kind != .command or packet.opcode != pm4.indirect_buffer) continue;
            if (packet.body.len == 3) {
                const address = (@as(u64, packet.body[1]) << 32) | packet.body[0];
                const word_count: usize = packet.body[2] & 0x000f_ffff;
                try self.snapshotIndirectStream(submission, address, word_count, depth, active_addresses);
            } else if (packet.body.len == 13) {
                const then_address = (@as(u64, packet.body[8]) << 32) | packet.body[7];
                const then_count: usize = packet.body[9] & 0x000f_ffff;
                try self.snapshotIndirectStream(submission, then_address, then_count, depth, active_addresses);

                const else_address = (@as(u64, packet.body[11]) << 32) | packet.body[10];
                const else_count: usize = packet.body[12] & 0x000f_ffff;
                try self.snapshotIndirectStream(submission, else_address, else_count, depth, active_addresses);
            }
        }
    }

    fn snapshotIndirectStream(
        self: *Scheduler,
        submission: *Submission,
        address: u64,
        word_count: usize,
        depth: usize,
        active_addresses: *[executor.maximum_stream_depth]u64,
    ) Error!void {
        if (address == 0 or address & 0x3 != 0 or word_count == 0) return;
        if (depth + 1 >= executor.maximum_stream_depth) return;
        for (active_addresses[0..depth]) |active| {
            if (active == address) return;
        }

        const child = try self.captureWords(submission, address, word_count);
        active_addresses[depth] = address;
        try self.snapshotStream(submission, child, address, depth + 1, active_addresses);
    }

    fn captureWords(
        self: *Scheduler,
        submission: *Submission,
        address: u64,
        word_count: usize,
    ) Error![]const u32 {
        const byte_count = std.math.mul(usize, word_count, @sizeOf(u32)) catch return Error.InvalidPacket;
        const requested_end = std.math.add(u64, address, byte_count) catch return Error.InvalidPacket;

        for (submission.snapshots.items) |snapshot| {
            if (address < snapshot.address) continue;
            const snapshot_bytes = std.mem.sliceAsBytes(snapshot.words);
            const snapshot_end = std.math.add(u64, snapshot.address, snapshot_bytes.len) catch continue;
            if (requested_end > snapshot_end) continue;
            const offset: usize = @intCast(address - snapshot.address);
            if (offset & 0x3 != 0) return Error.InvalidPacket;
            return snapshot.words[offset / 4 ..][0..word_count];
        }

        const words = try self.allocator.alloc(u32, word_count);
        errdefer self.allocator.free(words);
        if (!self.backend.vtable.read(self.backend.context, address, std.mem.sliceAsBytes(words))) {
            return Error.MemoryReadFailed;
        }
        try submission.snapshots.append(self.allocator, .{ .address = address, .words = words });
        return words;
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

/// Presents immutable submission snapshots at their original guest addresses
/// while forwarding every other operation to the live renderer/backend.
const SnapshotBackend = struct {
    original: executor.Backend,
    snapshots: []const Snapshot,
    forced_read: ?ForcedRead,

    fn from(context: ?*anyopaque) *SnapshotBackend {
        return @ptrCast(@alignCast(context.?));
    }

    fn makeVtable(self: *const SnapshotBackend) executor.Backend.VTable {
        return .{
            .read = read,
            .write = write,
            .acquire = if (self.original.vtable.acquire != null) acquire else null,
            .release = if (self.original.vtable.release != null) release else null,
            .wait = if (self.original.vtable.wait != null) wait else null,
            .write_data = if (self.original.vtable.write_data != null) writeData else null,
            .dma_data = if (self.original.vtable.dma_data != null) dmaData else null,
            .event = if (self.original.vtable.event != null) event else null,
            .flip = if (self.original.vtable.flip != null) flip else null,
            .draw = if (self.original.vtable.draw != null) draw else null,
            .dispatch = if (self.original.vtable.dispatch != null) dispatch else null,
        };
    }

    fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self = from(context);
        if (self.forced_read) |forced| {
            if (address == forced.address and bytes.len == forced.length) {
                @memcpy(bytes, forced.bytes[0..forced.length]);
                return true;
            }
        }
        for (self.snapshots) |snapshot| {
            if (address < snapshot.address) continue;
            const source = std.mem.sliceAsBytes(snapshot.words);
            const offset64 = address - snapshot.address;
            if (offset64 > source.len) continue;
            const offset: usize = @intCast(offset64);
            if (bytes.len > source.len - offset) continue;
            @memcpy(bytes, source[offset..][0..bytes.len]);
            return true;
        }
        return self.original.vtable.read(self.original.context, address, bytes);
    }

    fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const self = from(context);
        return self.original.vtable.write(self.original.context, address, bytes);
    }

    fn acquire(context: ?*anyopaque, value: gpu_state.AcquireMem) bool {
        const self = from(context);
        return self.original.vtable.acquire.?(self.original.context, value);
    }

    fn release(context: ?*anyopaque, value: gpu_state.ReleaseMem) bool {
        const self = from(context);
        return self.original.vtable.release.?(self.original.context, value);
    }

    fn wait(context: ?*anyopaque, value: gpu_state.WaitRegMem, satisfied: bool) bool {
        const self = from(context);
        return self.original.vtable.wait.?(self.original.context, value, satisfied);
    }

    fn writeData(context: ?*anyopaque, value: gpu_state.WriteData, words: []const u32) bool {
        const self = from(context);
        return self.original.vtable.write_data.?(self.original.context, value, words);
    }

    fn dmaData(context: ?*anyopaque, value: gpu_state.DmaData) bool {
        const self = from(context);
        return self.original.vtable.dma_data.?(self.original.context, value);
    }

    fn event(context: ?*anyopaque, value: gpu_state.EventWrite) bool {
        const self = from(context);
        return self.original.vtable.event.?(self.original.context, value);
    }

    fn flip(context: ?*anyopaque, value: gpu_state.Flip) bool {
        const self = from(context);
        return self.original.vtable.flip.?(self.original.context, value);
    }

    fn draw(context: ?*anyopaque, state: *const gpu_state.State, packet: pm4.Packet) bool {
        const self = from(context);
        return self.original.vtable.draw.?(self.original.context, state, packet);
    }

    fn dispatch(context: ?*anyopaque, state: *const gpu_state.State, packet: pm4.Packet) bool {
        const self = from(context);
        return self.original.vtable.dispatch.?(self.original.context, state, packet);
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
        1,                                        command(pm4.set_context_reg_indirect, 4),
        0x1180,                                   0,
        0,                                        1,
        command(pm4.event_write, 1),              0x21,
    };
    host.putWords(0x1100, &child);
    host.putWords(0x1180, &.{ 0x318, 0x1234_5678 });
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
    // redirect the saved indirect continuation. The child command buffer and
    // its indirect register list are equally immutable after submission.
    graphics[1] = 0x11c0;
    host.putWords(0x1100 + (child.len - 1) * 4, &.{0x7f});
    host.putWords(0x1180, &.{ 0x318, 0xdead_beef });
    _ = try scheduler.submit(.graphics, &queued_graphics);
    try testing.expectEqual(@as(usize, 1), scheduler.pendingCount(.graphics));

    const released = try scheduler.submit(.compute, &compute);
    try testing.expectEqual(@as(usize, 3), released.completed_submissions);
    try testing.expect(!scheduler.isBlocked(.graphics));
    try testing.expectEqual(@as(usize, 0), scheduler.pendingCount(.graphics));
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x21, 0x22 }, host.events[0..host.event_count]);
    try testing.expectEqual(
        @as(?u32, 0x1234_5678),
        scheduler.state(.graphics).readRegister(.context, 0x318),
    );
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

test "a protected wait can be soft-satisfied without mutating guest memory" {
    var host = FakeBackend{};
    const wait_stream = [_]u32{
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

    _ = try scheduler.submit(.graphics, &wait_stream);
    try testing.expect(scheduler.isBlocked(.graphics));
    const wait = scheduler.state(.graphics).blocked_wait.?;
    try testing.expect(scheduler.softSatisfyActiveWait(.graphics, wait));
    try testing.expectEqual(@as(usize, 1), (try scheduler.pump()).completed_submissions);
    try testing.expect(!scheduler.isBlocked(.graphics));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, host.memory[0x40..0x44], .little));
}

test "a label inside an indirect snapshot can be updated before resume" {
    var host = FakeBackend{};
    const label_address = 0x1128;
    const child = [_]u32{
        customCommand(pm4.custom.wait_mem_32, 6),
        label_address,
        0,
        0xffff_ffff,
        1,
        0x13,
        1,
        command(pm4.event_write, 1),
        0x20,
        command(pm4.nop, 1),
        0,
    };
    host.putWords(0x1100, &child);
    const graphics = [_]u32{
        command(pm4.indirect_buffer, 3), 0x1100, 0, 0x0f20_0000 | child.len,
    };

    var scheduler = Scheduler.init(testing.allocator, host.interface());
    defer scheduler.deinit();

    _ = try scheduler.submit(.graphics, &graphics);
    try testing.expect(scheduler.isBlocked(.graphics));

    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, 1, .little);
    try testing.expect(FakeBackend.vtable.write(&host, label_address, &payload));
    // The retained child still has the original zero until the scheduler is
    // told that this synchronization label, unlike PM4 itself, is mutable.
    try testing.expect((try scheduler.pump()).blocked_checks != 0);
    try testing.expect(scheduler.mirrorActiveWrite(.graphics, label_address, &payload));
    try testing.expectEqual(@as(usize, 1), (try scheduler.pump()).completed_submissions);
    try testing.expect(!scheduler.isBlocked(.graphics));
    try testing.expectEqualSlices(u8, &.{0x20}, host.events[0..host.event_count]);
}
