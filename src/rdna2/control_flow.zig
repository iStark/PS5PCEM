// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Basic-block and control-flow graph construction for decoded shaders.

const std = @import("std");
const isa = @import("isa.zig");
const instruction = @import("instruction.zig");

pub const Error = std.mem.Allocator.Error || error{InvalidBranchTarget};

pub const EdgeKind = enum { fallthrough, branch };
pub const PredicateDomain = enum { none, scalar_uniform, wave_mask };
pub const Condition = enum {
    none,
    scc,
    vcc_zero,
    exec_zero,

    pub fn domain(self: Condition) PredicateDomain {
        return switch (self) {
            .none => .none,
            .scc => .scalar_uniform,
            .vcc_zero, .exec_zero => .wave_mask,
        };
    }
};

pub const Edge = struct {
    from: u32,
    to: u32,
    kind: EdgeKind,
    condition: Condition = .none,
    expected: bool = true,
};

pub const Selection = struct {
    header: u32,
    merge: u32,
    branch_successor: u32,
    fallthrough_successor: u32,
    condition: Condition,
    branch_when: bool,
};

pub const BasicBlock = struct {
    index: u32,
    start_pc: u32,
    end_pc: u32,
    first_instruction: u32,
    instruction_count: u32,
};

pub const Graph = struct {
    blocks: std.ArrayList(BasicBlock) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    selections: std.ArrayList(Selection) = .empty,
    back_edge_count: u32 = 0,

    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        self.blocks.deinit(allocator);
        self.edges.deinit(allocator);
        self.selections.deinit(allocator);
    }

    pub fn blockForPc(self: *const Graph, pc: u32) ?u32 {
        for (self.blocks.items) |block| {
            if (block.start_pc == pc) return block.index;
        }
        return null;
    }

    pub fn selectionForHeader(self: *const Graph, block: u32) ?Selection {
        for (self.selections.items) |selection| {
            if (selection.header == block) return selection;
        }
        return null;
    }
};

fn instructionIndexAtPc(program: *const instruction.Program, pc: u32) ?usize {
    for (program.instructions.items, 0..) |inst, index| {
        if (inst.pc == pc) return index;
    }
    return null;
}

fn conditionalBranch(opcode: isa.Opcode) bool {
    return opcode.isBranch() and opcode != .s_branch;
}

fn branchPredicate(opcode: isa.Opcode) struct { Condition, bool } {
    return switch (opcode) {
        .s_cbranch_scc0 => .{ .scc, false },
        .s_cbranch_scc1 => .{ .scc, true },
        .s_cbranch_vccz => .{ .vcc_zero, true },
        .s_cbranch_vccnz => .{ .vcc_zero, false },
        .s_cbranch_execz => .{ .exec_zero, true },
        .s_cbranch_execnz => .{ .exec_zero, false },
        else => .{ .none, true },
    };
}

fn markReachable(
    allocator: std.mem.Allocator,
    graph: *const Graph,
    from: u32,
    visited: []bool,
    pending: *std.ArrayList(u32),
) Error!void {
    @memset(visited, false);
    pending.clearRetainingCapacity();
    try pending.append(allocator, from);
    while (pending.pop()) |block| {
        if (block >= visited.len or visited[block]) continue;
        visited[block] = true;
        for (graph.edges.items) |edge| {
            if (edge.from == block and !visited[edge.to]) try pending.append(allocator, edge.to);
        }
    }
}

fn buildSelections(allocator: std.mem.Allocator, graph: *Graph) Error!void {
    const branch_reachable = try allocator.alloc(bool, graph.blocks.items.len);
    defer allocator.free(branch_reachable);
    const fallthrough_reachable = try allocator.alloc(bool, graph.blocks.items.len);
    defer allocator.free(fallthrough_reachable);
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    for (graph.blocks.items) |block| {
        var branch_successor: ?u32 = null;
        var fallthrough_successor: ?u32 = null;
        var predicate = Condition.none;
        var expected = true;
        for (graph.edges.items) |edge| {
            if (edge.from != block.index) continue;
            switch (edge.kind) {
                .branch => {
                    branch_successor = edge.to;
                    predicate = edge.condition;
                    expected = edge.expected;
                },
                .fallthrough => fallthrough_successor = edge.to,
            }
        }
        const branch = branch_successor orelse continue;
        const fallthrough = fallthrough_successor orelse continue;
        if (predicate == .none) continue;
        try markReachable(allocator, graph, branch, branch_reachable, &pending);
        try markReachable(allocator, graph, fallthrough, fallthrough_reachable, &pending);
        var candidate = block.index + 1;
        while (candidate < graph.blocks.items.len) : (candidate += 1) {
            if (branch_reachable[candidate] and fallthrough_reachable[candidate]) {
                try graph.selections.append(allocator, .{
                    .header = block.index,
                    .merge = candidate,
                    .branch_successor = branch,
                    .fallthrough_successor = fallthrough,
                    .condition = predicate,
                    .branch_when = expected,
                });
                break;
            }
        }
    }
}

/// Splits a decoded program at entry, direct branch targets and instructions
/// following terminators, then materializes direct branch/fallthrough edges.
pub fn build(allocator: std.mem.Allocator, program: *const instruction.Program) Error!Graph {
    const count = program.instructions.items.len;
    var graph = Graph{};
    errdefer graph.deinit(allocator);
    if (count == 0) return graph;

    const leaders = try allocator.alloc(bool, count);
    defer allocator.free(leaders);
    @memset(leaders, false);
    leaders[0] = true;

    for (program.instructions.items, 0..) |inst, index| {
        if (inst.opcode.isBranch()) {
            const target = instructionIndexAtPc(program, inst.branch_target) orelse
                return Error.InvalidBranchTarget;
            leaders[target] = true;
            if (index + 1 < count) leaders[index + 1] = true;
        } else if (inst.opcode.isProgramEnd() and index + 1 < count) {
            leaders[index + 1] = true;
        }
    }

    var start: usize = 0;
    while (start < count) {
        var end = start + 1;
        while (end < count and !leaders[end]) : (end += 1) {}
        const first = program.instructions.items[start];
        const last = program.instructions.items[end - 1];
        try graph.blocks.append(allocator, .{
            .index = @intCast(graph.blocks.items.len),
            .start_pc = first.pc,
            .end_pc = last.pc + last.word_count * 4,
            .first_instruction = @intCast(start),
            .instruction_count = @intCast(end - start),
        });
        start = end;
    }

    for (graph.blocks.items, 0..) |block, block_index| {
        const last_index = block.first_instruction + block.instruction_count - 1;
        const last = program.instructions.items[last_index];
        if (last.opcode.isProgramEnd() or last.opcode == .s_setpc_b64) continue;

        if (last.opcode.isBranch()) {
            const target = graph.blockForPc(last.branch_target) orelse return Error.InvalidBranchTarget;
            const predicate = branchPredicate(last.opcode);
            try graph.edges.append(allocator, .{
                .from = @intCast(block_index),
                .to = target,
                .kind = .branch,
                .condition = predicate[0],
                .expected = predicate[1],
            });
            if (target <= block_index) graph.back_edge_count += 1;
            if (!conditionalBranch(last.opcode)) continue;
        }

        if (block_index + 1 < graph.blocks.items.len) {
            try graph.edges.append(allocator, .{
                .from = @intCast(block_index),
                .to = @intCast(block_index + 1),
                .kind = .fallthrough,
            });
        }
    }
    try buildSelections(allocator, &graph);
    return graph;
}

test "conditional branch creates target and fallthrough edges" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbf84_0001, // s_cbranch_scc0 -> pc 8
        0xbe80_0301, // s_mov_b32 s0, s1
        0xbf81_0000, // s_endpgm
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), graph.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 3), graph.edges.items.len);
    try std.testing.expectEqual(EdgeKind.branch, graph.edges.items[0].kind);
    try std.testing.expectEqual(@as(u32, 2), graph.edges.items[0].to);
    try std.testing.expectEqual(EdgeKind.fallthrough, graph.edges.items[1].kind);
    try std.testing.expectEqual(Condition.scc, graph.edges.items[0].condition);
    try std.testing.expectEqual(PredicateDomain.scalar_uniform, graph.edges.items[0].condition.domain());
    try std.testing.expect(!graph.edges.items[0].expected);
    try std.testing.expectEqual(@as(usize, 1), graph.selections.items.len);
    try std.testing.expectEqual(@as(u32, 2), graph.selections.items[0].merge);
}

test "branch into an instruction body is rejected" {
    var instructions: std.ArrayList(instruction.Instruction) = .empty;
    defer instructions.deinit(std.testing.allocator);
    try instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_branch,
        .branch_target = 2,
    });
    var program = instruction.Program{ .code = &.{0}, .instructions = instructions };
    // Ownership remains with the local list; `build` only borrows it.
    try std.testing.expectError(Error.InvalidBranchTarget, build(std.testing.allocator, &program));
}

test "back edges are recorded separately from structured selections" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbf80_0000, // s_nop
        0xbf82_fffe, // s_branch -> pc 0
        0xbf81_0000, // unreachable terminator retained by the decoder
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), graph.back_edge_count);
    try std.testing.expectEqual(@as(usize, 0), graph.selections.items.len);
}
