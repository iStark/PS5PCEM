// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Prove when a vector destination's old inactive-lane value cannot be read.
//! Ordinary vector consumers obey the same EXEC mask. Cross-lane consumers
//! and any possible EXEC expansion make the old value observable again.
const std = @import("std");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const control_flow = @import("control_flow.zig");
const relative_moves = @import("relative_vector_moves.zig");

const Mask = u256;
const State = struct { live: Mask = 0, observed: Mask = 0 };
const Effect = struct { reads: Mask = 0, cross: Mask = 0, changes_exec: bool = false };

fn tuple(op: operand.Operand) Mask {
    if (op.kind != .vgpr or op.reg >= 256) return 0;
    // Conservatively include wide operands, image coordinates and implicit
    // read/modify/write destinations. No kill sets rely on guessed widths.
    var result: Mask = 0;
    for (op.reg..@min(256, op.reg + 16)) |reg| result |= @as(Mask, 1) << @intCast(reg);
    return result;
}

fn execDestination(op: operand.Operand) bool {
    return op.kind == .exec_lo or op.kind == .exec_hi or
        (op.kind == .sgpr and op.reg >= 111 and op.reg <= 127);
}

fn describe(inst: instruction.Instruction) Effect {
    var result = Effect{};
    for ([_]operand.Operand{ inst.src0, inst.src1, inst.src2, inst.src3, inst.dst, inst.dst2 }) |op|
        result.reads |= tuple(op);
    if (inst.family == .mimg) for (inst.image_nsa_address) |reg| {
        result.reads |= tuple(.{ .kind = .vgpr, .reg = reg });
    };
    const name = @tagName(inst.opcode);
    // Treat exports as externally observable even when a host stage emits
    // outputs without a separate EXEC guard. Image derivatives also read
    // neighbouring/helper invocations, unlike lane-local vector arithmetic.
    if (inst.family == .mimg or inst.family == .ds or inst.family == .exp or
        inst.src0.dpp or inst.src1.dpp or inst.src2.dpp or inst.src3.dpp or
        std.mem.startsWith(u8, name, "v_read") or std.mem.startsWith(u8, name, "v_perm"))
        result.cross = result.reads;
    result.changes_exec = execDestination(inst.dst) or execDestination(inst.dst2) or
        std.mem.indexOf(u8, name, "exec") != null or std.mem.startsWith(u8, name, "v_cmpx_");
    return result;
}

fn transfer(effect: Effect, state: *State) void {
    if (effect.changes_exec) state.observed |= state.live;
    state.live |= effect.reads;
    state.observed |= effect.cross;
}

fn candidate(inst: instruction.Instruction) bool {
    return inst.dst.kind == .vgpr and inst.dst.reg < 256 and switch (inst.family) {
        .vop1, .vop2, .vop3, .vop3p, .vintrp => inst.opcode != .v_writelane_b32 and !relative_moves.destinationRelative(inst.opcode),
        else => false,
    };
}

/// Returns sorted PCs. Only the instruction's first explicit VGPR destination
/// may omit its EXEC select. The converged workgroup scheduler must still guard
/// idle waves independently; callers disable this optimization in that mode.
pub fn scanPcs(allocator: std.mem.Allocator, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) ![]u32 {
    for (instructions) |inst| {
        if (inst.opcode == .unknown or inst.opcode == .unsupported or inst.family == .unknown or
            inst.opcode == .s_setpc_b64 or inst.opcode == .s_call_b64 or inst.opcode == .s_swappc_b64)
            return allocator.alloc(u32, 0);
    }
    const effects = try allocator.alloc(Effect, instructions.len);
    defer allocator.free(effects);
    const relative_bounds = try relative_moves.analyze(allocator, instructions, graph);
    defer allocator.free(relative_bounds);
    for (instructions, effects) |inst, *effect| {
        effect.* = describe(inst);
        if (relative_moves.isRelative(inst.opcode)) effect.reads |= relative_moves.vectorMask(inst, relative_bounds);
    }
    const incoming = try allocator.alloc(State, graph.blocks.items.len);
    defer allocator.free(incoming);
    @memset(incoming, .{});
    var changed = true;
    while (changed) {
        changed = false;
        var cursor = graph.blocks.items.len;
        while (cursor != 0) {
            cursor -= 1;
            var state = State{};
            for (graph.edges.items) |edge| if (edge.from == cursor) {
                state.live |= incoming[edge.to].live;
                state.observed |= incoming[edge.to].observed;
            };
            const block = graph.blocks.items[cursor];
            var index = block.first_instruction + block.instruction_count;
            while (index > block.first_instruction) {
                index -= 1;
                transfer(effects[index], &state);
            }
            if (!std.meta.eql(state, incoming[cursor])) {
                incoming[cursor] = state;
                changed = true;
            }
        }
    }
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);
    for (graph.blocks.items) |block| {
        var state = State{};
        for (graph.edges.items) |edge| if (edge.from == block.index) {
            state.live |= incoming[edge.to].live;
            state.observed |= incoming[edge.to].observed;
        };
        var index = block.first_instruction + block.instruction_count;
        while (index > block.first_instruction) {
            index -= 1;
            const inst = instructions[index];
            if (candidate(inst) and state.observed & (@as(Mask, 1) << @intCast(inst.dst.reg)) == 0)
                try result.append(allocator, inst.pc);
            transfer(effects[index], &state);
        }
    }
    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(allocator);
}

test "inactive vector values remain guarded across EXEC expansion and cross-lane reads" {
    const a = std.testing.allocator;
    var code = [_]instruction.Instruction{
        .{ .pc = 0, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 32 } },
        .{ .pc = 4, .family = .sop1, .opcode = .s_nop },
        .{ .pc = 8, .family = .vop2, .opcode = .v_add_f32, .dst = .{ .kind = .vgpr, .reg = 64 }, .src0 = .{ .kind = .vgpr, .reg = 32 } },
        .{ .pc = 12, .family = .sopp, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(a, &code, false);
    defer graph.deinit(a);
    const local = try scanPcs(a, &code, &graph);
    defer a.free(local);
    try std.testing.expectEqualSlices(u32, &.{ 0, 8 }, local);
    code[1] = .{ .pc = 4, .family = .sop1, .opcode = .s_mov_b64, .dst = .{ .kind = .exec_lo } };
    const widened = try scanPcs(a, &code, &graph);
    defer a.free(widened);
    try std.testing.expectEqualSlices(u32, &.{8}, widened);
    code[1] = .{ .pc = 4, .family = .sop1, .opcode = .s_nop };
    code[2].src0.dpp = true;
    const shuffled = try scanPcs(a, &code, &graph);
    defer a.free(shuffled);
    try std.testing.expectEqualSlices(u32, &.{8}, shuffled);
    code[2].src0.dpp = false;
    code[2].opcode = .v_readlane_b32;
    code[2].dst.kind = .sgpr;
    const lane_read = try scanPcs(a, &code, &graph);
    defer a.free(lane_read);
    try std.testing.expectEqual(@as(usize, 0), lane_read.len);
}

test "inactive vector observation follows loop backedges and rejects indirect access" {
    const a = std.testing.allocator;
    var code = [_]instruction.Instruction{
        .{ .pc = 0, .family = .sop1, .opcode = .s_mov_b64, .dst = .{ .kind = .exec_lo } },
        .{ .pc = 4, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 64 }, .src0 = .{ .kind = .vgpr, .reg = 32 } },
        .{ .pc = 8, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 32 } },
        .{ .pc = 12, .family = .sopp, .opcode = .s_cbranch_scc0, .branch_target = 0 },
        .{ .pc = 16, .family = .sopp, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(a, &code, false);
    defer graph.deinit(a);
    const loop = try scanPcs(a, &code, &graph);
    defer a.free(loop);
    // No kill sets: even a destination is conservatively live on the backedge.
    try std.testing.expectEqual(@as(usize, 0), loop.len);
    code[0].opcode = .s_setpc_b64;
    const indirect = try scanPcs(a, &code, &graph);
    defer a.free(indirect);
    try std.testing.expectEqual(@as(usize, 0), indirect.len);
}

test "inactive values include relative reads after EXEC expansion" {
    const a = std.testing.allocator;
    const code = [_]instruction.Instruction{
        .{ .pc = 0, .family = .sop1, .opcode = .s_mov_b32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .integer_inline_constant, .value = 40 } },
        .{ .pc = 4, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 50 } },
        .{ .pc = 8, .family = .sop1, .opcode = .s_mov_b64, .dst = .{ .kind = .exec_lo } },
        .{ .pc = 12, .family = .vop1, .opcode = .v_movrels_b32, .dst = .{ .kind = .vgpr, .reg = 80 }, .src0 = .{ .kind = .vgpr, .reg = 10 } },
        .{ .pc = 16, .family = .vop1, .opcode = .v_movreld_b32, .dst = .{ .kind = .vgpr, .reg = 80 }, .src0 = .{ .kind = .vgpr, .reg = 1 } },
        .{ .pc = 20, .family = .sopp, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(a, &code, false);
    defer graph.deinit(a);
    const result = try scanPcs(a, &code, &graph);
    defer a.free(result);
    try std.testing.expectEqualSlices(u32, &.{12}, result);
}
