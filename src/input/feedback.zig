// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! One coalescing output worker. Guest threads publish two motor bytes and
//! never wait for a USB/Bluetooth write or enumerate controller devices.
const std = @import("std");
const builtin = @import("builtin");
const Mutex = @import("memory").HostMutex;
const hid = @import("hid.zig");

pub const Motors = packed struct(u16) {
    large: u8 = 0,
    small: u8 = 0,

    pub fn xinput(self: Motors) XInputVibration {
        return .{ .left = @as(u16, self.large) * 257, .right = @as(u16, self.small) * 257 };
    }
};

const XInputVibration = extern struct { left: u16 = 0, right: u16 = 0 };
const native = builtin.os.tag == .windows and !builtin.is_test;
var mutex: Mutex = .{};
var requested: std.atomic.Value(u16) = .init(0);
var stopping: std.atomic.Value(bool) = .init(false);
var worker: ?std.Thread = null;
var event: ?*anyopaque = null;

pub fn current() Motors {
    return @bitCast(requested.load(.acquire));
}

pub fn submit(motors: Motors, index: u32) void {
    mutex.lock();
    defer mutex.unlock();
    const previous = requested.swap(@bitCast(motors), .acq_rel);
    // Unit tests inspect the ABI/output mapping without vibrating real devices.
    if (comptime !native) return;
    if (worker == null) {
        if (@as(u16, @bitCast(motors)) == 0) return;
        event = Win32.CreateEventW(null, 0, 0, null) orelse return;
        stopping.store(false, .release);
        worker = std.Thread.spawn(.{}, run, .{index}) catch {
            _ = Win32.CloseHandle(event.?);
            event = null;
            return;
        };
    } else if (previous == @as(u16, @bitCast(motors))) return;
    _ = Win32.SetEvent(event.?);
}

pub fn reset() void {
    mutex.lock();
    defer mutex.unlock();
    requested.store(0, .release);
    if (comptime !native) return;
    if (worker) |thread| {
        stopping.store(true, .release);
        _ = Win32.SetEvent(event.?);
        thread.join();
        worker = null;
        _ = Win32.CloseHandle(event.?);
        event = null;
    }
}

fn run(index: u32) void {
    var using_sony = false;
    var used_xinput = false;
    while (!stopping.load(.acquire)) {
        const motors = current();
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
            _ = hid.setVibration(motors.large, motors.small);
        } else {
            using_sony = false;
            // A periodic write also restores feedback after reconnecting the
            // same XInput slot, even when the requested intensities did not change.
            const vibration = motors.xinput();
            used_xinput = Win32.XInputSetState(index, &vibration) == 0;
        }
        // Finish pending writes even if the guest stops reading input. While
        // rumbling, recheck disconnect/reconnect; idle workers sleep entirely.
        const pending = hid.pumpOutput();
        const timeout: u32 = if (pending) 4 else if (motors.large != 0 or motors.small != 0) 500 else 0xffff_ffff;
        _ = Win32.WaitForSingleObject(event.?, timeout);
    }
    if (using_sony) {
        _ = hid.setVibration(0, 0);
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
