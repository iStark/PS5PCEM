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
const filesystem = @import("../filesystem.zig");
const memory_api = @import("kernel_memory.zig");
const threading = @import("kernel_threading.zig");
const host_memory = @import("memory");

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

/// Extended timezone result used by the PS5 calendar conversion entry point.
///
/// This is deliberately distinct from the eight-byte POSIX `timezone` above.
/// The PS5 libc reads the two trailing second-resolution fields after calling
/// `sceKernelConvertLocaltimeToUtc`; leaving them outside the declared output
/// made libc consume adjacent guest-stack data as a timezone correction.
const ConversionTimezone = extern struct {
    minutes_west: i32,
    dst_time: i32,
    west_seconds: i32,
    dst_seconds: i32,
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
const process_argument_zero = "eboot.bin";
var process_arguments = [_]?[*:0]const u8{ process_argument_zero, null };
var program_name: ?[*:0]const u8 = process_argument_zero;
threadlocal var fallback_errno: i32 = 0;
threadlocal var rtld_atexit_count: u32 = 0;

/// Set when the launcher is done with guest execution (contained fault, clean
/// exit). Hot firmware paths that would otherwise spin forever — guest stdout
/// from AGC suspendPoint, for example — check this and leave guest code.
var guest_stop_requested: std.atomic.Value(bool) = .init(false);

var active_io: ?std.Io = null;
var process_start_nanoseconds: i96 = 0;
var process_clock_sequence: std.atomic.Value(u32) = .init(0);
var excluded_host_nanoseconds: std.atomic.Value(u64) = .init(0);
var active_host_exclusion_start: std.atomic.Value(u64) = .init(0);
const host_time_exclusion_grace_ns: u64 = 100 * std.time.ns_per_ms;
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
/// How often a parked address-wait re-reads guest memory.
///
/// The producer often stores a new counter and never calls the matching wake
/// export. A periodic poll notices the store directly; an explicit wake still
/// pre-empts it. Ten milliseconds matches the reference implementation and
/// avoids waking roughly one hundred idle Unity workers four thousand times a
/// second. The slice is internal and is never exposed to the guest as a
/// spurious successful return.
const sync_address_poll_us: u64 = 10 * std.time.us_per_ms;
const sync_address_log_limit: u32 = 16;
var sync_wait_log_count = std.atomic.Value(u32).init(0);
var sync_wake_log_count = std.atomic.Value(u32).init(0);

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
// Unity Baselib creates one semaphore per worker plus runtime/service objects;
// current titles can cross 64 before their first frame. Keep this allocation-
// free while matching the scale expected by a full process rather than a
// bootstrap-only workload.
const maximum_semaphores: usize = 1024;
const maximum_semaphore_waiters: usize = 1024;
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
    name: [32]u8 = @splat(0),
    attributes: u32 = 0,
    count: i32 = 0,
    initial_count: i32 = 0,
    maximum_count: i32 = 0,
    sequence: u64 = 1,
    waiters: u32 = 0,
    creator: u64 = 0,
    creator_name: [32]u8 = @splat(0),
    last_waiter: u64 = 0,
    last_waiter_name: [32]u8 = @splat(0),
    last_signaller: u64 = 0,
    last_signaller_host: u32 = 0,
    last_signaller_name: [32]u8 = @splat(0),
    last_needed_count: i32 = 0,
    wait_calls: u64 = 0,
    signal_calls: u64 = 0,
    deleted: bool = false,
};

const SemaphoreWaitResult = enum(u8) {
    pending,
    granted,
    canceled,
    deleted,
};

/// One persistent scheduler key per slot prevents stale wake tokens from one
/// wait being consumed by a later user of that slot. The sequence is retained
/// and advanced across reuse; all other fields are cleared on release.
const SemaphoreWaiter = struct {
    occupied: bool = false,
    semaphore_handle: u32 = 0,
    thread_id: u64 = 0,
    needed_count: i32 = 0,
    priority: i32 = threading.default_priority,
    order: u64 = 0,
    sequence: u64 = 1,
    result: SemaphoreWaitResult = .pending,
    wake_pending: bool = false,
};

/// Snapshot used by the CPU wait watchdog. Kernel semaphores use synthetic
/// scheduler keys rather than object addresses, so kernel_sync cannot describe
/// them and previously reported the most important AGC waits as "untracked".
pub const SemaphoreWaitInfo = struct {
    handle: u32,
    name: [32]u8,
    count: i32,
    initial_count: i32,
    maximum_count: i32,
    sequence: u64,
    waiters: u32,
    creator: u64,
    creator_name: [32]u8,
    last_waiter: u64,
    last_waiter_name: [32]u8,
    last_signaller: u64,
    last_signaller_host: u32,
    last_signaller_name: [32]u8,
    last_needed_count: i32,
    wait_calls: u64,
    signal_calls: u64,
};

var kernel_object_lock = SyncAddressLock{};
var event_flags: [maximum_event_flags]EventFlag = [_]EventFlag{.{}} ** maximum_event_flags;
var semaphores: [maximum_semaphores]Semaphore = [_]Semaphore{.{}} ** maximum_semaphores;
var semaphore_waiters: [maximum_semaphore_waiters]SemaphoreWaiter =
    [_]SemaphoreWaiter{.{}} ** maximum_semaphore_waiters;
var next_event_flag_handle: u64 = 1;
var next_semaphore_handle: u32 = 1;
var next_semaphore_wait_order: u64 = 1;
var exception_handlers: [128]u64 = [_]u64{0} ** 128;

fn findEventFlag(handle: u64) ?*EventFlag {
    for (&event_flags) |*object| if (object.handle == handle) return object;
    return null;
}

fn findSemaphore(handle: u32) ?*Semaphore {
    for (&semaphores) |*object| if (object.handle == handle) return object;
    return null;
}

pub fn describeSemaphoreWaitKey(key: u64) ?SemaphoreWaitInfo {
    if (key & 0xffff_ffff_0000_0000 != semaphore_key_prefix) return null;
    const raw_slot = key & 0xffff_ffff;
    if (raw_slot == 0 or raw_slot > maximum_semaphore_waiters) return null;

    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    const waiter = &semaphore_waiters[@intCast(raw_slot - 1)];
    if (!waiter.occupied) return null;
    const object = findSemaphore(waiter.semaphore_handle) orelse return null;
    return .{
        .handle = object.handle,
        .name = object.name,
        .count = object.count,
        .initial_count = object.initial_count,
        .maximum_count = object.maximum_count,
        .sequence = object.sequence,
        .waiters = object.waiters,
        .creator = object.creator,
        .creator_name = object.creator_name,
        .last_waiter = object.last_waiter,
        .last_waiter_name = object.last_waiter_name,
        .last_signaller = object.last_signaller,
        .last_signaller_host = object.last_signaller_host,
        .last_signaller_name = object.last_signaller_name,
        .last_needed_count = object.last_needed_count,
        .wait_calls = object.wait_calls,
        .signal_calls = object.signal_calls,
    };
}

fn copyGuestSemaphoreName(name: ?[*:0]const u8) [32]u8 {
    var result: [32]u8 = @splat(0);
    const source = name orelse return result;
    const base = @intFromPtr(source);
    for (result[0 .. result.len - 1], 0..) |*destination, index| {
        const address = std.math.add(u64, base, index) catch return result;
        if (!memory_api.isGuestRangeAccessible(address, 1)) return result;
        const byte = source[index];
        if (byte == 0) break;
        destination.* = byte;
    }
    return result;
}

fn advanceObjectSequence(sequence: *u64) u64 {
    sequence.* +%= 1;
    if (sequence.* == 0) sequence.* = 1;
    return sequence.*;
}

fn semaphoreWaitKey(index: usize) u64 {
    return semaphore_key_prefix | @as(u64, @intCast(index + 1));
}

fn allocateSemaphoreWaiterLocked(
    handle: u32,
    thread_id: u64,
    needed_count: i32,
    priority: i32,
) ?usize {
    for (&semaphore_waiters, 0..) |*waiter, index| {
        if (waiter.occupied) continue;
        const next_sequence = advanceObjectSequence(&waiter.sequence);
        const order = next_semaphore_wait_order;
        next_semaphore_wait_order +%= 1;
        if (next_semaphore_wait_order == 0) next_semaphore_wait_order = 1;
        waiter.* = .{
            .occupied = true,
            .semaphore_handle = handle,
            .thread_id = thread_id,
            .needed_count = needed_count,
            .priority = priority,
            .order = order,
            .sequence = next_sequence,
        };
        return index;
    }
    return null;
}

fn releaseSemaphoreWaiterLocked(index: usize) void {
    const sequence = semaphore_waiters[index].sequence;
    semaphore_waiters[index] = .{ .sequence = sequence };
}

fn finishSemaphoreWaiterLocked(object: *Semaphore, index: usize) SemaphoreWaitResult {
    const result = semaphore_waiters[index].result;
    releaseSemaphoreWaiterLocked(index);
    object.waiters -= 1;
    if (object.deleted and object.waiters == 0) object.* = .{};
    return result;
}

fn semaphoreWaitResultCode(result: SemaphoreWaitResult) i32 {
    return switch (result) {
        .granted => 0,
        .canceled => KernelError.ecanceled.raw(),
        .deleted => KernelError.eacces.raw(),
        .pending => KernelError.eio.raw(),
    };
}

fn waiterPrecedes(candidate: *const SemaphoreWaiter, current: *const SemaphoreWaiter, fifo: bool) bool {
    if (!fifo and candidate.priority != current.priority) return candidate.priority < current.priority;
    return candidate.order < current.order;
}

/// Reserve available tokens for already-blocked waiters while the semaphore is
/// locked. A thread arriving after Signal can therefore never steal a token
/// from a waiter that the signal was meant to release.
fn grantSemaphoreWaitersLocked(object: *Semaphore) void {
    while (true) {
        var selected: ?usize = null;
        for (&semaphore_waiters, 0..) |*waiter, index| {
            if (!waiter.occupied or waiter.semaphore_handle != object.handle or
                waiter.result != .pending or waiter.needed_count > object.count)
            {
                continue;
            }
            if (selected == null or waiterPrecedes(
                waiter,
                &semaphore_waiters[selected.?],
                object.attributes == 1,
            )) selected = index;
        }
        const index = selected orelse return;
        const waiter = &semaphore_waiters[index];
        object.count -= waiter.needed_count;
        waiter.result = .granted;
        waiter.wake_pending = true;
        _ = advanceObjectSequence(&waiter.sequence);
    }
}

fn completeSemaphoreWaitersLocked(handle: u32, result: SemaphoreWaitResult) void {
    for (&semaphore_waiters) |*waiter| {
        if (!waiter.occupied or waiter.semaphore_handle != handle or waiter.result != .pending) continue;
        waiter.result = result;
        waiter.wake_pending = true;
        _ = advanceObjectSequence(&waiter.sequence);
    }
}

fn pendingSemaphoreWaiterCountLocked(handle: u32) u32 {
    var count: u32 = 0;
    for (&semaphore_waiters) |*waiter| {
        if (waiter.occupied and waiter.semaphore_handle == handle and waiter.result == .pending) {
            count += 1;
        }
    }
    return count;
}

/// Wake exact waiter keys outside the kernel-object lock. The result is already
/// committed, so a waiter that reaches its predicate before this scan simply
/// removes its slot and needs no notification.
fn flushSemaphoreWakes(handle: u32) void {
    while (true) {
        kernel_object_lock.lock();
        var selected: ?usize = null;
        var sequence: u64 = 0;
        for (&semaphore_waiters, 0..) |*waiter, index| {
            if (!waiter.occupied or waiter.semaphore_handle != handle or !waiter.wake_pending) continue;
            waiter.wake_pending = false;
            selected = index;
            sequence = waiter.sequence;
            break;
        }
        kernel_object_lock.unlock();
        const index = selected orelse return;
        threading.wakeWaiters(semaphoreWaitKey(index), sequence, 1);
    }
}

fn resetKernelObjects() void {
    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    @memset(&event_flags, .{});
    @memset(&semaphores, .{});
    @memset(&semaphore_waiters, .{});
    @memset(&exception_handlers, 0);
    next_event_flag_handle = 1;
    next_semaphore_handle = 1;
    next_semaphore_wait_order = 1;
}

/// Reports what a parked thread is actually looking at.
///
/// A thread waiting on an address is waiting for a value there to change, and
/// the wait entry point is told only the address. When such a thread wakes,
/// re-checks and parks again — which is what a stalled render loop looks like —
/// the address alone says nothing: it cannot distinguish a wake that never
/// arrived from one that arrived and found the condition still false. The word
/// under the address separates the two, and it is the only thing that does.
fn announceSyncAddress(what: []const u8, address: u64) void {
    if (!trace.announces("sceKernelSyncOnAddress")) return;
    if (!memory_api.isGuestRangeAccessible(address, @sizeOf(u64))) {
        std.debug.print("[sync] {s} 0x{x} <unreadable>\n", .{ what, address });
        return;
    }
    const words: *const [2]u32 = @ptrFromInt(address);
    std.debug.print(
        "[sync] {s} 0x{x} = 0x{x:0>8} 0x{x:0>8}\n",
        .{ what, address, words[0], words[1] },
    );
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
    // waiter on a different address. Polling the compared word also prevents a
    // producer store without a matching wake from being missed.
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
            process_clock_sequence.store(0, .release);
            excluded_host_nanoseconds.store(0, .release);
            active_host_exclusion_start.store(0, .release);
        }
        guest_stop_requested.store(false, .release);
    } else {
        process_start_nanoseconds = 0;
        process_clock_sequence.store(0, .release);
        excluded_host_nanoseconds.store(0, .release);
        active_host_exclusion_start.store(0, .release);
        application_heap_api.store(0, .release);
        resetSyncAddresses();
        resetKernelObjects();
        guest_stop_requested.store(false, .release);
    }
}

/// Asks guest threads that pass through hot firmware to leave cleanly.
///
/// Used after a contained fault so AGC suspendPoint loops that only print
/// through `_write` stop burning cores before the host process exits.
pub fn requestGuestStop() void {
    guest_stop_requested.store(true, .release);
}

pub fn guestStopRequested() bool {
    return guest_stop_requested.load(.acquire);
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
    error_index_address: u64,
) callconv(abi.guest) i32 {
    if (paths_address == 0 or count == 0 or count > 1024 or
        (identifiers_address == 0 and sizes_address == 0))
    {
        return KernelError.einval.raw();
    }
    const path_bytes = std.math.mul(u64, count, @sizeOf(u64)) catch return KernelError.einval.raw();
    const identifier_bytes = std.math.mul(u64, count, @sizeOf(u32)) catch return KernelError.einval.raw();
    const size_bytes = std.math.mul(u64, count, @sizeOf(u64)) catch return KernelError.einval.raw();
    if (!memory_api.isGuestRangeAccessible(paths_address, path_bytes) or
        (identifiers_address != 0 and !memory_api.isGuestRangeAccessible(identifiers_address, identifier_bytes)) or
        (sizes_address != 0 and !memory_api.isGuestRangeAccessible(sizes_address, size_bytes)) or
        (error_index_address != 0 and !memory_api.isGuestRangeAccessible(error_index_address, @sizeOf(u32))))
    {
        return KernelError.efault.raw();
    }

    const paths: [*]const u64 = @ptrFromInt(paths_address);
    for (paths[0..@intCast(count)], 0..) |path_address, index| {
        var path_buffer: [apr.maximum_path]u8 = undefined;
        const path = readGuestCString(path_address, &path_buffer) orelse return KernelError.efault.raw();
        const resolved = apr.resolve(path) catch |err| {
            // This API stops at the first miss. Its outputs are nevertheless
            // defined: callers use the zero size to select their ordinary
            // file-open fallback instead of retaining stack garbage as a size.
            if (identifiers_address != 0) {
                const destination: *[4]u8 = @ptrFromInt(identifiers_address + index * @sizeOf(u32));
                std.mem.writeInt(u32, destination, std.math.maxInt(u32), .little);
            }
            if (sizes_address != 0) {
                const destination: *[8]u8 = @ptrFromInt(sizes_address + index * @sizeOf(u64));
                std.mem.writeInt(u64, destination, 0, .little);
            }
            if (error_index_address != 0) {
                const destination: *[4]u8 = @ptrFromInt(error_index_address);
                std.mem.writeInt(u32, destination, @intCast(index), .little);
            }
            if (trace.announces("sceKernelAprResolveFilepathsToIdsAndFileSizes")) {
                std.debug.print(
                    "[apr resolve {d}] '{s}' failed: {s}\n",
                    .{ index, path, @errorName(err) },
                );
            }
            return aprKernelError(err);
        };
        if (identifiers_address != 0) {
            const destination: *[4]u8 = @ptrFromInt(identifiers_address + index * @sizeOf(u32));
            std.mem.writeInt(u32, destination, resolved.identifier, .little);
        }
        if (sizes_address != 0) {
            const destination: *[8]u8 = @ptrFromInt(sizes_address + index * @sizeOf(u64));
            std.mem.writeInt(u64, destination, resolved.size, .little);
        }
        if (trace.announces("sceKernelAprResolveFilepathsToIdsAndFileSizes")) {
            std.debug.print(
                "[apr resolve {d}] '{s}' -> id={d} size={d}\n",
                .{ index, path, resolved.identifier, resolved.size },
            );
        }
    }
    return 0;
}

fn aprResolveFilepathsToIds(
    paths_address: u64,
    count: u64,
    identifiers_address: u64,
    error_index_address: u64,
) callconv(abi.guest) i32 {
    return aprResolveFilepathsToIdsAndFileSizes(
        paths_address,
        count,
        identifiers_address,
        0,
        error_index_address,
    );
}

fn aprGetFileStat(identifier: u32, out: ?*filesystem.Stat) callconv(abi.guest) i32 {
    const record = out orelse return KernelError.einval.raw();
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(record), @sizeOf(filesystem.Stat))) {
        return KernelError.efault.raw();
    }
    apr.stat(identifier, record) catch |err| return aprKernelError(err);
    return 0;
}

fn aprGetFileSize(identifier: u32, out: ?*u64) callconv(abi.guest) i32 {
    const size = out orelse return KernelError.einval.raw();
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(size), @sizeOf(u64))) {
        return KernelError.efault.raw();
    }
    size.* = apr.fileSize(identifier) catch |err| return aprKernelError(err);
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
        error.InvalidPath, error.InvalidCommandBuffer, error.TooManyCommands, error.InvalidRead, error.UnknownSubmission, error.MappingFailed => KernelError.einval.raw(),
        error.OutOfDirectMemory => KernelError.eagain.raw(),
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

fn syncCompareBytes(size: u64) usize {
    return switch (size) {
        1, 2, 4, 8 => @intCast(size),
        else => 4,
    };
}

fn readGuestSyncWord(address: u64, size: u64) ?u64 {
    const bytes = syncCompareBytes(size);
    if (!memory_api.isGuestRangeAccessible(address, bytes)) return null;
    // Firmware tests and early attach leave the guest address space unset;
    // the accessibility check then accepts any non-null pointer. Confirm the
    // host page is actually committed before touching it.
    if (!host_memory.isHostRangeReadable(address, bytes)) return null;
    var value: u64 = 0;
    const source: [*]const u8 = @ptrFromInt(address);
    @memcpy(std.mem.asBytes(&value)[0..bytes], source[0..bytes]);
    return value;
}

fn syncWordMask(size: u64) u64 {
    const bits = syncCompareBytes(size) * 8;
    if (bits >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(bits)) - 1;
}

fn syncAddressStillMatches(address: u64, expected: u64, size: u64) ?bool {
    const actual = readGuestSyncWord(address, size) orelse return null;
    return actual == expected & syncWordMask(size);
}

fn logSyncAddressCall(kind: []const u8, address: u64, a: u64, b: u64, c: u64, d: u64, word: ?u64) void {
    const counter = if (std.mem.eql(u8, kind, "wait"))
        &sync_wait_log_count
    else
        &sync_wake_log_count;
    const seen = counter.fetchAdd(1, .monotonic);
    if (seen >= sync_address_log_limit) return;
    if (word) |value| {
        std.debug.print(
            "[sync] {s} #{d} addr=0x{x} a1=0x{x} a2=0x{x} a3=0x{x} a4=0x{x} word=0x{x}\n",
            .{ kind, seen + 1, address, a, b, c, d, value },
        );
    } else {
        std.debug.print(
            "[sync] {s} #{d} addr=0x{x} a1=0x{x} a2=0x{x} a3=0x{x} a4=0x{x} word=<unreadable>\n",
            .{ kind, seen + 1, address, a, b, c, d },
        );
    }
}

/// Implements the typed PS5 futex-style wait shared by the public 32-bit alias
/// and the explicit Wait32/Wait64 exports. `timeout_address` points to a
/// microsecond value; null means an indefinite wait.
fn syncOnAddressWaitTyped(address: u64, expected: u64, timeout_address: u64, size: u64) i32 {
    const alignment = syncCompareBytes(size);
    if (address == 0 or address & (alignment - 1) != 0) return KernelError.einval.raw();

    const timeout_us: ?u64 = if (timeout_address == 0)
        null
    else
        readGuestSyncWord(timeout_address, @sizeOf(u32)) orelse return KernelError.efault.raw();

    // Capture the generation before comparing. A wake that races between the
    // compare and the backend park then has a newer sequence and is consumed
    // immediately instead of being lost.
    const generation = syncAddressGeneration(address, false);
    const observed = readGuestSyncWord(address, size) orelse return KernelError.efault.raw();
    announceSyncAddress("wait", address);
    logSyncAddressCall("wait", address, expected, timeout_address, size, timeout_us orelse 0, observed);
    if (observed != expected & syncWordMask(size)) return 0;
    if (timeout_us == 0) return KernelError.etimedout.raw();

    const started = processTimeMicroseconds();
    const deadline = if (timeout_us) |timeout| started +| timeout else 0;
    while (syncAddressStillMatches(address, expected, size) orelse return KernelError.efault.raw()) {
        if (guest_stop_requested.load(.acquire)) return 0;
        const now = processTimeMicroseconds();
        const remaining = if (timeout_us != null) deadline -| now else sync_address_poll_us;
        if (timeout_us != null and remaining == 0) return KernelError.etimedout.raw();
        const slice = @min(remaining, sync_address_poll_us);
        const wait_result = threading.waitCurrent(.{
            .key = address,
            .observed_sequence = generation,
            .timeout_microseconds = slice,
        }) catch return KernelError.enosys.raw();
        if (wait_result == .awoken) return 0;
        if (timeout_us != null and active_io == null) return KernelError.etimedout.raw();
    }
    return 0;
}

fn syncOnAddressWait(
    address: u64,
    expected: u64,
    timeout_address: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return syncOnAddressWaitTyped(address, expected, timeout_address, @sizeOf(u32));
}

fn syncOnAddressWait32(
    address: u64,
    expected: u64,
    timeout_address: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return syncOnAddressWaitTyped(address, expected, timeout_address, @sizeOf(u32));
}

fn syncOnAddressWait64(
    address: u64,
    expected: u64,
    timeout_address: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return syncOnAddressWaitTyped(address, expected, timeout_address, @sizeOf(u64));
}

/// Releases workers parked by `syncOnAddressWait` on the same address.
pub fn wakeSyncAddress(address: u64, maximum_waiters: usize) void {
    announceSyncAddress("wake", address);
    const generation = syncAddressGeneration(address, true);
    threading.wakeWaiters(address, generation, maximum_waiters);
}

/// Releases workers parked by `syncOnAddressWait` on the same address.
fn syncOnAddressWake(
    address: u64,
    count_raw: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    const requested_waiters: i32 = @bitCast(@as(u32, @truncate(count_raw)));
    if (address == 0 or address & (@alignOf(u32) - 1) != 0 or requested_waiters < 0) {
        return KernelError.einval.raw();
    }
    logSyncAddressCall("wake", address, @bitCast(@as(i64, requested_waiters)), 0, 0, 0, readGuestSyncWord(address, 4));
    if (requested_waiters == 0) return 0;
    const maximum_waiters: usize = @intCast(requested_waiters);
    wakeSyncAddress(address, maximum_waiters);
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

/// Delivers process exceptions through the CPU backend so Unity's stop-the-
/// world handler runs with the target pthread's TLS and stack identity.
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
    const handler = exception_handlers[@intCast(signal)];
    kernel_object_lock.unlock();
    if (handler == 0) return 0;
    threading.raiseGuestException(target_thread, handler, signal) catch |err| return switch (err) {
        error.ThreadNotFound => KernelError.esrch.raw(),
        else => KernelError.ebusy.raw(),
    };
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

    const object_name = copyGuestSemaphoreName(name);
    const creator = threading.currentThreadId();
    const creator_name = threading.currentThreadName();
    kernel_object_lock.lock();
    defer kernel_object_lock.unlock();
    for (&semaphores) |*object| {
        if (object.handle != 0) continue;
        const handle = next_semaphore_handle;
        next_semaphore_handle +%= 1;
        if (next_semaphore_handle == 0) next_semaphore_handle = 1;
        object.* = .{
            .handle = handle,
            .name = object_name,
            .attributes = attributes,
            .count = initial_count,
            .initial_count = initial_count,
            .maximum_count = maximum_count,
            .creator = creator,
            .creator_name = creator_name,
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
    const requested_timeout: ?u64 = if (timeout) |value| blk: {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(value), @sizeOf(u32))) {
            return KernelError.efault.raw();
        }
        break :blk value.*;
    } else null;

    const waiter = threading.currentThreadId();
    const waiter_name = threading.currentThreadName();
    const waiter_priority = threading.currentThreadPriority();
    var waiter_index: ?usize = null;
    while (true) {
        kernel_object_lock.lock();
        const object = findSemaphore(handle) orelse {
            if (waiter_index) |index| releaseSemaphoreWaiterLocked(index);
            kernel_object_lock.unlock();
            return KernelError.enoent.raw();
        };
        if (needed_count < 1 or needed_count > object.maximum_count) {
            if (waiter_index) |index| _ = finishSemaphoreWaiterLocked(object, index);
            kernel_object_lock.unlock();
            return KernelError.einval.raw();
        }
        if (waiter_index) |index| {
            const result = semaphore_waiters[index].result;
            if (result != .pending) {
                const completed = finishSemaphoreWaiterLocked(object, index);
                kernel_object_lock.unlock();
                return semaphoreWaitResultCode(completed);
            }
        } else if (object.deleted) {
            kernel_object_lock.unlock();
            return KernelError.eacces.raw();
        } else if (object.count >= needed_count) {
            object.count -= needed_count;
            kernel_object_lock.unlock();
            return 0;
        } else {
            const index = allocateSemaphoreWaiterLocked(
                handle,
                waiter,
                needed_count,
                waiter_priority,
            ) orelse {
                kernel_object_lock.unlock();
                return KernelError.enfile.raw();
            };
            waiter_index = index;
            object.waiters += 1;
            object.last_waiter = waiter;
            object.last_waiter_name = waiter_name;
            object.last_needed_count = needed_count;
            object.wait_calls +|= 1;
        }
        const index = waiter_index.?;
        const observed = semaphore_waiters[index].sequence;
        kernel_object_lock.unlock();

        const wait_result = threading.waitCurrent(.{
            .key = semaphoreWaitKey(index),
            .observed_sequence = observed,
            .timeout_microseconds = requested_timeout,
        }) catch {
            kernel_object_lock.lock();
            if (findSemaphore(handle)) |current| {
                if (semaphore_waiters[index].occupied) {
                    _ = finishSemaphoreWaiterLocked(current, index);
                }
            } else if (semaphore_waiters[index].occupied) {
                releaseSemaphoreWaiterLocked(index);
            }
            kernel_object_lock.unlock();
            return KernelError.enosys.raw();
        };
        if (wait_result != .timed_out) continue;

        kernel_object_lock.lock();
        const current = findSemaphore(handle) orelse {
            if (semaphore_waiters[index].occupied) releaseSemaphoreWaiterLocked(index);
            kernel_object_lock.unlock();
            return KernelError.enoent.raw();
        };
        const result = semaphore_waiters[index].result;
        if (result != .pending) {
            const completed = finishSemaphoreWaiterLocked(current, index);
            kernel_object_lock.unlock();
            return semaphoreWaitResultCode(completed);
        }
        _ = finishSemaphoreWaiterLocked(current, index);
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
    if (object.deleted) return KernelError.ebusy.raw();
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
    const signaller = threading.currentThreadId();
    const signaller_host = std.Thread.getCurrentId();
    const signaller_name = threading.currentThreadName();
    kernel_object_lock.lock();
    const object = findSemaphore(handle) orelse {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    };
    if (object.deleted or signal_count <= 0 or signal_count > object.maximum_count or
        object.count > object.maximum_count - signal_count)
    {
        kernel_object_lock.unlock();
        return KernelError.einval.raw();
    }
    object.count += signal_count;
    grantSemaphoreWaitersLocked(object);
    object.last_signaller = signaller;
    object.last_signaller_host = signaller_host;
    object.last_signaller_name = signaller_name;
    object.signal_calls +|= 1;
    _ = advanceObjectSequence(&object.sequence);
    kernel_object_lock.unlock();
    flushSemaphoreWakes(handle);
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
    if (object.deleted or set_count > object.maximum_count) {
        kernel_object_lock.unlock();
        return KernelError.einval.raw();
    }
    if (waiter_count) |output| output.* = pendingSemaphoreWaiterCountLocked(handle);
    object.count = if (set_count < 0) object.initial_count else set_count;
    completeSemaphoreWaitersLocked(handle, .canceled);
    _ = advanceObjectSequence(&object.sequence);
    kernel_object_lock.unlock();
    flushSemaphoreWakes(handle);
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
    if (object.deleted) {
        kernel_object_lock.unlock();
        return KernelError.enoent.raw();
    }
    object.deleted = true;
    completeSemaphoreWaitersLocked(handle, .deleted);
    _ = advanceObjectSequence(&object.sequence);
    if (object.waiters == 0) object.* = .{};
    kernel_object_lock.unlock();
    flushSemaphoreWakes(handle);
    return 0;
}

fn posixSemaphoreHandle(address: ?*const u32) ?u32 {
    const semaphore = address orelse return null;
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(semaphore), @sizeOf(u32))) return null;
    const handle = semaphore.*;
    return if (handle == 0) null else handle;
}

fn posixSemaphoreInit(destination: ?*u32, process_shared: i32, initial_count: u32) callconv(abi.guest) i32 {
    if (process_shared != 0 or initial_count > std.math.maxInt(i32)) return KernelError.einval.raw();
    return createSemaphore(
        destination,
        "posix".ptr,
        0,
        @intCast(initial_count),
        std.math.maxInt(i32),
        0,
    );
}

fn posixSemaphoreWait(address: ?*const u32) callconv(abi.guest) i32 {
    const handle = posixSemaphoreHandle(address) orelse return KernelError.einval.raw();
    return waitSemaphore(handle, 1, null, 0, 0, 0);
}

fn posixSemaphorePost(address: ?*const u32) callconv(abi.guest) i32 {
    const handle = posixSemaphoreHandle(address) orelse return KernelError.einval.raw();
    return signalSemaphore(handle, 1, 0, 0, 0, 0);
}

fn posixSemaphoreDestroy(address: ?*u32) callconv(abi.guest) i32 {
    const semaphore = address orelse return KernelError.einval.raw();
    const handle = posixSemaphoreHandle(semaphore) orelse return KernelError.einval.raw();
    const result = deleteSemaphore(handle, 0, 0, 0, 0, 0);
    if (result == 0) semaphore.* = 0;
    return result;
}

fn getArgc() callconv(abi.guest) i32 {
    return 1;
}

fn getArgv() callconv(abi.guest) u64 {
    return @intFromPtr(&process_arguments);
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

fn posixSocketFailure(reason: i32) i32 {
    setErrno(reason);
    return -1;
}

fn posixSocketBind(descriptor: i32, address: ?[*]const u8, length: u32) callconv(abi.guest) i32 {
    if (!filesystem.isVirtualSocket(descriptor)) return posixSocketFailure(errno.Posix.ebadf);
    if (address == null or length < 2) return posixSocketFailure(errno.Posix.einval);
    return errno.ok;
}

fn posixSocketListen(descriptor: i32, backlog: i32) callconv(abi.guest) i32 {
    if (!filesystem.isVirtualSocket(descriptor)) return posixSocketFailure(errno.Posix.ebadf);
    if (backlog < 0) return posixSocketFailure(errno.Posix.einval);
    return errno.ok;
}

fn writeLoopbackSocketAddress(address: ?[*]u8, length: ?*u32) bool {
    const size_pointer = length orelse return address == null;
    const capacity = size_pointer.*;
    size_pointer.* = 16;
    const output = address orelse return false;
    if (capacity < 16) return false;
    @memset(output[0..16], 0);
    output[0] = 16;
    output[1] = 2; // AF_INET
    output[2] = 0x9c; // synthetic port 40000, network byte order
    output[3] = 0x40;
    output[4] = 127;
    output[7] = 1;
    return true;
}

fn posixSocketAccept(descriptor: i32, address: ?[*]u8, length: ?*u32) callconv(abi.guest) i32 {
    if (!filesystem.isVirtualSocket(descriptor)) return posixSocketFailure(errno.Posix.ebadf);
    if ((address == null) != (length == null)) return posixSocketFailure(errno.Posix.efault);
    if (!writeLoopbackSocketAddress(address, length)) return posixSocketFailure(errno.Posix.einval);
    return filesystem.openVirtualSocket() catch posixSocketFailure(errno.Posix.emfile);
}

fn posixSocketName(descriptor: i32, address: ?[*]u8, length: ?*u32) callconv(abi.guest) i32 {
    if (!filesystem.isVirtualSocket(descriptor)) return posixSocketFailure(errno.Posix.ebadf);
    return if (writeLoopbackSocketAddress(address, length)) errno.ok else posixSocketFailure(errno.Posix.einval);
}

fn posixSocketGetOption(
    descriptor: i32,
    _: i32,
    _: i32,
    value: ?*i32,
    length: ?*u32,
) callconv(abi.guest) i32 {
    if (!filesystem.isVirtualSocket(descriptor)) return posixSocketFailure(errno.Posix.ebadf);
    const output = value orelse return posixSocketFailure(errno.Posix.efault);
    const size = length orelse return posixSocketFailure(errno.Posix.efault);
    if (size.* < @sizeOf(i32)) return posixSocketFailure(errno.Posix.einval);
    output.* = 0;
    size.* = @sizeOf(i32);
    return errno.ok;
}

fn posixSocketSend(descriptor: i32, buffer: ?[*]const u8, length: usize, _: i32) callconv(abi.guest) i64 {
    if (!filesystem.isVirtualSocket(descriptor)) return posixSocketFailure(errno.Posix.ebadf);
    if (buffer == null and length != 0) return posixSocketFailure(errno.Posix.efault);
    return @intCast(filesystem.writeVirtualSocket(descriptor, length) catch return posixSocketFailure(errno.Posix.ebadf));
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
    args_size: u64,
    args: u64,
    _: u32,
    _: u64,
    result: ?*i32,
) callconv(abi.guest) i32 {
    const name = path orelse return KernelError.efault.raw();
    var name_buffer: [1024]u8 = undefined;
    const module_path = readGuestCString(@intFromPtr(name), &name_buffer) orelse
        return KernelError.efault.raw();
    const loaded = modules.findByPath(module_path) orelse {
        if (trace.announces("sceKernelLoadStartModule")) {
            std.debug.print("[module] not mapped: {s}\n", .{module_path});
        }
        return KernelError.enoent.raw();
    };

    if (trace.announces("sceKernelLoadStartModule")) {
        std.debug.print("[module] start: {s} handle={d} args={d}@0x{x}\n", .{
            module_path,
            loaded.handle,
            args_size,
            args,
        });
    }

    const start_result = loaded.startDeferred(args_size, args);
    if (result) |out| out.* = start_result;
    return loaded.handle;
}

fn kernelDlsym(
    handle: i32,
    symbol_name: ?[*:0]const u8,
    destination: ?*u64,
) callconv(abi.guest) i32 {
    const output = destination orelse return KernelError.efault.raw();
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u64))) {
        return KernelError.efault.raw();
    }
    output.* = 0;
    const raw_name = symbol_name orelse return KernelError.efault.raw();
    var name_buffer: [1024]u8 = undefined;
    const name = readGuestCString(@intFromPtr(raw_name), &name_buffer) orelse
        return KernelError.efault.raw();
    if (modules.findByHandle(handle) == null) return KernelError.esrch.raw();
    if (modules.resolveExport(handle, name)) |address| {
        output.* = address;
        if (trace.announces("sceKernelDlsym")) {
            std.debug.print("[module] dlsym handle={d} {s} -> 0x{x}\n", .{ handle, name, address });
        }
        return errno.ok;
    }

    // Unity's IL2CPP runtime asks the main executable for this private bridge.
    // It is supplied by libkernel on the console rather than by the executable's
    // dynamic symbol table, so a normal export lookup cannot find it.
    if (handle == modules.executable_handle and std.mem.eql(u8, name, "scriptingGetMem")) {
        output.* = @intFromPtr(trace.wrap("scriptingGetMem", &scriptingGetMem));
        if (trace.announces("sceKernelDlsym")) {
            std.debug.print("[module] dlsym handle={d} {s} -> 0x{x}\n", .{ handle, name, output.* });
        }
        return errno.ok;
    }

    if (trace.announces("sceKernelDlsym")) {
        std.debug.print("[module] missing export handle={d}: {s}\n", .{ handle, name });
    }

    return KernelError.enoent.raw();
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
pub fn getModuleInfoForUnwind(
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

    if (unwind.find(address)) |owner| {
        unwind.describe(owner, out);
        return errno.ok;
    }

    // Native HLE calls sit directly on the same x64 stack as guest code. A
    // throw made under one therefore reaches a host return PC after the last
    // guest frame. Confirm both that it lies outside every console window and
    // that VirtualQuery marks it executable before reporting a terminal bridge
    // segment; unknown guest PCs must retain ESRCH rather than being hidden.
    for (host_memory.guest_ranges) |range| {
        if (range.contains(address, 1)) return KernelError.esrch.raw();
    }
    if (!host_memory.isHostRangeExecutable(address, 1)) return KernelError.esrch.raw();
    unwind.describeHostBoundary(address, out);
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
pub fn guestWrite(descriptor: i32, buffer: ?[*]const u8, length: u64) callconv(abi.guest) i64 {
    if (descriptor != 1 and descriptor != 2) {
        if (filesystem.isVirtualSocket(descriptor)) {
            if (buffer == null and length != 0) {
                setErrno(errno.Posix.efault);
                return -1;
            }
            return @intCast(filesystem.writeVirtualSocket(descriptor, @intCast(length)) catch {
                setErrno(errno.Posix.ebadf);
                return -1;
            });
        }
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
    // After a contained fault the launcher requests a stop. AGC's suspendPoint
    // loop only talks to the host through this write; exiting here ends those
    // workers without waiting on a join that never completes.
    if (guestStopRequested()) threading.scePthreadExit(null);
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

/// Unity allocation bridge returned by `sceKernelDlsym(0, "scriptingGetMem")`.
///
/// The genuine libc publishes ten allocator callbacks through
/// `_sceKernelRtldSetApplicationHeapAPI`; slot six is `posix_memalign`. Calling
/// that guest function keeps allocations owned by libc, so Unity can later
/// release them through the matching heap implementation.
fn scriptingGetMem(requested_alignment: u64, size: u64) callconv(abi.guest) ?*anyopaque {
    const alignment = @max(requested_alignment, @as(u64, 0x10));
    if (!std.math.isPowerOfTwo(alignment)) return null;

    const api_address = application_heap_api.load(.acquire);
    const api_size = @sizeOf([10]u64);
    if (!memory_api.isGuestRangeAccessible(api_address, api_size)) return null;
    const api: *const [10]u64 = @ptrFromInt(api_address);
    const posix_memalign = api[6];
    if (posix_memalign == 0) return null;

    // The callback executes synchronously on this host worker. Like the real
    // runtime bridge, a temporary output word is therefore valid until it
    // returns; only the allocated guest pointer escapes this frame.
    var address: u64 = 0;
    const status = threading.callGuestCurrent(posix_memalign, &.{
        @intFromPtr(&address),
        alignment,
        size,
    }) catch return null;
    if (@as(u32, @truncate(status)) != 0 or address == 0) return null;
    return @ptrFromInt(address);
}

// The system libc treats these as optional callback tables, not optional table
// pointers. A null table is dereferenced while it installs the C/C++ allocation
// layer; the supported "no replacement hooks" state is a valid structure whose
// size field is populated and whose callback slots are all null.
var sanitizer_malloc_replace = [_]u64{@sizeOf([14]u64)} ++ [_]u64{0} ** 13;
var sanitizer_new_replace = [_]u64{@sizeOf([13]u64)} ++ [_]u64{0} ** 12;

fn sanitizerMallocReplaceExternal() callconv(abi.guest) *anyopaque {
    return @ptrCast(&sanitizer_malloc_replace);
}

fn sanitizerNewReplaceExternal() callconv(abi.guest) *anyopaque {
    return @ptrCast(&sanitizer_new_replace);
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

/// A synchronous host operation that can contain excess emulator latency.
///
/// GPU submission is asynchronous on the console, but the current backend
/// decodes, translates, executes, and reads back the work before returning from
/// the submit call. The first short interval remains guest process time so
/// ordinary titles keep advancing their clocks; only latency past that grace
/// period is hidden from engine watchdogs.
pub const HostTimeExclusion = struct {
    active: bool = false,

    pub fn end(self: *HostTimeExclusion) void {
        if (!self.active) return;
        self.active = false;
        const now = nonnegativeNanoseconds(clockNanoseconds(1));

        _ = process_clock_sequence.fetchAdd(1, .acq_rel);
        const started = active_host_exclusion_start.swap(0, .acq_rel);
        const excess = excessHostNanoseconds(started, now);
        if (excess != 0) _ = excluded_host_nanoseconds.fetchAdd(excess, .monotonic);
        _ = process_clock_sequence.fetchAdd(1, .release);
    }
};

pub fn beginHostTimeExclusion() HostTimeExclusion {
    if (active_io == null) return .{};
    const now = nonnegativeNanoseconds(clockNanoseconds(1));
    if (now == 0 or active_host_exclusion_start.load(.acquire) != 0) return .{};

    _ = process_clock_sequence.fetchAdd(1, .acq_rel);
    active_host_exclusion_start.store(now, .release);
    _ = process_clock_sequence.fetchAdd(1, .release);
    return .{ .active = true };
}

fn nonnegativeNanoseconds(value: i96) u64 {
    if (value <= 0) return 0;
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn excessHostNanoseconds(started: u64, now: u64) u64 {
    if (started == 0 or now <= started) return 0;
    return (now - started) -| host_time_exclusion_grace_ns;
}

fn effectiveProcessNanoseconds(now: i96, started: i96, excluded: u64, active_start: u64) u64 {
    const elapsed: u64 = nonnegativeNanoseconds(@max(@as(i96, 0), now - started));
    var total_excluded = excluded;
    const current = nonnegativeNanoseconds(now);
    total_excluded +|= excessHostNanoseconds(active_start, current);
    return elapsed -| total_excluded;
}

/// Guest monotonic clocks share the same latency correction as process time,
/// but keep the host clock's epoch. Engines use clock_gettime(CLOCK_MONOTONIC)
/// for RenderThread watchdogs; exposing minutes spent synchronously translating
/// a GPU submission makes those watchdogs diagnose an emulator stall as a game
/// stall. Realtime remains untouched because calendar time must not pause.
fn effectiveMonotonicNanoseconds(now: i96, excluded: u64, active_start: u64) u64 {
    const current = nonnegativeNanoseconds(now);
    var total_excluded = excluded;
    total_excluded +|= excessHostNanoseconds(active_start, current);
    return current -| total_excluded;
}

fn guestMonotonicNanoseconds() u64 {
    while (true) {
        const before = process_clock_sequence.load(.acquire);
        if (before & 1 != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        const excluded = excluded_host_nanoseconds.load(.monotonic);
        const active_start = active_host_exclusion_start.load(.monotonic);
        const now = clockNanoseconds(1);
        if (before == process_clock_sequence.load(.acquire)) {
            return effectiveMonotonicNanoseconds(now, excluded, active_start);
        }
    }
}

/// Converts a deadline obtained from the latency-corrected guest monotonic
/// clock back to the host awake-clock epoch used by the scheduler futex. The
/// pair must use the same exclusion snapshot or a corrected absolute timeout
/// would appear to have expired immediately on the host.
pub fn hostMonotonicDeadline(guest_deadline_ns: u64) u64 {
    while (true) {
        const before = process_clock_sequence.load(.acquire);
        if (before & 1 != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        var excluded = excluded_host_nanoseconds.load(.monotonic);
        const active_start = active_host_exclusion_start.load(.monotonic);
        const now = nonnegativeNanoseconds(clockNanoseconds(1));
        excluded +|= excessHostNanoseconds(active_start, now);
        if (before == process_clock_sequence.load(.acquire)) {
            return guest_deadline_ns +| excluded;
        }
    }
}

fn processNanoseconds() u64 {
    while (true) {
        const before = process_clock_sequence.load(.acquire);
        if (before & 1 != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        const excluded = excluded_host_nanoseconds.load(.monotonic);
        const active_start = active_host_exclusion_start.load(.monotonic);
        const now = clockNanoseconds(1);
        if (before == process_clock_sequence.load(.acquire)) {
            return effectiveProcessNanoseconds(now, process_start_nanoseconds, excluded, active_start);
        }
    }
}

fn writeTimespec(clock_id: i32, output: ?*Timespec, kernel_errors: bool) i32 {
    const value = output orelse return if (kernel_errors)
        KernelError.einval.raw()
    else blk: {
        setErrno(errno.Posix.einval);
        break :blk -1;
    };
    const nanoseconds: i96 = if (clock_id == 0)
        clockNanoseconds(0)
    else
        guestMonotonicNanoseconds();
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

fn usleep(microseconds: u32) callconv(abi.guest) i32 {
    const status = threading.sceKernelUsleep(microseconds);
    if (status == errno.ok) return errno.ok;
    setErrno(errno.kernelToPosix(status));
    return -1;
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

/// Process time in microseconds since attach — used by VideoOut flip status
/// so titles can pace off completed flips.
pub fn processTimeMicroseconds() u64 {
    return processNanoseconds() / std.time.ns_per_us;
}

/// Nanosecond process-time counter (same units as sceKernelGetProcessTimeCounter).
pub fn processTimeCounter() u64 {
    return processNanoseconds();
}

fn getProcessTime() callconv(abi.guest) u64 {
    return processTimeMicroseconds();
}

fn getProcessTimeCounter() callconv(abi.guest) u64 {
    return processTimeCounter();
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
    timezone: ?*ConversionTimezone,
    dst_seconds: ?*i32,
) callconv(abi.guest) i32 {
    const zone = timezone orelse return KernelError.einval.raw();
    zone.* = .{
        .minutes_west = 0,
        .dst_time = 0,
        .west_seconds = 0,
        .dst_seconds = 0,
    };
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

fn getOpenPsId(output: ?*[16]u8) callconv(abi.guest) i32 {
    const identifier = output orelse return KernelError.einval.raw();
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(identifier), 16)) {
        return KernelError.efault.raw();
    }
    identifier.* = .{
        'P', 'S', '5', 'P', 'C', 'E', 'M', 0,
        'O', 'p', 'e', 'n', 'P', 's', 'I', 'd',
    };
    return errno.ok;
}

pub const exports = [_]symbols.Export{
    .{ .name = "_sceKernelSetThreadDtors", .function = trace.wrap("_sceKernelSetThreadDtors", &setThreadDtors), .expect_id = "rNhWz+lvOMU" },
    .{ .name = "_sceKernelSetThreadAtexitCount", .function = trace.wrap("_sceKernelSetThreadAtexitCount", &setThreadAtexitCount), .expect_id = "pB-yGZ2nQ9o" },
    .{ .name = "_sceKernelSetThreadAtexitReport", .function = trace.wrap("_sceKernelSetThreadAtexitReport", &setThreadAtexitReport), .expect_id = "WhCc1w3EhSI" },
    .{ .name = "sceKernelDebugRaiseException", .function = trace.wrap("sceKernelDebugRaiseException", &compatSuccess), .expect_id = "OMDRKKAZ8I4" },
    .{ .name = "sceKernelDebugRaiseExceptionOnReleaseMode", .function = trace.wrap("sceKernelDebugRaiseExceptionOnReleaseMode", &compatSuccess), .expect_id = "zE-wXIZjLoM" },
    .{ .name = "__error", .function = trace.wrap("__error", &errorAddress), .expect_id = "9BcDykPmo1I" },
    .{ .name = "getargc", .function = trace.wrap("getargc", &getArgc), .expect_id = "iKJMWrAumPE" },
    .{ .name = "getargv", .function = trace.wrap("getargv", &getArgv), .expect_id = "FJmglmTMdr4" },
    .{ .name = "__stack_chk_fail", .function = trace.wrap("__stack_chk_fail", &stackCheckFail), .expect_id = "Ou3iL1abvng" },
    .{ .name = "signal", .function = trace.wrap("signal", &compatSuccess), .expect_id = "VADc3MNQ3cM" },
    .{ .name = "sceKernelGetProcParam", .function = trace.wrap("sceKernelGetProcParam", &getProcParam), .expect_id = "959qrazPIrg" },
    .{ .name = "nanosleep", .function = trace.wrap("nanosleep", &nanosleep), .expect_id = "yS8U2TGCe1A" },
    .{ .name = "gettimeofday", .function = trace.wrap("gettimeofday", &gettimeofday), .expect_id = "n88vx3C5nW8" },
    .{ .name = "_sceKernelRtldSetApplicationHeapAPI", .function = trace.wrap("_sceKernelRtldSetApplicationHeapAPI", &setApplicationHeapApi), .expect_id = "p5EcQeEeJAE" },
    .{ .name = "sceKernelGetSanitizerMallocReplaceExternal", .function = trace.wrap("sceKernelGetSanitizerMallocReplaceExternal", &sanitizerMallocReplaceExternal), .expect_id = "py6L8jiVAN8" },
    .{ .name = "sceKernelInternalMemoryGetModuleSegmentInfo", .function = trace.wrap("sceKernelInternalMemoryGetModuleSegmentInfo", &kernelUnsupported), .expect_id = "-YTW+qXc3CQ" },
    .{ .name = "sceKernelMapNamedFlexibleMemoryInternal", .function = trace.wrap("sceKernelMapNamedFlexibleMemoryInternal", &mapNamedFlexibleMemoryInternal), .expect_id = "4h6F1LLbTiw" },
    .{ .name = "sceKernelMlock", .function = trace.wrap("sceKernelMlock", &compatSuccess), .expect_id = "3k6kx-zOOSQ" },
    .{ .name = "sceKernelIsAddressSanitizerEnabled", .function = trace.wrap("sceKernelIsAddressSanitizerEnabled", &compatSuccess), .expect_id = "jh+8XiK4LeE" },
    .{ .name = "_write", .function = trace.wrap("_write", &guestWrite), .expect_id = "FxVZqBAA7ks" },
    .{ .name = "rmdir", .function = trace.wrap("rmdir", &posixUnsupported), .expect_id = "c7ZnT7V1B98" },
    .{ .name = "unlink", .function = trace.wrap("unlink", &posixUnsupported), .expect_id = "VAzswvTOCzI" },
    .{ .name = "sceKernelGetSanitizerNewReplaceExternal", .function = trace.wrap("sceKernelGetSanitizerNewReplaceExternal", &sanitizerNewReplaceExternal), .expect_id = "bnZxYgAFeA0" },
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
    .{ .name = "sceKernelDlsym", .function = trace.wrap("sceKernelDlsym", &kernelDlsym), .expect_id = "LwG8g3niqwA" },
    .{ .name = "sceKernelLoadStartModule", .function = trace.wrap("sceKernelLoadStartModule", &loadStartModule), .expect_id = "wzvqT4UqKX8" },
    .{ .name = "sceKernelStopUnloadModule", .function = trace.wrap("sceKernelStopUnloadModule", &stopUnloadModule), .expect_id = "QKd0qM58Qes" },
    .{ .name = "sceKernelGetProcessTimeCounter", .function = trace.wrap("sceKernelGetProcessTimeCounter", &getProcessTimeCounter), .expect_id = "fgxnMeTNUtY" },
    .{ .name = "sceKernelGetProcessTimeCounterFrequency", .function = trace.wrap("sceKernelGetProcessTimeCounterFrequency", &getProcessTimeCounterFrequency), .expect_id = "BNowx2l588E" },
    .{ .name = "sceKernelSyncOnAddressWait32", .function = trace.wrap("sceKernelSyncOnAddressWait32", &syncOnAddressWait32), .expect_id = "B2n8aDorSH4" },
    .{ .name = "sceKernelSyncOnAddressWait64", .function = trace.wrap("sceKernelSyncOnAddressWait64", &syncOnAddressWait64), .expect_id = "PZQhiiLXRFs" },
    .{ .name = "sceKernelSyncOnAddressWake", .function = trace.wrap("sceKernelSyncOnAddressWake", &syncOnAddressWake), .expect_id = "q2y-wDIVWZA" },
    .{ .name = "sceKernelSyncOnAddressWait", .function = trace.wrap("sceKernelSyncOnAddressWait", &syncOnAddressWait), .expect_id = "Hc4CaR6JBL0" },
    .{ .name = "sceKernelIsTrinityMode", .function = trace.wrap("sceKernelIsTrinityMode", &isTrinityMode), .expect_id = "tU5e3f9gSiU" },
    .{ .name = "sceKernelSetGPO", .function = trace.wrap("sceKernelSetGPO", &setGpo), .expect_id = "ca7v6Cxulzs" },
    .{ .name = "sceKernelCancelEventFlag", .function = trace.wrap("sceKernelCancelEventFlag", &cancelEventFlag), .expect_id = "PZku4ZrXJqg" },
    .{ .name = "sceKernelDeleteSema", .function = trace.wrap("sceKernelDeleteSema", &deleteSemaphore), .expect_id = "R1Jvn8bSCW8" },
    .{ .name = "sceKernelAprResolveFilepathsToIdsAndFileSizes", .function = trace.wrap("sceKernelAprResolveFilepathsToIdsAndFileSizes", &aprResolveFilepathsToIdsAndFileSizes), .expect_id = "gEpBkcwxUjw" },
    .{ .name = "sceKernelAprSubmitCommandBufferAndGetResult", .function = trace.wrap("sceKernelAprSubmitCommandBufferAndGetResult", &aprSubmitCommandBufferAndGetResult), .expect_id = "ASoW5WE-UPo" },
    .{ .name = "sceKernelAprWaitCommandBuffer", .function = trace.wrap("sceKernelAprWaitCommandBuffer", &aprWaitCommandBuffer), .expect_id = "rqwFKI4PAiM" },

    .{ .name = "sceKernelAprGetFileStat", .function = trace.wrap("sceKernelAprGetFileStat", &aprGetFileStat), .expect_id = "ApkYaHb8Sek" },
    .{ .name = "sceKernelAprGetFileSize", .function = trace.wrap("sceKernelAprGetFileSize", &aprGetFileSize), .expect_id = "WvEu7yl3Ivg" },
    .{ .name = "sceKernelAprResolveFilepathsToIds", .function = trace.wrap("sceKernelAprResolveFilepathsToIds", &aprResolveFilepathsToIds), .expect_id = "WT-5NKy42fw" },

    // The remaining accelerator path variants are reported unimplemented.
    // Unlike the entries above, no currently exercised caller depends on an
    // identifier or stat record from them yet; they must join the same APR
    // registry before they can truthfully report success.
    .{ .name = "sceKernelAprResolveFilepathsToIdsForEach", .function = trace.wrap("sceKernelAprResolveFilepathsToIdsForEach", &kernelUnsupported), .expect_id = "eYAh2vlCY-U" },
    .{ .name = "sceKernelAprResolveFilepathsToIdsAndFileSizesForEach", .function = trace.wrap("sceKernelAprResolveFilepathsToIdsAndFileSizesForEach", &kernelUnsupported), .expect_id = "QzB4O+bJQyA" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIds", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIds", &kernelUnsupported), .expect_id = "i3HWvW35jao" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIdsForEach", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIdsForEach", &kernelUnsupported), .expect_id = "VB-BtuIW8Xc" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizes", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizes", &kernelUnsupported), .expect_id = "w5fcCG+t31g" },
    .{ .name = "sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizesForEach", .function = trace.wrap("sceKernelAprResolveFilepathsWithPrefixToIdsAndFileSizesForEach", &kernelUnsupported), .expect_id = "C+Khtbbx2g8" },
    .{ .name = "sceKernelAprSubmitCommandBuffer", .function = trace.wrap("sceKernelAprSubmitCommandBuffer", &kernelUnsupported), .expect_id = "eE4Szl8sil8" },
    .{ .name = "sceKernelAprSubmitCommandBufferAndGetId", .function = trace.wrap("sceKernelAprSubmitCommandBufferAndGetId", &kernelUnsupported), .expect_id = "qvMUCyyaCSI" },
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
    .{ .name = "send", .function = trace.wrap("send", &posixSocketSend), .expect_id = "fZOeZIOEmLw" },
    .{ .name = "usleep", .function = trace.wrap("usleep", &usleep), .expect_id = "QcteRwbsnV0" },
    .{ .name = "sem_init", .function = trace.wrap("sem_init", &posixSemaphoreInit), .expect_id = "pDuPEf3m4fI" },
    .{ .name = "sem_wait", .function = trace.wrap("sem_wait", &posixSemaphoreWait), .expect_id = "YCV5dGGBcCo" },
    .{ .name = "sem_post", .function = trace.wrap("sem_post", &posixSemaphorePost), .expect_id = "IKP8typ0QUk" },
    .{ .name = "sem_destroy", .function = trace.wrap("sem_destroy", &posixSemaphoreDestroy), .expect_id = "cDW233RAwWo" },

    // The rest of the socket surface, refused like `send` above it. The
    // networking model here is deliberately offline — no host socket is ever
    // opened — and a title told that a socket bound, listened, or accepted
    // would then wait for a peer that cannot arrive. An error it can see is
    // the better answer, and it is the one it would get from a console with no
    // connection.
    .{ .name = "bind", .function = trace.wrap("bind", &posixSocketBind), .expect_id = "KuOmgKoqCdY" },
    .{ .name = "listen", .function = trace.wrap("listen", &posixSocketListen), .expect_id = "pxnCmagrtao" },
    .{ .name = "accept", .function = trace.wrap("accept", &posixSocketAccept), .expect_id = "3e+4Iv7IJ8U" },
    .{ .name = "sendto", .function = trace.wrap("sendto", &posixUnsupported), .expect_id = "oBr313PppNE" },
    .{ .name = "recvfrom", .function = trace.wrap("recvfrom", &posixUnsupported), .expect_id = "lUk6wrGXyMw" },
    .{ .name = "getsockname", .function = trace.wrap("getsockname", &posixSocketName), .expect_id = "RenI1lL1WFk" },
    .{ .name = "getpeername", .function = trace.wrap("getpeername", &posixSocketName), .expect_id = "TXFFFiNldU8" },
    .{ .name = "getsockopt", .function = trace.wrap("getsockopt", &posixSocketGetOption), .expect_id = "6O8EwYOgH9Y" },

    // Descriptor flags. Refused rather than answered, because the flag a title
    // most often sets here is non-blocking, and claiming that took effect on a
    // descriptor that ignores it invites the title to spin.
    .{ .name = "fcntl", .function = trace.wrap("fcntl", &posixUnsupported), .expect_id = "8nY19bKoiZk" },
};

const open_ps_id_exports = [_]symbols.Export{
    .{ .name = "sceKernelGetOpenPsId", .function = trace.wrap("sceKernelGetOpenPsId", &getOpenPsId), .expect_id = "DLORcroUqbc" },
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
    try db.addLibrary(
        gpa,
        .{ .name = "libSceOpenPsId", .version = 1 },
        module,
        &open_ps_id_exports,
    );
}

test "calendar conversion clears the complete PS5 timezone result" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 16), @sizeOf(ConversionTimezone));

    var utc_time: i64 = -1;
    var timezone = ConversionTimezone{
        .minutes_west = 1,
        .dst_time = 2,
        .west_seconds = 3,
        .dst_seconds = 4,
    };
    var dst_seconds: i32 = -1;
    try testing.expectEqual(
        errno.ok,
        convertLocaltimeToUtc(1_234_567, 0, &utc_time, &timezone, &dst_seconds),
    );
    try testing.expectEqual(@as(i64, 1_234_567), utc_time);
    try testing.expectEqualDeep(
        ConversionTimezone{
            .minutes_west = 0,
            .dst_time = 0,
            .west_seconds = 0,
            .dst_seconds = 0,
        },
        timezone,
    );
    try testing.expectEqual(@as(i32, 0), dst_seconds);
}

test "runtime compatibility exports include libc bootstrap data and private NIDs" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);

    try std.testing.expect(db.findByName("__stack_chk_guard", .object) != null);
    try std.testing.expect(db.findByName("__progname", .object) != null);
    try std.testing.expect(db.findByName("__tls_get_addr", .function) != null);
    try std.testing.expect(db.findById("B2n8aDorSH4", .function) != null);
    try std.testing.expect(db.findByName("sceKernelSyncOnAddressWait32", .function) != null);
    try std.testing.expect(db.findByName("sceKernelSyncOnAddressWait64", .function) != null);
    try std.testing.expect(db.findByName("sceKernelSyncOnAddressWait", .function) != null);
    try std.testing.expect(db.findByName("sceKernelSyncOnAddressWake", .function) != null);
}

test "sanitizer replacement queries return sized empty hook tables" {
    const testing = std.testing;
    const malloc_hooks: *[14]u64 = @ptrCast(@alignCast(sanitizerMallocReplaceExternal()));
    const new_hooks: *[13]u64 = @ptrCast(@alignCast(sanitizerNewReplaceExternal()));

    try testing.expectEqual(@as(u64, @sizeOf(@TypeOf(malloc_hooks.*))), malloc_hooks[0]);
    try testing.expectEqual(@as(u64, @sizeOf(@TypeOf(new_hooks.*))), new_hooks[0]);
    try testing.expectEqualSlices(u64, &([_]u64{0} ** 13), malloc_hooks[1..]);
    try testing.expectEqualSlices(u64, &([_]u64{0} ** 12), new_hooks[1..]);
    try testing.expectEqual(@intFromPtr(malloc_hooks), @intFromPtr(sanitizerMallocReplaceExternal()));
    try testing.expectEqual(@intFromPtr(new_hooks), @intFromPtr(sanitizerNewReplaceExternal()));
}

const ApplicationHeapTestBackend = struct {
    allocated_address: u64,
    last_call: ?threading.GuestCall = null,

    fn start(_: ?*anyopaque, _: threading.StartRequest) threading.BackendError!void {
        return error.Unsupported;
    }

    fn call(raw: ?*anyopaque, request: threading.GuestCall) threading.BackendError!u64 {
        const self: *ApplicationHeapTestBackend = @ptrCast(@alignCast(raw.?));
        if (request.argument_count != 3) return error.CallFailed;
        const output: *u64 = @ptrFromInt(request.arguments[0]);
        output.* = self.allocated_address;
        self.last_call = request;
        return 0;
    }

    fn backend(self: *ApplicationHeapTestBackend) threading.Backend {
        return .{
            .context = self,
            .start_fn = &start,
            .call_fn = &call,
        };
    }
};

test "host time exclusions preserve normal submits and hide only excess latency" {
    const ms = std.time.ns_per_ms;
    try std.testing.expectEqual(
        @as(u64, 225 * ms),
        effectiveProcessNanoseconds(1250 * ms, 1000 * ms, 25 * ms, 0),
    );
    try std.testing.expectEqual(
        @as(u64, 175 * ms),
        effectiveProcessNanoseconds(1250 * ms, 1000 * ms, 25 * ms, 1100 * ms),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        effectiveProcessNanoseconds(1050 * ms, 1000 * ms, 200 * ms, 0),
    );
    try std.testing.expectEqual(@as(u64, 0), excessHostNanoseconds(1000 * ms, 1100 * ms));
    try std.testing.expectEqual(@as(u64, 50 * ms), excessHostNanoseconds(1000 * ms, 1150 * ms));
    try std.testing.expectEqual(
        @as(u64, 1175 * ms),
        effectiveMonotonicNanoseconds(1250 * ms, 25 * ms, 1100 * ms),
    );
}

test "Unity scripting allocator uses the application heap memalign callback" {
    var thread_manager = threading.Manager{};
    var backend = ApplicationHeapTestBackend{ .allocated_address = 0x1234_5000 };
    thread_manager.setBackend(backend.backend());
    threading.attachManager(&thread_manager);
    defer threading.attachManager(null);

    var api = [_]u64{0} ** 10;
    api[6] = 0xfeed_0000;
    try std.testing.expectEqual(errno.ok, setApplicationHeapApi(@intFromPtr(&api)));
    defer application_heap_api.store(0, .release);

    try std.testing.expectEqual(
        @as(?*anyopaque, @ptrFromInt(backend.allocated_address)),
        scriptingGetMem(8, 0x40000),
    );
    try std.testing.expectEqual(@as(u64, 0xfeed_0000), backend.last_call.?.entry_point);
    try std.testing.expectEqual(@as(u64, 0x10), backend.last_call.?.arguments[1]);
    try std.testing.expectEqual(@as(u64, 0x40000), backend.last_call.?.arguments[2]);
    try std.testing.expect(scriptingGetMem(24, 1) == null);
}

const SyncAddressTestBackend = struct {
    wait_request: ?threading.WaitRequest = null,
    wait_result: threading.WaitResult = .awoken,
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
        return self.wait_result;
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

const SemaphoreTestAction = enum { signal, cancel, delete };

const SemaphoreTestBackend = struct {
    handle: u32 = 0,
    action: SemaphoreTestAction = .signal,
    wait_request: ?threading.WaitRequest = null,
    wake_key: u64 = 0,
    wake_sequence: u64 = 0,
    wake_count: usize = 0,
    poll_after_signal: i32 = 0,

    fn start(_: ?*anyopaque, _: threading.StartRequest) threading.BackendError!void {
        return error.Unsupported;
    }

    fn wait(
        raw: ?*anyopaque,
        request: threading.WaitRequest,
    ) threading.BackendError!threading.WaitResult {
        const self: *SemaphoreTestBackend = @ptrCast(@alignCast(raw.?));
        self.wait_request = request;
        switch (self.action) {
            .signal => {
                if (signalSemaphore(self.handle, 1, 0, 0, 0, 0) != 0) return error.WaitFailed;
                self.poll_after_signal = pollSemaphore(self.handle, 1, 0, 0, 0, 0);
            },
            .cancel => {
                if (cancelSemaphore(self.handle, 0, null, 0, 0, 0) != 0) return error.WaitFailed;
            },
            .delete => {
                if (deleteSemaphore(self.handle, 0, 0, 0, 0, 0) != 0) return error.WaitFailed;
            },
        }
        return .awoken;
    }

    fn wake(
        raw: ?*anyopaque,
        key: u64,
        sequence: u64,
        maximum_waiters: usize,
    ) void {
        const self: *SemaphoreTestBackend = @ptrCast(@alignCast(raw.?));
        self.wake_key = key;
        self.wake_sequence = sequence;
        self.wake_count = maximum_waiters;
    }

    fn backend(self: *SemaphoreTestBackend) threading.Backend {
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

    var word: u32 = 0;
    const address: u64 = @intFromPtr(&word);
    try testing.expectEqual(KernelError.einval.raw(), syncOnAddressWait(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(i32, 0), syncOnAddressWait(address, 0, 0, 0, 0, 0));
    try testing.expectEqual(address, backend.wait_request.?.key);
    try testing.expectEqual(@as(u64, 1), backend.wait_request.?.observed_sequence);
    try testing.expectEqual(sync_address_poll_us, backend.wait_request.?.timeout_microseconds.?);

    try testing.expectEqual(@as(i32, 0), syncOnAddressWake(address, 1, 0, 0, 0, 0));
    try testing.expectEqual(address, backend.wake_key);
    try testing.expectEqual(@as(u64, 2), backend.wake_sequence);
    try testing.expectEqual(@as(usize, 1), backend.wake_count);

    try testing.expectEqual(@as(i32, 0), syncOnAddressWait(address, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u64, 2), backend.wait_request.?.observed_sequence);
    try testing.expectEqual(@as(i32, 0), syncOnAddressWake(address, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(usize, 1), backend.wake_count);
    try testing.expectEqual(KernelError.einval.raw(), syncOnAddressWake(address, std.math.maxInt(u64), 0, 0, 0, 0));
}

test "typed address waits compare values and honor timeout pointers" {
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

    var word: u32 = 7;
    const address: u64 = @intFromPtr(&word);
    var timeout_us: u32 = 1_000_000;
    try testing.expectEqual(@as(i32, 0), syncOnAddressWait(address, 3, @intFromPtr(&timeout_us), 0, 0, 0));
    try testing.expect(backend.wait_request == null);

    word = 3;
    timeout_us = 0;
    try testing.expectEqual(KernelError.etimedout.raw(), syncOnAddressWait(address, 3, @intFromPtr(&timeout_us), 0, 0, 0));
    try testing.expect(backend.wait_request == null);

    timeout_us = 1_000;
    backend.wait_result = .timed_out;
    try testing.expectEqual(KernelError.etimedout.raw(), syncOnAddressWait32(address, 3, @intFromPtr(&timeout_us), 0, 0, 0));
    try testing.expectEqual(@as(u64, timeout_us), backend.wait_request.?.timeout_microseconds.?);

    var word64: u64 = 0x1_0000_0000;
    backend.wait_request = null;
    try testing.expectEqual(@as(i32, 0), syncOnAddressWait64(@intFromPtr(&word64), 0, 0, 0, 0, 0));
    try testing.expect(backend.wait_request == null);
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

test "semaphore signal reserves a token for the already blocked waiter" {
    const testing = std.testing;
    resetKernelObjects();

    var thread_manager = threading.Manager{};
    var backend = SemaphoreTestBackend{};
    thread_manager.setBackend(backend.backend());
    threading.attachManager(&thread_manager);
    defer threading.attachManager(null);

    const name: [:0]const u8 = "reserved-token";
    try testing.expectEqual(@as(i32, 0), createSemaphore(&backend.handle, name.ptr, 1, 0, 1, 0));
    try testing.expectEqual(@as(i32, 0), waitSemaphore(backend.handle, 1, null, 0, 0, 0));

    // Signal committed the only token to this waiter before waking it. A new
    // poll racing in from the backend cannot consume that reserved grant.
    try testing.expectEqual(KernelError.ebusy.raw(), backend.poll_after_signal);
    try testing.expect(backend.wait_request != null);
    try testing.expectEqual(backend.wait_request.?.key, backend.wake_key);
    try testing.expectEqual(@as(usize, 1), backend.wake_count);
    try testing.expect(backend.wake_sequence != 0);
}

test "semaphore cancel and delete complete blocked waiters explicitly" {
    const testing = std.testing;
    resetKernelObjects();

    var thread_manager = threading.Manager{};
    var backend = SemaphoreTestBackend{ .action = .cancel };
    thread_manager.setBackend(backend.backend());
    threading.attachManager(&thread_manager);
    defer threading.attachManager(null);

    const cancel_name: [:0]const u8 = "cancel-wait";
    try testing.expectEqual(@as(i32, 0), createSemaphore(&backend.handle, cancel_name.ptr, 0, 0, 1, 0));
    try testing.expectEqual(
        KernelError.ecanceled.raw(),
        waitSemaphore(backend.handle, 1, null, 0, 0, 0),
    );

    backend = .{ .action = .delete };
    thread_manager.setBackend(backend.backend());
    const delete_name: [:0]const u8 = "delete-wait";
    try testing.expectEqual(@as(i32, 0), createSemaphore(&backend.handle, delete_name.ptr, 0, 0, 1, 0));
    try testing.expectEqual(
        KernelError.eacces.raw(),
        waitSemaphore(backend.handle, 1, null, 0, 0, 0),
    );
    try testing.expectEqual(
        KernelError.enoent.raw(),
        pollSemaphore(backend.handle, 1, 0, 0, 0, 0),
    );
}
