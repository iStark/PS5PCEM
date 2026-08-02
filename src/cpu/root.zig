// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest CPU dispatch and pthread scheduling.
//!
//! The dispatcher owns host workers and implements the complete libkernel
//! threading backend. Machine execution is deliberately behind `Bridge`: the
//! bridge is the only layer allowed to install or translate the guest FS base.
//! This matters on Windows, where FS addresses the host TEB and cannot remain
//! guest-owned while Zig or Win32 code runs.

const std = @import("std");
const hle = @import("hle");
const threading = hle.libs.kernel_threading;

const key_state_capacity: usize = 256;
const events_per_key: usize = 16;
const wake_all = std.math.maxInt(usize);

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

pub const ExecutionError = error{
    Unsupported,
    ExecutionFailed,
    Interrupted,
};

pub const Error = error{
    AlreadyInitialized,
    NotInitialized,
    InvalidArgument,
    DispatcherBusy,
} || std.mem.Allocator.Error || threading.Error || ExecutionError;

pub const EntryKind = enum {
    process_entry,
    pthread_entry,
    guest_callback,
};

/// Complete machine state required by an execution bridge for one guest call.
///
/// `stack_address` is the lowest writable byte. The initial RSP is normally
/// derived from `stack_address + stack_size` and aligned down to 16 bytes.
pub const ExecuteRequest = struct {
    kind: EntryKind,
    entry_point: u64,
    thread_handle: u64,
    arguments: [2]u64 = .{ 0, 0 },
    argument_count: u8 = 0,
    context: threading.ThreadContext,
    stack_address: u64,
    stack_size: u64,
    guard_size: u64,
};

/// Platform/native machine bridge used by `Dispatcher`.
///
/// Implementations execute System V AMD64 guest code and must make
/// `request.context.fs_base` visible to guest FS-relative instructions without
/// exposing that FS state to host Zig/HLE code. `interrupt` must make an active
/// `execute` return `error.Interrupted`; it is used by `scePthreadExit` and
/// dispatcher shutdown.
pub const Bridge = struct {
    context: ?*anyopaque = null,
    execute_fn: *const fn (?*anyopaque, ExecuteRequest) ExecutionError!u64,
    interrupt_fn: ?*const fn (?*anyopaque, u64) void = null,

    fn execute(self: Bridge, request: ExecuteRequest) ExecutionError!u64 {
        return self.execute_fn(self.context, request);
    }

    fn interrupt(self: Bridge, thread_handle: u64) void {
        if (self.interrupt_fn) |interrupt_fn| interrupt_fn(self.context, thread_handle);
    }
};

const WakeEvent = struct {
    sequence: u64 = 0,
    remaining: usize = 0,
};

const KeyState = struct {
    used: bool = false,
    key: u64 = 0,
    latest_sequence: u64 = 0,
    broadcast_sequence: u64 = 0,
    events: [events_per_key]WakeEvent = [_]WakeEvent{.{}} ** events_per_key,
};

const Worker = struct {
    dispatcher: *Dispatcher,
    request: threading.StartRequest,
    host_thread: ?std.Thread = null,
    result: u64 = 0,
    finished: bool = false,
    detached: bool,
    joining: bool = false,
    interrupt_sent: bool = false,
    execution_failed: bool = false,
};

const ActiveExecution = struct {
    dispatcher: *Dispatcher,
    thread_handle: u64,
    context: threading.ThreadContext,
    stack_address: u64,
    stack_size: u64,
    guard_size: u64,
    exit_requested: bool = false,
    exit_result: u64 = 0,
};

threadlocal var active_execution: ?ActiveExecution = null;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    manager: *threading.Manager = undefined,
    bridge: Bridge = undefined,
    workers: std.ArrayList(*Worker) = .empty,
    key_states: []KeyState = &.{},
    lock: Lock = .{},
    wake_epoch: u32 align(@alignOf(u32)) = 1,
    saturated_keys: bool = false,
    shutting_down: bool = false,
    initialized: bool = false,

    /// Initializes a stable, caller-owned dispatcher and attaches its pthread
    /// backend. The value must not move while guest execution is active.
    pub fn init(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *threading.Manager,
        bridge: Bridge,
    ) Error!void {
        if (self.initialized) return error.AlreadyInitialized;
        if (manager.hasBackend()) return error.DispatcherBusy;
        const states = try allocator.alloc(KeyState, key_state_capacity);
        @memset(states, .{});
        self.* = .{
            .allocator = allocator,
            .io = io,
            .manager = manager,
            .bridge = bridge,
            .key_states = states,
            .initialized = true,
        };
        manager.setBackend(self.backend());
    }

    /// Stops accepting work, requests every bridge execution to unwind, then
    /// joins all host workers before detaching from the pthread manager.
    pub fn deinit(self: *Dispatcher) void {
        if (!self.initialized) return;
        self.manager.setBackend(null);

        self.lock.lock();
        self.shutting_down = true;
        self.lock.unlock();
        self.publishWake();

        // Do not call bridge code under the dispatcher lock. An interrupt may
        // synchronously unwind through HLE and finish the same worker.
        while (true) {
            self.lock.lock();
            var handle: ?u64 = null;
            for (self.workers.items) |worker| {
                if (worker.finished or worker.interrupt_sent) continue;
                worker.interrupt_sent = true;
                handle = worker.request.thread_handle;
                break;
            }
            self.lock.unlock();
            const thread_handle = handle orelse break;
            self.bridge.interrupt(thread_handle);
        }

        while (true) {
            self.lock.lock();
            const worker = if (self.workers.items.len == 0)
                null
            else
                self.workers.pop();
            self.lock.unlock();
            const current = worker orelse break;
            if (current.host_thread) |host_thread| host_thread.join();
            self.allocator.destroy(current);
        }

        self.workers.deinit(self.allocator);
        self.allocator.free(self.key_states);
        self.* = .{};
    }

    pub fn backend(self: *Dispatcher) threading.Backend {
        return .{
            .context = self,
            .start_fn = &start,
            .join_fn = &join,
            .detach_fn = &detach,
            .yield_fn = &yield,
            .sleep_fn = &sleep,
            .wait_fn = &wait,
            .wake_fn = &wake,
            .call_fn = &call,
            .request_exit_fn = &requestExit,
        };
    }

    pub fn isInitialized(self: *const Dispatcher) bool {
        return self.initialized;
    }

    /// Executes the initial process thread on the caller's host worker.
    /// Callers retain ownership of `prepared` and release it afterwards.
    pub fn dispatchInitial(
        self: *Dispatcher,
        prepared: threading.PreparedThread,
        entry_point: u64,
        arguments: []const u64,
    ) Error!u64 {
        if (!self.initialized) return error.NotInitialized;
        if (entry_point == 0 or arguments.len > 2 or active_execution != null) {
            return error.InvalidArgument;
        }

        try self.manager.enter(prepared.handle);
        defer self.manager.leave();
        active_execution = .{
            .dispatcher = self,
            .thread_handle = @intFromPtr(prepared.handle.?),
            .context = prepared.context,
            .stack_address = prepared.stack_address,
            .stack_size = prepared.stack_size,
            .guard_size = prepared.guard_size,
        };
        defer active_execution = null;

        var request = ExecuteRequest{
            .kind = .process_entry,
            .entry_point = entry_point,
            .thread_handle = active_execution.?.thread_handle,
            .context = prepared.context,
            .stack_address = prepared.stack_address,
            .stack_size = prepared.stack_size,
            .guard_size = prepared.guard_size,
            .argument_count = @intCast(arguments.len),
        };
        @memcpy(request.arguments[0..arguments.len], arguments);
        const returned = self.bridge.execute(request) catch |err| {
            if (err == error.Interrupted and active_execution.?.exit_requested) {
                return active_execution.?.exit_result;
            }
            return err;
        };
        if (active_execution.?.exit_requested) return active_execution.?.exit_result;
        try self.manager.runSpecificDestructors();
        return returned;
    }

    fn start(raw: ?*anyopaque, request: threading.StartRequest) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        self.reapDetachedFinished();

        const worker = self.allocator.create(Worker) catch return error.StartFailed;
        worker.* = .{
            .dispatcher = self,
            .request = request,
            .detached = request.detached,
        };
        errdefer self.allocator.destroy(worker);

        self.lock.lock();
        if (self.shutting_down) {
            self.lock.unlock();
            return error.StartFailed;
        }
        self.workers.append(self.allocator, worker) catch {
            self.lock.unlock();
            return error.StartFailed;
        };
        self.lock.unlock();
        errdefer self.removeWorker(worker);

        worker.host_thread = std.Thread.spawn(.{}, workerMain, .{worker}) catch
            return error.StartFailed;
    }

    fn join(raw: ?*anyopaque, thread_handle: u64) threading.BackendError!u64 {
        const self = fromContext(raw) orelse return error.Unsupported;
        self.lock.lock();
        const worker = self.findWorkerLocked(thread_handle) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        if (worker.joining) {
            self.lock.unlock();
            return error.JoinFailed;
        }
        worker.joining = true;
        const host_thread = worker.host_thread orelse {
            self.lock.unlock();
            return error.JoinFailed;
        };
        self.lock.unlock();

        host_thread.join();
        self.lock.lock();
        const result = worker.result;
        _ = self.removeWorkerLocked(worker);
        self.lock.unlock();
        self.allocator.destroy(worker);
        return result;
    }

    fn detach(raw: ?*anyopaque, thread_handle: u64) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        self.lock.lock();
        const worker = self.findWorkerLocked(thread_handle) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        worker.detached = true;
        self.lock.unlock();
        self.reapDetachedFinished();
    }

    fn yield(_: ?*anyopaque) void {
        std.Thread.yield() catch {};
    }

    fn sleep(raw: ?*anyopaque, microseconds: u64) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        const duration = std.Io.Clock.Duration{
            .clock = .awake,
            .raw = .fromNanoseconds(@as(i96, microseconds) * std.time.ns_per_us),
        };
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, duration);
        while (true) {
            self.lock.lock();
            if (self.shutting_down) {
                self.lock.unlock();
                return error.WaitFailed;
            }
            const epoch = @atomicLoad(u32, &self.wake_epoch, .acquire);
            self.lock.unlock();

            const now = std.Io.Clock.Timestamp.now(self.io, deadline.clock);
            if (std.Io.Clock.Timestamp.compare(deadline, .lte, now)) return;
            self.io.futexWaitTimeout(
                u32,
                &self.wake_epoch,
                epoch,
                .{ .deadline = deadline },
            ) catch return error.WaitFailed;
        }
    }

    fn wait(
        raw: ?*anyopaque,
        request: threading.WaitRequest,
    ) threading.BackendError!threading.WaitResult {
        const self = fromContext(raw) orelse return error.Unsupported;
        const timeout = makeTimeout(self.io, request);
        const deadline = timeout.toTimestamp(self.io);

        while (true) {
            self.lock.lock();
            if (self.shutting_down) {
                self.lock.unlock();
                return error.WaitFailed;
            }
            if (self.consumeWakeLocked(request)) {
                self.lock.unlock();
                return .awoken;
            }
            const epoch = @atomicLoad(u32, &self.wake_epoch, .acquire);
            self.lock.unlock();

            if (deadline) |end| {
                const now = std.Io.Clock.Timestamp.now(self.io, end.clock);
                if (std.Io.Clock.Timestamp.compare(end, .lte, now)) return .timed_out;
            }
            self.io.futexWaitTimeout(u32, &self.wake_epoch, epoch, timeout) catch
                return error.WaitFailed;
        }
    }

    fn wake(
        raw: ?*anyopaque,
        key: u64,
        sequence: u64,
        maximum_waiters: usize,
    ) void {
        const self = fromContext(raw) orelse return;
        self.lock.lock();
        if (!self.shutting_down) self.recordWakeLocked(key, sequence, maximum_waiters);
        self.lock.unlock();
        self.publishWake();
    }

    fn call(raw: ?*anyopaque, guest_call: threading.GuestCall) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        const active = active_execution orelse return error.CallFailed;
        if (active.dispatcher != self or active.thread_handle != guest_call.thread_handle) {
            return error.CallFailed;
        }
        const request = ExecuteRequest{
            .kind = .guest_callback,
            .entry_point = guest_call.entry_point,
            .thread_handle = guest_call.thread_handle,
            .arguments = guest_call.arguments,
            .argument_count = guest_call.argument_count,
            .context = active.context,
            .stack_address = active.stack_address,
            .stack_size = active.stack_size,
            .guard_size = active.guard_size,
        };
        _ = self.bridge.execute(request) catch |err| {
            if (err == error.Unsupported) return error.Unsupported;
            if (err == error.Interrupted and active_execution.?.exit_requested) return;
            return error.CallFailed;
        };
    }

    fn requestExit(raw: ?*anyopaque, thread_handle: u64, result: u64) void {
        const self = fromContext(raw) orelse return;
        if (active_execution) |*active| {
            if (active.dispatcher != self or active.thread_handle != thread_handle) return;
            active.exit_requested = true;
            active.exit_result = result;
            self.bridge.interrupt(thread_handle);
        }
    }

    fn workerMain(worker: *Worker) void {
        const self = worker.dispatcher;
        const handle: threading.ThreadHandle = @ptrFromInt(worker.request.thread_handle);
        var result: u64 = 0;
        var failed = false;

        self.manager.enter(handle) catch {
            failed = true;
        };
        if (!failed) {
            active_execution = .{
                .dispatcher = self,
                .thread_handle = worker.request.thread_handle,
                .context = worker.request.context,
                .stack_address = worker.request.stack_address,
                .stack_size = worker.request.stack_size,
                .guard_size = worker.request.guard_size,
            };
            const request = ExecuteRequest{
                .kind = .pthread_entry,
                .entry_point = worker.request.entry_point,
                .thread_handle = worker.request.thread_handle,
                .arguments = .{ worker.request.argument, 0 },
                .argument_count = 1,
                .context = worker.request.context,
                .stack_address = worker.request.stack_address,
                .stack_size = worker.request.stack_size,
                .guard_size = worker.request.guard_size,
            };
            result = self.bridge.execute(request) catch |err| blk: {
                if (err == error.Interrupted and active_execution.?.exit_requested) {
                    break :blk active_execution.?.exit_result;
                }
                failed = true;
                break :blk 0;
            };
            if (active_execution.?.exit_requested) {
                result = active_execution.?.exit_result;
            } else if (!failed) {
                self.manager.runSpecificDestructors() catch {
                    failed = true;
                };
            }
            active_execution = null;
            self.manager.leave();
        }

        self.manager.complete(handle, result) catch {
            failed = true;
        };
        self.lock.lock();
        worker.result = result;
        worker.execution_failed = failed;
        worker.finished = true;
        self.lock.unlock();
        self.publishWake();
    }

    fn reapDetachedFinished(self: *Dispatcher) void {
        while (true) {
            self.lock.lock();
            var found: ?*Worker = null;
            for (self.workers.items) |worker| {
                if (worker.detached and worker.finished and !worker.joining) {
                    worker.joining = true;
                    found = worker;
                    _ = self.removeWorkerLocked(worker);
                    break;
                }
            }
            self.lock.unlock();
            const worker = found orelse return;
            if (worker.host_thread) |host_thread| host_thread.join();
            self.allocator.destroy(worker);
        }
    }

    fn removeWorker(self: *Dispatcher, worker: *Worker) void {
        self.lock.lock();
        _ = self.removeWorkerLocked(worker);
        self.lock.unlock();
    }

    fn removeWorkerLocked(self: *Dispatcher, worker: *Worker) bool {
        for (self.workers.items, 0..) |known, index| {
            if (known != worker) continue;
            _ = self.workers.orderedRemove(index);
            return true;
        }
        return false;
    }

    fn findWorkerLocked(self: *Dispatcher, thread_handle: u64) ?*Worker {
        for (self.workers.items) |worker| {
            if (worker.request.thread_handle == thread_handle) return worker;
        }
        return null;
    }

    fn findKeyLocked(self: *Dispatcher, key: u64) ?*KeyState {
        for (self.key_states) |*state| {
            if (state.used and state.key == key) return state;
        }
        return null;
    }

    fn findOrCreateKeyLocked(self: *Dispatcher, key: u64) ?*KeyState {
        if (self.findKeyLocked(key)) |state| return state;
        for (self.key_states) |*state| {
            if (state.used) continue;
            state.* = .{ .used = true, .key = key };
            return state;
        }
        self.saturated_keys = true;
        return null;
    }

    fn consumeWakeLocked(self: *Dispatcher, request: threading.WaitRequest) bool {
        // Saturation degrades to polling rather than risking a permanent lost
        // wakeup when a title creates more synchronization keys than expected.
        if (self.saturated_keys) return true;
        const state = self.findOrCreateKeyLocked(request.key) orelse return true;
        if (sequenceAfter(state.broadcast_sequence, request.observed_sequence)) return true;
        for (&state.events) |*event| {
            if (event.remaining == 0 or
                !sequenceAfter(event.sequence, request.observed_sequence)) continue;
            event.remaining -= 1;
            return true;
        }
        return false;
    }

    fn recordWakeLocked(
        self: *Dispatcher,
        key: u64,
        sequence: u64,
        maximum_waiters: usize,
    ) void {
        if (maximum_waiters == 0) return;
        const state = self.findOrCreateKeyLocked(key) orelse return;
        state.latest_sequence = sequence;
        if (maximum_waiters == wake_all) {
            state.broadcast_sequence = sequence;
            @memset(&state.events, .{});
            return;
        }

        for (&state.events) |*event| {
            if (event.remaining != 0 and event.sequence == sequence) {
                event.remaining +|= maximum_waiters;
                return;
            }
        }
        for (&state.events) |*event| {
            if (event.remaining != 0) continue;
            event.* = .{ .sequence = sequence, .remaining = maximum_waiters };
            return;
        }

        // More than `events_per_key` unconsumed signals means the exact waiter
        // cardinality is unavailable. A broadcast is the only safe fallback:
        // over-waking is recoverable because HLE rechecks object state, while a
        // dropped wake can deadlock the process.
        state.broadcast_sequence = sequence;
        @memset(&state.events, .{});
    }

    fn publishWake(self: *Dispatcher) void {
        _ = @atomicRmw(u32, &self.wake_epoch, .Add, 1, .release);
        self.io.futexWake(u32, &self.wake_epoch, std.math.maxInt(u32));
    }
};

fn fromContext(raw: ?*anyopaque) ?*Dispatcher {
    const pointer = raw orelse return null;
    const self: *Dispatcher = @ptrCast(@alignCast(pointer));
    return if (self.initialized) self else null;
}

fn sequenceAfter(candidate: u64, observed: u64) bool {
    if (candidate == 0 or candidate == observed) return false;
    return candidate -% observed < (@as(u64, 1) << 63);
}

fn guestClock(clock_id: i32) std.Io.Clock {
    return switch (clock_id) {
        0, 9, 10, 13 => .real,
        else => .awake,
    };
}

fn makeTimeout(io: std.Io, request: threading.WaitRequest) std.Io.Timeout {
    if (request.absolute_deadline_ns) |nanoseconds| {
        return .{ .deadline = .{
            .clock = guestClock(request.clock_id),
            .raw = .fromNanoseconds(@intCast(nanoseconds)),
        } };
    }
    if (request.timeout_microseconds) |microseconds| {
        const duration = std.Io.Clock.Duration{
            .clock = .awake,
            .raw = .fromNanoseconds(@as(i96, microseconds) * std.time.ns_per_us),
        };
        return .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, duration) };
    }
    return .none;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const memory = @import("memory");
const loader = @import("loader");

const TestBridge = struct {
    manager: *threading.Manager,
    calls: std.atomic.Value(usize) = .init(0),
    callbacks: std.atomic.Value(usize) = .init(0),
    last_fs_base: std.atomic.Value(u64) = .init(0),
    saw_stack: std.atomic.Value(bool) = .init(false),
    invoke_callback: bool = false,
    request_exit_result: ?u64 = null,

    fn execute(raw: ?*anyopaque, request: ExecuteRequest) ExecutionError!u64 {
        const self: *TestBridge = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.last_fs_base.store(request.context.fs_base, .release);
        self.saw_stack.store(request.stack_address != 0 and request.stack_size != 0, .release);
        if (request.kind == .guest_callback) {
            _ = self.callbacks.fetchAdd(1, .acq_rel);
            return 0;
        }
        if (self.invoke_callback) {
            self.manager.callGuest(0xfeed, &.{0xbeef}) catch return error.ExecutionFailed;
        }
        if (self.request_exit_result) |result| {
            threading.scePthreadExit(@ptrFromInt(result));
        }
        return request.arguments[0] + 1;
    }

    fn value(self: *TestBridge) Bridge {
        return .{ .context = self, .execute_fn = &execute };
    }
};

const TestContext = struct {
    address_space: memory.AddressSpace = undefined,
    tls_registry: loader.TlsRegistry = .{},
    manager: threading.Manager = .{},
    bridge: TestBridge = undefined,
    dispatcher: Dispatcher = .{},

    fn init(self: *TestContext) !void {
        self.* = .{};
        self.address_space = try memory.AddressSpace.init(testing.allocator);
        self.manager.init(testing.allocator, &self.address_space, &self.tls_registry);
        self.bridge = .{ .manager = &self.manager };
        try self.dispatcher.init(
            testing.allocator,
            testing.io,
            &self.manager,
            self.bridge.value(),
        );
        threading.attachManager(&self.manager);
    }

    fn deinit(self: *TestContext) void {
        threading.attachManager(null);
        self.dispatcher.deinit();
        self.manager.deinit();
        self.tls_registry.deinit(testing.allocator);
        self.address_space.deinit();
    }
};

test "initial dispatch carries FS, stack, arguments, and nested callbacks" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    context.bridge.invoke_callback = true;

    const prepared = try context.manager.prepareInitialThread("eboot-main");
    defer context.manager.releaseInitialThread(prepared.handle) catch {};
    const stack_mapping_address = prepared.stack_address - prepared.guard_size;
    const stack_mapping_size = prepared.guard_size +
        (try alignForwardForTest(prepared.stack_size, memory.page_size));
    const guard = context.address_space.query(stack_mapping_address, false).?;
    const stack = context.address_space.query(prepared.stack_address, false).?;
    try testing.expectEqual(memory.Protection.none, guard.protection);
    try testing.expect(stack.protection.write);
    const result = try context.dispatcher.dispatchInitial(prepared, 0x1234, &.{41});

    try testing.expectEqual(@as(u64, 42), result);
    try testing.expect(context.bridge.last_fs_base.load(.acquire) != 0);
    try testing.expect(context.bridge.saw_stack.load(.acquire));
    try testing.expectEqual(@as(usize, 1), context.bridge.callbacks.load(.acquire));
    try context.manager.releaseInitialThread(prepared.handle);
    try testing.expect(!context.address_space.isMapped(stack_mapping_address, stack_mapping_size));
}

test "pthread start and join run on a dispatcher host worker" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();

    var handle: threading.ThreadHandle = null;
    try context.manager.create(&handle, .{}, 0x4567, 9, "guest-worker");
    const result = try context.manager.join(handle);

    try testing.expectEqual(@as(u64, 10), result);
    try testing.expect(context.bridge.last_fs_base.load(.acquire) != 0);
    try testing.expect(context.bridge.saw_stack.load(.acquire));
}

test "scePthreadExit overrides a pthread entry return value" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    context.bridge.request_exit_result = 0x55;

    var handle: threading.ThreadHandle = null;
    try context.manager.create(&handle, .{}, 0x4567, 9, "guest-exit");
    try testing.expectEqual(@as(u64, 0x55), try context.manager.join(handle));
}

test "wake before park is consumed exactly once" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();

    Dispatcher.wake(&context.dispatcher, 0x1000, 2, 1);
    try testing.expectEqual(
        threading.WaitResult.awoken,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x1000,
            .observed_sequence = 1,
            .timeout_microseconds = 0,
        }),
    );
    try testing.expectEqual(
        threading.WaitResult.timed_out,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x1000,
            .observed_sequence = 1,
            .timeout_microseconds = 0,
        }),
    );
}

test "new waiters do not consume stale signal tokens" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();

    Dispatcher.wake(&context.dispatcher, 0x2000, 2, 1);
    Dispatcher.wake(&context.dispatcher, 0x2000, 3, 1);
    try testing.expectEqual(
        threading.WaitResult.awoken,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x2000,
            .observed_sequence = 2,
            .timeout_microseconds = 0,
        }),
    );
    try testing.expectEqual(
        threading.WaitResult.timed_out,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x2000,
            .observed_sequence = 3,
            .timeout_microseconds = 0,
        }),
    );
}

fn alignForwardForTest(value: u64, alignment: u64) !u64 {
    return std.mem.alignForward(u64, value, alignment);
}
