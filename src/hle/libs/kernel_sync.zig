// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest pthread synchronization objects.
//!
//! Guest mutexes, condition variables, and reader/writer locks are opaque
//! pointer handles. Object state stays in host-owned records, while blocking
//! goes through `kernel_threading.Backend.wait_fn`. The sequence supplied with
//! each wait closes the unlock-to-park race: a backend can observe that a wake
//! already advanced the sequence and avoid parking the guest continuation.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const threading = @import("kernel_threading.zig");
const runtime_api = @import("kernel_runtime.zig");
const kernel_memory = @import("kernel_memory.zig");

const KernelError = errno.KernelError;
const Posix = errno.Posix;

const mutex_magic: u64 = 0x5054_4d55_5445_5801;
const mutex_attr_magic: u64 = 0x5054_4d41_5454_5201;
const cond_magic: u64 = 0x5054_434f_4e44_0001;
const cond_attr_magic: u64 = 0x5054_4341_5454_5201;
const rwlock_magic: u64 = 0x5054_5257_4c4f_434b;
const rwlock_attr_magic: u64 = 0x5054_5257_4154_5452;
const barrier_magic: u64 = 0x5054_4241_5252_4945;

// AGC completion delivery is asynchronous with the guest driver's retirement
// queue. Expose a monotonic acknowledgement edge so the submit side can retry
// an interrupt which the guest consumed before publishing the matching node.
var agc_interrupt_cond_sequence: std.atomic.Value(u64) = .init(0);

pub fn agcInterruptCondSequence() u64 {
    return agc_interrupt_cond_sequence.load(.acquire);
}

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

const MutexOrigin = enum {
    explicit_default,
    explicit_attr,
    static_zero,
    static_adaptive,
};

pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub const MutexHandle = ?*Mutex;
pub const MutexAttrHandle = ?*MutexAttr;
pub const CondHandle = ?*Cond;
pub const CondAttrHandle = ?*CondAttr;
pub const RwlockHandle = ?*Rwlock;
pub const RwlockAttrHandle = ?*RwlockAttr;
pub const BarrierHandle = ?*Barrier;

const Mutex = struct {
    magic: u64 = mutex_magic,
    state_lock: Lock = .{},
    owner: u64 = 0,
    recursion: u32 = 0,
    kind: i32 = 1,
    protocol: i32 = 0,
    waiters: usize = 0,
    sequence: u64 = 1,
    origin: MutexOrigin = .static_zero,
    reported_self_lock: bool = false,
    /// Set when an unlock left waiters behind, so the mutex belongs to one of
    /// them rather than to whoever asks next.
    ///
    /// Releasing the mutex and letting everyone race for it again lets the
    /// thread that just released it win, because it is the one already
    /// running. A thread that locks and unlocks in a loop then holds the mutex
    /// in practice however long a waiter has been queued, and the waiter makes
    /// no progress at all: one observed title left its main thread parked here
    /// nine hundred times while a worker cycled the same lock, so its decoded
    /// video frames were never handed to the renderer while its audio, on
    /// another thread, played normally. Reserving the mutex for the waiters
    /// that already exist makes the queue mean something.
    handoff: bool = false,
};

const MutexAttr = struct {
    magic: u64 = mutex_attr_magic,
    kind: i32 = 1,
    protocol: i32 = 0,
};

const Cond = struct {
    magic: u64 = cond_magic,
    state_lock: Lock = .{},
    waiters: usize = 0,
    sequence: u64 = 1,
    clock_id: i32 = 0,
    last_waiter: u64 = 0,
    last_signaller: u64 = 0,
    signal_count: u64 = 0,
    zero_waiter_signals: u64 = 0,
    broadcast_count: u64 = 0,
};

const CondAttr = struct {
    magic: u64 = cond_attr_magic,
    clock_id: i32 = 0,
};

const ReaderOwner = struct {
    thread_id: u64,
    count: u32,
};

const Rwlock = struct {
    magic: u64 = rwlock_magic,
    allocator: std.mem.Allocator,
    state_lock: Lock = .{},
    writer: u64 = 0,
    readers: std.ArrayList(ReaderOwner) = .empty,
    reader_count: u32 = 0,
    waiting_readers: usize = 0,
    waiting_writers: usize = 0,
    sequence: u64 = 1,
    kind: i32 = 1,

    fn deinit(self: *Rwlock) void {
        self.readers.deinit(self.allocator);
    }
};

const RwlockAttr = struct {
    magic: u64 = rwlock_attr_magic,
    kind: i32 = 1,
};

const Barrier = struct {
    magic: u64 = barrier_magic,
    state_lock: Lock = .{},
    threshold: u32,
    arrived: u32 = 0,
    waiters: usize = 0,
    generation: u64 = 1,
};

/// Snapshot of a synchronization object addressed by a scheduler wait key.
/// This is intentionally read-only diagnostic state: the CPU dispatcher uses
/// it to distinguish a condition that has simply gone idle from a mutex or
/// rwlock whose recorded owner can no longer make progress.
pub const WaitKeyInfo = struct {
    pub const Kind = enum { mutex, condition, rwlock, barrier };

    kind: Kind,
    sequence: u64,
    waiters: usize = 0,
    owner: u64 = 0,
    recursion: u32 = 0,
    clock_id: i32 = 0,
    writer: u64 = 0,
    readers: u32 = 0,
    waiting_readers: usize = 0,
    waiting_writers: usize = 0,
    arrived: u32 = 0,
    threshold: u32 = 0,
    last_waiter: u64 = 0,
    last_signaller: u64 = 0,
    signal_count: u64 = 0,
    zero_waiter_signals: u64 = 0,
    broadcast_count: u64 = 0,
};

pub const Error = error{
    NotAttached,
    InvalidArgument,
    Busy,
    PermissionDenied,
    WouldDeadlock,
    TimedOut,
    ResourceLimit,
} || std.mem.Allocator.Error || threading.Error;

pub const Manager = struct {
    allocator: std.mem.Allocator = undefined,
    mutexes: std.ArrayList(*Mutex) = .empty,
    mutex_attrs: std.ArrayList(*MutexAttr) = .empty,
    conditions: std.ArrayList(*Cond) = .empty,
    cond_attrs: std.ArrayList(*CondAttr) = .empty,
    rwlocks: std.ArrayList(*Rwlock) = .empty,
    rwlock_attrs: std.ArrayList(*RwlockAttr) = .empty,
    barriers: std.ArrayList(*Barrier) = .empty,
    lock: Lock = .{},
    initialized: bool = false,

    pub fn init(self: *Manager, allocator: std.mem.Allocator) void {
        self.* = .{ .allocator = allocator, .initialized = true };
    }

    pub fn deinit(self: *Manager) void {
        if (!self.initialized) return;
        self.lock.lock();
        for (self.mutexes.items) |object| self.allocator.destroy(object);
        for (self.mutex_attrs.items) |attr| self.allocator.destroy(attr);
        for (self.conditions.items) |object| self.allocator.destroy(object);
        for (self.cond_attrs.items) |attr| self.allocator.destroy(attr);
        for (self.rwlocks.items) |object| {
            object.deinit();
            self.allocator.destroy(object);
        }
        for (self.rwlock_attrs.items) |attr| self.allocator.destroy(attr);
        for (self.barriers.items) |object| self.allocator.destroy(object);
        self.mutexes.deinit(self.allocator);
        self.mutex_attrs.deinit(self.allocator);
        self.conditions.deinit(self.allocator);
        self.cond_attrs.deinit(self.allocator);
        self.rwlocks.deinit(self.allocator);
        self.rwlock_attrs.deinit(self.allocator);
        self.barriers.deinit(self.allocator);
        self.lock.unlock();
        self.* = .{};
    }

    fn createMutex(
        self: *Manager,
        out: *MutexHandle,
        attr: ?MutexAttr,
        origin: MutexOrigin,
    ) Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        // Re-initializing a live object is undefined per POSIX, but titles do
        // it and firmware accepts it, so reuse the object rather than refusing.
        // Refusing loses: the guest's runtime turns the failure into an
        // exception it has no handler for. Ownership and waiter state are
        // cleared, which is what a fresh initialization means; the embedded
        // host lock is left alone because another thread may hold it.
        if (findPointer(Mutex, self.mutexes.items, out.*)) |existing| {
            existing.owner = 0;
            existing.recursion = 0;
            existing.waiters = 0;
            existing.sequence +%= 1;
            existing.kind = if (attr) |value| value.kind else 1;
            existing.protocol = if (attr) |value| value.protocol else 0;
            existing.origin = origin;
            existing.reported_self_lock = false;
            return;
        }
        const object = try self.allocator.create(Mutex);
        object.* = .{ .origin = origin };
        if (attr) |value| {
            object.kind = value.kind;
            object.protocol = value.protocol;
        }
        errdefer self.allocator.destroy(object);
        try self.mutexes.append(self.allocator, object);
        out.* = object;
    }

    /// Returns a state-locked mutex, lazily materializing static initializers.
    fn lockMutex(self: *Manager, out: *MutexHandle) Error!*Mutex {
        self.lock.lock();
        if (findPointer(Mutex, self.mutexes.items, out.*)) |object| {
            object.state_lock.lock();
            self.lock.unlock();
            return object;
        }
        const static_adaptive = if (out.*) |pointer| @intFromPtr(pointer) == 1 else false;
        if (out.* != null and !static_adaptive) {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        const object = self.allocator.create(Mutex) catch |err| {
            self.lock.unlock();
            return err;
        };
        object.* = .{
            .kind = if (static_adaptive) 4 else 1,
            .origin = if (static_adaptive) .static_adaptive else .static_zero,
        };
        self.mutexes.append(self.allocator, object) catch |err| {
            self.allocator.destroy(object);
            self.lock.unlock();
            return err;
        };
        out.* = object;
        object.state_lock.lock();
        self.lock.unlock();
        return object;
    }

    fn destroyMutex(self: *Manager, out: *MutexHandle) Error!void {
        self.lock.lock();
        const index = findIndex(Mutex, self.mutexes.items, out.*) orelse {
            if (out.* == null) {
                self.lock.unlock();
                return;
            }
            self.lock.unlock();
            return error.InvalidArgument;
        };
        const object = self.mutexes.items[index];
        object.state_lock.lock();
        if (object.owner != 0 or object.waiters != 0) {
            object.state_lock.unlock();
            self.lock.unlock();
            return error.Busy;
        }
        _ = self.mutexes.orderedRemove(index);
        object.magic = 0;
        out.* = null;
        object.state_lock.unlock();
        self.lock.unlock();
        self.allocator.destroy(object);
    }

    fn createCond(self: *Manager, out: *CondHandle, attr: ?CondAttr) Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        // See createMutex: re-initialization reuses the existing object.
        if (findPointer(Cond, self.conditions.items, out.*)) |existing| {
            existing.waiters = 0;
            existing.sequence +%= 1;
            existing.clock_id = if (attr) |value| value.clock_id else 0;
            existing.last_waiter = 0;
            existing.last_signaller = 0;
            existing.signal_count = 0;
            existing.zero_waiter_signals = 0;
            existing.broadcast_count = 0;
            return;
        }
        const object = try self.allocator.create(Cond);
        object.* = .{};
        if (attr) |value| object.clock_id = value.clock_id;
        errdefer self.allocator.destroy(object);
        try self.conditions.append(self.allocator, object);
        out.* = object;
    }

    fn lockCond(self: *Manager, out: *CondHandle) Error!*Cond {
        self.lock.lock();
        if (findPointer(Cond, self.conditions.items, out.*)) |object| {
            object.state_lock.lock();
            self.lock.unlock();
            return object;
        }
        if (out.* != null) {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        const object = self.allocator.create(Cond) catch |err| {
            self.lock.unlock();
            return err;
        };
        object.* = .{};
        self.conditions.append(self.allocator, object) catch |err| {
            self.allocator.destroy(object);
            self.lock.unlock();
            return err;
        };
        out.* = object;
        object.state_lock.lock();
        self.lock.unlock();
        return object;
    }

    fn lockCondAndMutex(
        self: *Manager,
        cond_out: *CondHandle,
        mutex_out: *MutexHandle,
    ) Error!struct { cond: *Cond, mutex: *Mutex } {
        self.lock.lock();

        var cond = findPointer(Cond, self.conditions.items, cond_out.*);
        var mutex = findPointer(Mutex, self.mutexes.items, mutex_out.*);
        if ((cond == null and cond_out.* != null) or
            (mutex == null and mutex_out.* != null))
        {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        if (cond == null) {
            const created = self.allocator.create(Cond) catch |err| {
                self.lock.unlock();
                return err;
            };
            created.* = .{};
            self.conditions.append(self.allocator, created) catch |err| {
                self.allocator.destroy(created);
                self.lock.unlock();
                return err;
            };
            cond_out.* = created;
            cond = created;
        }

        if (mutex == null) {
            const created = self.allocator.create(Mutex) catch |err| {
                self.lock.unlock();
                return err;
            };
            created.* = .{};
            self.mutexes.append(self.allocator, created) catch |err| {
                self.allocator.destroy(created);
                self.lock.unlock();
                return err;
            };
            mutex_out.* = created;
            mutex = created;
        }

        cond.?.state_lock.lock();
        mutex.?.state_lock.lock();
        self.lock.unlock();
        return .{ .cond = cond.?, .mutex = mutex.? };
    }

    fn destroyCond(self: *Manager, out: *CondHandle) Error!void {
        self.lock.lock();
        const index = findIndex(Cond, self.conditions.items, out.*) orelse {
            if (out.* == null) {
                self.lock.unlock();
                return;
            }
            self.lock.unlock();
            return error.InvalidArgument;
        };
        const object = self.conditions.items[index];
        object.state_lock.lock();
        if (object.waiters != 0) {
            object.state_lock.unlock();
            self.lock.unlock();
            return error.Busy;
        }
        _ = self.conditions.orderedRemove(index);
        object.magic = 0;
        out.* = null;
        object.state_lock.unlock();
        self.lock.unlock();
        self.allocator.destroy(object);
    }

    fn createRwlock(self: *Manager, out: *RwlockHandle, attr: ?RwlockAttr) Error!void {
        self.lock.lock();
        defer self.lock.unlock();
        // See createMutex: re-initialization reuses the existing object.
        if (findPointer(Rwlock, self.rwlocks.items, out.*)) |existing| {
            existing.writer = 0;
            existing.readers.clearRetainingCapacity();
            existing.reader_count = 0;
            existing.waiting_readers = 0;
            existing.waiting_writers = 0;
            existing.sequence +%= 1;
            existing.kind = if (attr) |value| value.kind else 1;
            return;
        }
        const object = try self.allocator.create(Rwlock);
        object.* = .{ .allocator = self.allocator };
        if (attr) |value| object.kind = value.kind;
        errdefer self.allocator.destroy(object);
        try self.rwlocks.append(self.allocator, object);
        out.* = object;
    }

    fn lockRwlock(self: *Manager, out: *RwlockHandle) Error!*Rwlock {
        self.lock.lock();
        if (findPointer(Rwlock, self.rwlocks.items, out.*)) |object| {
            object.state_lock.lock();
            self.lock.unlock();
            return object;
        }
        if (out.* != null) {
            self.lock.unlock();
            return error.InvalidArgument;
        }
        const object = self.allocator.create(Rwlock) catch |err| {
            self.lock.unlock();
            return err;
        };
        object.* = .{ .allocator = self.allocator };
        self.rwlocks.append(self.allocator, object) catch |err| {
            self.allocator.destroy(object);
            self.lock.unlock();
            return err;
        };
        out.* = object;
        object.state_lock.lock();
        self.lock.unlock();
        return object;
    }

    fn destroyRwlock(self: *Manager, out: *RwlockHandle) Error!void {
        self.lock.lock();
        const index = findIndex(Rwlock, self.rwlocks.items, out.*) orelse {
            if (out.* == null) {
                self.lock.unlock();
                return;
            }
            self.lock.unlock();
            return error.InvalidArgument;
        };
        const object = self.rwlocks.items[index];
        object.state_lock.lock();
        if (object.writer != 0 or object.reader_count != 0 or
            object.waiting_readers != 0 or object.waiting_writers != 0)
        {
            object.state_lock.unlock();
            self.lock.unlock();
            return error.Busy;
        }
        _ = self.rwlocks.orderedRemove(index);
        object.magic = 0;
        out.* = null;
        object.state_lock.unlock();
        self.lock.unlock();
        object.deinit();
        self.allocator.destroy(object);
    }

    fn createBarrier(self: *Manager, out: *BarrierHandle, count: u32) Error!void {
        if (count == 0) return error.InvalidArgument;
        self.lock.lock();
        defer self.lock.unlock();
        if (findPointer(Barrier, self.barriers.items, out.*)) |existing| {
            if (existing.waiters != 0 or existing.arrived != 0) return error.Busy;
            existing.threshold = count;
            _ = advanceSequence(&existing.generation);
            return;
        }
        if (out.* != null) return error.InvalidArgument;
        const object = try self.allocator.create(Barrier);
        object.* = .{ .threshold = count };
        errdefer self.allocator.destroy(object);
        try self.barriers.append(self.allocator, object);
        out.* = object;
    }

    fn lockBarrier(self: *Manager, out: *BarrierHandle) Error!*Barrier {
        self.lock.lock();
        const object = findPointer(Barrier, self.barriers.items, out.*) orelse {
            self.lock.unlock();
            return error.InvalidArgument;
        };
        object.state_lock.lock();
        self.lock.unlock();
        return object;
    }

    fn destroyBarrier(self: *Manager, out: *BarrierHandle) Error!void {
        self.lock.lock();
        const index = findIndex(Barrier, self.barriers.items, out.*) orelse {
            self.lock.unlock();
            return error.InvalidArgument;
        };
        const object = self.barriers.items[index];
        object.state_lock.lock();
        if (object.waiters != 0 or object.arrived != 0) {
            object.state_lock.unlock();
            self.lock.unlock();
            return error.Busy;
        }
        _ = self.barriers.orderedRemove(index);
        object.magic = 0;
        out.* = null;
        object.state_lock.unlock();
        self.lock.unlock();
        self.allocator.destroy(object);
    }
};

/// The thread manager every synchronization entry point works through.
///
/// Held as an atomic pointer rather than behind a lock. Reading it is the first
/// thing every mutex, condition and lock operation does, so a lock here is
/// taken by every guest thread for every one of those calls — and this one was
/// a spin lock, which does not yield. On a title with fifty threads that turns
/// the busiest path in the emulator into a queue the whole machine spins in:
/// measured on the title under test, sixteen cores fully busy while it managed
/// a third of a frame per second.
///
/// Mutual exclusion buys nothing here anyway. There is one pointer, readers
/// only read it, and a reader that races an attach sees either the old manager
/// or the new one — which is exactly what the lock guaranteed.
var attached_manager: std.atomic.Value(?*Manager) = .init(null);

pub fn attachManager(new_manager: ?*Manager) void {
    attached_manager.store(new_manager, .release);
}

fn activeManager() ?*Manager {
    return attached_manager.load(.acquire);
}

/// Resolves the opaque key passed to `threading.waitCurrent` back to its
/// host-owned synchronization record. Manager-before-state is the same lock
/// order used by the object entry points, so taking a snapshot cannot invert
/// the synchronization path being inspected.
pub fn describeWaitKey(key: u64) ?WaitKeyInfo {
    const manager = activeManager() orelse return null;
    manager.lock.lock();
    defer manager.lock.unlock();

    for (manager.mutexes.items) |object| {
        if (@intFromPtr(object) != key) continue;
        object.state_lock.lock();
        defer object.state_lock.unlock();
        return .{
            .kind = .mutex,
            .sequence = object.sequence,
            .waiters = object.waiters,
            .owner = object.owner,
            .recursion = object.recursion,
        };
    }
    for (manager.conditions.items) |object| {
        if (@intFromPtr(object) != key) continue;
        object.state_lock.lock();
        defer object.state_lock.unlock();
        return .{
            .kind = .condition,
            .sequence = object.sequence,
            .waiters = object.waiters,
            .clock_id = object.clock_id,
            .last_waiter = object.last_waiter,
            .last_signaller = object.last_signaller,
            .signal_count = object.signal_count,
            .zero_waiter_signals = object.zero_waiter_signals,
            .broadcast_count = object.broadcast_count,
        };
    }
    for (manager.rwlocks.items) |object| {
        if (@intFromPtr(object) != key) continue;
        object.state_lock.lock();
        defer object.state_lock.unlock();
        return .{
            .kind = .rwlock,
            .sequence = object.sequence,
            .waiters = object.waiting_readers + object.waiting_writers,
            .writer = object.writer,
            .readers = object.reader_count,
            .waiting_readers = object.waiting_readers,
            .waiting_writers = object.waiting_writers,
        };
    }
    for (manager.barriers.items) |object| {
        if (@intFromPtr(object) != key) continue;
        object.state_lock.lock();
        defer object.state_lock.unlock();
        return .{
            .kind = .barrier,
            .sequence = object.generation,
            .waiters = object.waiters,
            .arrived = object.arrived,
            .threshold = object.threshold,
        };
    }
    return null;
}

fn findPointer(comptime T: type, objects: []const *T, handle: ?*T) ?*T {
    const pointer = handle orelse return null;
    for (objects) |object| {
        if (object == pointer) return object;
    }
    return null;
}

fn findIndex(comptime T: type, objects: []const *T, handle: ?*T) ?usize {
    const pointer = handle orelse return null;
    for (objects, 0..) |object, index| {
        if (object == pointer) return index;
    }
    return null;
}

fn advanceSequence(sequence: *u64) u64 {
    sequence.* +%= 1;
    if (sequence.* == 0) sequence.* = 1;
    return sequence.*;
}

fn absoluteDeadline(value: ?*const Timespec) Error!?u64 {
    const timespec = value orelse return null;
    if (timespec.tv_sec < 0 or timespec.tv_nsec < 0 or timespec.tv_nsec >= std.time.ns_per_s) {
        return error.InvalidArgument;
    }
    const seconds: u64 = @intCast(timespec.tv_sec);
    const second_ns = std.math.mul(u64, seconds, std.time.ns_per_s) catch
        return error.InvalidArgument;
    return std.math.add(u64, second_ns, @intCast(timespec.tv_nsec)) catch
        return error.InvalidArgument;
}

fn supportedCondClock(clock_id: i32) bool {
    return switch (clock_id) {
        // Realtime, realtime precise/fast, and the one-second clock.
        0,
        9,
        10,
        13,
        // Monotonic, uptime variants, monotonic variants, and network clocks.
        4,
        5,
        7,
        8,
        11,
        12,
        16,
        17,
        18,
        19,
        => true,
        else => false,
    };
}

fn kernelStatus(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => KernelError.enomem.raw(),
        error.Busy => KernelError.ebusy.raw(),
        error.PermissionDenied => KernelError.eperm.raw(),
        error.WouldDeadlock => KernelError.edeadlk.raw(),
        error.TimedOut => KernelError.etimedout.raw(),
        error.ResourceLimit => KernelError.eagain.raw(),
        error.NotAttached, error.ExecutorUnavailable, error.Unsupported => KernelError.enosys.raw(),
        error.JoinFailed, error.WaitFailed, error.CallFailed => KernelError.eio.raw(),
        else => KernelError.einval.raw(),
    };
}

fn posixStatus(status: i32) i32 {
    return if (status == errno.ok) errno.ok else errno.kernelToPosix(status);
}

fn currentThread() Error!u64 {
    const thread_id = threading.currentThreadId();
    return if (thread_id == 0) error.InvalidArgument else thread_id;
}

fn mutexUsesDefaultCompatibility(object: *const Mutex) bool {
    return switch (object.origin) {
        .explicit_default, .static_zero => true,
        .explicit_attr, .static_adaptive => false,
    };
}

/// Gen5's CRT initializes the process-wide static-initializer guard with a
/// null attribute, then recursively try-locks that guard while constructing
/// nested function-local statics.  Its wrapper always performs a matching
/// unlock, so the compatibility try-lock must retain the recursion depth.
/// A repeated blocking lock on a firmware-default mutex is different: Gen5's
/// guest fast path can leave the HLE owner already established when its slow
/// path is entered.  Coalesce that duplicate below instead of accumulating a
/// recursion count which can keep the mutex owned after the caller is done.
fn mutexTracksRecursiveLock(object: *const Mutex, try_only: bool) bool {
    return object.kind == 2 or (try_only and mutexUsesDefaultCompatibility(object));
}

fn readMutexAttr(raw: ?*const MutexAttrHandle) ?MutexAttr {
    const outer = raw orelse return null;
    const manager = activeManager() orelse return null;
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = findPointer(MutexAttr, manager.mutex_attrs.items, outer.*) orelse return null;
    return attr.*;
}

fn mutexLockCore(
    outer: ?*MutexHandle,
    try_only: bool,
    timeout_microseconds: ?u64,
    absolute_deadline_ns: ?u64,
) Error!void {
    const handle = outer orelse return error.InvalidArgument;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(handle), @sizeOf(MutexHandle))) {
        return error.InvalidArgument;
    }
    const manager = activeManager() orelse return error.NotAttached;
    const thread_id = try currentThread();
    const object = try manager.lockMutex(handle);
    var state_locked = true;
    defer if (state_locked) object.state_lock.unlock();
    var registered_waiter = false;

    while (true) {
        // A free mutex reserved for its existing waiters is not available to a
        // thread arriving now. `trylock` is exempt: POSIX lets it fail only
        // when the mutex is held, and a title is entitled to that answer.
        const reserved = object.handoff and object.waiters != 0 and
            !registered_waiter and !try_only;
        if (object.owner == 0 and !reserved) {
            object.owner = thread_id;
            object.recursion = 1;
            object.handoff = false;
            if (registered_waiter) object.waiters -= 1;
            return;
        }
        if (object.owner == thread_id) {
            if (!object.reported_self_lock and trace.isLive()) {
                object.reported_self_lock = true;
                std.debug.print(
                    "[kernel sync] mutex self-lock outer=0x{x} object=0x{x} thread=0x{x} operation={s} kind={d} origin={s} recursion={d}\n",
                    .{
                        @intFromPtr(handle),
                        @intFromPtr(object),
                        thread_id,
                        if (try_only) "trylock" else "lock",
                        object.kind,
                        @tagName(object.origin),
                        object.recursion,
                    },
                );
            }
            if (mutexTracksRecursiveLock(object, try_only)) {
                if (object.recursion == std.math.maxInt(u32)) return error.ResourceLimit;
                object.recursion += 1;
                if (registered_waiter) object.waiters -= 1;
                return;
            }
            if (mutexUsesDefaultCompatibility(object)) {
                // The ordinary Gen5 mutex wrapper may reach the imported slow
                // path after its guest-side fast path has already established
                // ownership.  This is one logical acquisition, not recursion.
                if (registered_waiter) object.waiters -= 1;
                return;
            }
            if (registered_waiter) object.waiters -= 1;
            return if (try_only) error.Busy else error.WouldDeadlock;
        }
        if (try_only) {
            if (registered_waiter) object.waiters -= 1;
            return error.Busy;
        }
        if (!registered_waiter) {
            object.waiters += 1;
            registered_waiter = true;
        }
        const sequence = object.sequence;
        object.state_lock.unlock();
        state_locked = false;
        const wait_result = threading.waitCurrent(.{
            .key = @intFromPtr(object),
            .observed_sequence = sequence,
            .timeout_microseconds = timeout_microseconds,
            .absolute_deadline_ns = absolute_deadline_ns,
        }) catch |err| {
            object.state_lock.lock();
            state_locked = true;
            // A concurrent unlock won the race even though the scheduler
            // reported a failure. Recheck ownership before surfacing it.
            if (object.sequence != sequence) continue;
            object.waiters -= 1;
            if (object.waiters == 0) object.handoff = false;
            return err;
        };
        object.state_lock.lock();
        state_locked = true;
        if (wait_result == .timed_out and object.sequence == sequence) {
            object.waiters -= 1;
            if (object.waiters == 0) object.handoff = false;
            return error.TimedOut;
        }
    }
}

fn mutexUnlockCore(outer: ?*MutexHandle) Error!void {
    const handle = outer orelse return error.InvalidArgument;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(handle), @sizeOf(MutexHandle))) {
        return error.InvalidArgument;
    }
    const manager = activeManager() orelse return error.NotAttached;
    const thread_id = try currentThread();
    const object = try manager.lockMutex(handle);
    if (object.owner != thread_id) {
        object.state_lock.unlock();
        return error.PermissionDenied;
    }
    if ((object.kind == 2 or mutexUsesDefaultCompatibility(object)) and object.recursion > 1) {
        object.recursion -= 1;
        object.state_lock.unlock();
        return;
    }
    object.owner = 0;
    object.recursion = 0;
    const wake = object.waiters != 0;
    object.handoff = wake;
    const sequence = advanceSequence(&object.sequence);
    object.state_lock.unlock();
    if (wake) threading.wakeWaiters(@intFromPtr(object), sequence, 1);
}

pub fn scePthreadMutexInit(
    mutex: ?*MutexHandle,
    attr: ?*const MutexAttrHandle,
    _: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const output = mutex orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    const value = if (attr) |supplied|
        readMutexAttr(supplied) orelse return KernelError.einval.raw()
    else
        null;
    manager.createMutex(
        output,
        value,
        if (attr == null) .explicit_default else .explicit_attr,
    ) catch |err|
        return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_mutex_init(
    mutex: ?*MutexHandle,
    attr: ?*const MutexAttrHandle,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexInit(mutex, attr, null));
}

pub fn scePthreadMutexDestroy(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    const output = mutex orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.destroyMutex(output) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_mutex_destroy(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexDestroy(mutex));
}

pub fn scePthreadMutexLock(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    mutexLockCore(mutex, false, null, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_mutex_lock(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexLock(mutex));
}

pub fn scePthreadMutexTrylock(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    mutexLockCore(mutex, true, null, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_mutex_trylock(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexTrylock(mutex));
}

pub fn scePthreadMutexTimedlock(mutex: ?*MutexHandle, microseconds: u32) callconv(abi.guest) i32 {
    mutexLockCore(mutex, false, microseconds, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_mutex_timedlock(
    mutex: ?*MutexHandle,
    deadline: ?*const Timespec,
) callconv(abi.guest) i32 {
    const deadline_ns = absoluteDeadline(deadline) catch return Posix.einval;
    mutexLockCore(mutex, false, null, deadline_ns) catch |err|
        return posixStatus(kernelStatus(err));
    return errno.ok;
}

pub fn scePthreadMutexUnlock(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    mutexUnlockCore(mutex) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_mutex_unlock(mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexUnlock(mutex));
}

pub fn scePthreadMutexattrInit(out_attr: ?*MutexAttrHandle) callconv(abi.guest) i32 {
    const output = out_attr orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = manager.allocator.create(MutexAttr) catch return KernelError.enomem.raw();
    attr.* = .{};
    manager.mutex_attrs.append(manager.allocator, attr) catch {
        manager.allocator.destroy(attr);
        return KernelError.enomem.raw();
    };
    output.* = attr;
    return errno.ok;
}

pub fn pthread_mutexattr_init(out_attr: ?*MutexAttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexattrInit(out_attr));
}

pub fn scePthreadMutexattrDestroy(out_attr: ?*MutexAttrHandle) callconv(abi.guest) i32 {
    const output = out_attr orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    const index = findIndex(MutexAttr, manager.mutex_attrs.items, output.*) orelse {
        manager.lock.unlock();
        return KernelError.einval.raw();
    };
    const attr = manager.mutex_attrs.orderedRemove(index);
    output.* = null;
    manager.lock.unlock();
    manager.allocator.destroy(attr);
    return errno.ok;
}

pub fn pthread_mutexattr_destroy(out_attr: ?*MutexAttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexattrDestroy(out_attr));
}

fn updateMutexAttr(raw: ?*MutexAttrHandle, value: i32, protocol: bool) i32 {
    const outer = raw orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = findPointer(MutexAttr, manager.mutex_attrs.items, outer.*) orelse
        return KernelError.einval.raw();
    if (protocol) attr.protocol = value else attr.kind = value;
    return errno.ok;
}

pub fn scePthreadMutexattrSettype(attr: ?*MutexAttrHandle, kind: i32) callconv(abi.guest) i32 {
    // Guest values: error-checking, recursive, normal, and adaptive.
    if (kind < 1 or kind > 4) return KernelError.einval.raw();
    return updateMutexAttr(attr, kind, false);
}

pub fn pthread_mutexattr_settype(attr: ?*MutexAttrHandle, kind: i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexattrSettype(attr, kind));
}

pub fn scePthreadMutexattrSetprotocol(attr: ?*MutexAttrHandle, protocol: i32) callconv(abi.guest) i32 {
    if (protocol < 0 or protocol > 2) return KernelError.einval.raw();
    return updateMutexAttr(attr, protocol, true);
}

pub fn pthread_mutexattr_setprotocol(attr: ?*MutexAttrHandle, protocol: i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadMutexattrSetprotocol(attr, protocol));
}

fn readCondAttr(raw: ?*const CondAttrHandle) ?CondAttr {
    const outer = raw orelse return null;
    const manager = activeManager() orelse return null;
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = findPointer(CondAttr, manager.cond_attrs.items, outer.*) orelse return null;
    return attr.*;
}

fn reacquireMutexAfterCond(object: *Mutex, thread_id: u64, recursion: u32) Error!void {
    while (true) {
        object.state_lock.lock();
        if (object.owner == 0) {
            object.owner = thread_id;
            object.recursion = recursion;
            object.waiters -= 1;
            object.state_lock.unlock();
            return;
        }
        const sequence = object.sequence;
        object.state_lock.unlock();
        _ = threading.waitCurrent(.{
            .key = @intFromPtr(object),
            .observed_sequence = sequence,
        }) catch |err| {
            object.state_lock.lock();
            if (object.sequence != sequence) {
                object.state_lock.unlock();
                continue;
            }
            object.waiters -= 1;
            object.state_lock.unlock();
            return err;
        };
    }
}

fn condWaitCore(
    cond_outer: ?*CondHandle,
    mutex_outer: ?*MutexHandle,
    timeout_microseconds: ?u64,
    absolute_deadline_ns: ?u64,
) Error!void {
    const cond_handle = cond_outer orelse return error.InvalidArgument;
    const mutex_handle = mutex_outer orelse return error.InvalidArgument;
    const manager = activeManager() orelse return error.NotAttached;
    const thread_id = try currentThread();
    const pair = try manager.lockCondAndMutex(cond_handle, mutex_handle);
    const cond = pair.cond;
    const mutex = pair.mutex;

    if (mutex.owner == 0 and mutex.recursion == 0) {
        // Gen5 libkernel may acquire the uncontended mutex word entirely in
        // guest code.  No HLE lock call then exists to establish host-side
        // ownership, but cond_wait still has to perform its atomic
        // unlock/wait/relock cycle.  Adopt the uncontended owner here; a mutex
        // owned by another tracked thread remains a real EPERM below.
        mutex.owner = thread_id;
        mutex.recursion = 1;
    }
    if (mutex.owner != thread_id) {
        if (trace.isLive()) std.debug.print(
            "[kernel sync] cond wait ownership mismatch outer=0x{x} owner=0x{x} current=0x{x} recursion={d} waiters={d} origin={s}\n",
            .{ @intFromPtr(mutex_handle), mutex.owner, thread_id, mutex.recursion, mutex.waiters, @tagName(mutex.origin) },
        );
        mutex.state_lock.unlock();
        cond.state_lock.unlock();
        return error.PermissionDenied;
    }

    const saved_recursion = mutex.recursion;
    const observed_sequence = cond.sequence;
    const clock_id = cond.clock_id;
    cond.waiters += 1;
    cond.last_waiter = thread_id;
    // This reservation prevents mutex destruction while the condition waiter
    // is between the atomic unlock and mandatory reacquisition.
    mutex.waiters += 1;
    mutex.owner = 0;
    mutex.recursion = 0;
    const mutex_sequence = advanceSequence(&mutex.sequence);
    const wake_mutex = mutex.waiters > 1;
    mutex.state_lock.unlock();
    cond.state_lock.unlock();
    if (wake_mutex) threading.wakeWaiters(@intFromPtr(mutex), mutex_sequence, 1);

    var timed_out = false;
    var wait_failure: ?threading.Error = null;
    while (true) {
        const wait_result = threading.waitCurrent(.{
            .key = @intFromPtr(cond),
            .observed_sequence = observed_sequence,
            .timeout_microseconds = timeout_microseconds,
            .absolute_deadline_ns = absolute_deadline_ns,
            .clock_id = clock_id,
        }) catch |err| {
            cond.state_lock.lock();
            const signalled = cond.sequence != observed_sequence;
            cond.waiters -= 1;
            cond.state_lock.unlock();
            if (!signalled) wait_failure = err;
            break;
        };
        cond.state_lock.lock();
        const signalled = cond.sequence != observed_sequence;
        if (signalled or wait_result == .timed_out or wait_result == .awoken) {
            cond.waiters -= 1;
            timed_out = !signalled and wait_result == .timed_out;
            cond.state_lock.unlock();
            break;
        }
        cond.state_lock.unlock();
    }

    try reacquireMutexAfterCond(mutex, thread_id, saved_recursion);
    if (wait_failure) |failure| return failure;
    if (timed_out) return error.TimedOut;
}

fn condSignalCore(cond_outer: ?*CondHandle, broadcast: bool) Error!void {
    const handle = cond_outer orelse return error.InvalidArgument;
    const manager = activeManager() orelse return error.NotAttached;
    const object = try manager.lockCond(handle);
    const sequence = advanceSequence(&object.sequence);
    const waiters = object.waiters;
    object.last_signaller = threading.currentThreadId();
    const thread_name_storage = threading.currentThreadName();
    const thread_name = std.mem.sliceTo(&thread_name_storage, 0);
    if (std.mem.eql(u8, thread_name, "AgcInterruptThread")) {
        _ = agc_interrupt_cond_sequence.fetchAdd(1, .release);
        std.debug.print(
            "[agc interrupt] cond {s} key=0x{x} sequence={d} waiters={d}\n",
            .{ if (broadcast) "broadcast" else "signal", @intFromPtr(object), sequence, waiters },
        );
    }
    object.signal_count +|= 1;
    if (waiters == 0) object.zero_waiter_signals +|= 1;
    if (broadcast) object.broadcast_count +|= 1;
    object.state_lock.unlock();
    if (waiters != 0) {
        threading.wakeWaiters(
            @intFromPtr(object),
            sequence,
            if (broadcast) waiters else 1,
        );
    }
}

pub fn scePthreadCondInit(
    cond: ?*CondHandle,
    attr: ?*const CondAttrHandle,
    _: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const output = cond orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.createCond(output, if (attr == null) null else readCondAttr(attr)) catch |err|
        return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_cond_init(cond: ?*CondHandle, attr: ?*const CondAttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondInit(cond, attr, null));
}

pub fn scePthreadCondDestroy(cond: ?*CondHandle) callconv(abi.guest) i32 {
    const output = cond orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.destroyCond(output) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_cond_destroy(cond: ?*CondHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondDestroy(cond));
}

pub fn scePthreadCondWait(cond: ?*CondHandle, mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    condWaitCore(cond, mutex, null, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_cond_wait(cond: ?*CondHandle, mutex: ?*MutexHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondWait(cond, mutex));
}

pub fn scePthreadCondTimedwait(
    cond: ?*CondHandle,
    mutex: ?*MutexHandle,
    microseconds: u32,
) callconv(abi.guest) i32 {
    condWaitCore(cond, mutex, microseconds, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_cond_timedwait(
    cond: ?*CondHandle,
    mutex: ?*MutexHandle,
    deadline: ?*const Timespec,
) callconv(abi.guest) i32 {
    const deadline_ns = absoluteDeadline(deadline) catch return Posix.einval;
    condWaitCore(cond, mutex, null, deadline_ns) catch |err|
        return posixStatus(kernelStatus(err));
    return errno.ok;
}

pub fn scePthreadCondSignal(cond: ?*CondHandle) callconv(abi.guest) i32 {
    condSignalCore(cond, false) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_cond_signal(cond: ?*CondHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondSignal(cond));
}

pub fn scePthreadCondBroadcast(cond: ?*CondHandle) callconv(abi.guest) i32 {
    condSignalCore(cond, true) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_cond_broadcast(cond: ?*CondHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondBroadcast(cond));
}

pub fn scePthreadCondattrInit(out_attr: ?*CondAttrHandle) callconv(abi.guest) i32 {
    const output = out_attr orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = manager.allocator.create(CondAttr) catch return KernelError.enomem.raw();
    attr.* = .{};
    manager.cond_attrs.append(manager.allocator, attr) catch {
        manager.allocator.destroy(attr);
        return KernelError.enomem.raw();
    };
    output.* = attr;
    return errno.ok;
}

pub fn pthread_condattr_init(out_attr: ?*CondAttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondattrInit(out_attr));
}

pub fn scePthreadCondattrDestroy(out_attr: ?*CondAttrHandle) callconv(abi.guest) i32 {
    const output = out_attr orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    const index = findIndex(CondAttr, manager.cond_attrs.items, output.*) orelse {
        manager.lock.unlock();
        return KernelError.einval.raw();
    };
    const attr = manager.cond_attrs.orderedRemove(index);
    output.* = null;
    manager.lock.unlock();
    manager.allocator.destroy(attr);
    return errno.ok;
}

pub fn pthread_condattr_destroy(out_attr: ?*CondAttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondattrDestroy(out_attr));
}

pub fn scePthreadCondattrSetclock(attr_raw: ?*CondAttrHandle, clock_id: i32) callconv(abi.guest) i32 {
    if (!supportedCondClock(clock_id)) return KernelError.einval.raw();
    const outer = attr_raw orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = findPointer(CondAttr, manager.cond_attrs.items, outer.*) orelse
        return KernelError.einval.raw();
    attr.clock_id = clock_id;
    return errno.ok;
}

pub fn pthread_condattr_setclock(attr: ?*CondAttrHandle, clock_id: i32) callconv(abi.guest) i32 {
    return posixStatus(scePthreadCondattrSetclock(attr, clock_id));
}

fn readRwlockAttr(raw: ?*const RwlockAttrHandle) ?RwlockAttr {
    const outer = raw orelse return null;
    const manager = activeManager() orelse return null;
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = findPointer(RwlockAttr, manager.rwlock_attrs.items, outer.*) orelse return null;
    return attr.*;
}

fn readerIndex(object: *Rwlock, thread_id: u64) ?usize {
    for (object.readers.items, 0..) |reader, index| {
        if (reader.thread_id == thread_id) return index;
    }
    return null;
}

fn rwlockLockCore(
    outer: ?*RwlockHandle,
    write: bool,
    try_only: bool,
    timeout_microseconds: ?u64,
    absolute_deadline_ns: ?u64,
) Error!void {
    const handle = outer orelse return error.InvalidArgument;
    const manager = activeManager() orelse return error.NotAttached;
    const thread_id = try currentThread();
    const object = try manager.lockRwlock(handle);
    var state_locked = true;
    defer if (state_locked) object.state_lock.unlock();
    var registered_waiter = false;

    while (true) {
        const existing_reader = readerIndex(object, thread_id);
        if (write) {
            if (object.writer == thread_id or existing_reader != null) {
                if (registered_waiter) object.waiting_writers -= 1;
                return if (try_only) error.Busy else error.WouldDeadlock;
            }
            if (object.writer == 0 and object.reader_count == 0) {
                object.writer = thread_id;
                if (registered_waiter) object.waiting_writers -= 1;
                return;
            }
        } else {
            if (object.writer == thread_id) {
                if (registered_waiter) object.waiting_readers -= 1;
                return if (try_only) error.Busy else error.WouldDeadlock;
            }
            if (object.writer == 0 and (object.waiting_writers == 0 or existing_reader != null)) {
                if (object.reader_count == std.math.maxInt(u32)) {
                    if (registered_waiter) object.waiting_readers -= 1;
                    return error.ResourceLimit;
                }
                if (existing_reader) |index| {
                    if (object.readers.items[index].count == std.math.maxInt(u32)) {
                        if (registered_waiter) object.waiting_readers -= 1;
                        return error.ResourceLimit;
                    }
                    object.readers.items[index].count += 1;
                } else {
                    object.readers.append(object.allocator, .{
                        .thread_id = thread_id,
                        .count = 1,
                    }) catch |err| {
                        if (registered_waiter) object.waiting_readers -= 1;
                        return err;
                    };
                }
                object.reader_count += 1;
                if (registered_waiter) object.waiting_readers -= 1;
                return;
            }
        }

        if (try_only) {
            if (registered_waiter) {
                if (write) object.waiting_writers -= 1 else object.waiting_readers -= 1;
            }
            return error.Busy;
        }
        if (!registered_waiter) {
            if (write) object.waiting_writers += 1 else object.waiting_readers += 1;
            registered_waiter = true;
        }
        const sequence = object.sequence;
        object.state_lock.unlock();
        state_locked = false;
        const wait_result = threading.waitCurrent(.{
            .key = @intFromPtr(object),
            .observed_sequence = sequence,
            .timeout_microseconds = timeout_microseconds,
            .absolute_deadline_ns = absolute_deadline_ns,
        }) catch |err| {
            object.state_lock.lock();
            state_locked = true;
            if (object.sequence != sequence) continue;
            if (write) object.waiting_writers -= 1 else object.waiting_readers -= 1;
            return err;
        };
        object.state_lock.lock();
        state_locked = true;
        if (wait_result == .timed_out and object.sequence == sequence) {
            if (write) object.waiting_writers -= 1 else object.waiting_readers -= 1;
            return error.TimedOut;
        }
    }
}

fn rwlockUnlockCore(outer: ?*RwlockHandle) Error!void {
    const handle = outer orelse return error.InvalidArgument;
    const manager = activeManager() orelse return error.NotAttached;
    const thread_id = try currentThread();
    const object = try manager.lockRwlock(handle);

    if (object.writer == thread_id) {
        object.writer = 0;
    } else if (readerIndex(object, thread_id)) |index| {
        object.readers.items[index].count -= 1;
        object.reader_count -= 1;
        if (object.readers.items[index].count == 0) _ = object.readers.orderedRemove(index);
    } else {
        object.state_lock.unlock();
        return error.PermissionDenied;
    }

    const sequence = advanceSequence(&object.sequence);
    const waiters = object.waiting_readers + object.waiting_writers;
    object.state_lock.unlock();
    if (waiters != 0) threading.wakeWaiters(@intFromPtr(object), sequence, waiters);
}

pub fn scePthreadRwlockInit(
    rwlock: ?*RwlockHandle,
    attr: ?*const RwlockAttrHandle,
    _: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const output = rwlock orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.createRwlock(output, if (attr == null) null else readRwlockAttr(attr)) catch |err|
        return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_init(
    rwlock: ?*RwlockHandle,
    attr: ?*const RwlockAttrHandle,
) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockInit(rwlock, attr, null));
}

pub fn scePthreadRwlockDestroy(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    const output = rwlock orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.destroyRwlock(output) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_destroy(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockDestroy(rwlock));
}

pub fn scePthreadRwlockRdlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    rwlockLockCore(rwlock, false, false, null, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_rdlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockRdlock(rwlock));
}

pub fn scePthreadRwlockWrlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    rwlockLockCore(rwlock, true, false, null, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_wrlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockWrlock(rwlock));
}

pub fn scePthreadRwlockTryrdlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    rwlockLockCore(rwlock, false, true, null, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_tryrdlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockTryrdlock(rwlock));
}

pub fn scePthreadRwlockTrywrlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    rwlockLockCore(rwlock, true, true, null, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_trywrlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockTrywrlock(rwlock));
}

pub fn scePthreadRwlockTimedrdlock(
    rwlock: ?*RwlockHandle,
    microseconds: u32,
) callconv(abi.guest) i32 {
    rwlockLockCore(rwlock, false, false, microseconds, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn scePthreadRwlockTimedwrlock(
    rwlock: ?*RwlockHandle,
    microseconds: u32,
) callconv(abi.guest) i32 {
    rwlockLockCore(rwlock, true, false, microseconds, null) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_timedrdlock(
    rwlock: ?*RwlockHandle,
    deadline: ?*const Timespec,
) callconv(abi.guest) i32 {
    const deadline_ns = absoluteDeadline(deadline) catch return Posix.einval;
    rwlockLockCore(rwlock, false, false, null, deadline_ns) catch |err|
        return posixStatus(kernelStatus(err));
    return errno.ok;
}

pub fn pthread_rwlock_timedwrlock(
    rwlock: ?*RwlockHandle,
    deadline: ?*const Timespec,
) callconv(abi.guest) i32 {
    const deadline_ns = absoluteDeadline(deadline) catch return Posix.einval;
    rwlockLockCore(rwlock, true, false, null, deadline_ns) catch |err|
        return posixStatus(kernelStatus(err));
    return errno.ok;
}

pub fn scePthreadRwlockUnlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    rwlockUnlockCore(rwlock) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn pthread_rwlock_unlock(rwlock: ?*RwlockHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockUnlock(rwlock));
}

pub fn scePthreadRwlockattrInit(out_attr: ?*RwlockAttrHandle) callconv(abi.guest) i32 {
    const output = out_attr orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = manager.allocator.create(RwlockAttr) catch return KernelError.enomem.raw();
    attr.* = .{};
    manager.rwlock_attrs.append(manager.allocator, attr) catch {
        manager.allocator.destroy(attr);
        return KernelError.enomem.raw();
    };
    output.* = attr;
    return errno.ok;
}

pub fn pthread_rwlockattr_init(out_attr: ?*RwlockAttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockattrInit(out_attr));
}

pub fn scePthreadRwlockattrDestroy(out_attr: ?*RwlockAttrHandle) callconv(abi.guest) i32 {
    const output = out_attr orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    const index = findIndex(RwlockAttr, manager.rwlock_attrs.items, output.*) orelse {
        manager.lock.unlock();
        return KernelError.einval.raw();
    };
    const attr = manager.rwlock_attrs.orderedRemove(index);
    output.* = null;
    manager.lock.unlock();
    manager.allocator.destroy(attr);
    return errno.ok;
}

pub fn pthread_rwlockattr_destroy(out_attr: ?*RwlockAttrHandle) callconv(abi.guest) i32 {
    return posixStatus(scePthreadRwlockattrDestroy(out_attr));
}

pub fn scePthreadRwlockattrGettype(
    attr_raw: ?*const RwlockAttrHandle,
    output: ?*i32,
) callconv(abi.guest) i32 {
    const value = readRwlockAttr(attr_raw) orelse return KernelError.einval.raw();
    const type_output = output orelse return KernelError.einval.raw();
    type_output.* = value.kind;
    return errno.ok;
}

pub fn scePthreadRwlockattrSettype(attr_raw: ?*RwlockAttrHandle, kind: i32) callconv(abi.guest) i32 {
    const outer = attr_raw orelse return KernelError.einval.raw();
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.lock.lock();
    defer manager.lock.unlock();
    const attr = findPointer(RwlockAttr, manager.rwlock_attrs.items, outer.*) orelse
        return KernelError.einval.raw();
    attr.kind = kind;
    return errno.ok;
}

pub fn scePthreadBarrierInit(
    barrier: ?*BarrierHandle,
    _: ?*const anyopaque,
    count: u32,
    _: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const output = barrier orelse return KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(BarrierHandle))) {
        return KernelError.einval.raw();
    }
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.createBarrier(output, count) catch |err| return kernelStatus(err);
    return errno.ok;
}

pub fn scePthreadBarrierDestroy(barrier: ?*BarrierHandle) callconv(abi.guest) i32 {
    const output = barrier orelse return KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(BarrierHandle))) {
        return KernelError.einval.raw();
    }
    const manager = activeManager() orelse return KernelError.enosys.raw();
    manager.destroyBarrier(output) catch |err| return kernelStatus(err);
    return errno.ok;
}

/// Waits for one complete barrier generation. Exactly one participant receives
/// the FreeBSD/console `PTHREAD_BARRIER_SERIAL_THREAD` result (-1); all other
/// participants receive zero.
pub fn scePthreadBarrierWait(barrier: ?*BarrierHandle) callconv(abi.guest) i32 {
    const output = barrier orelse return KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(BarrierHandle))) {
        return KernelError.einval.raw();
    }
    const manager = activeManager() orelse return KernelError.enosys.raw();
    const object = manager.lockBarrier(output) catch |err| return kernelStatus(err);
    const observed_generation = object.generation;
    object.arrived += 1;
    if (object.arrived == object.threshold) {
        object.arrived = 0;
        const generation = advanceSequence(&object.generation);
        const waiters = object.waiters;
        object.state_lock.unlock();
        if (waiters != 0) threading.wakeWaiters(@intFromPtr(object), generation, waiters);
        return -1;
    }

    object.waiters += 1;
    object.state_lock.unlock();
    while (true) {
        _ = threading.waitCurrent(.{
            .key = @intFromPtr(object),
            .observed_sequence = observed_generation,
        }) catch |err| {
            object.state_lock.lock();
            if (object.generation != observed_generation) {
                object.waiters -= 1;
                object.state_lock.unlock();
                return errno.ok;
            }
            object.waiters -= 1;
            object.arrived -= 1;
            object.state_lock.unlock();
            return kernelStatus(err);
        };
        object.state_lock.lock();
        if (object.generation != observed_generation) {
            object.waiters -= 1;
            object.state_lock.unlock();
            return errno.ok;
        }
        object.state_lock.unlock();
    }
}

/// The kernel primitive a libc builds its own locks on.
///
/// Reported as unimplemented. Every lock a title actually takes goes through
/// the pthread entry points above, which are backed by the manager here;
/// answering this one would put a second, unrelated set of wait queues beside
/// them, and a thread blocked in one would be invisible to the other. A module
/// links against it, which is why it is registered at all.
fn umtxOp() callconv(abi.guest) i64 {
    runtime_api.setPosixErrno(errno.Posix.enosys);
    return -1;
}

pub const exports = [_]symbols.Export{
    .{ .name = "_umtx_op", .function = trace.wrap("_umtx_op", &umtxOp), .expect_id = "04AjkP0jO9U" },
    .{ .name = "scePthreadMutexInit", .function = trace.wrap("scePthreadMutexInit", &scePthreadMutexInit), .expect_id = "cmo1RIYva9o" },
    .{ .name = "pthread_mutex_init", .function = trace.wrap("pthread_mutex_init", &pthread_mutex_init), .expect_id = "ttHNfU+qDBU" },
    .{ .name = "scePthreadMutexDestroy", .function = trace.wrap("scePthreadMutexDestroy", &scePthreadMutexDestroy), .expect_id = "2Of0f+3mhhE" },
    .{ .name = "pthread_mutex_destroy", .function = trace.wrap("pthread_mutex_destroy", &pthread_mutex_destroy), .expect_id = "ltCfaGr2JGE" },
    .{ .name = "scePthreadMutexLock", .function = trace.wrap("scePthreadMutexLock", &scePthreadMutexLock), .expect_id = "9UK1vLZQft4" },
    .{ .name = "pthread_mutex_lock", .function = trace.wrap("pthread_mutex_lock", &pthread_mutex_lock), .expect_id = "7H0iTOciTLo" },
    .{ .name = "scePthreadMutexTrylock", .function = trace.wrap("scePthreadMutexTrylock", &scePthreadMutexTrylock), .expect_id = "upoVrzMHFeE" },
    .{ .name = "pthread_mutex_trylock", .function = trace.wrap("pthread_mutex_trylock", &pthread_mutex_trylock), .expect_id = "K-jXhbt2gn4" },
    .{ .name = "scePthreadMutexTimedlock", .function = trace.wrap("scePthreadMutexTimedlock", &scePthreadMutexTimedlock), .expect_id = "IafI2PxcPnQ" },
    .{ .name = "pthread_mutex_timedlock", .function = trace.wrap("pthread_mutex_timedlock", &pthread_mutex_timedlock), .expect_id = "Io9+nTKXZtA" },
    .{ .name = "scePthreadMutexUnlock", .function = trace.wrap("scePthreadMutexUnlock", &scePthreadMutexUnlock), .expect_id = "tn3VlD0hG60" },
    .{ .name = "pthread_mutex_unlock", .function = trace.wrap("pthread_mutex_unlock", &pthread_mutex_unlock), .expect_id = "2Z+PpY6CaJg" },
    .{ .name = "scePthreadMutexattrInit", .function = trace.wrap("scePthreadMutexattrInit", &scePthreadMutexattrInit), .expect_id = "F8bUHwAG284" },
    .{ .name = "pthread_mutexattr_init", .function = trace.wrap("pthread_mutexattr_init", &pthread_mutexattr_init), .expect_id = "dQHWEsJtoE4" },
    .{ .name = "scePthreadMutexattrDestroy", .function = trace.wrap("scePthreadMutexattrDestroy", &scePthreadMutexattrDestroy), .expect_id = "smWEktiyyG0" },
    .{ .name = "pthread_mutexattr_destroy", .function = trace.wrap("pthread_mutexattr_destroy", &pthread_mutexattr_destroy), .expect_id = "HF7lK46xzjY" },
    .{ .name = "scePthreadMutexattrSettype", .function = trace.wrap("scePthreadMutexattrSettype", &scePthreadMutexattrSettype), .expect_id = "iMp8QpE+XO4" },
    .{ .name = "pthread_mutexattr_settype", .function = trace.wrap("pthread_mutexattr_settype", &pthread_mutexattr_settype), .expect_id = "mDmgMOGVUqg" },
    .{ .name = "scePthreadMutexattrSetprotocol", .function = trace.wrap("scePthreadMutexattrSetprotocol", &scePthreadMutexattrSetprotocol), .expect_id = "1FGvU0i9saQ" },
    .{ .name = "pthread_mutexattr_setprotocol", .function = trace.wrap("pthread_mutexattr_setprotocol", &pthread_mutexattr_setprotocol), .expect_id = "5txKfcMUAok" },

    .{ .name = "scePthreadCondInit", .function = trace.wrap("scePthreadCondInit", &scePthreadCondInit), .expect_id = "2Tb92quprl0" },
    .{ .name = "pthread_cond_init", .function = trace.wrap("pthread_cond_init", &pthread_cond_init), .expect_id = "0TyVk4MSLt0" },
    .{ .name = "scePthreadCondDestroy", .function = trace.wrap("scePthreadCondDestroy", &scePthreadCondDestroy), .expect_id = "g+PZd2hiacg" },
    .{ .name = "pthread_cond_destroy", .function = trace.wrap("pthread_cond_destroy", &pthread_cond_destroy), .expect_id = "RXXqi4CtF8w" },
    .{ .name = "scePthreadCondWait", .function = trace.wrap("scePthreadCondWait", &scePthreadCondWait), .expect_id = "WKAXJ4XBPQ4" },
    .{ .name = "pthread_cond_wait", .function = trace.wrap("pthread_cond_wait", &pthread_cond_wait), .expect_id = "Op8TBGY5KHg" },
    .{ .name = "scePthreadCondTimedwait", .function = trace.wrap("scePthreadCondTimedwait", &scePthreadCondTimedwait), .expect_id = "BmMjYxmew1w" },
    .{ .name = "pthread_cond_timedwait", .function = trace.wrap("pthread_cond_timedwait", &pthread_cond_timedwait), .expect_id = "27bAgiJmOh0" },
    .{ .name = "scePthreadCondSignal", .function = trace.wrap("scePthreadCondSignal", &scePthreadCondSignal), .expect_id = "kDh-NfxgMtE" },
    .{ .name = "pthread_cond_signal", .function = trace.wrap("pthread_cond_signal", &pthread_cond_signal), .expect_id = "2MOy+rUfuhQ" },
    .{ .name = "scePthreadCondBroadcast", .function = trace.wrap("scePthreadCondBroadcast", &scePthreadCondBroadcast), .expect_id = "JGgj7Uvrl+A" },
    .{ .name = "pthread_cond_broadcast", .function = trace.wrap("pthread_cond_broadcast", &pthread_cond_broadcast), .expect_id = "mkx2fVhNMsg" },
    .{ .name = "scePthreadCondattrInit", .function = trace.wrap("scePthreadCondattrInit", &scePthreadCondattrInit), .expect_id = "m5-2bsNfv7s" },
    .{ .name = "pthread_condattr_init", .function = trace.wrap("pthread_condattr_init", &pthread_condattr_init), .expect_id = "mKoTx03HRWA" },
    .{ .name = "scePthreadCondattrDestroy", .function = trace.wrap("scePthreadCondattrDestroy", &scePthreadCondattrDestroy), .expect_id = "waPcxYiR3WA" },
    .{ .name = "pthread_condattr_destroy", .function = trace.wrap("pthread_condattr_destroy", &pthread_condattr_destroy), .expect_id = "dJcuQVn6-Iw" },
    .{ .name = "scePthreadCondattrSetclock", .function = trace.wrap("scePthreadCondattrSetclock", &scePthreadCondattrSetclock) },
    .{ .name = "pthread_condattr_setclock", .function = trace.wrap("pthread_condattr_setclock", &pthread_condattr_setclock), .expect_id = "EjllaAqAPZo" },

    .{ .name = "scePthreadRwlockInit", .function = trace.wrap("scePthreadRwlockInit", &scePthreadRwlockInit), .expect_id = "6ULAa0fq4jA" },
    .{ .name = "pthread_rwlock_init", .function = trace.wrap("pthread_rwlock_init", &pthread_rwlock_init), .expect_id = "ytQULN-nhL4" },
    .{ .name = "scePthreadRwlockDestroy", .function = trace.wrap("scePthreadRwlockDestroy", &scePthreadRwlockDestroy), .expect_id = "BB+kb08Tl9A" },
    .{ .name = "pthread_rwlock_destroy", .function = trace.wrap("pthread_rwlock_destroy", &pthread_rwlock_destroy), .expect_id = "1471ajPzxh0" },
    .{ .name = "scePthreadRwlockRdlock", .function = trace.wrap("scePthreadRwlockRdlock", &scePthreadRwlockRdlock), .expect_id = "Ox9i0c7L5w0" },
    .{ .name = "pthread_rwlock_rdlock", .function = trace.wrap("pthread_rwlock_rdlock", &pthread_rwlock_rdlock), .expect_id = "iGjsr1WAtI0" },
    .{ .name = "scePthreadRwlockWrlock", .function = trace.wrap("scePthreadRwlockWrlock", &scePthreadRwlockWrlock), .expect_id = "mqdNorrB+gI" },
    .{ .name = "pthread_rwlock_wrlock", .function = trace.wrap("pthread_rwlock_wrlock", &pthread_rwlock_wrlock), .expect_id = "sIlRvQqsN2Y" },
    .{ .name = "scePthreadRwlockTryrdlock", .function = trace.wrap("scePthreadRwlockTryrdlock", &scePthreadRwlockTryrdlock) },
    .{ .name = "pthread_rwlock_tryrdlock", .function = trace.wrap("pthread_rwlock_tryrdlock", &pthread_rwlock_tryrdlock), .expect_id = "SFxTMOfuCkE" },
    .{ .name = "scePthreadRwlockTrywrlock", .function = trace.wrap("scePthreadRwlockTrywrlock", &scePthreadRwlockTrywrlock), .expect_id = "bIHoZCTomsI" },
    .{ .name = "pthread_rwlock_trywrlock", .function = trace.wrap("pthread_rwlock_trywrlock", &pthread_rwlock_trywrlock), .expect_id = "XhWHn6P5R7U" },
    .{ .name = "scePthreadRwlockTimedrdlock", .function = trace.wrap("scePthreadRwlockTimedrdlock", &scePthreadRwlockTimedrdlock) },
    .{ .name = "scePthreadRwlockTimedwrlock", .function = trace.wrap("scePthreadRwlockTimedwrlock", &scePthreadRwlockTimedwrlock) },
    .{ .name = "pthread_rwlock_timedrdlock", .function = trace.wrap("pthread_rwlock_timedrdlock", &pthread_rwlock_timedrdlock) },
    .{ .name = "pthread_rwlock_timedwrlock", .function = trace.wrap("pthread_rwlock_timedwrlock", &pthread_rwlock_timedwrlock) },
    .{ .name = "scePthreadRwlockUnlock", .function = trace.wrap("scePthreadRwlockUnlock", &scePthreadRwlockUnlock), .expect_id = "+L98PIbGttk" },
    .{ .name = "pthread_rwlock_unlock", .function = trace.wrap("pthread_rwlock_unlock", &pthread_rwlock_unlock), .expect_id = "EgmLo6EWgso" },
    .{ .name = "scePthreadRwlockattrInit", .function = trace.wrap("scePthreadRwlockattrInit", &scePthreadRwlockattrInit), .expect_id = "yOfGg-I1ZII" },
    .{ .name = "pthread_rwlockattr_init", .function = trace.wrap("pthread_rwlockattr_init", &pthread_rwlockattr_init), .expect_id = "xFebsA4YsFI" },
    .{ .name = "scePthreadRwlockattrDestroy", .function = trace.wrap("scePthreadRwlockattrDestroy", &scePthreadRwlockattrDestroy), .expect_id = "i2ifZ3fS2fo" },
    .{ .name = "pthread_rwlockattr_destroy", .function = trace.wrap("pthread_rwlockattr_destroy", &pthread_rwlockattr_destroy), .expect_id = "qsdmgXjqSgk" },
    .{ .name = "scePthreadRwlockattrGettype", .function = trace.wrap("scePthreadRwlockattrGettype", &scePthreadRwlockattrGettype) },
    .{ .name = "scePthreadRwlockattrSettype", .function = trace.wrap("scePthreadRwlockattrSettype", &scePthreadRwlockattrSettype), .expect_id = "h-OifiouBd8" },

    .{ .name = "scePthreadBarrierWait", .function = trace.wrap("scePthreadBarrierWait", &scePthreadBarrierWait), .expect_id = "t9vVyTglqHQ" },
    .{ .name = "scePthreadBarrierDestroy", .function = trace.wrap("scePthreadBarrierDestroy", &scePthreadBarrierDestroy), .expect_id = "HudB2Jv2MPY" },
    .{ .name = "scePthreadBarrierInit", .function = trace.wrap("scePthreadBarrierInit", &scePthreadBarrierInit), .expect_id = "5dgOEPsEGqw" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const memory = @import("memory");
const loader = @import("loader");

const TestContext = struct {
    address_space: memory.AddressSpace = undefined,
    tls_registry: loader.TlsRegistry = .{},
    thread_manager: threading.Manager = .{},
    sync_manager: Manager = .{},

    fn init(self: *TestContext) !void {
        self.* = .{};
        self.address_space = try memory.AddressSpace.init(testing.allocator);
        self.thread_manager.init(testing.allocator, &self.address_space, &self.tls_registry);
        self.sync_manager.init(testing.allocator);
        threading.attachManager(&self.thread_manager);
        attachManager(&self.sync_manager);
    }

    fn deinit(self: *TestContext) void {
        attachManager(null);
        threading.attachManager(null);
        self.sync_manager.deinit();
        self.thread_manager.deinit();
        self.tls_registry.deinit(testing.allocator);
        self.address_space.deinit();
    }
};

const TestWaitBackend = struct {
    fail_wait: bool = false,
    last_request: ?threading.WaitRequest = null,

    fn start(_: ?*anyopaque, _: threading.StartRequest) threading.BackendError!void {
        return error.Unsupported;
    }

    fn wait(raw: ?*anyopaque, request: threading.WaitRequest) threading.BackendError!threading.WaitResult {
        const self: *TestWaitBackend = @ptrCast(@alignCast(raw.?));
        self.last_request = request;
        if (self.fail_wait) return error.WaitFailed;
        return .timed_out;
    }

    fn value(self: *TestWaitBackend) threading.Backend {
        return .{
            .context = self,
            .start_fn = &start,
            .wait_fn = &wait,
        };
    }
};

test "recursive mutexes preserve ownership and reject busy destruction" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("mutex-owner");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();

    var attr: MutexAttrHandle = null;
    try testing.expectEqual(errno.ok, pthread_mutexattr_init(&attr));
    try testing.expectEqual(errno.ok, pthread_mutexattr_settype(&attr, 2));
    var mutex: MutexHandle = null;
    try testing.expectEqual(errno.ok, pthread_mutex_init(&mutex, &attr));
    try testing.expectEqual(errno.ok, pthread_mutex_lock(&mutex));
    try testing.expectEqual(errno.ok, pthread_mutex_lock(&mutex));
    try testing.expectEqual(Posix.ebusy, pthread_mutex_destroy(&mutex));
    try testing.expectEqual(errno.ok, pthread_mutex_unlock(&mutex));
    try testing.expectEqual(errno.ok, pthread_mutex_unlock(&mutex));
    try testing.expectEqual(errno.ok, pthread_mutex_destroy(&mutex));
    try testing.expectEqual(errno.ok, pthread_mutexattr_destroy(&attr));
}

test "default mutexes keep nested Gen5 CRT guard locks balanced" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("default-nested");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();

    var mutex: MutexHandle = null;
    try testing.expectEqual(errno.ok, scePthreadMutexInit(&mutex, null, null));
    try testing.expectEqual(errno.ok, scePthreadMutexLock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexTrylock(&mutex));
    try testing.expectEqual(@as(u32, 2), mutex.?.recursion);
    try testing.expectEqual(errno.ok, scePthreadMutexUnlock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexUnlock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexDestroy(&mutex));
}

test "default blocking self-lock does not accumulate recursion" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("default-slow-path");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();

    var mutex: MutexHandle = null;
    try testing.expectEqual(errno.ok, scePthreadMutexInit(&mutex, null, null));
    try testing.expectEqual(errno.ok, scePthreadMutexLock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexLock(&mutex));
    try testing.expectEqual(@as(u32, 1), mutex.?.recursion);
    try testing.expectEqual(errno.ok, scePthreadMutexUnlock(&mutex));
    try testing.expectEqual(@as(u64, 0), mutex.?.owner);
    try testing.expectEqual(errno.ok, scePthreadMutexLock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexUnlock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexDestroy(&mutex));
}

test "explicit error-checking mutex remains strict on self lock" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("errorcheck");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();

    var attr: MutexAttrHandle = null;
    try testing.expectEqual(errno.ok, scePthreadMutexattrInit(&attr));
    try testing.expectEqual(errno.ok, scePthreadMutexattrSettype(&attr, 1));
    var mutex: MutexHandle = null;
    try testing.expectEqual(errno.ok, scePthreadMutexInit(&mutex, &attr, null));
    try testing.expectEqual(errno.ok, scePthreadMutexLock(&mutex));
    try testing.expectEqual(KernelError.ebusy.raw(), scePthreadMutexTrylock(&mutex));
    try testing.expectEqual(KernelError.edeadlk.raw(), scePthreadMutexLock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexUnlock(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexDestroy(&mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexattrDestroy(&attr));
}

test "static adaptive mutex initializer preserves its ABI type" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("static-adaptive");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();

    var raw_mutex_handle: usize = 1;
    const mutex: *MutexHandle = @ptrCast(&raw_mutex_handle);
    try testing.expectEqual(errno.ok, scePthreadMutexLock(mutex));
    try testing.expectEqual(@as(i32, 4), mutex.*.?.kind);
    try testing.expectEqual(MutexOrigin.static_adaptive, mutex.*.?.origin);
    try testing.expectEqual(errno.ok, scePthreadMutexUnlock(mutex));
    try testing.expectEqual(errno.ok, scePthreadMutexDestroy(mutex));
}

test "re-initializing a live object succeeds and resets its state" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("reinit");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();

    // Titles re-initialize condition variables and mutexes that are already
    // live. Refusing turns into an uncaught exception in the guest's own
    // runtime, so initialization has to succeed.
    var cond: CondHandle = null;
    try testing.expectEqual(errno.ok, scePthreadCondInit(&cond, null, null));
    const first = cond;
    try testing.expectEqual(errno.ok, scePthreadCondInit(&cond, null, null));
    // The same object is reused rather than leaked and replaced.
    try testing.expectEqual(first, cond);
    try testing.expectEqual(errno.ok, scePthreadCondDestroy(&cond));

    var mutex: MutexHandle = null;
    try testing.expectEqual(errno.ok, pthread_mutex_init(&mutex, null));
    const first_mutex = mutex;
    try testing.expectEqual(errno.ok, pthread_mutex_lock(&mutex));
    // Re-initialization clears ownership, so the mutex is free afterwards.
    try testing.expectEqual(errno.ok, pthread_mutex_init(&mutex, null));
    try testing.expectEqual(first_mutex, mutex);
    try testing.expectEqual(errno.ok, pthread_mutex_lock(&mutex));
    try testing.expectEqual(errno.ok, pthread_mutex_unlock(&mutex));
    try testing.expectEqual(errno.ok, pthread_mutex_destroy(&mutex));

    var rwlock: RwlockHandle = null;
    try testing.expectEqual(errno.ok, pthread_rwlock_init(&rwlock, null));
    const first_rwlock = rwlock;
    try testing.expectEqual(errno.ok, pthread_rwlock_init(&rwlock, null));
    try testing.expectEqual(first_rwlock, rwlock);
    try testing.expectEqual(errno.ok, pthread_rwlock_destroy(&rwlock));
}

test "timed condition wait reacquires its mutex" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("cond-owner");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();
    var backend = TestWaitBackend{};
    context.thread_manager.setBackend(backend.value());

    var mutex: MutexHandle = null;
    var attr: CondAttrHandle = null;
    var cond: CondHandle = null;
    try testing.expectEqual(errno.ok, pthread_condattr_init(&attr));
    try testing.expectEqual(errno.ok, pthread_condattr_setclock(&attr, 4));
    try testing.expectEqual(errno.ok, pthread_cond_init(&cond, &attr));
    try testing.expectEqual(errno.ok, pthread_mutex_lock(&mutex));
    const deadline = Timespec{ .tv_sec = 1, .tv_nsec = 0 };
    try testing.expectEqual(Posix.etimedout, pthread_cond_timedwait(&cond, &mutex, &deadline));
    try testing.expectEqual(@as(i32, 4), backend.last_request.?.clock_id);
    // Unlock succeeds only if timedwait restored ownership before returning.
    try testing.expectEqual(errno.ok, pthread_mutex_unlock(&mutex));
    try testing.expectEqual(errno.ok, pthread_cond_destroy(&cond));
    try testing.expectEqual(errno.ok, pthread_condattr_destroy(&attr));
    try testing.expectEqual(errno.ok, pthread_mutex_destroy(&mutex));
}

test "condition wait adopts an untracked uncontended fast-path owner" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("cond-fast-path");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();
    var backend = TestWaitBackend{};
    context.thread_manager.setBackend(backend.value());

    var mutex: MutexHandle = null;
    var cond: CondHandle = null;
    try testing.expectEqual(errno.ok, pthread_mutex_init(&mutex, null));
    try testing.expectEqual(errno.ok, pthread_cond_init(&cond, null));
    const deadline = Timespec{ .tv_sec = 1, .tv_nsec = 0 };
    try testing.expectEqual(Posix.etimedout, pthread_cond_timedwait(&cond, &mutex, &deadline));
    // Reacquisition proves the adopted owner took the ordinary wait path.
    try testing.expectEqual(errno.ok, pthread_mutex_unlock(&mutex));
    try testing.expectEqual(errno.ok, pthread_cond_destroy(&cond));
    try testing.expectEqual(errno.ok, pthread_mutex_destroy(&mutex));
}

test "condition wait failure restores ownership and waiter counts" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("cond-failure");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();
    var backend = TestWaitBackend{ .fail_wait = true };
    context.thread_manager.setBackend(backend.value());

    var mutex: MutexHandle = null;
    var cond: CondHandle = null;
    try testing.expectEqual(errno.ok, pthread_mutex_lock(&mutex));
    try testing.expectEqual(Posix.eio, pthread_cond_wait(&cond, &mutex));
    // Both operations prove that the error path restored ownership and removed
    // the condition waiter's lifecycle reservation.
    try testing.expectEqual(errno.ok, pthread_mutex_unlock(&mutex));
    try testing.expectEqual(errno.ok, pthread_cond_destroy(&cond));
    try testing.expectEqual(errno.ok, pthread_mutex_destroy(&mutex));
}

test "rwlock tracks reader and writer ownership" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    const thread = try context.thread_manager.prepareInitialThread("rw-owner");
    defer context.thread_manager.releaseInitialThread(thread.handle) catch {};
    try context.thread_manager.enter(thread.handle);
    defer context.thread_manager.leave();

    var rwlock: RwlockHandle = null;
    try testing.expectEqual(errno.ok, pthread_rwlock_rdlock(&rwlock));
    try testing.expectEqual(Posix.ebusy, pthread_rwlock_trywrlock(&rwlock));
    try testing.expectEqual(errno.ok, pthread_rwlock_unlock(&rwlock));
    try testing.expectEqual(errno.ok, pthread_rwlock_wrlock(&rwlock));
    try testing.expectEqual(Posix.ebusy, pthread_rwlock_tryrdlock(&rwlock));
    try testing.expectEqual(errno.ok, pthread_rwlock_unlock(&rwlock));
    try testing.expectEqual(errno.ok, pthread_rwlock_destroy(&rwlock));
}

test "synchronization exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findById("7H0iTOciTLo", .function) != null);
    try testing.expect(db.findById("27bAgiJmOh0", .function) != null);
    try testing.expect(db.findById("1471ajPzxh0", .function) != null);
}
