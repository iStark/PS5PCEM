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
//! is executing guest instructions, or patch segment-relative accesses as the
//! reference emulators do.

const std = @import("std");
const memory = @import("memory");
const loader = @import("loader");
const abi = @import("../abi.zig");
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
const stack_canary: u64 = 0xc0de_c0de_cafe_ba00;
const attr_magic: u64 = 0x5054_4852_4154_5452;

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
    call_fn: ?*const fn (?*anyopaque, u64, u64) BackendError!void = null,
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
    attributes: Attr,
    entry_point: u64,
    argument: u64,
    name: [32]u8,
    external: bool,
    joining: bool = false,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(ThreadState.prepared)),
    result: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const PreparedThread = struct {
    handle: ThreadHandle,
    context: ThreadContext,
};

pub const Error = error{
    AddressOverflow,
    NotAttached,
    ExecutorUnavailable,
    InvalidArgument,
    ThreadNotFound,
    ThreadDetached,
    WouldDeadlock,
} || memory.Error || loader.tls.Error || std.mem.Allocator.Error || BackendError;

pub const Manager = struct {
    allocator: std.mem.Allocator = undefined,
    address_space: *memory.AddressSpace = undefined,
    tls_registry: *loader.TlsRegistry = undefined,
    backend: ?Backend = null,
    threads: std.ArrayList(*ThreadRecord) = .empty,
    attributes: std.ArrayList(*Attr) = .empty,
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

    /// Creates TLS for a process-entry thread already owned by the executor.
    /// The executor must call `enter` before dispatch and `leave` afterwards.
    pub fn prepareInitialThread(self: *Manager, name: []const u8) Error!PreparedThread {
        const record = try self.allocateRecord(.{}, 0, 0, name, true);
        record.state.store(@intFromEnum(ThreadState.running), .release);
        return .{
            .handle = @ptrCast(record),
            .context = record.block.?.context,
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
            .stack_address = attributes.stack_address,
            .stack_size = attributes.stack_size,
            .guard_size = attributes.guard_size,
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

    pub fn callGuest(self: *Manager, entry_point: u64) Error!void {
        self.lock.lock();
        const backend = self.backend;
        self.lock.unlock();
        const active_backend = backend orelse return error.ExecutorUnavailable;
        const call_fn = active_backend.call_fn orelse return error.ExecutorUnavailable;
        return call_fn(active_backend.context, entry_point, current_guest_thread);
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
        try self.appendRecord(record);
        return record;
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

fn alignForward(value: u64, alignment: u64) Error!u64 {
    const mask = alignment - 1;
    const upper = std.math.add(u64, value, mask) catch return error.AddressOverflow;
    return upper & ~mask;
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
        error.StartFailed => KernelError.eagain.raw(),
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
    active_manager.create(
        output,
        selectedAttr(attr),
        entry_point,
        argument_value,
        cName(name),
    ) catch |err| return kernelStatus(err);
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
                active_manager.callGuest(entry) catch |err| {
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
    .{ .name = "scePthreadCreate", .function = abi.erase(&scePthreadCreate), .expect_id = "6UgtwV+0zb4" },
    .{ .name = "pthread_create", .function = abi.erase(&pthread_create), .expect_id = "OxhIB8LB-PQ" },
    .{ .name = "pthread_create_name_np", .function = abi.erase(&pthread_create_name_np), .expect_id = "Jmi+9w9u0E4" },
    .{ .name = "scePthreadJoin", .function = abi.erase(&scePthreadJoin), .expect_id = "onNY9Byn-W8" },
    .{ .name = "pthread_join", .function = abi.erase(&pthread_join), .expect_id = "h9CcP3J0oVM" },
    .{ .name = "scePthreadDetach", .function = abi.erase(&scePthreadDetach), .expect_id = "4qGrR6eoP9Y" },
    .{ .name = "pthread_detach", .function = abi.erase(&pthread_detach), .expect_id = "+U1R4WtXvoc" },
    .{ .name = "scePthreadSelf", .function = abi.erase(&scePthreadSelf), .expect_id = "aI+OeCz8xrQ" },
    .{ .name = "pthread_self", .function = abi.erase(&pthread_self), .expect_id = "EotR8a3ASf4" },
    .{ .name = "scePthreadEqual", .function = abi.erase(&scePthreadEqual), .expect_id = "3PtV6p3QNX4" },
    .{ .name = "pthread_equal", .function = abi.erase(&pthread_equal), .expect_id = "7Xl257M4VNI" },
    .{ .name = "scePthreadExit", .function = abi.erase(&scePthreadExit), .expect_id = "3kg7rT0NQIs" },
    .{ .name = "pthread_exit", .function = abi.erase(&pthread_exit), .expect_id = "FJrT5LuUBAU" },
    .{ .name = "scePthreadYield", .function = abi.erase(&scePthreadYield), .expect_id = "T72hz6ffq08" },
    .{ .name = "pthread_yield", .function = abi.erase(&pthread_yield), .expect_id = "B5GmVDKwpn0" },
    .{ .name = "sceKernelUsleep", .function = abi.erase(&sceKernelUsleep), .expect_id = "1jfXLRVzisc" },
    .{ .name = "scePthreadAttrInit", .function = abi.erase(&scePthreadAttrInit), .expect_id = "nsYoNRywwNg" },
    .{ .name = "pthread_attr_init", .function = abi.erase(&pthread_attr_init), .expect_id = "wtkt-teR1so" },
    .{ .name = "scePthreadAttrDestroy", .function = abi.erase(&scePthreadAttrDestroy), .expect_id = "62KCwEMmzcM" },
    .{ .name = "pthread_attr_destroy", .function = abi.erase(&pthread_attr_destroy), .expect_id = "zHchY8ft5pk" },
    .{ .name = "scePthreadAttrGet", .function = abi.erase(&scePthreadAttrGet), .expect_id = "x1X76arYMxU" },
    .{ .name = "pthread_attr_get_np", .function = abi.erase(&pthread_attr_get_np), .expect_id = "Ucsu-OK+els" },
    .{ .name = "scePthreadAttrGetstack", .function = abi.erase(&scePthreadAttrGetstack), .expect_id = "-quPa4SEJUw" },
    .{ .name = "pthread_attr_getstack", .function = abi.erase(&pthread_attr_getstack), .expect_id = "vQm4fDEsWi8" },
    .{ .name = "scePthreadAttrGetstacksize", .function = abi.erase(&scePthreadAttrGetstacksize), .expect_id = "-fA+7ZlGDQs" },
    .{ .name = "pthread_attr_getstacksize", .function = abi.erase(&pthread_attr_getstacksize), .expect_id = "0qOtCR-ZHck" },
    .{ .name = "scePthreadAttrSetstack", .function = abi.erase(&scePthreadAttrSetstack), .expect_id = "Bvn74vj6oLo" },
    .{ .name = "pthread_attr_setstack", .function = abi.erase(&pthread_attr_setstack) },
    .{ .name = "scePthreadAttrGetstackaddr", .function = abi.erase(&scePthreadAttrGetstackaddr), .expect_id = "Ru36fiTtJzA" },
    .{ .name = "scePthreadAttrSetstackaddr", .function = abi.erase(&scePthreadAttrSetstackaddr), .expect_id = "F+yfmduIBB8" },
    .{ .name = "scePthreadAttrSetstacksize", .function = abi.erase(&scePthreadAttrSetstacksize), .expect_id = "UTXzJbWhhTE" },
    .{ .name = "pthread_attr_setstacksize", .function = abi.erase(&pthread_attr_setstacksize), .expect_id = "2Q0z6rnBrTE" },
    .{ .name = "scePthreadAttrGetdetachstate", .function = abi.erase(&scePthreadAttrGetdetachstate), .expect_id = "JaRMy+QcpeU" },
    .{ .name = "pthread_attr_getdetachstate", .function = abi.erase(&pthread_attr_getdetachstate), .expect_id = "VUT1ZSrHT0I" },
    .{ .name = "scePthreadAttrSetdetachstate", .function = abi.erase(&scePthreadAttrSetdetachstate), .expect_id = "-Wreprtu0Qs" },
    .{ .name = "pthread_attr_setdetachstate", .function = abi.erase(&pthread_attr_setdetachstate), .expect_id = "E+tyo3lp5Lw" },
    .{ .name = "scePthreadAttrGetguardsize", .function = abi.erase(&scePthreadAttrGetguardsize), .expect_id = "txHtngJ+eyc" },
    .{ .name = "pthread_attr_getguardsize", .function = abi.erase(&pthread_attr_getguardsize), .expect_id = "JNkVVsVDmOk" },
    .{ .name = "scePthreadAttrSetguardsize", .function = abi.erase(&scePthreadAttrSetguardsize), .expect_id = "El+cQ20DynU" },
    .{ .name = "pthread_attr_setguardsize", .function = abi.erase(&pthread_attr_setguardsize), .expect_id = "JKyG3SWyA10" },
    .{ .name = "scePthreadAttrGetaffinity", .function = abi.erase(&scePthreadAttrGetaffinity), .expect_id = "8+s5BzZjxSg" },
    .{ .name = "scePthreadAttrSetaffinity", .function = abi.erase(&scePthreadAttrSetaffinity), .expect_id = "3qxgM4ezETA" },
    .{ .name = "scePthreadAttrSetinheritsched", .function = abi.erase(&scePthreadAttrSetinheritsched), .expect_id = "eXbUSpEaTsA" },
    .{ .name = "pthread_attr_setinheritsched", .function = abi.erase(&pthread_attr_setinheritsched), .expect_id = "7ZlAakEf0Qg" },
    .{ .name = "scePthreadAttrGetschedparam", .function = abi.erase(&scePthreadAttrGetschedparam), .expect_id = "FXPWHNk8Of0" },
    .{ .name = "pthread_attr_getschedparam", .function = abi.erase(&pthread_attr_getschedparam), .expect_id = "qlk9pSLsUmM" },
    .{ .name = "scePthreadAttrSetschedparam", .function = abi.erase(&scePthreadAttrSetschedparam), .expect_id = "DzES9hQF4f4" },
    .{ .name = "pthread_attr_setschedparam", .function = abi.erase(&pthread_attr_setschedparam), .expect_id = "euKRgm0Vn2M" },
    .{ .name = "pthread_attr_getschedpolicy", .function = abi.erase(&pthread_attr_getschedpolicy), .expect_id = "RtLRV-pBTTY" },
    .{ .name = "scePthreadAttrSetschedpolicy", .function = abi.erase(&scePthreadAttrSetschedpolicy), .expect_id = "4+h9EzwKF4I" },
    .{ .name = "pthread_attr_setschedpolicy", .function = abi.erase(&pthread_attr_setschedpolicy), .expect_id = "JarMIy8kKEY" },
    .{ .name = "scePthreadAttrGetsolosched", .function = abi.erase(&scePthreadAttrGetsolosched), .expect_id = "9RnL-m0+diQ" },
    .{ .name = "scePthreadAttrSetsolosched", .function = abi.erase(&scePthreadAttrSetsolosched), .expect_id = "Dk6FC-TI+7Q" },
    .{ .name = "scePthreadOnce", .function = abi.erase(&scePthreadOnce), .expect_id = "14bOACANTBo" },
    .{ .name = "pthread_once", .function = abi.erase(&pthread_once), .expect_id = "Z4QosVuAsA0" },
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

    fn call(raw: ?*anyopaque, _: u64, _: u64) BackendError!void {
        const self: *TestBackend = @ptrCast(@alignCast(raw.?));
        self.once_calls += 1;
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
    try testing.expectEqual(errno.ok, pthread_attr_destroy(&attr));
    try testing.expect(attr == null);
}

test "threading library registers the sample executable imports" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findById("6UgtwV+0zb4", .function) != null);
    try testing.expect(db.findById("1jfXLRVzisc", .function) != null);
}
