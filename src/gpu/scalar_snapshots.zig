// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Opt-in replacement of immutable, single-visit SMEM buffer reads.
const std = @import("std");
const rdna2 = @import("rdna2");
const checkpoints = @import("resource_checkpoints.zig");
const scalar = @import("scalar_provenance.zig");
const Register = rdna2.spirv.ScalarRegister;

pub export var entry_scalar_buffer_snapshots: bool = true;
pub export var entry_scalar_buffer_snapshots_used: u64 = 0;

pub fn prefix(instructions: []const rdna2.Instruction, plan: ?*const checkpoints.Plan, specialized_end: u32, draw_read_only: bool) u32 {
    if (!draw_read_only or !@atomicLoad(bool, &entry_scalar_buffer_snapshots, .monotonic)) return 0;
    const retained = plan orelse return 0;
    if (!retained.matches(instructions) or !retained.forward_only or !retained.reads_only_resources) return 0;
    return @min(specialized_end, retained.entry_block_end);
}

/// Revalidate after merges as well: a replacement scalar must never inherit
/// proof for an older value. Only exact producer/register/value matches count.
pub fn mark(evaluation: *const scalar.Evaluation, registers: []Register, end: u32) void {
    if (end == 0) return;
    for (evaluation.loadSlice()) |*load| {
        if (!load.buffer_descriptor or load.pc >= end) continue;
        for (load.values[0..load.word_count], 0..) |value, word| {
            for (registers) |*register| {
                if (register.producer_pc == load.pc and register.register == load.destination + word) {
                    register.entry_buffer_snapshot = register.value == value;
                    break;
                }
            }
        }
    }
}

pub fn complete(inst: rdna2.Instruction, registers: []const Register) bool {
    switch (inst.opcode) {
        .s_buffer_load_dword, .s_buffer_load_dwordx2, .s_buffer_load_dwordx4, .s_buffer_load_dwordx8, .s_buffer_load_dwordx16 => {},
        else => return false,
    }
    if (inst.dst.kind != .sgpr or inst.data_words == 0 or inst.data_words > 16) return false;
    if (@as(u32, inst.dst.reg) + inst.data_words > 128) return false;
    for (0..inst.data_words) |word| {
        var found = false;
        for (registers) |register| {
            if (register.producer_pc == inst.pc and register.register == inst.dst.reg + word) {
                if (!register.entry_buffer_snapshot) return false;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "entry buffer snapshots reject loops writes replaced programs and conditional blocks" {
    const a = std.testing.allocator;
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .smem, .opcode = .s_buffer_load_dword, .data_words = 1 },
        .{ .pc = 8, .family = .sopp, .opcode = .s_cbranch_scc0, .branch_target = 20 },
        .{ .pc = 12, .family = .smem, .opcode = .s_buffer_load_dword, .data_words = 1 },
        .{ .pc = 20, .family = .sopp, .opcode = .s_endpgm },
    };
    var plan = try checkpoints.Plan.init(a, &instructions);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(u32, 8), prefix(&instructions, &plan, 100, true));
    try std.testing.expectEqual(@as(u32, 4), prefix(&instructions, &plan, 4, true));
    try std.testing.expectEqual(@as(u32, 0), prefix(&instructions, &plan, 100, false));
    try std.testing.expectEqual(@as(u32, 0), prefix(instructions[1..], &plan, 100, true));
    try std.testing.expectEqual(@as(u32, 0), prefix(&instructions, null, 100, true));
    for ([_]rdna2.Instruction{
        .{ .pc = 20, .opcode = .s_branch, .branch_target = 0 },
        .{ .pc = 20, .opcode = .s_call_b64 },
        .{ .pc = 20, .opcode = .buffer_store_dword },
        .{ .pc = 20, .opcode = .image_store },
        .{ .pc = 20, .opcode = .unknown },
    }) |last| {
        instructions[3] = last;
        var rejected = try checkpoints.Plan.init(a, &instructions);
        defer rejected.deinit(a);
        try std.testing.expectEqual(@as(u32, 0), prefix(&instructions, &rejected, 100, true));
    }
}

test "entry buffer snapshots require complete exact producer values and retain out of range zeros" {
    const a = std.testing.allocator;
    const evaluation = try a.create(scalar.Evaluation);
    defer a.destroy(evaluation);
    evaluation.* = .{};
    evaluation.load_count = 1;
    evaluation.loads[0] = .{ .pc = 8, .address = 0x1000, .destination = 4, .word_count = 2, .buffer_descriptor = true, .from_srt = false, .base_sources = .{}, .offset_sources = .{}, .values = @splat(0) };
    evaluation.loads[0].values[0] = 123;
    const inst = rdna2.Instruction{ .pc = 8, .family = .smem, .opcode = .s_buffer_load_dwordx2, .dst = .{ .kind = .sgpr, .reg = 4 }, .data_words = 2 };
    var registers = [_]Register{ .{ .register = 4, .value = 123, .producer_pc = 8 }, .{ .register = 5, .value = 0, .producer_pc = 8 } };
    mark(evaluation, &registers, 8);
    try std.testing.expect(!complete(inst, &registers));
    mark(evaluation, &registers, 16);
    try std.testing.expect(complete(inst, &registers));
    try std.testing.expect(!complete(inst, registers[0..1]));
    registers[1].producer_pc = 12;
    try std.testing.expect(!complete(inst, &registers));
    registers[1].producer_pc = 8;
    registers[1].value = 99;
    mark(evaluation, &registers, 16);
    try std.testing.expect(!complete(inst, &registers));
}
