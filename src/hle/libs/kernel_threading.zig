// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest pthread lifecycle and AMD64 Variant II thread-local storage.
//!
//! The HLE layer owns guest-visible pthread handles and attributes. Actual
//! guest instruction execution remains an execution-backend responsibility:
//! every start request carries a fully initialized FS base, TCB, and DTV. This
//! boundary is intentional. In particular, Windows uses FS for the host TEB,
//! so replacing it while Zig or Win32 code is running would corrupt the host
//! thread. A native/JIT backend must install the supplied FS base only while it
//! is executing guest instructions, or patch segment-relative accesses.

const std = @import("std");
const memory = @import("memory");
const loader = @import("loader");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

const KernelError = errno.KernelError;
const Posix = errno.Posix;

pub const default_stack_size: u64 = 0x10_0000;
pub const minimum_stack_size: u64 = memory.page_size;
pub const default_guard_size: u64 = 0x1000;
pub const default_affinity_mask: u64 = 0x7f;
pub const default_priority: i32 = 700;
pub const default_policy: i32 = 1;
pub const default_inherit_sched: i32 = 4;

const minimum_tls_prefix: u64 = 0x20_000;
const tcb_size: u64 = 0x100;
const dtv_header_slots: u64 = 2;
const errno_tcb_offset: u64 = 0x80;
const stack_canary: u64 = 0xc0de_c0de_cafe_ba00;
const attr_magic: u64 = 0x5054_4852_4154_5452;
const maximum_keys: usize = 256;
const destructor_iterations: usize = 4;

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

pub const BackendError = error{
    Unsupported,
    StartFailed,
    ThreadNotFound,
    WouldDeadlock,
    JoinFailed,
    WaitFailed,
    CallFailed,
};

pub const WaitResult = enum {
    awoken,
    timed_out,
};

/// One scheduler-visible wait. Sequence numbers make wakeups race-free when a
/// signal happens after an HLE object is unlocked but before the backend parks
/// its current guest thread.
pub const WaitRequest = struct {
    key: u64,
    observed_sequence: u64,
    timeout_microseconds: ?u64 = null,
    absolute_deadline_ns: ?u64 = null,
    /// Guest clock ID used to interpret an absolute deadline. Relative sce
    /// timeouts leave this at `CLOCK_REALTIME` because the field is irrelevant.
    clock_id: i32 = 0,
};

pub const GuestCall = struct {
    entry_point: u64,
    thread_handle: u64,
    arguments: [6]u64 = [_]u64{0} ** 6,
    argument_count: u8 = 0,
};

/// Guest register state that a CPU backend must install before entering a
/// thread. `fs_base` is the address of the TCB, not the mapping base.
pub const ThreadContext = struct {
    tls_mapping_address: u64,
    tls_mapping_size: u64,
    fs_base: u64,
    dtv_address: u64,
    tls_generation: u64,
};

pub const StartRequest = struct {
    thread_handle: u64,
    entry_point: u64,
    argument: u64,
    context: ThreadContext,
    stack_address: u64,
    stack_size: u64,
    guard_size: u64,
    priority: i32,
    affinity_mask: u64,
    detached: bool,
    name: [32]u8,

    pub fn nameSlice(self: *const StartRequest) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

/// Adapter supplied by the future CPU dispatcher/native execution backend.
/// `start` must eventually call `Manager.complete` after guest execution has
/// left the supplied TLS context. `request_exit` transfers control out of a
/// guest entry point; it must not destroy the TLS mapping while guest code is
/// still using it. A `join` callback must not return until that same execution
/// context is quiescent, because the manager reclaims its TLS mapping next.
pub const Backend = struct {
    context: ?*anyopaque = null,
    start_fn: *const fn (?*anyopaque, StartRequest) BackendError!void,
    join_fn: ?*const fn (?*anyopaque, u64) BackendError!u64 = null,
    detach_fn: ?*const fn (?*anyopaque, u64) BackendError!void = null,
    yield_fn: ?*const fn (?*anyopaque) void = null,
    sleep_fn: ?*const fn (?*anyopaque, u64) BackendError!void = null,
    wait_fn: ?*const fn (?*anyopaque, WaitRequest) BackendError!WaitResult = null,
    wake_fn: ?*const fn (?*anyopaque, u64, u64, usize) void = null,
    call_fn: ?*const fn (?*anyopaque, GuestCall) BackendError!u64 = null,
    raise_exception_fn: ?*const fn (?*anyopaque, u64, u64, i32) BackendError!void = null,
    request_exit_fn: ?*const fn (?*anyopaque, u64, u64) void = null,

    fn start(self: Backend, request: StartRequest) BackendError!void {
        return self.start_fn(self.context, request);
    }
};

pub const Attr = struct {
    magic: u64 = attr_magic,
    stack_address: u64 = 0,
    stack_size: u64 = default_stack_size,
    guard_size: u64 = default_guard_size,
    affinity_mask: u64 = default_affinity_mask,
    priority: i32 = default_priority,
    policy: i32 = default_policy,
    inherit_sched: i32 = default_inherit_sched,
    solo_sched: i32 = 0,
    detached: bool = false,
};

pub const SchedParam = extern struct {
    sched_priority: i32,
};

pub const Scheduling = struct {
    policy: i32,
    priority: i32,
    affinity_mask: u64,
};

pub const ThreadHandle = ?*anyopaque;
pub const AttrHandle = ?*Attr;

const ThreadState = enum(u8) {
    prepared,
    running,
    finished,
};

const ThreadBlock = struct {
    address_space: *memory.AddressSpace,
    context: ThreadContext,

    fn init(
        gpa: std.mem.Allocator,
        address_space: *memory.AddressSpace,
        registry: *loader.TlsRegistry,
        thread_handle: u64,
    ) Error!ThreadBlock {
        var snapshot = try registry.snapshot(gpa);
        defer snapshot.deinit(gpa);

        const tls_alignment = @max(@as(u64, 16), snapshot.maximum_alignment);
        const prefix_required = @max(minimum_tls_prefix, snapshot.static_size);
        const tls_prefix_size = try alignForward(prefix_required, tls_alignment);
        const dtv_slots = std.math.add(u64, dtv_header_slots, snapshot.maximum_module_id) catch
            return error.AddressOverflow;
        const dtv_size = std.math.mul(u64, dtv_slots, @sizeOf(u64)) catch
            return error.AddressOverflow;
        const upper_size = std.math.add(u64, tcb_size, dtv_size) catch
            return error.AddressOverflow;
        const total_unaligned = std.math.add(u64, tls_prefix_size, upper_size) catch
            return error.AddressOverflow;
        const mapping_size = try alignForward(total_unaligned, memory.page_size);
        const mapping_alignment = @max(memory.page_size, tls_alignment);

        const mapping_address = try address_space.map(
            .user,
            0,
            mapping_size,
            mapping_alignment,
            .read_write,
            .private,
            null,
        );
        errdefer address_space.unmap(mapping_address, mapping_size) catch {};

        const fs_base = std.math.add(u64, mapping_address, tls_prefix_size) catch
            return error.AddressOverflow;
        const dtv_address = std.math.add(u64, fs_base, tcb_size) catch
            return error.AddressOverflow;

        // FreeBSD/AMD64 TCB fields used by guest runtimes and stack protectors.
        try address_space.writeInt(u64, fs_base + 0x00, fs_base);
        try address_space.writeInt(u64, fs_base + 0x08, dtv_address);
        try address_space.writeInt(u64, fs_base + 0x10, thread_handle);
        try address_space.writeInt(u64, fs_base + 0x28, stack_canary);
        try address_space.writeInt(u64, fs_base + 0x60, fs_base);
        try address_space.writeInt(i32, fs_base + errno_tcb_offset, 0);
        try address_space.writeInt(u64, dtv_address + 0x00, snapshot.generation);
        try address_space.writeInt(u64, dtv_address + 0x08, snapshot.maximum_module_id);

        for (snapshot.modules) |snapshot_module| {
            if (snapshot_module.info.static_offset > tls_prefix_size) return error.AddressOverflow;
            const module_address = fs_base - snapshot_module.info.static_offset;
            if (snapshot_module.initial_image.len != 0) {
                try address_space.write(module_address, snapshot_module.initial_image);
            }
            const slot = std.math.add(u64, dtv_header_slots, snapshot_module.info.id - 1) catch
                return error.AddressOverflow;
            const slot_offset = std.math.mul(u64, slot, @sizeOf(u64)) catch
                return error.AddressOverflow;
            try address_space.writeInt(u64, dtv_address + slot_offset, module_address);
        }

        return .{
            .address_space = address_space,
            .context = .{
                .tls_mapping_address = mapping_address,
                .tls_mapping_size = mapping_size,
                .fs_base = fs_base,
                .dtv_address = dtv_address,
                .tls_generation = snapshot.generation,
            },
        };
    }

    fn deinit(self: *ThreadBlock) void {
        self.address_space.unmap(
            self.context.tls_mapping_address,
            self.context.tls_mapping_size,
        ) catch {};
        self.* = undefined;
    }
};

const ThreadRecord = struct {
    block: ?ThreadBlock = null,
    stack_mapping_address: u64 = 0,
    stack_mapping_size: u64 = 0,
    attributes: Attr,
    entry_point: u64,
    argument: u64,
    name: [32]u8,
    external: bool,
    joining: bool = false,
    specific_values: [maximum_keys]u64 = [_]u64{0} ** maximum_keys,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(ThreadState.prepared)),
    result: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const PreparedThread = struct {
    handle: ThreadHandle,
    context: ThreadContext,
    stack_address: u64,
    stack_size: u64,
    guard_size: u64,
};

pub const LiveThreadInfo = struct {
    entry_point: u64 = 0,
    name: [32]u8 = @splat(0),
};

const KeyRecord = struct {
    allocated: bool = false,
    destructor: u64 = 0,
};

pub const Error = error{
    AddressOverflow,
    NotAttached,
    ExecutorUnavailable,
    InvalidArgument,
    ThreadNotFound,
    ThreadDetached,
    WouldDeadlock,
    KeyUnavailable,
} || memory.Error || loader.tls.Error || std.mem.Allocator.Error || BackendError;

pub const Manager = struct {
    allocator: std.mem.Allocator = undefined,
    address_space: *memory.AddressSpace = undefined,
    tls_registry: *loader.TlsRegistry = undefined,
    backend: ?Backend = null,
    threads: std.ArrayList(*ThreadRecord) = .empty,
    attributes: std.ArrayList(*Attr) = .empty,
    keys: [maximum_keys]KeyRecord = [_]KeyRecord{.{}} ** maximum_keys,
    lock: Lock = .{},
    initialized: bool = false,

    pub fn init(
        self: *Manager,
        allocator: std.mem.Allocator,
        address_space: *memory.AddressSpace,
        tls_registry: *loader.TlsRegistry,
    ) void {
        self.* = .{
            .allocator = allocator,
            .address_space = address_space,
            .tls_registry = tls_registry,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Manager) void {
        if (!self.initialized) return;
        self.lock.lock();
        for (self.threads.items) |record| {
            self.releaseGuestStack(record);
            if (record.block) |*block| block.deinit();
            self.allocator.destroy(record);
        }
        for (self.attributes.items) |attr| self.allocator.destroy(attr);
        self.threads.deinit(self.allocator);
        self.attributes.deinit(self.allocator);
        self.lock.unlock();
        self.* = .{};
    }

    pub fn setBackend(self: *Manager, backend: ?Backend) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.backend = backend;
    }

    pub fn hasBackend(self: *Manager) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.backend != null;
    }

    /// Number of child pthreads that have not completed yet. The externally
    /// owned process-entry record is excluded: some PS5 CRTs return from that
    /// bootstrap after handing the actual game loop to a child pthread.
    pub fn liveChildCount(self: *Manager) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var count: usize = 0;
        for (self.threads.items) |record| {
            if (record.external) continue;
            if (record.state.load(.acquire) != @intFromEnum(ThreadState.finished)) count += 1;
        }
        return count;
    }

    pub fn liveChildren(self: *Manager, output: []LiveThreadInfo) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var count: usize = 0;
        for (self.threads.items) |record| {
            if (record.external or
                record.state.load(.acquire) == @intFromEnum(ThreadState.finished)) continue;
            if (count < output.len) output[count] = .{
                .entry_point = record.entry_point,
                .name = record.name,
            };
            count += 1;
        }
        return count;
    }

    /// Creates TLS for a process-entry thread already owned by the executor.
    /// The executor must call `enter` before dispatch and `leave` afterwards.
    pub fn prepareInitialThread(self: *Manager, name: []const u8) Error!PreparedThread {
        const record = try self.allocateRecord(.{}, 0, 0, name, true);
        record.state.store(@intFromEnum(ThreadState.running), .release);
        return .{
            .handle = @ptrCast(record),
            .context = record.block.?.context,
            .stack_address = record.attributes.stack_address,
            .stack_size = record.attributes.stack_size,
            .guard_size = record.attributes.guard_size,
        };
    }

    pub fn releaseInitialThread(self: *Manager, handle: ThreadHandle) Error!void {
        const address = handleAddress(handle) orelse return error.InvalidArgument;
        self.lock.lock();
        const record = self.findRecordLocked(address) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        if (!record.external) {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        _ = self.removeRecordLocked(address);
        self.lock.unlock();
        self.destroyRecord(record);
    }

    /// Sets the guest pthread identity for the current host worker. FS itself is
    /// installed by the execution backend using `PreparedThread.context` or a
    /// child `StartRequest.context`.
    pub fn enter(self: *Manager, handle: ThreadHandle) Error!void {
        const address = handleAddress(handle) orelse return error.InvalidArgument;
        self.lock.lock();
        const found = self.findRecordLocked(address) != null;
        self.lock.unlock();
        if (!found) return error.ThreadNotFound;
        current_guest_thread = address;
    }

    pub fn leave(_: *Manager) void {
        current_guest_thread = 0;
    }

    pub fn current(_: *Manager) ThreadHandle {
        return if (current_guest_thread == 0) null else @ptrFromInt(current_guest_thread);
    }

    pub fn currentName(self: *Manager) [32]u8 {
        if (current_guest_thread == 0) return @splat(0);
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(current_guest_thread) orelse return @splat(0);
        return record.name;
    }

    /// Returns the immutable execution context for the current host worker's
    /// guest thread. The record remains owned by the manager; callers receive
    /// a value copy so no manager lock crosses an HLE call boundary.
    pub fn currentContext(self: *Manager) ?ThreadContext {
        if (current_guest_thread == 0) return null;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(current_guest_thread) orelse return null;
        const block = record.block orelse return null;
        return block.context;
    }

    /// Resolves the `{module, offset}` pair consumed by `__tls_get_addr`
    /// against the DTV constructed for the active guest thread.
    pub fn resolveCurrentTls(self: *Manager, module_id: u64, offset: u64) ?u64 {
        if (module_id == 0) return null;
        const module_info = self.tls_registry.findModule(module_id) orelse return null;
        if (offset >= module_info.memory_size) return null;
        const context = self.currentContext() orelse return null;
        const slot_index = std.math.add(u64, dtv_header_slots, module_id - 1) catch return null;
        const slot_offset = std.math.mul(u64, slot_index, @sizeOf(u64)) catch return null;
        const slot_address = std.math.add(u64, context.dtv_address, slot_offset) catch return null;
        var encoded: [@sizeOf(u64)]u8 = undefined;
        self.address_space.read(slot_address, &encoded) catch return null;
        const module_address = std.mem.readInt(u64, &encoded, .little);
        if (module_address == 0) return null;
        return std.math.add(u64, module_address, offset) catch null;
    }

    pub fn currentErrnoAddress(self: *Manager) ?u64 {
        const context = self.currentContext() orelse return null;
        return std.math.add(u64, context.fs_base, errno_tcb_offset) catch null;
    }

    pub fn readScheduling(self: *Manager, handle: ThreadHandle) ?Scheduling {
        const address = handleAddress(handle) orelse return null;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(address) orelse return null;
        return .{
            .policy = record.attributes.policy,
            .priority = record.attributes.priority,
            .affinity_mask = record.attributes.affinity_mask,
        };
    }

    pub fn setAffinity(self: *Manager, handle: ThreadHandle, mask: u64) bool {
        const address = handleAddress(handle) orelse return false;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(address) orelse return false;
        record.attributes.affinity_mask = mask;
        return true;
    }

    pub fn readAffinity(self: *Manager, handle: ThreadHandle) ?u64 {
        const address = handleAddress(handle) orelse return null;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(address) orelse return null;
        return record.attributes.affinity_mask;
    }

    /// Renames a live thread.
    ///
    /// The name is a label a title attaches for its own diagnostics, and it
    /// asks for it back through the same interface, so it is stored rather than
    /// discarded. Longer names are truncated to the field the record keeps,
    /// which is what the interface itself does.
    pub fn setName(self: *Manager, handle: ThreadHandle, name: []const u8) bool {
        const address = handleAddress(handle) orelse return false;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(address) orelse return false;
        record.name = @splat(0);
        const kept = @min(name.len, record.name.len - 1);
        @memcpy(record.name[0..kept], name[0..kept]);
        return true;
    }

    pub fn setPriority(self: *Manager, handle: ThreadHandle, priority: i32) bool {
        const address = handleAddress(handle) orelse return false;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(address) orelse return false;
        record.attributes.priority = priority;
        return true;
    }

    pub fn setScheduling(
        self: *Manager,
        handle: ThreadHandle,
        policy: i32,
        priority: i32,
    ) bool {
        const address = handleAddress(handle) orelse return false;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(address) orelse return false;
        record.attributes.policy = policy;
        record.attributes.priority = priority;
        return true;
    }

    pub fn create(
        self: *Manager,
        out_thread: *ThreadHandle,
        attributes: Attr,
        entry_point: u64,
        argument: u64,
        name: []const u8,
    ) Error!void {
        if (entry_point == 0) return error.InvalidArgument;
        const backend = self.backend orelse return error.ExecutorUnavailable;
        const record = try self.allocateRecord(attributes, entry_point, argument, name, false);
        errdefer {
            _ = self.removeRecord(@intFromPtr(record));
            self.destroyRecord(record);
        }

        const request = StartRequest{
            .thread_handle = @intFromPtr(record),
            .entry_point = entry_point,
            .argument = argument,
            .context = record.block.?.context,
            .stack_address = record.attributes.stack_address,
            .stack_size = record.attributes.stack_size,
            .guard_size = record.attributes.guard_size,
            .priority = attributes.priority,
            .affinity_mask = attributes.affinity_mask,
            .detached = attributes.detached,
            .name = record.name,
        };
        // Publish the running state before handing control to the backend. A
        // deterministic/test backend may execute and complete the thread
        // synchronously inside `start`.
        record.state.store(@intFromEnum(ThreadState.running), .release);
        try backend.start(request);
        out_thread.* = @ptrCast(record);
    }

    /// Called by an executor only after it has stopped executing with the
    /// thread's guest FS base.
    pub fn complete(self: *Manager, handle: ThreadHandle, result: u64) Error!void {
        const address = handleAddress(handle) orelse return error.InvalidArgument;
        self.lock.lock();
        const record = self.findRecordLocked(address) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        record.result.store(result, .release);
        record.state.store(@intFromEnum(ThreadState.finished), .release);
        const reap = record.attributes.detached and !record.external;
        if (reap) _ = self.removeRecordLocked(address);
        self.lock.unlock();
        if (reap) self.destroyRecord(record);
    }

    pub fn join(self: *Manager, handle: ThreadHandle) Error!u64 {
        const address = handleAddress(handle) orelse return error.InvalidArgument;
        if (current_guest_thread == address) return error.WouldDeadlock;

        self.lock.lock();
        const record = self.findRecordLocked(address) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        if (record.attributes.detached or record.external) {
            self.lock.unlock();
            return error.ThreadDetached;
        }
        if (record.joining) {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        record.joining = true;
        const backend = self.backend;
        self.lock.unlock();

        const result = (if (backend) |active_backend| blk: {
            if (active_backend.join_fn) |join_fn| {
                break :blk join_fn(active_backend.context, address);
            }
            break :blk self.waitForCompletion(record);
        } else self.waitForCompletion(record)) catch |err| {
            self.lock.lock();
            record.joining = false;
            self.lock.unlock();
            return err;
        };

        const removed = self.removeRecord(address) orelse return error.ThreadNotFound;
        self.destroyRecord(removed);
        return result;
    }

    pub fn detach(self: *Manager, handle: ThreadHandle) Error!void {
        const address = handleAddress(handle) orelse return error.InvalidArgument;
        self.lock.lock();
        const record = self.findRecordLocked(address) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        if (record.attributes.detached or record.external) {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        if (record.joining) {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        const backend = self.backend;
        self.lock.unlock();

        if (backend) |active_backend| {
            if (active_backend.detach_fn) |detach_fn| try detach_fn(active_backend.context, address);
        }

        self.lock.lock();
        record.attributes.detached = true;
        const reap = record.state.load(.acquire) == @intFromEnum(ThreadState.finished);
        if (reap) _ = self.removeRecordLocked(address);
        self.lock.unlock();
        if (reap) self.destroyRecord(record);
    }

    pub fn requestExit(self: *Manager, result: u64) void {
        const handle = current_guest_thread;
        if (handle == 0) return;
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        if (backend) |active_backend| {
            if (active_backend.request_exit_fn) |exit_fn| {
                exit_fn(active_backend.context, handle, result);
            }
        }
    }

    pub fn yield(self: *Manager) void {
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        if (backend) |active_backend| {
            if (active_backend.yield_fn) |yield_fn| {
                yield_fn(active_backend.context);
                return;
            }
        }
        std.Thread.yield() catch {};
    }

    pub fn sleep(self: *Manager, microseconds: u64) Error!void {
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        if (backend) |active_backend| {
            if (active_backend.sleep_fn) |sleep_fn| {
                return sleep_fn(active_backend.context, microseconds);
            }
        }
        if (microseconds == 0) {
            self.yield();
            return;
        }
        return error.ExecutorUnavailable;
    }

    /// Parks or yields the current guest thread until the object sequence
    /// changes. A CPU scheduler supplies a real wait; the fallback yields one
    /// host quantum so native concurrency tests can make progress.
    pub fn wait(self: *Manager, request: WaitRequest) Error!WaitResult {
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        if (backend) |active_backend| {
            if (active_backend.wait_fn) |wait_fn| {
                return wait_fn(active_backend.context, request);
            }
        }
        if (request.timeout_microseconds != null or request.absolute_deadline_ns != null) {
            return .timed_out;
        }
        self.yield();
        return .awoken;
    }

    /// Publishes a new object sequence and wakes up to `maximum_waiters`
    /// scheduler-owned guest contexts waiting on the same key.
    pub fn wake(self: *Manager, key: u64, sequence: u64, maximum_waiters: usize) void {
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        if (backend) |active_backend| {
            if (active_backend.wake_fn) |wake_fn| {
                wake_fn(active_backend.context, key, sequence, maximum_waiters);
            }
        }
    }

    pub fn callGuestResult(self: *Manager, entry_point: u64, arguments: []const u64) Error!u64 {
        if (arguments.len > 6) return error.InvalidArgument;
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        const active_backend = backend orelse return error.ExecutorUnavailable;
        const call_fn = active_backend.call_fn orelse return error.ExecutorUnavailable;
        var request = GuestCall{
            .entry_point = entry_point,
            .thread_handle = current_guest_thread,
            .argument_count = @intCast(arguments.len),
        };
        @memcpy(request.arguments[0..arguments.len], arguments);
        return call_fn(active_backend.context, request);
    }

    pub fn callGuest(self: *Manager, entry_point: u64, arguments: []const u64) Error!void {
        _ = try self.callGuestResult(entry_point, arguments);
    }

    /// Schedules a process exception callback on the target guest pthread.
    /// The execution backend owns delivery because only it can preserve the
    /// target's TLS, stack and native-thread identity.
    pub fn raiseGuestException(
        self: *Manager,
        target_thread: u64,
        handler: u64,
        exception_type: i32,
    ) Error!void {
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        const active_backend = backend orelse return error.ExecutorUnavailable;
        const raise_fn = active_backend.raise_exception_fn orelse return error.ExecutorUnavailable;
        return raise_fn(active_backend.context, target_thread, handler, exception_type);
    }

    pub fn keyCreate(self: *Manager, out_key: *u32, destructor: u64) Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.keys, 0..) |*key, index| {
            if (key.allocated) continue;
            key.* = .{ .allocated = true, .destructor = destructor };
            out_key.* = @intCast(index);
            return;
        }
        return error.KeyUnavailable;
    }

    pub fn keyDelete(self: *Manager, key: u32) Error!void {
        if (key >= maximum_keys) return error.InvalidArgument;
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.keys[key].allocated) return error.InvalidArgument;
        self.keys[key] = .{};
        for (self.threads.items) |record| record.specific_values[key] = 0;
    }

    pub fn setSpecific(self: *Manager, key: u32, value: u64) Error!void {
        if (key >= maximum_keys or current_guest_thread == 0) return error.InvalidArgument;
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.keys[key].allocated) return error.InvalidArgument;
        const record = self.findRecordLocked(current_guest_thread) orelse
            return error.ThreadNotFound;
        record.specific_values[key] = value;
    }

    pub fn getSpecific(self: *Manager, key: u32) u64 {
        if (key >= maximum_keys or current_guest_thread == 0) return 0;
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.keys[key].allocated) return 0;
        const record = self.findRecordLocked(current_guest_thread) orelse return 0;
        return record.specific_values[key];
    }

    /// Runs POSIX TLS-key destructors in the still-live guest execution
    /// context. Values are cleared before each callback so a destructor may set
    /// them again for the next of four standard passes.
    pub fn runSpecificDestructors(self: *Manager) Error!void {
        if (current_guest_thread == 0) return;
        var callbacks: [maximum_keys]struct { entry: u64, value: u64 } = undefined;

        for (0..destructor_iterations) |_| {
            var callback_count: usize = 0;
            self.lock.lock();
            const record = self.findRecordLocked(current_guest_thread) orelse {
                self.lock.unlock();
                return error.ThreadNotFound;
            };
            for (self.keys, 0..) |key, index| {
                const value = record.specific_values[index];
                if (!key.allocated or key.destructor == 0 or value == 0) continue;
                record.specific_values[index] = 0;
                callbacks[callback_count] = .{ .entry = key.destructor, .value = value };
                callback_count += 1;
            }
            self.lock.unlock();

            if (callback_count == 0) return;
            for (callbacks[0..callback_count]) |callback| {
                try self.callGuest(callback.entry, &.{callback.value});
            }
        }
    }

    fn allocateRecord(
        self: *Manager,
        attributes: Attr,
        entry_point: u64,
        argument: u64,
        name: []const u8,
        external: bool,
    ) Error!*ThreadRecord {
        const record = try self.allocator.create(ThreadRecord);
        record.* = .{
            .attributes = attributes,
            .entry_point = entry_point,
            .argument = argument,
            .name = copyName(name),
            .external = external,
        };
        errdefer self.allocator.destroy(record);
        record.block = try ThreadBlock.init(
            self.allocator,
            self.address_space,
            self.tls_registry,
            @intFromPtr(record),
        );
        errdefer record.block.?.deinit();
        try self.allocateGuestStack(record);
        errdefer self.releaseGuestStack(record);
        try self.appendRecord(record);
        return record;
    }

    fn allocateGuestStack(self: *Manager, record: *ThreadRecord) Error!void {
        // A caller-provided stack is guest-owned. The manager neither remaps
        // nor releases it, but validates that its complete range exists.
        if (record.attributes.stack_address != 0) {
            if (!isWritableGuestRange(
                self.address_space,
                record.attributes.stack_address,
                record.attributes.stack_size,
            )) return error.InvalidArgument;
            return;
        }

        const mapped_stack_size = try alignForward(record.attributes.stack_size, memory.page_size);
        const mapped_guard_size = if (record.attributes.guard_size == 0)
            0
        else
            try alignForward(record.attributes.guard_size, memory.page_size);
        const mapping_size = std.math.add(u64, mapped_guard_size, mapped_stack_size) catch
            return error.AddressOverflow;
        const mapping_address = try self.address_space.map(
            .user,
            0,
            mapping_size,
            memory.page_size,
            .none,
            .stack,
            null,
        );
        errdefer self.address_space.unmap(mapping_address, mapping_size) catch {};
        try self.address_space.protect(
            mapping_address + mapped_guard_size,
            mapped_stack_size,
            .read_write,
        );

        record.stack_mapping_address = mapping_address;
        record.stack_mapping_size = mapping_size;
        record.attributes.stack_address = mapping_address + mapped_guard_size;
        // Report the effective guard because the native address space can only
        // protect complete guest pages.
        record.attributes.guard_size = mapped_guard_size;
    }

    fn releaseGuestStack(self: *Manager, record: *ThreadRecord) void {
        if (record.stack_mapping_size == 0) return;
        self.address_space.unmap(
            record.stack_mapping_address,
            record.stack_mapping_size,
        ) catch {};
        record.stack_mapping_address = 0;
        record.stack_mapping_size = 0;
    }

    fn appendRecord(self: *Manager, record: *ThreadRecord) std.mem.Allocator.Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.threads.append(self.allocator, record);
    }

    fn removeRecord(self: *Manager, address: u64) ?*ThreadRecord {
        self.lock.lock();
        defer self.lock.unlock();
        return self.removeRecordLocked(address);
    }

    fn removeRecordLocked(self: *Manager, address: u64) ?*ThreadRecord {
        for (self.threads.items, 0..) |record, index| {
            if (@intFromPtr(record) == address) return self.threads.orderedRemove(index);
        }
        return null;
    }

    fn findRecordLocked(self: *Manager, address: u64) ?*ThreadRecord {
        for (self.threads.items) |record| {
            if (@intFromPtr(record) == address) return record;
        }
        return null;
    }

    fn destroyRecord(self: *Manager, record: *ThreadRecord) void {
        self.releaseGuestStack(record);
        if (record.block) |*block| block.deinit();
        self.allocator.destroy(record);
    }

    fn waitForCompletion(_: *Manager, record: *ThreadRecord) Error!u64 {
        while (record.state.load(.acquire) != @intFromEnum(ThreadState.finished)) {
            std.Thread.yield() catch {};
        }
        return record.result.load(.acquire);
    }

    fn createAttr(self: *Manager) Error!*Attr {
        const attr = try self.allocator.create(Attr);
        attr.* = .{};
        errdefer self.allocator.destroy(attr);
        self.lock.lock();
        defer self.lock.unlock();
        try self.attributes.append(self.allocator, attr);
        return attr;
    }

    fn readAttr(self: *Manager, handle: AttrHandle) ?Attr {
        const attr = handle orelse return null;
        self.lock.lock();
        defer self.lock.unlock();
        for (self.attributes.items) |known| {
            if (known == attr and known.magic == attr_magic) return known.*;
        }
        return null;
    }

    fn readThreadAttr(self: *Manager, handle: ThreadHandle) ?Attr {
        const address = handleAddress(handle) orelse return null;
        self.lock.lock();
        defer self.lock.unlock();
        const record = self.findRecordLocked(address) orelse return null;
        return record.attributes;
    }

    fn updateAttr(self: *Manager, handle: AttrHandle, value: Attr) bool {
        const attr = handle orelse return false;
        self.lock.lock();
        defer self.lock.unlock();
        for (self.attributes.items) |known| {
            if (known != attr or known.magic != attr_magic) continue;
            known.* = value;
            return true;
        }
        return false;
    }

    fn destroyAttr(self: *Manager, handle: AttrHandle) bool {
        const attr = handle orelse return false;
        self.lock.lock();
        for (self.attributes.items, 0..) |known, index| {
            if (known != attr or known.magic != attr_magic) continue;
            _ = self.attributes.orderedRemove(index);
            known.magic = 0;
            self.lock.unlock();
            self.allocator.destroy(known);
            return true;
        }
        self.lock.unlock();
        return false;
    }
};

threadlocal var current_guest_thread: u64 = 0;

const WaitDiagnostic = struct {
    key: u64 = 0,
    sequence: u64 = 0,
    repeats: u32 = 0,

    fn observe(self: *WaitDiagnostic, manager: *Manager, request: WaitRequest) void {
        if (self.key == request.key and self.sequence == request.observed_sequence) {
            self.repeats +|= 1;
        } else {
            self.* = .{ .key = request.key, .sequence = request.observed_sequence, .repeats = 1 };
        }
        if (self.repeats != 100_000) return;
        const name_storage = manager.currentName();
        const name = std.mem.sliceTo(&name_storage, 0);
        std.debug.print(
            "[cpu wait] repeated key=0x{x} sequence={d} thread=0x{x}/{s} relative_us={?d} deadline_ns={?d} clock={d}\n",
            .{
                request.key,
                request.observed_sequence,
                current_guest_thread,
                name,
                request.timeout_microseconds,
                request.absolute_deadline_ns,
                request.clock_id,
            },
        );
    }
};

threadlocal var wait_diagnostic: WaitDiagnostic = .{};
var attached_manager: ?*Manager = null;
var attach_lock: Lock = .{};

pub fn attachManager(new_manager: ?*Manager) void {
    attach_lock.lock();
    defer attach_lock.unlock();
    attached_manager = new_manager;
    if (new_manager == null) current_guest_thread = 0;
}

fn activeManager() ?*Manager {
    attach_lock.lock();
    defer attach_lock.unlock();
    return attached_manager;
}

/// Name of the guest thread currently executing on this host worker.
/// Diagnostics in sibling HLE subsystems use the value copy without retaining
/// a thread-manager record or lock.
pub fn currentThreadName() [32]u8 {
    const manager = activeManager() orelse return @splat(0);
    return manager.currentName();
}

/// Guest pthread identity used by synchronization objects for ownership.
pub fn currentThreadId() u64 {
    return current_guest_thread;
}

/// Scheduling priority used by priority-ordered kernel wait queues.
pub fn currentThreadPriority() i32 {
    const manager = activeManager() orelse return default_priority;
    const scheduling = manager.readScheduling(manager.current()) orelse return default_priority;
    return scheduling.priority;
}

pub fn resolveCurrentTls(module_id: u64, offset: u64) ?u64 {
    const active_manager = activeManager() orelse return null;
    return active_manager.resolveCurrentTls(module_id, offset);
}

pub fn currentErrnoAddress() ?u64 {
    const active_manager = activeManager() orelse return null;
    return active_manager.currentErrnoAddress();
}

pub fn waitCurrent(request: WaitRequest) Error!WaitResult {
    const active_manager = activeManager() orelse return error.NotAttached;
    wait_diagnostic.observe(active_manager, request);
    return active_manager.wait(request);
}

pub fn wakeWaiters(key: u64, sequence: u64, maximum_waiters: usize) void {
    const active_manager = activeManager() orelse return;
    active_manager.wake(key, sequence, maximum_waiters);
}

/// Executes a callback on the current guest thread and returns its RAX value.
/// Runtime allocator hooks use this to call back into the genuine libc while
/// preserving that thread's guest TLS and execution context.
pub fn callGuestCurrent(entry_point: u64, arguments: []const u64) Error!u64 {
    const active_manager = activeManager() orelse return error.NotAttached;
    return active_manager.callGuestResult(entry_point, arguments);
}

pub fn raiseGuestException(target_thread: u64, handler: u64, exception_type: i32) Error!void {
    const active_manager = activeManager() orelse return error.NotAttached;
    return active_manager.raiseGuestException(target_thread, handler, exception_type);
}

fn alignForward(value: u64, alignment: u64) Error!u64 {
    const mask = alignment - 1;
    const upper = std.math.add(u64, value, mask) catch return error.AddressOverflow;
    return upper & ~mask;
}

fn isWritableGuestRange(address_space: *memory.AddressSpace, address: u64, size: u64) bool {
    const end = std.math.add(u64, address, size) catch return false;
    var cursor = address;
    while (cursor < end) {
        const mapping = address_space.query(cursor, false) orelse return false;
        if (mapping.address > cursor or !mapping.protection.write) return false;
        cursor = @min(end, mapping.end());
    }
    return true;
}

fn handleAddress(handle: ThreadHandle) ?u64 {
    const pointer = handle orelse return null;
    return @intFromPtr(pointer);
}

fn copyName(source: []const u8) [32]u8 {
    var destination = [_]u8{0} ** 32;
    const length = @min(source.len, destination.len - 1);
    @memcpy(destination[0..length], source[0..length]);
    return destination;
}

fn cName(source: ?[*:0]const u8) []const u8 {
    const pointer = source orelse return "";
    return std.mem.sliceTo(pointer[0..32], 0);
}

fn kernelStatus(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => KernelError.enomem.raw(),
        error.ThreadNotFound => KernelError.esrch.raw(),
        error.WouldDeadlock => KernelError.edeadlk.raw(),
        error.ExecutorUnavailable, error.Unsupported => KernelError.enosys.raw(),
        error.StartFailed, error.KeyUnavailable => KernelError.eagain.raw(),
        error.JoinFailed, error.WaitFailed, error.CallFailed => KernelError.eio.raw(),
        else => KernelError.einval.raw(),
    };
}

fn posixStatus(status: i32) i32 {
    return if (status == errno.ok) errno.ok else errno.kernelToPosix(status);
}

fn selectedAttr(attr: ?*const AttrHandle) Attr {
    const active_manager = activeManager() orelse return .{};
    const outer = attr orelse return .{};
    return active_manager.readAttr(outer.*) orelse .{};
}

pub fn scePthreadCreate(
    out_thread: ?*ThreadHandle,
    attr: ?*const AttrHandle,
    entry: ?*const anyopaque,
    argument: ?*anyopaque,
    name: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const output = out_thread orelse return KernelError.einval.raw();
    const entry_point = if (entry) |pointer| @intFromPtr(pointer) else 0;
    const argument_value = if (argument) |pointer| @intFromPtr(pointer) else 0;
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    const attributes = selectedAttr(attr);
    active_manager.create(
        output,
        attributes,
        entry_point,
        argument_value,
        cName(name),
    ) catch |err| {
        std.debug.print(
            "[pthread] create failed: {s} entry=0x{x} stack=0x{x}+0x{x} guard=0x{x} name={s}\n",
            .{
                @errorName(err),
                entry_point,
                attributes.stack_address,
                attributes.stack_size,
                attributes.guard_size,
                cName(name),
            },
        );
        return kernelStatus(err);
    };
    return errno.ok;
}

pub fn pthread_create(
    out_thread: ?*ThreadHandle,
    attr: ?*const AttrHandle,
    entry: ?*const anyopaque,
    argument: ?*anyopaque,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCreate(out_thread, attr, entry, argument, null));
}

pub fn pthread_create_name_np(
    out_thread: ?*ThreadHandle,
    attr: ?*const AttrHandle,
    entry: ?*const anyopaque,
    argument: ?*anyopaque,
    name: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCreate(out_thread, attr, entry, argument, name));
}

pub fn scePthreadJoin(handle: ThreadHandle, result: ?*ThreadHandle) callconv(abi.guest) i32 {
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    const value = active_manager.join(handle) catch |err| return kernelStatus(err);
    if (result) |output| output.* = if (value == 0) null else @ptrFromInt(value);
    return errno.ok;
}

pub fn pthread_join(handle: ThreadHandle, result: ?*ThreadHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadJoin(handle, result));
}

pub fn scePthreadDetach(handle: ThreadHandle) callconv(abi.guest) i32 {
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    active_manager.detach(handle) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_detach(handle: ThreadHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadDetach(handle));
}

pub fn scePthreadSelf() callconv(abi.guest) ThreadHandle {
    const active_manager = activeManager() orelse return null;
    return active_manager.current();
}

pub fn pthread_self() callconv(abi.guest) ThreadHandle {
    return scePthreadSelf();
}

pub fn scePthreadEqual(first: ThreadHandle, second: ThreadHandle) callconv(abi.guest) i32 {
    return @intFromBool(handleAddress(first) == handleAddress(second));
}

pub fn pthread_equal(first: ThreadHandle, second: ThreadHandle) callconv(abi.guest) i32 {
    return scePthreadEqual(first, second);
}

pub fn scePthreadExit(result: ThreadHandle) callconv(abi.guest) void {
    const active_manager = activeManager() orelse return;
    active_manager.runSpecificDestructors() catch {};
    active_manager.requestExit(handleAddress(result) orelse 0);
}

pub fn pthread_exit(result: ThreadHandle) callconv(abi.guest) void {
    scePthreadExit(result);
}

pub fn scePthreadYield() callconv(abi.guest) void {
    const active_manager = activeManager() orelse return;
    active_manager.yield();
}

pub fn pthread_yield() callconv(abi.guest) void {
    scePthreadYield();
}

pub fn sceKernelUsleep(microseconds: u32) callconv(abi.guest) i32 {
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    active_manager.sleep(microseconds) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn scePthreadSetaffinity(handle: ThreadHandle, mask: u64) callconv(abi.guest) i32 {
    const manager = activeManager() orelse return KernelError.enosys.raw();
    return if (manager.setAffinity(handle, mask)) errno.ok else KernelError.esrch.raw();
}

pub fn scePthreadSetprio(handle: ThreadHandle, priority: i32) callconv(abi.guest) i32 {
    const manager = activeManager() orelse return KernelError.enosys.raw();
    return if (manager.setPriority(handle, priority)) errno.ok else KernelError.esrch.raw();
}

pub fn scePthreadGetschedparam(
    handle: ThreadHandle,
    out_policy: ?*i32,
    out_parameter: ?*SchedParam,
) callconv(abi.guest) i32 {
    const policy = out_policy orelse return KernelError.einval.raw();
    const parameter = out_parameter orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    const scheduling = manager.readScheduling(handle) orelse return KernelError.esrch.raw();
    policy.* = scheduling.policy;
    parameter.* = .{ .sched_priority = scheduling.priority };
    return errno.ok;
}

pub fn scePthreadSetschedparam(
    handle: ThreadHandle,
    policy: i32,
    parameter: ?*const SchedParam,
) callconv(abi.guest) i32 {
    const requested = parameter orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    return if (manager.setScheduling(handle, policy, requested.sched_priority))
        errno.ok
    else
        KernelError.esrch.raw();
}

pub fn pthread_getschedparam(
    handle: ThreadHandle,
    out_policy: ?*i32,
    out_parameter: ?*SchedParam,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadGetschedparam(handle, out_policy, out_parameter));
}

pub fn pthread_setschedparam(
    handle: ThreadHandle,
    policy: i32,
    parameter: ?*const SchedParam,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadSetschedparam(handle, policy, parameter));
}

pub fn scePthreadRename(handle: ThreadHandle, name: ?[*:0]const u8) callconv(abi.guest) i32 {
    const text = name orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    return if (manager.setName(handle, std.mem.span(text)))
        errno.ok
    else
        KernelError.esrch.raw();
}

pub fn pthread_rename_np(handle: ThreadHandle, name: ?[*:0]const u8) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRename(handle, name));
}

/// The identifier the operating system knows a thread by.
///
/// Distinct from the pthread handle: a title uses this where it wants a number
/// to print or compare, not something to call the thread through. Truncated to
/// the width the entry point returns, which is what a caller reads.
pub fn scePthreadGetthreadid() callconv(abi.guest) i32 {
    return @truncate(@as(i64, @bitCast(currentThreadId())));
}

/// Reads a thread's processor affinity.
pub fn scePthreadGetaffinity(handle: ThreadHandle, output: ?*u64) callconv(abi.guest) i32 {
    const out = output orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    const mask = manager.readAffinity(handle) orelse return KernelError.esrch.raw();
    out.* = mask;
    return errno.ok;
}

pub fn pthread_attr_setsolosched_np(attr: ?*AttrHandle, solo_sched: i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetsolosched(attr, solo_sched));
}

/// Cancellation, refused rather than answered.
///
/// Cancelling a thread means unwinding it at a point it did not choose, and
/// nothing here can do that: the thread is a host thread running guest code,
/// and stopping it between two instructions would leave whatever it held
/// locked. Reporting that it cannot be done is better than reporting success
/// and leaving the thread running, which is what a title would then assume had
/// stopped.
pub fn pthread_cancel(_: ThreadHandle) callconv(abi.guest) i32 {
    return errno.Posix.enosys;
}

/// The console's thread priority range, in which a smaller number is higher.
///
/// Reported so that a title asking the range and then choosing inside it picks
/// something this layer accepts; nothing here refuses a priority, so the range
/// only has to be the one the platform documents.
pub const highest_priority: i32 = 256;
pub const lowest_priority: i32 = 767;

pub fn sched_get_priority_max(_: i32) callconv(abi.guest) i32 {
    return highest_priority;
}

pub fn sched_get_priority_min(_: i32) callconv(abi.guest) i32 {
    return lowest_priority;
}

pub fn scePthreadAttrInit(out_attr: ?*AttrHandle) callconv(abi.guest) i32 {
    const output = out_attr orelse return KernelError.einval.raw();
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    output.* = active_manager.createAttr() catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_attr_init(out_attr: ?*AttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrInit(out_attr));
}

pub fn scePthreadAttrDestroy(attr: ?*AttrHandle) callconv(abi.guest) i32 {
    const outer = attr orelse return KernelError.einval.raw();
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    if (!active_manager.destroyAttr(outer.*)) return KernelError.einval.raw();
    outer.* = null;
    return errno.ok;
}

pub fn pthread_attr_destroy(attr: ?*AttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrDestroy(attr));
}

pub fn scePthreadAttrGet(handle: ThreadHandle, attr: ?*AttrHandle) callconv(abi.guest) i32 {
    const outer = attr orelse return KernelError.einval.raw();
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    const value = active_manager.readThreadAttr(handle) orelse return KernelError.esrch.raw();
    if (!active_manager.updateAttr(outer.*, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_get_np(handle: ThreadHandle, attr: ?*AttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrGet(handle, attr));
}

fn getAttr(attr: ?*const AttrHandle) ?Attr {
    const outer = attr orelse return null;
    const active_manager = activeManager() orelse return null;
    return active_manager.readAttr(outer.*);
}

fn putAttr(attr: ?*AttrHandle, value: Attr) bool {
    const outer = attr orelse return false;
    const active_manager = activeManager() orelse return false;
    return active_manager.updateAttr(outer.*, value);
}

pub fn scePthreadAttrGetstack(
    attr: ?*const AttrHandle,
    stack_address: ?*ThreadHandle,
    stack_size: ?*u64,
) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const address_output = stack_address orelse return KernelError.einval.raw();
    const size_output = stack_size orelse return KernelError.einval.raw();
    address_output.* = if (value.stack_address == 0) null else @ptrFromInt(value.stack_address);
    size_output.* = value.stack_size;
    return errno.ok;
}

pub fn pthread_attr_getstack(
    attr: ?*const AttrHandle,
    stack_address: ?*ThreadHandle,
    stack_size: ?*u64,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrGetstack(attr, stack_address, stack_size));
}

pub fn scePthreadAttrGetstacksize(attr: ?*const AttrHandle, output: ?*u64) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const size_output = output orelse return KernelError.einval.raw();
    size_output.* = value.stack_size;
    return errno.ok;
}

pub fn pthread_attr_getstacksize(attr: ?*const AttrHandle, output: ?*u64) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrGetstacksize(attr, output));
}

pub fn scePthreadAttrSetstack(attr: ?*AttrHandle, address: ThreadHandle, size: u64) callconv(abi.guest) i32 {
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    const stack_address = handleAddress(address) orelse return KernelError.einval.raw();
    if (size < minimum_stack_size) return KernelError.einval.raw();
    value.stack_address = stack_address;
    value.stack_size = size;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_setstack(attr: ?*AttrHandle, address: ThreadHandle, size: u64) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetstack(attr, address, size));
}

pub fn scePthreadAttrGetstackaddr(
    attr: ?*const AttrHandle,
    output: ?*ThreadHandle,
) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const address_output = output orelse return KernelError.einval.raw();
    address_output.* = if (value.stack_address == 0) null else @ptrFromInt(value.stack_address);
    return errno.ok;
}

pub fn scePthreadAttrSetstackaddr(attr: ?*AttrHandle, address: ThreadHandle) callconv(abi.guest) i32 {
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.stack_address = handleAddress(address) orelse return KernelError.einval.raw();
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn scePthreadAttrSetstacksize(attr: ?*AttrHandle, size: u64) callconv(abi.guest) i32 {
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    if (size < minimum_stack_size) return KernelError.einval.raw();
    value.stack_size = size;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_setstacksize(attr: ?*AttrHandle, size: u64) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetstacksize(attr, size));
}

pub fn scePthreadAttrGetdetachstate(attr: ?*const AttrHandle, output: ?*i32) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const state_output = output orelse return KernelError.einval.raw();
    state_output.* = @intFromBool(value.detached);
    return errno.ok;
}

pub fn pthread_attr_getdetachstate(attr: ?*const AttrHandle, output: ?*i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrGetdetachstate(attr, output));
}

pub fn scePthreadAttrSetdetachstate(attr: ?*AttrHandle, state: i32) callconv(abi.guest) i32 {
    if (state != 0 and state != 1) return KernelError.einval.raw();
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.detached = state == 1;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_setdetachstate(attr: ?*AttrHandle, state: i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetdetachstate(attr, state));
}

pub fn scePthreadAttrGetguardsize(attr: ?*const AttrHandle, output: ?*u64) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const size_output = output orelse return KernelError.einval.raw();
    size_output.* = value.guard_size;
    return errno.ok;
}

pub fn pthread_attr_getguardsize(attr: ?*const AttrHandle, output: ?*u64) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrGetguardsize(attr, output));
}

pub fn scePthreadAttrSetguardsize(attr: ?*AttrHandle, size: u64) callconv(abi.guest) i32 {
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.guard_size = size;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_setguardsize(attr: ?*AttrHandle, size: u64) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetguardsize(attr, size));
}

pub fn scePthreadAttrGetaffinity(attr: ?*const AttrHandle, output: ?*u64) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const mask_output = output orelse return KernelError.einval.raw();
    mask_output.* = value.affinity_mask;
    return errno.ok;
}

pub fn scePthreadAttrSetaffinity(attr: ?*AttrHandle, mask: u64) callconv(abi.guest) i32 {
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.affinity_mask = mask;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn scePthreadAttrSetinheritsched(attr: ?*AttrHandle, inherit_sched: i32) callconv(abi.guest) i32 {
    if (inherit_sched != 0 and inherit_sched != 4) return KernelError.einval.raw();
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.inherit_sched = inherit_sched;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_setinheritsched(attr: ?*AttrHandle, inherit_sched: i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetinheritsched(attr, inherit_sched));
}

pub fn scePthreadAttrGetschedparam(
    attr: ?*const AttrHandle,
    output: ?*SchedParam,
) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const parameter_output = output orelse return KernelError.einval.raw();
    parameter_output.* = .{ .sched_priority = value.priority };
    return errno.ok;
}

pub fn pthread_attr_getschedparam(
    attr: ?*const AttrHandle,
    output: ?*SchedParam,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrGetschedparam(attr, output));
}

pub fn scePthreadAttrSetschedparam(
    attr: ?*AttrHandle,
    parameter: ?*const SchedParam,
) callconv(abi.guest) i32 {
    const requested = parameter orelse return KernelError.einval.raw();
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.priority = requested.sched_priority;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_setschedparam(
    attr: ?*AttrHandle,
    parameter: ?*const SchedParam,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetschedparam(attr, parameter));
}

pub fn pthread_attr_getschedpolicy(attr: ?*const AttrHandle, output: ?*i32) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return Posix.einval;
    const policy_output = output orelse return Posix.einval;
    policy_output.* = value.policy;
    return errno.ok;
}

pub fn scePthreadAttrSetschedpolicy(attr: ?*AttrHandle, policy: i32) callconv(abi.guest) i32 {
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.policy = policy;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_attr_setschedpolicy(attr: ?*AttrHandle, policy: i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadAttrSetschedpolicy(attr, policy));
}

pub fn scePthreadKeyCreate(out_key: ?*u32, destructor: ?*const anyopaque) callconv(abi.guest) i32 {
    const output = out_key orelse return KernelError.einval.raw();
    const destructor_address = if (destructor) |pointer| @intFromPtr(pointer) else 0;
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    active_manager.keyCreate(output, destructor_address) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_key_create(out_key: ?*u32, destructor: ?*const anyopaque) callconv(abi.guest) i32 {
    return posixStatus(scePthreadKeyCreate(out_key, destructor));
}

pub fn scePthreadKeyDelete(key: u32) callconv(abi.guest) i32 {
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    active_manager.keyDelete(key) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_key_delete(key: u32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadKeyDelete(key));
}

pub fn scePthreadSetspecific(key: u32, value: ThreadHandle) callconv(abi.guest) i32 {
    const active_manager = activeManager() orelse return KernelError.enosys.raw();
    active_manager.setSpecific(key, handleAddress(value) orelse 0) catch |err|
        return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_setspecific(key: u32, value: ThreadHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadSetspecific(key, value));
}

pub fn scePthreadGetspecific(key: u32) callconv(abi.guest) ThreadHandle {
    const active_manager = activeManager() orelse return null;
    const value = active_manager.getSpecific(key);
    return if (value == 0) null else @ptrFromInt(value);
}

pub fn pthread_getspecific(key: u32) callconv(abi.guest) ThreadHandle {
    return scePthreadGetspecific(key);
}

pub fn scePthreadAttrGetsolosched(attr: ?*const AttrHandle, output: ?*i32) callconv(abi.guest) i32 {
    const value = getAttr(attr) orelse return KernelError.einval.raw();
    const solo_output = output orelse return KernelError.einval.raw();
    solo_output.* = value.solo_sched;
    return errno.ok;
}

pub fn scePthreadAttrSetsolosched(attr: ?*AttrHandle, solo_sched: i32) callconv(abi.guest) i32 {
    var value = getAttr(attr) orelse return KernelError.einval.raw();
    value.solo_sched = solo_sched;
    if (!putAttr(attr, value)) return KernelError.einval.raw();
    return errno.ok;
}

pub fn pthread_once(once_control: ?*u32, init_routine: ?*const anyopaque) callconv(abi.guest) i32 {
    const once = once_control orelse return Posix.einval;
    const entry = if (init_routine) |pointer| @intFromPtr(pointer) else return Posix.einval;

    while (true) {
        switch (@atomicLoad(u32, once, .acquire)) {
            0 => {
                if (@cmpxchgStrong(u32, once, 0, 2, .acq_rel, .acquire) != null) continue;
                const active_manager = activeManager() orelse {
                    @atomicStore(u32, once, 0, .release);
                    return Posix.enosys;
                };
                active_manager.callGuest(entry, &.{}) catch |err| {
                    @atomicStore(u32, once, 0, .release);
                    return posixStatus(kernelStatus(err));
                };
                @atomicStore(u32, once, 1, .release);
                return errno.ok;
            },
            1 => return errno.ok,
            2, 3 => {
                _ = @cmpxchgStrong(u32, once, 2, 3, .acq_rel, .acquire);
                if (activeManager()) |active_manager| active_manager.yield() else std.atomic.spinLoopHint();
            },
            else => return Posix.einval,
        }
    }
}

pub fn scePthreadOnce(once_control: ?*u32, init_routine: ?*const anyopaque) callconv(abi.guest) i32 {
    return pthread_once(once_control, init_routine);
}

pub const exports = [_]symbols.Export{
    .{ .name = "scePthreadCreate", .function = trace.wrap("scePthreadCreate", &scePthreadCreate), .expect_id = "6UgtwV+0zb4" },
    .{ .name = "pthread_create", .function = trace.wrap("pthread_create", &pthread_create), .expect_id = "OxhIB8LB-PQ" },
    .{ .name = "pthread_create_name_np", .function = trace.wrap("pthread_create_name_np", &pthread_create_name_np), .expect_id = "Jmi+9w9u0E4" },
    .{ .name = "scePthreadJoin", .function = trace.wrap("scePthreadJoin", &scePthreadJoin), .expect_id = "onNY9Byn-W8" },
    .{ .name = "pthread_join", .function = trace.wrap("pthread_join", &pthread_join), .expect_id = "h9CcP3J0oVM" },
    .{ .name = "scePthreadDetach", .function = trace.wrap("scePthreadDetach", &scePthreadDetach), .expect_id = "4qGrR6eoP9Y" },
    .{ .name = "pthread_detach", .function = trace.wrap("pthread_detach", &pthread_detach), .expect_id = "+U1R4WtXvoc" },
    .{ .name = "scePthreadSelf", .function = trace.wrap("scePthreadSelf", &scePthreadSelf), .expect_id = "aI+OeCz8xrQ" },
    .{ .name = "pthread_self", .function = trace.wrap("pthread_self", &pthread_self), .expect_id = "EotR8a3ASf4" },
    .{ .name = "scePthreadEqual", .function = trace.wrap("scePthreadEqual", &scePthreadEqual), .expect_id = "3PtV6p3QNX4" },
    .{ .name = "pthread_equal", .function = trace.wrap("pthread_equal", &pthread_equal), .expect_id = "7Xl257M4VNI" },
    .{ .name = "scePthreadExit", .function = trace.wrap("scePthreadExit", &scePthreadExit), .expect_id = "3kg7rT0NQIs" },
    .{ .name = "pthread_exit", .function = trace.wrap("pthread_exit", &pthread_exit), .expect_id = "FJrT5LuUBAU" },
    .{ .name = "scePthreadYield", .function = trace.wrap("scePthreadYield", &scePthreadYield), .expect_id = "T72hz6ffq08" },
    .{ .name = "pthread_yield", .function = trace.wrap("pthread_yield", &pthread_yield), .expect_id = "B5GmVDKwpn0" },
    .{ .name = "scePthreadSetaffinity", .function = trace.wrap("scePthreadSetaffinity", &scePthreadSetaffinity), .expect_id = "bt3CTBKmGyI" },
    .{ .name = "scePthreadSetprio", .function = trace.wrap("scePthreadSetprio", &scePthreadSetprio), .expect_id = "W0Hpm2X0uPE" },
    .{ .name = "scePthreadGetschedparam", .function = trace.wrap("scePthreadGetschedparam", &scePthreadGetschedparam), .expect_id = "P41kTWUS3EI" },
    .{ .name = "scePthreadSetschedparam", .function = trace.wrap("scePthreadSetschedparam", &scePthreadSetschedparam), .expect_id = "oIRFTjoILbg" },
    .{ .name = "pthread_getschedparam", .function = trace.wrap("pthread_getschedparam", &pthread_getschedparam), .expect_id = "FIs3-UQT9sg" },
    .{ .name = "pthread_setschedparam", .function = trace.wrap("pthread_setschedparam", &pthread_setschedparam), .expect_id = "Xs9hdiD7sAA" },
    .{ .name = "scePthreadGetaffinity", .function = trace.wrap("scePthreadGetaffinity", &scePthreadGetaffinity), .expect_id = "rcrVFJsQWRY" },
    .{ .name = "scePthreadGetthreadid", .function = trace.wrap("scePthreadGetthreadid", &scePthreadGetthreadid), .expect_id = "EI-5-jlq2dE" },
    .{ .name = "scePthreadRename", .function = trace.wrap("scePthreadRename", &scePthreadRename), .expect_id = "GBUY7ywdULE" },
    .{ .name = "pthread_rename_np", .function = trace.wrap("pthread_rename_np", &pthread_rename_np), .expect_id = "9vyP6Z7bqzc" },
    .{ .name = "pthread_attr_setsolosched_np", .function = trace.wrap("pthread_attr_setsolosched_np", &pthread_attr_setsolosched_np), .expect_id = "2+pVfgiEd7A" },
    .{ .name = "pthread_cancel", .function = trace.wrap("pthread_cancel", &pthread_cancel), .expect_id = "0D4-FVvEikw" },
    .{ .name = "sched_get_priority_max", .function = trace.wrap("sched_get_priority_max", &sched_get_priority_max), .expect_id = "CBNtXOoef-E" },
    .{ .name = "sched_get_priority_min", .function = trace.wrap("sched_get_priority_min", &sched_get_priority_min), .expect_id = "m0iS6jNsXds" },
    .{ .name = "sceKernelUsleep", .function = trace.wrap("sceKernelUsleep", &sceKernelUsleep), .expect_id = "1jfXLRVzisc" },
    .{ .name = "scePthreadAttrInit", .function = trace.wrap("scePthreadAttrInit", &scePthreadAttrInit), .expect_id = "nsYoNRywwNg" },
    .{ .name = "pthread_attr_init", .function = trace.wrap("pthread_attr_init", &pthread_attr_init), .expect_id = "wtkt-teR1so" },
    .{ .name = "scePthreadAttrDestroy", .function = trace.wrap("scePthreadAttrDestroy", &scePthreadAttrDestroy), .expect_id = "62KCwEMmzcM" },
    .{ .name = "pthread_attr_destroy", .function = trace.wrap("pthread_attr_destroy", &pthread_attr_destroy), .expect_id = "zHchY8ft5pk" },
    .{ .name = "scePthreadAttrGet", .function = trace.wrap("scePthreadAttrGet", &scePthreadAttrGet), .expect_id = "x1X76arYMxU" },
    .{ .name = "pthread_attr_get_np", .function = trace.wrap("pthread_attr_get_np", &pthread_attr_get_np), .expect_id = "Ucsu-OK+els" },
    .{ .name = "scePthreadAttrGetstack", .function = trace.wrap("scePthreadAttrGetstack", &scePthreadAttrGetstack), .expect_id = "-quPa4SEJUw" },
    .{ .name = "pthread_attr_getstack", .function = trace.wrap("pthread_attr_getstack", &pthread_attr_getstack), .expect_id = "vQm4fDEsWi8" },
    .{ .name = "scePthreadAttrGetstacksize", .function = trace.wrap("scePthreadAttrGetstacksize", &scePthreadAttrGetstacksize), .expect_id = "-fA+7ZlGDQs" },
    .{ .name = "pthread_attr_getstacksize", .function = trace.wrap("pthread_attr_getstacksize", &pthread_attr_getstacksize), .expect_id = "0qOtCR-ZHck" },
    .{ .name = "scePthreadAttrSetstack", .function = trace.wrap("scePthreadAttrSetstack", &scePthreadAttrSetstack), .expect_id = "Bvn74vj6oLo" },
    .{ .name = "pthread_attr_setstack", .function = trace.wrap("pthread_attr_setstack", &pthread_attr_setstack) },
    .{ .name = "scePthreadAttrGetstackaddr", .function = trace.wrap("scePthreadAttrGetstackaddr", &scePthreadAttrGetstackaddr), .expect_id = "Ru36fiTtJzA" },
    .{ .name = "scePthreadAttrSetstackaddr", .function = trace.wrap("scePthreadAttrSetstackaddr", &scePthreadAttrSetstackaddr), .expect_id = "F+yfmduIBB8" },
    .{ .name = "scePthreadAttrSetstacksize", .function = trace.wrap("scePthreadAttrSetstacksize", &scePthreadAttrSetstacksize), .expect_id = "UTXzJbWhhTE" },
    .{ .name = "pthread_attr_setstacksize", .function = trace.wrap("pthread_attr_setstacksize", &pthread_attr_setstacksize), .expect_id = "2Q0z6rnBrTE" },
    .{ .name = "scePthreadAttrGetdetachstate", .function = trace.wrap("scePthreadAttrGetdetachstate", &scePthreadAttrGetdetachstate), .expect_id = "JaRMy+QcpeU" },
    .{ .name = "pthread_attr_getdetachstate", .function = trace.wrap("pthread_attr_getdetachstate", &pthread_attr_getdetachstate), .expect_id = "VUT1ZSrHT0I" },
    .{ .name = "scePthreadAttrSetdetachstate", .function = trace.wrap("scePthreadAttrSetdetachstate", &scePthreadAttrSetdetachstate), .expect_id = "-Wreprtu0Qs" },
    .{ .name = "pthread_attr_setdetachstate", .function = trace.wrap("pthread_attr_setdetachstate", &pthread_attr_setdetachstate), .expect_id = "E+tyo3lp5Lw" },
    .{ .name = "scePthreadAttrGetguardsize", .function = trace.wrap("scePthreadAttrGetguardsize", &scePthreadAttrGetguardsize), .expect_id = "txHtngJ+eyc" },
    .{ .name = "pthread_attr_getguardsize", .function = trace.wrap("pthread_attr_getguardsize", &pthread_attr_getguardsize), .expect_id = "JNkVVsVDmOk" },
    .{ .name = "scePthreadAttrSetguardsize", .function = trace.wrap("scePthreadAttrSetguardsize", &scePthreadAttrSetguardsize), .expect_id = "El+cQ20DynU" },
    .{ .name = "pthread_attr_setguardsize", .function = trace.wrap("pthread_attr_setguardsize", &pthread_attr_setguardsize), .expect_id = "JKyG3SWyA10" },
    .{ .name = "scePthreadAttrGetaffinity", .function = trace.wrap("scePthreadAttrGetaffinity", &scePthreadAttrGetaffinity), .expect_id = "8+s5BzZjxSg" },
    .{ .name = "scePthreadAttrSetaffinity", .function = trace.wrap("scePthreadAttrSetaffinity", &scePthreadAttrSetaffinity), .expect_id = "3qxgM4ezETA" },
    .{ .name = "scePthreadAttrSetinheritsched", .function = trace.wrap("scePthreadAttrSetinheritsched", &scePthreadAttrSetinheritsched), .expect_id = "eXbUSpEaTsA" },
    .{ .name = "pthread_attr_setinheritsched", .function = trace.wrap("pthread_attr_setinheritsched", &pthread_attr_setinheritsched), .expect_id = "7ZlAakEf0Qg" },
    .{ .name = "scePthreadAttrGetschedparam", .function = trace.wrap("scePthreadAttrGetschedparam", &scePthreadAttrGetschedparam), .expect_id = "FXPWHNk8Of0" },
    .{ .name = "pthread_attr_getschedparam", .function = trace.wrap("pthread_attr_getschedparam", &pthread_attr_getschedparam), .expect_id = "qlk9pSLsUmM" },
    .{ .name = "scePthreadAttrSetschedparam", .function = trace.wrap("scePthreadAttrSetschedparam", &scePthreadAttrSetschedparam), .expect_id = "DzES9hQF4f4" },
    .{ .name = "pthread_attr_setschedparam", .function = trace.wrap("pthread_attr_setschedparam", &pthread_attr_setschedparam), .expect_id = "euKRgm0Vn2M" },
    .{ .name = "pthread_attr_getschedpolicy", .function = trace.wrap("pthread_attr_getschedpolicy", &pthread_attr_getschedpolicy), .expect_id = "RtLRV-pBTTY" },
    .{ .name = "scePthreadAttrSetschedpolicy", .function = trace.wrap("scePthreadAttrSetschedpolicy", &scePthreadAttrSetschedpolicy), .expect_id = "4+h9EzwKF4I" },
    .{ .name = "pthread_attr_setschedpolicy", .function = trace.wrap("pthread_attr_setschedpolicy", &pthread_attr_setschedpolicy), .expect_id = "JarMIy8kKEY" },
    .{ .name = "scePthreadAttrGetsolosched", .function = trace.wrap("scePthreadAttrGetsolosched", &scePthreadAttrGetsolosched), .expect_id = "9RnL-m0+diQ" },
    .{ .name = "scePthreadAttrSetsolosched", .function = trace.wrap("scePthreadAttrSetsolosched", &scePthreadAttrSetsolosched), .expect_id = "Dk6FC-TI+7Q" },
    .{ .name = "scePthreadKeyCreate", .function = trace.wrap("scePthreadKeyCreate", &scePthreadKeyCreate), .expect_id = "geDaqgH9lTg" },
    .{ .name = "pthread_key_create", .function = trace.wrap("pthread_key_create", &pthread_key_create), .expect_id = "mqULNdimTn0" },
    .{ .name = "scePthreadKeyDelete", .function = trace.wrap("scePthreadKeyDelete", &scePthreadKeyDelete), .expect_id = "PrdHuuDekhY" },
    .{ .name = "pthread_key_delete", .function = trace.wrap("pthread_key_delete", &pthread_key_delete), .expect_id = "6BpEZuDT7YI" },
    .{ .name = "scePthreadSetspecific", .function = trace.wrap("scePthreadSetspecific", &scePthreadSetspecific), .expect_id = "+BzXYkqYeLE" },
    .{ .name = "pthread_setspecific", .function = trace.wrap("pthread_setspecific", &pthread_setspecific), .expect_id = "WrOLvHU0yQM" },
    .{ .name = "scePthreadGetspecific", .function = trace.wrap("scePthreadGetspecific", &scePthreadGetspecific), .expect_id = "eoht7mQOCmo" },
    .{ .name = "pthread_getspecific", .function = trace.wrap("pthread_getspecific", &pthread_getspecific), .expect_id = "0-KXaS70xy4" },
    .{ .name = "scePthreadOnce", .function = trace.wrap("scePthreadOnce", &scePthreadOnce), .expect_id = "14bOACANTBo" },
    .{ .name = "pthread_once", .function = trace.wrap("pthread_once", &pthread_once), .expect_id = "Z4QosVuAsA0" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const TestBackend = struct {
    manager: *Manager,
    last_request: ?StartRequest = null,
    once_calls: usize = 0,
    last_call: ?GuestCall = null,

    fn start(raw: ?*anyopaque, request: StartRequest) BackendError!void {
        const self: *TestBackend = @ptrCast(@alignCast(raw.?));
        self.last_request = request;
        self.manager.complete(@ptrFromInt(request.thread_handle), request.argument) catch
            return error.StartFailed;
    }

    fn join(raw: ?*anyopaque, handle: u64) BackendError!u64 {
        const self: *TestBackend = @ptrCast(@alignCast(raw.?));
        self.manager.lock.lock();
        defer self.manager.lock.unlock();
        const record = self.manager.findRecordLocked(handle) orelse return error.ThreadNotFound;
        return record.result.load(.acquire);
    }

    fn call(raw: ?*anyopaque, request: GuestCall) BackendError!u64 {
        const self: *TestBackend = @ptrCast(@alignCast(raw.?));
        self.once_calls += 1;
        self.last_call = request;
        return request.entry_point;
    }

    fn value(self: *TestBackend) Backend {
        return .{
            .context = self,
            .start_fn = start,
            .join_fn = join,
            .call_fn = call,
        };
    }
};

fn testManager(
    address_space: *memory.AddressSpace,
    registry: *loader.TlsRegistry,
) Manager {
    var result = Manager{};
    result.init(testing.allocator, address_space, registry);
    return result;
}

fn readGuestU64(address_space: *memory.AddressSpace, address: u64) memory.Error!u64 {
    var bytes: [@sizeOf(u64)]u8 = undefined;
    try address_space.read(address, &bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

test "thread block seeds Variant II modules and a FreeBSD-style DTV" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var registry = loader.TlsRegistry{};
    defer registry.deinit(testing.allocator);
    const first = try registry.register(testing.allocator, .{
        .initial_image = &.{ 0x11, 0x22, 0x33 },
        .memory_size = 0x20,
        .alignment = 0x10,
    });
    const second = try registry.register(testing.allocator, .{
        .initial_image = &.{0x7a},
        .memory_size = 0x18,
        .alignment = 0x20,
        .alignment_bias = 8,
    });

    var thread_manager = testManager(&address_space, &registry);
    defer thread_manager.deinit();
    const prepared = try thread_manager.prepareInitialThread("MainThread");
    defer thread_manager.releaseInitialThread(prepared.handle) catch {};

    const self_pointer = try readGuestU64(&address_space, prepared.context.fs_base);
    const dtv_pointer = try readGuestU64(&address_space, prepared.context.fs_base + 8);
    const first_dtv = try readGuestU64(&address_space, prepared.context.dtv_address + 16);
    const second_dtv = try readGuestU64(&address_space, prepared.context.dtv_address + 24);
    try testing.expectEqual(prepared.context.fs_base, self_pointer);
    try testing.expectEqual(prepared.context.dtv_address, dtv_pointer);
    try testing.expectEqual(prepared.context.fs_base - first.static_offset, first_dtv);
    try testing.expectEqual(prepared.context.fs_base - second.static_offset, second_dtv);

    var initial: [3]u8 = undefined;
    try address_space.read(first_dtv, &initial);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33 }, &initial);
    var tbss: [4]u8 = undefined;
    try address_space.read(first_dtv + initial.len, &tbss);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &tbss);
}

test "backend receives FS context and join reaps a completed thread" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var registry = loader.TlsRegistry{};
    defer registry.deinit(testing.allocator);
    _ = try registry.register(testing.allocator, .{
        .initial_image = &.{0xaa},
        .memory_size = 0x20,
        .alignment = 0x10,
    });
    var thread_manager = testManager(&address_space, &registry);
    defer thread_manager.deinit();
    var backend = TestBackend{ .manager = &thread_manager };
    thread_manager.setBackend(backend.value());

    var handle: ThreadHandle = null;
    try thread_manager.create(&handle, .{}, 0x1234, 0x55, "worker");
    const request = backend.last_request orelse return error.TestExpectedStartRequest;
    try testing.expect(request.context.fs_base != 0);
    try testing.expectEqual(@as(u64, 0x55), try thread_manager.join(handle));
    try testing.expectError(error.ThreadNotFound, thread_manager.join(handle));
}

test "attributes and once expose POSIX-compatible state" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var registry = loader.TlsRegistry{};
    defer registry.deinit(testing.allocator);
    var thread_manager = testManager(&address_space, &registry);
    defer thread_manager.deinit();
    var backend = TestBackend{ .manager = &thread_manager };
    thread_manager.setBackend(backend.value());
    attachManager(&thread_manager);
    defer attachManager(null);

    var attr: AttrHandle = null;
    try testing.expectEqual(errno.ok, pthread_attr_init(&attr));
    try testing.expectEqual(errno.ok, pthread_attr_setstacksize(&attr, 0x20_000));
    var stack_size: u64 = 0;
    try testing.expectEqual(errno.ok, pthread_attr_getstacksize(&attr, &stack_size));
    try testing.expectEqual(@as(u64, 0x20_000), stack_size);

    var once: u32 = 0;
    try testing.expectEqual(errno.ok, pthread_once(&once, @ptrFromInt(0x1234)));
    try testing.expectEqual(errno.ok, pthread_once(&once, @ptrFromInt(0x1234)));
    try testing.expectEqual(@as(usize, 1), backend.once_calls);

    const callback_result = try callGuestCurrent(0x4567, &.{ 1, 2, 3 });
    try testing.expectEqual(@as(u64, 0x4567), callback_result);
    try testing.expectEqual(@as(u8, 3), backend.last_call.?.argument_count);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, backend.last_call.?.arguments[0..3]);
    try testing.expectEqual(errno.ok, pthread_attr_destroy(&attr));
    try testing.expect(attr == null);
}

test "live thread scheduling metadata can be queried and updated" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var registry = loader.TlsRegistry{};
    defer registry.deinit(testing.allocator);
    var thread_manager = testManager(&address_space, &registry);
    defer thread_manager.deinit();
    attachManager(&thread_manager);
    defer attachManager(null);

    const prepared = try thread_manager.prepareInitialThread("MainThread");
    defer thread_manager.releaseInitialThread(prepared.handle) catch {};
    try testing.expectEqual(errno.ok, scePthreadSetaffinity(prepared.handle, 0x3));
    try testing.expectEqual(errno.ok, scePthreadSetprio(prepared.handle, 512));
    const requested = SchedParam{ .sched_priority = 600 };
    try testing.expectEqual(errno.ok, scePthreadSetschedparam(prepared.handle, 2, &requested));

    var policy: i32 = 0;
    var current = SchedParam{ .sched_priority = 0 };
    try testing.expectEqual(errno.ok, scePthreadGetschedparam(prepared.handle, &policy, &current));
    try testing.expectEqual(@as(i32, 2), policy);
    try testing.expectEqual(@as(i32, 600), current.sched_priority);
    try testing.expectEqual(@as(u64, 0x3), thread_manager.readScheduling(prepared.handle).?.affinity_mask);
}

test "TLS keys are per-thread and run guest destructors" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var registry = loader.TlsRegistry{};
    defer registry.deinit(testing.allocator);
    var thread_manager = testManager(&address_space, &registry);
    defer thread_manager.deinit();
    var backend = TestBackend{ .manager = &thread_manager };
    thread_manager.setBackend(backend.value());
    attachManager(&thread_manager);
    defer attachManager(null);

    const prepared = try thread_manager.prepareInitialThread("MainThread");
    defer thread_manager.releaseInitialThread(prepared.handle) catch {};
    try thread_manager.enter(prepared.handle);
    defer thread_manager.leave();

    var key: u32 = undefined;
    try testing.expectEqual(errno.ok, pthread_key_create(&key, @ptrFromInt(0x1234)));
    try testing.expectEqual(errno.ok, pthread_setspecific(key, @ptrFromInt(0xbeef)));
    try testing.expectEqual(@as(usize, 0xbeef), @intFromPtr(pthread_getspecific(key).?));
    try thread_manager.runSpecificDestructors();
    const call = backend.last_call orelse return error.TestExpectedGuestCall;
    try testing.expectEqual(@as(u64, 0x1234), call.entry_point);
    try testing.expectEqual(@as(u8, 1), call.argument_count);
    try testing.expectEqual(@as(u64, 0xbeef), call.arguments[0]);
    try testing.expect(pthread_getspecific(key) == null);
    try testing.expectEqual(errno.ok, pthread_key_delete(key));
}

test "threading library registers the sample executable imports" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findById("6UgtwV+0zb4", .function) != null);
    try testing.expect(db.findById("1jfXLRVzisc", .function) != null);
}
