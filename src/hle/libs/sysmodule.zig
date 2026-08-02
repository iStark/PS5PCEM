// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Minimal sysmodule introspection needed by libc unwind setup.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

fn getModuleInfoForUnwind(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return errno.KernelError.enoent.raw();
}

fn loadModule(_: u32) callconv(abi.guest) i32 {
    // Built-in system modules are represented by their registered HLE exports;
    // there is no additional image to map for this compatibility path.
    return errno.ok;
}

pub const exports = [_]symbols.Export{ .{
    .name = "sceSysmoduleGetModuleInfoForUnwind",
    .function = trace.wrap("sceSysmoduleGetModuleInfoForUnwind", &getModuleInfoForUnwind),
    .expect_id = "4fU5yvOkVG4",
}, .{
    .name = "sceSysmoduleLoadModule",
    .function = trace.wrap("sceSysmoduleLoadModule", &loadModule),
    .expect_id = "g8cM39EUZ6o",
} };

pub const library = symbols.Library{ .name = "libSceSysmodule", .version = 1 };
pub const module = symbols.Module{
    .name = "libSceSysmodule",
    .version_major = 1,
    .version_minor = 1,
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "sysmodule unwind query registers" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findByName("sceSysmoduleGetModuleInfoForUnwind", .function) != null);
}
