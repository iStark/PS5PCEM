// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Conservative bounds for scalar table indices guarded by unsigned branches.
const std = @import("std");
const rdna2 = @import("rdna2");
const Instruction = rdna2.Instruction;
const Graph = rdna2.control_flow.Graph;
const maximum_blocks = 1024;

const Location = struct { register: u32, lane: ?u32 = null };
const Definition = struct { instruction: usize, component: u32 };

fn immediate(op: rdna2.Operand) ?u32 {
    return switch (op.kind) {
        .integer_inline_constant, .literal_constant => op.value,
        else => null,
    };
}

fn blockAt(graph: *const Graph, index: usize) ?u32 {
    for (graph.blocks.items) |block| {
        if (index >= block.first_instruction and index < block.first_instruction + block.instruction_count) return block.index;
    }
    return null;
}

fn writes(inst: Instruction, location: Location) bool {
    if (inst.opcode == .unknown) return true;
    const kind: rdna2.OperandKind = if (location.lane != null) .vgpr else .sgpr;
    if (location.lane) |lane| {
        if (inst.opcode == .v_writelane_b32 and inst.dst.kind == .vgpr and inst.dst.reg == location.register) {
            return if (lane == std.math.maxInt(u32)) true else if (immediate(inst.src1)) |written| written == lane else true;
        }
    }
    // Memory and 64-bit ALU destinations can span several registers. DS
    // pairs are deliberately overestimated when their exact width is absent.
    const width = @max(inst.data_words, if (inst.family == .ds) @as(u8, 4) else if (std.mem.endsWith(u8, @tagName(inst.opcode), "64")) @as(u8, 2) else 1);
    for ([_]rdna2.Operand{ inst.dst, inst.dst2 }) |dst| {
        const register: ?usize = if (kind == .sgpr) @import("scalar_provenance.zig").scalarRegisterIndex(dst) else if (dst.kind == kind) @as(usize, dst.reg) else null;
        if (register) |first| if (location.register >= first and location.register - first < width) return true;
    }
    return false;
}

/// Require the same reaching definition on every predecessor, including loop
/// back edges. A lexical last-write search can incorrectly trust a skipped
/// assignment or a register changed on a previous loop iteration.
const ReachingDefinitions = struct { items: [32]usize = undefined, count: usize = 0 };

fn reachingDefinitions(instructions: []const Instruction, graph: *const Graph, before: usize, location: Location) ?ReachingDefinitions {
    if (graph.blocks.items.len > maximum_blocks) return null;
    const first_block = blockAt(graph, before) orelse return null;
    var visited: [maximum_blocks]bool = @splat(false);
    var queue: [maximum_blocks]u32 = undefined;
    var count: usize = 0;
    var cursor: usize = 0;
    var result = ReachingDefinitions{};
    var block_index = first_block;
    var end = before;
    while (true) {
        const block = graph.blocks.items[block_index];
        var found = false;
        while (end > block.first_instruction) {
            end -= 1;
            if (!writes(instructions[end], location)) continue;
            if (std.mem.indexOfScalar(usize, result.items[0..result.count], end) == null) {
                if (result.count == result.items.len) return null;
                result.items[result.count] = end;
                result.count += 1;
            }
            found = true;
            break;
        }
        if (!found) {
            if (block_index == 0) return null;
            var has_predecessor = false;
            for (graph.edges.items) |edge| {
                if (edge.to != block_index) continue;
                has_predecessor = true;
                if (visited[edge.from]) continue;
                visited[edge.from] = true;
                queue[count] = edge.from;
                count += 1;
            }
            if (!has_predecessor) return null;
        }
        if (cursor == count) break;
        block_index = queue[cursor];
        cursor += 1;
        const next = graph.blocks.items[block_index];
        end = next.first_instruction + next.instruction_count;
    }
    return result;
}

fn reachingDefinition(instructions: []const Instruction, graph: *const Graph, before: usize, location: Location) ?usize {
    const definitions = reachingDefinitions(instructions, graph, before, location) orelse return null;
    return if (definitions.count == 1) definitions.items[0] else null;
}

const MaskProof = struct {
    visited: [32]usize = undefined,
    count: usize = 0,
    has_origin: bool = false,
};

// A waterfall loop saves EXEC after computing its vector index, then removes
// processed lanes with ANDN2. Every selected lane remains inside that original
// execution mask. Reject OR/restores, unknown entry values and other writers.
fn maskIsSubsetOfVectorWrite(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32, vector_write: usize, proof: *MaskProof) bool {
    for (0..2) |half| {
        const definitions = reachingDefinitions(instructions, graph, before, .{ .register = register + @as(u32, @intCast(half)) }) orelse return false;
        for (definitions.items[0..definitions.count]) |index| {
            if (std.mem.indexOfScalar(usize, proof.visited[0..proof.count], index) != null) continue;
            if (proof.count == proof.visited.len) return false;
            proof.visited[proof.count] = index;
            proof.count += 1;
            const inst = instructions[index];
            if (inst.dst.kind != .sgpr or inst.dst.reg != register) return false;
            if (inst.opcode == .s_mov_b64 and inst.src0.kind == .exec_lo) {
                if (index <= vector_write or blockAt(graph, index) != blockAt(graph, vector_write)) return false;
                for (instructions[vector_write + 1 .. index]) |between| {
                    if (between.dst.kind == .exec_lo or between.dst.kind == .exec_hi or
                        between.dst2.kind == .exec_lo or between.dst2.kind == .exec_hi or
                        std.mem.indexOf(u8, @tagName(between.opcode), "exec") != null) return false;
                }
                proof.has_origin = true;
            } else if ((inst.opcode == .s_mov_b64 or inst.opcode == .s_andn2_b64 or inst.opcode == .s_and_b64) and inst.src0.kind == .sgpr) {
                if (!maskIsSubsetOfVectorWrite(instructions, graph, index, inst.src0.reg, vector_write, proof)) return false;
            } else return false;
        }
    }
    return true;
}

fn scalarBitUpperBound(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32, depth: u32) ?u32 {
    if (depth == 16) return null;
    const index = reachingDefinition(instructions, graph, before, .{ .register = register }) orelse return null;
    const inst = instructions[index];
    if (inst.opcode == .s_mov_b32 and inst.src0.kind == .sgpr) return scalarBitUpperBound(instructions, graph, index, inst.src0.reg, depth + 1);
    if (inst.opcode != .v_readlane_b32 or inst.src0.kind != .vgpr) return null;
    const lane_register = @import("scalar_provenance.zig").scalarRegisterIndex(inst.src1) orelse return null;
    const lane_index = reachingDefinition(instructions, graph, index, .{ .register = @intCast(lane_register) }) orelse return null;
    const lane = instructions[lane_index];
    if (lane.opcode != .s_ff1_i32_b64 or lane.src0.kind != .sgpr) return null;
    // Check all writes to this VGPR, since the lane is chosen dynamically.
    const vector_index = reachingDefinition(instructions, graph, index, .{ .register = inst.src0.reg, .lane = std.math.maxInt(u32) }) orelse return null;
    const vector = instructions[vector_index];
    if (vector.dst.kind != .vgpr or vector.dst.reg != inst.src0.reg or vector.opcode != .v_lshrrev_b32 or
        vector.dst.sdwa_sel != 6 or vector.src1.sdwa_sel != 6 or vector.src1.dpp) return null;
    const shift = (immediate(vector.src0) orelse return null) & 31;
    if (shift == 0) return null;
    var proof = MaskProof{};
    if (!maskIsSubsetOfVectorWrite(instructions, graph, lane_index, lane.src0.reg, vector_index, &proof) or !proof.has_origin) return null;
    return @as(u32, 1) << @intCast(32 - shift);
}

fn scalarIdentity(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32, depth: u32) ?Definition {
    if (depth == 16) return null;
    const index = reachingDefinition(instructions, graph, before, .{ .register = register }) orelse return null;
    const inst = instructions[index];
    if (inst.opcode == .s_mov_b32 and inst.src0.kind == .sgpr) {
        return scalarIdentity(instructions, graph, index, inst.src0.reg, depth + 1);
    }
    if (inst.opcode == .v_readlane_b32 and inst.src0.kind == .vgpr) {
        const lane = immediate(inst.src1) orelse return null;
        const store_index = reachingDefinition(instructions, graph, index, .{ .register = inst.src0.reg, .lane = lane }) orelse return null;
        const store = instructions[store_index];
        if (store.opcode == .v_writelane_b32 and immediate(store.src1) == lane and store.src0.kind == .sgpr) {
            return scalarIdentity(instructions, graph, store_index, store.src0.reg, depth + 1);
        }
    }
    if (inst.opcode == .unknown or inst.dst.kind != .sgpr or register < inst.dst.reg) return null;
    return .{ .instruction = index, .component = register - inst.dst.reg };
}

fn requiresFallthrough(graph: *const Graph, definition: usize, use: usize, guard: u32) bool {
    if (graph.blocks.items.len > maximum_blocks) return false;
    const start = blockAt(graph, definition) orelse return false;
    const target = blockAt(graph, use) orelse return false;
    var visited: [maximum_blocks]bool = @splat(false);
    var queue: [maximum_blocks]u32 = undefined;
    queue[0] = start;
    visited[start] = true;
    var count: usize = 1;
    var cursor: usize = 0;
    while (cursor < count) : (cursor += 1) {
        const block = queue[cursor];
        if (block == target) return false;
        for (graph.edges.items) |edge| {
            if (edge.from != block or (edge.from == guard and edge.kind == .fallthrough) or visited[edge.to]) continue;
            visited[edge.to] = true;
            queue[count] = edge.to;
            count += 1;
        }
    }
    return true;
}

/// Exclusive upper bound at `use`, or null when not proven. In particular,
/// preserve full 32-bit wrap semantics unless a guard excludes large indices.
pub fn scalarUpperBound(instructions: []const Instruction, graph: *const Graph, use: usize, register: u32) ?u32 {
    var result = scalarBitUpperBound(instructions, graph, use, register, 0);
    const value = scalarIdentity(instructions, graph, use, register, 0) orelse return result;
    for (graph.blocks.items) |block| {
        if (block.instruction_count < 2) continue;
        const branch_index = block.first_instruction + block.instruction_count - 1;
        if (branch_index >= use or branch_index <= value.instruction) continue;
        const branch = instructions[branch_index];
        const compare = instructions[branch_index - 1];
        if (branch.opcode != .s_cbranch_scc1 or compare.opcode != .s_cmp_ge_u32 or compare.src0.kind != .sgpr) continue;
        const bound = immediate(compare.src1) orelse continue;
        const compared = scalarIdentity(instructions, graph, branch_index - 1, compare.src0.reg, 0) orelse continue;
        if (!std.meta.eql(value, compared) or !requiresFallthrough(graph, value.instruction, use, block.index)) continue;
        result = @min(result orelse std.math.maxInt(u32), bound);
    }
    return result;
}

test "waterfall lane indices retain the vector shift bound" {
    const s2 = rdna2.Operand{ .kind = .sgpr, .reg = 2 };
    const s70 = rdna2.Operand{ .kind = .sgpr, .reg = 70 };
    const v12 = rdna2.Operand{ .kind = .vgpr, .reg = 12 };
    const exec = rdna2.Operand{ .kind = .exec_lo };
    const vcc = rdna2.Operand{ .kind = .vcc_lo };
    var instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .v_lshrrev_b32, .dst = v12, .src0 = .{ .kind = .integer_inline_constant, .value = 16 }, .src1 = .{ .kind = .vgpr, .reg = 1 } },
        .{ .pc = 4, .opcode = .s_nop },
        .{ .pc = 8, .opcode = .s_mov_b64, .dst = s2, .src0 = exec },
        .{ .pc = 12, .opcode = .s_ff1_i32_b64, .dst = vcc, .src0 = s2 },
        .{ .pc = 16, .opcode = .v_readlane_b32, .dst = s70, .src0 = v12, .src1 = vcc },
        .{ .pc = 20, .opcode = .s_mul_i32, .dst = .{ .kind = .vcc_hi }, .src0 = s70, .src1 = .{ .kind = .literal_constant, .value = 592 } },
        .{ .pc = 24, .opcode = .s_andn2_b64, .dst = s2, .src0 = s2, .src1 = .{ .kind = .sgpr, .reg = 60 } },
        .{ .pc = 28, .opcode = .s_cbranch_scc1, .branch_target = 12 },
        .{ .pc = 32, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 65536), scalarUpperBound(&instructions, &graph, 5, 70));
    instructions[6].opcode = .s_or_b64; // can introduce lanes which never received the shift
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 5, 70));
    instructions[6].opcode = .s_andn2_b64;
    instructions[1] = .{ .pc = 4, .opcode = .s_mov_b64, .dst = exec, .src0 = s70 };
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 5, 70));
    instructions[1] = .{ .pc = 4, .opcode = .s_nop };
    instructions[6] = .{ .pc = 24, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 3 }, .src0 = s70 };
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 5, 70));
}

test "unsigned index bound follows a scalar spill through a guarded loop" {
    const s0 = rdna2.Operand{ .kind = .sgpr, .reg = 0 };
    const s2 = rdna2.Operand{ .kind = .sgpr, .reg = 2 };
    const v18 = rdna2.Operand{ .kind = .vgpr, .reg = 18 };
    const lane = rdna2.Operand{ .kind = .integer_inline_constant, .value = 4 };
    var instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .s_load_dword, .dst = s0 },
        .{ .pc = 4, .opcode = .v_writelane_b32, .dst = v18, .src0 = s0, .src1 = lane },
        .{ .pc = 8, .opcode = .s_cmp_ge_u32, .src0 = s0, .src1 = .{ .kind = .literal_constant, .value = 255 } },
        .{ .pc = 12, .opcode = .s_cbranch_scc1, .branch_target = 36 },
        .{ .pc = 16, .opcode = .s_mov_b32, .dst = s0, .src0 = .{ .kind = .literal_constant, .value = 999 } },
        .{ .pc = 20, .opcode = .v_readlane_b32, .dst = s2, .src0 = v18, .src1 = lane },
        .{ .pc = 24, .opcode = .s_mulk_i32, .dst = s2, .src0 = s2, .src1 = .{ .kind = .literal_constant, .value = 368 } },
        .{ .pc = 28, .opcode = .s_buffer_load_dwordx8 },
        .{ .pc = 32, .opcode = .s_branch, .branch_target = 0 },
        .{ .pc = 36, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 255), scalarUpperBound(&instructions, &graph, 6, 2));
    // An ordinary VGPR write invalidates the saved scalar.
    instructions[4] = .{ .pc = 16, .opcode = .v_mov_b32, .dst = v18 };
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 6, 2));
    instructions[4] = .{ .pc = 16, .opcode = .s_nop };
    // Taking the comparison's true edge must not establish an upper bound.
    instructions[3].opcode = .s_cbranch_scc0;
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 6, 2));
    instructions[3].opcode = .s_cbranch_scc1;
    // A path from the guarded definition to the use that bypasses the guard
    // must retain the unbounded/wrapping interpretation.
    try graph.edges.append(std.testing.allocator, .{ .from = 0, .to = 1, .kind = .branch });
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 6, 2));
}

test "index bounds reject ambiguous reaching definitions" {
    const s0 = rdna2.Operand{ .kind = .sgpr, .reg = 0 };
    const s2 = rdna2.Operand{ .kind = .sgpr, .reg = 2 };
    const instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .s_load_dword, .dst = s0 },
        .{ .pc = 4, .opcode = .s_cmp_ge_u32, .src0 = s0, .src1 = .{ .kind = .literal_constant, .value = 255 } },
        .{ .pc = 8, .opcode = .s_cbranch_scc1, .branch_target = 28 },
        .{ .pc = 12, .opcode = .s_cbranch_execz, .branch_target = 24 },
        .{ .pc = 16, .opcode = .s_mov_b32, .dst = s2, .src0 = s0 },
        .{ .pc = 20, .opcode = .s_branch, .branch_target = 24 },
        .{ .pc = 24, .opcode = .s_mulk_i32, .dst = s2, .src0 = s2 },
        .{ .pc = 28, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    // s2 can arrive unchanged from entry, bypassing the guarded s0 copy.
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 6, 2));
}
