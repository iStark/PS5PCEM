// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Neutral local-controller implementation of libScePad.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_runtime = @import("kernel_runtime.zig");
const user_service = @import("user_service.zig");

const error_invalid_argument: i32 = @bitCast(@as(u32, 0x8092_0001));
const error_invalid_handle: i32 = @bitCast(@as(u32, 0x8092_0003));
const error_not_initialized: i32 = @bitCast(@as(u32, 0x8092_0005));
const error_device_not_connected: i32 = @bitCast(@as(u32, 0x8092_0007));

const primary_handle: i32 = 1;
/// SCE_PAD_BUTTON_CROSS — used for auto-confirm during headless bring-up.
const button_cross: u32 = 0x4000;
/// Press Cross for 200 ms every 2 s after the pad opens so title/splash loops
/// that wait for confirm can advance without a physical controller.
const auto_cross_period_us: u64 = 2_000_000;
const auto_cross_hold_us: u64 = 200_000;

const PadData = extern struct {
    buttons: u32 = 0,
    left_stick_x: u8 = 128,
    left_stick_y: u8 = 128,
    right_stick_x: u8 = 128,
    right_stick_y: u8 = 128,
    analog_l2: u8 = 0,
    analog_r2: u8 = 0,
    padding0: [2]u8 = .{ 0, 0 },
    orientation_x: f32 = 0,
    orientation_y: f32 = 0,
    orientation_z: f32 = 0,
    orientation_w: f32 = 1,
    acceleration_x: f32 = 0,
    acceleration_y: f32 = 0,
    acceleration_z: f32 = 0,
    angular_velocity_x: f32 = 0,
    angular_velocity_y: f32 = 0,
    angular_velocity_z: f32 = 0,
    touch_count: u8 = 0,
    touch_reserved0: [3]u8 = .{ 0, 0, 0 },
    touch_reserved1: u32 = 0,
    touch0_x: u16 = 0,
    touch0_y: u16 = 0,
    touch0_id: u8 = 0,
    touch0_reserved: [3]u8 = .{ 0, 0, 0 },
    touch1_x: u16 = 0,
    touch1_y: u16 = 0,
    touch1_id: u8 = 0,
    touch1_reserved: [3]u8 = .{ 0, 0, 0 },
    connected: u8 = 1,
    timestamp: u64 = 0,
    extension_unit_id: u32 = 0,
    extension_reserved: u8 = 0,
    extension_data_length: u8 = 0,
    extension_data: [10]u8 = [_]u8{0} ** 10,
    connected_count: u8 = 1,
    reserved: [2]u8 = .{ 0, 0 },
    device_unique_data_length: u8 = 0,
    device_unique_data: [12]u8 = [_]u8{0} ** 12,
};

comptime {
    if (@sizeOf(PadData) != 0x78) @compileError("ScePadData ABI size must be 0x78 bytes");
    if (@offsetOf(PadData, "connected") != 0x4c) @compileError("ScePadData connected offset mismatch");
    if (@offsetOf(PadData, "timestamp") != 0x50) @compileError("ScePadData timestamp offset mismatch");
}

var initialized: std.atomic.Value(u8) = .init(0);
var open: std.atomic.Value(u8) = .init(0);
var motion_sensor_enabled: std.atomic.Value(u8) = .init(0);

pub fn reset() void {
    initialized.store(0, .release);
    open.store(0, .release);
    motion_sensor_enabled.store(0, .release);
}

fn validHandle(handle: i32) bool {
    return handle == primary_handle and open.load(.acquire) != 0;
}

fn padInit() callconv(abi.guest) i32 {
    initialized.store(1, .release);
    return errno.ok;
}

fn padOpen(user_id: i32, port_type: i32, index: i32, parameter: ?*const anyopaque) callconv(abi.guest) i32 {
    if (initialized.load(.acquire) == 0) return error_not_initialized;
    if (user_id != user_service.primary_user_id or port_type != 0 or index != 0 or parameter != null) {
        return error_device_not_connected;
    }
    open.store(1, .release);
    return primary_handle;
}

fn padClose(handle: i32) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    open.store(0, .release);
    return errno.ok;
}

fn fillPadData(output: *PadData) void {
    output.* = .{};
    const nanoseconds = kernel_runtime.realTimeNanoseconds();
    output.timestamp = @intCast(@max(@as(i96, 0), @divTrunc(nanoseconds, std.time.ns_per_us)));
    // Auto-confirm pulse for bring-up (same idea as env-driven auto-cross).
    const now_us = kernel_runtime.processTimeMicroseconds();
    if (now_us > 1_000_000) {
        const phase = now_us % auto_cross_period_us;
        if (phase < auto_cross_hold_us) output.buttons |= button_cross;
    }
}

fn padRead(handle: i32, output: ?[*]PadData, count: i32) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    const data = output orelse return error_invalid_argument;
    if (count < 1 or count > 64) return error_invalid_argument;
    fillPadData(&data[0]);
    return 1;
}

fn getControllerInformation(handle: i32, output: ?*[0x1c]u8) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    const info = output orelse return error_invalid_argument;
    @memset(info, 0);
    std.mem.writeInt(u32, info[0x00..0x04], @bitCast(@as(f32, 44.86)), .little);
    std.mem.writeInt(u16, info[0x04..0x06], 1920, .little);
    std.mem.writeInt(u16, info[0x06..0x08], 943, .little);
    info[0x08] = 30;
    info[0x09] = 30;
    info[0x0b] = 1;
    info[0x0c] = 1;
    return errno.ok;
}

fn deviceClassGetExtendedInformation(handle: i32, output: ?*[20]u8) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    const info = output orelse return error_invalid_argument;
    @memset(info, 0);
    return errno.ok;
}

fn deviceClassParseData(
    handle: i32,
    data: ?*const PadData,
    output: ?*[24]u8,
) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    const input = data orelse return error_invalid_argument;
    const parsed = output orelse return error_invalid_argument;
    @memset(parsed, 0);
    parsed[4] = @intFromBool(input.connected != 0);
    return errno.ok;
}

fn setMotionSensorState(handle: i32, enabled: bool) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    motion_sensor_enabled.store(@intFromBool(enabled), .release);
    return errno.ok;
}

fn acceptHandleState(handle: i32, _: bool) callconv(abi.guest) i32 {
    return if (validHandle(handle)) errno.ok else error_invalid_handle;
}

fn resetOrientation(handle: i32) callconv(abi.guest) i32 {
    return if (validHandle(handle)) errno.ok else error_invalid_handle;
}

fn acceptPointerState(handle: i32, parameter: ?*const anyopaque) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    if (parameter == null) return error_invalid_argument;
    return errno.ok;
}

fn setVibrationMode(handle: i32, _: i32) callconv(abi.guest) i32 {
    return if (validHandle(handle)) errno.ok else error_invalid_handle;
}

fn getTriggerEffectState(handle: i32, output: ?*[8]u8) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    const state = output orelse return error_invalid_argument;
    @memset(state, 0);
    return errno.ok;
}

fn isRemoteController(_: i32) callconv(abi.guest) i32 {
    return 0;
}

pub const exports = [_]symbols.Export{
    .{ .name = "scePadInit", .function = trace.wrap("scePadInit", &padInit), .expect_id = "hv1luiJrqQM" },
    .{ .name = "scePadOpen", .function = trace.wrap("scePadOpen", &padOpen), .expect_id = "xk0AcarP3V4" },
    .{ .name = "scePadClose", .function = trace.wrap("scePadClose", &padClose), .expect_id = "6ncge5+l5Qs" },
    .{ .name = "scePadRead", .function = trace.wrap("scePadRead", &padRead), .expect_id = "q1cHNfGycLI" },
    .{ .name = "scePadGetControllerInformation", .function = trace.wrap("scePadGetControllerInformation", &getControllerInformation), .expect_id = "gjP9-KQzoUk" },
    .{ .name = "scePadDeviceClassGetExtendedInformation", .function = trace.wrap("scePadDeviceClassGetExtendedInformation", &deviceClassGetExtendedInformation), .expect_id = "AcslpN1jHR8" },
    .{ .name = "scePadDeviceClassParseData", .function = trace.wrap("scePadDeviceClassParseData", &deviceClassParseData), .expect_id = "IHPqcbc0zCA" },
    .{ .name = "scePadSetMotionSensorState", .function = trace.wrap("scePadSetMotionSensorState", &setMotionSensorState), .expect_id = "clVvL4ZDntw" },
    .{ .name = "scePadSetAngularVelocityDeadbandState", .function = trace.wrap("scePadSetAngularVelocityDeadbandState", &acceptHandleState), .expect_id = "r44mAxdSG+U" },
    .{ .name = "scePadSetTiltCorrectionState", .function = trace.wrap("scePadSetTiltCorrectionState", &acceptHandleState), .expect_id = "vDLMoJLde8I" },
    .{ .name = "scePadResetOrientation", .function = trace.wrap("scePadResetOrientation", &resetOrientation), .expect_id = "rIZnR6eSpvk" },
    .{ .name = "scePadSetTriggerEffect", .function = trace.wrap("scePadSetTriggerEffect", &acceptPointerState), .expect_id = "2JgFB2n9oUM" },
    .{ .name = "scePadSetVibration", .function = trace.wrap("scePadSetVibration", &acceptPointerState), .expect_id = "yFVnOdGxvZY" },
    .{ .name = "scePadSetLightBar", .function = trace.wrap("scePadSetLightBar", &acceptPointerState), .expect_id = "RR4novUEENY" },
    .{ .name = "scePadResetLightBar", .function = trace.wrap("scePadResetLightBar", &resetOrientation), .expect_id = "DscD1i9HX1w" },
    .{ .name = "scePadSetVibrationMode", .function = trace.wrap("scePadSetVibrationMode", &setVibrationMode), .expect_id = "W2G-yoyMF5U" },
    .{ .name = "scePadGetTriggerEffectState", .function = trace.wrap("scePadGetTriggerEffectState", &getTriggerEffectState), .expect_id = "znaWI0gpuo8" },
    .{ .name = "scePadIsRemoteController", .function = trace.wrap("scePadIsRemoteController", &isRemoteController), .expect_id = "fCWdlnmB1Ks" },
};

pub const library = symbols.Library{ .name = "libScePad", .version = 1 };
pub const module = symbols.Module{ .name = "libScePad", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "pad opens for the primary user and reports neutral connected data" {
    reset();
    try std.testing.expectEqual(errno.ok, padInit());
    const handle = padOpen(user_service.primary_user_id, 0, 0, null);
    try std.testing.expectEqual(primary_handle, handle);

    var data: [1]PadData = .{.{}};
    try std.testing.expectEqual(@as(i32, 1), padRead(handle, &data, 1));
    try std.testing.expectEqual(@as(u8, 128), data[0].left_stick_x);
    try std.testing.expectEqual(@as(u8, 1), data[0].connected);
    try std.testing.expectEqual(errno.ok, padClose(handle));
}

test "pad exports include the PS5 remote-controller query" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("fCWdlnmB1Ks", .function) != null);
}
