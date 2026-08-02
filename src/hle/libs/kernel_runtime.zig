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
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
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
    .{ .name = "_sceKernelSetThreadDtors", .function = abi.erase(&setThreadDtors), .expect_id = "rNhWz+lvOMU" },
    .{ .name = "_sceKernelSetThreadAtexitCount", .function = abi.erase(&setThreadAtexitCount), .expect_id = "pB-yGZ2nQ9o" },
    .{ .name = "_sceKernelSetThreadAtexitReport", .function = abi.erase(&setThreadAtexitReport), .expect_id = "WhCc1w3EhSI" },
    .{ .name = "sceKernelDebugRaiseException", .function = abi.erase(&compatSuccess), .expect_id = "OMDRKKAZ8I4" },
    .{ .name = "sceKernelDebugRaiseExceptionOnReleaseMode", .function = abi.erase(&compatSuccess), .expect_id = "zE-wXIZjLoM" },
    .{ .name = "__error", .function = abi.erase(&errorAddress), .expect_id = "9BcDykPmo1I" },
    .{ .name = "__stack_chk_fail", .function = abi.erase(&stackCheckFail), .expect_id = "Ou3iL1abvng" },
    .{ .name = "signal", .function = abi.erase(&compatSuccess), .expect_id = "VADc3MNQ3cM" },
    .{ .name = "sceKernelGetProcParam", .function = abi.erase(&getProcParam), .expect_id = "959qrazPIrg" },
    .{ .name = "nanosleep", .function = abi.erase(&nanosleep), .expect_id = "yS8U2TGCe1A" },
    .{ .name = "gettimeofday", .function = abi.erase(&gettimeofday), .expect_id = "n88vx3C5nW8" },
    .{ .name = "_sceKernelRtldSetApplicationHeapAPI", .function = abi.erase(&setApplicationHeapApi), .expect_id = "p5EcQeEeJAE" },
    .{ .name = "sceKernelGetSanitizerMallocReplaceExternal", .function = abi.erase(&sanitizerHooksUnavailable), .expect_id = "py6L8jiVAN8" },
    .{ .name = "sceKernelInternalMemoryGetModuleSegmentInfo", .function = abi.erase(&kernelUnsupported), .expect_id = "-YTW+qXc3CQ" },
    .{ .name = "sceKernelMapNamedFlexibleMemoryInternal", .function = abi.erase(&mapNamedFlexibleMemoryInternal), .expect_id = "4h6F1LLbTiw" },
    .{ .name = "sceKernelMlock", .function = abi.erase(&compatSuccess), .expect_id = "3k6kx-zOOSQ" },
    .{ .name = "sceKernelIsAddressSanitizerEnabled", .function = abi.erase(&compatSuccess), .expect_id = "jh+8XiK4LeE" },
    .{ .name = "_read", .function = abi.erase(&posixUnsupported), .expect_id = "DRuBt2pvICk" },
    .{ .name = "_write", .function = abi.erase(&posixUnsupported), .expect_id = "FxVZqBAA7ks" },
    .{ .name = "_open", .function = abi.erase(&posixUnsupported), .expect_id = "6c3rCVE-fTU" },
    .{ .name = "_close", .function = abi.erase(&posixUnsupported), .expect_id = "NNtFaKJbPt0" },
    .{ .name = "lseek", .function = abi.erase(&posixUnsupported), .expect_id = "Oy6IpwgtYOk" },
    .{ .name = "rmdir", .function = abi.erase(&posixUnsupported), .expect_id = "c7ZnT7V1B98" },
    .{ .name = "unlink", .function = abi.erase(&posixUnsupported), .expect_id = "VAzswvTOCzI" },
    .{ .name = "sceKernelGetSanitizerNewReplaceExternal", .function = abi.erase(&sanitizerHooksUnavailable), .expect_id = "bnZxYgAFeA0" },
    .{ .name = "unknown_libkernel_cfwBSQyr5Ys", .function = abi.erase(&compatSuccess), .id_override = "cfwBSQyr5Ys" },
    .{ .name = "__tls_get_addr", .function = abi.erase(&tlsGetAddr), .expect_id = "vNe1w4diLCs" },
    .{ .name = "_sceKernelRtldThreadAtexitIncrement", .function = abi.erase(&rtldThreadAtexitIncrement), .expect_id = "Tz4RNUCBbGI" },
    .{ .name = "_sceKernelRtldThreadAtexitDecrement", .function = abi.erase(&rtldThreadAtexitDecrement), .expect_id = "8OnWXlgQlvo" },
    .{ .name = "sceKernelGetModuleInfoFromAddr", .function = abi.erase(&kernelUnsupported), .expect_id = "f7KBOafysXo" },
    .{ .name = "scePthreadGetname", .function = abi.erase(&pthreadGetname), .expect_id = "How7B8Oet6k" },
    .{ .name = "sceKernelGetModuleInfoForUnwind", .function = abi.erase(&kernelUnsupported), .expect_id = "RpQJJVKTiFM" },
    .{ .name = "_is_signal_return", .function = abi.erase(&compatSuccess), .expect_id = "crb5j7mkk1c" },
    .{ .name = "__elf_phdr_match_addr", .function = abi.erase(&elfPhdrMatchAddr), .expect_id = "Fjc4-n1+y2g" },
    .{ .name = "__pthread_cxa_finalize", .function = abi.erase(&compatSuccess), .expect_id = "kbw4UHHSYy0" },
    .{ .name = "_nanosleep", .function = abi.erase(&nanosleep), .expect_id = "NhpspxdjEKU" },
    .{ .name = "_exit", .function = abi.erase(&processExit), .expect_id = "6Z83sYWFlA8" },
    .{ .name = "sceKernelConvertLocaltimeToUtc", .function = abi.erase(&convertLocaltimeToUtc), .expect_id = "0NTHN1NKONI" },
    .{ .name = "_sigprocmask", .function = abi.erase(&compatSuccess), .expect_id = "6xVpy0Fdq+I" },
    .{ .name = "getrusage", .function = abi.erase(&getrusage), .expect_id = "hHlZQUnlxSM" },
    .{ .name = "sceKernelGetProcessTime", .function = abi.erase(&getProcessTime), .expect_id = "4J2sUJmuHZQ" },
    .{ .name = "sceKernelConvertUtcToLocaltime", .function = abi.erase(&convertUtcToLocaltime), .expect_id = "-o5uEDpN+oY" },
    .{ .name = "clock_gettime", .function = abi.erase(&clockGettime), .expect_id = "lLMT9vJAck0" },
    .{ .name = "sceKernelClockGettime", .function = abi.erase(&kernelClockGettime), .expect_id = "QBi7HCK03hw" },
    .{ .name = "sceKernelClose", .function = abi.erase(&kernelUnsupported), .expect_id = "UK2Tl2DWUns" },
    .{ .name = "sceKernelGetdents", .function = abi.erase(&kernelUnsupported), .expect_id = "j2AIqSqJP0w" },
    .{ .name = "sceKernelOpen", .function = abi.erase(&kernelUnsupported), .expect_id = "1G3lF1Gg1k8" },
    .{ .name = "sceKernelStat", .function = abi.erase(&kernelUnsupported), .expect_id = "eV9wAD2riIA" },
    .{ .name = "sceKernelMkdir", .function = abi.erase(&kernelUnsupported), .expect_id = "1-LFLmRFxxM" },
    .{ .name = "sceKernelUtimes", .function = abi.erase(&kernelUnsupported), .expect_id = "0Cq8ipKr9n0" },
    .{ .name = "sceKernelRename", .function = abi.erase(&kernelUnsupported), .expect_id = "52NcYU9+lEo" },
    .{ .name = "sceKernelTruncate", .function = abi.erase(&kernelUnsupported), .expect_id = "WlyEA-sLDf0" },
    .{ .name = "sceKernelUnlink", .function = abi.erase(&kernelUnsupported), .expect_id = "AUXVxWeJU-A" },
    .{ .name = "sceKernelChmod", .function = abi.erase(&kernelUnsupported), .expect_id = "fgIsQ10xYVA" },
    .{ .name = "sceKernelGettimeofday", .function = abi.erase(&kernelGettimeofday), .expect_id = "ejekcaNQNq0" },
    .{ .name = "sceKernelNanosleep", .function = abi.erase(&kernelNanosleep), .expect_id = "QvsZxomvUHs" },
    .{ .name = "sceKernelSleep", .function = abi.erase(&kernelSleep), .expect_id = "-ZR+hG7aDHw" },
    .{ .name = "sceKernelUuidCreate", .function = abi.erase(&uuidCreate), .expect_id = "Xjoosiw+XPI" },
    .{ .name = "sceKernelFstat", .function = abi.erase(&kernelUnsupported), .expect_id = "kBwCPsYX-m4" },
    .{ .name = "scePthreadRename", .function = abi.erase(&compatSuccess), .expect_id = "GBUY7ywdULE" },
    .{ .name = "sceKernelCreateEventFlag", .function = abi.erase(&kernelUnsupported), .expect_id = "BpFoboUJoZU" },
    .{ .name = "sceKernelCreateSema", .function = abi.erase(&kernelUnsupported), .expect_id = "188x57JYp0g" },
    .{ .name = "sceKernelSignalSema", .function = abi.erase(&kernelUnsupported), .expect_id = "4czppHBiriw" },
    .{ .name = "sceKernelWaitEventFlag", .function = abi.erase(&kernelUnsupported), .expect_id = "JTvBflhYazQ" },
    .{ .name = "sceKernelSetEventFlag", .function = abi.erase(&kernelUnsupported), .expect_id = "IOnSvHzqu6A" },
    .{ .name = "sceKernelWaitSema", .function = abi.erase(&kernelUnsupported), .expect_id = "Zxa0VhQVTsk" },
    .{ .name = "sceKernelClearEventFlag", .function = abi.erase(&kernelUnsupported), .expect_id = "7uhBFWRAS60" },
    .{ .name = "sceKernelDlsym", .function = abi.erase(&kernelUnsupported), .expect_id = "LwG8g3niqwA" },
    .{ .name = "sceKernelLoadStartModule", .function = abi.erase(&kernelUnsupported), .expect_id = "wzvqT4UqKX8" },
    .{ .name = "sceKernelStopUnloadModule", .function = abi.erase(&kernelUnsupported), .expect_id = "QKd0qM58Qes" },
    .{ .name = "sceKernelGetProcessTimeCounter", .function = abi.erase(&getProcessTimeCounter), .expect_id = "fgxnMeTNUtY" },
    .{ .name = "sceKernelGetProcessTimeCounterFrequency", .function = abi.erase(&getProcessTimeCounterFrequency), .expect_id = "BNowx2l588E" },
    .{ .name = "unknown_libkernel_B2n8aDorSH4", .function = abi.erase(&kernelUnsupported), .id_override = "B2n8aDorSH4" },
    .{ .name = "unknown_libkernel_PZQhiiLXRFs", .function = abi.erase(&kernelUnsupported), .id_override = "PZQhiiLXRFs" },
    .{ .name = "sceKernelSyncOnAddressWake", .function = abi.erase(&kernelUnsupported), .expect_id = "q2y-wDIVWZA" },
    .{ .name = "sceKernelSyncOnAddressWait", .function = abi.erase(&kernelUnsupported), .expect_id = "Hc4CaR6JBL0" },
};

pub const unity_exports = [_]symbols.Export{
    .{ .name = "sceKernelInstallExceptionHandler", .function = abi.erase(&compatSuccess), .expect_id = "WkwEd3N7w0Y" },
    .{ .name = "sceKernelRaiseException", .function = abi.erase(&compatSuccess), .expect_id = "il03nluKfMk" },
};

pub const posix_exports = [_]symbols.Export{
    .{ .name = "stat", .function = abi.erase(&posixUnsupported), .expect_id = "E6ao34wPw+U" },
    .{ .name = "mkdir", .function = abi.erase(&posixUnsupported), .expect_id = "JGMio+21L4c" },
    .{ .name = "chmod", .function = abi.erase(&posixUnsupported), .expect_id = "z0dtnPxYgtg" },
    .{ .name = "rename", .function = abi.erase(&posixUnsupported), .expect_id = "NN01qLRhiqU" },
    .{ .name = "fstat", .function = abi.erase(&posixUnsupported), .expect_id = "mqQMh1zPPT8" },
    .{ .name = "fchmod", .function = abi.erase(&posixUnsupported), .expect_id = "n01yNbQO5W4" },
    .{ .name = "read", .function = abi.erase(&posixUnsupported), .expect_id = "AqBioC2vF3I" },
    .{ .name = "write", .function = abi.erase(&posixUnsupported), .expect_id = "FN4gaPmuFV8" },
    .{ .name = "futimes", .function = abi.erase(&posixUnsupported), .expect_id = "+0EDo7YzcoU" },
    .{ .name = "open", .function = abi.erase(&posixUnsupported), .expect_id = "wuCroIGjt2g" },
    .{ .name = "close", .function = abi.erase(&posixUnsupported), .expect_id = "bY-PO6JhzhQ" },
    .{ .name = "utimes", .function = abi.erase(&posixUnsupported), .expect_id = "GDuV00CHrUg" },
    .{ .name = "sched_yield", .function = abi.erase(&schedYield), .expect_id = "6XG4B33N09g" },
    .{ .name = "inet_pton", .function = abi.erase(&posixUnsupported), .expect_id = "4n51s0zEf0c" },
    .{ .name = "send", .function = abi.erase(&posixUnsupported), .expect_id = "fZOeZIOEmLw" },
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
