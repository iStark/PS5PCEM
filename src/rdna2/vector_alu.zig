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
        0x50 => .v_cvt_f16_u16,
        0x51 => .v_cvt_f16_i16,
        0x52 => .v_cvt_u16_f16,
        0x53 => .v_cvt_i16_f16,
        0x54 => .v_rcp_f16,
        0x55 => .v_sqrt_f16,
        0x56 => .v_rsq_f16,
        0x57 => .v_log_f16,
        0x58 => .v_exp_f16,
        0x5b => .v_floor_f16,
        0x5c => .v_ceil_f16,
        0x5d => .v_trunc_f16,
        0x5e => .v_rndne_f16,
        else => .unsupported,
    };
}

fn vop2Opcode(id: u32) isa.Opcode {
    return switch (id) {
        0x01 => .v_cndmask_b32,
        0x02 => .v_dot2c_f32_f16,
        0x03 => .v_add_f32,
        0x04 => .v_sub_f32,
        0x05 => .v_subrev_f32,
        0x08 => .v_mul_f32,
        0x09 => .v_mul_i32_i24,
        0x0b => .v_mul_u32_u24,
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
        0x20, 0x2c => .v_madmk_f32,
        0x21, 0x2d => .v_madak_f32,
        0x22 => .v_bcnt_u32_b32,
        0x23 => .v_mbcnt_lo_u32_b32,
        0x24 => .v_mbcnt_hi_u32_b32,
        0x25 => .v_add_nc_u32,
        0x26 => .v_sub_nc_u32,
        0x27 => .v_subrev_nc_u32,
        0x28 => .v_addc_u32,
        0x2f => .v_cvt_pkrtz_f16_f32,
        0x32 => .v_add_f16,
        0x33 => .v_sub_f16,
        0x34 => .v_subrev_f16,
        0x35 => .v_mul_f16,
        0x36 => .v_fmac_f16,
        0x37 => .v_fmamk_f16,
        0x38 => .v_fmaak_f16,
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
        0x09 => .v_cmp_nge_f32,
        0x0a => .v_cmp_nlg_f32,
        0x0b => .v_cmp_ngt_f32,
        0x0c => .v_cmp_nle_f32,
        0x0d => .v_cmp_neq_f32,
        0x0e => .v_cmp_nlt_f32,
        0x0f => .v_cmp_tru_f32,
        0x10 => .v_cmpx_f_f32,
        0x11 => .v_cmpx_lt_f32,
        0x12 => .v_cmpx_eq_f32,
        0x13 => .v_cmpx_le_f32,
        0x14 => .v_cmpx_gt_f32,
        0x15 => .v_cmpx_lg_f32,
        0x16 => .v_cmpx_ge_f32,
        0x17 => .v_cmpx_o_f32,
        0x18 => .v_cmpx_u_f32,
        0x19 => .v_cmpx_nge_f32,
        0x1a => .v_cmpx_nlg_f32,
        0x1b => .v_cmpx_ngt_f32,
        0x1c => .v_cmpx_nle_f32,
        0x1d => .v_cmpx_neq_f32,
        0x1e => .v_cmpx_nlt_f32,
        0x1f => .v_cmpx_tru_f32,
        0x81 => .v_cmp_lt_i32,
        0x82 => .v_cmp_eq_i32,
        0x83 => .v_cmp_le_i32,
        0x84 => .v_cmp_gt_i32,
        0x85 => .v_cmp_ne_i32,
        0x86 => .v_cmp_ge_i32,
        0x91 => .v_cmpx_lt_i32,
        0x92 => .v_cmpx_eq_i32,
        0x93 => .v_cmpx_le_i32,
        0x94 => .v_cmpx_gt_i32,
        0x95 => .v_cmpx_ne_i32,
        0x96 => .v_cmpx_ge_i32,
        0xc1 => .v_cmp_lt_u32,
        0xc2 => .v_cmp_eq_u32,
        0xc3 => .v_cmp_le_u32,
        0xc4 => .v_cmp_gt_u32,
        0xc5 => .v_cmp_ne_u32,
        0xc6 => .v_cmp_ge_u32,
        0xd1 => .v_cmpx_lt_u32,
        0xd2 => .v_cmpx_eq_u32,
        0xd3 => .v_cmpx_le_u32,
        0xd4 => .v_cmpx_gt_u32,
        0xd5 => .v_cmpx_ne_u32,
        0xd6 => .v_cmpx_ge_u32,
        else => .unsupported,
    };
}

fn isCompareExec(op: isa.Opcode) bool {
    return switch (op) {
        .v_cmpx_f_f32,
        .v_cmpx_lt_f32,
        .v_cmpx_eq_f32,
        .v_cmpx_le_f32,
        .v_cmpx_gt_f32,
        .v_cmpx_lg_f32,
        .v_cmpx_ge_f32,
        .v_cmpx_o_f32,
        .v_cmpx_u_f32,
        .v_cmpx_nge_f32,
        .v_cmpx_nlg_f32,
        .v_cmpx_ngt_f32,
        .v_cmpx_nle_f32,
        .v_cmpx_neq_f32,
        .v_cmpx_nlt_f32,
        .v_cmpx_tru_f32,
        .v_cmpx_lt_i32,
        .v_cmpx_eq_i32,
        .v_cmpx_le_i32,
        .v_cmpx_gt_i32,
        .v_cmpx_ne_i32,
        .v_cmpx_ge_i32,
        .v_cmpx_lt_u32,
        .v_cmpx_eq_u32,
        .v_cmpx_le_u32,
        .v_cmpx_gt_u32,
        .v_cmpx_ne_u32,
        .v_cmpx_ge_u32,
        => true,
        else => false,
    };
}

fn requireModifier(inst: *Instruction, code: []const u32, word_index: u32) Error!u32 {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    inst.setRawWords(code, word_index, 2);
    return code[word_index + 1];
}

fn sdwaSource(code: u32, scalar: bool) Error!operand.Operand {
    return operand.decodeScalarSource(code + if (scalar) @as(u32, 0) else 256);
}

fn applySdwaSource(op: *operand.Operand, modifier: u32, shift: u5) void {
    op.sdwa_sel = @intCast((modifier >> shift) & 7);
    op.sdwa_sext = (modifier >> (shift + 3)) & 1 != 0;
    op.negate = (modifier >> (shift + 4)) & 1 != 0;
    op.absolute = (modifier >> (shift + 5)) & 1 != 0;
}

fn applyDppSource(op: *operand.Operand, modifier: u32) void {
    op.negate = (modifier >> 20) & 1 != 0;
    op.absolute = (modifier >> 21) & 1 != 0;
    op.dpp = true;
    op.dpp_ctrl = @intCast((modifier >> 8) & 0x1ff);
    op.dpp_fetch_inactive = (modifier >> 18) & 1 != 0;
    op.dpp_bound_ctrl = (modifier >> 19) & 1 != 0;
    op.dpp_bank_mask = @intCast((modifier >> 24) & 0xf);
    op.dpp_row_mask = @intCast((modifier >> 28) & 0xf);
}

fn decodeVop1Modifier(inst: *Instruction, code: []const u32, word_index: u32, escape: u32, vdst: u32) Error!bool {
    if (escape != 249 and escape != 250) return false;
    const modifier = try requireModifier(inst, code, word_index);
    inst.dst = if (inst.opcode == .v_readfirstlane_b32)
        try operand.decodeScalarDestination(vdst)
    else
        try operand.decodeVectorGpr(vdst);
    inst.src0 = try sdwaSource(modifier & 0xff, escape == 249 and (modifier >> 23) & 1 != 0);
    inst.src_count = 1;
    if (escape == 249) {
        inst.dst.sdwa_sel = @intCast((modifier >> 8) & 7);
        inst.dst.sdwa_dst_unused = @intCast((modifier >> 11) & 3);
        inst.dst.clamp = (modifier >> 13) & 1 != 0;
        inst.dst.omod = @intCast((modifier >> 14) & 3);
        applySdwaSource(&inst.src0, modifier, 16);
        if (inst.dst.sdwa_sel == 7 or inst.src0.sdwa_sel == 7) {
            inst.setUnsupported(.vop1, inst.opcode_id, "VOP1 SDWA selector is invalid");
        }
    } else {
        // DPP sources are always VGPRs; reinterpret the low byte accordingly.
        inst.src0 = try operand.decodeVectorGpr(modifier & 0xff);
        applyDppSource(&inst.src0, modifier);
    }
    try inst.readLiteralOperands(code, word_index);
    return true;
}

fn decodeVop2Modifier(inst: *Instruction, code: []const u32, word_index: u32, escape: u32, vdst: u32, vsrc1: u32) Error!bool {
    if (escape != 249 and escape != 250) return false;
    const modifier = try requireModifier(inst, code, word_index);
    inst.dst = try operand.decodeVectorGpr(vdst);
    if (escape == 249) {
        inst.src0 = try sdwaSource(modifier & 0xff, (modifier >> 23) & 1 != 0);
        inst.src1 = try sdwaSource(vsrc1, (modifier >> 31) & 1 != 0);
        inst.dst.sdwa_sel = @intCast((modifier >> 8) & 7);
        inst.dst.sdwa_dst_unused = @intCast((modifier >> 11) & 3);
        inst.dst.clamp = (modifier >> 13) & 1 != 0;
        inst.dst.omod = @intCast((modifier >> 14) & 3);
        applySdwaSource(&inst.src0, modifier, 16);
        applySdwaSource(&inst.src1, modifier, 24);
        if (inst.dst.sdwa_sel == 7 or inst.src0.sdwa_sel == 7 or inst.src1.sdwa_sel == 7) {
            inst.setUnsupported(.vop2, inst.opcode_id, "VOP2 SDWA selector is invalid");
        }
    } else {
        inst.src0 = try operand.decodeVectorGpr(modifier & 0xff);
        inst.src1 = try operand.decodeVectorGpr(vsrc1);
        applyDppSource(&inst.src0, modifier);
        inst.src1.negate = (modifier >> 22) & 1 != 0;
        inst.src1.absolute = (modifier >> 23) & 1 != 0;
    }
    finalizeVop2(inst);
    try inst.readLiteralOperands(code, word_index);
    return true;
}

fn decodeVopcModifier(inst: *Instruction, code: []const u32, word_index: u32, escape: u32, vsrc1: u32) Error!bool {
    if (escape != 249 and escape != 250) return false;
    const modifier = try requireModifier(inst, code, word_index);
    if (escape == 249) {
        inst.src0 = try sdwaSource(modifier & 0xff, (modifier >> 23) & 1 != 0);
        inst.src1 = try sdwaSource(vsrc1, (modifier >> 31) & 1 != 0);
        inst.dst = if (isCompareExec(inst.opcode))
            .{ .kind = .exec_lo }
        else if ((modifier >> 15) & 1 == 0)
            .{ .kind = .vcc_lo }
        else
            try operand.decodeScalarDestination((modifier >> 8) & 0x7f);
        applySdwaSource(&inst.src0, modifier, 16);
        applySdwaSource(&inst.src1, modifier, 24);
        if (inst.src0.sdwa_sel == 7 or inst.src1.sdwa_sel == 7) {
            inst.setUnsupported(.vopc, inst.opcode_id, "VOPC SDWA selector is invalid");
        }
    } else {
        inst.src0 = try operand.decodeVectorGpr(modifier & 0xff);
        inst.src1 = try operand.decodeVectorGpr(vsrc1);
        inst.dst.kind = if (isCompareExec(inst.opcode)) .exec_lo else .vcc_lo;
        applyDppSource(&inst.src0, modifier);
        inst.src1.negate = (modifier >> 22) & 1 != 0;
        inst.src1.absolute = (modifier >> 23) & 1 != 0;
    }
    inst.src_count = 2;
    try inst.readLiteralOperands(code, word_index);
    return true;
}

fn finalizeVop2(inst: *Instruction) void {
    switch (inst.opcode) {
        .v_madmk_f32, .v_fmamk_f16 => {
            inst.src2 = inst.src1;
            inst.src1 = .{ .kind = .literal_constant };
            inst.src_count = 3;
        },
        .v_madak_f32, .v_fmaak_f16 => {
            inst.src2 = .{ .kind = .literal_constant };
            inst.src_count = 3;
        },
        .v_addc_u32 => {
            inst.dst2.kind = .vcc_lo;
            inst.src2.kind = .vcc_lo;
            inst.src_count = 3;
        },
        .v_cndmask_b32 => {
            inst.src2.kind = .vcc_lo;
            inst.src_count = 3;
        },
        else => inst.src_count = 2,
    }
}

pub fn decodeVop2(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const id = (word >> 25) & 0x3f;
    if (id == 0x3e) return decodeVopc(pc, code, word_index);
    if (id == 0x3f) return decodeVop1(pc, code, word_index);

    var inst = Instruction{ .pc = pc, .word = word, .family = .vop2, .opcode_id = id, .opcode = vop2Opcode(id) };
    inst.setRawWords(code, word_index, 1);
    const src0 = word & 0x1ff;
    if (try decodeVop2Modifier(&inst, code, word_index, src0, (word >> 17) & 0xff, (word >> 9) & 0xff)) return inst;
    inst.dst = try operand.decodeVectorGpr((word >> 17) & 0xff);
    inst.src0 = try operand.decodeScalarSource(src0);
    inst.src1 = try operand.decodeVectorGpr((word >> 9) & 0xff);
    finalizeVop2(&inst);
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
    if (try decodeVop1Modifier(&inst, code, word_index, src0, (word >> 17) & 0xff)) return inst;
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
    if (try decodeVopcModifier(&inst, code, word_index, src0, (word >> 9) & 0xff)) return inst;
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
        0x345 => .v_xad_u32,
        0x346 => .v_lshl_add_u32,
        0x347 => .v_add_lshl_u32,
        0x36d => .v_add3_u32,
        0x36f => .v_lshl_or_b32,
        0x371 => .v_and_or_b32,
        0x372 => .v_or3_b32,
        0x360 => .v_readlane_b32,
        0x361 => .v_writelane_b32,
        // RDNA2's ordered min/max encodings.  LLVM exposes the same opcode
        // numbers as V_MINIMUM/V_MAXIMUM on newer targets; PS5 shaders use
        // them for finite clamp bounds in export programs.
        0x365 => .v_min_f32,
        0x366 => .v_max_f32,
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
    inst.src_count = if (id >= 0x180 and id <= 0x1ff)
        1
    else if (id <= 0x13f or id == 0x365 or id == 0x366)
        2
    else
        3;
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

test "native VOP3 shift-add opcode uses three sources" {
    const code = [_]u32{ 0xd746_0000, 0x0401_0c08 };
    const inst = try decodeVop3(4, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_lshl_add_u32, inst.opcode);
    try std.testing.expectEqual(@as(u32, 3), inst.src_count);
    try std.testing.expectEqual(isa.OperandKind.sgpr, inst.src0.kind);
    try std.testing.expectEqual(@as(u32, 8), inst.src0.reg);
    try std.testing.expectEqual(@as(i32, 6), inst.src1.signed_val);
    try std.testing.expectEqual(isa.OperandKind.vgpr, inst.src2.kind);
    try std.testing.expectEqual(@as(u32, 0), inst.src2.reg);
}

test "native VOP3 ordered float min max use two sources" {
    const minimum = try decodeVop3(0, &.{ 0xd765_0007, 0x0001_00c1 }, 0);
    try std.testing.expectEqual(isa.Opcode.v_min_f32, minimum.opcode);
    try std.testing.expectEqual(@as(u32, 2), minimum.src_count);
    try std.testing.expectEqual(@as(i32, -1), minimum.src0.signed_val);
    try std.testing.expectEqual(@as(i32, 0), minimum.src1.signed_val);

    const maximum = try decodeVop3(8, &.{ 0xd766_0009, 0x0001_00c1 }, 0);
    try std.testing.expectEqual(isa.Opcode.v_max_f32, maximum.opcode);
    try std.testing.expectEqual(@as(u32, 2), maximum.src_count);
}

test "truncated VOP3 is rejected" {
    const code = [_]u32{0xd14b_0000};
    try std.testing.expectError(Error.TruncatedInstruction, decodeVop3(0, &code, 0));
}

test "VOP2 SDWA retains selectors and scalar bank bits" {
    const word = (@as(u32, 0x03) << 25) | (@as(u32, 9) << 17) | (@as(u32, 7) << 9) | 249;
    const modifier = @as(u32, 5) |
        (@as(u32, 6) << 8) |
        (@as(u32, 4) << 16) |
        (@as(u32, 1) << 19) |
        (@as(u32, 1) << 20) |
        (@as(u32, 5) << 24) |
        (@as(u32, 1) << 29) |
        (@as(u32, 1) << 31);
    const code = [_]u32{ word, modifier };
    const inst = try decodeVop2(0x10, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_add_f32, inst.opcode);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
    try std.testing.expectEqual(isa.OperandKind.vgpr, inst.src0.kind);
    try std.testing.expectEqual(@as(u32, 5), inst.src0.reg);
    try std.testing.expectEqual(@as(u3, 4), inst.src0.sdwa_sel);
    try std.testing.expect(inst.src0.sdwa_sext);
    try std.testing.expect(inst.src0.negate);
    try std.testing.expectEqual(isa.OperandKind.sgpr, inst.src1.kind);
    try std.testing.expectEqual(@as(u32, 7), inst.src1.reg);
    try std.testing.expectEqual(@as(u3, 5), inst.src1.sdwa_sel);
    try std.testing.expect(inst.src1.absolute);
}

test "VOP2 SDWA conditional mask keeps implicit VCC and integer negate" {
    const code = [_]u32{ 0x020c_0cf9, 0x1606_0606 };
    const inst = try decodeVop2(0xc50, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_cndmask_b32, inst.opcode);
    try std.testing.expectEqual(@as(u32, 3), inst.src_count);
    try std.testing.expectEqual(isa.OperandKind.vcc_lo, inst.src2.kind);
    try std.testing.expect(inst.src1.negate);
}

test "VOP1 DPP retains lane control and masks" {
    const word = (@as(u32, 0x3f) << 25) | (@as(u32, 2) << 17) | (@as(u32, 1) << 9) | 250;
    const modifier = @as(u32, 3) |
        (@as(u32, 0x142) << 8) |
        (@as(u32, 1) << 18) |
        (@as(u32, 1) << 19) |
        (@as(u32, 1) << 20) |
        (@as(u32, 0xa) << 24) |
        (@as(u32, 5) << 28);
    const code = [_]u32{ word, modifier };
    const inst = try decodeVop1(0, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_mov_b32, inst.opcode);
    try std.testing.expect(inst.src0.dpp);
    try std.testing.expectEqual(@as(u9, 0x142), inst.src0.dpp_ctrl);
    try std.testing.expectEqual(@as(u4, 0xa), inst.src0.dpp_bank_mask);
    try std.testing.expectEqual(@as(u4, 5), inst.src0.dpp_row_mask);
    try std.testing.expect(inst.src0.dpp_fetch_inactive);
    try std.testing.expect(inst.src0.dpp_bound_ctrl);
    try std.testing.expect(inst.src0.negate);
}

test "VOPC SDWA may select an explicit scalar destination" {
    const word = (@as(u32, 0x3e) << 25) | (@as(u32, 2) << 17) | (@as(u32, 4) << 9) | 249;
    const modifier = @as(u32, 1) |
        (@as(u32, 12) << 8) |
        (@as(u32, 1) << 15) |
        (@as(u32, 6) << 16) |
        (@as(u32, 6) << 24);
    const code = [_]u32{ word, modifier };
    const inst = try decodeVopc(0, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_cmp_eq_f32, inst.opcode);
    try std.testing.expectEqual(isa.OperandKind.sgpr, inst.dst.kind);
    try std.testing.expectEqual(@as(u32, 12), inst.dst.reg);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
}

test "VOPC SDWA decodes GFX10 CMPX NLE predicate" {
    const code = [_]u32{ 0x7c38_d4f9, 0x8606_000a };
    const inst = try decodeVopc(0xb3c, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_cmpx_nle_f32, inst.opcode);
    try std.testing.expectEqual(isa.OperandKind.exec_lo, inst.dst.kind);
    try std.testing.expectEqual(isa.OperandKind.vgpr, inst.src0.kind);
    try std.testing.expectEqual(@as(u32, 10), inst.src0.reg);
    try std.testing.expectEqual(isa.OperandKind.vcc_lo, inst.src1.kind);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
}

test "VOPC decodes unsigned CMPX not-equal predicate" {
    const code = [_]u32{0x7daa_0e83};
    const inst = try decodeVopc(0x1710, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_cmpx_ne_u32, inst.opcode);
    try std.testing.expectEqual(isa.OperandKind.exec_lo, inst.dst.kind);
    try std.testing.expectEqual(@as(u32, 1), inst.word_count);
}

test "VOP2 mad literal operands keep their three-source order" {
    const word = (@as(u32, 0x20) << 25) | (@as(u32, 6) << 17) | (@as(u32, 4) << 9) | 256 + 3;
    const code = [_]u32{ word, 0x3f00_0000 };
    const inst = try decodeVop2(0, &code, 0);
    try std.testing.expectEqual(isa.Opcode.v_madmk_f32, inst.opcode);
    try std.testing.expectEqual(@as(u32, 3), inst.src_count);
    try std.testing.expectEqual(@as(u32, 3), inst.src0.reg);
    try std.testing.expectEqual(@as(u32, 0x3f00_0000), inst.src1.value);
    try std.testing.expectEqual(@as(u32, 4), inst.src2.reg);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
}
