// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Host sleeps accurate to well under a millisecond.
//!
//! Frame pacing cannot use the ordinary Windows delay: without a raised timer
//! resolution it wakes on the 15.6 ms system tick, which turns a 16.7 ms frame
//! slot into alternating 15.6 and 31.2 ms frames. A high-resolution waitable
//! timer (Windows 10 1803 and later) keeps the requested length without
//! changing the timer resolution for the whole process. Older systems fall
//! back to the ordinary delay. Linux nanosleep is already precise.
//!
//! Safe on guest threads: a lost FS base after the wait is repaired by the
//! native-execution fault handler, as after any other blocking call.

const std = @import("std");
const builtin = @import("builtin");

const windows = struct {
    const HANDLE = std.os.windows.HANDLE;
    const create_waitable_timer_high_resolution: u32 = 0x0000_0002;
    const timer_all_access: u32 = 0x001F_0003;
    const infinite: u32 = 0xFFFF_FFFF;

    extern "kernel32" fn CreateWaitableTimerExW(
        attributes: ?*anyopaque,
        name: ?[*:0]const u16,
        flags: u32,
        desired_access: u32,
    ) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetWaitableTimer(
        timer: HANDLE,
        due_time: *const i64,
        period: i32,
        completion_routine: ?*anyopaque,
        completion_argument: ?*anyopaque,
        resume_system: i32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) i32;

    fn waitHighResolution(microseconds: u64) bool {
        const timer = CreateWaitableTimerExW(null, null, create_waitable_timer_high_resolution, timer_all_access) orelse
            return false;
        defer _ = CloseHandle(timer);
        // Negative 100-ns units: relative to now, not to the wall clock.
        const due: i64 = -@as(i64, @intCast(@min(microseconds, std.math.maxInt(i64) / 10) * 10));
        if (SetWaitableTimer(timer, &due, 0, null, null, 0) == 0) return false;
        return WaitForSingleObject(timer, infinite) == 0;
    }

    fn delay(microseconds: u64) void {
        var interval: i64 = -@as(i64, @intCast(@min(microseconds, std.math.maxInt(i64) / 10) * 10));
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
    }
};

pub fn sleepMicroseconds(microseconds: u64) void {
    if (microseconds == 0) return;
    switch (comptime builtin.os.tag) {
        .windows => if (!windows.waitHighResolution(microseconds)) windows.delay(microseconds),
        .linux => {
            var request = std.os.linux.timespec{
                .sec = @intCast(microseconds / std.time.us_per_s),
                .nsec = @intCast((microseconds % std.time.us_per_s) * std.time.ns_per_us),
            };
            _ = std.os.linux.nanosleep(&request, null);
        },
        else => {},
    }
}

test "a precise sleep lasts at least as long as requested" {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    sleepMicroseconds(2_000);
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - start;
    try std.testing.expect(elapsed >= 2 * std.time.ns_per_ms - std.time.ns_per_ms / 4);
    sleepMicroseconds(0);
}
