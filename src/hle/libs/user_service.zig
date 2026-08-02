// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Single-user bootstrap implementation of libSceUserService.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

const error_not_initialized: i32 = @bitCast(@as(u32, 0x8096_0002));
const error_invalid_argument: i32 = @bitCast(@as(u32, 0x8096_0005));
const error_no_event: i32 = @bitCast(@as(u32, 0x8096_0007));
const error_not_logged_in: i32 = @bitCast(@as(u32, 0x8096_0009));
const error_buffer_too_short: i32 = @bitCast(@as(u32, 0x8096_000a));

pub const primary_user_id: i32 = 0x1000_0000;
const invalid_user_id: i32 = -1;
const user_name = "PS5PCEM";

const UserEvent = extern struct {
    event_type: i32 = 0,
    user_id: i32 = primary_user_id,
};

const LoginUserIdList = extern struct {
    user_ids: [4]i32 = .{ primary_user_id, invalid_user_id, invalid_user_id, invalid_user_id },
};

const GamePresets = extern struct {
    size: u64 = @sizeOf(GamePresets),
    difficulty: u32 = 0,
    priority: u32 = 0,
    invert_first_person_vertical: u32 = 0,
    invert_first_person_horizontal: u32 = 0,
    invert_third_person_vertical: u32 = 0,
    invert_third_person_horizontal: u32 = 0,
    display_subtitles: u32 = 0,
    audio_language: u32 = 0,
};

var initialized: std.atomic.Value(u8) = .init(0);
var login_event_pending: std.atomic.Value(u8) = .init(0);

pub fn reset() void {
    initialized.store(0, .release);
    login_event_pending.store(0, .release);
}

fn requireInitialized() ?i32 {
    return if (initialized.load(.acquire) == 0) error_not_initialized else null;
}

fn validateUser(user_id: i32) ?i32 {
    if (requireInitialized()) |status| return status;
    return if (user_id == primary_user_id) null else error_not_logged_in;
}

fn initialize(_: ?*const anyopaque) callconv(abi.guest) i32 {
    initialized.store(1, .release);
    login_event_pending.store(1, .release);
    return errno.ok;
}

fn terminate() callconv(abi.guest) i32 {
    reset();
    return errno.ok;
}

fn getInitialUser(output: ?*i32) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    const user_id = output orelse return error_invalid_argument;
    user_id.* = primary_user_id;
    return errno.ok;
}

fn getEvent(output: ?*UserEvent) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    const event = output orelse return error_invalid_argument;
    if (login_event_pending.swap(0, .acq_rel) == 0) return error_no_event;
    event.* = .{};
    return errno.ok;
}

fn getLoginUserIdList(output: ?*LoginUserIdList) callconv(abi.guest) i32 {
    if (requireInitialized()) |status| return status;
    const list = output orelse return error_invalid_argument;
    list.* = .{};
    return errno.ok;
}

fn getUserName(user_id: i32, output: ?[*]u8, capacity: usize) callconv(abi.guest) i32 {
    if (validateUser(user_id)) |status| return status;
    const name = output orelse return error_invalid_argument;
    if (capacity <= user_name.len) return error_buffer_too_short;
    @memcpy(name[0..user_name.len], user_name);
    name[user_name.len] = 0;
    return errno.ok;
}

fn getGamePresets(user_id: i32, output: ?*GamePresets) callconv(abi.guest) i32 {
    if (validateUser(user_id)) |status| return status;
    const presets = output orelse return error_invalid_argument;
    presets.* = .{};
    return errno.ok;
}

fn getSetting(user_id: i32, output: ?*i32, value: i32) i32 {
    if (validateUser(user_id)) |status| return status;
    const setting = output orelse return error_invalid_argument;
    setting.* = value;
    return errno.ok;
}

fn getAgeLevel(user_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    return getSetting(user_id, output, 18);
}

fn getGameAccessibilityChatTranscription(user_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    return getSetting(user_id, output, 0);
}

fn getAccessibilityPressAndHoldDelay(user_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    return getSetting(user_id, output, 0);
}

fn getAccessibilityVibration(user_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    return getSetting(user_id, output, 1);
}

fn getAccessibilityTriggerEffect(user_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    return getSetting(user_id, output, 1);
}

fn getAccessibilityZoomEnabled(user_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    return getSetting(user_id, output, 0);
}

fn getAccessibilityZoomFollowFocus(user_id: i32, output: ?*i32) callconv(abi.guest) i32 {
    return getSetting(user_id, output, 0);
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceUserServiceInitialize", .function = trace.wrap("sceUserServiceInitialize", &initialize), .expect_id = "j3YMu1MVNNo" },
    .{ .name = "sceUserServiceTerminate", .function = trace.wrap("sceUserServiceTerminate", &terminate), .expect_id = "bwFjS+bX9mA" },
    .{ .name = "sceUserServiceGetInitialUser", .function = trace.wrap("sceUserServiceGetInitialUser", &getInitialUser), .expect_id = "CdWp0oHWGr0" },
    .{ .name = "sceUserServiceGetEvent", .function = trace.wrap("sceUserServiceGetEvent", &getEvent), .expect_id = "yH17Q6NWtVg" },
    .{ .name = "sceUserServiceGetLoginUserIdList", .function = trace.wrap("sceUserServiceGetLoginUserIdList", &getLoginUserIdList), .expect_id = "fPhymKNvK-A" },
    .{ .name = "sceUserServiceGetUserName", .function = trace.wrap("sceUserServiceGetUserName", &getUserName), .expect_id = "1xxcMiGu2fo" },
    .{ .name = "sceUserServiceGetGamePresets", .function = trace.wrap("sceUserServiceGetGamePresets", &getGamePresets), .expect_id = "-sD02mFDBh4" },
    .{ .name = "sceUserServiceGetAgeLevel", .function = trace.wrap("sceUserServiceGetAgeLevel", &getAgeLevel), .expect_id = "woNpu+45RLk" },
    .{ .name = "sceUserServiceGetAccessibilityChatTranscription", .function = trace.wrap("sceUserServiceGetAccessibilityChatTranscription", &getGameAccessibilityChatTranscription), .expect_id = "rnEhHqG-4xo" },
    .{ .name = "sceUserServiceGetAccessibilityPressAndHoldDelay", .function = trace.wrap("sceUserServiceGetAccessibilityPressAndHoldDelay", &getAccessibilityPressAndHoldDelay), .expect_id = "ZKJtxdgvzwg" },
    .{ .name = "sceUserServiceGetAccessibilityVibration", .function = trace.wrap("sceUserServiceGetAccessibilityVibration", &getAccessibilityVibration), .expect_id = "qWYHOFwqCxY" },
    .{ .name = "sceUserServiceGetAccessibilityTriggerEffect", .function = trace.wrap("sceUserServiceGetAccessibilityTriggerEffect", &getAccessibilityTriggerEffect), .expect_id = "-3Y5GO+-i78" },
    .{ .name = "sceUserServiceGetAccessibilityZoomEnabled", .function = trace.wrap("sceUserServiceGetAccessibilityZoomEnabled", &getAccessibilityZoomEnabled), .expect_id = "hD-H81EN9Vg" },
    .{ .name = "sceUserServiceGetAccessibilityZoomFollowFocus", .function = trace.wrap("sceUserServiceGetAccessibilityZoomFollowFocus", &getAccessibilityZoomFollowFocus), .expect_id = "O6IW1-Dwm-w" },
};

pub const library = symbols.Library{ .name = "libSceUserService", .version = 1 };
pub const module = symbols.Module{
    .name = "libSceUserService",
    .version_major = 1,
    .version_minor = 1,
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "user service publishes one login session" {
    reset();
    try std.testing.expectEqual(errno.ok, initialize(null));
    var user_id: i32 = 0;
    try std.testing.expectEqual(errno.ok, getInitialUser(&user_id));
    try std.testing.expectEqual(primary_user_id, user_id);

    var event: UserEvent = .{};
    try std.testing.expectEqual(errno.ok, getEvent(&event));
    try std.testing.expectEqual(error_no_event, getEvent(&event));
    try std.testing.expectEqual(errno.ok, terminate());
    try std.testing.expectEqual(error_not_initialized, getInitialUser(&user_id));
}

test "user service exports use the catalogued NIDs" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("bwFjS+bX9mA", .function) != null);
    try std.testing.expect(db.findById("O6IW1-Dwm-w", .function) != null);
}
