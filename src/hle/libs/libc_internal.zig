// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Small libSceLibcInternalExt surface consumed by the genuine libc PRX.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

const HeapTraceInfo = extern struct {
    size: u64,
    reserved: u64,
    mask: ?*u64,
    table: ?*anyopaque,
};

var heap_trace_mask: u64 = 0;
var heap_trace_table: [64]u64 = [_]u64{0} ** 64;

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
    .{ .name = "sceLibcInternalBacktraceForGame", .function = abi.erase(&backtraceForGame), .expect_id = "EHsF2i9FXPM" },
    .{ .name = "sceLibcHeapGetTraceInfo", .function = abi.erase(&heapGetTraceInfo), .expect_id = "NWtTN10cJzE" },
    .{ .name = "sceLibcInternalHeapErrorReportForGame", .function = abi.erase(&heapErrorReportForGame), .expect_id = "al3JzFI9MQ0" },
};

pub const library = symbols.Library{ .name = "libSceLibcInternalExt", .version = 1 };
pub const module = symbols.Module{
    .name = "libSceLibcInternal",
    .version_major = 1,
    .version_minor = 1,
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "libc internal extension exports register with exact metadata" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findByName("sceLibcHeapGetTraceInfo", .function) != null);
}
