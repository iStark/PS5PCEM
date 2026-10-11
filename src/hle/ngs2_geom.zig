// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! NGS2 geometry helpers: a listener basis from position and orientation,
//! and the attributes one positioned source gets relative to it — distance
//! rolloff, cone directivity, Doppler pitch, and a speaker level matrix.
//!
//! The structures are the SDK's public layouts. The formulas are the usual
//! ones for positional audio (OpenAL's distance models and Doppler, pairwise
//! constant-power panning), because the SDK documents what each field means
//! but not its arithmetic. Two encodings are inferred rather than documented:
//! rolloff models are numbered inverse (the reset default), linear,
//! exponential; and `matrix_format` counts the source's input channels, each
//! a row of eight output levels in `Attribute.level`, as the pan matrix is.

const std = @import("std");

pub const Vector = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const Cone = extern struct {
    inner_level: f32 = 0,
    /// Full cone angles in degrees.
    inner_angle: f32 = 0,
    outer_level: f32 = 0,
    outer_angle: f32 = 0,
};

pub const Rolloff = extern struct {
    model: u32 = 0,
    max_distance: f32 = 0,
    rolloff_factor: f32 = 0,
    reference_distance: f32 = 0,
};

pub const ListenerParam = extern struct {
    position: Vector = .{},
    orient_front: Vector = .{},
    orient_up: Vector = .{},
    velocity: Vector = .{},
    sound_speed: f32 = 0,
    reserved: [2]u32 = .{ 0, 0 },
};

/// Opaque to titles: produced by `calcListener` and consumed by `apply`.
/// `matrix` rows are the listener's right, up and front axes, each with the
/// translation that moves the listener to the origin.
pub const ListenerWork = extern struct {
    matrix: [4][4]f32 = @splat(@splat(0)),
    velocity: Vector = .{},
    sound_speed: f32 = 0,
    coordinate: u32 = 0,
    reserved: [3]u32 = .{ 0, 0, 0 },
};

pub const SourceParam = extern struct {
    position: Vector = .{},
    velocity: Vector = .{},
    direction: Vector = .{},
    cone: Cone = .{},
    rolloff: Rolloff = .{},
    doppler_factor: f32 = 0,
    fbw_level: f32 = 0,
    lfe_level: f32 = 0,
    max_level: f32 = 0,
    min_level: f32 = 0,
    radius: f32 = 0,
    num_speakers: u32 = 0,
    matrix_format: u32 = 0,
    reserved: [2]u32 = .{ 0, 0 },
};

pub const A3dAttribute = extern struct {
    /// The source in listener space: x right, y up, z front.
    position: Vector = .{},
    volume: f32 = 0,
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

pub const max_channels = 8;

pub const Attribute = extern struct {
    pitch_ratio: f32 = 0,
    /// `level[input * 8 + output]`.
    level: [max_channels * max_channels]f32 = @splat(0),
    a3d: A3dAttribute = .{},
    reserved: [4]u32 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(ListenerParam) == 60);
    std.debug.assert(@sizeOf(ListenerWork) == 96);
    std.debug.assert(@sizeOf(SourceParam) == 108);
    std.debug.assert(@sizeOf(A3dAttribute) == 32);
    std.debug.assert(@sizeOf(Attribute) == 308);
}

pub const rolloff_inverse: u32 = 0;
pub const rolloff_linear: u32 = 1;
pub const rolloff_exponential: u32 = 2;

/// `calcListener` flag: the caller's coordinates are right-handed. Without
/// it they are left-handed, matching the reset orientation (front +Z, up +Y).
pub const coordinate_right_handed: u32 = 1;

pub const default_sound_speed: f32 = 343.0;

pub const Error = error{InvalidOrientation};

pub fn resetListener(param: *ListenerParam) void {
    param.* = .{
        .orient_front = .{ .z = 1 },
        .orient_up = .{ .y = 1 },
        .sound_speed = default_sound_speed,
    };
}

pub fn resetSource(param: *SourceParam) void {
    param.* = .{
        .direction = .{ .z = 1 },
        .cone = .{ .inner_level = 1, .inner_angle = 360, .outer_level = 1, .outer_angle = 360 },
        .rolloff = .{
            .model = rolloff_inverse,
            .max_distance = 1_000_000,
            .rolloff_factor = 1,
            .reference_distance = 1,
        },
        .doppler_factor = 1,
        .fbw_level = 1,
        .lfe_level = 1,
        .max_level = 1,
        .min_level = 0,
        .num_speakers = 2,
        .matrix_format = 1,
    };
}

/// Builds an orthonormal listener basis. The front vector wins; up is only
/// made perpendicular to it, so a slightly tilted up vector still works.
pub fn calcListener(param: ListenerParam, flags: u32, work: *ListenerWork) Error!void {
    const front = normalize(param.orient_front) orelse return Error.InvalidOrientation;
    const up_hint = normalize(param.orient_up) orelse return Error.InvalidOrientation;
    const right_handed = flags & coordinate_right_handed != 0;
    const right = normalize(if (right_handed) cross(front, up_hint) else cross(up_hint, front)) orelse
        return Error.InvalidOrientation;
    const up = if (right_handed) cross(right, front) else cross(front, right);
    work.* = .{
        .velocity = param.velocity,
        .sound_speed = if (param.sound_speed > 0 and std.math.isFinite(param.sound_speed)) param.sound_speed else default_sound_speed,
        .coordinate = if (right_handed) 1 else 0,
    };
    for ([_]Vector{ right, up, front }, 0..) |axis, row| {
        work.matrix[row] = .{ axis.x, axis.y, axis.z, -dot(axis, param.position) };
    }
    work.matrix[3] = .{ 0, 0, 0, 1 };
}

/// Computes one source's attributes relative to a listener from
/// `calcListener`. Every finite input produces finite output.
pub fn apply(listener: ListenerWork, source: SourceParam, attribute: *Attribute) void {
    attribute.* = .{};
    const local = transformPoint(listener, source.position);
    const distance = length(local);

    const level = std.math.clamp(
        distanceGain(source.rolloff, distance) * coneGain(listener, source, local, distance),
        @min(source.min_level, source.max_level),
        source.max_level,
    );
    attribute.pitch_ratio = dopplerRatio(listener, source, local, distance);
    attribute.a3d = .{ .position = local, .volume = level };

    const speakers = layoutFor(source.num_speakers);
    var outputs: [max_channels]f32 = @splat(0);
    panGains(speakers, local, distance, source.radius, &outputs);
    for (speakers.channels[0..speakers.count], 0..) |channel, index| {
        outputs[index] *= level * if (channel.lfe) source.lfe_level else source.fbw_level;
    }
    const inputs: usize = std.math.clamp(source.matrix_format, 1, max_channels);
    for (0..inputs) |input| {
        @memcpy(attribute.level[input * max_channels ..][0..max_channels], &outputs);
    }
}

fn distanceGain(rolloff: Rolloff, distance: f32) f32 {
    const reference: f32 = if (rolloff.reference_distance > 0) rolloff.reference_distance else 1;
    const maximum = @max(rolloff.max_distance, reference);
    const clamped = std.math.clamp(distance, reference, maximum);
    const factor = @max(rolloff.rolloff_factor, 0);
    const gain = switch (rolloff.model) {
        rolloff_linear => if (maximum > reference)
            1 - factor * (clamped - reference) / (maximum - reference)
        else
            1,
        rolloff_exponential => std.math.pow(f32, clamped / reference, -factor),
        else => reference / (reference + factor * (clamped - reference)),
    };
    return std.math.clamp(gain, 0, 1);
}

/// Cone angles are full apertures around the source's direction; the level
/// moves linearly between the inner and outer cones.
fn coneGain(listener: ListenerWork, source: SourceParam, local: Vector, distance: f32) f32 {
    const direction = normalize(rotate(listener, source.direction)) orelse return source.cone.inner_level;
    if (distance <= 1e-6) return source.cone.inner_level;
    const to_listener = scale(local, -1 / distance);
    const cosine = std.math.clamp(dot(direction, to_listener), -1, 1);
    const aperture = 2 * std.math.radiansToDegrees(std.math.acos(cosine));
    const inner = std.math.clamp(source.cone.inner_angle, 0, 360);
    const outer = std.math.clamp(@max(source.cone.outer_angle, inner), 0, 360);
    if (aperture <= inner) return source.cone.inner_level;
    if (aperture >= outer or outer <= inner) return source.cone.outer_level;
    const t = (aperture - inner) / (outer - inner);
    return source.cone.inner_level + (source.cone.outer_level - source.cone.inner_level) * t;
}

/// OpenAL's Doppler shift along the source-listener axis, with velocities
/// clamped below the speed of sound so the ratio stays positive.
fn dopplerRatio(listener: ListenerWork, source: SourceParam, local: Vector, distance: f32) f32 {
    const factor = source.doppler_factor;
    if (factor <= 0 or distance <= 1e-6) return 1;
    const speed = listener.sound_speed;
    const axis = scale(local, -1 / distance); // source towards listener
    const limit = speed / factor;
    const listener_speed = @min(dot(rotate(listener, listener.velocity), axis), limit * 0.999);
    const source_speed = @min(dot(rotate(listener, source.velocity), axis), limit * 0.999);
    const ratio = (speed - factor * listener_speed) / (speed - factor * source_speed);
    return if (std.math.isFinite(ratio)) std.math.clamp(ratio, 1.0 / 16.0, 16) else 1;
}

const Channel = struct { azimuth: f32 = 0, lfe: bool = false };
const Layout = struct { count: usize, channels: [max_channels]Channel };

/// Speaker azimuths in degrees, clockwise from front, in the PS5 output
/// channel order: L R C LFE Ls Rs (Lb Rb).
fn layoutFor(num_speakers: u32) Layout {
    var layout = Layout{ .count = 0, .channels = @splat(.{}) };
    const angles: []const Channel = switch (num_speakers) {
        0, 2...5 => &.{ .{ .azimuth = -90 }, .{ .azimuth = 90 } },
        1 => &.{.{ .azimuth = 0 }},
        6, 7 => &.{ .{ .azimuth = -30 }, .{ .azimuth = 30 }, .{ .azimuth = 0 }, .{ .lfe = true }, .{ .azimuth = -110 }, .{ .azimuth = 110 } },
        else => &.{ .{ .azimuth = -30 }, .{ .azimuth = 30 }, .{ .azimuth = 0 }, .{ .lfe = true }, .{ .azimuth = -90 }, .{ .azimuth = 90 }, .{ .azimuth = -150 }, .{ .azimuth = 150 } },
    };
    @memcpy(layout.channels[0..angles.len], angles);
    layout.count = angles.len;
    return layout;
}

/// Constant-power gains for the full-bandwidth speakers (LFE gets 1). A
/// source overhead, at the listener, or inside its own radius spreads
/// evenly; in between, the directional and even mixes are blended by power.
fn panGains(layout: Layout, local: Vector, distance: f32, radius: f32, gains: *[max_channels]f32) void {
    var full_band: usize = 0;
    for (layout.channels[0..layout.count]) |channel| full_band += @intFromBool(!channel.lfe);
    const horizontal = std.math.sqrt(local.x * local.x + local.z * local.z);
    var weight: f32 = if (distance > 1e-6) horizontal / distance else 0;
    if (radius > 0) weight *= 1 - std.math.clamp(radius / @max(distance, 1e-6), 0, 1);

    var directional: [max_channels]f32 = @splat(0);
    if (weight > 0) {
        const azimuth = std.math.radiansToDegrees(std.math.atan2(local.x, local.z));
        if (full_band == 1) {
            for (layout.channels[0..layout.count], 0..) |channel, index| {
                if (!channel.lfe) directional[index] = 1;
            }
        } else if (full_band == 2) {
            // Stereo folds the rear onto the front: the sine of the azimuth
            // is the left-right position.
            const position = std.math.sin(std.math.degreesToRadians(azimuth));
            const angle = (position + 1) * std.math.pi / 4;
            directional[0] = std.math.cos(angle);
            directional[1] = std.math.sin(angle);
        } else {
            pairwise(layout, azimuth, &directional);
        }
    }
    const even = 1 / @as(f32, @floatFromInt(full_band));
    for (layout.channels[0..layout.count], 0..) |channel, index| {
        gains[index] = if (channel.lfe)
            1
        else
            std.math.sqrt(weight * directional[index] * directional[index] + (1 - weight) * even);
    }
}

/// Pans between the two speakers that bracket the azimuth.
fn pairwise(layout: Layout, azimuth: f32, gains: *[max_channels]f32) void {
    var best_left: ?usize = null;
    var best_right: ?usize = null;
    var left_gap: f32 = 361;
    var right_gap: f32 = 361;
    for (layout.channels[0..layout.count], 0..) |channel, index| {
        if (channel.lfe) continue;
        const clockwise = wrap360(channel.azimuth - azimuth);
        const counter = wrap360(azimuth - channel.azimuth);
        if (clockwise < right_gap) {
            right_gap = clockwise;
            best_right = index;
        }
        if (counter < left_gap) {
            left_gap = counter;
            best_left = index;
        }
    }
    const left = best_left orelse return;
    const right = best_right orelse return;
    const span = left_gap + right_gap;
    if (left == right or span <= 1e-4) {
        gains[left] = 1;
        return;
    }
    const t = left_gap / span;
    gains[left] = std.math.cos(t * std.math.pi / 2);
    gains[right] = std.math.sin(t * std.math.pi / 2);
}

fn wrap360(degrees: f32) f32 {
    const wrapped = @mod(degrees, 360);
    return if (wrapped < 0) wrapped + 360 else wrapped;
}

fn transformPoint(work: ListenerWork, point: Vector) Vector {
    var result: [3]f32 = undefined;
    for (0..3) |row| {
        const m = work.matrix[row];
        result[row] = m[0] * point.x + m[1] * point.y + m[2] * point.z + m[3];
    }
    return .{ .x = result[0], .y = result[1], .z = result[2] };
}

fn rotate(work: ListenerWork, vector: Vector) Vector {
    var result: [3]f32 = undefined;
    for (0..3) |row| {
        const m = work.matrix[row];
        result[row] = m[0] * vector.x + m[1] * vector.y + m[2] * vector.z;
    }
    return .{ .x = result[0], .y = result[1], .z = result[2] };
}

fn dot(a: Vector, b: Vector) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn cross(a: Vector, b: Vector) Vector {
    return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
}

fn scale(a: Vector, factor: f32) Vector {
    return .{ .x = a.x * factor, .y = a.y * factor, .z = a.z * factor };
}

fn length(a: Vector) f32 {
    return std.math.sqrt(dot(a, a));
}

fn normalize(a: Vector) ?Vector {
    const magnitude = length(a);
    if (!(magnitude > 1e-6) or !std.math.isFinite(magnitude)) return null;
    return scale(a, 1 / magnitude);
}

fn defaultListener() ListenerWork {
    var param: ListenerParam = undefined;
    resetListener(&param);
    var work: ListenerWork = undefined;
    calcListener(param, 0, &work) catch unreachable;
    return work;
}

fn defaultSource() SourceParam {
    var source: SourceParam = undefined;
    resetSource(&source);
    return source;
}

test "listener basis maps left-handed and right-handed front, right and up" {
    var work = defaultListener();
    // Left-handed default: +X is right of a listener facing +Z.
    try std.testing.expectApproxEqAbs(@as(f32, 1), transformPoint(work, .{ .x = 1 }).x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), transformPoint(work, .{ .z = 1 }).z, 1e-6);

    var param: ListenerParam = undefined;
    resetListener(&param);
    param.orient_front = .{ .z = -1 };
    param.position = .{ .x = 10, .y = 2, .z = 5 };
    try calcListener(param, coordinate_right_handed, &work);
    // Right-handed, facing -Z: +X is still to the right, positions are relative.
    const local = transformPoint(work, .{ .x = 11, .y = 3, .z = 3 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), local.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), local.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), local.z, 1e-5);

    param.orient_up = param.orient_front;
    try std.testing.expectError(Error.InvalidOrientation, calcListener(param, 0, &work));
}

test "distance models attenuate between the reference and maximum distance" {
    const inverse = Rolloff{ .model = rolloff_inverse, .max_distance = 100, .rolloff_factor = 1, .reference_distance = 2 };
    try std.testing.expectEqual(@as(f32, 1), distanceGain(inverse, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), distanceGain(inverse, 4), 1e-6);
    try std.testing.expectApproxEqAbs(distanceGain(inverse, 100), distanceGain(inverse, 1000), 1e-6);
    const linear = Rolloff{ .model = rolloff_linear, .max_distance = 12, .rolloff_factor = 1, .reference_distance = 2 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), distanceGain(linear, 7), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), distanceGain(linear, 50));
    const exponential = Rolloff{ .model = rolloff_exponential, .max_distance = 100, .rolloff_factor = 2, .reference_distance = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), distanceGain(exponential, 2), 1e-6);
}

test "stereo panning keeps constant power and follows the source side" {
    const listener = defaultListener();
    var source = defaultSource();
    var attribute: Attribute = undefined;

    source.position = .{ .z = 1 };
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(attribute.level[0], attribute.level[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), attribute.level[0] * attribute.level[0] + attribute.level[1] * attribute.level[1], 1e-5);
    try std.testing.expectEqual(@as(f32, 1), attribute.pitch_ratio);

    source.position = .{ .x = 1 };
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(@as(f32, 0), attribute.level[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), attribute.level[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), attribute.a3d.position.x, 1e-6);

    // Overhead, or inside the source's own radius, spreads evenly.
    source.position = .{ .y = 5 };
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(attribute.level[0], attribute.level[1], 1e-6);
    source.position = .{ .x = 1 };
    source.radius = 2;
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(attribute.level[0], attribute.level[1], 1e-6);
}

test "surround layouts pan between bracketing speakers and feed LFE separately" {
    const listener = defaultListener();
    var source = defaultSource();
    source.num_speakers = 8;
    source.lfe_level = 0.5;
    source.matrix_format = 2;
    var attribute: Attribute = undefined;

    source.position = .{ .x = 1 }; // azimuth +90: exactly the right side speaker
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(@as(f32, 1), attribute.level[5], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), attribute.level[3], 1e-6);
    for ([_]usize{ 0, 1, 2, 4, 6, 7 }) |index| try std.testing.expectApproxEqAbs(@as(f32, 0), attribute.level[index], 1e-5);
    // The second input row repeats the first.
    try std.testing.expectEqualSlices(f32, attribute.level[0..8], attribute.level[8..16]);

    // Azimuth -135 at unit distance: between Ls (-90) and Lb (-150).
    source.position = .{ .x = -std.math.sqrt1_2, .z = -std.math.sqrt1_2 };
    apply(listener, source, &attribute);
    const ls = attribute.level[4];
    const lb = attribute.level[6];
    try std.testing.expect(ls > 0 and lb > 0 and lb > ls);
    try std.testing.expectApproxEqAbs(@as(f32, 1), ls * ls + lb * lb, 1e-5);
}

test "cone, level limits and Doppler shape the attributes" {
    const listener = defaultListener();
    var source = defaultSource();
    var attribute: Attribute = undefined;

    // A source 10 units ahead, facing away, behind a 90-degree cone.
    source.position = .{ .z = 10 };
    source.direction = .{ .z = 1 };
    source.cone = .{ .inner_level = 1, .inner_angle = 90, .outer_level = 0.25, .outer_angle = 180 };
    source.rolloff.model = rolloff_linear;
    source.rolloff.max_distance = 11;
    source.rolloff.reference_distance = 1;
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1 * 0.25), attribute.a3d.volume, 1e-5);
    source.min_level = 0.5;
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), attribute.a3d.volume, 1e-6);

    // Approaching at a tenth of the speed of sound raises the pitch by 1/0.9.
    source = defaultSource();
    source.position = .{ .z = 10 };
    source.velocity = .{ .z = -default_sound_speed / 10 };
    apply(listener, source, &attribute);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 0.9), attribute.pitch_ratio, 1e-5);
    source.doppler_factor = 0;
    apply(listener, source, &attribute);
    try std.testing.expectEqual(@as(f32, 1), attribute.pitch_ratio);
}
