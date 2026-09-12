// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Correlated resource tuples copied through vector registers before a waterfall.
const std = @import("std");
const rdna2 = @import("rdna2");
const definitions = @import("index_bounds.zig");
const scalar = @import("scalar_provenance.zig");
const maximum_blocks = 1024;
pub const Tuple = [8]usize;

fn plain(op: rdna2.Operand) bool {
    return std.meta.eql(op, rdna2.Operand{ .kind = op.kind, .reg = op.reg, .value = op.value, .signed_val = op.signed_val, .float_val = op.float_val });
}

fn writesExec(inst: rdna2.Instruction) bool {
    if (std.mem.indexOf(u8, @tagName(inst.opcode), "saveexec") != null) return true;
    for ([_]rdna2.Operand{ inst.dst, inst.dst2 }) |dst| {
        const register = scalar.scalarRegisterIndex(dst) orelse continue;
        const width: u32 = if (std.mem.endsWith(u8, @tagName(inst.opcode), "64")) 2 else @max(inst.data_words, 1);
        if (register < 128 and register + width > 126) return true;
    }
    return false;
}

fn blockAt(graph: *const rdna2.control_flow.Graph, instruction: usize) ?u32 {
    for (graph.blocks.items) |block| {
        if (instruction >= block.first_instruction and instruction < block.first_instruction + block.instruction_count) return block.index;
    }
    return null;
}

fn predecessors(graph: *const rdna2.control_flow.Graph, from: u32, stop: ?u32, reachable: *const [maximum_blocks]bool) [maximum_blocks]bool {
    var reached: [maximum_blocks]bool = @splat(false);
    var queue: [maximum_blocks]u32 = undefined;
    queue[0] = from;
    reached[from] = true;
    var length: usize = 1;
    var cursor: usize = 0;
    while (cursor < length) : (cursor += 1) {
        const block = queue[cursor];
        if (stop == block) continue;
        for (graph.edges.items) |edge| {
            if (edge.to != block or reached[edge.from] or !reachable[edge.from]) continue;
            reached[edge.from] = true;
            queue[length] = edge.from;
            length += 1;
        }
    }
    return reached;
}

/// Each returned tuple identifies four or eight scalar-to-vector moves which execute
/// under one mask. Taking whole tuples avoids a Cartesian product of unrelated
/// descriptor words. Unknown, partial and lane-shuffled writes are rejected.
pub fn imageTuples(
    instructions: []const rdna2.Instruction,
    graph: *const rdna2.control_flow.Graph,
    sample_index: usize,
    resource: u32,
    output: []Tuple,
) ?usize {
    if (graph.blocks.items.len > maximum_blocks) return null;
    if (sample_index >= instructions.len) return null;
    const word_count = instructions[sample_index].imageResourceWords();
    const reachable = definitions.reachableBlocks(graph) orelse return null;
    var reads: Tuple = undefined;
    var vector: u32 = 0;
    for (reads[0..word_count], 0..) |*read, component| {
        const definition = definitions.scalarDefinition(instructions, graph, sample_index, resource + @as(u32, @intCast(component))) orelse return null;
        const index = switch (definition) {
            .entry => return null,
            .instruction => |index| index,
        };
        const inst = instructions[index];
        if (inst.opcode != .v_readfirstlane_b32 or inst.src0.kind != .vgpr or !plain(inst.src0) or !plain(inst.dst)) return null;
        if (component == 0) vector = inst.src0.reg;
        if (inst.src0.reg != vector + component or (component != 0 and index <= reads[component - 1])) return null;
        read.* = index;
    }
    for (instructions[reads[0]..reads[word_count - 1]]) |inst| if (writesExec(inst) or inst.opcode.isBranch()) return null;
    const read_block = blockAt(graph, reads[0]) orelse return null;
    const ancestors = predecessors(graph, read_block, null, &reachable);
    var count: usize = 0;
    var component: usize = 0;
    var tuple: Tuple = @splat(0);
    var first_complete: ?usize = null;
    for (instructions, 0..) |inst, index| {
        const block = blockAt(graph, index) orelse return null;
        if (!ancestors[block]) continue;
        // A branch into the middle of a tuple can bypass some word copies.
        if (component != 0 and block != blockAt(graph, tuple[0])) return null;
        if (component != 0 and (writesExec(inst) or inst.opcode.isBranch())) return null;
        var overlaps = false;
        for ([_]rdna2.Operand{ inst.dst, inst.dst2 }) |dst| {
            if (dst.kind != .vgpr) continue;
            const width = @max(inst.data_words, if (std.mem.endsWith(u8, @tagName(inst.opcode), "64")) @as(u8, 2) else 1);
            overlaps = overlaps or (dst.reg < vector + word_count and dst.reg + width > vector);
        }
        if (!overlaps) continue;
        // A later loop-carried overwrite needs a separate loop analysis.
        if (index >= reads[0] or inst.opcode != .v_mov_b32 or inst.dst.reg != vector + component or
            scalar.scalarRegisterIndex(inst.src0) == null or !plain(inst.src0) or !plain(inst.dst)) return null;
        tuple[component] = index;
        component += 1;
        if (component == word_count) {
            if (count == output.len) return null;
            output[count] = tuple;
            count += 1;
            component = 0;
            if (first_complete == null) first_complete = index;
        }
    }
    if (component != 0) return null;
    const complete = first_complete orelse return null;
    const initial_block = blockAt(graph, complete) orelse return null;
    // Every path to the selection must pass a complete initialization tuple.
    // Subsequent masked copies then preserve the correlation of all eight words.
    if (initial_block != read_block) {
        const without_initial = predecessors(graph, read_block, initial_block, &reachable);
        if (initial_block != 0 and without_initial[0]) return null;
    }
    return count;
}

test "vector resource tuples preserve all words under a common mask" {
    var code: [28]rdna2.Instruction = @splat(.{ .opcode = .s_nop });
    for (&code, 0..) |*inst, index| inst.pc = @intCast(index * 4);
    for (0..8) |i| {
        code[i].opcode = .v_mov_b32;
        code[i].dst = .{ .kind = .vgpr, .reg = @intCast(8 + i) };
        code[i].src0 = .{ .kind = .sgpr, .reg = @intCast(16 + i) };
        code[9 + i] = code[i];
        code[9 + i].pc = @intCast((9 + i) * 4);
        code[9 + i].src0.reg += 8;
        code[19 + i].opcode = .v_readfirstlane_b32;
        code[19 + i].dst = .{ .kind = .sgpr, .reg = @intCast(4 + i) };
        code[19 + i].src0 = code[i].dst;
    }
    code[8].opcode = .s_mov_b64;
    code[8].dst = .{ .kind = .exec_lo };
    code[18] = code[8];
    code[18].pc = 72;
    code[27].opcode = .s_endpgm;
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &code);
    defer graph.deinit(std.testing.allocator);
    var tuples: [4]Tuple = undefined;
    try std.testing.expectEqual(@as(?usize, 2), imageTuples(&code, &graph, 27, 4, &tuples));
    try std.testing.expectEqual(@as(usize, 7), tuples[0][7]);
    try std.testing.expectEqual(@as(usize, 16), tuples[1][7]);
    // R128 uses only the first four moves; unrelated upper-half writes
    // must neither become part of the tuple nor prevent its recovery.
    code[27].image_r128 = true;
    code[13].src0.negate = true;
    try std.testing.expectEqual(@as(?usize, 2), imageTuples(&code, &graph, 27, 4, &tuples));
    try std.testing.expectEqual(@as(usize, 3), tuples[0][3]);
    try std.testing.expectEqual(@as(usize, 12), tuples[1][3]);
    code[27].image_r128 = false;
    code[13].src0.negate = true;
    try std.testing.expectEqual(null, imageTuples(&code, &graph, 27, 4, &tuples));
    code[13].src0.negate = false;
    code[13].dst.reg += 1;
    try std.testing.expectEqual(null, imageTuples(&code, &graph, 27, 4, &tuples));
    code[13].dst.reg -= 1;
    const saved = code[13];
    code[13] = code[8];
    try std.testing.expectEqual(null, imageTuples(&code, &graph, 27, 4, &tuples));
    code[13] = saved;
    code[13].opcode = .s_and_saveexec_b64;
    code[13].dst = .{ .kind = .sgpr, .reg = 40 };
    try std.testing.expectEqual(null, imageTuples(&code, &graph, 27, 4, &tuples));
    code[13] = saved;
    code[23] = code[8];
    try std.testing.expectEqual(null, imageTuples(&code, &graph, 27, 4, &tuples));
    code[23] = .{ .pc = 92, .opcode = .v_readfirstlane_b32, .dst = .{ .kind = .sgpr, .reg = 8 }, .src0 = .{ .kind = .vgpr, .reg = 12 } };
    code[8] = .{ .pc = 32, .opcode = .s_cbranch_execz, .branch_target = 52 };
    graph.deinit(std.testing.allocator);
    graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &code);
    try std.testing.expectEqual(null, imageTuples(&code, &graph, 27, 4, &tuples));
}
