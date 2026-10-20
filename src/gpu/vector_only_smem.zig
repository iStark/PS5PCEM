// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Conservative proof for leaving vector-only constant-buffer loads on the GPU.
//! This never removes an instruction from the translated shader. It identifies
//! loads whose values are not inputs to later host scalar/resource work.
const std = @import("std");
const rdna2 = @import("rdna2");
const scalar = @import("scalar_provenance.zig");

fn include(mask: *u128, operand: rdna2.Operand, width: usize) void {
    const first = scalar.scalarRegisterIndex(operand) orelse return;
    for (first..@min(first + width, 128)) |index|
        mask.* |= @as(u128, 1) << @intCast(index);
}

fn readMask(inst: *const rdna2.Instruction) ?u128 {
    var used: u128 = 0;
    if (inst.opcode == .unknown or inst.opcode == .unsupported or
        std.mem.indexOf(u8, @tagName(inst.opcode), "movrel") != null) return null;
    switch (inst.opcode) {
        .s_setpc_b64,
        .s_swappc_b64,
        .s_call_b64,
        .v_readlane_b32,
        .v_readfirstlane_b32,
        .v_writelane_b32,
        .s_cbranch_cdbgsys,
        .s_cbranch_cdbguser,
        .s_cbranch_cdbgsys_or_user,
        .s_cbranch_cdbgsys_and_user,
        => return null,
        .s_branch,
        .s_cbranch_scc0,
        .s_cbranch_scc1,
        .s_cbranch_execz,
        .s_cbranch_execnz,
        .s_cbranch_vccz,
        .s_cbranch_vccnz,
        => if (inst.branch_target <= inst.pc) return null,
        else => {},
    }
    switch (inst.family) {
        .sop1, .sop2, .sopc => {
            // A 32-bit read must not pin the neighbouring register's distinct
            // lifetime. Keep a conservative pair for every 64-bit opcode.
            const name = @tagName(inst.opcode);
            const width: usize = if (std.mem.indexOf(u8, name, "_b64") != null or
                std.mem.indexOf(u8, name, "_u64") != null) 2 else 1;
            for ([_]rdna2.Operand{ inst.src0, inst.src1, inst.src2, inst.src3 }) |source|
                include(&used, source, width);
            if (inst.opcode == .s_bitset0_b32 or inst.opcode == .s_bitset1_b32)
                include(&used, inst.dst, 1);
            if (inst.opcode == .s_bitset0_b64) include(&used, inst.dst, 2);
        },
        .sopk => {
            include(&used, inst.dst, 1); // MULK reads its destination.
            include(&used, inst.src0, 1);
        },
        .sopp => {
            include(&used, inst.src0, 2);
            include(&used, inst.src1, 2);
        },
        .smem => {
            switch (inst.opcode) {
                .s_load_dword,
                .s_load_dwordx2,
                .s_load_dwordx4,
                .s_load_dwordx8,
                .s_load_dwordx16,
                .s_buffer_load_dword,
                .s_buffer_load_dwordx2,
                .s_buffer_load_dwordx4,
                .s_buffer_load_dwordx8,
                .s_buffer_load_dwordx16,
                => {},
                else => return null,
            }
            const buffer = std.mem.startsWith(u8, @tagName(inst.opcode), "s_buffer_load");
            include(&used, inst.src0, if (buffer) 4 else 2);
            include(&used, inst.src1, 1);
            include(&used, inst.src2, 1);
        },
        .mubuf, .mtbuf => {
            include(&used, inst.src1, 4);
            include(&used, inst.src2, 1);
        },
        .mimg => {
            include(&used, inst.src1, 8);
            include(&used, inst.src2, 4);
        },
        .vop1, .vop2, .vop3, .vop3p, .vopc, .vintrp, .exp => {
            if (scalar.scalarWalkVisits(inst.*)) {
                for ([_]rdna2.Operand{ inst.src0, inst.src1, inst.src2, inst.src3 }) |source|
                    include(&used, source, 2);
            }
        },
        // Flat addresses, LDS/lane recovery and unknown families require
        // a richer proof; their complete existing walk remains in use.
        else => return null,
    }
    return used;
}

/// All control flow must move forward. A suffix union therefore includes every
/// possible later consumer, even across a skipped block. Definite overwrites
/// end a register lifetime only in a program without branches.
pub fn collect(allocator: std.mem.Allocator, instructions: []const rdna2.Instruction) ![]const u32 {
    var result: std.ArrayList(u32) = .empty;
    defer result.deinit(allocator);
    var used: u128 = ~((@as(u128, 1) << 104) - 1);
    const straight_line = for (instructions) |inst| {
        if (inst.opcode.isBranch()) break false;
    } else true;
    var cursor = instructions.len;
    while (cursor != 0) {
        cursor -= 1;
        const inst = &instructions[cursor];
        if (cursor + 1 < instructions.len and instructions[cursor + 1].pc <= inst.pc) return &.{};
        const inputs = readMask(inst) orelse return &.{};
        if (canDefer(inst, ~used)) try result.append(allocator, inst.pc);
        // With no branches, a definite overwrite ends the old register's
        // lifetime. Conditional programs retain the conservative suffix union.
        if (straight_line) used &= ~definiteWrites(inst);
        used |= inputs;
    }
    std.mem.reverse(u32, result.items);
    return result.toOwnedSlice(allocator);
}

fn definiteWrites(inst: *const rdna2.Instruction) u128 {
    var writes: u128 = 0;
    // Only scalar instructions with explicit, unconditional destinations.
    // Other families can only lose an opportunity here.
    switch (inst.family) {
        .smem => include(&writes, inst.dst, inst.data_words),
        .sop1, .sop2, .sopk => include(&writes, inst.dst, scalar.destinationWords(inst.opcode)),
        else => {},
    }
    return writes & ((@as(u128, 1) << 104) - 1);
}

/// Entry registers which host interpretation neither consumes nor modifies.
/// GPU-only SMEM descriptors are rebound from the current draw after replay.
pub fn passthroughRegisters(instructions: []const rdna2.Instruction, deferred: []const u32) u128 {
    if (deferred.len == 0) return 0;
    var unavailable: u128 = ~((@as(u128, 1) << 104) - 1);
    for (instructions) |*inst| {
        const inputs = readMask(inst) orelse return 0;
        // Vector memory instructions consume these registers only when the
        // renderer resolves their instruction-local descriptor/offset. They
        // do not feed host scalar arithmetic. Replay rebinds their untouched
        // entry words before resource preparation sees the checkpoint.
        const vector_resource = inst.family == .mubuf or inst.family == .mtbuf or inst.family == .mimg;
        if (!vector_resource and std.mem.indexOfScalar(u32, deferred, inst.pc) == null) unavailable |= inputs;
        include(&unavailable, inst.dst, @max(@as(usize, inst.data_words), 2));
        include(&unavailable, inst.dst2, 2);
    }
    return ~unavailable;
}

pub fn canDefer(inst: *const rdna2.Instruction, allowed: u128) bool {
    switch (inst.opcode) {
        .s_buffer_load_dword,
        .s_buffer_load_dwordx2,
        .s_buffer_load_dwordx4,
        .s_buffer_load_dwordx8,
        .s_buffer_load_dwordx16,
        => {},
        else => return false,
    }
    if (inst.dst.kind != .sgpr or inst.data_words == 0 or inst.data_words > 16 or
        @as(u32, inst.dst.reg) + inst.data_words > 104) return false;
    for (inst.dst.reg..inst.dst.reg + inst.data_words) |index|
        if (allowed & (@as(u128, 1) << @intCast(index)) == 0) return false;
    return true;
}

test "vector-only buffer proof retains resource control and scalar consumers" {
    const load = rdna2.Instruction{
        .pc = 0,
        .family = .smem,
        .opcode = .s_buffer_load_dwordx4,
        .dst = .{ .kind = .sgpr, .reg = 20 },
        .data_words = 4,
        .src0 = .{ .kind = .sgpr, .reg = 8 },
    };
    var code = [_]rdna2.Instruction{
        load,
        .{ .pc = 8, .family = .vop2, .opcode = .v_mul_f32, .dst = .{ .kind = .vgpr }, .src0 = .{ .kind = .sgpr, .reg = 20 } },
        .{ .pc = 12, .family = .sopp, .opcode = .s_endpgm },
    };
    const allowed = try collect(std.testing.allocator, &code);
    defer std.testing.allocator.free(allowed);
    try std.testing.expectEqualSlices(u32, &.{0}, allowed);
    code[1] = .{ .pc = 8, .family = .sopc, .opcode = .s_cmp_eq_u32, .src0 = .{ .kind = .sgpr, .reg = 19 } };
    const neighbour = try collect(std.testing.allocator, &code);
    defer std.testing.allocator.free(neighbour);
    try std.testing.expectEqualSlices(u32, &.{0}, neighbour);
    for ([_]rdna2.Instruction{
        .{ .family = .sopc, .opcode = .s_cmp_eq_u64, .src0 = .{ .kind = .sgpr, .reg = 19 } },
        .{ .family = .sopk, .opcode = .s_mulk_i32, .dst = .{ .kind = .sgpr, .reg = 20 } },
        .{ .family = .smem, .opcode = .s_load_dword, .src0 = .{ .kind = .sgpr, .reg = 20 } },
        .{ .family = .mubuf, .opcode = .buffer_load_dword, .src1 = .{ .kind = .sgpr, .reg = 17 } },
        .{ .family = .mtbuf, .opcode = .tbuffer_load_format_x, .src2 = .{ .kind = .sgpr, .reg = 20 } },
        .{ .family = .mimg, .opcode = .image_sample, .src1 = .{ .kind = .sgpr, .reg = 13 } },
        .{ .family = .mimg, .opcode = .image_sample, .src2 = .{ .kind = .sgpr, .reg = 17 } },
        .{ .family = .vop1, .opcode = .v_writelane_b32, .src0 = .{ .kind = .sgpr, .reg = 20 } },
        .{ .family = .vop1, .opcode = .v_movrels_b32 },
        .{ .family = .sop1, .opcode = .s_call_b64 },
        .{ .family = .sopp, .opcode = .s_branch, .branch_target = 0 },
        .{ .family = .sopp, .opcode = .s_cbranch_cdbgsys, .branch_target = 16 },
        .{ .family = .flat, .opcode = .flat_load_dword },
        .{ .family = .sop2, .opcode = .unsupported },
    }) |consumer| {
        code[1] = consumer;
        code[1].pc = 8;
        const rejected = try collect(std.testing.allocator, &code);
        defer std.testing.allocator.free(rejected);
        try std.testing.expectEqual(@as(usize, 0), rejected.len);
    }
    var pointer = load;
    pointer.opcode = .s_load_dwordx4;
    try std.testing.expect(!canDefer(&pointer, std.math.maxInt(u128)));

    // The entry USER_DATA value can be consumed before the load overwrites it.
    code[0] = .{ .pc = 0, .family = .sop1, .opcode = .s_mov_b32, .src0 = .{ .kind = .sgpr, .reg = 20 }, .dst = .{ .kind = .sgpr, .reg = 40 } };
    code[1] = load;
    code[1].pc = 4;
    const overwritten = try collect(std.testing.allocator, &code);
    defer std.testing.allocator.free(overwritten);
    try std.testing.expectEqualSlices(u32, &.{4}, overwritten);
}

test "straight-line deferral separates overwritten lifetimes but branches retain dependencies" {
    const a = std.testing.allocator;
    var code = [_]rdna2.Instruction{
        .{ .pc = 0, .word_count = 2, .family = .smem, .opcode = .s_buffer_load_dwordx2, .dst = .{ .kind = .sgpr, .reg = 20 }, .src0 = .{ .kind = .sgpr }, .data_words = 2 },
        .{ .pc = 8, .family = .vop2, .opcode = .v_mul_f32, .dst = .{ .kind = .vgpr }, .src0 = .{ .kind = .sgpr, .reg = 20 } },
        .{ .pc = 12, .family = .sop1, .opcode = .s_mov_b64, .dst = .{ .kind = .sgpr, .reg = 20 }, .src0 = .{ .kind = .integer_inline_constant, .value = 5 } },
        .{ .pc = 16, .family = .sopc, .opcode = .s_cmp_eq_u64, .src0 = .{ .kind = .sgpr, .reg = 20 } },
        .{ .pc = 20, .family = .sopp, .opcode = .s_endpgm },
    };
    const allowed = try collect(a, &code);
    defer a.free(allowed);
    try std.testing.expectEqualSlices(u32, &.{0}, allowed);
    try std.testing.expectEqual(@as(u128, 15), passthroughRegisters(&code, allowed) & 15);
    code[1] = .{ .pc = 8, .family = .sopp, .opcode = .s_cbranch_scc0, .branch_target = 16 };
    const conditional = try collect(a, &code);
    defer a.free(conditional);
    try std.testing.expectEqual(@as(usize, 0), conditional.len);
    code[1] = .{ .pc = 8, .family = .sopp, .opcode = .s_nop };
    code[2].opcode = .s_mov_b32;
    const partial = try collect(a, &code);
    defer a.free(partial);
    try std.testing.expectEqual(@as(usize, 0), partial.len);
    code[2].opcode = .s_bitset1_b32;
    code[3].opcode = .s_nop;
    code[3].family = .sopp;
    code[3].src0 = .{ .kind = .unknown };
    const bitset = try collect(a, &code);
    defer a.free(bitset);
    try std.testing.expectEqual(@as(usize, 0), bitset.len);
    code[2].opcode = .s_bitset0_b64;
    const bitset64 = try collect(a, &code);
    defer a.free(bitset64);
    try std.testing.expectEqual(@as(usize, 0), bitset64.len);
}
