// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Conservative bounds for scalar table indices guarded by unsigned branches.
const std = @import("std");
const rdna2 = @import("rdna2");
const Instruction = rdna2.Instruction;
const Graph = rdna2.control_flow.Graph;
const maximum_blocks = 1024;

const Location = struct { register: u32, lane: ?u32 = null };
pub const Definition = struct { instruction: usize, component: u32 };

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
    if (location.lane == null and location.register >= 126 and location.register <= 127) {
        switch (inst.opcode) {
            .s_and_saveexec_b64, .s_orn2_saveexec_b64, .s_andn1_saveexec_b64 => return true,
            .s_and_saveexec_b32, .s_andn1_saveexec_b32 => if (location.register == 126) return true,
            else => {},
        }
    }
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
        const vector_mask = dst.kind == .vcc_lo and switch (inst.family) {
            .vop1, .vop2, .vop3, .vop3p, .vopc => true,
            else => false,
        };
        const destination_width = if (vector_mask) @max(width, 2) else width;
        const register: ?usize = if (kind == .sgpr) @import("scalar_provenance.zig").scalarRegisterIndex(dst) else if (dst.kind == kind) @as(usize, dst.reg) else null;
        if (register) |first| if (location.register >= first and location.register - first < destination_width) return true;
    }
    return false;
}

/// Require the same reaching definition on every predecessor, including loop
/// back edges. A lexical last-write search can incorrectly trust a skipped
/// assignment or a register changed on a previous loop iteration.
const ReachingDefinitions = struct { items: [32]usize = undefined, count: usize = 0, entry: bool = false, origin: bool = false };

/// Pruned shader blocks retain their byte positions as NOPs. Their fallthrough
/// edges must not introduce definitions into code reachable from the entry.
pub fn reachableBlocks(graph: *const Graph) ?[maximum_blocks]bool {
    if (graph.blocks.items.len == 0 or graph.blocks.items.len > maximum_blocks) return null;
    // Resource recovery asks this question for many individual SGPR words.
    // Index the outgoing edges once per query instead of scanning every edge
    // again for each reached block. Decoded blocks have at most two successors;
    // retain the general scan for larger externally constructed graphs.
    const no_edge = std.math.maxInt(u32);
    var first_edge: [maximum_blocks]u32 = undefined;
    var next_edge: [maximum_blocks * 2]u32 = undefined;
    // Tiny graphs are cheaper to scan than to initialize another index.
    const indexed = graph.blocks.items.len >= 32 and graph.edges.items.len <= next_edge.len;
    if (indexed) @memset(first_edge[0..graph.blocks.items.len], no_edge);
    for (graph.edges.items, 0..) |edge, index| {
        if (edge.from >= graph.blocks.items.len or edge.to >= graph.blocks.items.len) return null;
        if (indexed) {
            next_edge[index] = first_edge[edge.from];
            first_edge[edge.from] = @intCast(index);
        }
    }
    var reached: [maximum_blocks]bool = @splat(false);
    var queue: [maximum_blocks]u32 = undefined;
    reached[0] = true;
    queue[0] = 0;
    var length: usize = 1;
    var cursor: usize = 0;
    while (cursor < length) : (cursor += 1) {
        if (indexed) {
            var index = first_edge[queue[cursor]];
            while (index != no_edge) : (index = next_edge[index]) {
                const target = graph.edges.items[index].to;
                if (reached[target]) continue;
                reached[target] = true;
                queue[length] = target;
                length += 1;
            }
            continue;
        }
        for (graph.edges.items) |edge| {
            if (edge.from != queue[cursor] or reached[edge.to]) continue;
            reached[edge.to] = true;
            queue[length] = edge.to;
            length += 1;
        }
    }
    return reached;
}

test "resource reachability handles unordered edges, cycles and disconnected blocks" {
    var graph = Graph{};
    defer graph.deinit(std.testing.allocator);
    for (0..64) |index| try graph.blocks.append(std.testing.allocator, .{
        .index = @intCast(index),
        .start_pc = @intCast(index * 4),
        .end_pc = @intCast(index * 4 + 4),
        .first_instruction = @intCast(index),
        .instruction_count = 1,
    });
    for ([_][2]u32{ .{ 3, 1 }, .{ 5, 4 }, .{ 0, 2 }, .{ 1, 3 }, .{ 2, 1 }, .{ 0, 2 }, .{ 4, 3 } }) |edge|
        try graph.edges.append(std.testing.allocator, .{ .from = edge[0], .to = edge[1], .kind = .branch });
    const indexed = reachableBlocks(&graph).?;
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true, false, false }, indexed[0..6]);
    for (indexed[6..]) |reached| try std.testing.expect(!reached);
    // The fallback for graphs exceeding the decoder's edge ceiling must
    // preserve the same result, including duplicate incoming edges.
    for (0..maximum_blocks * 2) |_| try graph.edges.append(std.testing.allocator, .{ .from = 3, .to = 1, .kind = .branch });
    try std.testing.expectEqual(indexed, reachableBlocks(&graph).?);
    try graph.edges.append(std.testing.allocator, .{ .from = 0, .to = 64, .kind = .branch });
    try std.testing.expectEqual(null, reachableBlocks(&graph));
}

fn reachingDefinitions(instructions: []const Instruction, graph: *const Graph, before: usize, location: Location) ?ReachingDefinitions {
    return reachingDefinitionsUntil(instructions, graph, before, location, null);
}

fn reachingDefinitionsUntil(instructions: []const Instruction, graph: *const Graph, before: usize, location: Location, origin: ?usize) ?ReachingDefinitions {
    const reachable = reachableBlocks(graph) orelse return null;
    const first_block = blockAt(graph, before) orelse return null;
    if (!reachable[first_block]) return null;
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
            if (end == origin) {
                result.origin = true;
                found = true;
                break;
            }
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
            if (block_index == 0) result.entry = true;
            var has_predecessor = false;
            for (graph.edges.items) |edge| {
                if (edge.to != block_index or !reachable[edge.from]) continue;
                has_predecessor = true;
                if (visited[edge.from]) continue;
                visited[edge.from] = true;
                queue[count] = edge.from;
                count += 1;
            }
            if (!has_predecessor and block_index != 0) return null;
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
    return if (!definitions.entry and definitions.count == 1) definitions.items[0] else null;
}

pub const ScalarDefinition = union(enum) { entry, instruction: usize };

/// Distinguishes an unchanged USER_DATA word from a unique shader writer.
/// Mixed entry/written paths and loop-carried alternatives remain unknown.
pub fn scalarDefinition(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32) ?ScalarDefinition {
    const definitions = reachingDefinitions(instructions, graph, before, .{ .register = register }) orelse return null;
    if (definitions.entry) return if (definitions.count == 0) .entry else null;
    return if (definitions.count == 1) .{ .instruction = definitions.items[0] } else null;
}

const MaskProof = struct {
    const Visit = struct { instruction: usize, register: u32 };
    visited: [64]Visit = undefined,
    count: usize = 0,
    has_origin: bool = false,
};

// A fetch can run after an explicit restoration of an earlier saved EXEC.
// Follow only exact 64-bit copies here: a narrowing write before the fetch
// does not establish that every lane in the older snapshot received a value.
fn maskRestoresOrigin(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32, origin: usize, depth: u32) bool {
    if (depth == 16) return false;
    for (0..2) |half| {
        const definitions = reachingDefinitions(instructions, graph, before, .{ .register = register + @as(u32, @intCast(half)) }) orelse return false;
        if (definitions.entry or definitions.count == 0) return false;
        for (definitions.items[0..definitions.count]) |index| {
            const inst = instructions[index];
            if (index == origin) {
                // SAVEEXEC writes both its SGPR destination and implicit EXEC;
                // only the SGPR pair contains the saved, pre-narrowing mask.
                if (@import("scalar_provenance.zig").scalarRegisterIndex(inst.dst) != register) return false;
                continue;
            }
            if (inst.opcode != .s_mov_b64 or @import("scalar_provenance.zig").scalarRegisterIndex(inst.dst) != register) return false;
            const source = @import("scalar_provenance.zig").scalarRegisterIndex(inst.src0) orelse return false;
            if (!maskRestoresOrigin(instructions, graph, index, @intCast(source), origin, depth + 1)) return false;
        }
    }
    return true;
}

// A waterfall loop saves EXEC after computing its vector index, then removes
// processed lanes with ANDN2. Every selected lane remains inside that original
// execution mask. Reject OR/restores, unknown entry values and other writers.
fn maskIsSubsetOfVectorWrite(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32, vector_write: usize, proof: *MaskProof) bool {
    for (0..2) |half| {
        const definitions = reachingDefinitionsUntil(instructions, graph, before, .{ .register = register + @as(u32, @intCast(half)) }, if (register == 126) vector_write else null) orelse return false;
        if (definitions.entry) return false;
        proof.has_origin = proof.has_origin or definitions.origin;
        for (definitions.items[0..definitions.count]) |index| {
            const visit = MaskProof.Visit{ .instruction = index, .register = register };
            var visited = false;
            for (proof.visited[0..proof.count]) |previous| if (std.meta.eql(previous, visit)) {
                visited = true;
                break;
            };
            if (visited) continue;
            if (proof.count == proof.visited.len) return false;
            proof.visited[proof.count] = visit;
            proof.count += 1;
            const inst = instructions[index];
            if (register == 126 and (inst.opcode == .s_and_saveexec_b64 or
                (std.mem.startsWith(u8, @tagName(inst.opcode), "v_cmpx_") and inst.dst.kind == .exec_lo)))
            {
                if (!maskIsSubsetOfVectorWrite(instructions, graph, index, 126, vector_write, proof)) return false;
                continue;
            }
            if (@import("scalar_provenance.zig").scalarRegisterIndex(inst.dst) != register) return false;
            const copies_exec = inst.opcode == .s_mov_b64 and inst.src0.kind == .exec_lo;
            // SAVEEXEC returns the mask from before narrowing EXEC. An earlier
            // snapshot is usable only after proving its restoration at the fetch.
            const saves_previous_exec = switch (inst.opcode) {
                .s_and_saveexec_b64, .s_andn1_saveexec_b64, .s_orn2_saveexec_b64 => true,
                else => false,
            };
            if (copies_exec or saves_previous_exec) {
                if (index > vector_write) {
                    if (!maskIsSubsetOfVectorWrite(instructions, graph, index, 126, vector_write, proof)) return false;
                } else {
                    var unchanged = copies_exec and index < vector_write and blockAt(graph, index) == blockAt(graph, vector_write);
                    if (unchanged) for (instructions[index + 1 .. vector_write]) |between| {
                        if (writes(between, .{ .register = 126 }) or writes(between, .{ .register = 127 })) {
                            unchanged = false;
                            break;
                        }
                    };
                    if (!unchanged and !maskRestoresOrigin(instructions, graph, vector_write, 126, index, 0)) return false;
                    proof.has_origin = true;
                }
            } else if (inst.opcode == .s_mov_b64 or inst.opcode == .s_andn2_b64 or inst.opcode == .s_and_b64) {
                const source = @import("scalar_provenance.zig").scalarRegisterIndex(inst.src0) orelse return false;
                if (!maskIsSubsetOfVectorWrite(instructions, graph, index, @intCast(source), vector_write, proof)) return false;
            } else return false;
        }
    }
    return true;
}

/// The vector definition shared by every lane a waterfall can select.
pub fn scalarLaneDefinition(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32, depth: u32) ?Definition {
    if (depth == 16) return null;
    const index = reachingDefinition(instructions, graph, before, .{ .register = register }) orelse return null;
    const inst = instructions[index];
    if (inst.opcode == .s_mov_b32 and inst.src0.kind == .sgpr) return scalarLaneDefinition(instructions, graph, index, inst.src0.reg, depth + 1);
    if (inst.src0.kind != .vgpr) return null;
    var lane_index = index;
    var mask_register: usize = 126;
    if (inst.opcode == .v_readlane_b32) {
        const lane_register = @import("scalar_provenance.zig").scalarRegisterIndex(inst.src1) orelse return null;
        lane_index = reachingDefinition(instructions, graph, index, .{ .register = @intCast(lane_register) }) orelse return null;
        const lane = instructions[lane_index];
        if (lane.opcode != .s_ff1_i32_b64) return null;
        mask_register = @import("scalar_provenance.zig").scalarRegisterIndex(lane.src0) orelse return null;
    } else if (inst.opcode != .v_readfirstlane_b32) return null;
    // Check all writes to this VGPR, since the lane is chosen dynamically.
    const vector_index = reachingDefinition(instructions, graph, index, .{ .register = inst.src0.reg, .lane = std.math.maxInt(u32) }) orelse return null;
    const vector = instructions[vector_index];
    if (vector.dst.kind != .vgpr or vector.dst.reg > inst.src0.reg or vector.dst.sdwa_sel != 6) return null;
    var proof = MaskProof{};
    if (!maskIsSubsetOfVectorWrite(instructions, graph, lane_index, @intCast(mask_register), vector_index, &proof) or !proof.has_origin) return null;
    return .{ .instruction = vector_index, .component = inst.src0.reg - vector.dst.reg };
}

fn scalarBitUpperBound(instructions: []const Instruction, graph: *const Graph, before: usize, register: u32, depth: u32) ?u32 {
    const definition = scalarLaneDefinition(instructions, graph, before, register, depth) orelse return null;
    const vector = instructions[definition.instruction];
    if (definition.component != 0 or vector.opcode != .v_lshrrev_b32 or vector.src1.sdwa_sel != 6 or vector.src1.dpp) return null;
    const shift = (immediate(vector.src0) orelse return null) & 31;
    if (shift == 0) return null;
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
    if (start == target and definition <= use) return false;
    var visited: [maximum_blocks]bool = @splat(false);
    var queue: [maximum_blocks]u32 = undefined;
    queue[0] = start;
    visited[start] = true;
    var count: usize = 1;
    var cursor: usize = 0;
    while (cursor < count) : (cursor += 1) {
        const block = queue[cursor];
        for (graph.edges.items) |edge| {
            if (edge.from != block or (edge.from == guard and edge.kind == .fallthrough)) continue;
            if (edge.to == target) return false;
            if (visited[edge.to]) continue;
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
    if (scalarLoopUpperBound(instructions, graph, use, register)) |bound|
        result = @min(result orelse std.math.maxInt(u32), bound);
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

/// A zero-based unit counter, with every recurrence guarded by counter < N.
/// Both reaching-definition checks are necessary: a separate write before
/// the increment could otherwise introduce negative or wrapping values.
fn scalarLoopUpperBound(instructions: []const Instruction, graph: *const Graph, use: usize, register: u32) ?u32 {
    const location = Location{ .register = register };
    const definitions = reachingDefinitions(instructions, graph, use, location) orelse return null;
    if (definitions.entry or definitions.count != 2 or graph.blocks.items.len > maximum_blocks) return null;
    const initial_index = @min(definitions.items[0], definitions.items[1]);
    const increment_index = @max(definitions.items[0], definitions.items[1]);
    if (initial_index >= use or increment_index < use or increment_index + 2 >= instructions.len) return null;
    const initial = instructions[initial_index];
    const increment = instructions[increment_index];
    if (initial.opcode != .s_mov_b32 or initial.dst.kind != .sgpr or initial.dst.reg != register or immediate(initial.src0) != 0 or
        increment.opcode != .s_add_i32 or increment.dst.kind != .sgpr or increment.dst.reg != register or
        increment.src0.kind != .sgpr or increment.src0.reg != register or immediate(increment.src1) != 1) return null;
    const prior = reachingDefinitions(instructions, graph, increment_index, location) orelse return null;
    if (prior.entry or prior.count != 2 or @min(prior.items[0], prior.items[1]) != initial_index or
        @max(prior.items[0], prior.items[1]) != increment_index) return null;
    const compare = instructions[increment_index + 1];
    const branch = instructions[increment_index + 2];
    if ((compare.opcode != .s_cmp_lt_i32 and compare.opcode != .s_cmp_lt_u32) or
        compare.src0.kind != .sgpr or compare.src0.reg != register or branch.opcode != .s_cbranch_scc1) return null;
    const bound = immediate(compare.src1) orelse return null;
    if (bound == 0 or bound > std.math.maxInt(i32)) return null;
    const header_pc = branch.branch_target;
    if (header_pc <= initial.pc or header_pc > instructions[use].pc) return null;
    const guard = blockAt(graph, increment_index) orelse return null;
    if (blockAt(graph, increment_index + 2) != guard) return null;
    const target = blockAt(graph, use) orelse return null;
    // Starting after the increment, no path may return to the use without
    // taking this comparison's true edge. A fallthrough/bypass invalidates
    // the induction even if the conventional back edge is also present.
    var visited: [maximum_blocks]bool = @splat(false);
    var queue: [maximum_blocks]u32 = undefined;
    queue[0] = guard;
    visited[guard] = true;
    var length: usize = 1;
    var cursor: usize = 0;
    while (cursor < length) : (cursor += 1) {
        for (graph.edges.items) |edge| {
            if (edge.from != queue[cursor] or (edge.from == guard and edge.kind == .branch)) continue;
            if (edge.to == target) return null;
            if (visited[edge.to]) continue;
            visited[edge.to] = true;
            queue[length] = edge.to;
            length += 1;
        }
    }
    return bound;
}

pub const ScalarLoopLimit = struct { operand: rdna2.Operand, before_pc: u32 };

/// A zero-based, unit-increment while loop whose true comparison dominates
/// every use, including the first iteration and all back edges. The caller
/// must recover the uniform limit at before_pc and require 0 < limit <= INT_MAX:
/// this also proves the increment cannot wrap into a negative signed value.
pub fn scalarGuardedLoopLimit(instructions: []const Instruction, graph: *const Graph, use: usize, register: u32) ?ScalarLoopLimit {
    const location = Location{ .register = register };
    const definitions = reachingDefinitions(instructions, graph, use, location) orelse return null;
    if (definitions.entry or definitions.count != 2) return null;
    const initial_index = @min(definitions.items[0], definitions.items[1]);
    const increment_index = @max(definitions.items[0], definitions.items[1]);
    if (initial_index >= use or increment_index <= use) return null;
    const initial = instructions[initial_index];
    const increment = instructions[increment_index];
    if (initial.opcode != .s_mov_b32 or initial.dst.kind != .sgpr or initial.dst.reg != register or immediate(initial.src0) != 0 or
        increment.opcode != .s_add_i32 or increment.dst.kind != .sgpr or increment.dst.reg != register or
        increment.src0.kind != .sgpr or increment.src0.reg != register or immediate(increment.src1) != 1) return null;
    const prior = reachingDefinitions(instructions, graph, increment_index, location) orelse return null;
    if (prior.entry or prior.count != 2 or @min(prior.items[0], prior.items[1]) != initial_index or
        @max(prior.items[0], prior.items[1]) != increment_index) return null;
    for (graph.blocks.items) |block| {
        if (block.instruction_count < 2) continue;
        const branch_index = block.first_instruction + block.instruction_count - 1;
        if (branch_index <= initial_index or branch_index >= use) continue;
        const compare = instructions[branch_index - 1];
        if (instructions[branch_index].opcode != .s_cbranch_scc0 or
            (compare.opcode != .s_cmp_lt_i32 and compare.opcode != .s_cmp_lt_u32) or
            compare.src0.kind != .sgpr or compare.src0.reg != register) continue;
        const compared = reachingDefinitions(instructions, graph, branch_index - 1, location) orelse continue;
        if (compared.entry or compared.count != 2 or @min(compared.items[0], compared.items[1]) != initial_index or
            @max(compared.items[0], compared.items[1]) != increment_index) continue;
        if (!requiresFallthrough(graph, initial_index, use, block.index) or
            !requiresFallthrough(graph, increment_index, use, block.index)) continue;
        return .{ .operand = compare.src1, .before_pc = compare.pc };
    }
    return null;
}

test "uniform while-loop limits guard initialization and every recurrence" {
    const counter = rdna2.Operand{ .kind = .sgpr, .reg = 17 };
    var instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .s_mov_b32, .dst = counter, .src0 = .{ .kind = .integer_inline_constant, .value = 0 } },
        .{ .pc = 4, .opcode = .s_cmp_lt_i32, .src0 = counter, .src1 = .{ .kind = .sgpr, .reg = 16 } },
        .{ .pc = 8, .opcode = .s_cbranch_scc0, .branch_target = 32 },
        .{ .pc = 12, .opcode = .s_nop },
        .{ .pc = 16, .opcode = .s_lshl_b32, .dst = .{ .kind = .vcc_lo }, .src0 = counter, .src1 = .{ .kind = .integer_inline_constant, .value = 5 } },
        .{ .pc = 20, .opcode = .s_add_i32, .dst = counter, .src0 = counter, .src1 = .{ .kind = .integer_inline_constant, .value = 1 } },
        .{ .pc = 24, .opcode = .s_nop },
        .{ .pc = 28, .opcode = .s_branch, .branch_target = 4 },
        .{ .pc = 32, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    const limit = scalarGuardedLoopLimit(&instructions, &graph, 4, 17).?;
    try std.testing.expectEqual(@as(u32, 4), limit.before_pc);
    try std.testing.expectEqual(@as(u32, 16), limit.operand.reg);
    instructions[0].src0.value = 0xffff_ffff;
    try std.testing.expect(scalarGuardedLoopLimit(&instructions, &graph, 4, 17) == null);
    instructions[0].src0.value = 0;
    instructions[5].src1.value = 2;
    try std.testing.expect(scalarGuardedLoopLimit(&instructions, &graph, 4, 17) == null);
    instructions[5].src1.value = 1;
    instructions[3] = .{ .pc = 12, .opcode = .s_mov_b32, .dst = counter, .src0 = .{ .kind = .integer_inline_constant, .value = 99 } };
    try std.testing.expect(scalarGuardedLoopLimit(&instructions, &graph, 4, 17) == null);
    instructions[3] = .{ .pc = 12, .opcode = .s_nop };
    instructions[7].branch_target = 12;
    var bypass = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer bypass.deinit(std.testing.allocator);
    try std.testing.expect(scalarGuardedLoopLimit(&instructions, &bypass, 4, 17) == null);
}

test "counted scalar image loops require a bounded recurrence" {
    const counter = rdna2.Operand{ .kind = .sgpr, .reg = 16 };
    var instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .s_mov_b32, .dst = counter, .src0 = .{ .kind = .integer_inline_constant, .value = 0 } },
        .{ .pc = 4, .opcode = .s_nop },
        .{ .pc = 8, .opcode = .s_lshl_b32, .dst = .{ .kind = .vcc_lo }, .src0 = counter, .src1 = .{ .kind = .integer_inline_constant, .value = 5 } },
        .{ .pc = 12, .opcode = .s_nop },
        .{ .pc = 16, .opcode = .s_add_i32, .dst = counter, .src0 = counter, .src1 = .{ .kind = .integer_inline_constant, .value = 1 } },
        .{ .pc = 20, .opcode = .s_cmp_lt_i32, .src0 = counter, .src1 = .{ .kind = .integer_inline_constant, .value = 6 } },
        .{ .pc = 24, .opcode = .s_cbranch_scc1, .branch_target = 4 },
        .{ .pc = 28, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 6), scalarUpperBound(&instructions, &graph, 2, 16));
    instructions[5].opcode = .s_cmp_lt_u32;
    try std.testing.expectEqual(@as(?u32, 6), scalarUpperBound(&instructions, &graph, 2, 16));
    instructions[0].src0.value = 0xffff_ffff;
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 2, 16));
    instructions[0].src0.value = 0;
    instructions[4].src1.value = 2;
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 2, 16));
    instructions[4].src1.value = 1;
    instructions[3] = .{ .pc = 12, .opcode = .s_mov_b32, .dst = counter, .src0 = .{ .kind = .integer_inline_constant, .value = 0xffff_ffff } };
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &graph, 2, 16));
    instructions[3] = .{ .pc = 12, .opcode = .s_nop };
    instructions[7] = .{ .pc = 28, .opcode = .s_branch, .branch_target = 4 };
    var bypass = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer bypass.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, null), scalarUpperBound(&instructions, &bypass, 2, 16));
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

test "waterfall image lanes preserve a mask saved through VCC before the fetch" {
    const exec = rdna2.Operand{ .kind = .exec_lo };
    const vcc = rdna2.Operand{ .kind = .vcc_lo };
    const s8 = rdna2.Operand{ .kind = .sgpr, .reg = 8 };
    var instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .s_mov_b64, .dst = vcc, .src0 = exec },
        .{ .pc = 4, .opcode = .s_nop },
        .{ .pc = 8, .opcode = .image_load, .dst = .{ .kind = .vgpr, .reg = 15 } },
        .{ .pc = 12, .opcode = .s_nop },
        .{ .pc = 16, .opcode = .s_mov_b64, .dst = exec, .src0 = vcc },
        .{ .pc = 20, .opcode = .s_mov_b64, .dst = s8, .src0 = vcc },
        .{ .pc = 24, .opcode = .s_ff1_i32_b64, .dst = vcc, .src0 = s8 },
        .{ .pc = 28, .opcode = .v_readlane_b32, .dst = .{ .kind = .sgpr, .reg = 26 }, .src0 = .{ .kind = .vgpr, .reg = 15 }, .src1 = vcc },
        .{ .pc = 32, .opcode = .s_mul_i32 },
        .{ .pc = 36, .opcode = .s_andn2_b64, .dst = s8, .src0 = s8, .src1 = .{ .kind = .sgpr, .reg = 24 } },
        .{ .pc = 40, .opcode = .s_cbranch_scc1, .branch_target = 24 },
        .{ .pc = 44, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?Definition, .{ .instruction = 2, .component = 0 }), scalarLaneDefinition(&instructions, &graph, 8, 26, 0));
    instructions[1] = .{ .pc = 4, .opcode = .s_mov_b64, .dst = exec, .src0 = s8 };
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 8, 26, 0) == null);
    instructions[1] = .{ .pc = 4, .opcode = .s_nop };
    instructions[9].opcode = .s_or_b64;
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 8, 26, 0) == null);
    instructions[9].opcode = .s_andn2_b64;
    instructions[3] = .{ .pc = 12, .opcode = .s_mov_b32, .dst = .{ .kind = .vcc_hi }, .src0 = s8 };
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 8, 26, 0) == null);
    instructions[3] = .{ .pc = 12, .opcode = .v_cmp_eq_u32, .family = .vopc, .dst = vcc };
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 8, 26, 0) == null);
    // Terrain masks also save the fetch's active lanes while entering a
    // conditional branch, then restore that saved mask for their waterfall.
    instructions[0] = .{ .pc = 0, .opcode = .s_nop };
    instructions[3] = .{ .pc = 12, .opcode = .s_and_saveexec_b64, .dst = vcc, .src0 = s8 };
    try std.testing.expectEqual(@as(?Definition, .{ .instruction = 2, .component = 0 }), scalarLaneDefinition(&instructions, &graph, 8, 26, 0));
    // Saving before a narrowing fetch does not prove that all saved lanes
    // received its value.
    instructions[0] = instructions[3];
    instructions[0].pc = 0;
    instructions[3] = .{ .pc = 12, .opcode = .s_nop };
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 8, 26, 0) == null);
}

test "waterfall masks follow restored EXEC across conditional blocks" {
    const exec = rdna2.Operand{ .kind = .exec_lo };
    const vcc = rdna2.Operand{ .kind = .vcc_lo };
    const s8 = rdna2.Operand{ .kind = .sgpr, .reg = 8 };
    const s10 = rdna2.Operand{ .kind = .sgpr, .reg = 10 };
    const other = rdna2.Operand{ .kind = .sgpr, .reg = 12 };
    var instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .s_mov_b64, .dst = s8, .src0 = exec },
        .{ .pc = 4, .opcode = .v_cmpx_gt_u32, .dst = exec },
        .{ .pc = 8, .opcode = .s_cbranch_execz, .branch_target = 16 },
        .{ .pc = 12, .opcode = .s_nop },
        .{ .pc = 16, .opcode = .s_mov_b64, .dst = exec, .src0 = s8 },
        .{ .pc = 20, .opcode = .image_load, .dst = .{ .kind = .vgpr, .reg = 15 } },
        .{ .pc = 24, .opcode = .v_cmpx_gt_u32, .dst = exec },
        .{ .pc = 28, .opcode = .s_cbranch_execz, .branch_target = 36 },
        .{ .pc = 32, .opcode = .s_nop },
        .{ .pc = 36, .opcode = .s_mov_b64, .dst = exec, .src0 = s8 },
        .{ .pc = 40, .opcode = .s_and_saveexec_b64, .dst = s10, .src0 = other },
        .{ .pc = 44, .opcode = .s_cbranch_execz, .branch_target = 52 },
        .{ .pc = 48, .opcode = .s_nop },
        .{ .pc = 52, .opcode = .s_mov_b64, .dst = exec, .src0 = s10 },
        .{ .pc = 56, .opcode = .s_ff1_i32_b64, .dst = vcc, .src0 = s10 },
        .{ .pc = 60, .opcode = .v_readlane_b32, .dst = .{ .kind = .sgpr, .reg = 26 }, .src0 = .{ .kind = .vgpr, .reg = 15 }, .src1 = vcc },
        .{ .pc = 64, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?Definition, .{ .instruction = 5, .component = 0 }), scalarLaneDefinition(&instructions, &graph, 16, 26, 0));
    // Without restoration before the fetch, the older snapshot includes
    // lanes which never received an index.
    instructions[4].opcode = .s_nop;
    instructions[4].dst = .{};
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 16, 26, 0) == null);
    instructions[4].opcode = .s_mov_b64;
    instructions[4].dst = exec;
    instructions[9].src0 = other;
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 16, 26, 0) == null);
    instructions[9].src0 = s8;
    // A SAVEEXEC snapshot from before the fetch is also valid when explicitly
    // restored, even though it narrowed EXEC at the time of the save.
    instructions[0].opcode = .s_and_saveexec_b64;
    instructions[0].src0 = other;
    try std.testing.expectEqual(@as(?Definition, .{ .instruction = 5, .component = 0 }), scalarLaneDefinition(&instructions, &graph, 16, 26, 0));
    // Implicit EXEC writes must also invalidate the pre-fetch restoration.
    instructions[4] = .{ .pc = 16, .opcode = .s_and_saveexec_b64, .dst = other, .src0 = s8 };
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 16, 26, 0) == null);
    instructions[4] = .{ .pc = 16, .opcode = .s_mov_b64, .dst = exec, .src0 = s8 };
    instructions[15].opcode = .v_readfirstlane_b32;
    try std.testing.expectEqual(@as(?Definition, .{ .instruction = 5, .component = 0 }), scalarLaneDefinition(&instructions, &graph, 16, 26, 0));
    instructions[0].opcode = .s_andn1_saveexec_b64;
    try std.testing.expectEqual(@as(?Definition, .{ .instruction = 5, .component = 0 }), scalarLaneDefinition(&instructions, &graph, 16, 26, 0));
    instructions[13].src0 = other;
    try std.testing.expect(scalarLaneDefinition(&instructions, &graph, 16, 26, 0) == null);
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

test "scalar definitions ignore unreachable fallthrough after branch specialization" {
    const s4 = rdna2.Operand{ .kind = .sgpr, .reg = 4 };
    var instructions = [_]Instruction{
        .{ .pc = 0, .opcode = .s_mov_b32, .dst = s4, .src0 = .{ .kind = .sgpr, .reg = 0 } },
        .{ .pc = 4, .opcode = .s_branch, .branch_target = 16 },
        .{ .pc = 8, .opcode = .s_mov_b32, .dst = s4, .src0 = .{ .kind = .sgpr, .reg = 1 } },
        .{ .pc = 12, .opcode = .s_nop },
        .{ .pc = 16, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?ScalarDefinition, .{ .instruction = 0 }), scalarDefinition(&instructions, &graph, 4, 4));
    try std.testing.expect(scalarDefinition(&instructions, &graph, 3, 4) == null);
    // The same predecessor must participate when the branch is conditional.
    instructions[1].opcode = .s_cbranch_scc1;
    graph.deinit(std.testing.allocator);
    graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    try std.testing.expect(scalarDefinition(&instructions, &graph, 4, 4) == null);
}
