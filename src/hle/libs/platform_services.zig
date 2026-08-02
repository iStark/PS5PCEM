// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bootstrap-level platform services imported by Unity support PRXs.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_runtime = @import("kernel_runtime.zig");

const rtc_unix_epoch_microseconds: i96 = 62_135_596_800 * std.time.us_per_s;
const net_ctl_error_invalid_address: i32 = @bitCast(@as(u32, 0x8041_2107));
const net_ctl_error_not_connected: i32 = @bitCast(@as(u32, 0x8041_2108));

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

fn netCtlInit() callconv(abi.guest) i32 {
    return errno.ok;
}

fn netCtlTerm() callconv(abi.guest) void {}

fn netCtlGetNatInfo(output: ?*[16]u8) callconv(abi.guest) i32 {
    const info = output orelse return net_ctl_error_invalid_address;
    // Preserve the caller-supplied size field and report no mapped address.
    const size = info[0..4].*;
    @memset(info, 0);
    info[0..4].* = size;
    return errno.ok;
}

fn netCtlCheckCallback() callconv(abi.guest) i32 {
    // Guest callbacks are deliberately not invoked from an arbitrary HLE frame.
    // GetState/GetInfo expose the same disconnected state synchronously.
    return errno.ok;
}

fn netCtlGetState(output: ?*i32) callconv(abi.guest) i32 {
    const state = output orelse return net_ctl_error_invalid_address;
    state.* = 0; // SCE_NET_CTL_STATE_DISCONNECTED
    return errno.ok;
}

fn netCtlRegisterCallback(
    callback: ?*const anyopaque,
    _: ?*anyopaque,
    output: ?*i32,
) callconv(abi.guest) i32 {
    if (callback == null or output == null) return net_ctl_error_invalid_address;
    output.?.* = 0;
    return errno.ok;
}

fn netCtlUnregisterCallback(_: i32) callconv(abi.guest) i32 {
    return errno.ok;
}

fn netCtlGetResult(_: i32, output: ?*i32) callconv(abi.guest) i32 {
    const result = output orelse return net_ctl_error_invalid_address;
    result.* = errno.ok;
    return errno.ok;
}

fn netCtlGetInfo(_: i32, output: ?*[256]u8) callconv(abi.guest) i32 {
    const info = output orelse return net_ctl_error_invalid_address;
    @memset(info, 0);
    return net_ctl_error_not_connected;
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

const net_ctl_exports = [_]symbols.Export{
    .{ .name = "sceNetCtlInit", .function = abi.erase(&netCtlInit), .expect_id = "gky0+oaNM4k" },
    .{ .name = "sceNetCtlTerm", .function = abi.erase(&netCtlTerm), .expect_id = "Z4wwCFiBELQ" },
    .{ .name = "sceNetCtlGetNatInfo", .function = abi.erase(&netCtlGetNatInfo), .expect_id = "JO4yuTuMoKI" },
    .{ .name = "sceNetCtlCheckCallback", .function = abi.erase(&netCtlCheckCallback), .expect_id = "iQw3iQPhvUQ" },
    .{ .name = "sceNetCtlGetState", .function = abi.erase(&netCtlGetState), .expect_id = "uBPlr0lbuiI" },
    .{ .name = "sceNetCtlGetStateV6", .function = abi.erase(&netCtlGetState), .expect_id = "+lxqIKeU9UY" },
    .{ .name = "sceNetCtlRegisterCallback", .function = abi.erase(&netCtlRegisterCallback), .expect_id = "UJ+Z7Q+4ck0" },
    .{ .name = "sceNetCtlUnregisterCallback", .function = abi.erase(&netCtlUnregisterCallback), .expect_id = "Rqm2OnZMCz0" },
    .{ .name = "sceNetCtlGetResult", .function = abi.erase(&netCtlGetResult), .expect_id = "0cBgduPRR+M" },
    .{ .name = "sceNetCtlGetInfo", .function = abi.erase(&netCtlGetInfo), .expect_id = "obuxdTiwkF8" },
};

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

test "network control reports a coherent disconnected console" {
    var state: i32 = -1;
    try std.testing.expectEqual(errno.ok, netCtlGetState(&state));
    try std.testing.expectEqual(@as(i32, 0), state);
    var info: [256]u8 = [_]u8{0xff} ** 256;
    try std.testing.expectEqual(net_ctl_error_not_connected, netCtlGetInfo(14, &info));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 256), &info);
}
