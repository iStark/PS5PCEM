// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Basic-block and control-flow graph construction for decoded shaders.

const std = @import("std");
const isa = @import("isa.zig");
const instruction = @import("instruction.zig");

pub const Error = std.mem.Allocator.Error || error{InvalidBranchTarget};

pub const EdgeKind = enum { fallthrough, branch };

pub const Edge = struct {
    from: u32,
    to: u32,
    kind: EdgeKind,
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

    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        self.blocks.deinit(allocator);
        self.edges.deinit(allocator);
    }

    pub fn blockForPc(self: *const Graph, pc: u32) ?u32 {
        for (self.blocks.items) |block| {
            if (block.start_pc == pc) return block.index;
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
        } else if (inst.opcode == .s_endpgm and index + 1 < count) {
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
        if (last.opcode == .s_endpgm or last.opcode == .s_setpc_b64) continue;

        if (last.opcode.isBranch()) {
            const target = graph.blockForPc(last.branch_target) orelse return Error.InvalidBranchTarget;
            try graph.edges.append(allocator, .{
                .from = @intCast(block_index),
                .to = target,
                .kind = .branch,
            });
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
