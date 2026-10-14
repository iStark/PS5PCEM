// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Ordered GPU timestamps in the 100 MHz graphics reference-clock domain.
//! Windows QPC calibration gives device queries and the CPU fallback the
//! same epoch without a queue submission or a host fence per timestamp.
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const vk = @import("api.zig");

pub const frequency: u64 = 100_000_000;
pub const Info = extern struct {
    s_type: u32 = 1000184000,
    p_next: ?*const anyopaque = null,
    time_domain: u32,
};
pub const GetDomains = *const fn (vk.PhysicalDevice, *u32, ?[*]u32) callconv(vk.call) vk.Result;
pub const GetTimestamps = *const fn (vk.Device, u32, [*]const Info, [*]u64, *u64) callconv(vk.call) vk.Result;

pub fn supportsDomains(get: GetDomains, physical: vk.PhysicalDevice) bool {
    if (builtin.os.tag != .windows) return false;
    var count: u32 = 0;
    if (get(physical, &count, null) != vk.success or count > 16) return false;
    var domains: [16]u32 = undefined;
    if (get(physical, &count, &domains) != vk.success or count > domains.len) return false;
    return std.mem.indexOfScalar(u32, domains[0..count], 0) != null and
        std.mem.indexOfScalar(u32, domains[0..count], 3) != null;
}

pub fn scale(ticks: u64, source_frequency: u64) ?u64 {
    if (source_frequency == 0) return null;
    return std.math.cast(u64, @as(u128, ticks) * frequency / source_frequency);
}

pub fn now() u64 {
    return gpu.frame_timing.timestampNs() / 10;
}

pub const Calibration = struct {
    device_ticks: u64,
    reference_ticks: u64,
    period_ns: f64,
    max_deviation_ns: u64,

    pub fn convert(self: Calibration, ticks: u64) ?u64 {
        // The optimized path requires 64 valid bits. A backwards clock is
        // not a plausible wrap during one process lifetime.
        if (ticks < self.device_ticks or !std.math.isFinite(self.period_ns) or self.period_ns <= 0) return null;
        const delta = @as(f64, @floatFromInt(ticks - self.device_ticks)) * self.period_ns / 10.0;
        if (!std.math.isFinite(delta) or delta >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
        return std.math.add(u64, self.reference_ticks, @intFromFloat(delta)) catch null;
    }
};

pub fn capture(get: GetTimestamps, device: vk.Device, period_ns: f32) ?Calibration {
    if (builtin.os.tag != .windows) return null;
    if (!std.math.isFinite(period_ns) or period_ns <= 0) return null;
    var host_frequency: std.os.windows.LARGE_INTEGER = 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(&host_frequency).toBool() or host_frequency <= 0) return null;
    const infos = [_]Info{ .{ .time_domain = 0 }, .{ .time_domain = 3 } };
    var ticks: [2]u64 = undefined;
    var deviation: u64 = 0;
    if (get(device, infos.len, &infos, &ticks, &deviation) != vk.success) return null;
    return .{
        .device_ticks = ticks[0],
        .reference_ticks = scale(ticks[1], @intCast(host_frequency)) orelse return null,
        .period_ns = period_ns,
        .max_deviation_ns = deviation,
    };
}

test "graphics reference clock scales host domains without overflow" {
    try std.testing.expectEqual(@as(?u64, 250_000_000), scale(25_000_000, 10_000_000));
    try std.testing.expectEqual(@as(?u64, 100_000_000), scale(3_800_000_000, 3_800_000_000));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), scale(std.math.maxInt(u64), frequency));
    try std.testing.expectEqual(@as(?u64, null), scale(std.math.maxInt(u64), 1));
    try std.testing.expectEqual(@as(?u64, null), scale(1, 0));
}

test "calibrated device timestamps retain intervals and reject invalid clocks" {
    var clock = Calibration{ .device_ticks = 1_000_000, .reference_ticks = 9_000_000, .period_ns = 2.5, .max_deviation_ns = 100 };
    try std.testing.expectEqual(@as(?u64, 9_000_000), clock.convert(1_000_000));
    try std.testing.expectEqual(@as(?u64, 9_100_000), clock.convert(1_400_000));
    try std.testing.expectEqual(@as(?u64, null), clock.convert(999_999));
    clock.reference_ticks = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(?u64, null), clock.convert(1_400_000));
    clock.period_ns = std.math.nan(f64);
    try std.testing.expectEqual(@as(?u64, null), clock.convert(1_000_000));
}
