// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Identify scalar bit scans whose input is a saved per-invocation lane mask.
//! Ordinary integer bitfields keep their numeric representation. A forward
//! fixed point includes loop back edges and rejects mixed mask/integer joins.
const std = @import("std");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const control_flow = @import("control_flow.zig");
const Kind = enum { unseen, mask, integer };
const State = [128]Kind;

fn index(op: operand.Operand) ?usize {
    return switch (op.kind) {
        .sgpr => if (op.reg < 128) op.reg else null,
        .vcc_lo => 106,
        .vcc_hi => 107,
        .exec_lo => 126,
        .exec_hi => 127,
        .m0 => 124,
        else => null,
    };
}

fn source(state: *const State, op: operand.Operand, component: usize) Kind {
    const base = index(op) orelse return .integer;
    return if (base + component < state.len) state[base + component] else .integer;
}

fn neutral(op: operand.Operand) bool {
    return switch (op.kind) {
        .integer_inline_constant, .literal_constant => op.value == 0 or op.value == 0xffff_ffff,
        .null => true,
        else => false,
    };
}

fn join(a: Kind, b: Kind) Kind {
    if (a == .unseen) return b;
    if (b == .unseen or a == b) return a;
    return .integer;
}

fn combine(state: *const State, a: operand.Operand, b: operand.Operand, component: usize) Kind {
    const left = source(state, a, component);
    const right = source(state, b, component);
    if (neutral(a)) return right;
    if (neutral(b)) return left;
    if (left == .integer or right == .integer) return .integer;
    if (left == .unseen or right == .unseen) return .unseen;
    return .mask;
}

fn write(state: *State, op: operand.Operand, values: []const Kind) void {
    const base = index(op) orelse return;
    const count = @min(values.len, state.len - base);
    @memcpy(state[base..][0..count], values[0..count]);
}

fn transfer(state: *State, inst: instruction.Instruction) void {
    const name = @tagName(inst.opcode);
    if (std.mem.startsWith(u8, name, "v_cmp")) {
        write(state, inst.dst, &.{ .mask, .mask });
        return;
    }
    var pair: [2]Kind = undefined;
    switch (inst.opcode) {
        .s_mov_b64, .s_not_b64 => {
            for (0..2) |i| pair[i] = source(state, inst.src0, i);
            write(state, inst.dst, &pair);
        },
        .s_and_b64, .s_or_b64, .s_xor_b64, .s_andn2_b64, .s_orn2_b64, .s_nand_b64, .s_nor_b64, .s_xnor_b64, .s_cselect_b64 => {
            for (0..2) |i| pair[i] = combine(state, inst.src0, inst.src1, i);
            write(state, inst.dst, &pair);
        },
        .s_and_saveexec_b64, .s_orn2_saveexec_b64, .s_andn1_saveexec_b64 => {
            const previous = state[126..128].*;
            for (0..2) |i| pair[i] = combine(state, .{ .kind = .exec_lo }, inst.src0, i);
            write(state, inst.dst, &previous);
            write(state, .{ .kind = .exec_lo }, &pair);
        },
        .s_mov_b32 => write(state, inst.dst, &.{source(state, inst.src0, 0)}),
        .s_wqm_b64 => {}, // The current graphics lowering retains its existing mask.
        else => {
            // Unknown operations may overwrite several consecutive SGPRs.
            // Losing provenance is safe; retaining a stale mask tag is not.
            const width: usize = if (inst.data_words != 0) inst.data_words else if (std.mem.endsWith(u8, name, "_b64") or std.mem.endsWith(u8, name, "_u64") or
                std.mem.endsWith(u8, name, "_i64")) 2 else 1;
            const integers = [_]Kind{.integer} ** 128;
            write(state, inst.dst, integers[0..@min(width, integers.len)]);
            write(state, inst.dst2, &.{.integer});
        },
    }
}

pub fn scanPcs(allocator: std.mem.Allocator, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);
    const needed = for (instructions) |inst| {
        if (inst.opcode == .s_ff1_i32_b64 or inst.opcode == .s_flbit_i32_b64) break true;
    } else false;
    if (!needed or graph.blocks.items.len == 0) return result.toOwnedSlice(allocator);
    const incoming = try allocator.alloc(State, graph.blocks.items.len);
    defer allocator.free(incoming);
    const outgoing = try allocator.alloc(State, graph.blocks.items.len);
    defer allocator.free(outgoing);
    @memset(incoming, @splat(.unseen));
    @memset(outgoing, @splat(.unseen));
    var entry: State = @splat(.integer);
    entry[126] = .mask;
    entry[127] = .mask;
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.blocks.items) |block| {
            var state: State = if (block.index == 0) entry else @splat(.unseen);
            for (graph.edges.items) |edge| {
                if (edge.to != block.index) continue;
                for (&state, outgoing[edge.from]) |*value, previous| value.* = join(value.*, previous);
            }
            incoming[block.index] = state;
            const end = block.first_instruction + block.instruction_count;
            for (instructions[block.first_instruction..end]) |inst| transfer(&state, inst);
            if (!std.mem.eql(Kind, &state, &outgoing[block.index])) {
                outgoing[block.index] = state;
                changed = true;
            }
        }
    }
    for (graph.blocks.items) |block| {
        var state = incoming[block.index];
        const end = block.first_instruction + block.instruction_count;
        for (instructions[block.first_instruction..end]) |inst| {
            if ((inst.opcode == .s_ff1_i32_b64 or inst.opcode == .s_flbit_i32_b64) and
                source(&state, inst.src0, 0) == .mask and source(&state, inst.src0, 1) == .mask)
                try result.append(allocator, inst.pc);
            transfer(&state, inst);
        }
    }
    return result.toOwnedSlice(allocator);
}

test "mask provenance rejects integer input from another control flow edge" {
    const allocator = std.testing.allocator;
    const code = [_]u32{
        0xbe98047e, // saved = EXEC
        0xbf068000, // runtime scalar condition
        0xbf840002, // branch to numeric overwrite
        0x87987e18, // saved &= EXEC
        0xbf820001, // join
        0xbe980390, // low word = 16 on the other edge
        0xbe8c1418, // FF1 sees mask or integer
        0xbf810000,
    };
    var program = try @import("decoder.zig").decodeProgram(allocator, &code);
    defer program.deinit(allocator);
    var graph = try control_flow.buildInstructionsWithBarriers(allocator, program.instructions.items, false);
    defer graph.deinit(allocator);
    const pcs = try scanPcs(allocator, program.instructions.items, &graph);
    defer allocator.free(pcs);
    try std.testing.expectEqual(@as(usize, 0), pcs.len);
}
