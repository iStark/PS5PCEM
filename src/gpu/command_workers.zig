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

pub export var incremental_command_snapshots: bool = true;
pub export var shared_command_banks: bool = true;
pub export var queued_ordering_commands: bool = true;
pub export var command_lookahead_limit: u32 = 64;
const maximum_lookahead = 64;
const bank_names = .{ "config", "context", "shader", "uconfig", "context_stack" };

// Only the interpreting worker changes references. The owner reads immutable
// bytes until Call.complete; a slot releases its references only after that.
const Bank = struct {
    bytes: []u8 = &.{},
    references: usize = 0,
    version: u64 = 0,
    identity: u64 = 0,
};
const BankStore = struct {
    records: [5][maximum_lookahead + 2]Bank = @splat(@splat(.{})),
    materialized: ?*state.State = null,

    fn acquire(self: *BankStore, index: usize, bytes: []const u8, version: u64, identity: u64) !*Bank {
        for (&self.records[index]) |*bank| if (bank.references == 0) {
            if (bank.bytes.len == 0) bank.bytes = try allocator.alloc(u8, bytes.len);
            std.debug.assert(bank.bytes.len == bytes.len);
            @memcpy(bank.bytes, bytes);
            bank.references = 1;
            bank.version = version;
            bank.identity = identity;
            return bank;
        };
        // At most one current bank plus one per occupied slot can be retained.
        unreachable;
    }

    fn deinit(self: *BankStore) void {
        for (&self.records) |*records| for (records) |*bank| {
            std.debug.assert(bank.references == 0);
            allocator.free(bank.bytes);
        };
        if (self.materialized) |registers| allocator.destroy(registers);
        self.* = .{};
    }
};

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
    failure_registers: ?*const state.State = null,
    snapshot: ?*Execution.DrawSlot = null,

    fn invoke(self: *Call) void {
        const task = self.execution;
        if (!task.failed.load(.acquire)) {
            var operation = self.operation;
            switch (operation) {
                .draw => |*value| if (self.snapshot) |slot| {
                    value.registers = task.materialize(slot);
                },
                .dispatch => |*value| if (self.snapshot) |slot| {
                    value.registers = task.materialize(slot);
                },
                else => {},
            }
            const backend = task.backend;
            const vt = backend.vtable;
            const context = backend.context;
            self.accepted = switch (operation) {
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
                    task.rejected_registers = if (self.snapshot) |slot| task.materialize(slot) else self.failure_registers orelse switch (operation) {
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
    slots: [maximum_lookahead]DrawSlot = @splat(.{}),
    cursor: usize = 0,
    lookahead_limit: usize = 4,
    prepared_draws: u64 = 0,
    prepared_controls: u64 = 0,
    snapshot_reads: u64 = 0,
    snapshot_bytes: u64 = 0,
    materialized_bytes: u64 = 0,
    bank_store: *BankStore = undefined,
    current_banks: [5]?*Bank = @splat(null),
    next_bank_identity: u64 = 1,
    materialized_ids: [5]u64 = @splat(0),

    const DrawSlot = struct {
        call: Call = undefined,
        occupied: bool = false,
        snapshot_valid: bool = false,
        registers: ?*state.State = null,
        words: std.ArrayList(u32) = .empty,
        banks: [5]?*Bank = @splat(null),

        fn releaseBanks(self: *DrawSlot) void {
            for (&self.banks) |*entry| if (entry.*) |bank| {
                std.debug.assert(bank.references != 0);
                bank.references -= 1;
                entry.* = null;
            };
        }

        fn deinit(self: *DrawSlot) void {
            if (self.occupied) self.call.complete.waitUncancelable(io());
            self.releaseBanks();
            if (self.registers) |registers| allocator.destroy(registers);
            self.words.deinit(allocator);
            self.* = .{};
        }
    };

    pub fn deinit(self: *Execution) void {
        for (&self.slots) |*slot| slot.deinit();
    }

    // Owner-thread scratch is valid for the duration of one backend callback.
    // Comparing against the preceding draw avoids copying unchanged banks
    // merely because the producer advanced to another lookahead slot.
    fn materialize(self: *Execution, slot: *const DrawSlot) *const state.State {
        if (slot.banks[0] == null) return slot.registers.?;
        const registers = self.bank_store.materialized.?;
        inline for (bank_names, 0..) |name, index| {
            const bank = slot.banks[index].?;
            if (self.materialized_ids[index] != bank.identity) {
                @memcpy(std.mem.asBytes(&@field(registers, name)), bank.bytes);
                self.materialized_ids[index] = bank.identity;
                self.materialized_bytes += bank.bytes.len;
            }
        }
        registers.copySnapshotScalars(slot.registers.?);
        return registers;
    }

    fn run(self: *Execution) void {
        defer for (&self.current_banks) |*entry| if (entry.*) |bank| {
            bank.references -= 1;
            entry.* = null;
        };
        self.lookahead_limit = std.math.clamp(@atomicLoad(u32, &command_lookahead_limit, .monotonic), 1, maximum_lookahead);
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

    fn reserveSlot(self: *Execution, registers: *const state.State) ?*DrawSlot {
        if (self.failed.load(.acquire)) return null;
        const slot = &self.slots[self.cursor];
        if (slot.occupied) slot.call.complete.waitUncancelable(io());
        if (self.failed.load(.acquire)) return null;
        if (slot.registers == null) slot.registers = allocator.create(state.State) catch return null;
        slot.releaseBanks();
        if (@atomicLoad(bool, &shared_command_banks, .monotonic)) {
            if (self.bank_store.materialized == null) self.bank_store.materialized = allocator.create(state.State) catch return null;
            inline for (bank_names, 0..) |name, index| {
                const version = registers.snapshot_versions[index];
                const previous = self.current_banks[index];
                if (previous == null or previous.?.version != version or version == std.math.maxInt(u64)) {
                    if (previous) |bank| bank.references -= 1;
                    self.current_banks[index] = null;
                    const bytes = std.mem.asBytes(&@field(registers, name));
                    self.current_banks[index] = self.bank_store.acquire(index, bytes, version, self.next_bank_identity) catch return null;
                    self.next_bank_identity += 1;
                    self.snapshot_bytes += bytes.len;
                }
                const bank = self.current_banks[index].?;
                bank.references += 1;
                slot.banks[index] = bank;
            }
            slot.registers.?.copySnapshotScalars(registers);
            slot.snapshot_valid = false;
        } else {
            self.snapshot_bytes += slot.registers.?.copySnapshot(registers, slot.snapshot_valid and @atomicLoad(bool, &incremental_command_snapshots, .monotonic));
            slot.snapshot_valid = true;
        }
        return slot;
    }

    fn enqueueSlot(self: *Execution, slot: *DrawSlot, operation: Operation) bool {
        slot.call = .{ .execution = self, .operation = operation, .failure_registers = slot.registers, .snapshot = slot };
        slot.occupied = true;
        self.pool.enqueue(&slot.call);
        self.cursor = (self.cursor + 1) % self.lookahead_limit;
        return true;
    }

    fn prepareDraw(self: *Execution, registers: *const state.State, packet: pm4.Packet, compute: bool) bool {
        const slot = self.reserveSlot(registers) orelse return false;
        slot.words.resize(allocator, packet.body.len) catch return false;
        @memcpy(slot.words.items, packet.body);
        var owned_packet = packet;
        owned_packet.body = slot.words.items;
        self.prepared_draws += 1;
        return self.enqueueSlot(slot, if (compute)
            .{ .dispatch = .{ .registers = slot.registers.?, .packet = owned_packet } }
        else
            .{ .draw = .{ .registers = slot.registers.?, .packet = owned_packet } });
    }

    fn prepareControl(self: *Execution, operation: Operation) bool {
        // These packets contain values only. Reads, borrowed write payloads,
        // waits and frame boundaries retain their synchronous FIFO requests.
        switch (operation) {
            .acquire, .release, .dma_data, .event => {},
            else => unreachable,
        }
        if (!@atomicLoad(bool, &queued_ordering_commands, .monotonic)) return self.request(operation);
        const slot = self.reserveSlot(self.registers) orelse return false;
        self.prepared_controls += 1;
        return self.enqueueSlot(slot, operation);
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
        return from(raw).prepareControl(.{ .acquire = value });
    }
    fn release(raw: ?*anyopaque, value: state.ReleaseMem) bool {
        return from(raw).prepareControl(.{ .release = value });
    }
    fn wait(raw: ?*anyopaque, value: state.WaitRegMem, satisfied: bool) bool {
        return from(raw).request(.{ .wait = .{ .value = value, .satisfied = satisfied } });
    }
    fn writeData(raw: ?*anyopaque, value: state.WriteData, words: []const u32) bool {
        return from(raw).request(.{ .write_data = .{ .value = value, .words = words } });
    }
    fn dmaData(raw: ?*anyopaque, value: state.DmaData) bool {
        return from(raw).prepareControl(.{ .dma_data = value });
    }
    fn event(raw: ?*anyopaque, value: state.EventWrite) bool {
        return from(raw).prepareControl(.{ .event = value });
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
    prepared_controls: u64 = 0,
    snapshot_reads: u64 = 0,
    snapshot_bytes: u64 = 0,

    const Worker = struct {
        thread: ?std.Thread = null,
        ready: std.Io.Event = .unset,
        task: ?*Execution = null,
        stopping: bool = false,
        thread_id: ?std.Thread.Id = null,
        // Allocations survive submission boundaries; queued calls never do.
        slots: [maximum_lookahead]Execution.DrawSlot = @splat(.{}),
        bank_store: BankStore = .{},

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
                current.bank_store = &worker.bank_store;
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
            self.prepared_controls += current.prepared_controls;
            self.snapshot_reads += current.snapshot_reads;
            self.snapshot_bytes += current.snapshot_bytes + current.materialized_bytes;
            if (current.failed.load(.acquire)) current.failure = error.BackendRejected;
            // Decoding may have advanced beyond the rejected draw. Preserve
            // the same register state a serial interpreter leaves on failure.
            if (current.rejected_registers) |registers| current.registers.* = registers.*;
            worker.slots = current.slots;
            for (&worker.slots) |*slot| {
                slot.occupied = false;
                slot.snapshot_valid = false;
                slot.releaseBanks();
            }
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
            worker.bank_store.deinit();
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
    try std.testing.expect(pool.peak_pending <= maximum_lookahead * 2);
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

test "queued ordering packets preserve serial effects rejection state and frame boundaries" {
    const Host = struct {
        const Item = struct { kind: u8, value: u64 };
        owner: std.Thread.Id,
        items: [1024]Item = undefined,
        count: usize = 0,
        label: u32 = 0,
        reject: u32 = 0,
        wrong_thread: bool = false,
        const vtable = executor.Backend.VTable{ .read = read, .write = write, .acquire = acquire, .release = release, .event = event, .draw = draw, .flip = flip };
        fn from(raw: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(raw.?));
        }
        fn record(self: *@This(), kind: u8, value: u64) bool {
            self.wrong_thread = self.wrong_thread or self.owner != std.Thread.getCurrentId();
            self.items[self.count] = .{ .kind = kind, .value = value };
            self.count += 1;
            return true;
        }
        fn read(raw: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self = from(raw);
            if (address != 0x1000 or bytes.len != 4) return false;
            std.mem.writeInt(u32, bytes[0..4], self.label, .little);
            return self.record(1, self.label);
        }
        fn write(_: ?*anyopaque, _: u64, _: []const u8) bool {
            return false;
        }
        fn acquire(raw: ?*anyopaque, value: state.AcquireMem) bool {
            const self = from(raw);
            _ = self.record(2, value.base_address);
            return self.reject == 0 or value.base_address != self.reject * 256;
        }
        fn release(raw: ?*anyopaque, value: state.ReleaseMem) bool {
            const self = from(raw);
            self.label = @truncate(value.data);
            return self.record(3, value.data);
        }
        fn event(raw: ?*anyopaque, value: state.EventWrite) bool {
            return from(raw).record(4, value.event_type);
        }
        fn draw(raw: ?*anyopaque, registers: *const state.State, packet: pm4.Packet) bool {
            const value = registers.readRegister(.context, 0x318) orelse return false;
            if (value != packet.body[0]) return false;
            if (registers.readRegister(.config, 0x30) != value or
                registers.readRegister(.shader, 0x30) != value or
                registers.readRegister(.uconfig, 0x30) != value or
                registers.context_depth != 1 or
                registers.context_stack[0].values[0x318] != value) return false;
            return from(raw).record(5, value);
        }
        fn flip(raw: ?*anyopaque, _: state.Flip) bool {
            const self = from(raw);
            return self.record(6, self.label);
        }
        fn interface(self: *@This()) executor.Backend {
            return .{ .context = self, .vtable = &vtable };
        }
    };
    const a = std.testing.allocator;
    var stream: std.ArrayList(u32) = .empty;
    defer stream.deinit(a);
    for (1..101) |index| {
        const n: u32 = @intCast(index);
        try stream.appendSlice(a, &.{
            command(pm4.set_context_reg, 2),                                 0x318,                           n,
            command(pm4.set_config_reg, 2),                                  0x30,                            n,
            command(pm4.set_sh_reg, 2),                                      0x30,                            n,
            command(pm4.set_uconfig_reg, 2),                                 0x30,                            n,
            command(pm4.nop, 1) | (@as(u32, pm4.custom.context_state) << 2), 3,                               command(pm4.set_context_reg, 2),
            0x318,                                                           n,                               command(pm4.nop, 7) | (@as(u32, pm4.custom.acquire_mem) << 2),
            0x80000001,                                                      1,                               0,
            n,                                                               0,                               3,
            0x388,                                                           command(pm4.draw_index_auto, 2), n,
            0,                                                               command(pm4.event_write, 1),     0x2f,
            command(pm4.release_mem, 7),                                     0,                               1 << 29,
            0x1000,                                                          0,                               n,
            0,                                                               0,                               command(pm4.nop, 1) | (@as(u32, pm4.custom.context_state) << 2),
            2,
        });
        if (n % 23 == 0) try stream.appendSlice(a, &.{ command(pm4.wait_reg_mem, 6), 0x13, 0x1000, 0, n, 0xffffffff, 1 });
    }
    try stream.appendSlice(a, &.{ command(pm4.nop, 5) | (@as(u32, pm4.custom.flip) << 2), 1, 0, 0, 0, 0 });
    var pool = Pool{};
    defer pool.deinit();
    const saved_shared = shared_command_banks;
    const saved_limit = command_lookahead_limit;
    defer {
        shared_command_banks = saved_shared;
        command_lookahead_limit = saved_limit;
    }
    for ([_]bool{ false, true }) |shared| {
        shared_command_banks = shared;
        for ([_]u32{ 4, 64 }) |limit| {
            command_lookahead_limit = limit;
            for ([_]u32{ 0, 2, 67, 0 }) |reject| {
                var serial_host = Host{ .owner = std.Thread.getCurrentId(), .reject = reject };
                var parallel_host = Host{ .owner = std.Thread.getCurrentId(), .reject = reject };
                const serial_state = try a.create(state.State);
                defer a.destroy(serial_state);
                serial_state.* = .{};
                const parallel_state = try a.create(state.State);
                defer a.destroy(parallel_state);
                parallel_state.* = .{};
                var serial = executor.DcbExecutor{ .state = serial_state, .backend = serial_host.interface(), .allocator = a };
                const serial_result = serial.execute(stream.items);
                var task = Execution{ .registers = parallel_state, .stream = stream.items, .backend = parallel_host.interface() };
                defer task.deinit();
                try std.testing.expect(pool.run(.{ &task, null }));
                if (reject == 0) {
                    try std.testing.expectEqual(executor.Status.complete, (try serial_result).status);
                    try std.testing.expectEqual(@as(?executor.Error, null), task.failure);
                    try std.testing.expectEqual(executor.Status.complete, task.result.?.status);
                    try std.testing.expectEqual(@as(u8, 6), parallel_host.items[parallel_host.count - 1].kind);
                    try std.testing.expectEqual(@as(u64, 100), parallel_host.items[parallel_host.count - 1].value);
                    try std.testing.expectEqual(@as(u64, 300), task.prepared_controls);
                } else {
                    try std.testing.expectError(error.BackendRejected, serial_result);
                    try std.testing.expectEqual(@as(?executor.Error, error.BackendRejected), task.failure);
                }
                try std.testing.expectEqualDeep(serial_host.items[0..serial_host.count], parallel_host.items[0..parallel_host.count]);
                try std.testing.expectEqualDeep(serial_state.*, parallel_state.*);
                try std.testing.expect(!parallel_host.wrong_thread);
                try std.testing.expectEqual(@as(usize, 0), pool.pending);
                try std.testing.expect(pool.peak_pending <= maximum_lookahead + 1);
                for (&pool.workers) |*worker| for (&worker.bank_store.records) |*records| for (records) |bank| {
                    try std.testing.expectEqual(@as(usize, 0), bank.references);
                };
            }
        }
    }
}
