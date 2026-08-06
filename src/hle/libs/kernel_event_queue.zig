// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Kernel event queues with user-edge registration and dispatcher-backed waits.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const threading = @import("kernel_threading.zig");
const runtime_api = @import("kernel_runtime.zig");

const KernelError = errno.KernelError;
const maximum_queues = 64;
const maximum_events = 64;
const user_filter: i16 = -11;
const timer_filter: i16 = -7;
pub const video_out_filter: i16 = -13;
pub const video_out_flip_ident: u64 = 6;
/// Distinct from flip; only distinctness matters for GetEventId.
pub const video_out_vblank_ident: u64 = 0x40;
pub const graphics_filter: i16 = -14;
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
    filter: i16 = user_filter,
    /// Edge-triggered registrations clear themselves once delivered; level
    /// ones stay raised until the title acts on them.
    edge: bool = true,
    /// When a timer registration next comes due, in microseconds on the shared
    /// clock. Null for everything that is not a timer.
    deadline_microseconds: ?u64 = null,
    /// Repeat interval, or null for a timer that fires once.
    period_microseconds: ?u64 = null,
    user_data: u64 = 0,
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
    return addRegistration(handle, id, .{});
}

/// Registers a level-triggered user event.
///
/// The only difference from the edge form is what happens after delivery: a
/// level event stays raised until the title clears it, an edge one clears
/// itself. Recording which kind was asked for is the whole distinction.
fn addUserEvent(handle: i64, id: i32) callconv(abi.guest) i32 {
    return addRegistration(handle, id, .{ .edge = false });
}

const RegistrationOptions = struct {
    edge: bool = true,
    filter: i16 = user_filter,
    deadline_microseconds: ?u64 = null,
    period_microseconds: ?u64 = null,
    user_data: u64 = 0,
};

fn addRegistration(handle: i64, id: i32, options: RegistrationOptions) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    const ident: u64 = @bitCast(@as(i64, id));

    for (&queue.registrations) |*registration| {
        if (registration.active and registration.ident == ident and registration.filter == options.filter) {
            return KernelError.eexist.raw();
        }
    }
    for (&queue.registrations) |*registration| {
        if (registration.active) continue;
        registration.* = .{
            .active = true,
            .ident = ident,
            .filter = options.filter,
            .edge = options.edge,
            .deadline_microseconds = options.deadline_microseconds,
            .period_microseconds = options.period_microseconds,
            .user_data = options.user_data,
        };
        return errno.ok;
    }
    return KernelError.enospc.raw();
}

/// Microseconds on the clock the rest of the firmware shares.
///
/// Null when no clock is attached, which makes timers inert rather than
/// letting them fire at an arbitrary moment.
fn nowMicroseconds() ?u64 {
    const io = runtime_api.activeIo() orelse return null;
    const nanoseconds = std.Io.Clock.awake.now(io).nanoseconds;
    if (nanoseconds <= 0) return null;
    return @intCast(@divFloor(nanoseconds, 1000));
}

/// Registers a timer that delivers an event once its interval elapses.
///
/// Timers are delivered by whoever waits on the queue rather than by a thread
/// of their own: a title arms a timer precisely so that it can wait for it, so
/// the wait is where the deadline has to be honoured. A timer nothing waits on
/// costs nothing, which is the right trade for something checked this often.
fn addTimerEvent(
    handle: i64,
    id: i32,
    microseconds: i64,
    user_data: u64,
) callconv(abi.guest) i32 {
    if (microseconds <= 0) return KernelError.einval.raw();
    const now = nowMicroseconds() orelse return KernelError.enosys.raw();
    const interval: u64 = @intCast(microseconds);

    return addRegistration(handle, id, .{
        .edge = true,
        .deadline_microseconds = now +| interval,
        .period_microseconds = interval,
        .user_data = user_data,
    });
}

/// Raises any timer that has come due, and reports when the next one is.
///
/// Returns the shortest remaining wait in microseconds, so a caller can bound
/// its sleep by the nearest deadline instead of oversleeping past it.
fn serviceTimers(queue: *Queue, now: u64) ?u64 {
    var nearest: ?u64 = null;
    for (&queue.registrations) |*registration| {
        if (!registration.active) continue;
        const deadline = registration.deadline_microseconds orelse continue;

        if (deadline > now) {
            const remaining = deadline - now;
            nearest = if (nearest) |value| @min(value, remaining) else remaining;
            continue;
        }

        if (queue.pending_count == maximum_events) continue;
        const index = (queue.pending_head + queue.pending_count) % maximum_events;
        queue.pending[index] = .{
            .ident = registration.ident,
            .filter = timer_filter,
            .flags = event_add,
            .user_data = registration.user_data,
        };
        queue.pending_count += 1;
        queue.sequence +%= 1;

        // A repeating timer re-arms from now rather than from its old deadline,
        // so a late wait cannot produce a burst of missed firings.
        if (registration.period_microseconds) |period| {
            registration.deadline_microseconds = now +| period;
            nearest = if (nearest) |value| @min(value, period) else period;
        } else {
            registration.deadline_microseconds = null;
        }
    }
    return nearest;
}

fn deleteUserEvent(handle: i64, id: i32) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    const ident: u64 = @bitCast(@as(i64, id));
    for (&queue.registrations) |*registration| {
        if (!registration.active or registration.ident != ident or registration.filter != user_filter) continue;
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
        if (registration.active and registration.ident == ident and registration.filter == user_filter) {
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

/// Registers the VideoOut flip edge used by display-worker event queues.
pub fn addVideoOutFlipEvent(handle: i64, user_data: u64) i32 {
    return addRegistration(handle, @intCast(video_out_flip_ident), .{
        .edge = true,
        .filter = video_out_filter,
        .user_data = user_data,
    });
}

pub fn deleteVideoOutFlipEvent(handle: i64) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    for (&queue.registrations) |*registration| {
        if (!registration.active or registration.ident != video_out_flip_ident or
            registration.filter != video_out_filter)
        {
            continue;
        }
        registration.* = .{};
        return errno.ok;
    }
    return KernelError.enoent.raw();
}

/// Registers one AGC completion interrupt under the identifier selected by the
/// graphics driver. Graphics uses zero; compute queues use their owner handle.
pub fn addGraphicsEvent(handle: i64, id: i32, user_data: u64) i32 {
    return addRegistration(handle, id, .{
        .edge = true,
        .filter = graphics_filter,
        .user_data = user_data,
    });
}

pub fn deleteGraphicsEvent(handle: i64, id: i32) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    const ident: u64 = @bitCast(@as(i64, id));
    for (&queue.registrations) |*registration| {
        if (!registration.active or registration.ident != ident or
            registration.filter != graphics_filter)
        {
            continue;
        }
        registration.* = .{};
        return errno.ok;
    }
    return KernelError.enoent.raw();
}

/// Publishes a completed graphics/compute submission to every matching equeue.
pub fn triggerGraphicsEvent(id: i32, context_id: u32) usize {
    var wake_handles: [maximum_queues]i64 = undefined;
    var wake_sequences: [maximum_queues]u64 = undefined;
    var wake_count: usize = 0;
    const ident: u64 = @bitCast(@as(i64, id));

    lock.lock();
    for (&queues) |*queue| {
        if (!queue.active or queue.pending_count == maximum_events) continue;
        const registration = for (queue.registrations) |candidate| {
            if (candidate.active and candidate.ident == ident and
                candidate.filter == graphics_filter)
            {
                break candidate;
            }
        } else continue;
        const index = (queue.pending_head + queue.pending_count) % maximum_events;
        queue.pending[index] = .{
            .ident = ident,
            .filter = graphics_filter,
            .flags = event_clear,
            .fflags = 1,
            .data = context_id,
            .user_data = registration.user_data,
        };
        queue.pending_count += 1;
        queue.sequence +%= 1;
        wake_handles[wake_count] = queue.handle;
        wake_sequences[wake_count] = queue.sequence;
        wake_count += 1;
    }
    lock.unlock();

    for (wake_handles[0..wake_count], wake_sequences[0..wake_count]) |handle, sequence| {
        threading.wakeWaiters(waitKey(handle), sequence, 1);
    }
    return wake_count;
}

/// Packs a flip argument into event `data` as
/// `ident | ((flip_arg & 0x0000_ffff_ffff_ffff) << 16)`. Titles then read the
/// argument with `sceVideoOutGetEventData` (`data >> 16`).
pub fn packVideoOutFlipData(flip_argument: i64) i64 {
    const payload: u64 = @as(u64, @bitCast(flip_argument)) & 0x0000_ffff_ffff_ffff;
    const bits: u64 = video_out_flip_ident | (payload << 16);
    return @bitCast(bits);
}

/// Delivers one completed flip to every equeue that registered for it.
pub fn triggerVideoOutFlip(flip_argument: i64) usize {
    var wake_handles: [maximum_queues]i64 = undefined;
    var wake_sequences: [maximum_queues]u64 = undefined;
    var wake_count: usize = 0;
    const packed_data = packVideoOutFlipData(flip_argument);

    lock.lock();
    for (&queues) |*queue| {
        if (!queue.active or queue.pending_count == maximum_events) continue;
        const registration = for (queue.registrations) |candidate| {
            if (candidate.active and candidate.ident == video_out_flip_ident and
                candidate.filter == video_out_filter)
            {
                break candidate;
            }
        } else continue;
        const index = (queue.pending_head + queue.pending_count) % maximum_events;
        queue.pending[index] = .{
            .ident = video_out_flip_ident,
            .filter = video_out_filter,
            .flags = event_add | event_clear,
            .data = packed_data,
            .user_data = registration.user_data,
        };
        queue.pending_count += 1;
        queue.sequence +%= 1;
        wake_handles[wake_count] = queue.handle;
        wake_sequences[wake_count] = queue.sequence;
        wake_count += 1;
    }
    lock.unlock();

    for (wake_handles[0..wake_count], wake_sequences[0..wake_count]) |handle, sequence| {
        threading.wakeWaiters(waitKey(handle), sequence, 1);
    }
    return wake_count;
}

fn dequeue(
    handle: i64,
    output: [*]Event,
    capacity: usize,
    observed: *u64,
    next_deadline: *?u64,
) i32 {
    lock.lock();
    defer lock.unlock();
    const queue = findQueue(handle) orelse return KernelError.ebadf.raw();
    // Timers are raised here because this is the moment someone is looking.
    next_deadline.* = if (nowMicroseconds()) |now| serviceTimers(queue, now) else null;
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
        var next_deadline: ?u64 = null;
        const delivered = dequeue(handle, output, event_capacity, &observed, &next_deadline);
        if (delivered < 0) return delivered;
        count_output.* = delivered;
        if (delivered != 0) return errno.ok;

        const requested = if (timeout_microseconds) |value| @as(?u64, value.*) else null;
        if (requested == 0) return KernelError.etimedout.raw();
        // Sleeping past a timer would deliver it late, so the wait is cut short
        // at the nearest deadline. Waking early only costs one more round.
        const timeout = if (next_deadline) |deadline|
            if (requested) |value| @min(value, deadline) else deadline
        else
            requested;
        const result = threading.waitCurrent(.{
            .key = waitKey(handle),
            .observed_sequence = observed,
            .timeout_microseconds = timeout,
        }) catch return KernelError.enosys.raw();
        // A wait cut short by a timer deadline is not a timeout for the caller:
        // the next round raises the timer and delivers it.
        if (result == .timed_out and (next_deadline == null or requested != null and
            requested.? <= next_deadline.?))
        {
            return KernelError.etimedout.raw();
        }
    }
}

fn getEventId(event: ?*const Event) callconv(abi.guest) u64 {
    return if (event) |value| value.ident else 0;
}

fn getEventFilter(event: ?*const Event) callconv(abi.guest) i32 {
    return if (event) |value| value.filter else 0;
}

fn getEventData(event: ?*const Event) callconv(abi.guest) i64 {
    return if (event) |value| value.data else 0;
}

fn getEventUserData(event: ?*const Event) callconv(abi.guest) u64 {
    return if (event) |value| value.user_data else 0;
}

/// The POSIX primitive the queue interface is built on.
///
/// Reported as unimplemented rather than answered emptily. A caller that
/// registered a change would otherwise believe it took effect, and one waiting
/// for an event would spin against a queue that can never deliver — both fail
/// far from here and with nothing to point at. The queue interface above is
/// what titles actually use; this exists because a module links against it.
fn kevent() callconv(abi.guest) i64 {
    runtime_api.setPosixErrno(errno.Posix.enosys);
    return -1;
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
    .{ .name = "sceKernelAddUserEvent", .function = trace.wrap("sceKernelAddUserEvent", &addUserEvent), .expect_id = "4R6-OvI2cEA" },
    .{ .name = "sceKernelAddTimerEvent", .function = trace.wrap("sceKernelAddTimerEvent", &addTimerEvent), .expect_id = "57ZK+ODEXWY" },
    .{ .name = "sceKernelGetEventData", .function = trace.wrap("sceKernelGetEventData", &getEventData), .expect_id = "kwGyyjohI50" },
    .{ .name = "sceKernelGetEventUserData", .function = trace.wrap("sceKernelGetEventUserData", &getEventUserData), .expect_id = "vz+pg2zdopI" },
    .{ .name = "kevent", .function = trace.wrap("kevent", &kevent), .expect_id = "RW-GEfpnsqg" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "an armed timer is delivered to whoever waits" {
    reset();
    runtime_api.attachIo(std.testing.io);
    defer runtime_api.attachIo(null);

    var handle: i64 = 0;
    try std.testing.expectEqual(errno.ok, createEqueue(&handle, "timer"));
    defer _ = deleteEqueue(handle);

    // A title arms a timer precisely so that it can wait for it, so the wait is
    // where the deadline has to be honoured.
    try std.testing.expectEqual(errno.ok, addTimerEvent(handle, 9, 500, 0xabcd));

    // Let the interval pass. Blocking would need a thread manager this test
    // does not set up; what is being checked is that the deadline is noticed at
    // all, which the non-blocking collection below does.
    const armed = nowMicroseconds().?;
    while ((nowMicroseconds() orelse armed) < armed + 1000) {}

    var event: [1]Event = .{.{}};
    var count: i32 = 0;
    var timeout: u32 = 0;
    try std.testing.expectEqual(errno.ok, waitEqueue(handle, &event, 1, &count, &timeout));
    try std.testing.expectEqual(@as(i32, 1), count);
    try std.testing.expectEqual(@as(u64, 9), getEventId(&event[0]));
    try std.testing.expectEqual(@as(i32, timer_filter), getEventFilter(&event[0]));
    try std.testing.expectEqual(@as(u64, 0xabcd), getEventUserData(&event[0]));
}

test "a timer with no interval is rejected" {
    reset();
    runtime_api.attachIo(std.testing.io);
    defer runtime_api.attachIo(null);

    var handle: i64 = 0;
    try std.testing.expectEqual(errno.ok, createEqueue(&handle, "timer"));
    defer _ = deleteEqueue(handle);

    try std.testing.expectEqual(KernelError.einval.raw(), addTimerEvent(handle, 1, 0, 0));
    try std.testing.expectEqual(KernelError.einval.raw(), addTimerEvent(handle, 1, -5, 0));
}

test "level and edge registrations are both accepted and distinct" {
    reset();
    var handle: i64 = 0;
    try std.testing.expectEqual(errno.ok, createEqueue(&handle, "mixed"));
    defer _ = deleteEqueue(handle);

    try std.testing.expectEqual(errno.ok, addUserEvent(handle, 1));
    try std.testing.expectEqual(errno.ok, addUserEventEdge(handle, 2));
    // One identifier cannot be registered twice, whichever form is used.
    try std.testing.expectEqual(KernelError.eexist.raw(), addUserEvent(handle, 2));
}

test "accessors tolerate a null event" {
    // Firmware is handed raw pointers; reading one without checking would fault
    // in host code, where the guest fault handler declines to act.
    try std.testing.expectEqual(@as(u64, 0), getEventId(null));
    try std.testing.expectEqual(@as(i64, 0), getEventData(null));
    try std.testing.expectEqual(@as(u64, 0), getEventUserData(null));
}

test "the POSIX primitive reports that it is unimplemented" {
    // Answering emptily would let a caller believe a registration took effect.
    try std.testing.expectEqual(@as(i64, -1), kevent());
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

test "VideoOut flip events retain their filter and user data" {
    reset();
    var handle: i64 = 0;
    try std.testing.expectEqual(errno.ok, createEqueue(&handle, "video-out"));
    defer _ = deleteEqueue(handle);
    try std.testing.expectEqual(errno.ok, addVideoOutFlipEvent(handle, 0x1234));
    try std.testing.expectEqual(@as(usize, 1), triggerVideoOutFlip(77));

    var event: [1]Event = .{.{}};
    var count: i32 = 0;
    var timeout: u32 = 0;
    try std.testing.expectEqual(errno.ok, waitEqueue(handle, &event, 1, &count, &timeout));
    try std.testing.expectEqual(@as(i16, video_out_filter), event[0].filter);
    try std.testing.expectEqual(video_out_flip_ident, event[0].ident);
    try std.testing.expectEqual(packVideoOutFlipData(77), event[0].data);
    try std.testing.expectEqual(@as(u64, 77), @as(u64, @bitCast(event[0].data)) >> 16);
    try std.testing.expectEqual(@as(u64, 0x1234), event[0].user_data);
}

test "graphics completion events match the registered queue identifier" {
    reset();
    var handle: i64 = 0;
    try std.testing.expectEqual(errno.ok, createEqueue(&handle, "graphics"));
    defer _ = deleteEqueue(handle);
    try std.testing.expectEqual(errno.ok, addGraphicsEvent(handle, 0x21, 0xcafe));
    try std.testing.expectEqual(@as(usize, 0), triggerGraphicsEvent(0x20, 7));
    try std.testing.expectEqual(@as(usize, 1), triggerGraphicsEvent(0x21, 9));

    var event: [1]Event = .{.{}};
    var count: i32 = 0;
    var timeout: u32 = 0;
    try std.testing.expectEqual(errno.ok, waitEqueue(handle, &event, 1, &count, &timeout));
    try std.testing.expectEqual(@as(i16, graphics_filter), event[0].filter);
    try std.testing.expectEqual(@as(u64, 0x21), event[0].ident);
    try std.testing.expectEqual(@as(u16, event_clear), event[0].flags);
    try std.testing.expectEqual(@as(u32, 1), event[0].fflags);
    try std.testing.expectEqual(@as(i64, 9), event[0].data);
    try std.testing.expectEqual(@as(u64, 0xcafe), event[0].user_data);
    try std.testing.expectEqual(errno.ok, deleteGraphicsEvent(handle, 0x21));
}
