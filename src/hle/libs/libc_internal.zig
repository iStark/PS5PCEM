// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Small libSceLibcInternalExt surface consumed by the genuine libc PRX.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const threading = @import("kernel_threading.zig");

const HeapTraceInfo = extern struct {
    size: u64,
    reserved: u64,
    mask: ?*u64,
    table: ?*anyopaque,
};

var heap_trace_mask: u64 = 0;
var heap_trace_table: [64]u64 = [_]u64{0} ** 64;

const ThreadDestructor = struct {
    function: u64,
    object: u64,
    module: u64,
};

// libc++ registers thread_local objects here through __cxa_thread_atexit. A
// fixed per-host-thread stack mirrors the active guest thread without taking a
// process allocator lock during teardown. The limit is deliberately generous
// for title startup while keeping failure explicit instead of losing entries.
const maximum_thread_destructors = 1024;
threadlocal var thread_destructors: [maximum_thread_destructors]ThreadDestructor = undefined;
threadlocal var thread_destructor_count: usize = 0;

fn cxaThreadAtexit(function: u64, object: u64, dso_handle: u64) callconv(abi.guest) i32 {
    if (thread_destructor_count >= thread_destructors.len) return -1;
    thread_destructors[thread_destructor_count] = .{
        .function = function,
        .object = object,
        .module = dso_handle,
    };
    thread_destructor_count += 1;
    return errno.ok;
}

fn runThreadDestructors() void {
    // Pop before entering guest code: a destructor may register another
    // thread_local object, which must then run before older entries.
    while (thread_destructor_count != 0) {
        thread_destructor_count -= 1;
        const destructor = thread_destructors[thread_destructor_count];
        _ = destructor.module;
        if (destructor.function == 0) continue;
        _ = threading.callGuestCurrent(destructor.function, &.{destructor.object}) catch |err| {
            std.debug.print(
                "[libc internal] TLS destructor 0x{x} failed: {s}\n",
                .{ destructor.function, @errorName(err) },
            );
        };
    }
}

fn forceTlsDestructor(_: i32) callconv(abi.guest) void {
    runThreadDestructors();
}

fn finalizeTls() callconv(abi.guest) void {
    runThreadDestructors();
}

fn backtraceForGame(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return errno.ok;
}

fn heapGetTraceInfo(info: ?*HeapTraceInfo) callconv(abi.guest) i32 {
    const output = info orelse return errno.KernelError.einval.raw();
    if (output.size != @sizeOf(HeapTraceInfo)) return errno.KernelError.einval.raw();
    output.mask = &heap_trace_mask;
    output.table = &heap_trace_table;
    return errno.ok;
}

fn heapErrorReportForGame(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return errno.ok;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceLibcInternalBacktraceForGame", .function = trace.wrap("sceLibcInternalBacktraceForGame", &backtraceForGame), .expect_id = "EHsF2i9FXPM" },
    .{ .name = "sceLibcHeapGetTraceInfo", .function = trace.wrap("sceLibcHeapGetTraceInfo", &heapGetTraceInfo), .expect_id = "NWtTN10cJzE" },
    .{ .name = "sceLibcInternalHeapErrorReportForGame", .function = trace.wrap("sceLibcInternalHeapErrorReportForGame", &heapErrorReportForGame), .expect_id = "al3JzFI9MQ0" },
    .{ .name = "sceLibcInternalForceTlsDestructor", .function = trace.wrap("sceLibcInternalForceTlsDestructor", &forceTlsDestructor), .id_override = "tB59hFLH3SA" },
    .{ .name = "sceLibcInternalFinalizeTls", .function = trace.wrap("sceLibcInternalFinalizeTls", &finalizeTls), .id_override = "OQ-dzhlnM28" },
    .{ .name = "sceLibcInternalCxaThreadAtexit", .function = trace.wrap("sceLibcInternalCxaThreadAtexit", &cxaThreadAtexit), .id_override = "qBS714-Jr3g" },
};

pub const library = symbols.Library{ .name = "libSceLibcInternalExt", .version = 1 };
pub const module = symbols.Module{
    .name = "libSceLibcInternal",
    .version_major = 1,
    .version_minor = 1,
};

/// The marker a module imports to state that it needs this library.
///
/// Nothing reads its value; the import exists so that the dynamic linker pulls
/// the library in. It resolves to a byte of our own rather than to nothing,
/// because a relocation against it still writes an address somewhere.
var need_marker: u8 = 0;

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
    try db.addObject(
        gpa,
        .{ .name = "libSceLibcInternal", .version = 1 },
        module,
        "Need_sceLibcInternal",
        @intFromPtr(&need_marker),
        "ZT4ODD2Ts9o",
    );
}

test "libc internal extension exports register with exact metadata" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findByName("sceLibcHeapGetTraceInfo", .function) != null);
    try std.testing.expect(db.findById("tB59hFLH3SA", .function) != null);
    try std.testing.expect(db.findById("OQ-dzhlnM28", .function) != null);
    try std.testing.expect(db.findById("qBS714-Jr3g", .function) != null);
}

test "thread destructors are bounded and consumed in teardown" {
    thread_destructor_count = 0;
    defer thread_destructor_count = 0;

    try std.testing.expectEqual(errno.ok, cxaThreadAtexit(0, 0x1234, 0x5678));
    try std.testing.expectEqual(@as(usize, 1), thread_destructor_count);
    finalizeTls();
    try std.testing.expectEqual(@as(usize, 0), thread_destructor_count);

    thread_destructor_count = thread_destructors.len;
    try std.testing.expectEqual(@as(i32, -1), cxaThreadAtexit(0, 0, 0));
}
