// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest graphics routing is selected by VGT_SHADER_STAGES_EN. Program addresses
//! can remain in disabled banks across draws; their presence is not an enable.
const std = @import("std");
const gpu = @import("gpu");

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
