// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! GFX10 vector ALU and interpolation instruction decoding.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");

const Instruction = instruction.Instruction;
pub const Error = instruction.Error;

fn vop1Opcode(id: u32) isa.Opcode {
    return switch (id) {
        0x00 => .v_nop,
        0x01 => .v_mov_b32,
        0x02 => .v_readfirstlane_b32,
        0x05 => .v_cvt_f32_i32,
        0x06 => .v_cvt_f32_u32,
        0x07 => .v_cvt_u32_f32,
        0x08 => .v_cvt_i32_f32,
        0x0a => .v_cvt_f16_f32,
        0x0b => .v_cvt_f32_f16,
        0x0c => .v_cvt_rpi_i32_f32,
        0x0d => .v_cvt_flr_i32_f32,
        0x11 => .v_cvt_f32_ubyte0,
        0x12 => .v_cvt_f32_ubyte1,
        0x13 => .v_cvt_f32_ubyte2,
        0x14 => .v_cvt_f32_ubyte3,
        0x20 => .v_fract_f32,
        0x21 => .v_trunc_f32,
        0x22 => .v_ceil_f32,
        0x23 => .v_rndne_f32,
        0x24 => .v_floor_f32,
        0x25 => .v_exp_f32,
        0x27 => .v_log_f32,
        0x2a, 0x2b => .v_rcp_f32,
        0x2e => .v_rsq_f32,
        0x33 => .v_sqrt_f32,
        0x35 => .v_sin_f32,
        0x36 => .v_cos_f32,
        0x37 => .v_not_b32,
        0x38 => .v_bfrev_b32,
        0x39 => .v_ffbh_u32,
        0x3a => .v_ffbl_b32,
        else => .unsupported,
    };
}

fn vop2Opcode(id: u32) isa.Opcode {
    return switch (id) {
        0x01 => .v_cndmask_b32,
        0x03 => .v_add_f32,
        0x04 => .v_sub_f32,
        0x05 => .v_subrev_f32,
        0x08 => .v_mul_f32,
        0x0f => .v_min_f32,
        0x10 => .v_max_f32,
        0x11 => .v_min_i32,
        0x12 => .v_max_i32,
        0x13 => .v_min_u32,
        0x14 => .v_max_u32,
        0x15 => .v_lshr_b32,
        0x16 => .v_lshrrev_b32,
        0x17 => .v_ashr_i32,
        0x18 => .v_ashrrev_i32,
        0x19 => .v_lshl_b32,
        0x1a => .v_lshlrev_b32,
        0x1b => .v_and_b32,
        0x1c => .v_or_b32,
        0x1d => .v_xor_b32,
        0x1e => .v_xnor_b32,
        0x1f, 0x2b => .v_mac_f32,
        0x22 => .v_bcnt_u32_b32,
        0x23 => .v_mbcnt_lo_u32_b32,
        0x24 => .v_mbcnt_hi_u32_b32,
        0x25 => .v_add_nc_u32,
        0x26 => .v_sub_nc_u32,
        0x27 => .v_subrev_nc_u32,
        0x28 => .v_addc_u32,
        0x32 => .v_add_f16,
        0x33 => .v_sub_f16,
        0x34 => .v_subrev_f16,
        0x35 => .v_mul_f16,
        0x36 => .v_fmac_f16,
        0x39 => .v_max_f16,
        0x3a => .v_min_f16,
        else => .unsupported,
    };
}

fn vopcOpcode(id: u32) isa.Opcode {
    return switch (id) {
        0x00 => .v_cmp_f_f32,
        0x01 => .v_cmp_lt_f32,
        0x02 => .v_cmp_eq_f32,
        0x03 => .v_cmp_le_f32,
        0x04 => .v_cmp_gt_f32,
        0x05 => .v_cmp_lg_f32,
        0x06 => .v_cmp_ge_f32,
        0x07 => .v_cmp_o_f32,
        0x08 => .v_cmp_u_f32,
        0x0f => .v_cmp_tru_f32,
        0x11 => .v_cmpx_lt_f32,
        0x12 => .v_cmpx_eq_f32,
        0x13 => .v_cmpx_le_f32,
        0x14 => .v_cmpx_gt_f32,
        0x15 => .v_cmpx_lg_f32,
        0x16 => .v_cmpx_ge_f32,
        0x81 => .v_cmp_lt_i32,
        0x82 => .v_cmp_eq_i32,
        0x83 => .v_cmp_le_i32,
        0x84 => .v_cmp_gt_i32,
        0x85 => .v_cmp_ne_i32,
        0x86 => .v_cmp_ge_i32,
        0x91 => .v_cmpx_lt_i32,
        0x92 => .v_cmpx_eq_i32,
        0xc1 => .v_cmp_lt_u32,
        0xc2 => .v_cmp_eq_u32,
        0xc3 => .v_cmp_le_u32,
        0xc4 => .v_cmp_gt_u32,
        0xc5 => .v_cmp_ne_u32,
        0xc6 => .v_cmp_ge_u32,
        0xd1 => .v_cmpx_lt_u32,
        0xd2 => .v_cmpx_eq_u32,
        else => .unsupported,
    };
}

fn isCompareExec(op: isa.Opcode) bool {
    return switch (op) {
        .v_cmpx_lt_f32, .v_cmpx_eq_f32, .v_cmpx_le_f32, .v_cmpx_gt_f32, .v_cmpx_lg_f32, .v_cmpx_ge_f32, .v_cmpx_lt_i32, .v_cmpx_eq_i32, .v_cmpx_lt_u32, .v_cmpx_eq_u32 => true,
        else => false,
    };
}

fn modifierLength(inst: *Instruction, code: []const u32, word_index: u32, src0: u32) Error!bool {
    if (src0 != 249 and src0 != 250) return false;
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    inst.setRawWords(code, word_index, 2);
    inst.unsupported_reason = if (src0 == 249)
        "SDWA modifiers are decoded structurally but not lowered"
    else
        "DPP modifiers are decoded structurally but not lowered";
    inst.opcode = .unsupported;
    return true;
}

pub fn decodeVop2(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const id = (word >> 25) & 0x3f;
    if (id == 0x3e) return decodeVopc(pc, code, word_index);
    if (id == 0x3f) return decodeVop1(pc, code, word_index);

    var inst = Instruction{ .pc = pc, .word = word, .family = .vop2, .opcode_id = id, .opcode = vop2Opcode(id) };
    inst.setRawWords(code, word_index, 1);
    const src0 = word & 0x1ff;
    if (try modifierLength(&inst, code, word_index, src0)) return inst;
    inst.dst = try operand.decodeVectorGpr((word >> 17) & 0xff);
    inst.src0 = try operand.decodeScalarSource(src0);
    inst.src1 = try operand.decodeVectorGpr((word >> 9) & 0xff);
    inst.src_count = 2;
    if (inst.opcode == .unsupported) inst.unsupported_reason = "VOP2 opcode is not implemented";
    try inst.readLiteralOperands(code, word_index);
    return inst;
}

pub fn decodeVop1(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const id = (word >> 9) & 0xff;
    var inst = Instruction{ .pc = pc, .word = word, .family = .vop1, .opcode_id = id, .opcode = vop1Opcode(id) };
    inst.setRawWords(code, word_index, 1);
    const src0 = word & 0x1ff;
    if (try modifierLength(&inst, code, word_index, src0)) return inst;
    if (inst.opcode == .v_nop) {
        inst.dst.kind = .null;
        return inst;
    }
    inst.dst = if (inst.opcode == .v_readfirstlane_b32)
        try operand.decodeScalarDestination((word >> 17) & 0xff)
    else
        try operand.decodeVectorGpr((word >> 17) & 0xff);
    inst.src0 = try operand.decodeScalarSource(src0);
    inst.src_count = 1;
    if (inst.opcode == .unsupported) inst.unsupported_reason = "VOP1 opcode is not implemented";
    try inst.readLiteralOperands(code, word_index);
    return inst;
}

pub fn decodeVopc(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const id = (word >> 17) & 0xff;
    const op = vopcOpcode(id);
    var inst = Instruction{ .pc = pc, .word = word, .family = .vopc, .opcode_id = id, .opcode = op };
    inst.setRawWords(code, word_index, 1);
    const src0 = word & 0x1ff;
    if (try modifierLength(&inst, code, word_index, src0)) return inst;
    inst.dst.kind = if (isCompareExec(op)) .exec_lo else .vcc_lo;
    inst.src0 = try operand.decodeScalarSource(src0);
    inst.src1 = try operand.decodeVectorGpr((word >> 9) & 0xff);
    inst.src_count = 2;
    if (op == .unsupported) inst.unsupported_reason = "VOPC opcode is not implemented";
    try inst.readLiteralOperands(code, word_index);
    return inst;
}

fn nativeVop3Opcode(id: u32) isa.Opcode {
    return switch (id) {
        0x141 => .v_mad_f32,
        0x148 => .v_bfe_u32,
        0x149 => .v_bfe_i32,
        0x14a => .v_bfi_b32,
        0x14b => .v_fma_f32,
        0x14e => .v_alignbit_b32,
        0x151 => .v_min3_f32,
        0x154 => .v_max3_f32,
        0x157 => .v_med3_f32,
        0x169 => .v_mul_lo_u32,
        0x16a => .v_mul_hi_u32,
        0x16b => .v_mul_lo_i32,
        0x16c => .v_mul_hi_i32,
        0x178 => .v_xor3_b32,
        0x345 => .v_add3_u32,
        0x36f => .v_lshl_or_b32,
        0x371 => .v_and_or_b32,
        0x372 => .v_or3_b32,
        0x360 => .v_readlane_b32,
        0x361 => .v_writelane_b32,
        else => .unsupported,
    };
}

fn vop3Opcode(id: u32) isa.Opcode {
    if (id <= 0xff) return vopcOpcode(id);
    if (id >= 0x100 and id <= 0x13f) return vop2Opcode(id - 0x100);
    if (id >= 0x180 and id <= 0x1ff) return vop1Opcode(id - 0x180);
    return nativeVop3Opcode(id);
}

pub fn decodeVop3(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const id = (word0 >> 16) & 0x3ff;
    const op = vop3Opcode(id);
    var inst = Instruction{ .pc = pc, .word = word0, .family = .vop3, .opcode_id = id, .opcode = op };
    inst.setRawWords(code, word_index, 2);
    if (id <= 0xff) {
        inst.dst.kind = if (isCompareExec(op)) .exec_lo else .vcc_lo;
    } else if (op == .v_readlane_b32) {
        inst.dst = try operand.decodeScalarDestination(word0 & 0xff);
    } else {
        inst.dst = try operand.decodeVectorGpr(word0 & 0xff);
    }
    inst.src0 = try operand.decodeScalarSource(word1 & 0x1ff);
    inst.src_count = if (id >= 0x180 and id <= 0x1ff) 1 else if (id <= 0x13f) 2 else 3;
    if (inst.src_count >= 2) inst.src1 = try operand.decodeScalarSource((word1 >> 9) & 0x1ff);
    if (inst.src_count >= 3) inst.src2 = try operand.decodeScalarSource((word1 >> 18) & 0x1ff);
    const abs = (word0 >> 8) & 7;
    const neg = (word1 >> 29) & 7;
    const sources = [_]*operand.Operand{ &inst.src0, &inst.src1, &inst.src2 };
    for (sources, 0..) |src, i| {
        if (i >= inst.src_count) break;
        src.absolute = abs & (@as(u32, 1) << @intCast(i)) != 0;
        src.negate = neg & (@as(u32, 1) << @intCast(i)) != 0;
    }
    inst.dst.clamp = (word0 >> 15) & 1 != 0;
    inst.dst.omod = @intCast((word1 >> 27) & 3);
    if (op == .unsupported) inst.unsupported_reason = "VOP3 opcode is not implemented";
    try inst.readLiteralOperands(code, word_index);
    return inst;
}

fn vop3pOpcode(id: u32) isa.Opcode {
    return switch (id) {
        0x02 => .v_pk_add_i16,
        0x03 => .v_pk_sub_i16,
        0x0a => .v_pk_add_u16,
        0x0b => .v_pk_sub_u16,
        0x0e => .v_pk_fma_f16,
        0x0f => .v_pk_add_f16,
        0x10 => .v_pk_mul_f16,
        0x20 => .v_fma_f32,
        0x21 => .v_mad_mixlo_f16,
        0x22 => .v_mad_mixhi_f16,
        else => .unsupported,
    };
}

pub fn decodeVop3p(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const id = (word0 >> 16) & 0x7f;
    var inst = Instruction{ .pc = pc, .word = word0, .family = .vop3p, .opcode_id = id, .opcode = vop3pOpcode(id) };
    inst.setRawWords(code, word_index, 2);
    inst.dst = try operand.decodeVectorGpr(word0 & 0xff);
    inst.src0 = try operand.decodeScalarSource(word1 & 0x1ff);
    inst.src1 = try operand.decodeScalarSource((word1 >> 9) & 0x1ff);
    inst.src2 = try operand.decodeScalarSource((word1 >> 18) & 0x1ff);
    inst.src_count = 3;
    inst.dst.clamp = (word0 >> 15) & 1 != 0;
    if (inst.opcode == .unsupported) inst.unsupported_reason = "VOP3P opcode is not implemented";
    try inst.readLiteralOperands(code, word_index);
    return inst;
}

pub fn decodeVintrp(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const id = (word >> 16) & 3;
    const op: isa.Opcode = switch (id) {
        0 => .v_interp_p1_f32,
        1 => .v_interp_p2_f32,
        2 => .v_interp_mov_f32,
        else => .unsupported,
    };
    var inst = Instruction{ .pc = pc, .word = word, .family = .vintrp, .opcode_id = id, .opcode = op };
    inst.setRawWords(code, word_index, 1);
    inst.dst = try operand.decodeVectorGpr((word >> 18) & 0xff);
    inst.src0 = if (op == .v_interp_mov_f32)
        .{ .kind = .integer_inline_constant, .value = word & 3, .signed_val = @intCast(word & 3) }
    else
        try operand.decodeVectorGpr(word & 0xff);
    inst.src1 = .{ .kind = .integer_inline_constant, .value = (word >> 10) & 0x3f, .signed_val = @intCast((word >> 10) & 0x3f) };
    inst.src2 = .{ .kind = .integer_inline_constant, .value = (word >> 8) & 3, .signed_val = @intCast((word >> 8) & 3) };
    inst.src_count = 3;
    if (op == .unsupported) inst.unsupported_reason = "VINTRP opcode is not implemented";
    return inst;
}

test "VOP2 is one word and decodes vector operands" {
    const code = [_]u32{(@as(u32, 0x03) << 25) | (@as(u32, 7) << 17) | (@as(u32, 2) << 9) | 256 + 1};
    const inst = try decodeVop2(0, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_add_f32, inst.opcode);
    try std.testing.expectEqual(@as(u32, 7), inst.dst.reg);
    try std.testing.expectEqual(@as(u32, 1), inst.src0.reg);
    try std.testing.expectEqual(@as(u32, 2), inst.src1.reg);
}

test "VOP3 retains both encoding words and modifiers" {
    const code = [_]u32{ 0xd14b_8003, 0x0406_0504 };
    const inst = try decodeVop3(0x20, &code, 0);
    try std.testing.expectEqual(isa.Family.vop3, inst.family);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
    try std.testing.expect(inst.dst.clamp);
}

test "truncated VOP3 is rejected" {
    const code = [_]u32{0xd14b_0000};
    try std.testing.expectError(Error.TruncatedInstruction, decodeVop3(0, &code, 0));
}
