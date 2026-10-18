// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest graphics routing is selected by VGT_SHADER_STAGES_EN. Program addresses
//! can remain in disabled banks across draws; their presence is not an enable.
const std = @import("std");
const gpu = @import("gpu");
const rdna2 = @import("rdna2");

pub const Routing = struct {
    stage: gpu.resources.ShaderStage,
    vertex_wave32: bool,
    fragment_wave32: bool,
};

pub const Interface = struct {
    mask: u32 = 0,
    controls: [32]u32 = undefined,
    locations: [32]u8 = undefined,
};

/// Guest DI_PT values are not D3D_PRIMITIVE_TOPOLOGY values. In particular,
/// guest 5 is a fan and guest 6 is a strip; D3D12 uses 5 for a strip.
pub fn nativeTopology(guest: u32) !u32 {
    return switch (guest) {
        4, 5 => 4, // List, or fan expanded to a list before submission.
        6 => 5, // DI_PT_TRISTRIP -> D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP
        else => error.UnsupportedPrimitive,
    };
}

test "guest primitive numbers map explicitly and fans never masquerade as strips" {
    try std.testing.expectEqual(@as(u32, 4), try nativeTopology(4));
    try std.testing.expectEqual(@as(u32, 5), try nativeTopology(6));
    try std.testing.expectEqual(@as(u32, 4), try nativeTopology(5));
    try std.testing.expectError(error.UnsupportedPrimitive, nativeTopology(7));
}

/// Fan triangles share the first index. Cyclic rotation preserves winding and
/// makes the guest provoking vertex the first D3D12 list vertex: the previous
/// rim vertex for FIRST, the current rim vertex for LAST (PA_SU_SC_MODE_CNTL).
pub const TriangleFan = struct {
    count: u32,
    indices: []const u8 = &.{},
    element_bytes: u32 = 0,
    first_vertex: u32 = 0,
    base_vertex: i32 = 0,
    restart: ?u32 = null,
    provoking_last: bool = false,

    pub fn expand(self: TriangleFan, allocator: std.mem.Allocator) ![]u8 {
        if (self.element_bytes != 0 and self.element_bytes != 1 and self.element_bytes != 2 and self.element_bytes != 4)
            return error.UnsupportedIndexType;
        if (@as(u64, self.count) * self.element_bytes != self.indices.len) return error.InvalidFanIndices;
        const max_bytes = @as(u64, self.count -| 2) * 12;
        if (max_bytes > 64 * 1024 * 1024) return error.IndexBufferTooLarge;
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, @intCast(max_bytes));
        var anchor: ?u32 = null;
        var previous: ?u32 = null;
        for (0..self.count) |i| {
            const index = switch (self.element_bytes) {
                0 => try std.math.add(u32, self.first_vertex, @intCast(i)),
                1 => @as(u32, self.indices[i]),
                2 => @as(u32, std.mem.readInt(u16, self.indices[i * 2 ..][0..2], .little)),
                4 => std.mem.readInt(u32, self.indices[i * 4 ..][0..4], .little),
                else => unreachable,
            };
            // Auto-index draws ignore primitive restart. Indexed markers are
            // recognized before base-vertex arithmetic, including custom cuts.
            if (self.element_bytes != 0 and self.restart != null and index == self.restart.?) {
                anchor = null;
                previous = null;
                continue;
            }
            const vertex = @as(i64, index) + self.base_vertex;
            if (vertex < 0 or vertex > std.math.maxInt(u32)) return error.InvalidBaseVertex;
            if (anchor == null) {
                anchor = index;
            } else if (previous) |rim| {
                const triangle: [3]u32 = if (self.provoking_last) .{ index, anchor.?, rim } else .{ rim, index, anchor.? };
                for (triangle) |value| {
                    const start = result.items.len;
                    result.items.len += 4;
                    std.mem.writeInt(u32, result.items[start..][0..4], value, .little);
                }
                previous = index;
            } else previous = index;
        }
        return result.toOwnedSlice(allocator);
    }
};

test "fan expansion preserves rim provoking vertices and independent restart segments" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |last| {
        const fan = TriangleFan{ .count = 5, .first_vertex = 7, .provoking_last = last };
        const result = try fan.expand(allocator);
        defer allocator.free(result);
        const expected: [9]u32 = if (last) .{ 9, 7, 8, 10, 7, 9, 11, 7, 10 } else .{ 8, 9, 7, 9, 10, 7, 10, 11, 7 };
        for (expected, 0..) |value, i| try std.testing.expectEqual(value, std.mem.readInt(u32, result[i * 4 ..][0..4], .little));
    }
    // Leading, trailing and adjacent cuts; short segments never join neighbors.
    const source = [_]u8{ 99, 8, 99, 9, 10, 99, 99, 7, 8, 9, 10, 99, 11, 12, 13, 99 };
    for ([_]u32{ 1, 2, 4 }) |width| {
        var encoded: [source.len * 4]u8 = @splat(0);
        for (source, 0..) |value, i| switch (width) {
            1 => encoded[i] = value,
            2 => std.mem.writeInt(u16, encoded[i * 2 ..][0..2], value, .little),
            else => std.mem.writeInt(u32, encoded[i * 4 ..][0..4], value, .little),
        };
        const result = try (TriangleFan{ .count = source.len, .indices = encoded[0 .. source.len * width], .element_bytes = width, .restart = 99, .base_vertex = -7 }).expand(allocator);
        defer allocator.free(result);
        const expected = [_]u32{ 8, 9, 7, 9, 10, 7, 12, 13, 11 };
        try std.testing.expectEqual(expected.len * 4, result.len);
        for (expected, 0..) |value, i| try std.testing.expectEqual(value, std.mem.readInt(u32, result[i * 4 ..][0..4], .little));
    }
}

test "fan expansion bounds short fans and does not confuse disabled restart with indices" {
    const allocator = std.testing.allocator;
    for (0..3) |count| {
        const result = try (TriangleFan{ .count = @intCast(count) }).expand(allocator);
        defer allocator.free(result);
        try std.testing.expectEqual(@as(usize, 0), result.len);
    }
    const result = try (TriangleFan{ .count = 3, .indices = &.{ 255, 1, 2 }, .element_bytes = 1 }).expand(allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(u32, 255), std.mem.readInt(u32, result[8..12], .little));
    try std.testing.expectError(error.InvalidFanIndices, (TriangleFan{ .count = 4, .indices = &.{ 0, 1, 2 }, .element_bytes = 1 }).expand(allocator));
    try std.testing.expectError(error.IndexBufferTooLarge, (TriangleFan{ .count = std.math.maxInt(u32) }).expand(allocator));
    try std.testing.expectError(error.Overflow, (TriangleFan{ .count = 3, .first_vertex = std.math.maxInt(u32) }).expand(allocator));
    try std.testing.expectError(error.InvalidBaseVertex, (TriangleFan{ .count = 3, .indices = &.{ 0, 1, 2 }, .element_bytes = 1, .base_vertex = -1 }).expand(allocator));
    try std.testing.expectError(error.InvalidBaseVertex, (TriangleFan{ .count = 1, .first_vertex = std.math.maxInt(u32), .base_vertex = 1 }).expand(allocator));
}

/// Depth is observed by depth testing/writes or a pixel position-Z input.
/// Replacing an unobserved depth mapping preserves clipping (performed before
/// the viewport), coverage, perspective interpolation and all color outputs.
pub fn viewportDepthRange(minimum: f32, maximum: f32, depth_observed: bool) ![2]f32 {
    if (!std.math.isFinite(minimum) or !std.math.isFinite(maximum)) return error.InvalidViewportDepth;
    if (minimum >= 0 and maximum <= 1 and minimum <= maximum) return .{ minimum, maximum };
    if (depth_observed) return error.UnrestrictedViewportDepthNotImplemented;
    return .{ 0, 1 };
}

pub const ViewportDepth = struct {
    range: [2]f32,
    transform: ?rdna2.spirv.VertexDepthTransform = null,
};

/// PA_SC_VPORT_ZMIN/MAX clamp per-pixel depth independently of PA_CL_VPORT_Z
/// scale/offset. With an explicit 0..1 clamp we can apply Z in the VS, retain
/// the original homogeneous planes as ClipDistance, and let D3D12 clamp after
/// interpolation. Rebasing Z into 0.5..1 instead would lose small D32 values.
pub fn viewportDepth(state: *const gpu.State, vp: gpu.resources.ViewportTransform, zero_to_one: bool, depth_test: bool, position_z: bool) !ViewportDepth {
    const minimum = if (zero_to_one) vp.z_offset else vp.z_offset - vp.z_scale;
    const maximum = vp.z_offset + vp.z_scale;
    const range = viewportDepthRange(minimum, maximum, depth_test or position_z) catch |err| {
        if (err != error.UnrestrictedViewportDepthNotImplemented) return err;
        const clamp_min: f32 = @bitCast(state.readRegister(.context, 0x0b4) orelse return err);
        const clamp_max: f32 = @bitCast(state.readRegister(.context, 0x0b5) orelse return err);
        const clip = state.readRegister(.context, 0x204) orelse 0;
        const vte = state.readRegister(.context, 0x206) orelse 0x43f;
        // User planes, disabled clipping/near/far, and nonstandard vertex
        // formats require separate lowering. Position-Z input is unproven.
        if (position_z or clamp_min != 0 or clamp_max != 1 or
            clip & 0x1c01003f != 0 or vte != 0x43f) return err;
        return .{ .range = .{ 0, 1 }, .transform = .{
            .scale = vp.z_scale,
            .offset = vp.z_offset,
            .negative_one_to_one = !zero_to_one,
        } };
    };
    return .{ .range = range };
}

test "explicit unit depth clamp preserves unrestricted viewport without inventing defaults" {
    var state: gpu.State = .{};
    const vp: gpu.resources.ViewportTransform = .{ .x_scale = 1, .x_offset = 1, .y_scale = -1, .y_offset = 1, .z_scale = 1, .z_offset = 0 };
    try std.testing.expectError(error.UnrestrictedViewportDepthNotImplemented, viewportDepth(&state, vp, false, true, false));
    try state.writeRegister(.context, 0xb4, 0);
    try state.writeRegister(.context, 0xb5, @bitCast(@as(f32, 1)));
    const plan = try viewportDepth(&state, vp, false, true, false);
    try std.testing.expectEqual([2]f32{ 0, 1 }, plan.range);
    try std.testing.expectEqual(rdna2.spirv.VertexDepthTransform{ .scale = 1, .offset = 0, .negative_one_to_one = true }, plan.transform.?);
    try std.testing.expect((try viewportDepth(&state, vp, true, true, false)).transform == null);
    try std.testing.expect((try viewportDepth(&state, vp, false, false, false)).transform == null);
    try std.testing.expectError(error.UnrestrictedViewportDepthNotImplemented, viewportDepth(&state, vp, false, true, true));
    try state.writeRegister(.context, 0xb5, 0);
    try std.testing.expectError(error.UnrestrictedViewportDepthNotImplemented, viewportDepth(&state, vp, false, true, false));
    try state.writeRegister(.context, 0xb5, @bitCast(@as(f32, 1)));
    for ([_]u32{ 1, 1 << 16, 1 << 26, 1 << 27, 1 << 28 }) |clip| {
        try state.writeRegister(.context, 0x204, clip);
        try std.testing.expectError(error.UnrestrictedViewportDepthNotImplemented, viewportDepth(&state, vp, false, true, false));
    }
    try state.writeRegister(.context, 0x204, 0);
    try state.writeRegister(.context, 0x206, 0x42f);
    try std.testing.expectError(error.UnrestrictedViewportDepthNotImplemented, viewportDepth(&state, vp, false, true, false));
}

test "only unobserved viewport depth can be normalized into the native range" {
    try std.testing.expectEqual([2]f32{ 0.25, 0.75 }, try viewportDepthRange(0.25, 0.75, true));
    try std.testing.expectEqual([2]f32{ 0, 1 }, try viewportDepthRange(-1, 1, false));
    try std.testing.expectEqual([2]f32{ 0, 1 }, try viewportDepthRange(1, 0, false));
    try std.testing.expectError(error.UnrestrictedViewportDepthNotImplemented, viewportDepthRange(-1, 1, true));
    try std.testing.expectError(error.UnrestrictedViewportDepthNotImplemented, viewportDepthRange(1, 0, true));
    try std.testing.expectError(error.InvalidViewportDepth, viewportDepthRange(std.math.nan(f32), 1, false));
}

pub fn linkInterface(state: *const gpu.State, vertex: []const gpu.ShaderInstruction, fragment: []const gpu.ShaderInstruction) !Interface {
    const outputs = gpu.resource_checkpoints.graphicsInterface(vertex, null);
    const inputs = gpu.resource_checkpoints.graphicsInterface(fragment, null);
    var result = Interface{ .mask = inputs.attributes };
    for (&result.controls, &result.locations, 0..) |*control, *location, i| {
        location.* = @intCast(i);
        control.* = state.readRegister(.context, 0x191 + @as(u32, @intCast(i))) orelse @as(u32, @intCast(i));
        if (inputs.attributes & (@as(u32, 1) << @intCast(i)) == 0) continue;
        // Smooth PARAM interpolation is provided by the native rasterizer.
        // Default constants, flat/custom and point-sprite inputs need their
        // own lowering; do not silently replace them with screen-space UVs.
        if (control.* & ~@as(u32, 0x1f) != 0) return error.FragmentInterpolationModeNotImplemented;
        if (outputs.parameters & (@as(u32, 1) << @intCast(control.*)) == 0) return error.MissingVertexParameterExport;
    }
    for (fragment) |inst| if (inst.opcode == .v_interp_mov_f32) return error.FragmentPerVertexInterpolationNotImplemented;
    return result;
}

pub fn routing(state: *const gpu.State) !Routing {
    const enables = state.readRegister(.context, 0x2d5) orelse 0;
    const ls = enables & 3;
    const es = (enables >> 3) & 3;
    const vs = (enables >> 6) & 3;
    if (enables & 0xfc000000 != 0 or ls == 3 or es == 3 or vs == 3) return error.InvalidGraphicsStageRouting;
    if (enables & 4 != 0 or ls != 0 or vs == 1 or (state.readRegister(.uconfig, 0x242) orelse 4) == 9)
        return error.TessellationStagesNotImplemented;
    if (enables & 0x20 != 0 or vs == 2) return error.GeometryAmplificationNotImplemented;
    const merged = enables & 0x2000 != 0;
    if (merged) {
        // ES routing, wave size, maximum primitive groups and passthrough are
        // compatible with one translated vertex invocation per guest vertex.
        // The observed passthrough ES=DS alias has no enabled tessellation stage.
        if ((enables & ~@as(u32, 0x0247a010)) != 0 and enables != 0x02002008)
            return error.UnsupportedNggStageRouting;
        if (enables & 0x02000000 == 0) return error.NggCullingNotImplemented;
    } else if (es != 0 or enables & 0x02000000 != 0) return error.UnsupportedLegacyStageRouting;
    const stage: gpu.resources.ShaderStage = if (merged) .export_shader else .vertex;
    if (stage.programAddress(state) == null) return error.MissingVertexProgram;
    return .{
        .stage = stage,
        .vertex_wave32 = enables & (if (merged) @as(u32, 1 << 22) else @as(u32, 1 << 23)) != 0,
        .fragment_wave32 = (state.readRegister(.context, 0x1b6) orelse 0) & 0x8000 != 0,
    };
}

test "active routing wins over stale shader banks and carries wave size" {
    var state: gpu.State = .{};
    for ([_]gpu.resources.ShaderStage{ .vertex, .geometry, .export_shader, .hull }) |stage| {
        try state.writeRegister(.shader, stage.programRegisterBase(), 2);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    }
    try std.testing.expectEqual(gpu.resources.ShaderStage.vertex, (try routing(&state)).stage);
    for ([_]u32{ 0x02002000, 0x02002010, 0x02002008 }) |enables| {
        try state.writeRegister(.context, 0x2d5, enables);
        try std.testing.expectEqual(gpu.resources.ShaderStage.export_shader, (try routing(&state)).stage);
    }
    try state.writeRegister(.context, 0x2d5, 0x02402010);
    try state.writeRegister(.context, 0x1b6, 0x8000);
    const merged = try routing(&state);
    try std.testing.expect(merged.vertex_wave32 and merged.fragment_wave32);
    try state.writeRegister(.context, 0x2d5, 1 << 23);
    const legacy = try routing(&state);
    try std.testing.expect(legacy.vertex_wave32 and legacy.stage == .vertex);
    // PRIMGEN must not fall back to a still-populated legacy VS bank.
    try state.writeRegister(.shader, 0x0c8, 0);
    try state.writeRegister(.context, 0x2d5, 0x02002000);
    try std.testing.expectError(error.MissingVertexProgram, routing(&state));
}

test "real geometry, tessellation and reserved routing remain explicit failures" {
    var state: gpu.State = .{};
    for ([_]u32{ 0x2003, 0x2018, 0x20c0, 0x80002000 }) |enables| {
        try state.writeRegister(.context, 0x2d5, enables);
        try std.testing.expectError(error.InvalidGraphicsStageRouting, routing(&state));
    }
    try state.writeRegister(.context, 0x2d5, 0x2020);
    try std.testing.expectError(error.GeometryAmplificationNotImplemented, routing(&state));
    try state.writeRegister(.context, 0x2d5, 0x0200210d);
    try std.testing.expectError(error.TessellationStagesNotImplemented, routing(&state));
    try state.writeRegister(.context, 0x2d5, 0x2008);
    try std.testing.expectError(error.UnsupportedNggStageRouting, routing(&state));
    try state.writeRegister(.context, 0x2d5, 0x2000);
    try std.testing.expectError(error.NggCullingNotImplemented, routing(&state));
}

test "fragment interface rejects absent exports and unsupported interpolation instead of synthesizing inputs" {
    var state: gpu.State = .{};
    const vertex = [_]gpu.ShaderInstruction{.{ .opcode = .exp, .export_target = 0x23, .export_enable = 15 }};
    const fragment = [_]gpu.ShaderInstruction{.{
        .opcode = .v_interp_p2_f32,
        .src1 = .{ .kind = .integer_inline_constant, .value = 0 },
        .src2 = .{ .kind = .integer_inline_constant, .value = 0 },
    }};
    try std.testing.expectError(error.MissingVertexParameterExport, linkInterface(&state, &vertex, &fragment));
    try state.writeRegister(.context, 0x191, 3);
    try std.testing.expectEqual(@as(u32, 1), (try linkInterface(&state, &vertex, &fragment)).mask);
    try state.writeRegister(.context, 0x191, 0x403);
    try std.testing.expectError(error.FragmentInterpolationModeNotImplemented, linkInterface(&state, &vertex, &fragment));
}
