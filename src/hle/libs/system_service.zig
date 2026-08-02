// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Stateful bootstrap implementation of libSceSystemService.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

const error_unavailable: i32 = @bitCast(@as(u32, 0x80a1_0002));
const error_parameter: i32 = @bitCast(@as(u32, 0x80a1_0003));
const error_no_event: i32 = @bitCast(@as(u32, 0x80a1_0004));

const Status = extern struct {
    event_count: i32 = 0,
    system_ui_overlaid: u8 = 0,
    background_execution: u8 = 0,
    ready_to_display: u8 = 1,
    reserved0: u8 = 0,
    reserved1: u32 = 0,
};

const Event = extern struct {
    event_type: i32 = -1,
    data: [8192]u8 = [_]u8{0} ** 8192,
};

const DisplaySafeAreaInfo = extern struct {
    ratio: f32 = 1.0,
    reserved: [128]u8 = [_]u8{0} ** 128,
};

const HdrToneMapLuminance = extern struct {
    max_full_frame: f32 = 80.0,
    max: f32 = 1000.0,
    min: f32 = 0.0,
};

var notice_screen_skip: std.atomic.Value(u8) = .init(0);
var music_player_disabled: std.atomic.Value(u8) = .init(0);

pub fn reset() void {
    notice_screen_skip.store(0, .release);
    music_player_disabled.store(0, .release);
}

fn paramGetInt(param_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    const value = output orelse return error_parameter;
    value.* = switch (param_id) {
        1 => 1, // English (US)
        2 => 1, // DD/MM/YYYY
        3 => 1, // 24-hour clock
        4 => 180, // UTC+3, in minutes
        5 => 0, // daylight saving disabled
        7, 208 => 0, // parental control and screen reader disabled
        1000 => 1, // Cross is the enter button
        else => return error_parameter,
    };
    return errno.ok;
}

fn paramGetString(_: i32, buffer: ?[*]u8, capacity: usize) callconv(abi.guest) i32 {
    const output = buffer orelse return error_parameter;
    const name = "PS5PCEM";
    if (capacity <= name.len) return error_parameter;
    @memcpy(output[0..name.len], name);
    output[name.len] = 0;
    return errno.ok;
}

fn receiveEvent(output: ?*Event) callconv(abi.guest) i32 {
    const event = output orelse return error_parameter;
    event.* = .{};
    return error_no_event;
}

fn getStatus(output: ?*Status) callconv(abi.guest) i32 {
    const status = output orelse return error_parameter;
    status.* = .{};
    return errno.ok;
}

fn getDisplaySafeAreaInfo(output: ?*DisplaySafeAreaInfo) callconv(abi.guest) i32 {
    const info = output orelse return error_parameter;
    info.* = .{};
    return errno.ok;
}

fn getHdrToneMapLuminance(output: ?*HdrToneMapLuminance) callconv(abi.guest) i32 {
    const luminance = output orelse return error_parameter;
    luminance.* = .{};
    return errno.ok;
}

fn getNoticeScreenSkipFlag(output: ?*u8) callconv(abi.guest) i32 {
    const flag = output orelse return error_parameter;
    flag.* = notice_screen_skip.load(.acquire);
    return errno.ok;
}

fn setNoticeScreenSkipFlag() callconv(abi.guest) i32 {
    notice_screen_skip.store(1, .release);
    return errno.ok;
}

fn disableNoticeScreenSkipFlagAutoSet() callconv(abi.guest) i32 {
    return errno.ok;
}

fn hideSplashScreen() callconv(abi.guest) i32 {
    return errno.ok;
}

fn powerTick() callconv(abi.guest) i32 {
    return errno.ok;
}

fn reportAbnormalTermination(_: ?*const anyopaque) callconv(abi.guest) i32 {
    return errno.ok;
}

fn disableMusicPlayer() callconv(abi.guest) i32 {
    music_player_disabled.store(1, .release);
    return errno.ok;
}

fn reenableMusicPlayer() callconv(abi.guest) i32 {
    music_player_disabled.store(0, .release);
    return errno.ok;
}

fn unavailable(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return error_unavailable;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceSystemServiceParamGetInt", .function = trace.wrap("sceSystemServiceParamGetInt", &paramGetInt), .expect_id = "fZo48un7LK4" },
    .{ .name = "sceSystemServiceParamGetString", .function = trace.wrap("sceSystemServiceParamGetString", &paramGetString), .expect_id = "SsC-m-S9JTA" },
    .{ .name = "sceSystemServiceReceiveEvent", .function = trace.wrap("sceSystemServiceReceiveEvent", &receiveEvent), .expect_id = "656LMQSrg6U" },
    .{ .name = "sceSystemServiceGetStatus", .function = trace.wrap("sceSystemServiceGetStatus", &getStatus), .expect_id = "rPo6tV8D9bM" },
    .{ .name = "sceSystemServiceGetDisplaySafeAreaInfo", .function = trace.wrap("sceSystemServiceGetDisplaySafeAreaInfo", &getDisplaySafeAreaInfo), .expect_id = "1n37q1Bvc5Y" },
    .{ .name = "sceSystemServiceGetHdrToneMapLuminance", .function = trace.wrap("sceSystemServiceGetHdrToneMapLuminance", &getHdrToneMapLuminance), .expect_id = "mPpPxv5CZt4" },
    .{ .name = "sceSystemServiceGetNoticeScreenSkipFlag", .function = trace.wrap("sceSystemServiceGetNoticeScreenSkipFlag", &getNoticeScreenSkipFlag), .expect_id = "3RQ5aQfnstU" },
    .{ .name = "sceSystemServiceSetNoticeScreenSkipFlag", .function = trace.wrap("sceSystemServiceSetNoticeScreenSkipFlag", &setNoticeScreenSkipFlag), .expect_id = "Q3utJvma4Mo" },
    .{ .name = "sceSystemServiceDisableNoticeScreenSkipFlagAutoSet", .function = trace.wrap("sceSystemServiceDisableNoticeScreenSkipFlagAutoSet", &disableNoticeScreenSkipFlagAutoSet), .expect_id = "8Lo6Zv94aho" },
    .{ .name = "sceSystemServiceHideSplashScreen", .function = trace.wrap("sceSystemServiceHideSplashScreen", &hideSplashScreen), .expect_id = "Vo5V8KAwCmk" },
    .{ .name = "sceSystemServicePowerTick", .function = trace.wrap("sceSystemServicePowerTick", &powerTick), .expect_id = "XbbJC3E+L5M" },
    .{ .name = "sceSystemServiceReportAbnormalTermination", .function = trace.wrap("sceSystemServiceReportAbnormalTermination", &reportAbnormalTermination), .expect_id = "3s8cHiCBKBE" },
    .{ .name = "sceSystemServiceDisableMusicPlayer", .function = trace.wrap("sceSystemServiceDisableMusicPlayer", &disableMusicPlayer), .expect_id = "x1UB9bwDSOw" },
    .{ .name = "sceSystemServiceReenableMusicPlayer", .function = trace.wrap("sceSystemServiceReenableMusicPlayer", &reenableMusicPlayer), .expect_id = "9kPCz7Or+1Y" },
    .{ .name = "sceSystemServiceLoadExec", .function = trace.wrap("sceSystemServiceLoadExec", &unavailable), .expect_id = "JoBqSQt1yyA" },
    .{ .name = "sceSystemServiceShowControllerSettings", .function = trace.wrap("sceSystemServiceShowControllerSettings", &unavailable), .expect_id = "w9wlKcHrmm8" },
    .{ .name = "sceSystemServiceInitializePlayerDialogParam", .function = trace.wrap("sceSystemServiceInitializePlayerDialogParam", &unavailable), .expect_id = "m5CYKX20wfg" },
    .{ .name = "sceSystemServiceLaunchPlayerDialog", .function = trace.wrap("sceSystemServiceLaunchPlayerDialog", &unavailable), .expect_id = "uaieF+glFPs" },
    .{ .name = "sceSystemServiceOpenChallengeActivity", .function = trace.wrap("sceSystemServiceOpenChallengeActivity", &unavailable), .expect_id = "sPuK5ic3GD4" },
    .{ .name = "sceSystemServiceOpenTournamentOccurrence", .function = trace.wrap("sceSystemServiceOpenTournamentOccurrence", &unavailable), .expect_id = "gELp9ue2ccQ" },
};

pub const library = symbols.Library{ .name = "libSceSystemService", .version = 1 };
pub const module = symbols.Module{
    .name = "libSceSystemService",
    .version_major = 1,
    .version_minor = 1,
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "system service exposes stable defaults and state" {
    reset();
    var language: i32 = -1;
    try std.testing.expectEqual(errno.ok, paramGetInt(1, &language));
    try std.testing.expectEqual(@as(i32, 1), language);

    var flag: u8 = 0;
    try std.testing.expectEqual(errno.ok, setNoticeScreenSkipFlag());
    try std.testing.expectEqual(errno.ok, getNoticeScreenSkipFlag(&flag));
    try std.testing.expectEqual(@as(u8, 1), flag);

    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("gELp9ue2ccQ", .function) != null);
}
