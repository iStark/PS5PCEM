// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const gpu = @import("gpu");

/// Values are D3D12_BLEND / D3D12_BLEND_OP, shared with native.h.
pub const State = extern struct {
    enabled: u32 = 0,
    source_color: u32 = 2,
    destination_color: u32 = 1,
    color_operation: u32 = 1,
    source_alpha: u32 = 2,
    destination_alpha: u32 = 1,
    alpha_operation: u32 = 1,
    constants: [4]f32 = @splat(0),

    pub fn valid(self: State) bool {
        if (self.enabled > 1 or self.color_operation < 1 or self.color_operation > 5 or
            self.alpha_operation < 1 or self.alpha_operation > 5) return false;
        for ([_]u32{ self.source_color, self.destination_color }) |f| if (!validFactor(f, false)) return false;
        for ([_]u32{ self.source_alpha, self.destination_alpha }) |f| if (!validFactor(f, true)) return false;
        for (self.constants) |v| if (!std.math.isFinite(v)) return false;
        return true;
    }
};

fn validFactor(f: u32, alpha: bool) bool {
    return switch (f) {
        1, 2, 5...8, 14, 15 => true,
        3, 4, 9...11, 20, 21 => !alpha,
        else => false,
    };
}

pub fn decode(state: *const gpu.State, blend: gpu.resources.BlendControl) !State {
    if (!blend.enabled) return .{};
    const color_op = try operation(blend.color_operation);
    const alpha_op = try operation(if (blend.separate_alpha) blend.alpha_operation else blend.color_operation);
    // MIN/MAX ignore their factors. Normalize these before validating dormant
    // factors or deciding which constant registers the draw actually consumes.
    const color_source = if (color_op >= 4) 1 else blend.color_source;
    const color_dest = if (color_op >= 4) 1 else blend.color_destination;
    const alpha_source = if (alpha_op >= 4) 1 else if (blend.separate_alpha) blend.alpha_source else blend.color_source;
    const alpha_dest = if (alpha_op >= 4) 1 else if (blend.separate_alpha) blend.alpha_destination else blend.color_destination;
    var result = State{
        .enabled = 1,
        .source_color = try factor(color_source, false),
        .destination_color = try factor(color_dest, false),
        .color_operation = color_op,
        .source_alpha = try factor(alpha_source, true),
        .destination_alpha = try factor(alpha_dest, true),
        .alpha_operation = alpha_op,
    };
    const color_constant = isColorConstant(color_source) or isColorConstant(color_dest);
    const alpha_in_rgb = isAlphaConstant(color_source) or isAlphaConstant(color_dest);
    const alpha_constant = alpha_in_rgb or isColorConstant(alpha_source) or isColorConstant(alpha_dest) or
        isAlphaConstant(alpha_source) or isAlphaConstant(alpha_dest);
    for (&result.constants, 0..) |*value, i| {
        if (if (i == 3) alpha_constant else color_constant) {
            value.* = @bitCast(state.readRegister(.context, 0x105 + @as(u32, @intCast(i))) orelse 0);
            if (!std.math.isFinite(value.*)) return error.NonFiniteBlendConstant;
            // The only supported attachment is UNORM, whose blend constants
            // are clamped to its representable range by the output merger.
            value.* = std.math.clamp(value.*, 0, 1);
        }
    }
    if (alpha_in_rgb and !color_constant) {
        // Older D3D12 runtimes have only one RGBA blend constant. Replicating A
        // into RGB is exact if no RGB constant is consumed. Mixed color/alpha
        // constants retain factors 20/21 and require OPTIONS13 at the boundary.
        for (result.constants[0..3]) |*value| value.* = result.constants[3];
        if (result.source_color == 20 or result.source_color == 21) result.source_color -= 6;
        if (result.destination_color == 20 or result.destination_color == 21) result.destination_color -= 6;
    }
    return result;
}

fn isColorConstant(f: u5) bool {
    return f == 13 or f == 14;
}
fn isAlphaConstant(f: u5) bool {
    return f == 19 or f == 20;
}
fn factor(f: u5, alpha: bool) !u32 {
    return switch (f) {
        0, 1 => @as(u32, f) + 1,
        2, 3 => if (alpha) @as(u32, f) + 3 else @as(u32, f) + 1,
        4...7 => @as(u32, f) + 1,
        8, 9 => if (alpha) @as(u32, f) - 1 else @as(u32, f) + 1,
        10 => if (alpha) 2 else 11,
        13, 14 => @as(u32, f) + 1,
        19, 20 => if (alpha) @as(u32, f) - 5 else @as(u32, f) + 1,
        15...18 => error.DualSourceBlendingNotImplemented,
        else => error.InvalidBlendFactor,
    };
}
fn operation(op: u3) !u32 {
    return switch (op) {
        0, 1 => @as(u32, op) + 1,
        2, 3 => @as(u32, op) + 2,
        4 => 3,
        else => error.InvalidBlendOperation,
    };
}

test "blend constants distinguish RGB from replicated alpha and ignore dormant state" {
    var state = gpu.State{};
    for ([_]f32{ 0.2, 0.4, 0.6, 0.8 }, 0..) |v, i| try state.writeRegister(.context, 0x105 + @as(u32, @intCast(i)), @bitCast(v));
    const alpha = try decode(&state, .{ .enabled = true, .color_source = 19, .color_destination = 20 });
    try std.testing.expectEqual(@as(u32, 14), alpha.source_color);
    try std.testing.expectEqualSlices(f32, &@as([4]f32, @splat(0.8)), &alpha.constants);
    const mixed = try decode(&state, .{ .enabled = true, .color_source = 13, .color_destination = 19 });
    try std.testing.expectEqual(@as(u32, 20), mixed.destination_color);
    try std.testing.expectEqualSlices(f32, &.{ 0.2, 0.4, 0.6, 0.8 }, &mixed.constants);
    try std.testing.expect(mixed.valid());
    try state.writeRegister(.context, 0x105, @bitCast(std.math.nan(f32)));
    try std.testing.expectError(error.NonFiniteBlendConstant, decode(&state, .{ .enabled = true, .color_source = 13 }));
    _ = try decode(&state, .{ .enabled = true, .color_source = 19 });
    _ = try decode(&state, .{ .enabled = true, .color_source = 31, .color_operation = 2, .color_destination = 15 });
    _ = try decode(&state, .{ .color_source = 31, .color_operation = 7 });
}

test "blend alpha factors obey scalar alpha semantics and reject unsupported state" {
    var state = gpu.State{};
    const saturate = try decode(&state, .{ .enabled = true, .color_source = 10, .color_destination = 8 });
    try std.testing.expectEqual(@as(u32, 2), saturate.source_alpha);
    try std.testing.expectEqual(@as(u32, 7), saturate.destination_alpha);
    try std.testing.expectError(error.DualSourceBlendingNotImplemented, decode(&state, .{ .enabled = true, .color_source = 15 }));
    try std.testing.expectError(error.InvalidBlendFactor, decode(&state, .{ .enabled = true, .color_source = 12 }));
    try std.testing.expectError(error.InvalidBlendOperation, decode(&state, .{ .enabled = true, .alpha_operation = 7, .separate_alpha = true }));
    try std.testing.expect(!(State{ .source_alpha = 3 }).valid());
    try std.testing.expect(!(State{ .source_color = 16 }).valid());
    try std.testing.expect(!(State{ .enabled = 2 }).valid());
}
