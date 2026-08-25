// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Basic-block and control-flow graph construction for decoded shaders.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
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
    /// True when a back edge's target does not dominate its source. Structured
    /// loop lowering cannot name a unique header for that cycle.
    irreducible: bool = false,

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

fn instructionEndPc(inst: instruction.Instruction) u32 {
    return inst.pc + inst.word_count * 4;
}

fn immediateOperand(value: operand.Operand) ?u32 {
    return switch (value.kind) {
        .integer_inline_constant, .literal_constant, .float_inline_constant => value.value,
        .null => 0,
        else => null,
    };
}

fn addImmediate(inst: instruction.Instruction, pc_reg: u32) ?struct { opcode: isa.Opcode, imm: u32 } {
    const is_add = inst.opcode == .s_add_u32 or inst.opcode == .s_add_i32;
    const is_sub = inst.opcode == .s_sub_u32 or inst.opcode == .s_sub_i32;
    if (!is_add and !is_sub) return null;
    const src0_pc = inst.src0.kind == .sgpr and inst.src0.reg == pc_reg;
    const src1_pc = inst.src1.kind == .sgpr and inst.src1.reg == pc_reg;
    if (src0_pc == src1_pc) return null;
    const imm = immediateOperand(if (src0_pc) inst.src1 else inst.src0) orelse return null;
    return .{ .opcode = inst.opcode, .imm = imm };
}

/// Resolves `s_getpc_b64` / add-or-sub / `s_setpc_b64` to a shader-relative PC.
///
/// Fetch and NGG prologs jump this way to the rest of the same allocation.
/// `s[6:7]` hardware exporters and external fetch-shader pointers return null
/// and stay terminators.
pub fn resolveSetpcTarget(program: *const instruction.Program, setpc_index: usize) ?u32 {
    const instructions = program.instructions.items;
    if (setpc_index >= instructions.len) return null;
    const setpc = instructions[setpc_index];
    if (setpc.opcode != .s_setpc_b64 or setpc.src0.kind != .sgpr) return null;
    const pc_reg = setpc.src0.reg;

    var index = setpc_index;
    if (index >= 1) {
        const prev = instructions[index - 1];
        if (prev.opcode == .s_addc_u32 and prev.dst.kind == .sgpr and prev.dst.reg == pc_reg + 1) {
            const carry = immediateOperand(prev.src0) orelse immediateOperand(prev.src1);
            if (carry == 0) index -= 1;
        }
    }

    if (index >= 2) {
        const arith = instructions[index - 1];
        const getpc = instructions[index - 2];
        if (getpc.opcode == .s_getpc_b64 and getpc.dst.kind == .sgpr and getpc.dst.reg == pc_reg and
            arith.dst.kind == .sgpr and arith.dst.reg == pc_reg)
        {
            if (addImmediate(arith, pc_reg)) |delta| {
                const base = instructionEndPc(getpc);
                const target = switch (delta.opcode) {
                    .s_add_u32, .s_add_i32 => base +% delta.imm,
                    else => base -% delta.imm,
                };
                return target & ~@as(u32, 3);
            }
        }
    }

    if (index >= 1) {
        const getpc = instructions[index - 1];
        if (getpc.opcode == .s_getpc_b64 and getpc.dst.kind == .sgpr and getpc.dst.reg == pc_reg) {
            return instructionEndPc(getpc);
        }
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

fn canReachWithout(
    allocator: std.mem.Allocator,
    graph: *const Graph,
    from: u32,
    wanted: u32,
    forbidden: u32,
) Error!bool {
    const visited = try allocator.alloc(bool, graph.blocks.items.len);
    defer allocator.free(visited);
    @memset(visited, false);
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, from);
    while (pending.pop()) |block| {
        if (block == forbidden or block >= visited.len or visited[block]) continue;
        if (block == wanted) return true;
        visited[block] = true;
        for (graph.edges.items) |edge| {
            if (edge.from == block and !visited[edge.to]) try pending.append(allocator, edge.to);
        }
    }
    return false;
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

        // For a natural loop, ordinary reachability is misleading: the exit
        // path can travel around an enclosing loop and eventually revisit this
        // header, making an inner body block look like a post-dominator. Find
        // the successor that reaches the latch without crossing the header;
        // the other successor is the canonical loop merge.
        var latch: ?u32 = null;
        for (graph.edges.items) |edge| {
            if (edge.to == block.index and edge.from >= block.index) {
                if (latch != null) {
                    latch = null;
                    break;
                }
                latch = edge.from;
            }
        }
        if (latch) |back_edge_source| {
            const branch_is_body = try canReachWithout(allocator, graph, branch, back_edge_source, block.index);
            const fallthrough_is_body = try canReachWithout(allocator, graph, fallthrough, back_edge_source, block.index);
            if (branch_is_body != fallthrough_is_body) {
                try graph.selections.append(allocator, .{
                    .header = block.index,
                    .merge = if (branch_is_body) fallthrough else branch,
                    .branch_successor = branch,
                    .fallthrough_successor = fallthrough,
                    .condition = predicate,
                    .branch_when = expected,
                });
                continue;
            }
        }

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
        } else if (inst.opcode == .s_setpc_b64) {
            if (resolveSetpcTarget(program, index)) |target| {
                if (instructionIndexAtPc(program, target)) |target_index| {
                    leaders[target_index] = true;
                }
            }
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
        if (last.opcode.isProgramEnd()) continue;
        if (last.opcode == .s_setpc_b64) {
            if (resolveSetpcTarget(program, last_index)) |target| {
                if (graph.blockForPc(target)) |dest| {
                    try graph.edges.append(allocator, .{
                        .from = @intCast(block_index),
                        .to = dest,
                        .kind = .branch,
                    });
                    if (dest <= block_index) graph.back_edge_count += 1;
                }
            }
            continue;
        }

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
    graph.irreducible = try graphHasIrreducibleCycle(allocator, &graph);
    return graph;
}

fn graphHasIrreducibleCycle(allocator: std.mem.Allocator, graph: *const Graph) Error!bool {
    if (graph.back_edge_count == 0 or graph.blocks.items.len == 0) return false;
    for (graph.edges.items) |edge| {
        if (edge.to > edge.from) continue;
        if (try canReachWithout(allocator, graph, 0, edge.from, edge.to)) return true;
    }
    return false;
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
    try std.testing.expect(!graph.irreducible);
}

test "GETPC plus add SETPC is an intra-program jump" {
    var instructions: std.ArrayList(instruction.Instruction) = .empty;
    defer instructions.deinit(std.testing.allocator);
    try instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_getpc_b64,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .word_count = 1,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .s_add_u32,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .src0 = .{ .kind = .sgpr, .reg = 0 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 8 },
        .src_count = 2,
        .word_count = 1,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 8,
        .opcode = .s_setpc_b64,
        .src0 = .{ .kind = .sgpr, .reg = 0 },
        .src_count = 1,
        .word_count = 1,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 12,
        .opcode = .s_mov_b32,
        .dst = .{ .kind = .sgpr, .reg = 2 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1 },
        .src_count = 1,
        .word_count = 1,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 16,
        .opcode = .s_endpgm,
        .word_count = 1,
    });
    const program = instruction.Program{ .code = &.{}, .instructions = instructions };
    try std.testing.expectEqual(@as(?u32, 12), resolveSetpcTarget(&program, 2));
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), graph.blocks.items.len);
    try std.testing.expectEqual(@as(u32, 12), graph.blocks.items[1].start_pc);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    try std.testing.expectEqual(EdgeKind.branch, graph.edges.items[0].kind);
    try std.testing.expectEqual(@as(u32, 1), graph.edges.items[0].to);
}

test "hardware NGG SETPC s6 stays a terminator" {
    var instructions: std.ArrayList(instruction.Instruction) = .empty;
    defer instructions.deinit(std.testing.allocator);
    try instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_setpc_b64,
        .src0 = .{ .kind = .sgpr, .reg = 6 },
        .src_count = 1,
        .word_count = 1,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .s_endpgm,
        .word_count = 1,
    });
    const program = instruction.Program{ .code = &.{}, .instructions = instructions };
    try std.testing.expectEqual(@as(?u32, null), resolveSetpcTarget(&program, 0));
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
}

test "a cycle entered from two predecessors is irreducible" {
    var instructions: std.ArrayList(instruction.Instruction) = .empty;
    defer instructions.deinit(std.testing.allocator);
    try instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_cbranch_scc0,
        .branch_target = 8,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .s_branch,
        .branch_target = 12,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 8,
        .opcode = .s_branch,
        .branch_target = 12,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 12,
        .opcode = .s_cbranch_scc0,
        .branch_target = 4,
    });
    try instructions.append(std.testing.allocator, .{
        .pc = 16,
        .opcode = .s_endpgm,
    });
    const program = instruction.Program{ .code = &.{}, .instructions = instructions };
    var graph = try build(std.testing.allocator, &program);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.back_edge_count >= 1);
    try std.testing.expect(graph.irreducible);
}
