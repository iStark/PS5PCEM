// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Decoding of the RDNA2 scalar families: SOP1, SOP2, SOPK, SOPC, SOPP.
//!
//! The opcode-to-mnemonic tables are expanded into direct-index arrays at
//! compile time (`buildTable`), so a lookup is a single indexed load rather than
//! a linear scan over a list of pairs.

const std = @import("std");
const isa = @import("isa.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");

const Opcode = isa.Opcode;
const Instruction = instruction.Instruction;
const Error = instruction.Error;

const Entry = struct { u32, Opcode };

/// Expands a list of pairs into a direct-index array.
/// Everything happens at compile time; only the array survives into the binary.
fn buildTable(comptime size: usize, comptime entries: []const Entry) [size]Opcode {
    comptime {
        var table = [_]Opcode{.unsupported} ** size;
        for (entries) |e| {
            const id, const op = e;
            if (id >= size) @compileError("opcode exceeds table size: " ++ @tagName(op));
            if (table[id] != .unsupported) @compileError("duplicate opcode: " ++ @tagName(op));
            table[id] = op;
        }
        return table;
    }
}

const sop1_table = buildTable(256, &.{
    .{ 0x03, .s_mov_b32 },
    .{ 0x04, .s_mov_b64 },
    .{ 0x07, .s_not_b32 },
    .{ 0x08, .s_not_b64 },
    .{ 0x0a, .s_wqm_b64 },
    .{ 0x0b, .s_brev_b32 },
    .{ 0x0f, .s_bcnt1_i32_b32 },
    .{ 0x10, .s_bcnt1_i32_b64 },
    .{ 0x13, .s_ff1_i32_b32 },
    .{ 0x16, .s_flbit_i32_b64 },
    .{ 0x1b, .s_bitset0_b32 },
    .{ 0x1d, .s_bitset1_b32 },
    .{ 0x1f, .s_getpc_b64 },
    .{ 0x20, .s_setpc_b64 },
    .{ 0x24, .s_and_saveexec_b64 },
    .{ 0x28, .s_orn2_saveexec_b64 },
    .{ 0x34, .s_abs_i32 },
    .{ 0x37, .s_andn1_saveexec_b64 },
    .{ 0x3b, .s_bitreplicate_b64_b32 },
    .{ 0x3c, .s_and_saveexec_b32 },
    .{ 0x44, .s_andn1_saveexec_b32 },
});

const sop2_table = buildTable(128, &.{
    .{ 0x00, .s_add_u32 },         .{ 0x01, .s_sub_u32 },
    .{ 0x02, .s_add_i32 },         .{ 0x03, .s_sub_i32 },
    .{ 0x04, .s_addc_u32 },        .{ 0x05, .s_subb_u32 },
    .{ 0x06, .s_min_i32 },         .{ 0x07, .s_min_u32 },
    .{ 0x08, .s_max_i32 },         .{ 0x09, .s_max_u32 },
    .{ 0x0a, .s_cselect_b32 },     .{ 0x0b, .s_cselect_b64 },
    .{ 0x0e, .s_and_b32 },         .{ 0x0f, .s_and_b64 },
    .{ 0x10, .s_or_b32 },          .{ 0x11, .s_or_b64 },
    .{ 0x12, .s_xor_b32 },         .{ 0x13, .s_xor_b64 },
    .{ 0x14, .s_andn2_b32 },       .{ 0x15, .s_andn2_b64 },
    .{ 0x16, .s_orn2_b32 },        .{ 0x17, .s_orn2_b64 },
    .{ 0x18, .s_nand_b32 },        .{ 0x19, .s_nand_b64 },
    .{ 0x1a, .s_nor_b32 },         .{ 0x1b, .s_nor_b64 },
    .{ 0x1c, .s_xnor_b32 },        .{ 0x1d, .s_xnor_b64 },
    .{ 0x1e, .s_lshl_b32 },        .{ 0x1f, .s_lshl_b64 },
    .{ 0x20, .s_lshr_b32 },        .{ 0x21, .s_lshr_b64 },
    .{ 0x22, .s_ashr_i32 },        .{ 0x24, .s_bfm_b32 },
    .{ 0x25, .s_bfm_b64 },         .{ 0x26, .s_mul_i32 },
    .{ 0x27, .s_bfe_u32 },         .{ 0x29, .s_bfe_u64 },
    .{ 0x2e, .s_lshl1_add_u32 },   .{ 0x2f, .s_lshl2_add_u32 },
    .{ 0x30, .s_lshl3_add_u32 },   .{ 0x31, .s_lshl4_add_u32 },
    .{ 0x32, .s_pack_ll_b32_b16 }, .{ 0x33, .s_pack_lh_b32_b16 },
    .{ 0x34, .s_pack_hh_b32_b16 }, .{ 0x35, .s_mul_hi_u32 },
});

const sopc_table = buildTable(128, &.{
    .{ 0x00, .s_cmp_eq_i32 },  .{ 0x01, .s_cmp_lg_i32 },
    .{ 0x02, .s_cmp_gt_i32 },  .{ 0x03, .s_cmp_ge_i32 },
    .{ 0x04, .s_cmp_lt_i32 },  .{ 0x05, .s_cmp_le_i32 },
    .{ 0x06, .s_cmp_eq_u32 },  .{ 0x07, .s_cmp_lg_u32 },
    .{ 0x08, .s_cmp_gt_u32 },  .{ 0x09, .s_cmp_ge_u32 },
    .{ 0x0a, .s_cmp_lt_u32 },  .{ 0x0b, .s_cmp_le_u32 },
    .{ 0x0c, .s_bitcmp0_b32 }, .{ 0x0d, .s_bitcmp1_b32 },
    .{ 0x13, .s_cmp_lg_u64 },
});

const sopk_table = buildTable(32, &.{
    .{ 0x00, .s_movk_i32 },   .{ 0x03, .s_cmp_eq_i32 },
    .{ 0x04, .s_cmp_lg_i32 }, .{ 0x05, .s_cmp_gt_i32 },
    .{ 0x06, .s_cmp_ge_i32 }, .{ 0x07, .s_cmp_lt_i32 },
    .{ 0x08, .s_cmp_le_i32 }, .{ 0x09, .s_cmp_eq_u32 },
    .{ 0x0a, .s_cmp_lg_u32 }, .{ 0x0b, .s_cmp_gt_u32 },
    .{ 0x0c, .s_cmp_ge_u32 }, .{ 0x0d, .s_cmp_lt_u32 },
    .{ 0x0e, .s_cmp_le_u32 }, .{ 0x0f, .s_add_i32 },
    .{ 0x10, .s_mulk_i32 },   .{ 0x13, .s_setreg_b32 },
    // The four s_waitcnt encodings differ only in which counter they wait on.
    .{ 0x17, .s_waitcnt },    .{ 0x18, .s_waitcnt },
    .{ 0x19, .s_waitcnt },    .{ 0x1a, .s_waitcnt },
});

const sopp_table = buildTable(128, &.{
    .{ 0x00, .s_nop },            .{ 0x01, .s_endpgm },
    .{ 0x02, .s_branch },         .{ 0x04, .s_cbranch_scc0 },
    .{ 0x05, .s_cbranch_scc1 },   .{ 0x06, .s_cbranch_vccz },
    .{ 0x07, .s_cbranch_vccnz },  .{ 0x08, .s_cbranch_execz },
    .{ 0x09, .s_cbranch_execnz }, .{ 0x0a, .s_barrier },
    .{ 0x0c, .s_waitcnt },        .{ 0x0e, .s_sleep },
    .{ 0x10, .s_sendmsg },        .{ 0x16, .s_ttrace_data },
    .{ 0x20, .s_inst_prefetch },
});

comptime {
    // The tables are built by the compiler, so mistakes in them are compile
    // errors rather than test failures. These assertions pin the layout.
    std.debug.assert(sop1_table[0x03] == .s_mov_b32);
    std.debug.assert(sop2_table[0x00] == .s_add_u32);
    std.debug.assert(sopc_table[0x00] == .s_cmp_eq_i32);
    std.debug.assert(sopp_table[0x01] == .s_endpgm);
}

/// Decodes both scalar sources and fetches the literal, if any.
fn decodeBinarySources(
    inst: *Instruction,
    code: []const u32,
    word_index: u32,
    ssrc0: u32,
    ssrc1: u32,
) Error!void {
    inst.src0 = try operand.decodeScalarSource(ssrc0);
    inst.src1 = try operand.decodeScalarSource(ssrc1);
    inst.src_count = 2;
    try inst.readLiteralOperands(code, word_index);
}

pub fn decodeSop1(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const opcode_id = (word >> 8) & 0xff;
    const ssrc0 = word & 0xff;
    const sdst = (word >> 16) & 0x7f;

    var inst = Instruction{
        .pc = pc,
        .word = word,
        .family = .sop1,
        .opcode_id = opcode_id,
        .opcode = sop1_table[opcode_id],
    };
    inst.setRawWords(code, word_index, 1);

    if (inst.opcode == .unsupported) {
        inst.setUnsupported(.sop1, opcode_id, "SOP1 opcode is not implemented");
        return inst;
    }

    switch (inst.opcode) {
        // s_getpc_b64 reads no source; it only writes the next instruction address.
        .s_getpc_b64 => {
            inst.src_count = 0;
            inst.dst = try operand.decodeScalarDestination(sdst);
            return inst;
        },
        // s_setpc_b64 is the mirror image: a source but no destination.
        .s_setpc_b64 => {
            inst.src_count = 1;
            inst.dst = .{ .kind = .@"null" };
            inst.src0 = try operand.decodeScalarSource(ssrc0);
            try inst.readLiteralOperands(code, word_index);
            return inst;
        },
        else => {},
    }

    inst.src0 = try operand.decodeScalarSource(ssrc0);
    inst.dst = try operand.decodeScalarDestination(sdst);
    inst.src_count = 1;
    try inst.readLiteralOperands(code, word_index);
    return inst;
}

pub fn decodeSop2(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const opcode_id = (word >> 23) & 0x7f;
    const ssrc0 = word & 0xff;
    const ssrc1 = (word >> 8) & 0xff;
    const sdst = (word >> 16) & 0x7f;

    var inst = Instruction{
        .pc = pc,
        .word = word,
        .family = .sop2,
        .opcode_id = opcode_id,
        .opcode = sop2_table[opcode_id],
    };
    inst.setRawWords(code, word_index, 1);

    if (inst.opcode == .unsupported) {
        inst.setUnsupported(.sop2, opcode_id, "SOP2 opcode is not implemented");
        return inst;
    }

    inst.dst = try operand.decodeScalarDestination(sdst);
    try decodeBinarySources(&inst, code, word_index, ssrc0, ssrc1);
    return inst;
}

pub fn decodeSopk(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const opcode_id = (word >> 23) & 0x1f;
    const sdst = (word >> 16) & 0x7f;
    const imm: i16 = @bitCast(@as(u16, @truncate(word & 0xffff)));

    var inst = Instruction{
        .pc = pc,
        .word = word,
        .family = .sopk,
        .opcode_id = opcode_id,
        .opcode = sopk_table[opcode_id],
        .src0 = .{
            .kind = .integer_inline_constant,
            .signed_val = imm,
            .value = @bitCast(@as(i32, imm)),
        },
        .src_count = 1,
    };
    inst.setRawWords(code, word_index, 1);

    if (inst.opcode == .unsupported) {
        inst.setUnsupported(.sopk, opcode_id, "SOPK opcode is not implemented");
        return inst;
    }

    switch (inst.opcode) {
        .s_movk_i32 => {
            inst.dst = try operand.decodeScalarDestination(sdst);
            return inst;
        },
        // For s_waitcnt the 16-bit field is a set of counters, not a signed value.
        .s_waitcnt => {
            const waitcnt = word & 0xffff;
            inst.dst = .{ .kind = .@"null" };
            inst.src0.signed_val = @intCast(waitcnt);
            inst.src0.value = waitcnt;
            inst.src_count = 1;
            return inst;
        },
        .s_setreg_b32 => {
            inst.dst = .{ .kind = .@"null" };
            inst.src1 = .{
                .kind = .literal_constant,
                .value = word & 0xffff,
                .signed_val = imm,
            };
            inst.src_count = 2;
            inst.src0 = try operand.decodeScalarSource(sdst);
            return inst;
        },
        else => {},
    }

    // The remaining SOPK instructions compare a register against an immediate:
    // here the sdst field acts as a source.
    inst.src1 = inst.src0;
    inst.src0 = try operand.decodeScalarSource(sdst);

    if (inst.opcode == .s_add_i32 or inst.opcode == .s_mulk_i32) {
        inst.src_count = 2;
        inst.dst = try operand.decodeScalarDestination(sdst);
        return inst;
    }

    inst.dst = .{ .kind = .scc };
    inst.src_count = 2;
    return inst;
}

pub fn decodeSopc(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const opcode_id = (word >> 16) & 0x7f;
    const ssrc0 = word & 0xff;
    const ssrc1 = (word >> 8) & 0xff;

    var inst = Instruction{
        .pc = pc,
        .word = word,
        .family = .sopc,
        .opcode_id = opcode_id,
        .opcode = sopc_table[opcode_id],
        .dst = .{ .kind = .scc },
    };
    inst.setRawWords(code, word_index, 1);

    if (inst.opcode == .unsupported) {
        inst.setUnsupported(.sopc, opcode_id, "SOPC opcode is not implemented");
        return inst;
    }

    try decodeBinarySources(&inst, code, word_index, ssrc0, ssrc1);
    return inst;
}

pub fn decodeSopp(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];
    const opcode_id = (word >> 16) & 0x7f;
    const simm: u32 = word & 0xffff;
    const signed_simm: i16 = @bitCast(@as(u16, @truncate(simm)));

    var inst = Instruction{
        .pc = pc,
        .word = word,
        .family = .sopp,
        .opcode_id = opcode_id,
        .opcode = sopp_table[opcode_id],
        .src0 = .{
            .kind = .literal_constant,
            .value = simm,
            .signed_val = signed_simm,
        },
    };

    // For some SOPP instructions the immediate field is an operand; for the
    // rest (branches) it is an offset, printed as a target instead of a source.
    inst.src_count = switch (inst.opcode) {
        .s_nop, .s_waitcnt, .s_sleep, .s_sendmsg, .s_ttrace_data, .s_inst_prefetch => 1,
        else => 0,
    };

    // The branch offset counts words from the instruction following this one.
    inst.branch_offset = @as(i32, signed_simm) * 4;
    inst.branch_target = pc +% 4 +% @as(u32, @bitCast(inst.branch_offset));
    inst.setRawWords(code, word_index, 1);

    if (inst.opcode == .unsupported) {
        inst.setUnsupported(.sopp, opcode_id, "SOPP control-flow opcode is not implemented");
    }
    return inst;
}

test "s_mov_b32 s0, s1" {
    const code = [_]u32{0xbe80_0301};
    const inst = try decodeSop1(0, &code, 0);
    try std.testing.expectEqual(Opcode.s_mov_b32, inst.opcode);
    try std.testing.expectEqual(isa.Family.sop1, inst.family);
    try std.testing.expectEqual(@as(u32, 0), inst.dst.reg);
    try std.testing.expectEqual(isa.OperandKind.sgpr, inst.dst.kind);
    try std.testing.expectEqual(@as(u32, 1), inst.src0.reg);
    try std.testing.expectEqual(@as(u32, 1), inst.word_count);
}

test "s_mov_b32 with a literal occupies two words" {
    // ssrc0 = 255 -> literal in the following word.
    const code = [_]u32{ 0xbe80_03ff, 0x1234_5678 };
    const inst = try decodeSop1(0, &code, 0);
    try std.testing.expectEqual(Opcode.s_mov_b32, inst.opcode);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), inst.src0.value);
}

test "an unimplemented SOP1 opcode does not abort the parse" {
    // Opcode 0x02 is absent from the table.
    const code = [_]u32{0xbe80_0200};
    const inst = try decodeSop1(0, &code, 0);
    try std.testing.expectEqual(Opcode.unsupported, inst.opcode);
    try std.testing.expectEqual(@as(u32, 0x02), inst.opcode_id);
    try std.testing.expect(inst.unsupported_reason.len > 0);
}

test "s_endpgm" {
    const code = [_]u32{0xbf81_0000};
    const inst = try decodeSopp(0, &code, 0);
    try std.testing.expectEqual(Opcode.s_endpgm, inst.opcode);
    try std.testing.expectEqual(@as(u32, 0), inst.src_count);
}

test "s_branch resolves its target relative to the next instruction" {
    // simm = -2 -> target = pc + 4 + (-2*4) = pc - 4.
    const code = [_]u32{0xbf82_fffe};
    const inst = try decodeSopp(8, &code, 0);
    try std.testing.expectEqual(Opcode.s_branch, inst.opcode);
    try std.testing.expectEqual(@as(i32, -8), inst.branch_offset);
    try std.testing.expectEqual(@as(u32, 4), inst.branch_target);
    try std.testing.expect(inst.opcode.isBranch());
}
