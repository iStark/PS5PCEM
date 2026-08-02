// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bootstrap-level platform services imported by Unity support PRXs.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_runtime = @import("kernel_runtime.zig");

const rtc_unix_epoch_microseconds: i96 = 62_135_596_800 * std.time.us_per_s;

fn appContentInitialize(_: ?*const anyopaque, boot_param: ?*[40]u8) callconv(abi.guest) i32 {
    if (boot_param) |output| @memset(output, 0);
    return errno.ok;
}

fn temporaryDataMount2(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return errno.KernelError.enosys.raw();
}

fn netCtlGetInfo(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return errno.KernelError.enosys.raw();
}

fn systemServiceParamGetInt(param_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    const value = output orelse return errno.KernelError.einval.raw();
    value.* = switch (param_id) {
        1 => 1, // English (US)
        2 => 1, // DD/MM/YYYY
        3 => 1, // 24-hour clock
        4 => 0, // UTC timezone, in minutes
        5 => 0, // daylight saving disabled
        else => 0,
    };
    return errno.ok;
}

fn rtcGetCurrentTick(output: ?*u64) callconv(abi.guest) i32 {
    const value = output orelse return errno.KernelError.einval.raw();
    const unix_microseconds = @divTrunc(
        kernel_runtime.realTimeNanoseconds(),
        std.time.ns_per_us,
    );
    value.* = @intCast(@max(@as(i96, 0), rtc_unix_epoch_microseconds + unix_microseconds));
    return errno.ok;
}

const app_content_exports = [_]symbols.Export{
    .{ .name = "sceAppContentInitialize", .function = abi.erase(&appContentInitialize), .expect_id = "R9lA82OraNs" },
    .{ .name = "sceAppContentTemporaryDataMount2", .function = abi.erase(&temporaryDataMount2), .expect_id = "buYbeLOGWmA" },
};

const net_ctl_exports = [_]symbols.Export{.{
    .name = "sceNetCtlGetInfo",
    .function = abi.erase(&netCtlGetInfo),
    .expect_id = "obuxdTiwkF8",
}};

const system_service_exports = [_]symbols.Export{.{
    .name = "sceSystemServiceParamGetInt",
    .function = abi.erase(&systemServiceParamGetInt),
    .expect_id = "fZo48un7LK4",
}};

const rtc_exports = [_]symbols.Export{.{
    .name = "sceRtcGetCurrentTick",
    .function = abi.erase(&rtcGetCurrentTick),
    .expect_id = "18B2NS1y9UU",
}};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(
        gpa,
        .{ .name = "libSceAppContent", .version = 1 },
        .{ .name = "libSceAppContentUtil", .version_major = 1, .version_minor = 1 },
        &app_content_exports,
    );
    try db.addLibrary(
        gpa,
        .{ .name = "libSceNetCtl", .version = 1 },
        .{ .name = "libSceNetCtl", .version_major = 1, .version_minor = 1 },
        &net_ctl_exports,
    );
    try db.addLibrary(
        gpa,
        .{ .name = "libSceSystemService", .version = 1 },
        .{ .name = "libSceSystemService", .version_major = 1, .version_minor = 1 },
        &system_service_exports,
    );
    try db.addLibrary(
        gpa,
        .{ .name = "libSceRtc", .version = 1 },
        .{ .name = "libSceRtc", .version_major = 1, .version_minor = 1 },
        &rtc_exports,
    );
}

test "Unity bootstrap platform services register" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findByName("sceAppContentInitialize", .function) != null);
    try std.testing.expect(db.findByName("sceRtcGetCurrentTick", .function) != null);
}
