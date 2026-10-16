// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! One coalescing output worker. Guest threads publish motor and RGB state and
//! never wait for a USB/Bluetooth write or enumerate controller devices.
const std = @import("std");
const builtin = @import("builtin");
const Mutex = @import("memory").HostMutex;
const hid = @import("hid.zig");
const dualshock = @import("dualshock.zig");

pub const Motors = packed struct(u16) {
    large: u8 = 0,
    small: u8 = 0,

    pub fn xinput(self: Motors) XInputVibration {
        return .{ .left = @as(u16, self.large) * 257, .right = @as(u16, self.small) * 257 };
    }
};

pub const LightBar = packed struct(u32) {
    red: u8 = 0,
    green: u8 = 0,
    blue: u8 = 0,
    active: bool = false,
    reserved: u7 = 0,
};

/// Primary-player host default, also used by AnyPS5. Black is a valid color.
pub const default_light_bar: LightBar = .{ .green = 64, .blue = 255, .active = true };

pub const Output = packed struct(u64) {
    motors: Motors = .{},
    light_bar: LightBar = .{},
    motors_set: bool = false,
    reserved: u15 = 0,

    fn active(self: Output) bool {
        return self.motors.large != 0 or self.motors.small != 0 or self.light_bar.active;
    }

    fn stopped(self: Output) Output {
        var result = self;
        result.motors = .{};
        if (result.light_bar.active) result.light_bar = default_light_bar;
        return result;
    }

    pub fn sony(self: Output) dualshock.Output {
        return .{
            .rumble_strong = self.motors.large,
            .rumble_weak = self.motors.small,
            .set_motors = self.motors_set,
            .red = self.light_bar.red,
            .green = self.light_bar.green,
            .blue = self.light_bar.blue,
            .set_light_bar = self.light_bar.active,
        };
    }
};

const XInputVibration = extern struct { left: u16 = 0, right: u16 = 0 };
const native = builtin.os.tag == .windows and !builtin.is_test;
var mutex: Mutex = .{};
var requested: std.atomic.Value(u64) = .init(0);
var stopping: std.atomic.Value(bool) = .init(false);
var worker: ?std.Thread = null;
var event: ?*anyopaque = null;

pub fn current() Motors {
    return currentOutput().motors;
}

pub fn currentOutput() Output {
    return @bitCast(requested.load(.acquire));
}

pub fn submit(motors: Motors, index: u32) void {
    mutex.lock();
    defer mutex.unlock();
    var output = currentOutput();
    output.motors = motors;
    output.motors_set = true;
    publishLocked(output, index);
}

pub fn setLightBar(red: u8, green: u8, blue: u8, index: u32) void {
    mutex.lock();
    defer mutex.unlock();
    var output = currentOutput();
    output.light_bar = .{ .red = red, .green = green, .blue = blue, .active = true };
    publishLocked(output, index);
}

pub fn resetLightBar(index: u32) void {
    setLightBar(default_light_bar.red, default_light_bar.green, default_light_bar.blue, index);
}

/// Pad close releases the game's color and motors in one atomic update.
pub fn stop(index: u32) void {
    mutex.lock();
    defer mutex.unlock();
    publishLocked(currentOutput().stopped(), index);
}

fn publishLocked(output: Output, index: u32) void {
    const previous = requested.swap(@bitCast(output), .acq_rel);
    // Unit tests inspect the ABI/output mapping without vibrating real devices.
    if (comptime !native) return;
    if (worker == null) {
        if (!output.active()) return;
        event = Win32.CreateEventW(null, 0, 0, null) orelse return;
        stopping.store(false, .release);
        worker = std.Thread.spawn(.{}, run, .{index}) catch {
            _ = Win32.CloseHandle(event.?);
            event = null;
            return;
        };
    } else if (previous == @as(u64, @bitCast(output))) return;
    _ = Win32.SetEvent(event.?);
}

pub fn reset() void {
    mutex.lock();
    defer mutex.unlock();
    if (comptime !native) {
        requested.store(0, .release);
        return;
    }
    // Keep the reset color available to the worker until its final report.
    requested.store(@bitCast(currentOutput().stopped()), .release);
    if (worker) |thread| {
        stopping.store(true, .release);
        _ = Win32.SetEvent(event.?);
        thread.join();
        worker = null;
        _ = Win32.CloseHandle(event.?);
        event = null;
    }
    requested.store(0, .release);
}

fn run(index: u32) void {
    var using_sony = false;
    var used_xinput = false;
    while (!stopping.load(.acquire)) {
        const output = currentOutput();
        // Follow the same preference as input: a native Sony controller first,
        // otherwise the configured XInput slot. Never vibrate both at once.
        // A Sony pad this process cannot drive (another program owns its
        // output, or it refused a report) is still read directly; its rumble
        // goes to the XInput pad such a program usually presents for it.
        const sony = hid.presence();
        if (sony.connected and sony.writable) {
            if (used_xinput) {
                _ = Win32.XInputSetState(index, &.{});
                used_xinput = false;
            }
            using_sony = true;
            _ = hid.setFeedback(output.sony());
        } else {
            using_sony = false;
            // A periodic write also restores feedback after reconnecting the
            // same XInput slot, even when the requested intensities did not change.
            if (output.motors_set) {
                const vibration = output.motors.xinput();
                used_xinput = Win32.XInputSetState(index, &vibration) == 0;
            }
        }
        // Finish pending writes even if the guest stops reading input. While
        // driving motors or color, recheck disconnect/reconnect.
        const pending = hid.pumpOutput();
        const timeout: u32 = if (pending) 4 else if (output.active()) 500 else 0xffff_ffff;
        _ = Win32.WaitForSingleObject(event.?, timeout);
    }
    if (using_sony) {
        _ = hid.setFeedback(currentOutput().sony());
        const until = Win32.GetTickCount64() + 250;
        while (hid.pumpOutput() and Win32.GetTickCount64() < until) Win32.Sleep(1);
    }
    if (used_xinput) _ = Win32.XInputSetState(index, &.{});
}

const Win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn CreateEventW(?*anyopaque, i32, i32, ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn SetEvent(*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(*anyopaque, u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
    extern "xinput1_4" fn XInputSetState(u32, *const XInputVibration) callconv(.winapi) u32;
} else struct {};

test "motor intensity reaches both XInput endpoints without swapping channels" {
    for ([_]Motors{ .{}, .{ .large = 1, .small = 128 }, .{ .large = 255, .small = 17 } }) |motors| {
        const native_motors = motors.xinput();
        try std.testing.expectEqual(@as(u16, motors.large) * 257, native_motors.left);
        try std.testing.expectEqual(@as(u16, motors.small) * 257, native_motors.right);
    }
    submit(.{ .large = 255, .small = 33 }, 0);
    try std.testing.expectEqual(Motors{ .large = 255, .small = 33 }, current());
    submit(.{}, 0);
    try std.testing.expectEqual(Motors{}, current());
    reset();
    try std.testing.expectEqual(Motors{}, current());
}

test "light bar and motors preserve each other including black and reset" {
    reset();
    defer reset();
    setLightBar(201, 17, 89, 0);
    var output = currentOutput();
    try std.testing.expect(!output.motors_set);
    try std.testing.expect(!output.sony().set_motors);
    try std.testing.expectEqual(LightBar{ .red = 201, .green = 17, .blue = 89, .active = true }, output.light_bar);
    submit(.{ .large = 73, .small = 255 }, 0);
    try std.testing.expectEqual(output.light_bar, currentOutput().light_bar);
    setLightBar(0, 0, 0, 0);
    output = currentOutput();
    try std.testing.expectEqual(Motors{ .large = 73, .small = 255 }, output.motors);
    try std.testing.expectEqual(LightBar{ .active = true }, output.light_bar);
    const repeated = requested.load(.acquire);
    setLightBar(0, 0, 0, 0);
    try std.testing.expectEqual(repeated, requested.load(.acquire));
    resetLightBar(0);
    try std.testing.expectEqual(default_light_bar, currentOutput().light_bar);
    try std.testing.expectEqual(output.motors, current());
    stop(0);
    try std.testing.expectEqual(Motors{}, current());
    try std.testing.expectEqual(default_light_bar, currentOutput().light_bar);
    reset();
    try std.testing.expectEqual(Output{}, currentOutput());
}

test "concurrent color and motor producers cannot lose the other channel" {
    reset();
    defer reset();
    const Producer = struct {
        fn colors() void {
            for (0..2000) |i| setLightBar(@truncate(i), 37, 83, 0);
            setLightBar(12, 34, 56, 0);
        }
        fn motors() void {
            for (0..2000) |i| submit(.{ .large = @truncate(i), .small = 53 }, 0);
            submit(.{ .large = 78, .small = 90 }, 0);
        }
    };
    const colors = try std.Thread.spawn(.{}, Producer.colors, .{});
    const motors = std.Thread.spawn(.{}, Producer.motors, .{}) catch |err| {
        colors.join();
        return err;
    };
    colors.join();
    motors.join();
    const output = currentOutput();
    try std.testing.expectEqual(LightBar{ .red = 12, .green = 34, .blue = 56, .active = true }, output.light_bar);
    try std.testing.expectEqual(Motors{ .large = 78, .small = 90 }, output.motors);
}
