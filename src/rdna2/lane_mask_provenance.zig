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
const State = []Kind;
const Spill = struct { vgpr: u32, lane: u32 };

fn lane(op: operand.Operand) ?u32 {
    if (op.negate or op.absolute or op.dpp) return null;
    return switch (op.kind) {
        .integer_inline_constant, .literal_constant => op.value & 63,
        else => null,
    };
}

fn spillIndex(spills: []const Spill, vgpr: u32, selected: u32) ?usize {
    for (spills, 0..) |spill, i| {
        if (spill.vgpr == vgpr and spill.lane == selected) return 128 + i;
    }
    return null;
}

fn invalidateSpills(state: State, spills: []const Spill, dst: operand.Operand, width: usize) void {
    if (dst.kind != .vgpr) return;
    for (spills, 0..) |spill, i| {
        if (spill.vgpr >= dst.reg and spill.vgpr - dst.reg < width) state[128 + i] = .integer;
    }
}

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

fn source(state: []const Kind, op: operand.Operand, component: usize) Kind {
    const base = index(op) orelse return .integer;
    return if (base + component < 128) state[base + component] else .integer;
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

fn combine(state: []const Kind, a: operand.Operand, b: operand.Operand, component: usize) Kind {
    const left = source(state, a, component);
    const right = source(state, b, component);
    if (neutral(a)) return right;
    if (neutral(b)) return left;
    if (left == .integer or right == .integer) return .integer;
    if (left == .unseen or right == .unseen) return .unseen;
    return .mask;
}

fn write(state: State, op: operand.Operand, values: []const Kind) void {
    const base = index(op) orelse return;
    const count = @min(values.len, 128 - base);
    @memcpy(state[base..][0..count], values[0..count]);
}

fn transfer(state: State, spills: []const Spill, inst: instruction.Instruction) void {
    // The graphics backend keeps scalar WRITELANE spills in private slots.
    // Their mask tags must follow the same slots across CFG joins/back edges.
    if (inst.opcode == .v_writelane_b32 and inst.dst.kind == .vgpr) {
        if (lane(inst.src1)) |selected| {
            if (spillIndex(spills, inst.dst.reg, selected)) |slot|
                state[slot] = source(state, inst.src0, 0);
        } else invalidateSpills(state, spills, inst.dst, 1);
        return;
    }
    const name = @tagName(inst.opcode);
    const width: usize = if (inst.data_words != 0) inst.data_words else if (std.mem.endsWith(u8, name, "_b64") or std.mem.endsWith(u8, name, "_u64") or
        std.mem.endsWith(u8, name, "_i64")) 2 else 1;
    invalidateSpills(state, spills, inst.dst, width);
    invalidateSpills(state, spills, inst.dst2, 1);
    if (inst.opcode == .v_readlane_b32 and inst.src0.kind == .vgpr) {
        const kind = if (lane(inst.src1)) |selected| blk: {
            const slot = spillIndex(spills, inst.src0.reg, selected) orelse break :blk Kind.integer;
            break :blk state[slot];
        } else Kind.integer;
        write(state, inst.dst, &.{kind});
        return;
    }
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
            const previous = state[126..128][0..2].*;
            for (0..2) |i| pair[i] = combine(state, .{ .kind = .exec_lo }, inst.src0, i);
            write(state, inst.dst, &previous);
            write(state, .{ .kind = .exec_lo }, &pair);
        },
        .s_mov_b32 => write(state, inst.dst, &.{source(state, inst.src0, 0)}),
        .s_wqm_b64 => {}, // The current graphics lowering retains its existing mask.
        else => {
            // Unknown operations may overwrite several consecutive SGPRs.
            // Losing provenance is safe; retaining a stale mask tag is not.
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
    var spills: std.ArrayList(Spill) = .empty;
    defer spills.deinit(allocator);
    for (instructions) |inst| {
        if (inst.opcode != .v_writelane_b32 or inst.dst.kind != .vgpr or inst.src0.kind == .vgpr) continue;
        const selected = lane(inst.src1) orelse continue;
        if (spillIndex(spills.items, inst.dst.reg, selected) == null)
            try spills.append(allocator, .{ .vgpr = inst.dst.reg, .lane = selected });
    }
    const stride = 128 + spills.items.len;
    const incoming = try allocator.alloc(Kind, graph.blocks.items.len * stride);
    defer allocator.free(incoming);
    const outgoing = try allocator.alloc(Kind, graph.blocks.items.len * stride);
    defer allocator.free(outgoing);
    @memset(incoming, .unseen);
    @memset(outgoing, .unseen);
    const entry = try allocator.alloc(Kind, stride);
    defer allocator.free(entry);
    @memset(entry, .integer);
    entry[126] = .mask;
    entry[127] = .mask;
    const state = try allocator.alloc(Kind, stride);
    defer allocator.free(state);
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.blocks.items) |block| {
            @memset(state, .unseen);
            if (block.index == 0) @memcpy(state, entry);
            for (graph.edges.items) |edge| {
                if (edge.to != block.index) continue;
                for (state, outgoing[edge.from * stride ..][0..stride]) |*value, previous| value.* = join(value.*, previous);
            }
            @memcpy(incoming[block.index * stride ..][0..stride], state);
            const end = block.first_instruction + block.instruction_count;
            for (instructions[block.first_instruction..end]) |inst| transfer(state, spills.items, inst);
            const output = outgoing[block.index * stride ..][0..stride];
            if (!std.mem.eql(Kind, state, output)) {
                @memcpy(output, state);
                changed = true;
            }
        }
    }
    for (graph.blocks.items) |block| {
        @memcpy(state, incoming[block.index * stride ..][0..stride]);
        const end = block.first_instruction + block.instruction_count;
        for (instructions[block.first_instruction..end]) |inst| {
            if ((inst.opcode == .s_ff1_i32_b64 or inst.opcode == .s_flbit_i32_b64) and
                source(state, inst.src0, 0) == .mask and source(state, inst.src0, 1) == .mask)
                try result.append(allocator, inst.pc);
            transfer(state, spills.items, inst);
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

test "mask provenance follows lane spills and rejects overwritten slots" {
    const a = std.testing.allocator;
    const scalar = operand.Operand{ .kind = .sgpr, .reg = 24 };
    const vector = operand.Operand{ .kind = .vgpr, .reg = 16 };
    const low_lane = operand.Operand{ .kind = .integer_inline_constant, .value = 7 };
    const high_lane = operand.Operand{ .kind = .literal_constant, .value = 72 }; // lane8 after masking
    for (0..8) |mode| {
        var code = std.ArrayList(instruction.Instruction).empty;
        defer code.deinit(a);
        try code.appendSlice(a, &.{
            .{ .opcode = .v_writelane_b32, .dst = vector, .src0 = .{ .kind = .exec_lo }, .src1 = low_lane, .src_count = 2 },
            .{ .opcode = .v_writelane_b32, .dst = vector, .src0 = .{ .kind = .exec_hi }, .src1 = high_lane, .src_count = 2 },
        });
        switch (mode) {
            0 => {},
            1 => try code.append(a, .{ .opcode = .v_writelane_b32, .dst = vector, .src0 = .{ .kind = .integer_inline_constant, .value = 16 }, .src1 = low_lane, .src_count = 2 }),
            2 => try code.append(a, .{ .opcode = .v_mov_b32, .dst = vector, .src0 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 1 }),
            3 => try code.append(a, .{ .opcode = .v_writelane_b32, .dst = vector, .src0 = .{ .kind = .exec_lo }, .src1 = scalar, .src_count = 2 }),
            4 => try code.append(a, .{ .opcode = .v_writelane_b32, .dst = vector, .src0 = .{ .kind = .integer_inline_constant, .value = 16 }, .src1 = .{ .kind = .integer_inline_constant, .value = 9 }, .src_count = 2 }),
            5 => try code.append(a, .{ .opcode = .buffer_load_dwordx2, .dst = .{ .kind = .vgpr, .reg = 15 }, .data_words = 2 }),
            6 => try code.append(a, .{ .opcode = .v_writelane_b32, .dst = vector, .src0 = .{ .kind = .vgpr, .reg = 1 }, .src1 = low_lane, .src_count = 2 }),
            7 => try code.appendSlice(a, &.{
                .{ .opcode = .s_cmp_eq_u32, .src0 = scalar, .src1 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 2 },
                .{ .opcode = .s_cbranch_scc0, .branch_target = 5 * 8 },
                .{ .opcode = .v_writelane_b32, .dst = vector, .src0 = .{ .kind = .integer_inline_constant, .value = 16 }, .src1 = low_lane, .src_count = 2 },
            }),
            else => unreachable,
        }
        try code.appendSlice(a, &.{
            .{ .opcode = .v_readlane_b32, .dst = scalar, .src0 = vector, .src1 = low_lane, .src_count = 2 },
            .{ .opcode = .v_readlane_b32, .dst = .{ .kind = .sgpr, .reg = 25 }, .src0 = vector, .src1 = high_lane, .src_count = 2 },
            .{ .opcode = .s_ff1_i32_b64, .dst = .{ .kind = .sgpr, .reg = 12 }, .src0 = scalar, .src_count = 1 },
            .{ .opcode = .s_endpgm },
        });
        for (code.items, 0..) |*inst, i| inst.pc = @intCast(i * 8);
        var graph = try control_flow.buildInstructionsWithBarriers(a, code.items, false);
        defer graph.deinit(a);
        const pcs = try scanPcs(a, code.items, &graph);
        defer a.free(pcs);
        try std.testing.expectEqual(@as(usize, if (mode == 0 or mode == 4) 1 else 0), pcs.len);
        if (pcs.len != 0) try std.testing.expectEqual(code.items[code.items.len - 2].pc, pcs[0]);
    }
}
