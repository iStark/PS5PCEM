// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Comparisons whose VCC result is consumed only by lane-local selections
//! before a complete overwrite in the same basic block.
const std = @import("std");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const control_flow = @import("control_flow.zig");

fn mayNameVcc(op: operand.Operand) bool {
    return switch (op.kind) {
        .vcc_lo, .vcc_hi, .vcc_z => true,
        // Conservatively include wide SGPR tuples near the VCC pair.
        .sgpr => op.reg >= 91 and op.reg <= 107,
        else => false,
    };
}

fn comparison(inst: instruction.Instruction) bool {
    return inst.dst.kind == .vcc_lo and std.mem.startsWith(u8, @tagName(inst.opcode), "v_cmp_");
}

pub fn scanPcs(allocator: std.mem.Allocator, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) ![]u32 {
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);
    for (graph.blocks.items) |block| {
        const end = block.first_instruction + block.instruction_count;
        for (block.first_instruction..end) |index| {
            if (!comparison(instructions[index])) continue;
            var selected = false;
            // Bound analysis work even for unusually large straight-line code.
            for (instructions[index + 1 .. @min(end, index + 129)]) |next| {
                if (next.opcode.isBranch() or next.opcode.isProgramEnd() or
                    next.opcode == .s_setpc_b64 or
                    next.opcode == .unknown or next.opcode == .unsupported) break;
                if (next.opcode == .v_cndmask_b32 and next.src2.kind == .vcc_lo and
                    !mayNameVcc(next.src0) and !mayNameVcc(next.src1) and !mayNameVcc(next.src3))
                {
                    selected = true;
                    continue;
                }
                if (mayNameVcc(next.src0) or mayNameVcc(next.src1) or
                    mayNameVcc(next.src2) or mayNameVcc(next.src3)) break;
                if (comparison(next)) {
                    if (selected) try result.append(allocator, instructions[index].pc);
                    break;
                }
                // Partial writes and arithmetic carry outputs require their
                // usual full-mask representation throughout the sequence.
                if (mayNameVcc(next.dst) or mayNameVcc(next.dst2)) break;
            }
        }
    }
    return result.toOwnedSlice(allocator);
}

test "local VCC proof excludes scalar reads, carry outputs and block boundaries" {
    const allocator = std.testing.allocator;
    var instructions = [_]instruction.Instruction{
        .{ .pc = 0, .opcode = .v_cmp_eq_u32, .dst = .{ .kind = .vcc_lo } },
        .{ .pc = 4, .opcode = .v_cndmask_b32, .dst = .{ .kind = .vgpr, .reg = 1 }, .src2 = .{ .kind = .vcc_lo } },
        .{ .pc = 8, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 2 } },
        .{ .pc = 12, .opcode = .v_cmp_ne_u32, .dst = .{ .kind = .vcc_lo } },
        .{ .pc = 16, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(allocator, &instructions, false);
    defer graph.deinit(allocator);
    const local = try scanPcs(allocator, &instructions, &graph);
    defer allocator.free(local);
    try std.testing.expectEqualSlices(u32, &.{0}, local);
    for ([_]operand.Operand{ .{ .kind = .vcc_lo }, .{ .kind = .vcc_hi }, .{ .kind = .vcc_z }, .{ .kind = .sgpr, .reg = 105 } }) |source| {
        instructions[2].src0 = source;
        const rejected = try scanPcs(allocator, &instructions, &graph);
        defer allocator.free(rejected);
        try std.testing.expectEqual(@as(usize, 0), rejected.len);
    }
    instructions[2].src0 = .{};
    instructions[2].dst2 = .{ .kind = .vcc_lo };
    const carry = try scanPcs(allocator, &instructions, &graph);
    defer allocator.free(carry);
    try std.testing.expectEqual(@as(usize, 0), carry.len);
    instructions[2].dst2 = .{};
    graph.blocks.items[0].instruction_count = 3;
    const boundary = try scanPcs(allocator, &instructions, &graph);
    defer allocator.free(boundary);
    try std.testing.expectEqual(@as(usize, 0), boundary.len);
}
