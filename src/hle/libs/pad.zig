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
const host_input = @import("input");

const error_invalid_argument: i32 = @bitCast(@as(u32, 0x8092_0001));
const error_invalid_handle: i32 = @bitCast(@as(u32, 0x8092_0003));
const error_not_initialized: i32 = @bitCast(@as(u32, 0x8092_0005));
const error_device_not_connected: i32 = @bitCast(@as(u32, 0x8092_0007));

const primary_handle: i32 = 1;
/// SCE_PAD_BUTTON_CROSS — used for auto-confirm during headless bring-up.
const button_cross: u32 = 0x4000;
const button_down: u32 = 0x0040;
/// SCE_PAD_BUTTON_TRIANGLE — some confirmation prompts require a hold, not a tap.
const button_triangle: u32 = 0x1000;
/// Press Cross so splash/attract loops that wait for confirmation can advance
/// without a physical controller. Options is deliberately not synthesized:
/// once a title reaches interactive rendering it commonly means pause or opens
/// a settings page, and a single pulse can leave an unattended run parked.
// Keep the pulse deliberately off the one-second cadence used by some title
// screens. A one-second period phase-locks with their sparse pad polling and
// can make every read miss Cross forever.
const auto_cross_period_us: u64 = 1_337_000;
const auto_cross_hold_us: u64 = 500_000;
const delayed_cross_period_us: u64 = 4_000_000;
const delayed_cross_hold_us: u64 = 2_000_000;
/// After the world has loaded, frames last many seconds. A 2 s pulse is
/// shorter than one frame and never produces a rising edge on the
/// post-load "press Cross" prompt.
const auto_cross_late_start_us: u64 = auto_triangle_start_us + auto_triangle_hold_us;
const auto_cross_late_period_us: u64 = 35 * std.time.us_per_s;
const auto_cross_late_hold_us: u64 = 25 * std.time.us_per_s;
/// Leave the pad idle until the title's START prompt is up. A button that is
/// already held when the prompt appears never produces the rising edge Unity
/// menus wait for.
const auto_cross_start_us: u64 = 40 * std.time.us_per_s;
/// After the initial confirmations, hold Triangle for menus that require it.
const auto_triangle_start_us: u64 = 90 * std.time.us_per_s;
const auto_triangle_hold_us: u64 = 180 * std.time.us_per_s;
const rapid_down_period_us: u64 = 16 * std.time.us_per_s;
const rapid_down_hold_us: u64 = 15 * std.time.us_per_s;
var auto_input_origin_us: std.atomic.Value(u64) = .init(0);
var diagnostics_enabled: std.atomic.Value(u8) = .init(0);
var diagnostic_last_buttons: std.atomic.Value(u32) = .init(std.math.maxInt(u32));
var diagnostic_last_left_y: std.atomic.Value(u8) = .init(std.math.maxInt(u8));

pub const AutomaticProfile = enum(u8) {
    default,
    delayed_triangle_hold,
    rapid_down,
};

var automatic_profile: std.atomic.Value(u8) = .init(@intFromEnum(AutomaticProfile.default));

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
    auto_input_origin_us.store(0, .release);
    diagnostics_enabled.store(0, .release);
    diagnostic_last_buttons.store(std.math.maxInt(u32), .release);
    diagnostic_last_left_y.store(std.math.maxInt(u8), .release);
    automatic_profile.store(@intFromEnum(AutomaticProfile.default), .release);
    host_input.reset();
}

pub fn setAutomaticProfile(profile: AutomaticProfile) void {
    automatic_profile.store(@intFromEnum(profile), .release);
    auto_input_origin_us.store(0, .release);
}

pub fn setDiagnostics(enabled: bool) void {
    diagnostics_enabled.store(@intFromBool(enabled), .release);
    diagnostic_last_buttons.store(std.math.maxInt(u32), .release);
    diagnostic_last_left_y.store(std.math.maxInt(u8), .release);
}

fn autoInputElapsedUs() u64 {
    const now_ns = kernel_runtime.realTimeNanoseconds();
    const now_us: u64 = if (now_ns > 0)
        @intCast(@divTrunc(now_ns, std.time.ns_per_us))
    else
        kernel_runtime.processTimeMicroseconds();
    const origin = auto_input_origin_us.load(.monotonic);
    if (origin == 0) {
        if (auto_input_origin_us.cmpxchgStrong(0, now_us, .monotonic, .monotonic) == null) {
            return 0;
        }
        return now_us -| auto_input_origin_us.load(.monotonic);
    }
    return now_us -| origin;
}

fn validHandle(handle: i32) bool {
    return handle == primary_handle and open.load(.acquire) != 0;
}

fn rapidDownStick(elapsed_us: u64) u8 {
    return if (elapsed_us % rapid_down_period_us < rapid_down_hold_us) 255 else 128;
}

fn automaticCrossHeld(now_us: u64) bool {
    return now_us > 500_000 and now_us % auto_cross_period_us < auto_cross_hold_us;
}

fn padInit() callconv(abi.guest) i32 {
    initialized.store(1, .release);
    return errno.ok;
}

fn padOpen(user_id: i32, port_type: i32, index: i32, parameter: ?*const anyopaque) callconv(abi.guest) i32 {
    if (initialized.load(.acquire) == 0) return error_not_initialized;
    // PS5 titles use port type 2 for the login user's special controller port
    // (Cat Quest III does this during input bootstrap). It is the same physical
    // primary pad as the standard type-0 port from the emulator's perspective.
    if (user_id != user_service.primary_user_id or
        (port_type != 0 and port_type != 2) or index != 0 or parameter != null)
    {
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

/// Returns the system-managed primary pad handle. Some titles never call
/// scePadOpen and acquire the login user's already-associated controller only
/// through this API, so obtaining the handle also makes it readable locally.
fn padGetHandle(user_id: i32, port_type: i32, index: i32) callconv(abi.guest) i32 {
    if (initialized.load(.acquire) == 0) return error_not_initialized;
    if (user_id != user_service.primary_user_id or
        (port_type != 0 and port_type != 1 and port_type != 2) or index != 0)
    {
        return error_device_not_connected;
    }
    open.store(1, .release);
    return primary_handle;
}

fn fillPadData(output: *PadData) void {
    output.* = .{};
    const nanoseconds = kernel_runtime.realTimeNanoseconds();
    output.timestamp = @intCast(@max(@as(i96, 0), @divTrunc(nanoseconds, std.time.ns_per_us)));
    const host = host_input.read();
    output.buttons = host.buttons;
    output.left_stick_x = host.left_stick_x;
    output.left_stick_y = host.left_stick_y;
    output.right_stick_x = host.right_stick_x;
    output.right_stick_y = host.right_stick_y;
    output.analog_l2 = host.analog_l2;
    output.analog_r2 = host.analog_r2;

    // Direct CLI runs retain the automatic bring-up pulse. The launcher always
    // selects an explicit mode, so physical input is never mixed with it.
    if (host_input.mode() != .automatic) return;
    const profile: AutomaticProfile = @enumFromInt(automatic_profile.load(.acquire));
    if (profile == .default or profile == .rapid_down) {
        const now_us = kernel_runtime.processTimeMicroseconds();
        if (automaticCrossHeld(now_us)) output.buttons |= button_cross;
        // Some UI screens only repeat navigation once per rendered frame. In
        // bring-up runs a frame can take several seconds, so a host key pulse
        // can be missed completely. Use wall-clock intervals rather than a
        // read counter because a title can query scePadReadState several times
        // inside one UI frame.
        if (profile == .rapid_down) {
            const down = rapidDownStick(autoInputElapsedUs());
            output.left_stick_y = down;
            output.right_stick_y = down;
            if (down == 255) output.buttons |= button_down;
        }
        return;
    }
    const now_us = autoInputElapsedUs();
    if (now_us >= auto_cross_late_start_us) {
        const phase = (now_us - auto_cross_late_start_us) % auto_cross_late_period_us;
        if (phase < auto_cross_late_hold_us) {
            output.buttons |= button_cross;
        }
    } else if (now_us >= auto_cross_start_us) {
        const phase = (now_us - auto_cross_start_us) % delayed_cross_period_us;
        if (phase < delayed_cross_hold_us) {
            output.buttons |= button_cross;
        }
    }
    if (now_us >= auto_triangle_start_us and
        now_us < auto_triangle_start_us + auto_triangle_hold_us)
    {
        output.buttons |= button_triangle;
    }
}

fn reportPadData(output: *const PadData) void {
    if (diagnostics_enabled.load(.acquire) == 0) return;
    const previous_buttons = diagnostic_last_buttons.swap(output.buttons, .acq_rel);
    const previous_left_y = diagnostic_last_left_y.swap(output.left_stick_y, .acq_rel);
    if (previous_buttons == output.buttons and previous_left_y == output.left_stick_y) return;
    std.debug.print(
        "[pad state] elapsed_us={d} process_us={d} buttons=0x{x:0>8} left_y={d} mode={s} profile={s}\n",
        .{
            autoInputElapsedUs(),
            kernel_runtime.processTimeMicroseconds(),
            output.buttons,
            output.left_stick_y,
            @tagName(host_input.mode()),
            @tagName(@as(AutomaticProfile, @enumFromInt(automatic_profile.load(.acquire)))),
        },
    );
}

fn padRead(handle: i32, output: ?[*]PadData, count: i32) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    const data = output orelse return error_invalid_argument;
    if (count < 1 or count > 64) return error_invalid_argument;
    fillPadData(&data[0]);
    reportPadData(&data[0]);
    return 1;
}

fn padReadState(handle: i32, output: ?*PadData) callconv(abi.guest) i32 {
    if (!validHandle(handle)) return error_invalid_handle;
    const data = output orelse return error_invalid_argument;
    fillPadData(data);
    reportPadData(data);
    return errno.ok;
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
    // Games also use this as a global feature toggle with the sentinel handle
    // -1. The platform accepts that form even when no controller is open.
    return if (handle == -1 or validHandle(handle)) errno.ok else error_invalid_handle;
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
    .{ .name = "scePadGetHandle", .function = trace.wrap("scePadGetHandle", &padGetHandle), .expect_id = "u1GRHp+oWoY" },
    .{ .name = "scePadRead", .function = trace.wrap("scePadRead", &padRead), .expect_id = "q1cHNfGycLI" },
    .{ .name = "scePadReadState", .function = trace.wrap("scePadReadState", &padReadState), .expect_id = "YndgXqQVV7c" },
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

test "pad opens the primary user's PS5 special controller port" {
    reset();
    try std.testing.expectEqual(errno.ok, padInit());
    try std.testing.expectEqual(primary_handle, padOpen(user_service.primary_user_id, 2, 0, null));

    var data: [1]PadData = .{.{}};
    try std.testing.expectEqual(@as(i32, 1), padRead(primary_handle, &data, 1));
    try std.testing.expectEqual(@as(u8, 1), data[0].connected);
}

test "vibration mode accepts the global sentinel handle" {
    reset();
    try std.testing.expectEqual(errno.ok, setVibrationMode(-1, 1));
    try std.testing.expectEqual(error_invalid_handle, setVibrationMode(99, 1));
}

test "pad get handle exposes the system-managed primary controller" {
    reset();
    try std.testing.expectEqual(errno.ok, padInit());
    const handle = padGetHandle(user_service.primary_user_id, 0, 0);
    try std.testing.expectEqual(primary_handle, handle);

    var data: [1]PadData = .{.{}};
    try std.testing.expectEqual(@as(i32, 1), padRead(handle, &data, 1));
    try std.testing.expectEqual(@as(u8, 1), data[0].connected);
}

test "rapid down profile has a long hold and a neutral edge" {
    try std.testing.expectEqual(@as(u8, 255), rapidDownStick(0));
    try std.testing.expectEqual(@as(u8, 255), rapidDownStick(rapid_down_hold_us - 1));
    try std.testing.expectEqual(@as(u8, 128), rapidDownStick(rapid_down_hold_us));
    try std.testing.expectEqual(@as(u8, 128), rapidDownStick(rapid_down_period_us - 1));
    try std.testing.expectEqual(@as(u8, 255), rapidDownStick(rapid_down_period_us));
}

test "automatic Cross cannot phase-lock with one-second pad polling" {
    var previous = false;
    var saw_neutral = false;
    var saw_rising_edge = false;
    for (0..8) |index| {
        const held = automaticCrossHeld(16_483_000 + index * std.time.us_per_s);
        saw_neutral = saw_neutral or !held;
        saw_rising_edge = saw_rising_edge or (held and !previous);
        previous = held;
    }
    try std.testing.expect(saw_neutral);
    try std.testing.expect(saw_rising_edge);
}

test "pad exports include the PS5 remote-controller query" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("fCWdlnmB1Ks", .function) != null);
}
