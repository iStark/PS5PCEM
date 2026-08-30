// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! User-level thread runtime used by title job systems.
//!
//! A missing import here is a hard link failure: engines treat the whole task
//! system as unavailable. Guest ULTs are scheduled as ordinary pthreads, while
//! mutexes, semaphores and queues keep their state on the host keyed by the
//! firmware objects the title allocated.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");
const kernel_memory = @import("kernel_memory.zig");
const kernel_threading = @import("kernel_threading.zig");

const error_null: i32 = @bitCast(@as(u32, 0x8081_0001));
const error_alignment: i32 = @bitCast(@as(u32, 0x8081_0002));
const error_range: i32 = @bitCast(@as(u32, 0x8081_0003));
const error_invalid: i32 = @bitCast(@as(u32, 0x8081_0004));
const error_state: i32 = @bitCast(@as(u32, 0x8081_0006));
const error_busy: i32 = @bitCast(@as(u32, 0x8081_0007));
const error_again: i32 = @bitCast(@as(u32, 0x8081_0008));

const maximum_objects = 256;
const runtime_bytes: usize = 4096;
const ulthread_bytes: usize = 512;
const pool_bytes: usize = 256;
const queue_pool_bytes: usize = 512;
const mutex_bytes: usize = 256;
const semaphore_bytes: usize = 256;

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

const MutexOptParam = extern struct {
    reserved_header: [2]u32 = .{ 0, 0 },
    attribute: u32 = 0,
    reserved: u32 = 0,
};

const Runtime = struct {
    address: u64 = 0,
    max_ulthreads: u32 = 0,
    workers: u32 = 0,
};

const WaitingPool = struct {
    address: u64 = 0,
};

const QueueDataPool = struct {
    address: u64 = 0,
    num_data: u32 = 0,
    data_size: u64 = 0,
};

const HostMutex = struct {
    address: u64 = 0,
    inner: Lock = .{},
    owner: ?std.Thread.Id = null,
    depth: u32 = 0,

    fn lock(self: *HostMutex) void {
        const me = std.Thread.getCurrentId();
        while (true) {
            self.inner.lock();
            if (self.depth == 0 or self.owner == me) {
                self.owner = me;
                self.depth += 1;
                self.inner.unlock();
                return;
            }
            self.inner.unlock();
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *HostMutex) bool {
        const me = std.Thread.getCurrentId();
        self.inner.lock();
        defer self.inner.unlock();
        if (self.depth == 0 or self.owner != me) return false;
        self.depth -= 1;
        if (self.depth == 0) self.owner = null;
        return true;
    }
};

const Semaphore = struct {
    address: u64 = 0,
    inner: Lock = .{},
    resources: i32 = 0,
    waiters: u32 = 0,
    alive: bool = false,
};

const Queue = struct {
    address: u64 = 0,
    data_size: u64 = 0,
    capacity: u32 = 0,
    count: u32 = 0,
    head: u32 = 0,
    storage: []u8 = &.{},
    inner: Lock = .{},
};

const Ulthread = struct {
    address: u64 = 0,
    entry: u64 = 0,
    argument: u64 = 0,
    thread: kernel_threading.ThreadHandle = null,
};

var table_lock: Lock = .{};
var runtimes: [maximum_objects]Runtime = [_]Runtime{.{}} ** maximum_objects;
var waiting_pools: [maximum_objects]WaitingPool = [_]WaitingPool{.{}} ** maximum_objects;
var queue_data_pools: [maximum_objects]QueueDataPool = [_]QueueDataPool{.{}} ** maximum_objects;
var mutexes: [maximum_objects]HostMutex = [_]HostMutex{.{}} ** maximum_objects;
var semaphores: [maximum_objects]Semaphore = [_]Semaphore{.{}} ** maximum_objects;
var queues: [maximum_objects]Queue = [_]Queue{.{}} ** maximum_objects;
var ulthreads: [maximum_objects]Ulthread = [_]Ulthread{.{}} ** maximum_objects;

fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn clearGuest(pointer: ?*anyopaque, size: usize) void {
    const object = pointer orelse return;
    const address = @intFromPtr(object);
    if (!kernel_memory.isGuestRangeAccessible(address, size)) return;
    const bytes: [*]u8 = @ptrCast(object);
    @memset(bytes[0..size], 0);
}

fn findSlot(comptime T: type, table: []T, address: u64) ?*T {
    for (table) |*slot| {
        if (slot.address == address) return slot;
    }
    return null;
}

fn claimSlot(comptime T: type, table: []T, address: u64) ?*T {
    if (findSlot(T, table, address) != null) return null;
    for (table) |*slot| {
        if (slot.address != 0) continue;
        slot.address = address;
        return slot;
    }
    return null;
}

fn ultInitialize() callconv(abi.guest) i32 {
    return errno.ok;
}

fn ultFinalize() callconv(abi.guest) i32 {
    reset();
    return errno.ok;
}

fn ultUlthreadRuntimeOptParamInitialize(opt: ?*[128]u8, _: u32) callconv(abi.guest) i32 {
    const output = opt orelse return error_null;
    @memset(output, 0);
    return errno.ok;
}

fn ultUlthreadRuntimeGetWorkAreaSize(max_ulthread: u32, workers: u32) callconv(abi.guest) u64 {
    return alignUp(@as(u64, max_ulthread) * 256 + @as(u64, workers) * 16 * 1024, 8);
}

fn ultUlthreadRuntimeCreate(
    runtime: ?*anyopaque,
    _: ?[*:0]const u8,
    max_ulthread: u32,
    workers: u32,
    _: ?*anyopaque,
    _: ?*const anyopaque,
    _: u32,
) callconv(abi.guest) i32 {
    const object = runtime orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    const slot = claimSlot(Runtime, &runtimes, @intFromPtr(object)) orelse return error_state;
    slot.max_ulthreads = max_ulthread;
    slot.workers = workers;
    clearGuest(object, runtime_bytes);
    return errno.ok;
}

fn ulthreadStart(argument: ?*anyopaque) callconv(abi.guest) ?*anyopaque {
    const thread: *Ulthread = @ptrCast(@alignCast(argument.?));
    const entry: *const fn (u64) callconv(abi.guest) i32 = @ptrFromInt(thread.entry);
    const status = entry(thread.argument);
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, status))));
}

fn ultUlthreadCreate(
    ulthread: ?*anyopaque,
    name: ?[*:0]const u8,
    entry: ?*const fn (u64) callconv(abi.guest) i32,
    argument: u64,
    context: ?*anyopaque,
    _: u64,
    runtime: ?*anyopaque,
    _: ?*const anyopaque,
    _: u32,
) callconv(abi.guest) i32 {
    const object = ulthread orelse return error_null;
    const start = entry orelse return error_null;
    const runtime_object = runtime orelse return error_null;
    if (context == null) return error_null;

    table_lock.lock();
    if (findSlot(Runtime, &runtimes, @intFromPtr(runtime_object)) == null) {
        table_lock.unlock();
        return error_state;
    }
    const slot = claimSlot(Ulthread, &ulthreads, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    slot.entry = @intFromPtr(start);
    slot.argument = argument;
    slot.thread = null;
    clearGuest(object, ulthread_bytes);
    table_lock.unlock();

    var handle: kernel_threading.ThreadHandle = null;
    const status = kernel_threading.scePthreadCreate(&handle, null, @ptrCast(&ulthreadStart), slot, name);
    if (status != errno.ok) {
        table_lock.lock();
        slot.* = .{};
        table_lock.unlock();
        return error_again;
    }
    table_lock.lock();
    slot.thread = handle;
    table_lock.unlock();
    return errno.ok;
}

fn ultUlthreadJoin(ulthread: ?*anyopaque, status: ?*i32) callconv(abi.guest) i32 {
    const object = ulthread orelse return error_null;
    table_lock.lock();
    const slot = findSlot(Ulthread, &ulthreads, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    const handle = slot.thread;
    table_lock.unlock();

    var result: kernel_threading.ThreadHandle = null;
    if (kernel_threading.scePthreadJoin(handle, &result) != errno.ok) return error_state;
    if (status) |output| {
        output.* = if (result) |pointer|
            @truncate(@as(isize, @bitCast(@intFromPtr(pointer))))
        else
            0;
    }
    table_lock.lock();
    slot.* = .{};
    table_lock.unlock();
    return errno.ok;
}

fn ultWaitingQueueResourcePoolGetWorkAreaSize(num_threads: u32, num_sync: u32) callconv(abi.guest) u64 {
    return alignUp(@as(u64, num_threads + num_sync) * 256, 8);
}

fn ultWaitingQueueResourcePoolCreate(
    pool: ?*anyopaque,
    _: ?[*:0]const u8,
    _: u32,
    _: u32,
    _: ?*anyopaque,
    _: ?*const anyopaque,
    _: u32,
) callconv(abi.guest) i32 {
    const object = pool orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    _ = claimSlot(WaitingPool, &waiting_pools, @intFromPtr(object)) orelse return error_state;
    clearGuest(object, pool_bytes);
    return errno.ok;
}

fn ultWaitingQueueResourcePoolDestroy(pool: ?*anyopaque) callconv(abi.guest) i32 {
    const object = pool orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    const slot = findSlot(WaitingPool, &waiting_pools, @intFromPtr(object)) orelse return error_state;
    slot.* = .{};
    clearGuest(object, pool_bytes);
    return errno.ok;
}

fn ultQueueDataResourcePoolGetWorkAreaSize(num_data: u32, data_size: u64, num_queue: u32) callconv(abi.guest) u64 {
    return alignUp(@as(u64, num_data) * alignUp(data_size, 8) + @as(u64, num_queue) * 512, 8);
}

fn ultQueueDataResourcePoolCreate(
    pool: ?*anyopaque,
    _: ?[*:0]const u8,
    num_data: u32,
    data_size: u64,
    _: u32,
    waiting_pool: ?*anyopaque,
    _: ?*anyopaque,
    _: ?*const anyopaque,
    _: u32,
) callconv(abi.guest) i32 {
    const object = pool orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    if (waiting_pool) |wait| {
        if (findSlot(WaitingPool, &waiting_pools, @intFromPtr(wait)) == null) return error_invalid;
    }
    const slot = claimSlot(QueueDataPool, &queue_data_pools, @intFromPtr(object)) orelse return error_state;
    slot.num_data = num_data;
    slot.data_size = data_size;
    clearGuest(object, queue_pool_bytes);
    return errno.ok;
}

fn ultQueueCreate(
    queue: ?*anyopaque,
    _: ?[*:0]const u8,
    data_size: u64,
    waiting_pool: ?*anyopaque,
    data_pool: ?*anyopaque,
    _: ?*const anyopaque,
    _: u32,
) callconv(abi.guest) i32 {
    const object = queue orelse return error_null;
    const pool_object = data_pool orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    const pool = findSlot(QueueDataPool, &queue_data_pools, @intFromPtr(pool_object)) orelse return error_invalid;
    if (waiting_pool) |wait| {
        if (findSlot(WaitingPool, &waiting_pools, @intFromPtr(wait)) == null) return error_invalid;
    }
    const slot = claimSlot(Queue, &queues, @intFromPtr(object)) orelse return error_state;
    slot.data_size = data_size;
    slot.capacity = pool.num_data;
    slot.count = 0;
    slot.head = 0;
    slot.storage = &.{};
    if (slot.capacity != 0 and data_size != 0) {
        const bytes = std.math.mul(usize, slot.capacity, @intCast(data_size)) catch {
            slot.* = .{};
            return error_range;
        };
        slot.storage = std.heap.page_allocator.alloc(u8, bytes) catch {
            slot.* = .{};
            return error_again;
        };
    }
    clearGuest(object, queue_pool_bytes);
    return errno.ok;
}

fn queueItem(queue: *Queue, index: u32) []u8 {
    const size: usize = @intCast(queue.data_size);
    const offset = @as(usize, index) * size;
    return queue.storage[offset .. offset + size];
}

fn ultQueuePush(queue: ?*anyopaque, data: ?*const anyopaque) callconv(abi.guest) i32 {
    const object = queue orelse return error_null;
    table_lock.lock();
    const slot = findSlot(Queue, &queues, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    table_lock.unlock();

    if (data == null and slot.data_size != 0) return error_null;
    slot.inner.lock();
    defer slot.inner.unlock();
    if (slot.capacity != 0 and slot.count >= slot.capacity) return errno.ok;
    if (slot.storage.len != 0) {
        const index = (slot.head + slot.count) % slot.capacity;
        const destination = queueItem(slot, index);
        const source: [*]const u8 = @ptrCast(data.?);
        @memcpy(destination, source[0..destination.len]);
    }
    slot.count += 1;
    return errno.ok;
}

fn ultQueueTryPop(queue: ?*anyopaque, data: ?*anyopaque) callconv(abi.guest) i32 {
    const object = queue orelse return error_null;
    table_lock.lock();
    const slot = findSlot(Queue, &queues, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    table_lock.unlock();

    if (data == null and slot.data_size != 0) return error_null;
    slot.inner.lock();
    defer slot.inner.unlock();
    if (slot.count == 0) return error_again;
    if (slot.storage.len != 0) {
        const source = queueItem(slot, slot.head);
        const destination: [*]u8 = @ptrCast(data.?);
        @memcpy(destination[0..source.len], source);
        slot.head = (slot.head + 1) % slot.capacity;
    }
    slot.count -= 1;
    return errno.ok;
}

fn ultMutexOptParamInitialize(opt: ?*MutexOptParam, _: u32) callconv(abi.guest) i32 {
    const output = opt orelse return error_null;
    output.* = .{};
    return errno.ok;
}

fn ultMutexCreate(
    mutex: ?*anyopaque,
    _: ?[*:0]const u8,
    waiting_pool: ?*anyopaque,
    _: ?*const MutexOptParam,
    _: u32,
) callconv(abi.guest) i32 {
    const object = mutex orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    if (waiting_pool) |wait| {
        if (findSlot(WaitingPool, &waiting_pools, @intFromPtr(wait)) == null) return error_invalid;
    }
    _ = claimSlot(HostMutex, &mutexes, @intFromPtr(object)) orelse return error_state;
    clearGuest(object, mutex_bytes);
    return errno.ok;
}

fn ultMutexLock(mutex: ?*anyopaque) callconv(abi.guest) i32 {
    const object = mutex orelse return error_null;
    table_lock.lock();
    const slot = findSlot(HostMutex, &mutexes, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    table_lock.unlock();
    slot.lock();
    return errno.ok;
}

fn ultMutexUnlock(mutex: ?*anyopaque) callconv(abi.guest) i32 {
    const object = mutex orelse return error_null;
    table_lock.lock();
    const slot = findSlot(HostMutex, &mutexes, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    table_lock.unlock();
    return if (slot.unlock()) errno.ok else error_state;
}

fn ultMutexDestroy(mutex: ?*anyopaque) callconv(abi.guest) i32 {
    const object = mutex orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    const slot = findSlot(HostMutex, &mutexes, @intFromPtr(object)) orelse return error_state;
    slot.inner.lock();
    if (slot.depth != 0) {
        slot.inner.unlock();
        return error_busy;
    }
    slot.inner.unlock();
    slot.* = .{};
    clearGuest(object, mutex_bytes);
    return errno.ok;
}

fn ultSemaphoreCreate(
    semaphore: ?*anyopaque,
    _: ?[*:0]const u8,
    initial: i32,
    waiting_pool: ?*anyopaque,
    opt: ?*const anyopaque,
    _: u32,
) callconv(abi.guest) i32 {
    const object = semaphore orelse return error_null;
    if (@intFromPtr(object) & 7 != 0) return error_alignment;
    if (opt) |parameter| {
        if (@intFromPtr(parameter) & 7 != 0) return error_alignment;
    }
    if (initial < 0) return error_range;
    table_lock.lock();
    defer table_lock.unlock();
    if (waiting_pool) |wait| {
        if (findSlot(WaitingPool, &waiting_pools, @intFromPtr(wait)) == null) return error_invalid;
    }
    const slot = claimSlot(Semaphore, &semaphores, @intFromPtr(object)) orelse return error_state;
    slot.resources = initial;
    slot.waiters = 0;
    slot.alive = true;
    clearGuest(object, semaphore_bytes);
    return errno.ok;
}

fn ultSemaphoreAcquire(semaphore: ?*anyopaque, count: i32) callconv(abi.guest) i32 {
    if (count <= 0) return error_range;
    const object = semaphore orelse return error_null;
    table_lock.lock();
    const slot = findSlot(Semaphore, &semaphores, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    table_lock.unlock();

    while (true) {
        slot.inner.lock();
        if (!slot.alive) {
            slot.inner.unlock();
            return error_state;
        }
        if (slot.resources >= count) {
            slot.resources -= count;
            slot.inner.unlock();
            return errno.ok;
        }
        slot.waiters += 1;
        slot.inner.unlock();
        std.atomic.spinLoopHint();
        slot.inner.lock();
        slot.waiters -= 1;
        slot.inner.unlock();
    }
}

fn ultSemaphoreTryAcquire(semaphore: ?*anyopaque, count: i32) callconv(abi.guest) i32 {
    if (count <= 0) return error_range;
    const object = semaphore orelse return error_null;
    table_lock.lock();
    const slot = findSlot(Semaphore, &semaphores, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    table_lock.unlock();

    slot.inner.lock();
    defer slot.inner.unlock();
    if (!slot.alive) return error_state;
    if (slot.resources < count) return error_again;
    slot.resources -= count;
    return errno.ok;
}

fn ultSemaphoreRelease(semaphore: ?*anyopaque, count: i32) callconv(abi.guest) i32 {
    if (count <= 0) return error_range;
    const object = semaphore orelse return error_null;
    table_lock.lock();
    const slot = findSlot(Semaphore, &semaphores, @intFromPtr(object)) orelse {
        table_lock.unlock();
        return error_state;
    };
    table_lock.unlock();

    slot.inner.lock();
    defer slot.inner.unlock();
    if (!slot.alive) return error_state;
    const next = std.math.add(i32, slot.resources, count) catch return error_range;
    slot.resources = next;
    return errno.ok;
}

fn ultSemaphoreDestroy(semaphore: ?*anyopaque) callconv(abi.guest) i32 {
    const object = semaphore orelse return error_null;
    table_lock.lock();
    defer table_lock.unlock();
    const slot = findSlot(Semaphore, &semaphores, @intFromPtr(object)) orelse return error_state;
    slot.inner.lock();
    defer slot.inner.unlock();
    if (slot.waiters != 0) return error_busy;
    slot.alive = false;
    slot.address = 0;
    slot.resources = 0;
    return errno.ok;
}

pub fn reset() void {
    table_lock.lock();
    defer table_lock.unlock();
    for (&queues) |*queue| {
        if (queue.storage.len != 0) std.heap.page_allocator.free(queue.storage);
        queue.* = .{};
    }
    runtimes = [_]Runtime{.{}} ** maximum_objects;
    waiting_pools = [_]WaitingPool{.{}} ** maximum_objects;
    queue_data_pools = [_]QueueDataPool{.{}} ** maximum_objects;
    mutexes = [_]HostMutex{.{}} ** maximum_objects;
    semaphores = [_]Semaphore{.{}} ** maximum_objects;
    ulthreads = [_]Ulthread{.{}} ** maximum_objects;
}

const exports = [_]symbols.Export{
    .{ .name = "sceUltInitialize", .function = trace.wrap("sceUltInitialize", &ultInitialize), .id_override = "hZIg1EWGsHM" },
    .{ .name = "sceUltFinalize", .function = trace.wrap("sceUltFinalize", &ultFinalize), .id_override = "d-kSG2fLrvI" },
    .{ .name = "sceUltUlthreadRuntimeOptParamInitialize", .function = trace.wrap("sceUltUlthreadRuntimeOptParamInitialize", &ultUlthreadRuntimeOptParamInitialize), .id_override = "V2u3WLrwh64" },
    .{ .name = "sceUltUlthreadRuntimeGetWorkAreaSize", .function = trace.wrap("sceUltUlthreadRuntimeGetWorkAreaSize", &ultUlthreadRuntimeGetWorkAreaSize), .id_override = "grs2pbc2awM" },
    .{ .name = "sceUltUlthreadRuntimeCreate", .function = trace.wrap("sceUltUlthreadRuntimeCreate", &ultUlthreadRuntimeCreate), .id_override = "jw9FkZBXo-g" },
    .{ .name = "sceUltUlthreadCreate", .function = trace.wrap("sceUltUlthreadCreate", &ultUlthreadCreate), .id_override = "znI3q8S7KQ4" },
    .{ .name = "sceUltUlthreadJoin", .function = trace.wrap("sceUltUlthreadJoin", &ultUlthreadJoin), .id_override = "gCeAI57LGgI" },
    .{ .name = "sceUltWaitingQueueResourcePoolGetWorkAreaSize", .function = trace.wrap("sceUltWaitingQueueResourcePoolGetWorkAreaSize", &ultWaitingQueueResourcePoolGetWorkAreaSize), .id_override = "WIWV1Qd7PFU" },
    .{ .name = "sceUltWaitingQueueResourcePoolCreate", .function = trace.wrap("sceUltWaitingQueueResourcePoolCreate", &ultWaitingQueueResourcePoolCreate), .id_override = "YiHujOG9vXY" },
    .{ .name = "sceUltWaitingQueueResourcePoolDestroy", .function = trace.wrap("sceUltWaitingQueueResourcePoolDestroy", &ultWaitingQueueResourcePoolDestroy), .expect_id = "or55417wcDk" },
    .{ .name = "sceUltQueueDataResourcePoolGetWorkAreaSize", .function = trace.wrap("sceUltQueueDataResourcePoolGetWorkAreaSize", &ultQueueDataResourcePoolGetWorkAreaSize), .id_override = "evj9YPkS8s4" },
    .{ .name = "sceUltQueueDataResourcePoolCreate", .function = trace.wrap("sceUltQueueDataResourcePoolCreate", &ultQueueDataResourcePoolCreate), .id_override = "TFHm6-N6vks" },
    .{ .name = "sceUltQueueCreate", .function = trace.wrap("sceUltQueueCreate", &ultQueueCreate), .id_override = "9Y5keOvb6ok" },
    .{ .name = "sceUltQueuePush", .function = trace.wrap("sceUltQueuePush", &ultQueuePush), .id_override = "dUwpX3e5NDE" },
    .{ .name = "sceUltQueueTryPop", .function = trace.wrap("sceUltQueueTryPop", &ultQueueTryPop), .id_override = "uZz3ci7XYqc" },
    .{ .name = "sceUltMutexOptParamInitialize", .function = trace.wrap("sceUltMutexOptParamInitialize", &ultMutexOptParamInitialize), .id_override = "1+8t9aHLiz8" },
    .{ .name = "sceUltMutexCreate", .function = trace.wrap("sceUltMutexCreate", &ultMutexCreate), .id_override = "mmt8Sa6tL6c" },
    .{ .name = "sceUltMutexLock", .function = trace.wrap("sceUltMutexLock", &ultMutexLock), .id_override = "8hEGkR1pfr8" },
    .{ .name = "sceUltMutexUnlock", .function = trace.wrap("sceUltMutexUnlock", &ultMutexUnlock), .id_override = "h0XebKiMBtk" },
    .{ .name = "sceUltMutexDestroy", .function = trace.wrap("sceUltMutexDestroy", &ultMutexDestroy), .expect_id = "jW+HnafeS3Y" },
    .{ .name = "sceUltSemaphoreCreate", .function = trace.wrap("sceUltSemaphoreCreate", &ultSemaphoreCreate), .id_override = "h5QlIYj+Ro8" },
    .{ .name = "sceUltSemaphoreAcquire", .function = trace.wrap("sceUltSemaphoreAcquire", &ultSemaphoreAcquire), .id_override = "QAH1ofI97vU" },
    .{ .name = "sceUltSemaphoreTryAcquire", .function = trace.wrap("sceUltSemaphoreTryAcquire", &ultSemaphoreTryAcquire), .id_override = "HA1Ldbi3lPY" },
    .{ .name = "sceUltSemaphoreRelease", .function = trace.wrap("sceUltSemaphoreRelease", &ultSemaphoreRelease), .id_override = "lbtk5X1mecw" },
    .{ .name = "sceUltSemaphoreDestroy", .function = trace.wrap("sceUltSemaphoreDestroy", &ultSemaphoreDestroy), .id_override = "izXyehpoZGo" },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libSceUlt" }, .{ .name = "libSceUlt" }, &exports);
}

test "Ult initialize, mutex, queue and semaphore keep guest objects coherent" {
    reset();
    defer reset();
    try std.testing.expectEqual(errno.ok, ultInitialize());

    var opt: [128]u8 = @splat(0xaa);
    try std.testing.expectEqual(errno.ok, ultUlthreadRuntimeOptParamInitialize(&opt, 0));
    try std.testing.expectEqual(@as(u8, 0), opt[0]);
    try std.testing.expect(ultUlthreadRuntimeGetWorkAreaSize(4, 2) >= 4 * 256);

    var runtime: [runtime_bytes]u8 = undefined;
    try std.testing.expectEqual(errno.ok, ultUlthreadRuntimeCreate(&runtime, "rt", 4, 2, &runtime, null, 0));

    var waiting: [pool_bytes]u8 = undefined;
    try std.testing.expectEqual(errno.ok, ultWaitingQueueResourcePoolCreate(&waiting, "wait", 4, 4, &waiting, null, 0));

    var data_pool: [queue_pool_bytes]u8 = undefined;
    try std.testing.expectEqual(
        errno.ok,
        ultQueueDataResourcePoolCreate(&data_pool, "data", 2, 4, 1, &waiting, &data_pool, null, 0),
    );

    var queue: [queue_pool_bytes]u8 = undefined;
    try std.testing.expectEqual(errno.ok, ultQueueCreate(&queue, "q", 4, &waiting, &data_pool, null, 0));
    const first: u32 = 0x1122_3344;
    const second: u32 = 0xaabb_ccdd;
    try std.testing.expectEqual(errno.ok, ultQueuePush(&queue, &first));
    try std.testing.expectEqual(errno.ok, ultQueuePush(&queue, &second));
    var popped: u32 = 0;
    try std.testing.expectEqual(errno.ok, ultQueueTryPop(&queue, &popped));
    try std.testing.expectEqual(first, popped);
    try std.testing.expectEqual(errno.ok, ultQueueTryPop(&queue, &popped));
    try std.testing.expectEqual(second, popped);
    try std.testing.expectEqual(error_again, ultQueueTryPop(&queue, &popped));

    var mutex: [mutex_bytes]u8 = undefined;
    try std.testing.expectEqual(errno.ok, ultMutexCreate(&mutex, "m", &waiting, null, 0));
    try std.testing.expectEqual(errno.ok, ultMutexLock(&mutex));
    try std.testing.expectEqual(error_busy, ultMutexDestroy(&mutex));
    try std.testing.expectEqual(errno.ok, ultMutexLock(&mutex));
    try std.testing.expectEqual(errno.ok, ultMutexUnlock(&mutex));
    try std.testing.expectEqual(errno.ok, ultMutexUnlock(&mutex));
    try std.testing.expectEqual(errno.ok, ultMutexDestroy(&mutex));

    var semaphore: [semaphore_bytes]u8 align(8) = undefined;
    try std.testing.expectEqual(errno.ok, ultSemaphoreCreate(&semaphore, "s", 1, &waiting, null, 0));
    try std.testing.expectEqual(errno.ok, ultSemaphoreTryAcquire(&semaphore, 1));
    try std.testing.expectEqual(error_again, ultSemaphoreTryAcquire(&semaphore, 1));
    try std.testing.expectEqual(errno.ok, ultSemaphoreRelease(&semaphore, 1));
    try std.testing.expectEqual(errno.ok, ultSemaphoreDestroy(&semaphore));
    try std.testing.expectEqual(errno.ok, ultWaitingQueueResourcePoolDestroy(&waiting));
    try std.testing.expectEqual(errno.ok, ultFinalize());
}

test "Ult exports resolve the observed identifiers" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    inline for (&.{
        "hZIg1EWGsHM",
        "d-kSG2fLrvI",
        "znI3q8S7KQ4",
        "mmt8Sa6tL6c",
        "jW+HnafeS3Y",
        "h5QlIYj+Ro8",
        "9Y5keOvb6ok",
        "or55417wcDk",
    }) |id| {
        try std.testing.expect(db.findById(id, .function) != null);
    }
}
