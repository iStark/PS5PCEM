// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Motion sensors of Sony's pads, in the units libScePad reports.
//!
//! The reports carry raw gyroscope and accelerometer counts on the pad's own
//! axes: X to the right, Y up and Z towards the player, so a pad lying flat
//! measures one g along +Y. libScePad keeps those axes and reports
//! acceleration in g, angular velocity in radians per second and an
//! orientation quaternion it integrates itself.
//!
//! Calibration layouts and scales follow Linux's hid-playstation driver
//! (`dualsense_get_calibration_data`, `dualshock4_get_calibration_data`).
//! The orientation filter is the standard Mahony complementary filter: the
//! gyroscope is integrated and its drift is steered towards the measured
//! gravity, which corrects pitch and roll. Heading cannot be observed.

const std = @import("std");
const dualshock = @import("dualshock.zig");

pub const gravity_up = [3]f32{ 0, 1, 0 };

/// One sample as libScePad reports it.
pub const Sample = struct {
    /// Quaternion x, y, z, w; identity is the orientation at the last reset.
    orientation: [4]f32 = .{ 0, 0, 0, 1 },
    acceleration: [3]f32 = gravity_up,
    angular_velocity: [3]f32 = .{ 0, 0, 0 },
};

/// Both pads span about +/-2000 degrees per second over 16 bits.
const default_gyro_scale: f32 = std.math.rad_per_deg / 16.0;
/// And +/-4 g, 8192 counts per g.
const default_accel_scale: f32 = 1.0 / 8192.0;

/// Converts raw counts into rad/s and g.
pub const Calibration = struct {
    gyro_bias: [3]i32 = .{ 0, 0, 0 },
    gyro_scale: [3]f32 = @splat(default_gyro_scale),
    accel_bias: [3]i32 = .{ 0, 0, 0 },
    accel_scale: [3]f32 = @splat(default_accel_scale),

    pub fn gyro(self: Calibration, raw: [3]i16) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, raw, self.gyro_bias, self.gyro_scale) |*value, count, bias, scale|
            value.* = @as(f32, @floatFromInt(@as(i32, count) - bias)) * scale;
        return out;
    }

    pub fn accel(self: Calibration, raw: [3]i16) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, raw, self.accel_bias, self.accel_scale) |*value, count, bias, scale|
            value.* = @as(f32, @floatFromInt(@as(i32, count) - bias)) * scale;
        return out;
    }
};

/// The feature report each pad answers with its calibration. Asking for it is
/// also what moves a Bluetooth pad onto the full report that carries motion.
pub fn calibrationReportId(family: dualshock.Family, transport: dualshock.Transport) u8 {
    return switch (family) {
        .dual_sense => 0x05,
        .dual_shock_4 => if (transport == .usb) 0x02 else 0x05,
    };
}

fn field(report: []const u8, offset: usize) i32 {
    return std.mem.readInt(i16, report[offset..][0..2], .little);
}

/// Decodes a calibration feature report. Axes whose factory values cannot
/// produce a scale keep the nominal one instead of rejecting the whole pad.
pub fn parseCalibration(family: dualshock.Family, transport: dualshock.Transport, report: []const u8) ?Calibration {
    if (report.len < 35 or report[0] != calibrationReportId(family, transport)) return null;
    const bias = [3]i32{ field(report, 1), field(report, 3), field(report, 5) };
    // Pitch, yaw and roll limits. The DualShock 4's cable report groups the
    // three plus limits before the three minus ones; every other form pairs
    // each axis.
    const grouped = family == .dual_shock_4 and transport == .usb;
    var plus: [3]i32 = undefined;
    var minus: [3]i32 = undefined;
    for (0..3) |axis| {
        plus[axis] = field(report, if (grouped) 7 + axis * 2 else 7 + axis * 4);
        minus[axis] = field(report, if (grouped) 13 + axis * 2 else 9 + axis * 4);
    }
    const speed_2x = field(report, 19) + field(report, 21);

    var calibration = Calibration{};
    for (0..3) |axis| {
        // The DualSense applies its gyroscope bias itself; the limits are
        // still measured from it.
        const denominator: i32 = switch (family) {
            .dual_sense => @intCast(@abs(plus[axis] - bias[axis]) + @abs(minus[axis] - bias[axis])),
            .dual_shock_4 => plus[axis] - minus[axis],
        };
        if (family == .dual_shock_4) calibration.gyro_bias[axis] = bias[axis];
        if (denominator > 0 and speed_2x > 0)
            calibration.gyro_scale[axis] = @as(f32, @floatFromInt(speed_2x)) / @as(f32, @floatFromInt(denominator)) * std.math.rad_per_deg;

        const accel_plus = field(report, 23 + axis * 4);
        const accel_minus = field(report, 25 + axis * 4);
        const range = accel_plus - accel_minus;
        if (range > 0) {
            calibration.accel_bias[axis] = accel_plus - @divTrunc(range, 2);
            calibration.accel_scale[axis] = 2.0 / @as(f32, @floatFromInt(range));
        }
    }
    return calibration;
}

/// Elapsed time between two readings of a pad's free-running sensor clock.
pub fn sensorIntervalNanoseconds(family: dualshock.Family, previous: u32, current: u32) u64 {
    return switch (family) {
        // A 32-bit count of 1/3 microsecond.
        .dual_sense => @as(u64, current -% previous) * 1000 / 3,
        // A 16-bit count of 16/3 microseconds.
        .dual_shock_4 => @as(u64, @as(u16, @truncate(current)) -% @as(u16, @truncate(previous))) * 16000 / 3,
    };
}

const Quaternion = [4]f32;

fn normalize(q: Quaternion) Quaternion {
    const length = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (length < 1e-6) return .{ 0, 0, 0, 1 };
    return .{ q[0] / length, q[1] / length, q[2] / length, q[3] / length };
}

/// The world vector `v` expressed on the pad's axes, i.e. rotated by the
/// conjugate of the pad's orientation.
fn toBody(q: Quaternion, v: [3]f32) [3]f32 {
    const x = -q[0];
    const y = -q[1];
    const z = -q[2];
    const w = q[3];
    // v + 2w(u x v) + 2u x (u x v), with u the vector part.
    const t = [3]f32{ 2 * (y * v[2] - z * v[1]), 2 * (z * v[0] - x * v[2]), 2 * (x * v[1] - y * v[0]) };
    return .{
        v[0] + w * t[0] + (y * t[2] - z * t[1]),
        v[1] + w * t[1] + (z * t[0] - x * t[2]),
        v[2] + w * t[2] + (x * t[1] - y * t[0]),
    };
}

/// Accumulates the pad's orientation from consecutive samples.
pub const Fusion = struct {
    orientation: Quaternion = .{ 0, 0, 0, 1 },
    /// Gravity in the frame the orientation is measured from.
    reference_up: [3]f32 = gravity_up,
    drift: [3]f32 = .{ 0, 0, 0 },
    tilt_correction: bool = true,
    /// libScePad's optional deadband: rates below one degree per second read
    /// as zero, before integration.
    deadband: bool = false,
    /// The gyroscope's resting offset, learned while the pad lies still. The
    /// factory bias does not match it once the sensor warms up, and gravity
    /// cannot correct the heading drift it causes.
    gyro_bias: [3]f32 = .{ 0, 0, 0 },
    still_sum: [3]f32 = .{ 0, 0, 0 },
    still_time: f32 = 0,
    last: Sample = .{},

    const proportional_gain: f32 = 1.5;
    const integral_gain: f32 = 0.02;
    const deadband_rate: f32 = std.math.rad_per_deg;
    /// Longer gaps (a stalled guest, a queue overflow) are not integrated.
    const maximum_interval_s: f32 = 0.1;
    /// A pad turning slower than this, about three degrees per second, with
    /// one g on its accelerometer for a whole second is treated as resting.
    const still_rate: f32 = 0.05;
    const still_window_s: f32 = 1.0;

    /// Feeds one sample. `interval_s` is the time since the previous one.
    pub fn update(self: *Fusion, gyro: [3]f32, accel: [3]f32, interval_s: f32) void {
        self.learnBias(gyro, accel, interval_s);
        var rate = [3]f32{ gyro[0] - self.gyro_bias[0], gyro[1] - self.gyro_bias[1], gyro[2] - self.gyro_bias[2] };
        if (self.deadband) for (&rate) |*axis| {
            if (@abs(axis.*) < deadband_rate) axis.* = 0;
        };
        self.last.acceleration = accel;
        self.last.angular_velocity = rate;
        if (interval_s > 0 and interval_s <= maximum_interval_s) {
            var corrected = rate;
            const magnitude = @sqrt(accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2]);
            // Only a sample near one g is a trustworthy gravity reading.
            if (self.tilt_correction and magnitude > 0.75 and magnitude < 1.25) {
                const measured = [3]f32{ accel[0] / magnitude, accel[1] / magnitude, accel[2] / magnitude };
                const expected = toBody(self.orientation, self.reference_up);
                const err = [3]f32{
                    measured[1] * expected[2] - measured[2] * expected[1],
                    measured[2] * expected[0] - measured[0] * expected[2],
                    measured[0] * expected[1] - measured[1] * expected[0],
                };
                for (&corrected, &self.drift, err) |*axis, *drift, e| {
                    drift.* += integral_gain * e * interval_s;
                    axis.* += proportional_gain * e + drift.*;
                }
            }
            const half = [3]f32{ 0.5 * corrected[0] * interval_s, 0.5 * corrected[1] * interval_s, 0.5 * corrected[2] * interval_s };
            const q = self.orientation;
            self.orientation = normalize(.{
                q[0] + q[3] * half[0] + q[1] * half[2] - q[2] * half[1],
                q[1] + q[3] * half[1] - q[0] * half[2] + q[2] * half[0],
                q[2] + q[3] * half[2] + q[0] * half[1] - q[1] * half[0],
                q[3] - q[0] * half[0] - q[1] * half[1] - q[2] * half[2],
            });
        }
        self.last.orientation = self.orientation;
    }

    fn learnBias(self: *Fusion, gyro: [3]f32, accel: [3]f32, interval_s: f32) void {
        if (interval_s <= 0 or interval_s > maximum_interval_s) return;
        const magnitude = @sqrt(accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2]);
        var still = magnitude > 0.9 and magnitude < 1.1;
        for (gyro, self.gyro_bias) |axis, bias| still = still and @abs(axis - bias) < still_rate;
        if (!still) {
            self.still_sum = .{ 0, 0, 0 };
            self.still_time = 0;
            return;
        }
        for (&self.still_sum, gyro) |*sum, axis| sum.* += axis * interval_s;
        self.still_time += interval_s;
        if (self.still_time < still_window_s) return;
        for (&self.gyro_bias, self.still_sum) |*bias, sum| bias.* = sum / self.still_time;
        self.still_sum = .{ 0, 0, 0 };
        self.still_time = 0;
    }

    /// Makes the current attitude the new identity, as scePadResetOrientation
    /// does. The present gravity reading becomes the reference that later
    /// tilt corrections steer towards.
    pub fn resetOrientation(self: *Fusion) void {
        const a = self.last.acceleration;
        const magnitude = @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
        self.reference_up = if (magnitude > 0.75 and magnitude < 1.25)
            .{ a[0] / magnitude, a[1] / magnitude, a[2] / magnitude }
        else
            gravity_up;
        self.orientation = .{ 0, 0, 0, 1 };
        self.drift = .{ 0, 0, 0 };
        self.last.orientation = self.orientation;
    }
};

test "DualSense calibration scales counts into radians per second and g" {
    var report: [41]u8 = @splat(0);
    report[0] = 0x05;
    const words = [_]i16{
        3, -2, 1, // gyro bias
        8640, -8640, 8640, -8640, 8640, -8640, // pitch, yaw, roll limits
        540, 540, // speed limits
        8192, -8192, 8300, -8100, 8192, -8192, // accelerometer limits
    };
    for (words, 0..) |word, index| std.mem.writeInt(i16, report[1 + index * 2 ..][0..2], word, .little);
    const calibration = parseCalibration(.dual_sense, .usb, &report).?;
    // 1080 / ~17280 degrees per second per count: 16 counts per degree.
    const rate = calibration.gyro(.{ 1728, 0, -1728 });
    try std.testing.expectApproxEqRel(@as(f32, 108 * std.math.rad_per_deg), rate[0], 0.01);
    try std.testing.expectApproxEqRel(@as(f32, -108 * std.math.rad_per_deg), rate[2], 0.01);
    // The DualSense bias is not subtracted again.
    try std.testing.expectEqual(@as(f32, 0), calibration.gyro(.{ 0, 0, 0 })[1]);
    const accel = calibration.accel(.{ 0, 8300, -8192 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), accel[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), accel[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -1), accel[2], 1e-3);
    try std.testing.expect(parseCalibration(.dual_sense, .usb, report[0..20]) == null);
    report[0] = 0x02;
    try std.testing.expect(parseCalibration(.dual_sense, .usb, &report) == null);
}

test "DualShock 4 calibration reads both limit orders and subtracts its bias" {
    var usb: [37]u8 = @splat(0);
    usb[0] = 0x02;
    var bluetooth: [41]u8 = @splat(0);
    bluetooth[0] = 0x05;
    const usb_words = [_]i16{ 10, 0, 0, 8650, 8640, 8640, -8630, -8640, -8640, 540, 540, 8192, -8192, 8192, -8192, 8192, -8192 };
    const bluetooth_words = [_]i16{ 10, 0, 0, 8650, -8630, 8640, -8640, 8640, -8640, 540, 540, 8192, -8192, 8192, -8192, 8192, -8192 };
    for (usb_words, 0..) |word, index| std.mem.writeInt(i16, usb[1 + index * 2 ..][0..2], word, .little);
    for (bluetooth_words, 0..) |word, index| std.mem.writeInt(i16, bluetooth[1 + index * 2 ..][0..2], word, .little);
    const wired = parseCalibration(.dual_shock_4, .usb, &usb).?;
    const wireless = parseCalibration(.dual_shock_4, .bluetooth, &bluetooth).?;
    try std.testing.expectEqual(wired, wireless);
    try std.testing.expectEqual(@as(f32, 0), wired.gyro(.{ 10, 0, 0 })[0]);
    try std.testing.expectApproxEqRel(@as(f32, std.math.rad_per_deg), wired.gyro(.{ 26, 16, 0 })[0], 0.01);
}

test "sensor clocks wrap at their own widths" {
    try std.testing.expectEqual(@as(u64, 1000), sensorIntervalNanoseconds(.dual_sense, 100, 103));
    try std.testing.expectEqual(@as(u64, 1000), sensorIntervalNanoseconds(.dual_sense, 0xffff_ffff, 2));
    try std.testing.expectEqual(@as(u64, 16000), sensorIntervalNanoseconds(.dual_shock_4, 0x1ffff, 0x20002));
}

test "a resting pad keeps its identity orientation and reports one g up" {
    var fusion = Fusion{};
    for (0..1000) |_| fusion.update(.{ 0, 0, 0 }, gravity_up, 0.004);
    try std.testing.expectApproxEqAbs(@as(f32, 1), fusion.last.orientation[3], 1e-4);
    try std.testing.expectEqual(gravity_up, fusion.last.acceleration);
}

test "a pitch rotation integrates and tilt correction pulls drift back to gravity" {
    var fusion = Fusion{ .tilt_correction = false };
    // Ninety degrees about X in one second.
    for (0..250) |_| fusion.update(.{ std.math.pi / 2.0, 0, 0 }, gravity_up, 0.004);
    const half = @sqrt(@as(f32, 0.5));
    try std.testing.expectApproxEqAbs(half, fusion.last.orientation[0], 0.01);
    try std.testing.expectApproxEqAbs(half, fusion.last.orientation[3], 0.01);
    // The expected gravity on the pad's axes then lies along -Z.
    const up = toBody(fusion.orientation, gravity_up);
    try std.testing.expectApproxEqAbs(@as(f32, -1), up[2], 0.02);

    // A stationary pad whose gyroscope reports a false rate stays level.
    fusion = .{};
    for (0..5000) |_| fusion.update(.{ 0.05, 0, 0 }, gravity_up, 0.004);
    try std.testing.expect(@abs(fusion.last.orientation[0]) < 0.02);
}

test "a resting gyroscope offset is learned and no longer turns the heading" {
    var fusion = Fusion{};
    const offset = [3]f32{ 0.01, -0.009, 0.011 };
    for (0..2000) |_| fusion.update(offset, gravity_up, 0.004);
    for (fusion.last.angular_velocity) |axis| try std.testing.expect(@abs(axis) < 1e-4);
    const heading = fusion.last.orientation[1];
    for (0..2500) |_| fusion.update(offset, gravity_up, 0.004);
    try std.testing.expect(@abs(fusion.last.orientation[1] - heading) < 1e-3);
    // Real motion is reported in full and never absorbed into the offset.
    fusion.update(.{ 0.01, 1.0, 0.011 }, gravity_up, 0.004);
    try std.testing.expectApproxEqAbs(@as(f32, 1.009), fusion.last.angular_velocity[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -0.009), fusion.gyro_bias[1], 1e-4);
}

test "orientation resets to the current attitude and the deadband zeroes slow rates" {
    var fusion = Fusion{ .deadband = true };
    const tilted = [3]f32{ 0, @sqrt(@as(f32, 0.5)), -@sqrt(@as(f32, 0.5)) };
    fusion.update(.{ 0.01, 0.5, 0 }, tilted, 0.004);
    try std.testing.expectEqual(@as(f32, 0), fusion.last.angular_velocity[0]);
    try std.testing.expectEqual(@as(f32, 0.5), fusion.last.angular_velocity[1]);
    fusion.resetOrientation();
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, fusion.last.orientation);
    // Held at that tilt, the reset attitude stays the identity.
    for (0..1000) |_| fusion.update(.{ 0, 0, 0 }, tilted, 0.004);
    try std.testing.expectApproxEqAbs(@as(f32, 1), fusion.last.orientation[3], 1e-3);
    // A gap longer than the integration limit only refreshes the readings.
    fusion.update(.{ 3, 0, 0 }, tilted, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), fusion.last.orientation[3], 1e-3);
}
