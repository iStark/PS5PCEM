// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! File entry points needed for linkage before a guest VFS is available.
//!
//! These functions deliberately report ENOSYS. Returning a fabricated byte
//! count or success would let callers consume uninitialized buffers and hide
//! the actual missing filesystem boundary.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

const unsupported64: i64 = errno.KernelError.enosys.raw();

fn read(_: i32, _: ?[*]u8, _: usize) callconv(abi.guest) i64 {
    return unsupported64;
}

fn write(_: i32, _: ?[*]const u8, _: usize) callconv(abi.guest) i64 {
    return unsupported64;
}

fn pread(_: i32, _: ?[*]u8, _: usize, _: i64) callconv(abi.guest) i64 {
    return unsupported64;
}

fn pwrite(_: i32, _: ?[*]const u8, _: usize, _: i64) callconv(abi.guest) i64 {
    return unsupported64;
}

fn lseek(_: i32, _: i64, _: i32) callconv(abi.guest) i64 {
    return unsupported64;
}

fn unsupportedStatus(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return errno.KernelError.enosys.raw();
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceKernelRead", .function = trace.wrap("sceKernelRead", &read), .expect_id = "Cg4srZ6TKbU" },
    .{ .name = "sceKernelWrite", .function = trace.wrap("sceKernelWrite", &write), .expect_id = "4wSze92BhLI" },
    .{ .name = "sceKernelPread", .function = trace.wrap("sceKernelPread", &pread), .expect_id = "+r3rMFwItV4" },
    .{ .name = "sceKernelPwrite", .function = trace.wrap("sceKernelPwrite", &pwrite), .expect_id = "nKWi-N2HBV4" },
    .{ .name = "sceKernelLseek", .function = trace.wrap("sceKernelLseek", &lseek), .expect_id = "oib76F-12fk" },
    .{ .name = "sceKernelFsync", .function = trace.wrap("sceKernelFsync", &unsupportedStatus), .expect_id = "fTx66l5iWIA" },
    .{ .name = "sceKernelFchmod", .function = trace.wrap("sceKernelFchmod", &unsupportedStatus), .expect_id = "UtszJWHrDcA" },
    .{ .name = "sceKernelFtruncate", .function = trace.wrap("sceKernelFtruncate", &unsupportedStatus), .expect_id = "VW3TVZiM4-E" },
    .{ .name = "sceKernelRmdir", .function = trace.wrap("sceKernelRmdir", &unsupportedStatus), .expect_id = "naInUjYt3so" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "file bootstrap returns a sign-extended kernel error" {
    try std.testing.expectEqual(@as(i64, errno.KernelError.enosys.raw()), read(-1, null, 0));
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("nKWi-N2HBV4", .function) != null);
}
