// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Where a guest frame's wall time actually goes.
//!
//! The renderer times its own work in detail, but those timers only cover
//! what it is asked to do. They cannot see the interval between submissions,
//! so a frame whose renderer accounting sums to a fraction of its length
//! leaves no record of what consumed the rest. This splits the frame at the
//! one boundary that separates the two: the guest's submit entry points.
//! Everything inside them is command-stream translation and Vulkan work;
//! everything outside is guest code and the rest of the HLE.
const std = @import("std");
const builtin = @import("builtin");

var submit_ns: u64 = 0;
var submit_calls: u64 = 0;

pub const Split = struct {
    submit_ns: u64,
    submit_calls: u64,
};

/// Monotonic host nanoseconds, or zero where no counter is available. A zero
/// return disables the split rather than reporting a nonsensical interval.
pub fn timestampNs() u64 {
    if (comptime builtin.os.tag != .windows) {
        var timer = std.time.Timer.start() catch return 0;
        return timer.read();
    }
    var counter: std.os.windows.LARGE_INTEGER = 0;
    var frequency: std.os.windows.LARGE_INTEGER = 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or
        !std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or
        frequency <= 0) return 0;
    const ticks: u128 = @intCast(@max(counter, 0));
    return @intCast(ticks * std.time.ns_per_s / @as(u128, @intCast(frequency)));
}

pub fn elapsedNs(started: u64) u64 {
    if (started == 0) return 0;
    const now = timestampNs();
    return if (now >= started) now - started else 0;
}

/// Submissions arrive on several guest threads, so the accumulators are
/// updated atomically. They are counters, never read for ordering.
pub fn noteSubmit(elapsed_ns: u64) void {
    _ = @atomicRmw(u64, &submit_ns, .Add, elapsed_ns, .monotonic);
    _ = @atomicRmw(u64, &submit_calls, .Add, 1, .monotonic);
}

/// Reads the accumulated split and clears it for the next frame.
pub fn take() Split {
    return .{
        .submit_ns = @atomicRmw(u64, &submit_ns, .Xchg, 0, .monotonic),
        .submit_calls = @atomicRmw(u64, &submit_calls, .Xchg, 0, .monotonic),
    };
}

test "submit accounting accumulates and resets" {
    _ = take();
    noteSubmit(1500);
    noteSubmit(2500);
    const split = take();
    try std.testing.expectEqual(@as(u64, 4000), split.submit_ns);
    try std.testing.expectEqual(@as(u64, 2), split.submit_calls);
    const cleared = take();
    try std.testing.expectEqual(@as(u64, 0), cleared.submit_ns);
    try std.testing.expectEqual(@as(u64, 0), cleared.submit_calls);
    try std.testing.expectEqual(@as(u64, 0), elapsedNs(0));
}
