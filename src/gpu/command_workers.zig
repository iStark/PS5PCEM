// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Per-queue command processors with bounded draw lookahead. Workers own only
//! command/register interpretation. All memory and rendering callbacks run on
//! the calling thread, in FIFO order within each guest queue.
const std = @import("std");
const executor = @import("executor.zig");
const state = @import("state.zig");
const pm4 = @import("pm4.zig");
const allocator = std.heap.page_allocator;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Operation = union(enum) {
    read: struct { address: u64, bytes: []u8 },
    read_live: struct { address: u64, bytes: []u8 },
    read_wait: struct { address: u64, bytes: []u8 },
    write: struct { address: u64, bytes: []const u8 },
    acquire: state.AcquireMem,
    release: state.ReleaseMem,
    wait: struct { value: state.WaitRegMem, satisfied: bool },
    write_data: struct { value: state.WriteData, words: []const u32 },
    dma_data: state.DmaData,
    event: state.EventWrite,
    flip: state.Flip,
    draw: struct { registers: *const state.State, packet: pm4.Packet },
    dispatch: struct { registers: *const state.State, packet: pm4.Packet },
};

const Call = struct {
    next: ?*Call = null,
    execution: *Execution,
    operation: Operation,
    complete: std.Io.Event = .unset,
    accepted: bool = false,

    fn invoke(self: *Call) void {
        const task = self.execution;
        if (!task.failed.load(.acquire)) {
            const backend = task.backend;
            const vt = backend.vtable;
            const context = backend.context;
            self.accepted = switch (self.operation) {
                .read => |value| vt.read(context, value.address, value.bytes),
                .read_live => |value| (vt.read_live orelse vt.read)(context, value.address, value.bytes),
                .read_wait => |value| (vt.read_wait orelse vt.read)(context, value.address, value.bytes),
                .write => |value| vt.write(context, value.address, value.bytes),
                .acquire => |value| vt.acquire.?(context, value),
                .release => |value| vt.release.?(context, value),
                .wait => |value| vt.wait.?(context, value.value, value.satisfied),
                .write_data => |value| vt.write_data.?(context, value.value, value.words),
                .dma_data => |value| vt.dma_data.?(context, value),
                .event => |value| vt.event.?(context, value),
                .flip => |value| vt.flip.?(context, value),
                .draw => |value| vt.draw.?(context, value.registers, value.packet),
                .dispatch => |value| vt.dispatch.?(context, value.registers, value.packet),
            };
            // Unbacked reads are allowed to return false to the executor. A
            // rejected rendering/ordering command invalidates later lookahead.
            switch (self.operation) {
                .read, .read_live, .read_wait => {},
                else => if (!self.accepted) {
                    task.rejected_registers = switch (self.operation) {
                        .draw => |value| value.registers,
                        .dispatch => |value| value.registers,
                        else => null,
                    };
                    task.failed.store(true, .release);
                },
            }
        }
        self.complete.set(io());
        // A synchronous caller can release this stack record immediately.
    }
};

pub const Execution = struct {
    registers: *state.State,
    stream: []const u32,
    continuation: ?executor.Continuation = null,
    backend: executor.Backend,
    result: ?executor.Result = null,
    failure: ?executor.Error = null,
    rejected_registers: ?*const state.State = null,
    failed: std.atomic.Value(bool) = .init(false),
    pool: *Pool = undefined,
    slots: [4]DrawSlot = @splat(.{}),
    cursor: usize = 0,
    prepared_draws: u64 = 0,
    snapshot_reads: u64 = 0,

    const DrawSlot = struct {
        call: Call = undefined,
        occupied: bool = false,
        registers: ?*state.State = null,
        words: std.ArrayList(u32) = .empty,

        fn deinit(self: *DrawSlot) void {
            if (self.occupied) self.call.complete.waitUncancelable(io());
            if (self.registers) |registers| allocator.destroy(registers);
            self.words.deinit(allocator);
            self.* = .{};
        }
    };

    pub fn deinit(self: *Execution) void {
        for (&self.slots) |*slot| slot.deinit();
    }

    fn run(self: *Execution) void {
        const original = self.backend.vtable;
        const vtable = executor.Backend.VTable{
            .read = read,
            .read_live = readLive,
            .read_wait = readWait,
            .write = write,
            .acquire = if (original.acquire != null) acquire else null,
            .release = if (original.release != null) release else null,
            .wait = if (original.wait != null) wait else null,
            .write_data = if (original.write_data != null) writeData else null,
            .dma_data = if (original.dma_data != null) dmaData else null,
            .event = if (original.event != null) event else null,
            .flip = if (original.flip != null) flip else null,
            .draw = if (original.draw != null) draw else null,
            .dispatch = if (original.dispatch != null) dispatch else null,
        };
        var interpreter = executor.DcbExecutor{
            .state = self.registers,
            .backend = .{ .context = self, .vtable = &vtable },
            .allocator = allocator,
        };
        self.result = (if (self.continuation) |continuation|
            interpreter.resumeFrom(self.stream, continuation)
        else
            interpreter.execute(self.stream)) catch |err| {
            self.failure = err;
            return;
        };
    }

    fn from(raw: ?*anyopaque) *Execution {
        return @ptrCast(@alignCast(raw.?));
    }

    fn request(self: *Execution, operation: Operation) bool {
        if (self.failed.load(.acquire)) return false;
        var call = Call{ .execution = self, .operation = operation };
        self.pool.enqueue(&call);
        call.complete.waitUncancelable(io());
        return call.accepted;
    }

    fn prepareDraw(self: *Execution, registers: *const state.State, packet: pm4.Packet, compute: bool) bool {
        if (self.failed.load(.acquire)) return false;
        const slot = &self.slots[self.cursor];
        if (slot.occupied) slot.call.complete.waitUncancelable(io());
        if (self.failed.load(.acquire)) return false;
        if (slot.registers == null) slot.registers = allocator.create(state.State) catch return false;
        slot.words.resize(allocator, packet.body.len) catch return false;
        @memcpy(slot.words.items, packet.body);
        slot.registers.?.* = registers.*;
        var owned_packet = packet;
        owned_packet.body = slot.words.items;
        slot.call = .{
            .execution = self,
            .operation = if (compute)
                .{ .dispatch = .{ .registers = slot.registers.?, .packet = owned_packet } }
            else
                .{ .draw = .{ .registers = slot.registers.?, .packet = owned_packet } },
        };
        slot.occupied = true;
        self.pool.enqueue(&slot.call);
        self.cursor = (self.cursor + 1) % self.slots.len;
        self.prepared_draws += 1;
        return true;
    }

    fn read(raw: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self = from(raw);
        if (self.failed.load(.acquire)) return false;
        if (self.backend.vtable.read_snapshot) |copy| {
            if (copy(self.backend.context, address, bytes)) {
                self.snapshot_reads += 1;
                return true;
            }
        }
        return self.request(.{ .read = .{ .address = address, .bytes = bytes } });
    }
    fn readLive(raw: ?*anyopaque, address: u64, bytes: []u8) bool {
        return from(raw).request(.{ .read_live = .{ .address = address, .bytes = bytes } });
    }
    fn readWait(raw: ?*anyopaque, address: u64, bytes: []u8) bool {
        return from(raw).request(.{ .read_wait = .{ .address = address, .bytes = bytes } });
    }
    fn write(raw: ?*anyopaque, address: u64, bytes: []const u8) bool {
        return from(raw).request(.{ .write = .{ .address = address, .bytes = bytes } });
    }
    fn acquire(raw: ?*anyopaque, value: state.AcquireMem) bool {
        return from(raw).request(.{ .acquire = value });
    }
    fn release(raw: ?*anyopaque, value: state.ReleaseMem) bool {
        return from(raw).request(.{ .release = value });
    }
    fn wait(raw: ?*anyopaque, value: state.WaitRegMem, satisfied: bool) bool {
        return from(raw).request(.{ .wait = .{ .value = value, .satisfied = satisfied } });
    }
    fn writeData(raw: ?*anyopaque, value: state.WriteData, words: []const u32) bool {
        return from(raw).request(.{ .write_data = .{ .value = value, .words = words } });
    }
    fn dmaData(raw: ?*anyopaque, value: state.DmaData) bool {
        return from(raw).request(.{ .dma_data = value });
    }
    fn event(raw: ?*anyopaque, value: state.EventWrite) bool {
        return from(raw).request(.{ .event = value });
    }
    fn flip(raw: ?*anyopaque, value: state.Flip) bool {
        return from(raw).request(.{ .flip = value });
    }
    fn draw(raw: ?*anyopaque, registers: *const state.State, packet: pm4.Packet) bool {
        return from(raw).prepareDraw(registers, packet, false);
    }
    fn dispatch(raw: ?*anyopaque, registers: *const state.State, packet: pm4.Packet) bool {
        return from(raw).prepareDraw(registers, packet, true);
    }
};

pub const Pool = struct {
    lock: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    head: ?*Call = null,
    tail: ?*Call = null,
    remaining: usize = 0,
    pending: usize = 0,
    peak_pending: usize = 0,
    start_failed: bool = false,
    workers: [2]Worker = @splat(.{}),
    batches: u64 = 0,
    paired_batches: u64 = 0,
    prepared_draws: u64 = 0,
    snapshot_reads: u64 = 0,

    const Worker = struct {
        thread: ?std.Thread = null,
        ready: std.Io.Event = .unset,
        task: ?*Execution = null,
        stopping: bool = false,
        thread_id: ?std.Thread.Id = null,
        // Allocations survive submission boundaries; queued calls never do.
        slots: [4]Execution.DrawSlot = @splat(.{}),

        fn run(self: *Worker) void {
            self.thread_id = std.Thread.getCurrentId();
            while (true) {
                self.ready.waitUncancelable(io());
                self.ready.reset();
                if (self.stopping) return;
                const task = self.task.?;
                task.run();
                const pool = task.pool;
                pool.lock.lockUncancelable(io());
                pool.remaining -= 1;
                pool.changed.signal(io());
                pool.lock.unlock(io());
            }
        }
    };

    /// False means no task started and the owner must execute synchronously.
    /// Keep the pool at a stable address until deinit; only its owner calls run.
    pub fn run(self: *Pool, tasks: [2]?*Execution) bool {
        if (self.start_failed) return false;
        for (&self.workers) |*worker| {
            if (worker.thread == null) worker.thread = std.Thread.spawn(.{}, Worker.run, .{worker}) catch {
                self.deinit();
                self.start_failed = true;
                return false;
            };
        }
        self.remaining = @intFromBool(tasks[0] != null) + @as(usize, @intFromBool(tasks[1] != null));
        if (self.remaining == 0) return true;
        self.batches += 1;
        if (self.remaining == 2) self.paired_batches += 1;
        for (tasks, &self.workers) |task, *worker| {
            if (task) |current| {
                current.pool = self;
                current.slots = worker.slots;
                worker.slots = @splat(.{});
                worker.task = current;
                worker.ready.set(io());
            }
        }
        self.lock.lockUncancelable(io());
        while (self.remaining != 0 or self.head != null) {
            const call = self.head orelse {
                self.changed.waitUncancelable(io(), &self.lock);
                continue;
            };
            self.head = call.next;
            self.pending -= 1;
            if (self.head == null) self.tail = null;
            self.lock.unlock(io());
            call.invoke();
            self.lock.lockUncancelable(io());
        }
        self.lock.unlock(io());
        for (tasks, &self.workers) |task, *worker| if (task) |current| {
            self.prepared_draws += current.prepared_draws;
            self.snapshot_reads += current.snapshot_reads;
            if (current.failed.load(.acquire)) current.failure = error.BackendRejected;
            // Decoding may have advanced beyond the rejected draw. Preserve
            // the same register state a serial interpreter leaves on failure.
            if (current.rejected_registers) |registers| current.registers.* = registers.*;
            worker.slots = current.slots;
            for (&worker.slots) |*slot| slot.occupied = false;
            current.slots = @splat(.{});
        };
        return true;
    }

    fn enqueue(self: *Pool, call: *Call) void {
        self.lock.lockUncancelable(io());
        if (self.tail) |tail| tail.next = call else self.head = call;
        self.tail = call;
        self.pending += 1;
        self.peak_pending = @max(self.peak_pending, self.pending);
        self.changed.signal(io());
        self.lock.unlock(io());
    }

    pub fn deinit(self: *Pool) void {
        std.debug.assert(self.remaining == 0 and self.head == null);
        for (&self.workers) |*worker| if (worker.thread != null) {
            worker.stopping = true;
            worker.ready.set(io());
        };
        for (&self.workers) |*worker| if (worker.thread) |thread| {
            thread.join();
            for (&worker.slots) |*slot| slot.deinit();
            worker.* = .{};
        };
    }
};

fn command(opcode: u8, words: u14) u32 {
    return (@as(u32, 3) << 30) | (@as(u32, words - 1) << 16) | (@as(u32, opcode) << 8);
}

const TestHost = struct {
    pool: *Pool,
    owner: std.Thread.Id,
    observed: [2]u32 = @splat(0),
    reject_at: u32 = 0,
    observe_overlap: bool = false,
    overlapped: bool = false,
    wrong_thread: bool = false,
    wrong_snapshot: bool = false,

    const vtable = executor.Backend.VTable{ .read = read, .write = write, .draw = draw };
    fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
        return false;
    }
    fn write(_: ?*anyopaque, _: u64, _: []const u8) bool {
        return false;
    }
    fn draw(raw: ?*anyopaque, registers: *const state.State, packet: pm4.Packet) bool {
        const self: *TestHost = @ptrCast(@alignCast(raw.?));
        self.wrong_thread = self.wrong_thread or self.owner != std.Thread.getCurrentId();
        const value = registers.readRegister(.context, 0x318) orelse return false;
        const queue = value >> 16;
        if (queue > 1) return false;
        const sequence = value & 0xffff;
        self.wrong_snapshot = self.wrong_snapshot or sequence != self.observed[queue] + 1 or packet.body[0] != sequence;
        self.observed[queue] = sequence;
        if (self.observe_overlap and !self.overlapped) {
            const start = std.Io.Clock.awake.now(io()).nanoseconds;
            while (std.Io.Clock.awake.now(io()).nanoseconds - start < 5 * std.time.ns_per_s) {
                self.pool.lock.lockUncancelable(io());
                const pending = self.pool.pending;
                self.pool.lock.unlock(io());
                if (pending >= 7) {
                    self.overlapped = true;
                    break;
                }
                std.Thread.yield() catch {};
            }
            if (!self.overlapped) return false;
        }
        return self.reject_at == 0 or sequence != self.reject_at;
    }
};

fn testStream(queue: u32) [60]u32 {
    var words: [60]u32 = undefined;
    for (0..10) |i| {
        const sequence: u32 = @intCast(i + 1);
        words[i * 6 ..][0..6].* = .{
            command(pm4.set_context_reg, 2), 0x318,    (queue << 16) | sequence,
            command(pm4.draw_index_auto, 2), sequence, 0,
        };
    }
    return words;
}

test "queue processors overlap with bounded immutable draw snapshots and owner callbacks" {
    var pool = Pool{};
    defer pool.deinit();
    var host = TestHost{ .pool = &pool, .owner = std.Thread.getCurrentId(), .observe_overlap = true };
    var graphics = state.State{};
    var compute = state.State{};
    const first_words = testStream(0);
    const second_words = testStream(1);
    var first = Execution{ .registers = &graphics, .stream = &first_words, .backend = .{ .context = &host, .vtable = &TestHost.vtable } };
    defer first.deinit();
    var second = Execution{ .registers = &compute, .stream = &second_words, .backend = first.backend };
    defer second.deinit();
    try std.testing.expect(pool.run(.{ &first, &second }));
    try std.testing.expectEqual(@as(?executor.Error, null), first.failure);
    try std.testing.expectEqual(@as(?executor.Error, null), second.failure);
    try std.testing.expectEqual([2]u32{ 10, 10 }, host.observed);
    try std.testing.expect(host.overlapped and !host.wrong_thread and !host.wrong_snapshot);
    try std.testing.expect(pool.peak_pending <= 8);
    try std.testing.expect(pool.workers[0].thread_id.? != pool.workers[1].thread_id.?);
    try std.testing.expect(pool.workers[0].thread_id.? != host.owner);
    try std.testing.expect(pool.workers[1].thread_id.? != host.owner);
}

test "rejected draw stops later lookahead and workers remain reusable" {
    var pool = Pool{};
    defer pool.deinit();
    var host = TestHost{ .pool = &pool, .owner = std.Thread.getCurrentId(), .reject_at = 2 };
    const words = testStream(0);
    for (0..2) |_| {
        var registers = state.State{};
        var execution = Execution{ .registers = &registers, .stream = &words, .backend = .{ .context = &host, .vtable = &TestHost.vtable } };
        defer execution.deinit();
        host.observed = @splat(0);
        try std.testing.expect(pool.run(.{ &execution, null }));
        try std.testing.expectEqual(@as(?executor.Error, error.BackendRejected), execution.failure);
        try std.testing.expectEqual(@as(u32, 2), host.observed[0]);
        try std.testing.expectEqual(@as(?u32, 2), registers.readRegister(.context, 0x318));
        try std.testing.expect(!host.wrong_thread and !host.wrong_snapshot);
        try std.testing.expectEqual(@as(usize, 0), pool.pending);
    }
}
