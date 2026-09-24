// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Recognize a packed-index fragment waterfall's wave-wide unsigned minimum.
//! Two row reductions feed READLANE 31/63, then their scalar minimum. The two
//! scalar temporaries and SCC are overwritten immediately after that minimum.
const std = @import("std");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const control_flow = @import("control_flow.zig");

pub const Reduction = struct { start_pc: u32, read_pcs: [2]u32 };

fn reg(op: operand.Operand, kind: @TypeOf(op.kind), index: u32) bool {
    return std.meta.eql(op, operand.Operand{ .kind = kind, .reg = index });
}

fn constant(op: operand.Operand, value: u32) bool {
    if (op.negate or op.absolute or op.dpp or op.dpp8 or op.sdwa_sel != 6) return false;
    return (op.kind == .integer_inline_constant or op.kind == .literal_constant) and op.value == value;
}

pub fn scan(a: std.mem.Allocator, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) std.mem.Allocator.Error![]Reduction {
    var pcs: std.ArrayList(Reduction) = .empty;
    errdefer pcs.deinit(a);
    if (instructions.len < 14) return pcs.toOwnedSlice(a);
    for (7..instructions.len - 6) |i| {
        const low = instructions[i];
        const high = instructions[i + 1];
        // A scalar wait may separate READLANE from the scalar minimum. The
        // wait has no register side effects; translated memory operations
        // already produce their value before use. Do not skip other opcodes.
        const minimum_index = i + 2 + @as(usize, @intFromBool(instructions[i + 2].opcode == .s_waitcnt));
        if (minimum_index + 4 >= instructions.len) continue;
        const minimum = instructions[minimum_index];
        if (low.opcode != .v_readlane_b32 or high.opcode != .v_readlane_b32 or minimum.opcode != .s_min_u32) continue;
        if (low.dst.kind != .sgpr or low.src0.kind != .vgpr or high.dst.kind != .sgpr or low.dst.reg >= 104) continue;
        const scalar = low.dst.reg;
        const vector = low.src0.reg;
        if (!constant(low.src1, 31) or !constant(high.src1, 63) or
            !reg(low.src0, .vgpr, vector) or !reg(high.src0, .vgpr, vector) or
            !reg(low.dst, .sgpr, scalar) or !reg(high.dst, .sgpr, scalar + 1) or
            !reg(minimum.src0, .sgpr, scalar) or !reg(minimum.src1, .sgpr, scalar + 1) or
            minimum.dst.kind != .sgpr or minimum.dst.reg == scalar or minimum.dst.reg == scalar + 1) continue;
        // No other observation of the individual half minima or their SCC.
        const overwrite = instructions[minimum_index + 1];
        const compare = instructions[minimum_index + 2];
        const exit_test = instructions[minimum_index + 3];
        if (overwrite.opcode != .v_cmp_ne_u32 or !reg(overwrite.dst, .sgpr, scalar) or
            !reg(overwrite.src0, .sgpr, minimum.dst.reg) or overwrite.src1.kind != .vgpr or
            compare.opcode != .v_cmp_ne_u32 or compare.dst.kind != .vcc_lo or
            compare.src0.kind != .vgpr or !reg(compare.src1, .sgpr, minimum.dst.reg) or
            exit_test.opcode != .s_cmp_ge_u32 or !reg(exit_test.src0, .sgpr, minimum.dst.reg) or
            !constant(exit_test.src1, 255) or instructions[minimum_index + 4].opcode != .s_cbranch_scc1) continue;
        const restore = instructions[i - 1];
        const combine = instructions[i - 2];
        const exchange = instructions[i - 3];
        if (restore.opcode != .s_mov_b64 or restore.dst.kind != .exec_lo or restore.src0.kind != .vcc_lo or
            combine.opcode != .v_min_u32 or !reg(combine.dst, .vgpr, vector) or !reg(combine.src0, .vgpr, vector) or
            exchange.opcode != .v_permlanex16_b32 or exchange.dst.kind != .vgpr or exchange.dst.reg == vector or
            !reg(combine.src1, .vgpr, exchange.dst.reg) or exchange.src0.kind != .vgpr or exchange.src0.reg != vector or
            !constant(exchange.src1, 0xffff_ffff) or !constant(exchange.src2, 0xffff_ffff)) continue;
        var matches = true;
        for ([_]u9{ 0x111, 0x112, 0x114, 0x118 }, 0..) |control, j| {
            const step = instructions[i - 7 + j];
            const expected = operand.Operand{ .kind = .vgpr, .reg = vector, .dpp = true, .dpp_ctrl = control };
            if (step.opcode != .v_min_u32 or !reg(step.dst, .vgpr, vector) or
                !std.meta.eql(step.src0, expected) or !reg(step.src1, .vgpr, vector)) matches = false;
        }
        // A branch must not bypass part of the recognized def/use window.
        for (graph.blocks.items) |block| {
            if (block.start_pc > instructions[i - 7].pc and block.start_pc <= instructions[minimum_index + 4].pc) matches = false;
        }
        if (!matches) continue;
        try pcs.append(a, .{ .start_pc = instructions[i - 7].pc, .read_pcs = .{ low.pc, high.pc } });
    }
    return pcs.toOwnedSlice(a);
}

test "fragment minimum requires the captured reduction and dead half-minimum temporaries" {
    // Captured packed-index reduction. Only the final branch is relocated to
    // END so the small fixture is a complete shader allocation.
    const code = [_]u32{
        0x261a1afa, 0xff01110d, 0x261a1afa, 0xff01120d,
        0x261a1afa, 0xff01140d, 0x261a1afa, 0xff01180d,
        0xd778100c, 0x0305830d, 0x261a190d, 0xbefe046a,
        0xd7600006, 0x00013f0d, 0xd7600007, 0x00017f0d,
        0x83880706, 0x7d8a16f9, 0x06868608, 0x7d8a10f9,
        0x86000000, 0xb60800ff, 0xbf850000, 0xbf810000,
    };
    const a = std.testing.allocator;
    for (0..8) |variant| {
        var program = try @import("decoder.zig").decodeProgram(a, &code);
        defer program.deinit(a);
        for (program.instructions.items) |*inst| {
            if (variant == 1 and inst.pc == 0x38) inst.src1.value = 32;
            if (variant == 2 and inst.pc == 0x10) inst.src0.dpp_ctrl = 0x112;
            if (variant == 3 and inst.pc == 0x44) inst.dst.reg = 10;
            if (variant == 4 and inst.pc == 0x54) inst.opcode = .s_nop;
            if (variant == 5 and inst.pc == 0x58) inst.branch_target = 0x10;
        }
        if (variant >= 6) {
            for (program.instructions.items) |*inst| {
                if (inst.pc >= 0x40) inst.pc += 4;
                if (inst.branch_target >= 0x40) inst.branch_target += 4;
            }
            try program.instructions.insert(a, 9, .{
                .pc = 0x40,
                .opcode = if (variant == 6) .s_waitcnt else .s_mov_b32,
                .dst = .{ .kind = .sgpr, .reg = 6 },
                .src0 = .{ .kind = .integer_inline_constant, .value = 0 },
            });
        }
        var graph = try control_flow.build(a, &program);
        defer graph.deinit(a);
        const pcs = try scan(a, program.instructions.items, &graph);
        defer a.free(pcs);
        if (variant == 0 or variant == 6) {
            try std.testing.expectEqual(@as(usize, 1), pcs.len);
            try std.testing.expectEqual(@as(u32, 0), pcs[0].start_pc);
            try std.testing.expectEqualSlices(u32, &.{ 0x30, 0x38 }, &pcs[0].read_pcs);
        } else try std.testing.expectEqual(@as(usize, 0), pcs.len);
    }
}
