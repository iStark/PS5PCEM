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

var active_io: ?std.Io = null;
var process_start_nanoseconds: i96 = 0;
var process_param_address: std.atomic.Value(u64) = .init(0);
var application_heap_api: std.atomic.Value(u64) = .init(0);
var thread_dtors: std.atomic.Value(u64) = .init(0);
var thread_atexit_count: std.atomic.Value(u64) = .init(0);
var thread_atexit_report: std.atomic.Value(u64) = .init(0);
var uuid_counter: std.atomic.Value(u64) = .init(1);
var gpo_state: std.atomic.Value(u32) = .init(0);

pub fn attachIo(io: ?std.Io) void {
    const was_detached = active_io == null;
    active_io = io;
    if (io) |value| {
        if (was_detached) {
            process_start_nanoseconds = std.Io.Clock.awake.now(value).nanoseconds;
        }
    } else {
        process_start_nanoseconds = 0;
    }
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
    .{ .name = "_read", .function = trace.wrap("_read", &posixUnsupported), .expect_id = "DRuBt2pvICk" },
    .{ .name = "_write", .function = trace.wrap("_write", &guestWrite), .expect_id = "FxVZqBAA7ks" },
    .{ .name = "_open", .function = trace.wrap("_open", &posixUnsupported), .expect_id = "6c3rCVE-fTU" },
    .{ .name = "_close", .function = trace.wrap("_close", &posixUnsupported), .expect_id = "NNtFaKJbPt0" },
    .{ .name = "lseek", .function = trace.wrap("lseek", &posixUnsupported), .expect_id = "Oy6IpwgtYOk" },
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
    .{ .name = "sceKernelCreateEventFlag", .function = trace.wrap("sceKernelCreateEventFlag", &kernelUnsupported), .expect_id = "BpFoboUJoZU" },
    .{ .name = "sceKernelCreateSema", .function = trace.wrap("sceKernelCreateSema", &kernelUnsupported), .expect_id = "188x57JYp0g" },
    .{ .name = "sceKernelSignalSema", .function = trace.wrap("sceKernelSignalSema", &kernelUnsupported), .expect_id = "4czppHBiriw" },
    .{ .name = "sceKernelWaitEventFlag", .function = trace.wrap("sceKernelWaitEventFlag", &kernelUnsupported), .expect_id = "JTvBflhYazQ" },
    .{ .name = "sceKernelSetEventFlag", .function = trace.wrap("sceKernelSetEventFlag", &kernelUnsupported), .expect_id = "IOnSvHzqu6A" },
    .{ .name = "sceKernelWaitSema", .function = trace.wrap("sceKernelWaitSema", &kernelUnsupported), .expect_id = "Zxa0VhQVTsk" },
    .{ .name = "sceKernelClearEventFlag", .function = trace.wrap("sceKernelClearEventFlag", &kernelUnsupported), .expect_id = "7uhBFWRAS60" },
    .{ .name = "sceKernelDlsym", .function = trace.wrap("sceKernelDlsym", &kernelUnsupported), .expect_id = "LwG8g3niqwA" },
    .{ .name = "sceKernelLoadStartModule", .function = trace.wrap("sceKernelLoadStartModule", &loadStartModule), .expect_id = "wzvqT4UqKX8" },
    .{ .name = "sceKernelStopUnloadModule", .function = trace.wrap("sceKernelStopUnloadModule", &stopUnloadModule), .expect_id = "QKd0qM58Qes" },
    .{ .name = "sceKernelGetProcessTimeCounter", .function = trace.wrap("sceKernelGetProcessTimeCounter", &getProcessTimeCounter), .expect_id = "fgxnMeTNUtY" },
    .{ .name = "sceKernelGetProcessTimeCounterFrequency", .function = trace.wrap("sceKernelGetProcessTimeCounterFrequency", &getProcessTimeCounterFrequency), .expect_id = "BNowx2l588E" },
    .{ .name = "unknown_libkernel_B2n8aDorSH4", .function = trace.wrap("unknown_libkernel_B2n8aDorSH4", &kernelUnsupported), .id_override = "B2n8aDorSH4" },
    .{ .name = "unknown_libkernel_PZQhiiLXRFs", .function = trace.wrap("unknown_libkernel_PZQhiiLXRFs", &kernelUnsupported), .id_override = "PZQhiiLXRFs" },
    .{ .name = "sceKernelSyncOnAddressWake", .function = trace.wrap("sceKernelSyncOnAddressWake", &kernelUnsupported), .expect_id = "q2y-wDIVWZA" },
    .{ .name = "sceKernelSyncOnAddressWait", .function = trace.wrap("sceKernelSyncOnAddressWait", &kernelUnsupported), .expect_id = "Hc4CaR6JBL0" },
    .{ .name = "sceKernelIsTrinityMode", .function = trace.wrap("sceKernelIsTrinityMode", &isTrinityMode), .expect_id = "tU5e3f9gSiU" },
    .{ .name = "sceKernelSetGPO", .function = trace.wrap("sceKernelSetGPO", &setGpo), .expect_id = "ca7v6Cxulzs" },
    .{ .name = "sceKernelCancelEventFlag", .function = trace.wrap("sceKernelCancelEventFlag", &kernelUnsupported), .expect_id = "PZku4ZrXJqg" },
    .{ .name = "sceKernelDeleteSema", .function = trace.wrap("sceKernelDeleteSema", &kernelUnsupported), .expect_id = "R1Jvn8bSCW8" },
    .{ .name = "sceKernelAprResolveFilepathsToIdsAndFileSizes", .function = trace.wrap("sceKernelAprResolveFilepathsToIdsAndFileSizes", &kernelUnsupported), .expect_id = "gEpBkcwxUjw" },
    .{ .name = "sceKernelAprSubmitCommandBufferAndGetResult", .function = trace.wrap("sceKernelAprSubmitCommandBufferAndGetResult", &kernelUnsupported), .expect_id = "ASoW5WE-UPo" },
    .{ .name = "sceKernelAprWaitCommandBuffer", .function = trace.wrap("sceKernelAprWaitCommandBuffer", &kernelUnsupported), .expect_id = "rqwFKI4PAiM" },
};

pub const unity_exports = [_]symbols.Export{
    .{ .name = "sceKernelInstallExceptionHandler", .function = trace.wrap("sceKernelInstallExceptionHandler", &compatSuccess), .expect_id = "WkwEd3N7w0Y" },
    .{ .name = "sceKernelRaiseException", .function = trace.wrap("sceKernelRaiseException", &compatSuccess), .expect_id = "il03nluKfMk" },
};

pub const posix_exports = [_]symbols.Export{
    .{ .name = "stat", .function = trace.wrap("stat", &posixUnsupported), .expect_id = "E6ao34wPw+U" },
    .{ .name = "mkdir", .function = trace.wrap("mkdir", &posixUnsupported), .expect_id = "JGMio+21L4c" },
    .{ .name = "chmod", .function = trace.wrap("chmod", &posixUnsupported), .expect_id = "z0dtnPxYgtg" },
    .{ .name = "rename", .function = trace.wrap("rename", &posixUnsupported), .expect_id = "NN01qLRhiqU" },
    .{ .name = "fstat", .function = trace.wrap("fstat", &posixUnsupported), .expect_id = "mqQMh1zPPT8" },
    .{ .name = "fchmod", .function = trace.wrap("fchmod", &posixUnsupported), .expect_id = "n01yNbQO5W4" },
    .{ .name = "read", .function = trace.wrap("read", &posixUnsupported), .expect_id = "AqBioC2vF3I" },
    .{ .name = "write", .function = trace.wrap("write", &guestWrite), .expect_id = "FN4gaPmuFV8" },
    .{ .name = "futimes", .function = trace.wrap("futimes", &posixUnsupported), .expect_id = "+0EDo7YzcoU" },
    .{ .name = "open", .function = trace.wrap("open", &posixUnsupported), .expect_id = "wuCroIGjt2g" },
    .{ .name = "close", .function = trace.wrap("close", &posixUnsupported), .expect_id = "bY-PO6JhzhQ" },
    .{ .name = "utimes", .function = trace.wrap("utimes", &posixUnsupported), .expect_id = "GDuV00CHrUg" },
    .{ .name = "sched_yield", .function = trace.wrap("sched_yield", &schedYield), .expect_id = "6XG4B33N09g" },
    .{ .name = "inet_pton", .function = trace.wrap("inet_pton", &posixUnsupported), .expect_id = "4n51s0zEf0c" },
    .{ .name = "send", .function = trace.wrap("send", &posixUnsupported), .expect_id = "fZOeZIOEmLw" },
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
}
