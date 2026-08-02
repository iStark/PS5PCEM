// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Kernel event queues with user-edge registration and dispatcher-backed waits.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const threading = @import("kernel_threading.zig");

const KernelError = errno.KernelError;
const maximum_queues = 64;
const maximum_events = 64;
const user_filter: i16 = -11;
const event_add: u16 = 0x01;
const event_clear: u16 = 0x20;
const wait_key_prefix: u64 = 0x4551_0000_0000_0000;

pub const Event = extern struct {
    ident: u64 = 0,
    filter: i16 = 0,
    flags: u16 = 0,
    fflags: u32 = 0,
    data: i64 = 0,
    user_data: u64 = 0,
};

comptime {
    if (@sizeOf(Event) != 32) @compileError("SceKernelEvent ABI size must be 32 bytes");
}

const Registration = struct {
    active: bool = false,
    ident: u64 = 0,
};

const Queue = struct {
    active: bool = false,
    handle: i64 = 0,
    registrations: [maximum_events]Registration = [_]Registration{.{}} ** maximum_events,
    pending: [maximum_events]Event = [_]Event{.{}} ** maximum_events,
    pending_head: usize = 0,
    pending_count: usize = 0,
    sequence: u64 = 0,
};

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

var lock: Lock = .{};
var queues: [maximum_queues]Queue = [_]Queue{.{}} ** maximum_queues;
var next_handle: i64 = 1;

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    queues = [_]Queue{.{}} ** maximum_queues;
    next_handle = 1;
}

fn findQueue(handle: i64) ?*Queue {
    for (&queues) |*queue| {
        if (queue.active and queue.handle == handle) return queue;
    }
    return null;
}

fn waitKey(handle: i64) u64 {
    return wait_key_prefix ^ @as(u64, @bitCast(handle));
}

fn createEqueue(output: ?*i64, name: ?[*:0]const u8) callconv(abi.guest) i32 {
    const handle_out = output orelse return KernelError.einval.raw();
    if (name == null) return KernelError.einval.raw();

    lock.lock();
    defer lock.unlock();
    for (&queues) |*queue| {
        if (queue.active) continue;
        queue.* = .{ .active = true, .handle = next_handle };
        next_handle +|= 1;
        handle_out.* = queue.handle;
        return errno.ok;
    }
    return KernelError.emfile.raw();
}

fn deleteEqueue(handle: i64) callconv(abi.guest) i32 {
    lock.lock();
    const queue = findQueue(handle) orelse {
        lock.unlock();
        return KernelError.ebadf.raw();
    };
    const sequence = queue.sequence +% 1;
    queue.* = .{};
    lock.unlock();
    threading.wakeWaiters(waitKey(handle), sequence, std.math.maxInt(usize));
    return errno.ok;
}

fn addUserEventEdge(handle: i64, id: i32) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    const ident: u64 = @bitCast(@as(i64, id));
    for (&queue.registrations) |*registration| {
        if (registration.active and registration.ident == ident) return KernelError.eexist.raw();
    }
    for (&queue.registrations) |*registration| {
        if (registration.active) continue;
        registration.* = .{ .active = true, .ident = ident };
        return errno.ok;
    }
    return KernelError.enospc.raw();
}

fn deleteUserEvent(handle: i64, id: i32) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    const ident: u64 = @bitCast(@as(i64, id));
    for (&queue.registrations) |*registration| {
        if (!registration.active or registration.ident != ident) continue;
        registration.* = .{};
        return errno.ok;
    }
    return KernelError.enoent.raw();
}

fn triggerUserEvent(handle: i64, id: i32, user_data: u64) callconv(abi.guest) i32 {
    lock.lock();
    const queue = findQueue(handle) orelse {
        lock.unlock();
        return KernelError.ebadf.raw();
    };
    const ident: u64 = @bitCast(@as(i64, id));
    var registered = false;
    for (queue.registrations) |registration| {
        if (registration.active and registration.ident == ident) {
            registered = true;
            break;
        }
    }
    if (!registered) {
        lock.unlock();
        return KernelError.enoent.raw();
    }
    if (queue.pending_count == maximum_events) {
        lock.unlock();
        return KernelError.enospc.raw();
    }
    const index = (queue.pending_head + queue.pending_count) % maximum_events;
    queue.pending[index] = .{
        .ident = ident,
        .filter = user_filter,
        .flags = event_add | event_clear,
        .user_data = user_data,
    };
    queue.pending_count += 1;
    queue.sequence +%= 1;
    const sequence = queue.sequence;
    lock.unlock();
    threading.wakeWaiters(waitKey(handle), sequence, 1);
    return errno.ok;
}

fn dequeue(handle: i64, output: [*]Event, capacity: usize, observed: *u64) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    observed.* = queue.sequence;
    const count = @min(capacity, queue.pending_count);
    for (0..count) |index| {
        output[index] = queue.pending[queue.pending_head];
        queue.pending[queue.pending_head] = .{};
        queue.pending_head = (queue.pending_head + 1) % maximum_events;
    }
    queue.pending_count -= count;
    return @intCast(count);
}

fn waitEqueue(
    handle: i64,
    events: ?[*]Event,
    capacity: i32,
    out_count: ?*i32,
    timeout_microseconds: ?*const u32,
) callconv(abi.guest) i32 {
    const output = events orelse return KernelError.efault.raw();
    const count_output = out_count orelse return KernelError.efault.raw();
    if (capacity < 1) return KernelError.einval.raw();
    const event_capacity: usize = @intCast(capacity);

    while (true) {
        var observed: u64 = 0;
        const delivered = dequeue(handle, output, event_capacity, &observed);
        if (delivered < 0) return delivered;
        count_output.* = delivered;
        if (delivered != 0) return errno.ok;

        const timeout = if (timeout_microseconds) |value| @as(?u64, value.*) else null;
        if (timeout == 0) return KernelError.etimedout.raw();
        const result = threading.waitCurrent(.{
            .key = waitKey(handle),
            .observed_sequence = observed,
            .timeout_microseconds = timeout,
        }) catch return KernelError.enosys.raw();
        if (result == .timed_out) return KernelError.etimedout.raw();
    }
}

fn getEventId(event: ?*const Event) callconv(abi.guest) u64 {
    return if (event) |value| value.ident else 0;
}

fn getEventFilter(event: ?*const Event) callconv(abi.guest) i32 {
    return if (event) |value| value.filter else 0;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceKernelCreateEqueue", .function = trace.wrap("sceKernelCreateEqueue", &createEqueue), .expect_id = "D0OdFMjp46I" },
    .{ .name = "sceKernelDeleteEqueue", .function = trace.wrap("sceKernelDeleteEqueue", &deleteEqueue), .expect_id = "jpFjmgAC5AE" },
    .{ .name = "sceKernelWaitEqueue", .function = trace.wrap("sceKernelWaitEqueue", &waitEqueue), .expect_id = "fzyMKs9kim0" },
    .{ .name = "sceKernelGetEventId", .function = trace.wrap("sceKernelGetEventId", &getEventId), .expect_id = "mJ7aghmgvfc" },
    .{ .name = "sceKernelGetEventFilter", .function = trace.wrap("sceKernelGetEventFilter", &getEventFilter), .expect_id = "23CPPI1tyBY" },
    .{ .name = "sceKernelAddUserEventEdge", .function = trace.wrap("sceKernelAddUserEventEdge", &addUserEventEdge), .expect_id = "WDszmSbWuDk" },
    .{ .name = "sceKernelTriggerUserEvent", .function = trace.wrap("sceKernelTriggerUserEvent", &triggerUserEvent), .expect_id = "F6e0kwo4cnk" },
    .{ .name = "sceKernelDeleteUserEvent", .function = trace.wrap("sceKernelDeleteUserEvent", &deleteUserEvent), .expect_id = "LJDwdSNTnDg" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "user edge events round-trip through an event queue" {
    reset();
    var handle: i64 = 0;
    try std.testing.expectEqual(errno.ok, createEqueue(&handle, "test"));
    try std.testing.expectEqual(errno.ok, addUserEventEdge(handle, 7));
    try std.testing.expectEqual(errno.ok, triggerUserEvent(handle, 7, 0x1234));

    var event: [1]Event = .{.{}};
    var count: i32 = 0;
    var timeout: u32 = 0;
    try std.testing.expectEqual(errno.ok, waitEqueue(handle, &event, 1, &count, &timeout));
    try std.testing.expectEqual(@as(i32, 1), count);
    try std.testing.expectEqual(@as(u64, 7), getEventId(&event[0]));
    try std.testing.expectEqual(@as(i32, user_filter), getEventFilter(&event[0]));
    try std.testing.expectEqual(@as(u64, 0x1234), event[0].user_data);
    try std.testing.expectEqual(errno.ok, deleteEqueue(handle));
}
