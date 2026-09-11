// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Lower the merged LS/HS ABI to a compute workgroup. The guest stages retain
//! their instructions and share LDS; only hardware entry values and the
//! continuation between stages are supplied here.
const std = @import("std");
const rdna2 = @import("rdna2");
const analysis = @import("shader_analysis.zig");
const shaders = @import("shaders.zig");
const State = @import("state.zig").State;

pub const Config = struct {
    patches: u8,
    control_points: u8,
    factor_words: u8,
    inputs: rdna2.spirv.TessellationInputs,

    pub fn decode(state: *const State) !?Config {
        if ((state.readRegister(.uconfig, 0x242) orelse 0) != 9) return null;
        const layout = state.readRegister(.context, 0x2d6) orelse return error.MissingTessellationState;
        const mode = state.readRegister(.context, 0x2db) orelse return error.MissingTessellationState;
        const patches = layout & 255;
        const input = (layout >> 8) & 63;
        const output = (layout >> 14) & 63;
        // This ABI variant feeds one four-control-point patch per instance.
        // Other layouts need their own input assembly and LDS entry mapping.
        if (input != 4 or output != 4 or patches == 0 or patches > 64)
            return error.UnsupportedTessellationLayout;
        const domain = mode & 3;
        if (domain != 2) return error.UnsupportedTessellationDomain;
        const partition = (mode >> 2) & 7;
        const topology = (mode >> 5) & 7;
        if (partition == 1 or partition > 3 or topology < 2 or topology > 3) return error.UnsupportedTessellationMode;
        // The emulated GFX10 offchip ring uses 32 KiB workgroup slices when
        // the command stream inherits the kernel's ring configuration.
        if (state.readRegister(.uconfig, 0x24f)) |offchip| {
            if ((offchip >> 9) & 3 != 0) return error.UnsupportedTessellationOffchipSize;
        }
        return .{
            .patches = @intCast(patches),
            .control_points = 4,
            .factor_words = 6,
            .inputs = .{
                .domain = .quads,
                .spacing = switch (partition) {
                    0 => .equal,
                    3 => .fractional_even,
                    2 => .fractional_odd,
                    else => unreachable,
                },
                .order = if (topology == 2) .clockwise else .counter_clockwise,
                .coordinate_vgprs = .{ 5, 6 },
                .relative_patch_vgpr = 7,
                .patch_id_vgpr = 8,
                .patches_per_group = @intCast(patches),
                .offchip_offset_sgpr = 4,
                .offchip_group_bytes = 32768,
            },
        };
    }

    pub fn prepareState(self: Config, state: *State, first_instance: u32, instances: u32) !void {
        const ls_low = state.readRegister(.shader, 0x148) orelse return error.MissingLocalShader;
        const ls_high = state.readRegister(.shader, 0x149) orelse 0;
        var user: [16]u32 = @splat(0);
        user[0] = state.readRegister(.shader, 0x102) orelse return error.MissingHullShaderTable;
        user[1] = state.readRegister(.shader, 0x103) orelse return error.MissingHullShaderTable;
        for (0..6) |i| user[8 + i] = state.readRegister(.shader, @as(u32, @intCast(0x10c + i))) orelse return error.MissingLocalShaderUserData;
        user[14] = first_instance;
        user[15] = instances;
        for (user, 0..) |value, i| try state.writeRegister(.shader, @intCast(0x240 + i), value);
        try state.writeRegister(.shader, 0x20c, ls_low);
        try state.writeRegister(.shader, 0x20d, ls_high);
        // 16 user SGPRs, WGID_X in s16, 8 KiB LDS, local ID in v0.
        try state.writeRegister(.shader, 0x213, (16 << 1) | (1 << 7) | (16 << 15));
        try state.writeRegister(.shader, 0x207, self.localSize());
        try state.writeRegister(.shader, 0x208, 1);
        try state.writeRegister(.shader, 0x209, 1);
    }

    pub fn localSize(self: Config) u32 {
        return std.mem.alignForward(u32, @as(u32, self.patches) * self.control_points, 64);
    }
};

pub const Entry = struct {
    config: Config,
    local_words: []u32,
    hull_words: []u32,
    merged: analysis.Analysis,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.merged.deinit(allocator);
        allocator.free(self.local_words);
        allocator.free(self.hull_words);
    }

    pub fn matches(self: *const Entry, config: Config, local: *const analysis.Analysis, hull: *const analysis.Analysis) bool {
        return std.meta.eql(self.config, config) and std.mem.eql(u32, self.local_words, local.code.items) and std.mem.eql(u32, self.hull_words, hull.code.items);
    }

    pub fn init(allocator: std.mem.Allocator, config: Config, local: *const analysis.Analysis, hull: *const analysis.Analysis) !Entry {
        const local_end = for (local.program.instructions.items) |inst| {
            if (inst.opcode == .s_setpc_b64 and inst.src0.kind == .sgpr and inst.src0.reg == 6) break inst.pc / 4;
            // v127 is a lowering temporary. Conservatively reject high tuples
            // rather than aliasing a live local-shader register.
            for ([_]rdna2.Operand{ inst.dst, inst.src0, inst.src1, inst.src2, inst.src3 }) |operand| {
                if (operand.kind == .vgpr and operand.reg >= 112) return error.UnsupportedLocalShaderRegisters;
            }
            if (inst.dst.kind == .sgpr and inst.dst.reg < 8) return error.UnsupportedLocalShaderRegisters;
        } else return error.MissingLocalShaderContinuation;
        if (local_end == 0 or hull.program.instructions.items.len == 0) return error.EmptyTessellationProgram;
        for (local.program.instructions.items) |inst| {
            if (inst.pc >= local_end * 4) break;
            if (inst.opcode.isBranch() and inst.branch_target >= local_end * 4) return error.UnsupportedLocalShaderBranch;
        }
        // The merged HS starts from the hardware pointer in s0:s1 and loads
        // its four root-table words into s8:s11.
        var has_root = false;
        for (hull.program.instructions.items[0..@min(4, hull.program.instructions.items.len)]) |inst| {
            if (inst.opcode == .s_load_dwordx4 and inst.dst.reg == 8 and inst.src0.reg == 0 and inst.memory_offset == 0) has_root = true;
        }
        if (!has_root) return error.UnsupportedHullShaderEntry;
        var w = Words{ .allocator = allocator };
        defer w.code.deinit(allocator);
        try w.sop2(0x26, 17, 16, 128 + config.patches, null);
        try w.sop2(0x03, 18, 15, 17, null);
        try w.sop2(0x07, 18, 18, 128 + config.patches, null);
        try w.sop2(0x1e, 18, 18, 130, null);
        try w.vop1(0x02, 19, 256); // readfirstlane(local_id)
        try w.sop2(0x03, 19, 18, 19, null);
        try w.sop2(0x08, 19, 19, 128, null);
        try w.sop2(0x07, 19, 19, 192, null);
        try w.sop2(0x1e, 3, 19, 136, null);
        try w.sop2(0x10, 3, 3, 19, null);
        try w.sop2(0x1e, 2, 16, 143, null);
        try w.sop2(0x26, 4, 16, 255, @as(u32, config.patches) * config.factor_words * 4);
        try w.vop2(0x16, 5, 130, 0);
        try w.vop2(0x25, 5, 17, 5);
        try w.vop2(0x25, 5, 14, 5);
        try w.vop2(0x1b, 2, 131, 0);
        try w.vop1(0x01, 3, 256);
        try w.vop2(0x16, 1, 130, 0);
        try w.vop2(0x1a, 127, 136, 2);
        try w.vop2(0x1c, 127, 257, 127);
        try w.code.appendSlice(allocator, local.code.items[0..local_end]);
        try w.code.append(allocator, 0xbf8a0000); // all LS writes visible to HS
        try w.vop1(0x01, 1, 256 + 127);
        try w.code.appendSlice(allocator, hull.code.items);
        const reader = shaders.MemoryReader{ .context = &w, .read_fn = Words.read };
        var merged = try analysis.decodeBoundedWithOptions(allocator, reader, 0, w.code.items.len, w.code.items.len * 4, local.pipeline_options);
        errdefer merged.deinit(allocator);
        const local_words = try allocator.dupe(u32, local.code.items);
        errdefer allocator.free(local_words);
        const hull_words = try allocator.dupe(u32, hull.code.items);
        merged.enableScalarDefinitionCache(allocator) catch {};
        merged.enableResourceCheckpoints(allocator) catch {};
        merged.enableUniformSpecializations(allocator) catch {};
        merged.enableTranslationKey(allocator) catch {};
        return .{ .config = config, .local_words = local_words, .hull_words = hull_words, .merged = merged };
    }
};

const Words = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayList(u32) = .empty,
    fn sop2(self: *Words, op: u32, dst: u32, a: u32, b: u32, literal: ?u32) !void {
        try self.code.append(self.allocator, 0x80000000 | (op << 23) | (dst << 16) | (b << 8) | a);
        if (literal) |value| try self.code.append(self.allocator, value);
    }
    fn vop1(self: *Words, op: u32, dst: u32, src: u32) !void {
        try self.code.append(self.allocator, 0x7e000000 | (dst << 17) | (op << 9) | src);
    }
    fn vop2(self: *Words, op: u32, dst: u32, a: u32, b: u32) !void {
        try self.code.append(self.allocator, (op << 25) | (dst << 17) | (b << 9) | a);
    }
    fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self: *const Words = @ptrCast(@alignCast(context));
        const source = std.mem.sliceAsBytes(self.code.items);
        if (address > source.len or bytes.len > source.len - address) return false;
        @memcpy(bytes, source[@intCast(address)..][0..bytes.len]);
        return true;
    }
};

test "tessellation register decoding and compute entry preserve graphics state" {
    var state = State{};
    try std.testing.expectEqual(null, try Config.decode(&state));
    try state.writeRegister(.uconfig, 0x242, 9);
    try state.writeRegister(.context, 0x2d6, 0x1043f);
    try state.writeRegister(.context, 0x2db, 0x4006a);
    const config = (try Config.decode(&state)).?;
    try std.testing.expectEqual(.fractional_odd, config.inputs.spacing);
    try std.testing.expectEqual(.counter_clockwise, config.inputs.order);
    try std.testing.expectEqual(63, config.patches);
    try std.testing.expectEqual(256, config.localSize());
    try state.writeRegister(.context, 0x2db, 0x4e); // fractional even, CW
    const even = (try Config.decode(&state)).?;
    try std.testing.expectEqual(.fractional_even, even.inputs.spacing);
    try std.testing.expectEqual(.clockwise, even.inputs.order);
    try state.writeRegister(.context, 0x2db, 0x46); // unsupported power-of-two partition
    try std.testing.expectError(error.UnsupportedTessellationMode, Config.decode(&state));
    try state.writeRegister(.context, 0x2db, 0x4006a);
    try state.writeRegister(.uconfig, 0x24f, 1 << 9);
    try std.testing.expectError(error.UnsupportedTessellationOffchipSize, Config.decode(&state));
    try state.writeRegister(.uconfig, 0x24f, 0);
    try state.writeRegister(.shader, 0x148, 0x1234);
    try state.writeRegister(.shader, 0x102, 0x1000);
    try state.writeRegister(.shader, 0x103, 0x20);
    for (0..6) |i| try state.writeRegister(.shader, @intCast(0x10c + i), @intCast(100 + i));
    var compute = state;
    try config.prepareState(&compute, 17, 64);
    try std.testing.expectEqual(17, compute.readRegister(.shader, 0x24e).?);
    try std.testing.expectEqual(64, compute.readRegister(.shader, 0x24f).?);
    try std.testing.expectEqual(100, compute.readRegister(.shader, 0x248).?);
    try std.testing.expectEqual(105, compute.readRegister(.shader, 0x24d).?);
    try std.testing.expectEqual(null, state.readRegister(.shader, 0x240));
    try std.testing.expectEqualDeep(state.context, compute.context);
    try std.testing.expectEqualDeep(state.uconfig, compute.uconfig);
}
