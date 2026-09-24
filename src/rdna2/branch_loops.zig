// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Proves a deliberately narrow structured CFG: disjoint natural loops with
//! single latches and properly nested forward skips, breaks and continues.
//! No shader instructions or SPIR-V IDs are changed while checking eligibility.
const std = @import("std");
const instruction = @import("instruction.zig");
const control_flow = @import("control_flow.zig");

pub const none = std.math.maxInt(u32);
pub const Kind = enum { ordinary, selection, loop_exit };
pub const Block = struct {
    loop_header: u32 = none,
    latch: u32 = none,
    target: u32 = none,
    kind: Kind = .ordinary,
};

pub fn analyze(a: std.mem.Allocator, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) std.mem.Allocator.Error!?[]Block {
    if (graph.back_edge_count == 0 or graph.irreducible) return null;
    const blocks = try a.alloc(Block, graph.blocks.items.len);
    var accepted = false;
    defer if (!accepted) a.free(blocks);
    @memset(blocks, .{});
    // Disjoint intervals, a single back edge, and an exit after
    // the latch. Nested loops remain on the existing lowering paths.
    for (graph.edges.items) |edge| {
        if (edge.to > edge.from) continue;
        const source = graph.blocks.items[edge.from];
        const last = instructions[source.first_instruction + source.instruction_count - 1];
        if (edge.kind != .branch or !last.opcode.isBranch() or edge.to == edge.from or edge.from + 1 >= blocks.len) return null;
        for (blocks[edge.to .. edge.from + 1]) |*block| {
            if (block.loop_header != none) return null;
            block.loop_header = edge.to;
            block.latch = edge.from;
        }
    }
    for (graph.blocks.items) |block| {
        const index = block.index;
        const last = instructions[block.first_instruction + block.instruction_count - 1];
        if (last.opcode == .s_setpc_b64) return null;
        if (last.opcode.isProgramEnd()) {
            if (index + 1 != blocks.len or blocks[index].loop_header != none) return null;
        } else if (last.opcode.isBranch()) {
            const target = graph.blockForPc(last.branch_target) orelse return null;
            blocks[index].target = target;
            if (last.opcode == .s_branch) {
                if (index != blocks[index].latch or target != blocks[index].loop_header) return null;
            } else {
                if (index == blocks[index].latch and target == blocks[index].loop_header) continue;
                if (target <= index or index + 1 >= blocks.len) return null;
                const owner = blocks[index];
                blocks[index].kind = if (owner.loop_header != none and (target == owner.latch or target == owner.latch + 1)) .loop_exit else .selection;
            }
        } else if (index + 1 == blocks.len) return null;
    }
    for (graph.edges.items) |edge| {
        const source = blocks[edge.from];
        const target = blocks[edge.to];
        if (edge.kind == .fallthrough and edge.to != edge.from + 1) return null;
        if (target.loop_header != none and source.loop_header != target.loop_header and edge.to != target.loop_header) return null;
        if (source.loop_header != none and target.loop_header != source.loop_header and edge.to != source.latch + 1) return null;
    }
    for (blocks, 0..) |block, i| {
        if (block.loop_header != i) continue;
        var has_exit = blocks[block.latch].target == i and instructions[graph.blocks.items[block.latch].first_instruction + graph.blocks.items[block.latch].instruction_count - 1].opcode != .s_branch;
        for (blocks[i .. block.latch + 1]) |inside| {
            if (inside.kind == .loop_exit and inside.target == block.latch + 1) has_exit = true;
        }
        if (!has_exit) return null;
    }
    // Lexical forward regions must nest. A skip can contain a complete loop,
    // but cannot enter or escape its middle except through break/continue.
    for (blocks, 0..) |block, i| {
        if (block.kind != .selection) continue;
        for (blocks, 0..) |other, j| {
            if (other.kind == .selection and i < j and j < block.target and block.target < other.target) return null;
            if (other.loop_header != j) continue;
            if ((i < j and j < block.target and block.target <= other.latch) or
                (j <= i and i <= other.latch and other.latch < block.target)) return null;
        }
    }
    // Canonical loop-only graphs already have a dedicated lowering path with
    // its own semantics. In particular, do not introduce the dispatcher's cap
    // into loops which previously executed without that fallback.
    var canonical = true;
    for (blocks, 0..) |block, i| {
        if (block.loop_header == i and graph.selectionForHeader(@intCast(i)) == null) canonical = false;
    }
    for (graph.selections.items) |selection| {
        if (blocks[selection.header].loop_header != selection.header) canonical = false;
    }
    if (canonical) return null;
    accepted = true;
    return blocks;
}

test "branch loop proof accepts forward selections and rejects unsafe boundaries" {
    const a = std.testing.allocator;
    const original = [_]instruction.Instruction{
        .{ .pc = 0, .opcode = .s_cbranch_scc0, .branch_target = 32 },
        .{ .pc = 4, .opcode = .s_nop },
        .{ .pc = 8, .opcode = .s_cbranch_scc1, .branch_target = 32 },
        .{ .pc = 12, .opcode = .s_cbranch_scc1, .branch_target = 28 },
        .{ .pc = 16, .opcode = .s_cbranch_scc1, .branch_target = 24 },
        .{ .pc = 20, .opcode = .s_nop },
        .{ .pc = 24, .opcode = .s_nop },
        .{ .pc = 28, .opcode = .s_branch, .branch_target = 4 },
        .{ .pc = 32, .opcode = .s_endpgm },
    };
    for (0..8) |variant| {
        var inst = original;
        switch (variant) {
            0 => {},
            1 => inst[7].opcode = .s_cbranch_scc1,
            2 => inst[0].branch_target = 20, // bypass the loop header
            3 => inst[4].opcode = .s_branch, // unsupported forward jump
            4 => inst[3].opcode = .s_setpc_b64, // indirect exit
            5 => inst[5].opcode = .s_endpgm, // early termination
            6 => inst[2].branch_target = 28, // no loop exit
            7 => inst[5] = .{ .pc = 20, .opcode = .s_branch, .branch_target = 16 }, // nested loop
            else => unreachable,
        }
        var graph = try control_flow.buildInstructions(a, &inst);
        defer graph.deinit(a);
        const plan = try analyze(a, &inst, &graph);
        defer if (plan) |blocks| a.free(blocks);
        try std.testing.expectEqual(variant < 2, plan != null);
    }
}
