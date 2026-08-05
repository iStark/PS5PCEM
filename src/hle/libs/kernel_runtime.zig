// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runtime-facing libkernel exports used by the genuine libc PRX.
//!
//! This module intentionally covers the narrow ABI between the system libc and
//! libkernel. Stateful facilities (TLS, errno, clocks, process parameters and
//! rtld callbacks) have concrete implementations. Filesystem and unwind APIs
//! that require subsystems the runtime does not own yet return their documented
//! error forms instead of pretending to have completed an operation.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const unwind = @import("../unwind.zig");
const modules = @import("../modules.zig");
const apr = @import("../apr.zig");
const memory_api = @import("kernel_memory.zig");
const threading = @import("kernel_threading.zig");

const KernelError = errno.KernelError;

const Timespec = extern struct {
    seconds: i64,
    nanoseconds: i64,
};

const Timeval = extern struct {
    seconds: i64,
    microseconds: i64,
};

const Timezone = extern struct {
    minutes_west: i32,
    dst_time: i32,
};

const TimeSeconds = extern struct {
    seconds: i64,
    west_seconds: u32,
    dst_seconds: u32,
};

const TlsIndex = extern struct {
    module_id: u64,
    offset: u64,
};

var stack_check_guard: u64 align(16) = 0xc0de_c0de_cafe_ba00;
var program_name: usize = 0;
threadlocal var fallback_errno: i32 = 0;
threadlocal var rtld_atexit_count: u32 = 0;
threadlocal var undelivered_exception_waits: u8 = 0;

var active_io: ?std.Io = null;
var process_start_nanoseconds: i96 = 0;
var process_param_address: std.atomic.Value(u64) = .init(0);
var application_heap_api: std.atomic.Value(u64) = .init(0);
var thread_dtors: std.atomic.Value(u64) = .init(0);
var thread_atexit_count: std.atomic.Value(u64) = .init(0);
var thread_atexit_report: std.atomic.Value(u64) = .init(0);
var uuid_counter: std.atomic.Value(u64) = .init(1);
var gpo_state: std.atomic.Value(u32) = .init(0);

/// One futex-style address and the last wake generation published for it.
///
/// The table is fixed-size because this is a firmware hot path: allocating
/// while a title is trying to park an allocator or job-system worker can recurse
/// into the very subsystem that is waiting. Open addressing keeps the common
/// lookup bounded without turning every wait into a linear scan.
const sync_address_capacity: usize = 1024;
const sync_address_mask: usize = sync_address_capacity - 1;
const sync_address_self_heal_us: u64 = 100 * std.time.us_per_ms;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(sync_address_capacity));
}

const SyncAddress = struct {
    address: u64 = 0,
    generation: u64 = 1,
};

const SyncAddressLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SyncAddressLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SyncAddressLock) void {
        self.inner.unlock();
    }
};

var sync_address_lock = SyncAddressLock{};
var sync_addresses: [sync_address_capacity]SyncAddress =
    [_]SyncAddress{.{}} ** sync_address_capacity;
var sync_fallback_generation: u64 = 1;

/// Kernel event flags and semaphores used by the graphics runtime.
///
/// These objects stay in fixed tables for the same reason as the address-wait
/// generations above: creation can happen while Unity's allocators and worker
/// pool are live, so a firmware synchronization primitive must not allocate
/// through them. Handles are never reused during one process, which also keeps
/// a waiter on a deleted object from attaching to a newly created one.
const maximum_event_flags: usize = 64;
const maximum_semaphores: usize = 64;
const event_flag_key_prefix: u64 = 0x4556_0000_0000_0000;
const semaphore_key_prefix: u64 = 0x5345_0000_0000_0000;

const EventFlag = struct {
    handle: u64 = 0,
    bits: u64 = 0,
    sequence: u64 = 1,
    waiters: u32 = 0,
};

const Semaphore = struct {
    handle: u32 = 0,
    count: i32 = 0,
    initial_count: i32 = 0,
    maximum_count: i32 = 0,
    sequence: u64 = 1,
    waiters: u32 = 0,
};

var kernel_object_lock = SyncAddressLock{};
var event_flags: [maximum_event_flags]EventFlag = [_]EventFlag{.{}} ** maximum_event_flags;
var semaphores: [maximum_semaphores]Semaphore = [_]Semaphore{.{}} ** maximum_semaphores;
var next_event_flag_handle: u64 = 1;
var next_semaphore_handle: u32 = 1;
var exception_handlers: [128]u64 = [_]u64{0} ** 128;

fn findEventFlag(handle: u64) ?*EventFlag {
    for (&event_flags) |*object| if (object.handle == handle) return object;
    return null;
}

fn findSemaphore(handle: u32) ?*Semaphore {
    for (&semaphores) |*object| if (object.handle == handle) return object;
    return null;
}

fn advanceObjectSequence(sequence: *u64) u64 {
    sequence.* +%= 1;
    if (sequence.* == 0) sequence.* = 1;
    return sequence.*;
}

fn resetKernelObjects() void {
    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    @memset(&event_flags, .{});
    @memset(&semaphores, .{});
    @memset(&exception_handlers, 0);
    next_event_flag_handle = 1;
    next_semaphore_handle = 1;
    undelivered_exception_waits = 0;
}

fn syncAddressIndex(address: u64) usize {
    var mixed = address ^ (address >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    return @intCast(mixed & @as(u64, sync_address_mask));
}

fn syncAddressGeneration(address: u64, advance: bool) u64 {
    sync_address_lock.lock();
    defer sync_address_lock.unlock();

    const first = syncAddressIndex(address);
    for (0..sync_address_capacity) |offset| {
        const index = (first + offset) & sync_address_mask;
        const entry = &sync_addresses[index];
        if (entry.address == 0) entry.* = .{ .address = address };
        if (entry.address != address) continue;
        if (advance) {
            entry.generation +%= 1;
            if (entry.generation == 0) entry.generation = 1;
        }
        return entry.generation;
    }

    // Saturation degrades to a shared generation but remains race-safe: the
    // scheduler key is still the guest address, so a wake cannot release a
    // waiter on a different address. The bounded wait below prevents a missed
    // wake from becoming permanent.
    if (advance) {
        sync_fallback_generation +%= 1;
        if (sync_fallback_generation == 0) sync_fallback_generation = 1;
    }
    return sync_fallback_generation;
}

fn resetSyncAddresses() void {
    sync_address_lock.lock();
    defer sync_address_lock.unlock();
    @memset(&sync_addresses, .{});
    sync_fallback_generation = 1;
}

pub fn attachIo(io: ?std.Io) void {
    const was_detached = active_io == null;
    active_io = io;
    if (io) |value| {
        if (was_detached) {
            process_start_nanoseconds = std.Io.Clock.awake.now(value).nanoseconds;
        }
    } else {
        process_start_nanoseconds = 0;
        resetSyncAddresses();
        resetKernelObjects();
    }
}

/// The clock source firmware libraries share.
///
/// Exposed so sibling libraries measure time against the same source rather
/// than each reaching for one of their own, which would let their answers
/// disagree.
pub fn activeIo() ?std.Io {
    return active_io;
}

pub fn attachProcessParam(address: u64) void {
    process_param_address.store(address, .release);
}

fn errnoAddress() *i32 {
    if (threading.currentErrnoAddress()) |address| return @ptrFromInt(address);
    return &fallback_errno;
}

fn setErrno(value: i32) void {
    errnoAddress().* = value;
}

/// Lets sibling POSIX compatibility libraries report failure through the same
/// guest-thread errno cell as libc and libkernel.
pub fn setPosixErrno(value: i32) void {
    setErrno(value);
}

fn compatSuccess(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i64 {
    return 0;
}

fn kernelUnsupported(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return KernelError.enosys.raw();
}

fn aprResolveFilepathsToIdsAndFileSizes(
    paths_address: u64,
    count: u64,
    identifiers_address: u64,
    sizes_address: u64,
    results_address: u64,
    option: u64,
) callconv(abi.guest) i32 {
    if (count == 0 or count > 64) return KernelError.einval.raw();
    const path_bytes = std.math.mul(u64, count, @sizeOf(u64)) catch return KernelError.einval.raw();
    const identifier_bytes = std.math.mul(u64, count, @sizeOf(u32)) catch return KernelError.einval.raw();
    const size_bytes = std.math.mul(u64, count, @sizeOf(u64)) catch return KernelError.einval.raw();
    const result_bytes = std.math.mul(u64, count, @sizeOf(i32)) catch return KernelError.einval.raw();
    if (!memory_api.isGuestRangeAccessible(paths_address, path_bytes) or
        !memory_api.isGuestRangeAccessible(identifiers_address, identifier_bytes) or
        !memory_api.isGuestRangeAccessible(sizes_address, size_bytes) or
        !memory_api.isGuestRangeAccessible(results_address, result_bytes))
    {
        return KernelError.efault.raw();
    }

    const paths: [*]const u64 = @ptrFromInt(paths_address);
    for (paths[0..@intCast(count)], 0..) |path_address, index| {
        var path_buffer: [apr.maximum_path]u8 = undefined;
        const path = readGuestCString(path_address, &path_buffer) orelse return KernelError.efault.raw();
        const resolved = apr.resolve(path) catch |err| return aprKernelError(err);
        const identifier_destination: *[4]u8 = @ptrFromInt(identifiers_address + index * @sizeOf(u32));
        const size_destination: *[8]u8 = @ptrFromInt(sizes_address + index * @sizeOf(u64));
        const result_destination: *[4]u8 = @ptrFromInt(results_address + index * @sizeOf(i32));
        std.mem.writeInt(u32, identifier_destination, resolved.identifier, .little);
        std.mem.writeInt(u64, size_destination, resolved.size, .little);
        std.mem.writeInt(i32, result_destination, 0, .little);
        if (trace.isLive()) {
            std.debug.print(
                "[apr resolve {d}] '{s}' -> id={d} size={d} option=0x{x}\n",
                .{ index, path, resolved.identifier, resolved.size, option },
            );
        }
    }
    return 0;
}

fn readGuestCString(address: u64, buffer: []u8) ?[]const u8 {
    if (address == 0) return null;
    var length: usize = 0;
    while (length < buffer.len) : (length += 1) {
        if (!memory_api.isGuestRangeAccessible(address + length, 1)) return null;
        const source: *const u8 = @ptrFromInt(address + length);
        if (source.* == 0) return if (length == 0) null else buffer[0..length];
        buffer[length] = source.*;
    }
    return null;
}

fn aprKernelError(err: apr.Error) i32 {
    return switch (err) {
        error.FileNotFound, error.UnknownFile => KernelError.enoent.raw(),
        error.FileTableFull, error.CommandBufferTableFull, error.SubmissionTableFull => KernelError.enomem.raw(),
        error.IoFailed => KernelError.eio.raw(),
        error.InvalidPath, error.InvalidCommandBuffer, error.TooManyCommands, error.InvalidRead, error.UnknownSubmission => KernelError.einval.raw(),
    };
}

fn aprSubmitCommandBufferAndGetResult(
    command_buffer: u64,
    _: u64,
    result_address: u64,
    identifier_address: u64,
) callconv(abi.guest) i32 {
    if (command_buffer == 0) return KernelError.einval.raw();
    if ((result_address != 0 and !memory_api.isGuestRangeAccessible(result_address, 8)) or
        (identifier_address != 0 and !memory_api.isGuestRangeAccessible(identifier_address, @sizeOf(u32))))
    {
        return KernelError.efault.raw();
    }
    const identifier = apr.submitCommandBuffer(command_buffer) catch |err| return aprKernelError(err);
    if (result_address != 0) {
        const result: *[8]u8 = @ptrFromInt(result_address);
        @memset(result, 0);
    }
    if (identifier_address != 0) {
        const identifier_output: *[4]u8 = @ptrFromInt(identifier_address);
        std.mem.writeInt(u32, identifier_output, identifier, .little);
    }
    return 0;
}

fn aprWaitCommandBuffer(identifier: u32) callconv(abi.guest) i32 {
    apr.waitCommandBuffer(identifier) catch |err| return aprKernelError(err);
    return 0;
}

/// Parks a guest worker on an address until a matching wake is published.
///
/// Unity uses this as a futex-style primitive in its job system. Returning an
/// error makes every worker retry immediately and produces millions of firmware
/// calls without allowing the producer thread to run. A bounded deadline is a
/// safety net for a genuinely missed wake; callers already re-check their own
/// condition after every successful or spurious wakeup.
fn syncOnAddressWait(
    address: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (address == 0) return KernelError.einval.raw();
    const generation = syncAddressGeneration(address, false);
    _ = threading.waitCurrent(.{
        .key = address,
        .observed_sequence = generation,
        .timeout_microseconds = sync_address_self_heal_us,
    }) catch return KernelError.enosys.raw();
    return 0;
}

/// Releases workers parked by `syncOnAddressWait` on the same address.
fn syncOnAddressWake(
    address: u64,
    requested_waiters: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (address == 0) return KernelError.einval.raw();
    const generation = syncAddressGeneration(address, true);
    const maximum_waiters: usize = if (requested_waiters == 0 or
        requested_waiters >= std.math.maxInt(u32))
        std.math.maxInt(usize)
    else
        @intCast(requested_waiters);
    threading.wakeWaiters(address, generation, maximum_waiters);
    return 0;
}

fn supportedExceptionSignal(signal: i32) bool {
    return switch (signal) {
        1, 4, 8, 10, 11, 30 => true,
        else => false,
    };
}

fn installExceptionHandler(
    signal: i32,
    handler: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!supportedExceptionSignal(signal)) return KernelError.einval.raw();
    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    const slot = &exception_handlers[@intCast(signal)];
    if (slot.* != 0) return KernelError.eexist.raw();
    slot.* = handler;
    return 0;
}

fn removeExceptionHandler(
    signal: i32,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!supportedExceptionSignal(signal)) return KernelError.einval.raw();
    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    exception_handlers[@intCast(signal)] = 0;
    return 0;
}

/// Records a process exception request that the direct native bridge cannot
/// yet deliver to a different guest pthread.
///
/// A real kernel interrupts the target, runs the installed handler there, and
/// resumes its register context. The current bridge deliberately cannot fake
/// that by calling on the raiser's stack: Unity's stop-the-world callback would
/// publish roots for the wrong thread. Marking this one handshake lets the
/// raiser's following semaphore wait report ENOSYS, which is the title's
/// existing fallback path, while unrelated semaphores retain real semantics.
fn raiseException(
    target_thread: u64,
    signal: i32,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (target_thread == 0 or signal < 0 or signal >= exception_handlers.len) {
        return KernelError.einval.raw();
    }
    kernel_object_lock.lock();
    const installed = exception_handlers[@intCast(signal)] != 0;
    kernel_object_lock.unlock();
    if (installed and target_thread != threading.currentThreadId()) {
        // Unity's stop/resume handshake uses the pair of zero-count
        // semaphores created beside its exception handler. Neither side can be
        // completed without running that handler on the target pthread.
        undelivered_exception_waits = 2;
    }
    return 0;
}

const event_wait_and: u32 = 0x01;
const event_wait_or: u32 = 0x02;
const event_clear_all: u32 = 0x10;
const event_clear_pattern: u32 = 0x20;

fn validEventAttributes(attributes: u32) bool {
    const queue_mode = attributes & 0x0f;
    const thread_mode = attributes & 0xf0;
    return (queue_mode == 0 or queue_mode == 1 or queue_mode == 2) and
        (thread_mode == 0 or thread_mode == 0x10 or thread_mode == 0x20) and
        attributes & ~@as(u32, 0x33) == 0;
}

fn validEventWaitMode(mode: u32) bool {
    const condition = mode & 0x0f;
    const clear_mode = mode & 0xf0;
    return (condition == event_wait_and or condition == event_wait_or) and
        (clear_mode == 0 or clear_mode == event_clear_all or clear_mode == event_clear_pattern) and
        mode & ~@as(u32, 0x33) == 0;
}

fn eventSatisfied(bits: u64, pattern: u64, mode: u32) bool {
    return if (mode & 0x0f == event_wait_and)
        bits & pattern == pattern
    else
        bits & pattern != 0;
}

fn createEventFlag(
    output: ?*u64,
    name: ?[*:0]const u8,
    attributes: u32,
    initial_pattern: u64,
    option: u64,
    _: u64,
) callconv(abi.guest) i32 {
    const destination = output orelse return KernelError.einval.raw();
    if (name == null or option != 0 or !validEventAttributes(attributes)) {
        return KernelError.einval.raw();
    }
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(u64))) {
        return KernelError.efault.raw();
    }

    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    for (&event_flags) |*object| {
        if (object.handle != 0) continue;
        const handle = next_event_flag_handle;
        next_event_flag_handle +%= 1;
        if (next_event_flag_handle == 0) next_event_flag_handle = 1;
        object.* = .{ .handle = handle, .bits = initial_pattern };
        destination.* = handle;
        return 0;
    }
    return KernelError.enfile.raw();
}

fn deleteEventFlag(
    handle: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    kernel_object_lock.lock();
    const object = findEventFlag(handle) orelse {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    };
    const sequence = advanceObjectSequence(&object.sequence);
    object.handle = 0;
    kernel_object_lock.unlock();
    threading.wakeWaiters(event_flag_key_prefix | handle, sequence, std.math.maxInt(usize));
    return 0;
}

fn setEventFlag(
    handle: u64,
    pattern: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    kernel_object_lock.lock();
    const object = findEventFlag(handle) orelse {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    };
    object.bits |= pattern;
    const sequence = advanceObjectSequence(&object.sequence);
    kernel_object_lock.unlock();
    threading.wakeWaiters(event_flag_key_prefix | handle, sequence, std.math.maxInt(usize));
    return 0;
}

fn clearEventFlag(
    handle: u64,
    mask: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    const object = findEventFlag(handle) orelse return KernelError.enoent.raw();
    // The PS5 ABI supplies the bits to retain, not the bits to remove.
    object.bits &= mask;
    return 0;
}

fn pollEventFlag(
    handle: u64,
    pattern: u64,
    mode: u32,
    result_pattern: ?*u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (pattern == 0 or !validEventWaitMode(mode)) return KernelError.einval.raw();
    if (result_pattern) |output| {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u64))) {
            return KernelError.efault.raw();
        }
    }

    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    const object = findEventFlag(handle) orelse return KernelError.enoent.raw();
    if (result_pattern) |output| output.* = object.bits;
    if (!eventSatisfied(object.bits, pattern, mode)) return KernelError.ebusy.raw();
    switch (mode & 0xf0) {
        event_clear_all => object.bits = 0,
        event_clear_pattern => object.bits &= ~pattern,
        else => {},
    }
    return 0;
}

fn waitEventFlag(
    handle: u64,
    pattern: u64,
    mode: u32,
    result_pattern: ?*u64,
    timeout: ?*u32,
    _: u64,
) callconv(abi.guest) i32 {
    if (pattern == 0 or !validEventWaitMode(mode)) return KernelError.einval.raw();
    if (result_pattern) |output| {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u64))) {
            return KernelError.efault.raw();
        }
    }
    const requested_timeout: ?u64 = if (timeout) |value| blk: {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(value), @sizeOf(u32))) {
            return KernelError.efault.raw();
        }
        break :blk value.*;
    } else null;

    var registered_waiter = false;
    while (true) {
        kernel_object_lock.lock();
        const object = findEventFlag(handle) orelse {
            kernel_object_lock.unlock();
            return KernelError.enoent.raw();
        };
        if (eventSatisfied(object.bits, pattern, mode)) {
            if (registered_waiter) object.waiters -= 1;
            if (result_pattern) |output| output.* = object.bits;
            switch (mode & 0xf0) {
                event_clear_all => object.bits = 0,
                event_clear_pattern => object.bits &= ~pattern,
                else => {},
            }
            kernel_object_lock.unlock();
            return 0;
        }
        if (!registered_waiter) {
            object.waiters += 1;
            registered_waiter = true;
        }
        const observed = object.sequence;
        kernel_object_lock.unlock();

        const wait_result = threading.waitCurrent(.{
            .key = event_flag_key_prefix | handle,
            .observed_sequence = observed,
            .timeout_microseconds = requested_timeout,
        }) catch {
            kernel_object_lock.lock();
            if (findEventFlag(handle)) |current| current.waiters -= 1;
            kernel_object_lock.unlock();
            return KernelError.enosys.raw();
        };
        if (wait_result != .timed_out) continue;

        kernel_object_lock.lock();
        const current = findEventFlag(handle) orelse {
            kernel_object_lock.unlock();
            return KernelError.enoent.raw();
        };
        if (current.sequence != observed) {
            kernel_object_lock.unlock();
            continue;
        }
        current.waiters -= 1;
        if (result_pattern) |output| output.* = current.bits;
        kernel_object_lock.unlock();
        if (timeout) |value| value.* = 0;
        return KernelError.etimedout.raw();
    }
}

fn cancelEventFlag(
    handle: u64,
    set_pattern: u64,
    waiter_count: ?*u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (waiter_count) |output| {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u32))) {
            return KernelError.efault.raw();
        }
    }
    kernel_object_lock.lock();
    const object = findEventFlag(handle) orelse {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    };
    if (waiter_count) |output| output.* = object.waiters;
    object.bits = set_pattern;
    const sequence = advanceObjectSequence(&object.sequence);
    kernel_object_lock.unlock();
    threading.wakeWaiters(event_flag_key_prefix | handle, sequence, std.math.maxInt(usize));
    return 0;
}

fn createSemaphore(
    output: ?*u32,
    name: ?[*:0]const u8,
    attributes: u32,
    initial_count: i32,
    maximum_count: i32,
    option: u64,
) callconv(abi.guest) i32 {
    const destination = output orelse return KernelError.einval.raw();
    if (name == null or attributes > 2 or initial_count < 0 or maximum_count <= 0 or
        initial_count > maximum_count or option != 0)
    {
        return KernelError.einval.raw();
    }
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(u32))) {
        return KernelError.efault.raw();
    }

    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    for (&semaphores) |*object| {
        if (object.handle != 0) continue;
        const handle = next_semaphore_handle;
        next_semaphore_handle +%= 1;
        if (next_semaphore_handle == 0) next_semaphore_handle = 1;
        object.* = .{
            .handle = handle,
            .count = initial_count,
            .initial_count = initial_count,
            .maximum_count = maximum_count,
        };
        destination.* = handle;
        return 0;
    }
    return KernelError.enfile.raw();
}

fn waitSemaphore(
    handle: u32,
    needed_count: i32,
    timeout: ?*u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (undelivered_exception_waits != 0) {
        undelivered_exception_waits -= 1;
        return KernelError.enosys.raw();
    }
    const requested_timeout: ?u64 = if (timeout) |value| blk: {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(value), @sizeOf(u32))) {
            return KernelError.efault.raw();
        }
        break :blk value.*;
    } else null;

    var registered_waiter = false;
    while (true) {
        kernel_object_lock.lock();
        const object = findSemaphore(handle) orelse {
            kernel_object_lock.unlock();
            return KernelError.enoent.raw();
        };
        if (needed_count < 1 or needed_count > object.maximum_count) {
            kernel_object_lock.unlock();
            return KernelError.einval.raw();
        }
        if (object.count >= needed_count) {
            object.count -= needed_count;
            if (registered_waiter) object.waiters -= 1;
            kernel_object_lock.unlock();
            return 0;
        }
        if (!registered_waiter) {
            object.waiters += 1;
            registered_waiter = true;
        }
        const observed = object.sequence;
        kernel_object_lock.unlock();

        const wait_result = threading.waitCurrent(.{
            .key = semaphore_key_prefix | handle,
            .observed_sequence = observed,
            .timeout_microseconds = requested_timeout,
        }) catch {
            kernel_object_lock.lock();
            if (findSemaphore(handle)) |current| current.waiters -= 1;
            kernel_object_lock.unlock();
            return KernelError.enosys.raw();
        };
        if (wait_result != .timed_out) continue;

        kernel_object_lock.lock();
        const current = findSemaphore(handle) orelse {
            kernel_object_lock.unlock();
            return KernelError.enoent.raw();
        };
        if (current.sequence != observed) {
            kernel_object_lock.unlock();
            continue;
        }
        current.waiters -= 1;
        kernel_object_lock.unlock();
        if (timeout) |value| value.* = 0;
        return KernelError.etimedout.raw();
    }
}

fn pollSemaphore(
    handle: u32,
    needed_count: i32,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    const object = findSemaphore(handle) orelse return KernelError.enoent.raw();
    if (needed_count < 1 or needed_count > object.maximum_count) return KernelError.einval.raw();
    if (object.count < needed_count) return KernelError.ebusy.raw();
    object.count -= needed_count;
    return 0;
}

fn signalSemaphore(
    handle: u32,
    signal_count: i32,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    kernel_object_lock.lock();
    const object = findSemaphore(handle) orelse {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    };
    if (signal_count <= 0 or object.count > object.maximum_count - signal_count) {
        kernel_object_lock.unlock();
        return KernelError.einval.raw();
    }
    object.count += signal_count;
    const sequence = advanceObjectSequence(&object.sequence);
    kernel_object_lock.unlock();
    threading.wakeWaiters(semaphore_key_prefix | handle, sequence, @intCast(signal_count));
    return 0;
}

fn cancelSemaphore(
    handle: u32,
    set_count: i32,
    waiter_count: ?*u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (waiter_count) |output| {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u32))) {
            return KernelError.efault.raw();
        }
    }
    kernel_object_lock.lock();
    const object = findSemaphore(handle) orelse {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    };
    if (set_count > object.maximum_count) {
        kernel_object_lock.unlock();
        return KernelError.einval.raw();
    }
    if (waiter_count) |output| output.* = object.waiters;
    object.count = if (set_count < 0) object.initial_count else set_count;
    const sequence = advanceObjectSequence(&object.sequence);
    kernel_object_lock.unlock();
    threading.wakeWaiters(semaphore_key_prefix | handle, sequence, std.math.maxInt(usize));
    return 0;
}

fn deleteSemaphore(
    handle: u32,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    kernel_object_lock.lock();
    const object = findSemaphore(handle) orelse {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    };
    const sequence = advanceObjectSequence(&object.sequence);
    object.handle = 0;
    kernel_object_lock.unlock();
    threading.wakeWaiters(semaphore_key_prefix | handle, sequence, std.math.maxInt(usize));
    return 0;
}

fn posixUnsupported(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i64 {
    setErrno(errno.Posix.enosys);
    return -1;
}

/// Returns the handle of a module the title asks for by path.
///
/// Titles load some of their own modules explicitly rather than through the
/// dynamic tables, then use the returned handle to resolve symbols. Every
/// module adjacent to the executable is already mapped and relocated by the
/// time guest code runs, so this names what exists instead of loading anything:
/// loading again would produce a second copy with its own relocations and
/// duplicate state the title expects to be shared.
///
/// `result` receives what the module's entry point returned. Reporting success
/// there is accurate — initializers ran during loading — and titles check it.
fn loadStartModule(
    path: ?[*:0]const u8,
    _: u64,
    _: u64,
    _: u32,
    _: u64,
    result: ?*i32,
) callconv(abi.guest) i32 {
    const name = path orelse return KernelError.efault.raw();
    const loaded = modules.findByPath(std.mem.span(name)) orelse
        return KernelError.enoent.raw();

    if (result) |out| out.* = errno.ok;
    return loaded.handle;
}

/// Accepts a request to stop and unload a module.
///
/// Nothing is unloaded: modules stay mapped for the life of the process, and a
/// title that unloads one is usually shutting down. Reporting failure here
/// would make an orderly teardown look like an error.
fn stopUnloadModule(
    handle: i32,
    _: u64,
    _: u64,
    _: u32,
    _: u64,
    result: ?*i32,
) callconv(abi.guest) i32 {
    if (modules.findByHandle(handle) == null) return KernelError.esrch.raw();
    if (result) |out| out.* = errno.ok;
    return errno.ok;
}

/// Reports which module owns an address and where its unwind tables are.
///
/// A throwing title asks this for every return address on the stack. Answering
/// with "unimplemented" leaves its runtime unable to find any handler, so a
/// caught exception becomes a call to `terminate` — the failure looks like a
/// crash in unrelated code long after the throw.
///
/// `flags` selects the record variant; only the two documented forms exist, and
/// anything above them is rejected after clearing the record so a guest cannot
/// read stale stack contents as a result.
fn getModuleInfoForUnwind(
    address: u64,
    flags: i32,
    info: ?*unwind.Info,
) callconv(abi.guest) i32 {
    if (flags >= 3) {
        if (info) |out| out.* = .{};
        return KernelError.einval.raw();
    }
    const out = info orelse return KernelError.efault.raw();
    // The guest declares which layout it understands by pre-filling the size.
    // Filling a record it believes to be smaller would write past its buffer.
    if (out.size < @sizeOf(unwind.Info)) return KernelError.einval.raw();

    const owner = unwind.find(address) orelse return KernelError.esrch.raw();
    unwind.describe(owner, out);
    return errno.ok;
}

/// Writes guest output to the host's standard streams.
///
/// Only the standard descriptors are handled. A title's own diagnostics are the
/// clearest statement of what went wrong, and refusing this call silences them:
/// the guest runtime then fails without ever explaining itself, which is far
/// more expensive to debug than the write is to support.
///
/// Any other descriptor still reports that files are unimplemented, rather than
/// pretending a write succeeded and letting the guest believe data was stored.
fn guestWrite(descriptor: i32, buffer: ?[*]const u8, length: u64) callconv(abi.guest) i64 {
    if (descriptor != 1 and descriptor != 2) {
        setErrno(errno.Posix.ebadf);
        return -1;
    }
    const bytes = buffer orelse {
        setErrno(errno.Posix.efault);
        return -1;
    };
    if (length == 0) return 0;

    const io = active_io orelse {
        setErrno(errno.Posix.eio);
        return -1;
    };

    const file = if (descriptor == 2) std.Io.File.stderr() else std.Io.File.stdout();
    // Unbuffered: guest output is interleaved with host diagnostics, and a
    // title writing its last words before terminating must not lose them to a
    // buffer that never gets flushed.
    var writer = file.writerStreaming(io, &.{});
    writer.interface.writeAll(bytes[0..@intCast(length)]) catch {
        setErrno(errno.Posix.eio);
        return -1;
    };
    writer.interface.flush() catch {};
    return @intCast(length);
}

fn setThreadDtors(callback: u64) callconv(abi.guest) i32 {
    thread_dtors.store(callback, .release);
    return errno.ok;
}

fn setThreadAtexitCount(callback: u64) callconv(abi.guest) i32 {
    thread_atexit_count.store(callback, .release);
    return errno.ok;
}

fn setThreadAtexitReport(callback: u64) callconv(abi.guest) i32 {
    thread_atexit_report.store(callback, .release);
    return errno.ok;
}

fn errorAddress() callconv(abi.guest) *i32 {
    return errnoAddress();
}

fn stackCheckFail() callconv(abi.guest) void {
    // The guest ABI marks this noreturn. Requesting a pthread exit gives the
    // native bridge a controlled escape path instead of trapping in host HLE.
    threading.scePthreadExit(null);
}

fn getProcParam() callconv(abi.guest) ?*const anyopaque {
    const address = process_param_address.load(.acquire);
    return if (address == 0) null else @ptrFromInt(address);
}

fn setApplicationHeapApi(address: u64) callconv(abi.guest) i32 {
    application_heap_api.store(address, .release);
    return errno.ok;
}

fn sanitizerHooksUnavailable() callconv(abi.guest) ?*anyopaque {
    return null;
}

fn mapNamedFlexibleMemoryInternal(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    name: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    return memory_api.sceKernelMapNamedFlexibleMemory(
        out_address,
        len,
        protection_bits,
        flags,
        name,
    );
}

fn tlsGetAddr(index: ?*const TlsIndex) callconv(abi.guest) ?*anyopaque {
    const value = index orelse return null;
    const address = threading.resolveCurrentTls(value.module_id, value.offset) orelse return null;
    return @ptrFromInt(address);
}

fn rtldThreadAtexitIncrement() callconv(abi.guest) i32 {
    rtld_atexit_count +|= 1;
    return errno.ok;
}

fn rtldThreadAtexitDecrement() callconv(abi.guest) i32 {
    rtld_atexit_count -|= 1;
    return errno.ok;
}

fn pthreadGetname(_: ?*anyopaque, name: ?[*]u8, len: usize) callconv(abi.guest) i32 {
    if (name == null or len == 0) return KernelError.einval.raw();
    name.?[0] = 0;
    return errno.ok;
}

fn elfPhdrMatchAddr(module_info: ?*const anyopaque, _: u64) callconv(abi.guest) i32 {
    return @intFromBool(module_info != null);
}

fn processExit(_: i32) callconv(abi.guest) void {
    threading.scePthreadExit(null);
}

fn clockNanoseconds(clock_id: i32) i96 {
    const io = active_io orelse return 0;
    const clock: std.Io.Clock = if (clock_id == 0) .real else .awake;
    return clock.now(io).nanoseconds;
}

pub fn realTimeNanoseconds() i96 {
    return clockNanoseconds(0);
}

fn writeTimespec(clock_id: i32, output: ?*Timespec, kernel_errors: bool) i32 {
    const value = output orelse return if (kernel_errors)
        KernelError.einval.raw()
    else blk: {
        setErrno(errno.Posix.einval);
        break :blk -1;
    };
    const nanoseconds = clockNanoseconds(clock_id);
    value.seconds = @intCast(@divTrunc(nanoseconds, std.time.ns_per_s));
    value.nanoseconds = @intCast(@mod(nanoseconds, std.time.ns_per_s));
    return errno.ok;
}

fn clockGettime(clock_id: i32, output: ?*Timespec) callconv(abi.guest) i32 {
    return writeTimespec(clock_id, output, false);
}

fn kernelClockGettime(clock_id: i32, output: ?*Timespec) callconv(abi.guest) i32 {
    return writeTimespec(clock_id, output, true);
}

fn gettimeofday(output: ?*Timeval, timezone: ?*Timezone) callconv(abi.guest) i32 {
    if (output) |value| {
        const nanoseconds = clockNanoseconds(0);
        value.seconds = @intCast(@divTrunc(nanoseconds, std.time.ns_per_s));
        value.microseconds = @intCast(@divTrunc(
            @mod(nanoseconds, std.time.ns_per_s),
            std.time.ns_per_us,
        ));
    }
    if (timezone) |value| value.* = .{ .minutes_west = 0, .dst_time = 0 };
    return errno.ok;
}

fn kernelGettimeofday(output: ?*Timeval) callconv(abi.guest) i32 {
    if (output == null) return KernelError.einval.raw();
    return gettimeofday(output, null);
}

fn nanosleep(request: ?*const Timespec, remaining: ?*Timespec) callconv(abi.guest) i32 {
    const value = request orelse {
        setErrno(errno.Posix.einval);
        return -1;
    };
    if (value.seconds < 0 or value.nanoseconds < 0 or
        value.nanoseconds >= std.time.ns_per_s)
    {
        setErrno(errno.Posix.einval);
        return -1;
    }
    const whole_microseconds = std.math.mul(u64, @intCast(value.seconds), std.time.us_per_s) catch {
        setErrno(errno.Posix.einval);
        return -1;
    };
    const fractional: u64 = @intCast(@divTrunc(value.nanoseconds + std.time.ns_per_us - 1, std.time.ns_per_us));
    const total = std.math.add(u64, whole_microseconds, fractional) catch {
        setErrno(errno.Posix.einval);
        return -1;
    };
    if (total > std.math.maxInt(u32)) {
        setErrno(errno.Posix.einval);
        return -1;
    }
    const status = threading.sceKernelUsleep(@intCast(total));
    if (status != errno.ok) {
        setErrno(errno.kernelToPosix(status));
        return -1;
    }
    if (remaining) |value_remaining| value_remaining.* = .{ .seconds = 0, .nanoseconds = 0 };
    return errno.ok;
}

fn kernelNanosleep(request: ?*const Timespec, remaining: ?*Timespec) callconv(abi.guest) i32 {
    const result = nanosleep(request, remaining);
    return if (result == errno.ok) errno.ok else errno.posixToKernel(errnoAddress().*);
}

fn kernelSleep(seconds: u32) callconv(abi.guest) i32 {
    var remaining = seconds;
    const maximum_seconds: u32 = std.math.maxInt(u32) / std.time.us_per_s;
    while (remaining != 0) {
        const chunk = @min(remaining, maximum_seconds);
        const status = threading.sceKernelUsleep(chunk * @as(u32, std.time.us_per_s));
        if (status != errno.ok) return status;
        remaining -= chunk;
    }
    return errno.ok;
}

fn getProcessTime() callconv(abi.guest) u64 {
    const now = clockNanoseconds(1);
    const elapsed = @max(@as(i96, 0), now - process_start_nanoseconds);
    return @intCast(@divTrunc(elapsed, std.time.ns_per_us));
}

fn getProcessTimeCounter() callconv(abi.guest) u64 {
    const now = clockNanoseconds(1);
    const elapsed = @max(@as(i96, 0), now - process_start_nanoseconds);
    return @intCast(elapsed);
}

fn getProcessTimeCounterFrequency() callconv(abi.guest) u64 {
    return std.time.ns_per_s;
}

fn uuidCreate(output: ?*[16]u8) callconv(abi.guest) i32 {
    const value = output orelse return KernelError.einval.raw();
    const sequence = uuid_counter.fetchAdd(1, .monotonic);
    std.mem.writeInt(u64, value[0..8], getProcessTimeCounter(), .little);
    std.mem.writeInt(u64, value[8..16], sequence, .little);
    value[6] = (value[6] & 0x0f) | 0x40;
    value[8] = (value[8] & 0x3f) | 0x80;
    return errno.ok;
}

fn schedYield() callconv(abi.guest) i32 {
    threading.scePthreadYield();
    return errno.ok;
}

fn isTrinityMode() callconv(abi.guest) i32 {
    return 0;
}

fn setGpo(bits: u32) callconv(abi.guest) void {
    gpo_state.store(bits, .release);
}

fn convertLocaltimeToUtc(
    local_time: i64,
    _: i64,
    utc_time: ?*i64,
    timezone: ?*Timezone,
    dst_seconds: ?*i32,
) callconv(abi.guest) i32 {
    const zone = timezone orelse return KernelError.einval.raw();
    zone.* = .{ .minutes_west = 0, .dst_time = 0 };
    if (utc_time) |output| output.* = local_time;
    if (dst_seconds) |output| output.* = 0;
    return errno.ok;
}

fn convertUtcToLocaltime(
    utc_time: i64,
    local_time: ?*i64,
    time_seconds: ?*TimeSeconds,
    dst_seconds: ?*u64,
) callconv(abi.guest) i32 {
    if (local_time) |output| output.* = utc_time;
    if (time_seconds) |output| output.* = .{
        .seconds = utc_time,
        .west_seconds = 0,
        .dst_seconds = 0,
    };
    if (dst_seconds) |output| output.* = 0;
    return errno.ok;
}

fn getrusage(_: i32, output: ?*[144]u8) callconv(abi.guest) i32 {
    const value = output orelse {
        setErrno(errno.Posix.efault);
        return -1;
    };
    @memset(value, 0);
    return errno.ok;
}

pub const exports = [_]symbols.Export{
    .{ .name = "_sceKernelSetThreadDtors", .function = trace.wrap("_sceKernelSetThreadDtors", &setThreadDtors), .expect_id = "rNhWz+lvOMU" },
    .{ .name = "_sceKernelSetThreadAtexitCount", .function = trace.wrap("_sceKernelSetThreadAtexitCount", &setThreadAtexitCount), .expect_id = "pB-yGZ2nQ9o" },
    .{ .name = "_sceKernelSetThreadAtexitReport", .function = trace.wrap("_sceKernelSetThreadAtexitReport", &setThreadAtexitReport), .expect_id = "WhCc1w3EhSI" },
    .{ .name = "sceKernelDebugRaiseException", .function = trace.wrap("sceKernelDebugRaiseException", &compatSuccess), .expect_id = "OMDRKKAZ8I4" },
    .{ .name = "sceKernelDebugRaiseExceptionOnReleaseMode", .function = trace.wrap("sceKernelDebugRaiseExceptionOnReleaseMode", &compatSuccess), .expect_id = "zE-wXIZjLoM" },
    .{ .name = "__error", .function = trace.wrap("__error", &errorAddress), .expect_id = "9BcDykPmo1I" },
    .{ .name = "__stack_chk_fail", .function = trace.wrap("__stack_chk_fail", &stackCheckFail), .expect_id = "Ou3iL1abvng" },
    .{ .name = "signal", .function = trace.wrap("signal", &compatSuccess), .expect_id = "VADc3MNQ3cM" },
    .{ .name = "sceKernelGetProcParam", .function = trace.wrap("sceKernelGetProcParam", &getProcParam), .expect_id = "959qrazPIrg" },
    .{ .name = "nanosleep", .function = trace.wrap("nanosleep", &nanosleep), .expect_id = "yS8U2TGCe1A" },
    .{ .name = "gettimeofday", .function = trace.wrap("gettimeofday", &gettimeofday), .expect_id = "n88vx3C5nW8" },
    .{ .name = "_sceKernelRtldSetApplicationHeapAPI", .function = trace.wrap("_sceKernelRtldSetApplicationHeapAPI", &setApplicationHeapApi), .expect_id = "p5EcQeEeJAE" },
    .{ .name = "sceKernelGetSanitizerMallocReplaceExternal", .function = trace.wrap("sceKernelGetSanitizerMallocReplaceExternal", &sanitizerHooksUnavailable), .expect_id = "py6L8jiVAN8" },
    .{ .name = "sceKernelInternalMemoryGetModuleSegmentInfo", .function = trace.wrap("sceKernelInternalMemoryGetModuleSegmentInfo", &kernelUnsupported), .expect_id = "-YTW+qXc3CQ" },
    .{ .name = "sceKernelMapNamedFlexibleMemoryInternal", .function = trace.wrap("sceKernelMapNamedFlexibleMemoryInternal", &mapNamedFlexibleMemoryInternal), .expect_id = "4h6F1LLbTiw" },
    .{ .name = "sceKernelMlock", .function = trace.wrap("sceKernelMlock", &compatSuccess), .expect_id = "3k6kx-zOOSQ" },
    .{ .name = "sceKernelIsAddressSanitizerEnabled", .function = trace.wrap("sceKernelIsAddressSanitizerEnabled", &compatSuccess), .expect_id = "jh+8XiK4LeE" },
    .{ .name = "_write", .function = trace.wrap("_write", &guestWrite), .expect_id = "FxVZqBAA7ks" },
    .{ .name = "rmdir", .function = trace.wrap("rmdir", &posixUnsupported), .expect_id = "c7ZnT7V1B98" },
    .{ .name = "unlink", .function = trace.wrap("unlink", &posixUnsupported), .expect_id = "VAzswvTOCzI" },
    .{ .name = "sceKernelGetSanitizerNewReplaceExternal", .function = trace.wrap("sceKernelGetSanitizerNewReplaceExternal", &sanitizerHooksUnavailable), .expect_id = "bnZxYgAFeA0" },
    .{ .name = "unknown_libkernel_cfwBSQyr5Ys", .function = trace.wrap("unknown_libkernel_cfwBSQyr5Ys", &compatSuccess), .id_override = "cfwBSQyr5Ys" },
    .{ .name = "__tls_get_addr", .function = trace.wrap("__tls_get_addr", &tlsGetAddr), .expect_id = "vNe1w4diLCs" },
    .{ .name = "_sceKernelRtldThreadAtexitIncrement", .function = trace.wrap("_sceKernelRtldThreadAtexitIncrement", &rtldThreadAtexitIncrement), .expect_id = "Tz4RNUCBbGI" },
    .{ .name = "_sceKernelRtldThreadAtexitDecrement", .function = trace.wrap("_sceKernelRtldThreadAtexitDecrement", &rtldThreadAtexitDecrement), .expect_id = "8OnWXlgQlvo" },
    .{ .name = "sceKernelGetModuleInfoFromAddr", .function = trace.wrap("sceKernelGetModuleInfoFromAddr", &kernelUnsupported), .expect_id = "f7KBOafysXo" },
    .{ .name = "scePthreadGetname", .function = trace.wrap("scePthreadGetname", &pthreadGetname), .expect_id = "How7B8Oet6k" },
    .{ .name = "sceKernelGetModuleInfoForUnwind", .function = trace.wrap("sceKernelGetModuleInfoForUnwind", &getModuleInfoForUnwind), .expect_id = "RpQJJVKTiFM" },
    .{ .name = "_is_signal_return", .function = trace.wrap("_is_signal_return", &compatSuccess), .expect_id = "crb5j7mkk1c" },
    .{ .name = "__elf_phdr_match_addr", .function = trace.wrap("__elf_phdr_match_addr", &elfPhdrMatchAddr), .expect_id = "Fjc4-n1+y2g" },
    .{ .name = "__pthread_cxa_finalize", .function = trace.wrap("__pthread_cxa_finalize", &compatSuccess), .expect_id = "kbw4UHHSYy0" },
    .{ .name = "_nanosleep", .function = trace.wrap("_nanosleep", &nanosleep), .expect_id = "NhpspxdjEKU" },
    .{ .name = "_exit", .function = trace.wrap("_exit", &processExit), .expect_id = "6Z83sYWFlA8" },
    .{ .name = "sceKernelConvertLocaltimeToUtc", .function = trace.wrap("sceKernelConvertLocaltimeToUtc", &convertLocaltimeToUtc), .expect_id = "0NTHN1NKONI" },
    .{ .name = "_sigprocmask", .function = trace.wrap("_sigprocmask", &compatSuccess), .expect_id = "6xVpy0Fdq+I" },
    .{ .name = "getrusage", .function = trace.wrap("getrusage", &getrusage), .expect_id = "hHlZQUnlxSM" },
    .{ .name = "sceKernelGetProcessTime", .function = trace.wrap("sceKernelGetProcessTime", &getProcessTime), .expect_id = "4J2sUJmuHZQ" },
    .{ .name = "sceKernelConvertUtcToLocaltime", .function = trace.wrap("sceKernelConvertUtcToLocaltime", &convertUtcToLocaltime), .expect_id = "-o5uEDpN+oY" },
    .{ .name = "clock_gettime", .function = trace.wrap("clock_gettime", &clockGettime), .expect_id = "lLMT9vJAck0" },
    .{ .name = "sceKernelClockGettime", .function = trace.wrap("sceKernelClockGettime", &kernelClockGettime), .expect_id = "QBi7HCK03hw" },
    .{ .name = "sceKernelClose", .function = trace.wrap("sceKernelClose", &kernelUnsupported), .expect_id = "UK2Tl2DWUns" },
    .{ .name = "sceKernelGetdents", .function = trace.wrap("sceKernelGetdents", &kernelUnsupported), .expect_id = "j2AIqSqJP0w" },
    .{ .name = "sceKernelOpen", .function = trace.wrap("sceKernelOpen", &kernelUnsupported), .expect_id = "1G3lF1Gg1k8" },
    .{ .name = "sceKernelStat", .function = trace.wrap("sceKernelStat", &kernelUnsupported), .expect_id = "eV9wAD2riIA" },
    .{ .name = "sceKernelMkdir", .function = trace.wrap("sceKernelMkdir", &kernelUnsupported), .expect_id = "1-LFLmRFxxM" },
    .{ .name = "sceKernelUtimes", .function = trace.wrap("sceKernelUtimes", &kernelUnsupported), .expect_id = "0Cq8ipKr9n0" },
    .{ .name = "sceKernelRename", .function = trace.wrap("sceKernelRename", &kernelUnsupported), .expect_id = "52NcYU9+lEo" },
    .{ .name = "sceKernelTruncate", .function = trace.wrap("sceKernelTruncate", &kernelUnsupported), .expect_id = "WlyEA-sLDf0" },
    .{ .name = "sceKernelUnlink", .function = trace.wrap("sceKernelUnlink", &kernelUnsupported), .expect_id = "AUXVxWeJU-A" },
    .{ .name = "sceKernelChmod", .function = trace.wrap("sceKernelChmod", &kernelUnsupported), .expect_id = "fgIsQ10xYVA" },
    .{ .name = "sceKernelGettimeofday", .function = trace.wrap("sceKernelGettimeofday", &kernelGettimeofday), .expect_id = "ejekcaNQNq0" },
    .{ .name = "sceKernelNanosleep", .function = trace.wrap("sceKernelNanosleep", &kernelNanosleep), .expect_id = "QvsZxomvUHs" },
    .{ .name = "sceKernelSleep", .function = trace.wrap("sceKernelSleep", &kernelSleep), .expect_id = "-ZR+hG7aDHw" },
    .{ .name = "sceKernelUuidCreate", .function = trace.wrap("sceKernelUuidCreate", &uuidCreate), .expect_id = "Xjoosiw+XPI" },
    .{ .name = "sceKernelFstat", .function = trace.wrap("sceKernelFstat", &kernelUnsupported), .expect_id = "kBwCPsYX-m4" },
    .{ .name = "scePthreadRename", .function = trace.wrap("scePthreadRename", &compatSuccess), .expect_id = "GBUY7ywdULE" },
    .{ .name = "sceKernelCreateEventFlag", .function = trace.wrap("sceKernelCreateEventFlag", &createEventFlag), .expect_id = "BpFoboUJoZU" },
    .{ .name = "sceKernelDeleteEventFlag", .function = trace.wrap("sceKernelDeleteEventFlag", &deleteEventFlag), .expect_id = "8mql9OcQnd4" },
    .{ .name = "sceKernelPollEventFlag", .function = trace.wrap("sceKernelPollEventFlag", &pollEventFlag), .expect_id = "9lvj5DjHZiA" },
    .{ .name = "sceKernelWaitEventFlag", .function = trace.wrap("sceKernelWaitEventFlag", &waitEventFlag), .expect_id = "JTvBflhYazQ" },
    .{ .name = "sceKernelSetEventFlag", .function = trace.wrap("sceKernelSetEventFlag", &setEventFlag), .expect_id = "IOnSvHzqu6A" },
    .{ .name = "sceKernelClearEventFlag", .function = trace.wrap("sceKernelClearEventFlag", &clearEventFlag), .expect_id = "7uhBFWRAS60" },
    .{ .name = "sceKernelCreateSema", .function = trace.wrap("sceKernelCreateSema", &createSemaphore), .expect_id = "188x57JYp0g" },
    .{ .name = "sceKernelPollSema", .function = trace.wrap("sceKernelPollSema", &pollSemaphore), .expect_id = "12wOHk8ywb0" },
    .{ .name = "sceKernelWaitSema", .function = trace.wrap("sceKernelWaitSema", &waitSemaphore), .expect_id = "Zxa0VhQVTsk" },
    .{ .name = "sceKernelSignalSema", .function = trace.wrap("sceKernelSignalSema", &signalSemaphore), .expect_id = "4czppHBiriw" },
    .{ .name = "sceKernelCancelSema", .function = trace.wrap("sceKernelCancelSema", &cancelSemaphore), .expect_id = "4DM06U2BNEY" },
    .{ .name = "sceKernelDlsym", .function = trace.wrap("sceKernelDlsym", &kernelUnsupported), .expect_id = "LwG8g3niqwA" },
    .{ .name = "sceKernelLoadStartModule", .function = trace.wrap("sceKernelLoadStartModule", &loadStartModule), .expect_id = "wzvqT4UqKX8" },
    .{ .name = "sceKernelStopUnloadModule", .function = trace.wrap("sceKernelStopUnloadModule", &stopUnloadModule), .expect_id = "QKd0qM58Qes" },
    .{ .name = "sceKernelGetProcessTimeCounter", .function = trace.wrap("sceKernelGetProcessTimeCounter", &getProcessTimeCounter), .expect_id = "fgxnMeTNUtY" },
    .{ .name = "sceKernelGetProcessTimeCounterFrequency", .function = trace.wrap("sceKernelGetProcessTimeCounterFrequency", &getProcessTimeCounterFrequency), .expect_id = "BNowx2l588E" },
    .{ .name = "unknown_libkernel_B2n8aDorSH4", .function = trace.wrap("unknown_libkernel_B2n8aDorSH4", &kernelUnsupported), .id_override = "B2n8aDorSH4" },
    .{ .name = "unknown_libkernel_PZQhiiLXRFs", .function = trace.wrap("unknown_libkernel_PZQhiiLXRFs", &kernelUnsupported), .id_override = "PZQhiiLXRFs" },
    .{ .name = "sceKernelSyncOnAddressWake", .function = trace.wrap("sceKernelSyncOnAddressWake", &syncOnAddressWake), .expect_id = "q2y-wDIVWZA" },
    .{ .name = "sceKernelSyncOnAddressWait", .function = trace.wrap("sceKernelSyncOnAddressWait", &syncOnAddressWait), .expect_id = "Hc4CaR6JBL0" },
    .{ .name = "sceKernelIsTrinityMode", .function = trace.wrap("sceKernelIsTrinityMode", &isTrinityMode), .expect_id = "tU5e3f9gSiU" },
    .{ .name = "sceKernelSetGPO", .function = trace.wrap("sceKernelSetGPO", &setGpo), .expect_id = "ca7v6Cxulzs" },
    .{ .name = "sceKernelCancelEventFlag", .function = trace.wrap("sceKernelCancelEventFlag", &cancelEventFlag), .expect_id = "PZku4ZrXJqg" },
    .{ .name = "sceKernelDeleteSema", .function = trace.wrap("sceKernelDeleteSema", &deleteSemaphore), .expect_id = "R1Jvn8bSCW8" },
    .{ .name = "sceKernelAprResolveFilepathsToIdsAndFileSizes", .function = trace.wrap("sceKernelAprResolveFilepathsToIdsAndFileSizes", &aprResolveFilepathsToIdsAndFileSizes), .expect_id = "gEpBkcwxUjw" },
    .{ .name = "sceKernelAprSubmitCommandBufferAndGetResult", .function = trace.wrap("sceKernelAprSubmitCommandBufferAndGetResult", &aprSubmitCommandBufferAndGetResult), .expect_id = "ASoW5WE-UPo" },
    .{ .name = "sceKernelAprWaitCommandBuffer", .function = trace.wrap("sceKernelAprWaitCommandBuffer", &aprWaitCommandBuffer), .expect_id = "rqwFKI4PAiM" },

    // The rest of the accelerator's path-resolution and submission surface,
    // reported unimplemented like the entries above it. These turn a list of
    // file paths into identifiers the accelerator then reads by, and answering
    // them without an accelerator behind it would hand a title identifiers that
    // name nothing, which it would carry until a read failed for no visible
    // reason.
    .{ .name = "sceKernelAprGetFileStat", .function = trace.wrap("sceKernelAprGetFileStat", &kernelUnsupported), .expect_id = "ApkYaHb8Sek" },
    .{ .name = "sceKernelAprGetFileSize", .function = trace.wrap("sceKernelAprGetFileSize", &kernelUnsupported), .expect_id = "WvEu7yl3Ivg" },
    .{ .name = "sceKernelAprResolveFilepathsToIds", .function = trace.wrap("sceKernelAprResolveFilepathsToIds", &kernelUnsupported), .expect_id = "WT-5NKy42fw" },
    .{ .name = "sceKernelAprResolveFilepathsToIdsForEach", .function = trace.wrap("sceKernelAprResolveFilepathsToIdsForEach", &kernelUnsupported), .expect_id = "eYAh2vlCY-U" },
    .{ .name = "sceKernelAprResolveFilepathsToIdsAndFileSizesForEach", .function = trace.wrap("sceKernelAprResolveFilepathsToIdsAndFileSizesForEach", &kernelUnsupported), .expect_id = "QzB4O+bJQyA" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIds", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIds", &kernelUnsupported), .expect_id = "i3HWvW35jao" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIdsForEach", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIdsForEach", &kernelUnsupported), .expect_id = "VB-BtuIW8Xc" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizes", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizes", &kernelUnsupported), .expect_id = "w5fcCG+t31g" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizesForEach", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizesForEach", &kernelUnsupported), .expect_id = "C+Khtbbx2g8" },
    .{ .name = "sceKernelAprSubmitCommandBuffer", .function = trace.wrap("sceKernelAprSubmitCommandBuffer", &kernelUnsupported), .expect_id = "eE4Szl8sil8" },
    .{ .name = "sceKernelAprSubmitCommandBufferAndGetId", .function = trace.wrap("sceKernelAprSubmitCommandBufferAndGetId", &kernelUnsupported), .expect_id = "qvMUCyyaCSI" },

    // An accelerator event on a queue that will never carry one. Registering
    // the event would leave a title waiting on something nothing signals.
    .{ .name = "sceKernelAddAmprEvent", .function = trace.wrap("sceKernelAddAmprEvent", &kernelUnsupported), .expect_id = "bBfz7kMF2Ho" },
};

pub const unity_exports = [_]symbols.Export{
    .{ .name = "sceKernelInstallExceptionHandler", .function = trace.wrap("sceKernelInstallExceptionHandler", &installExceptionHandler), .expect_id = "WkwEd3N7w0Y" },
    .{ .name = "sceKernelRemoveExceptionHandler", .function = trace.wrap("sceKernelRemoveExceptionHandler", &removeExceptionHandler), .expect_id = "Qhv5ARAoOEc" },
    .{ .name = "sceKernelRaiseException", .function = trace.wrap("sceKernelRaiseException", &raiseException), .expect_id = "il03nluKfMk" },
};

pub const posix_exports = [_]symbols.Export{
    .{ .name = "mkdir", .function = trace.wrap("mkdir", &posixUnsupported), .expect_id = "JGMio+21L4c" },
    .{ .name = "chmod", .function = trace.wrap("chmod", &posixUnsupported), .expect_id = "z0dtnPxYgtg" },
    .{ .name = "rename", .function = trace.wrap("rename", &posixUnsupported), .expect_id = "NN01qLRhiqU" },
    .{ .name = "fchmod", .function = trace.wrap("fchmod", &posixUnsupported), .expect_id = "n01yNbQO5W4" },
    .{ .name = "write", .function = trace.wrap("write", &guestWrite), .expect_id = "FN4gaPmuFV8" },
    .{ .name = "futimes", .function = trace.wrap("futimes", &posixUnsupported), .expect_id = "+0EDo7YzcoU" },
    .{ .name = "utimes", .function = trace.wrap("utimes", &posixUnsupported), .expect_id = "GDuV00CHrUg" },
    .{ .name = "sched_yield", .function = trace.wrap("sched_yield", &schedYield), .expect_id = "6XG4B33N09g" },
    .{ .name = "inet_pton", .function = trace.wrap("inet_pton", &posixUnsupported), .expect_id = "4n51s0zEf0c" },
    .{ .name = "send", .function = trace.wrap("send", &posixUnsupported), .expect_id = "fZOeZIOEmLw" },

    // The rest of the socket surface, refused like `send` above it. The
    // networking model here is deliberately offline — no host socket is ever
    // opened — and a title told that a socket bound, listened, or accepted
    // would then wait for a peer that cannot arrive. An error it can see is
    // the better answer, and it is the one it would get from a console with no
    // connection.
    .{ .name = "bind", .function = trace.wrap("bind", &posixUnsupported), .expect_id = "KuOmgKoqCdY" },
    .{ .name = "listen", .function = trace.wrap("listen", &posixUnsupported), .expect_id = "pxnCmagrtao" },
    .{ .name = "accept", .function = trace.wrap("accept", &posixUnsupported), .expect_id = "3e+4Iv7IJ8U" },
    .{ .name = "sendto", .function = trace.wrap("sendto", &posixUnsupported), .expect_id = "oBr313PppNE" },
    .{ .name = "recvfrom", .function = trace.wrap("recvfrom", &posixUnsupported), .expect_id = "lUk6wrGXyMw" },
    .{ .name = "getsockname", .function = trace.wrap("getsockname", &posixUnsupported), .expect_id = "RenI1lL1WFk" },
    .{ .name = "getpeername", .function = trace.wrap("getpeername", &posixUnsupported), .expect_id = "TXFFFiNldU8" },
    .{ .name = "getsockopt", .function = trace.wrap("getsockopt", &posixUnsupported), .expect_id = "6O8EwYOgH9Y" },

    // Descriptor flags. Refused rather than answered, because the flag a title
    // most often sets here is non-blocking, and claiming that took effect on a
    // descriptor that ignores it invites the title to spin.
    .{ .name = "fcntl", .function = trace.wrap("fcntl", &posixUnsupported), .expect_id = "8nY19bKoiZk" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const unity_library = symbols.Library{ .name = "libkernel_unity", .version = 1 };
pub const posix_library = symbols.Library{ .name = "libScePosix", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addObject(
        gpa,
        library,
        module,
        "__stack_chk_guard",
        @intFromPtr(&stack_check_guard),
        "f7uOxY9mM1U",
    );
    try db.addObject(
        gpa,
        library,
        module,
        "__progname",
        @intFromPtr(&program_name),
        "djxxOmW6-aw",
    );
    try db.addLibrary(gpa, library, module, &exports);
    try db.addLibrary(gpa, unity_library, module, &unity_exports);
    try db.addLibrary(gpa, posix_library, module, &posix_exports);
}

test "runtime compatibility exports include libc bootstrap data and private NIDs" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);

    try std.testing.expect(db.findByName("__stack_chk_guard", .object) != null);
    try std.testing.expect(db.findByName("__progname", .object) != null);
    try std.testing.expect(db.findByName("__tls_get_addr", .function) != null);
    try std.testing.expect(db.findById("B2n8aDorSH4", .function) != null);
    try std.testing.expect(db.findByName("sceKernelSyncOnAddressWait", .function) != null);
    try std.testing.expect(db.findByName("sceKernelSyncOnAddressWake", .function) != null);
}

const SyncAddressTestBackend = struct {
    wait_request: ?threading.WaitRequest = null,
    wake_key: u64 = 0,
    wake_sequence: u64 = 0,
    wake_count: usize = 0,

    fn start(_: ?*anyopaque, _: threading.StartRequest) threading.BackendError!void {
        return error.Unsupported;
    }

    fn wait(
        raw: ?*anyopaque,
        request: threading.WaitRequest,
    ) threading.BackendError!threading.WaitResult {
        const self: *SyncAddressTestBackend = @ptrCast(@alignCast(raw.?));
        self.wait_request = request;
        return .timed_out;
    }

    fn wake(
        raw: ?*anyopaque,
        key: u64,
        sequence: u64,
        maximum_waiters: usize,
    ) void {
        const self: *SyncAddressTestBackend = @ptrCast(@alignCast(raw.?));
        self.wake_key = key;
        self.wake_sequence = sequence;
        self.wake_count = maximum_waiters;
    }

    fn backend(self: *SyncAddressTestBackend) threading.Backend {
        return .{
            .context = self,
            .start_fn = &start,
            .wait_fn = &wait,
            .wake_fn = &wake,
        };
    }
};

test "address waits park by generation and matching wakes advance it" {
    const testing = std.testing;
    const memory = @import("memory");
    const loader = @import("loader");

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var tls_registry = loader.TlsRegistry{};
    defer tls_registry.deinit(testing.allocator);
    var thread_manager = threading.Manager{};
    thread_manager.init(testing.allocator, &address_space, &tls_registry);
    defer thread_manager.deinit();
    var backend = SyncAddressTestBackend{};
    thread_manager.setBackend(backend.backend());
    threading.attachManager(&thread_manager);
    defer threading.attachManager(null);
    resetSyncAddresses();

    const address: u64 = 0x1234_0000;
    try testing.expectEqual(KernelError.einval.raw(), syncOnAddressWait(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(i32, 0), syncOnAddressWait(address, 0, 0, 0, 0, 0));
    try testing.expectEqual(address, backend.wait_request.?.key);
    try testing.expectEqual(@as(u64, 1), backend.wait_request.?.observed_sequence);
    try testing.expectEqual(sync_address_self_heal_us, backend.wait_request.?.timeout_microseconds.?);

    try testing.expectEqual(@as(i32, 0), syncOnAddressWake(address, 1, 0, 0, 0, 0));
    try testing.expectEqual(address, backend.wake_key);
    try testing.expectEqual(@as(u64, 2), backend.wake_sequence);
    try testing.expectEqual(@as(usize, 1), backend.wake_count);

    try testing.expectEqual(@as(i32, 0), syncOnAddressWait(address, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u64, 2), backend.wait_request.?.observed_sequence);
    try testing.expectEqual(@as(i32, 0), syncOnAddressWake(address, 0, 0, 0, 0, 0));
    try testing.expectEqual(std.math.maxInt(usize), backend.wake_count);
}

test "kernel event flags and semaphores retain and consume their state" {
    const testing = std.testing;
    resetKernelObjects();

    const event_name: [:0]const u8 = "render-stop";
    var event_handle: u64 = 0;
    try testing.expectEqual(
        @as(i32, 0),
        createEventFlag(&event_handle, event_name.ptr, 0x21, 0x2, 0, 0),
    );
    try testing.expect(event_handle != 0);
    try testing.expectEqual(@as(i32, 0), setEventFlag(event_handle, 0x4, 0, 0, 0, 0));

    var observed: u64 = 0;
    try testing.expectEqual(
        @as(i32, 0),
        pollEventFlag(event_handle, 0x4, event_wait_or | event_clear_pattern, &observed, 0, 0),
    );
    try testing.expectEqual(@as(u64, 0x6), observed);
    try testing.expectEqual(
        KernelError.ebusy.raw(),
        pollEventFlag(event_handle, 0x4, event_wait_or, &observed, 0, 0),
    );
    try testing.expectEqual(@as(i32, 0), clearEventFlag(event_handle, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(i32, 0), deleteEventFlag(event_handle, 0, 0, 0, 0, 0));

    const semaphore_name: [:0]const u8 = "render-jobs";
    var semaphore_handle: u32 = 0;
    try testing.expectEqual(
        @as(i32, 0),
        createSemaphore(&semaphore_handle, semaphore_name.ptr, 0, 2, 3, 0),
    );
    try testing.expectEqual(@as(i32, 0), installExceptionHandler(30, 0x1234, 0, 0, 0, 0));
    try testing.expectEqual(@as(i32, 0), raiseException(0x5678, 30, 0, 0, 0, 0));
    try testing.expectEqual(
        KernelError.enosys.raw(),
        waitSemaphore(semaphore_handle, 1, null, 0, 0, 0),
    );
    try testing.expectEqual(
        KernelError.enosys.raw(),
        waitSemaphore(semaphore_handle, 1, null, 0, 0, 0),
    );
    try testing.expectEqual(@as(i32, 0), pollSemaphore(semaphore_handle, 1, 0, 0, 0, 0));
    try testing.expectEqual(@as(i32, 0), waitSemaphore(semaphore_handle, 1, null, 0, 0, 0));
    try testing.expectEqual(
        KernelError.ebusy.raw(),
        pollSemaphore(semaphore_handle, 1, 0, 0, 0, 0),
    );
    try testing.expectEqual(@as(i32, 0), signalSemaphore(semaphore_handle, 2, 0, 0, 0, 0));
    try testing.expectEqual(@as(i32, 0), pollSemaphore(semaphore_handle, 2, 0, 0, 0, 0));
    try testing.expectEqual(@as(i32, 0), deleteSemaphore(semaphore_handle, 0, 0, 0, 0, 0));
}
