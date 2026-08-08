// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Host input polling shared by the launcher-facing configuration and libScePad.
//!
//! The native launcher passes a small, dependency-free contract through the
//! environment. Keeping host polling here means the firmware implementation is
//! still testable and platform-neutral while Windows builds can use XInput and
//! the keyboard without pulling a GUI toolkit into the emulator core.

const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum {
    /// Preserve the old unattended bring-up behaviour when game-run is invoked
    /// directly instead of through the launcher.
    automatic,
    controller,
    keyboard,
    hybrid,
};

pub const State = struct {
    buttons: u32 = 0,
    left_stick_x: u8 = 128,
    left_stick_y: u8 = 128,
    right_stick_x: u8 = 128,
    right_stick_y: u8 = 128,
    analog_l2: u8 = 0,
    analog_r2: u8 = 0,
    connected: bool = false,
};

pub const Button = struct {
    pub const l3: u32 = 0x0000_0002;
    pub const r3: u32 = 0x0000_0004;
    pub const options: u32 = 0x0000_0008;
    pub const up: u32 = 0x0000_0010;
    pub const right: u32 = 0x0000_0020;
    pub const down: u32 = 0x0000_0040;
    pub const left: u32 = 0x0000_0080;
    pub const l2: u32 = 0x0000_0100;
    pub const r2: u32 = 0x0000_0200;
    pub const l1: u32 = 0x0000_0400;
    pub const r1: u32 = 0x0000_0800;
    pub const triangle: u32 = 0x0000_1000;
    pub const circle: u32 = 0x0000_2000;
    pub const cross: u32 = 0x0000_4000;
    pub const square: u32 = 0x0000_8000;
    pub const touch_pad: u32 = 0x0010_0000;
};

const Mapping = struct {
    cross: u8 = 0x20, // Space
    circle: u8 = 'E',
    square: u8 = 'F',
    triangle: u8 = 'Q',
    l1: u8 = 0x10, // Shift
    l2: u8 = 0x11, // Ctrl
    r1: u8 = 'R',
    r2: u8 = 'T',
    options: u8 = 0x0d, // Enter
    touch_pad: u8 = 0x09, // Tab
    up: u8 = 0x26,
    right: u8 = 0x27,
    down: u8 = 0x28,
    left: u8 = 0x25,
};

var cached_mode: ?Mode = null;
var cached_mapping: ?Mapping = null;
var cached_controller_index: ?u32 = null;

pub fn reset() void {
    cached_mode = null;
    cached_mapping = null;
    cached_controller_index = null;
}

pub fn mode() Mode {
    if (cached_mode) |value| return value;
    var value: Mode = .automatic;
    if (comptime builtin.os.tag == .windows) {
        var buffer: [32]u8 = undefined;
        const length = Win32.GetEnvironmentVariableA("PS5_INPUT_MODE", &buffer, buffer.len);
        if (length > 0 and length < buffer.len) {
            const text = buffer[0..length];
            if (eqlIgnoreCase(text, "controller")) value = .controller;
            if (eqlIgnoreCase(text, "keyboard")) value = .keyboard;
            if (eqlIgnoreCase(text, "hybrid")) value = .hybrid;
        }
    }
    cached_mode = value;
    return value;
}

pub fn read() State {
    const selected = mode();
    if (selected == .automatic) return .{};

    var state = State{ .connected = true };
    if (selected == .controller or selected == .hybrid) mergeController(&state);
    if (selected == .keyboard or selected == .hybrid) mergeKeyboard(&state, mapping());
    return state;
}

fn mergeKeyboard(state: *State, keys: Mapping) void {
    if (comptime builtin.os.tag != .windows) return;
    const bindings = [_]struct { key: u8, mask: u32 }{
        .{ .key = keys.cross, .mask = Button.cross },
        .{ .key = keys.circle, .mask = Button.circle },
        .{ .key = keys.square, .mask = Button.square },
        .{ .key = keys.triangle, .mask = Button.triangle },
        .{ .key = keys.l1, .mask = Button.l1 },
        .{ .key = keys.l2, .mask = Button.l2 },
        .{ .key = keys.r1, .mask = Button.r1 },
        .{ .key = keys.r2, .mask = Button.r2 },
        .{ .key = keys.options, .mask = Button.options },
        .{ .key = keys.touch_pad, .mask = Button.touch_pad },
        .{ .key = keys.up, .mask = Button.up },
        .{ .key = keys.right, .mask = Button.right },
        .{ .key = keys.down, .mask = Button.down },
        .{ .key = keys.left, .mask = Button.left },
    };
    for (bindings) |binding| {
        if (keyDown(binding.key)) state.buttons |= binding.mask;
    }

    // WASD is the left stick. The arrow keys remain available as both the
    // directional buttons and, with Alt held, the right stick.
    state.left_stick_x = axis(keyDown('A'), keyDown('D'));
    state.left_stick_y = axis(keyDown('W'), keyDown('S'));
    if (keyDown(0x12)) { // Alt
        state.right_stick_x = axis(keyDown(0x25), keyDown(0x27));
        state.right_stick_y = axis(keyDown(0x26), keyDown(0x28));
    }
    if (keyDown(keys.l2)) state.analog_l2 = 255;
    if (keyDown(keys.r2)) state.analog_r2 = 255;
}

fn mergeController(state: *State) void {
    if (comptime builtin.os.tag != .windows) return;
    var native: Win32.XInputState = .{};
    if (Win32.XInputGetState(controllerIndex(), &native) != 0) return;
    const pad = native.gamepad;
    state.connected = true;
    if (pad.buttons & Win32.xinput_dpad_up != 0) state.buttons |= Button.up;
    if (pad.buttons & Win32.xinput_dpad_right != 0) state.buttons |= Button.right;
    if (pad.buttons & Win32.xinput_dpad_down != 0) state.buttons |= Button.down;
    if (pad.buttons & Win32.xinput_dpad_left != 0) state.buttons |= Button.left;
    if (pad.buttons & Win32.xinput_start != 0) state.buttons |= Button.options;
    if (pad.buttons & Win32.xinput_left_thumb != 0) state.buttons |= Button.l3;
    if (pad.buttons & Win32.xinput_right_thumb != 0) state.buttons |= Button.r3;
    if (pad.buttons & Win32.xinput_left_shoulder != 0) state.buttons |= Button.l1;
    if (pad.buttons & Win32.xinput_right_shoulder != 0) state.buttons |= Button.r1;
    if (pad.buttons & Win32.xinput_a != 0) state.buttons |= Button.cross;
    if (pad.buttons & Win32.xinput_b != 0) state.buttons |= Button.circle;
    if (pad.buttons & Win32.xinput_x != 0) state.buttons |= Button.square;
    if (pad.buttons & Win32.xinput_y != 0) state.buttons |= Button.triangle;
    if (pad.left_trigger > 24) state.buttons |= Button.l2;
    if (pad.right_trigger > 24) state.buttons |= Button.r2;
    state.analog_l2 = pad.left_trigger;
    state.analog_r2 = pad.right_trigger;
    state.left_stick_x = stickAxis(pad.thumb_lx);
    state.left_stick_y = invertStickAxis(pad.thumb_ly);
    state.right_stick_x = stickAxis(pad.thumb_rx);
    state.right_stick_y = invertStickAxis(pad.thumb_ry);
}

fn controllerIndex() u32 {
    if (cached_controller_index) |value| return value;
    var value: u32 = 0;
    if (comptime builtin.os.tag == .windows) {
        var buffer: [8]u8 = undefined;
        const length = Win32.GetEnvironmentVariableA("PS5_CONTROLLER_INDEX", &buffer, buffer.len);
        if (length > 0 and length < buffer.len) {
            const parsed = std.fmt.parseInt(u32, buffer[0..length], 10) catch 0;
            if (parsed < 4) value = parsed;
        }
    }
    cached_controller_index = value;
    return value;
}

fn mapping() Mapping {
    if (cached_mapping) |value| return value;
    var value = Mapping{};
    if (comptime builtin.os.tag == .windows) {
        var buffer: [512]u8 = undefined;
        const length = Win32.GetEnvironmentVariableA("PS5_KEYMAP", &buffer, buffer.len);
        if (length > 0 and length < buffer.len) parseMapping(buffer[0..length], &value);
    }
    cached_mapping = value;
    return value;
}

fn parseMapping(text: []const u8, output: *Mapping) void {
    var fields = std.mem.splitScalar(u8, text, ',');
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const name = std.mem.trim(u8, field[0..separator], " \t");
        const number = std.mem.trim(u8, field[separator + 1 ..], " \t");
        const key = std.fmt.parseInt(u8, number, 10) catch continue;
        if (eqlIgnoreCase(name, "cross")) output.cross = key;
        if (eqlIgnoreCase(name, "circle")) output.circle = key;
        if (eqlIgnoreCase(name, "square")) output.square = key;
        if (eqlIgnoreCase(name, "triangle")) output.triangle = key;
        if (eqlIgnoreCase(name, "l1")) output.l1 = key;
        if (eqlIgnoreCase(name, "l2")) output.l2 = key;
        if (eqlIgnoreCase(name, "r1")) output.r1 = key;
        if (eqlIgnoreCase(name, "r2")) output.r2 = key;
        if (eqlIgnoreCase(name, "options")) output.options = key;
        if (eqlIgnoreCase(name, "touch")) output.touch_pad = key;
        if (eqlIgnoreCase(name, "up")) output.up = key;
        if (eqlIgnoreCase(name, "right")) output.right = key;
        if (eqlIgnoreCase(name, "down")) output.down = key;
        if (eqlIgnoreCase(name, "left")) output.left = key;
    }
}

fn keyDown(key: u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return Win32.GetAsyncKeyState(key) < 0;
}

fn axis(negative: bool, positive: bool) u8 {
    if (negative == positive) return 128;
    return if (negative) 0 else 255;
}

fn stickAxis(value: i16) u8 {
    const shifted: i32 = @as(i32, value) + 32768;
    return @intCast(@divTrunc(shifted * 255, 65535));
}

fn invertStickAxis(value: i16) u8 {
    return 255 - stickAxis(value);
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

const Win32 = if (builtin.os.tag == .windows) struct {
    const XInputGamepad = extern struct {
        buttons: u16 = 0,
        left_trigger: u8 = 0,
        right_trigger: u8 = 0,
        thumb_lx: i16 = 0,
        thumb_ly: i16 = 0,
        thumb_rx: i16 = 0,
        thumb_ry: i16 = 0,
    };
    const XInputState = extern struct {
        packet_number: u32 = 0,
        gamepad: XInputGamepad = .{},
    };

    const xinput_dpad_up: u16 = 0x0001;
    const xinput_dpad_down: u16 = 0x0002;
    const xinput_dpad_left: u16 = 0x0004;
    const xinput_dpad_right: u16 = 0x0008;
    const xinput_start: u16 = 0x0010;
    const xinput_left_thumb: u16 = 0x0040;
    const xinput_right_thumb: u16 = 0x0080;
    const xinput_left_shoulder: u16 = 0x0100;
    const xinput_right_shoulder: u16 = 0x0200;
    const xinput_a: u16 = 0x1000;
    const xinput_b: u16 = 0x2000;
    const xinput_x: u16 = 0x4000;
    const xinput_y: u16 = 0x8000;

    extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buffer: ?[*]u8, size: u32) callconv(.winapi) u32;
    extern "user32" fn GetAsyncKeyState(key: i32) callconv(.winapi) i16;
    extern "xinput1_4" fn XInputGetState(user_index: u32, state: *XInputState) callconv(.winapi) u32;
} else struct {};

test "stick axes preserve the centre and endpoints" {
    try std.testing.expectEqual(@as(u8, 0), stickAxis(-32768));
    try std.testing.expectEqual(@as(u8, 127), stickAxis(0));
    try std.testing.expectEqual(@as(u8, 255), stickAxis(32767));
}

test "keyboard mapping parser changes only named keys" {
    var value = Mapping{};
    parseMapping("cross=88,circle=67,unknown=1", &value);
    try std.testing.expectEqual(@as(u8, 'X'), value.cross);
    try std.testing.expectEqual(@as(u8, 'C'), value.circle);
    try std.testing.expectEqual(@as(u8, 'F'), value.square);
}
