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
var counter_frequency: std.atomic.Value(u64) = .init(0);

pub const Split = struct {
    submit_ns: u64,
    submit_calls: u64,
};

/// Monotonic host nanoseconds, or zero where no counter is available. A zero
/// return disables the split rather than reporting a nonsensical interval.
pub fn timestampNs() u64 {
    if (comptime builtin.os.tag == .linux) {
        var now: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(.MONOTONIC, &now) != 0 or now.sec < 0) return 0;
        return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
    }
    if (comptime builtin.os.tag != .windows) return 0;
    var counter: std.os.windows.LARGE_INTEGER = 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or counter < 0) return 0;
    var frequency = counter_frequency.load(.monotonic);
    if (frequency == 0) {
        var queried: std.os.windows.LARGE_INTEGER = 0;
        if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(&queried).toBool() or queried <= 0) return 0;
        frequency = @intCast(queried);
        counter_frequency.store(frequency, .monotonic);
    }
    return counterNanoseconds(@intCast(counter), frequency);
}

fn counterNanoseconds(ticks: u64, frequency: u64) u64 {
    // Windows commonly exposes a 10 MHz counter. Avoid a 128-bit divide at
    // every resource timer when the conversion is an exact multiplication.
    if (std.time.ns_per_s % frequency == 0) {
        const product = @mulWithOverflow(ticks, std.time.ns_per_s / frequency);
        if (product[1] == 0) return product[0];
    }
    return @intCast(@min(std.math.maxInt(u64), @as(u128, ticks) * std.time.ns_per_s / frequency));
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

test "counter conversion preserves fractional frequencies and long uptimes" {
    for ([_]u64{ 1, 3_579_545, 10_000_000, 1_000_000_000, 3_000_000_000 }) |frequency| {
        for ([_]u64{ 0, 1, 123456789, std.math.maxInt(i64), std.math.maxInt(u64) }) |ticks| {
            const expected: u64 = @intCast(@min(std.math.maxInt(u64), @as(u128, ticks) * std.time.ns_per_s / frequency));
            try std.testing.expectEqual(expected, counterNanoseconds(ticks, frequency));
        }
    }
}
