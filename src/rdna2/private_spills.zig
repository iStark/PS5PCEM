// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Prove fixed addresses for an entire graphics DS spill allocation before
//! replacing its sparse, dynamically indexed private array with scalar slots.
const std = @import("std");
const instruction = @import("instruction.zig");
const control_flow = @import("control_flow.zig");

pub const Access = struct { pc: u32, word: u32 };
const unseen: u64 = 0x1_0000_0000;
const unknown: u64 = unseen + 1;

fn join(a: u64, b: u64) u64 {
    if (a == unseen) return b;
    if (b == unseen or a == b) return a;
    return unknown;
}

fn transfer(value: u64, inst: instruction.Instruction) u64 {
    if (inst.dst2.kind == .m0) return unknown;
    if (inst.dst.kind != .m0) return value;
    if (inst.opcode == .s_mov_b32 or inst.opcode == .s_movk_i32) {
        return switch (inst.src0.kind) {
            .integer_inline_constant, .literal_constant => inst.src0.value,
            .null => 0,
            .m0 => value,
            else => unknown,
        };
    }
    return unknown;
}

pub fn scan(allocator: std.mem.Allocator, instructions: []const instruction.Instruction, graph: *const control_flow.Graph, words: u32) ![]Access {
    var accesses: std.ArrayList(Access) = .empty;
    errdefer accesses.deinit(allocator);
    var count: usize = 0;
    for (instructions) |inst| {
        if (inst.opcode == .unknown or inst.opcode == .unsupported or
            std.mem.indexOf(u8, @tagName(inst.opcode), "bvh") != null)
            return accesses.toOwnedSlice(allocator);
        if (inst.family != .ds or inst.gds or inst.opcode == .ds_swizzle_b32) continue;
        if (inst.opcode != .ds_read_addtid_b32 and inst.opcode != .ds_write_addtid_b32)
            return accesses.toOwnedSlice(allocator);
        count += 1;
    }
    if (count == 0 or graph.blocks.items.len == 0) return accesses.toOwnedSlice(allocator);
    const incoming = try allocator.alloc(u64, graph.blocks.items.len);
    defer allocator.free(incoming);
    const outgoing = try allocator.alloc(u64, graph.blocks.items.len);
    defer allocator.free(outgoing);
    @memset(incoming, unseen);
    @memset(outgoing, unseen);
    incoming[0] = unknown;
    // Each block's lattice value can only advance from unseen to a constant
    // and then to unknown. A constant assignment can kill an unknown input.
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.blocks.items) |block| {
            var value = incoming[block.index];
            if (value == unseen) continue;
            for (instructions[block.first_instruction..][0..block.instruction_count]) |inst|
                value = transfer(value, inst);
            if (outgoing[block.index] != value) {
                outgoing[block.index] = value;
                changed = true;
            }
        }
        for (graph.edges.items) |edge| {
            const value = join(incoming[edge.to], outgoing[edge.from]);
            if (value != incoming[edge.to]) {
                incoming[edge.to] = value;
                changed = true;
            }
        }
    }
    for (graph.blocks.items) |block| {
        var value = incoming[block.index];
        for (instructions[block.first_instruction..][0..block.instruction_count]) |inst| {
            if (!inst.gds and (inst.opcode == .ds_read_addtid_b32 or inst.opcode == .ds_write_addtid_b32)) {
                if (value >= unseen or inst.memory_offset < 0) {
                    accesses.clearRetainingCapacity();
                    return accesses.toOwnedSlice(allocator);
                }
                const address = (value & 0xffff) + @as(u64, @intCast(inst.memory_offset));
                if (address / 4 >= words) {
                    accesses.clearRetainingCapacity();
                    return accesses.toOwnedSlice(allocator);
                }
                try accesses.append(allocator, .{ .pc = inst.pc, .word = @intCast(address / 4) });
            }
            value = transfer(value, inst);
        }
    }
    return accesses.toOwnedSlice(allocator);
}

test "private spill addresses converge across loops and reject mixed aliases" {
    const a = std.testing.allocator;
    var inst = [_]instruction.Instruction{
        .{ .pc = 0, .opcode = .s_movk_i32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .integer_inline_constant, .value = 0 } },
        .{ .pc = 4, .family = .ds, .opcode = .ds_write_addtid_b32, .memory_offset = 256 },
        .{ .pc = 12, .family = .ds, .opcode = .ds_read_addtid_b32, .memory_offset = 256 },
        .{ .pc = 20, .opcode = .s_cbranch_scc1, .branch_target = 12 },
        .{ .pc = 24, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(a, &inst, false);
    defer graph.deinit(a);
    const proven = try scan(a, &inst, &graph, 8192);
    defer a.free(proven);
    try std.testing.expectEqualSlices(Access, &.{ .{ .pc = 4, .word = 64 }, .{ .pc = 12, .word = 64 } }, proven);
    inst[0].src0 = .{ .kind = .sgpr, .reg = 0 };
    const dynamic = try scan(a, &inst, &graph, 8192);
    defer a.free(dynamic);
    try std.testing.expectEqual(@as(usize, 0), dynamic.len);
    inst[0].src0 = .{ .kind = .integer_inline_constant, .value = 0 };
    inst[2].opcode = .ds_read_b32;
    const alias = try scan(a, &inst, &graph, 8192);
    defer a.free(alias);
    try std.testing.expectEqual(@as(usize, 0), alias.len);
}

test "private spill proof rejects disagreeing predecessor bases and out-of-range accesses" {
    const a = std.testing.allocator;
    var inst = [_]instruction.Instruction{
        .{ .pc = 0, .opcode = .s_cbranch_scc1, .branch_target = 16 },
        .{ .pc = 4, .opcode = .s_movk_i32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .integer_inline_constant, .value = 0 } },
        .{ .pc = 8, .opcode = .s_branch, .branch_target = 24 },
        .{ .pc = 16, .opcode = .s_movk_i32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .integer_inline_constant, .value = 4 } },
        .{ .pc = 24, .family = .ds, .opcode = .ds_read_addtid_b32, .memory_offset = 256 },
        .{ .pc = 32, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(a, &inst, false);
    defer graph.deinit(a);
    const conflicting = try scan(a, &inst, &graph, 8192);
    defer a.free(conflicting);
    try std.testing.expectEqual(@as(usize, 0), conflicting.len);
    inst[3].src0.value = 0;
    const same = try scan(a, &inst, &graph, 8192);
    defer a.free(same);
    try std.testing.expectEqualSlices(Access, &.{.{ .pc = 24, .word = 64 }}, same);
    const outside = try scan(a, &inst, &graph, 64);
    defer a.free(outside);
    try std.testing.expectEqual(@as(usize, 0), outside.len);
}
